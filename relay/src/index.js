// The push relay: a Pendenz server names the devices that should sync, and the relay asks APNs
// to wake the app on them. It holds the APNs key of the app, which a self-hosted server cannot
// have. The caller chooses neither the payload nor the topic, so the relay can only ever say
// "sync now", and it never sees an item or a note.

const ORIGINS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};
const MAX_DEVICES = 16;
const MAX_BODY = 8 * 1024;
// Apple wants a provider token replaced at most every 20 minutes and at least every 60.
const TOKEN_MINUTES = 45;
const MIN_TOKEN_MINUTES = 20;
// How long APNs keeps the push for a device that is offline. It holds one per app and device.
const KEEP_SECONDS = 3600;
// Apple does not promise a length, so anything from today's 32 bytes up is taken.
const DEVICE_TOKEN = /^[0-9a-f]{64,200}$/;

// Provider tokens by key ID. They live as long as this isolate does.
const providerTokens = new Map();

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    },
  });
}

function refuse(status, message) {
  return json(status, { error: message });
}

function base64url(bytes) {
  let text = '';
  for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// The key and its ID for an environment. A key made for the sandbox alone is optional: without
// it the main key serves both.
function keyFor(env, environment) {
  if (environment === 'sandbox' && env.APNS_SANDBOX_KEY) {
    return { pem: env.APNS_SANDBOX_KEY, id: env.APNS_SANDBOX_KEY_ID };
  }
  return { pem: env.APNS_KEY, id: env.APNS_KEY_ID };
}

async function sign(env, key, now) {
  const der = Uint8Array.from(
    atob(key.pem.replace(/-----[^-]+-----|\s/g, '')),
    (char) => char.charCodeAt(0),
  );
  const secret = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const text = new TextEncoder();
  const head = base64url(
    text.encode(JSON.stringify({ alg: 'ES256', kid: key.id })),
  );
  const claims = base64url(
    text.encode(
      JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) }),
    ),
  );
  // WebCrypto answers with r and s side by side, which is the form a JWT carries.
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    secret,
    text.encode(`${head}.${claims}`),
  );
  return `${head}.${claims}.${base64url(signature)}`;
}

// The provider token for a key, made again when it is older than `minutes`.
async function providerToken(env, key, minutes = TOKEN_MINUTES) {
  const now = Date.now();
  const kept = providerTokens.get(key.id);
  if (kept && now - kept.madeAt < minutes * 60_000) return kept.promise;
  // The promise is kept, not the token, so requests that arrive together sign once.
  const promise = sign(env, key, now);
  providerTokens.set(key.id, { madeAt: now, promise });
  try {
    return await promise;
  } catch (error) {
    providerTokens.delete(key.id);
    throw error;
  }
}

async function post(env, origin, device, token) {
  return fetch(`${origin}/3/device/${device.token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${token}`,
      'apns-push-type': 'background',
      // Apple: a background push always has priority 5.
      'apns-priority': '5',
      'apns-topic': env.APNS_TOPIC,
      'apns-collapse-id': 'sync',
      'apns-expiration': String(Math.floor(Date.now() / 1000) + KEEP_SECONDS),
      'content-type': 'application/json',
    },
    body: '{"aps":{"content-available":1}}',
  });
}

async function reason(response) {
  try {
    return (await response.json()).reason ?? '';
  } catch {
    return '';
  }
}

// One device. The answer is a word the server can act on: it forgets a token that is gone or
// invalid and leaves the rest alone.
async function push(env, device) {
  const { success } = await env.DEVICE_LIMIT.limit({ key: device.token });
  if (!success) return 'limited';
  const key = keyFor(env, device.environment);
  const origin =
    (device.environment === 'sandbox'
      ? env.APNS_SANDBOX_ORIGIN
      : env.APNS_ORIGIN) || ORIGINS[device.environment];
  try {
    let response = await post(
      env,
      origin,
      device,
      await providerToken(env, key),
    );
    let why = response.ok ? '' : await reason(response);
    if (response.status === 403 && why === 'ExpiredProviderToken') {
      // Never sooner than Apple allows a new one, or it refuses them all for a while.
      response = await post(
        env,
        origin,
        device,
        await providerToken(env, key, MIN_TOKEN_MINUTES),
      );
      why = response.ok ? '' : await reason(response);
    }
    if (response.ok) return 'sent';
    if (response.status === 410) return 'gone';
    if (why === 'BadDeviceToken' || why === 'DeviceTokenNotForTopic')
      return 'invalid';
    if (response.status === 429) return 'limited';
    // The reason names no device. It tells whoever runs the relay what to repair.
    console.error(`APNs ${device.environment} ${response.status} ${why}`);
    return 'failed';
  } catch (error) {
    console.error(`APNs ${device.environment} unreachable: ${error.message}`);
    return 'failed';
  }
}

async function read(request) {
  const length = Number(request.headers.get('content-length') ?? 0);
  if (length > MAX_BODY) return null;
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BODY) return null;
  return body;
}

// While RELAY_SECRET is set, only a server that sends it may ask. Both sides are hashed first,
// so the comparison takes the same time whatever was sent.
async function isAllowed(request, env) {
  if (!env.RELAY_SECRET) return true;
  const sent = request.headers.get('authorization') ?? '';
  const text = new TextEncoder();
  const [given, wanted] = await Promise.all([
    crypto.subtle.digest('SHA-256', text.encode(sent)),
    crypto.subtle.digest('SHA-256', text.encode(`Bearer ${env.RELAY_SECRET}`)),
  ]);
  return crypto.subtle.timingSafeEqual(given, wanted);
}

function devicesFrom(body) {
  let sent;
  try {
    sent = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return null;
  }
  if (sent?.kind !== 'sync' || !Array.isArray(sent.devices)) return null;
  if (sent.devices.length === 0 || sent.devices.length > MAX_DEVICES)
    return null;
  const devices = [];
  for (const device of sent.devices) {
    const token =
      typeof device?.token === 'string' ? device.token.toLowerCase() : '';
    if (!DEVICE_TOKEN.test(token) || !(device.environment in ORIGINS))
      return null;
    devices.push({ token, environment: device.environment });
  }
  return devices;
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === '/healthz') return json(200, { status: 'ok' });
    if (pathname !== '/v1/push') return refuse(404, 'Not found.');
    if (request.method !== 'POST')
      return refuse(405, 'This route takes a POST.');
    if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
      return refuse(503, 'The relay has no APNs key.');
    }
    if (!(await isAllowed(request, env))) {
      return refuse(401, 'This relay is not open to other servers yet.');
    }
    const caller = request.headers.get('cf-connecting-ip') ?? 'unknown';
    const { success } = await env.CALLER_LIMIT.limit({ key: caller });
    if (!success) return refuse(429, 'Too many requests. Try again later.');
    const body = await read(request);
    if (!body) return refuse(413, 'The request body is larger than 8 KB.');
    const devices = devicesFrom(body);
    if (!devices) {
      return refuse(
        400,
        `Send {"kind": "sync", "devices": [{"token", "environment"}]} with 1 to ${MAX_DEVICES} devices. The environment is sandbox or production.`,
      );
    }
    const statuses = await Promise.all(
      devices.map((device) => push(env, device)),
    );
    return json(200, { results: statuses.map((status) => ({ status })) });
  },
};
