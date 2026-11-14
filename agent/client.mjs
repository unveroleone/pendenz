import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const LOOPBACK = ['localhost', '127.0.0.1', '[::1]'];

// One request function for the CLI and both MCP servers.
// PENDENZ_API_URL and PENDENZ_API_TOKEN come from the environment. PENDENZ_SOURCE names where
// new items come from ("telegram" for an agent that captures from Telegram, otherwise the server records "mcp").
export function createClient(config = process.env, internal = false) {
  // With `binary` a successful answer is returned as `{ mime, data }` instead of parsed JSON.
  // An image takes longer than a row, so it gets more time.
  return async function request(
    path,
    { method = 'GET', body, key, binary = false } = {},
  ) {
    const isImage = /^\/items\/\d+\/images/.test(path);
    const base = new URL(config.PENDENZ_API_URL || 'http://127.0.0.1:8080');
    if (
      base.protocol !== 'https:' &&
      !LOOPBACK.includes(base.hostname) &&
      !(internal && base.href === 'http://api:8080/')
    ) {
      throw new Error('Use HTTPS when sending a token to a remote API.');
    }
    if (!config.PENDENZ_API_TOKEN)
      throw new Error('Set PENDENZ_API_TOKEN to your Pendenz token.');
    const headers = { Authorization: `Bearer ${config.PENDENZ_API_TOKEN}` };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      // A retry of the same action has to reuse its key. Without one, each call is its own action.
      headers['Idempotency-Key'] = key || randomUUID();
      if (method === 'POST' && path === '/items' && config.PENDENZ_SOURCE)
        body = { ...body, created_via: config.PENDENZ_SOURCE };
    }
    const response = await fetch(new URL(`/api${path}`, base), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(isImage ? 90_000 : 20_000),
    });
    if (binary && response.ok)
      return {
        mime:
          response.headers.get('content-type') || 'application/octet-stream',
        data: Buffer.from(await response.arrayBuffer()),
      };
    if (!response.headers.get('content-type')?.includes('application/json'))
      throw new Error(
        `The API answered ${response.status} without JSON. Check PENDENZ_API_URL.`,
      );
    const result = await response.json();
    if (!response.ok)
      throw new Error(
        `${response.status}: ${result.error || 'Request failed'}`,
      );
    return result;
  };
}

export const request = (...args) => createClient()(...args);

// The symbols a project can show, as the app's project sheet offers them (`Project.symbols` in
// the app). The server takes any symbol name, but the app has no way to choose another one, and
// a name that is not a symbol draws as nothing.
export const PROJECT_ICONS = [
  'number',
  'house',
  'briefcase',
  'cart',
  'book',
  'graduationcap',
  'heart',
  'star',
  'flag',
  'bolt',
  'leaf',
  'pawprint',
  'hammer',
  'wrench.and.screwdriver',
  'server.rack',
  'desktopcomputer',
  'chevron.left.forwardslash.chevron.right',
  'banknote',
  'car',
  'airplane',
  'fork.knife',
  'dumbbell',
  'music.note',
  'lightbulb',
];

// A local image file as the upload route takes it. The first bytes decide the type, as they do
// on the server, which also checks the size and refuses anything else.
export async function imageBody(path) {
  const data = await readFile(String(path ?? ''));
  const mime =
    data[0] === 0xff && data[1] === 0xd8
      ? 'image/jpeg'
      : data.subarray(0, 4).toString('latin1') === '\x89PNG'
        ? 'image/png'
        : null;
  if (!mime) throw new Error('Only JPEG and PNG images can be attached.');
  if (data.length > 5 * 1024 * 1024)
    throw new Error('An image can be at most 5 MB.');
  return { mime, data: data.toString('base64') };
}

// An image ID from the item's images list.
export function imageId(value) {
  const id = String(value ?? '').trim();
  if (!/^[1-9]\d*$/.test(id))
    throw new Error("Use an image ID from the item's images list.");
  return Number(id);
}

// A project ID as the server makes it: lowercase letters, digits and hyphens.
export function projectId(value) {
  const id = String(value ?? '').trim();
  if (!/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/.test(id))
    throw new Error('Use a project ID from workspace, such as home-lab.');
  return id;
}

// Items are shown as P-12. Accepts that form or the plain number.
export function itemId(value) {
  const match = /^(?:P-)?([1-9]\d*)$/i.exec(String(value).trim());
  if (!match) throw new Error('Use an item ID like P-12 or 12.');
  return Number(match[1]);
}

// Notes have no prefix: the app never shows their ID.
export function noteId(value) {
  const id = String(value ?? '').trim();
  if (!/^[1-9]\d*$/.test(id)) throw new Error('Use a note ID like 12.');
  return Number(id);
}

export function query(params) {
  const entries = Object.entries(params).filter(
    ([, value]) => value !== undefined && value !== null && value !== '',
  );
  return entries.length
    ? `?${new URLSearchParams(entries.map(([k, v]) => [k, String(v)]))}`
    : '';
}
