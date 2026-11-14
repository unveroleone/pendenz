import http from 'node:http';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createMcpServer } from './mcp-tools.mjs';
import { createClient } from './client.mjs';

// The hosted MCP endpoint: stateless POST /mcp with the caller's own Pendenz token. Each request
// is checked against the API and then served with exactly that token's scopes.
const origin = new URL(process.env.PENDENZ_ORIGIN || 'http://127.0.0.1:8090');
const api = process.env.PENDENZ_INTERNAL_API_URL || 'http://127.0.0.1:8080';
if (!['http://api:8080', 'http://127.0.0.1:8080'].includes(api))
  throw new Error('Use the private API service or the loopback address.');
const attempts = new Map();
let active = 0;
const server = http.createServer(async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  const reply = (status, message) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify(status === 200 ? { status: message } : { error: message }),
    );
  };
  if (req.url === '/healthz' && req.method === 'GET') return reply(200, 'ok');
  if (req.url !== '/mcp') return reply(404, 'Not found.');
  if (
    req.headers.host !== origin.host ||
    (req.headers.origin && req.headers.origin !== origin.origin)
  )
    return reply(403, 'Unrecognized host or origin.');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return reply(405, 'Use a stateless MCP POST request.');
  }
  const ip = req.headers['cf-connecting-ip'] || req.socket.remoteAddress;
  const now = Date.now();
  const bucket = attempts.get(ip) || { at: now, count: 0 };
  if (now - bucket.at >= 60_000) {
    bucket.at = now;
    bucket.count = 0;
  }
  bucket.count++;
  attempts.set(ip, bucket);
  if (attempts.size > 10_000) {
    for (const [key, value] of attempts)
      if (now - value.at >= 60_000) attempts.delete(key);
    if (attempts.size > 10_000) attempts.delete(attempts.keys().next().value);
  }
  if (bucket.count > 180 || active >= 32) {
    res.setHeader('Retry-After', '60');
    return reply(429, 'Too many requests. Retry shortly.');
  }
  const authorization = req.headers.authorization;
  if (
    typeof authorization !== 'string' ||
    !/^Bearer pdz_[a-f0-9]{64}$/.test(authorization)
  ) {
    res.setHeader('WWW-Authenticate', 'Bearer');
    return reply(401, 'Send a valid Pendenz bearer token.');
  }
  active++;
  let mcp, transport;
  try {
    const check = await fetch(`${api}/api/identity`, {
      headers: { Authorization: authorization },
      redirect: 'error',
      signal: AbortSignal.timeout(5000),
    });
    if (!check.ok) {
      if (check.status !== 401) return reply(503, 'The API is unavailable.');
      res.setHeader('WWW-Authenticate', 'Bearer');
      return reply(401, 'This token is invalid, expired or revoked.');
    }
    const identity = await check.json();
    if (!req.headers['content-type']?.startsWith('application/json'))
      return reply(415, 'Use application/json.');
    let bytes = 0;
    const chunks = [];
    for await (const chunk of req) {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) return reply(413, 'The request is too large.');
      chunks.push(chunk);
    }
    let body;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString());
    } catch {
      return reply(400, 'Invalid JSON.');
    }
    if (Array.isArray(body))
      return reply(400, 'Send one JSON-RPC request per call.');
    mcp = createMcpServer(
      createClient(
        {
          PENDENZ_API_URL: api,
          PENDENZ_API_TOKEN: authorization.slice(7),
        },
        true,
      ),
      identity.scopes,
    );
    transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    res.once('close', () => {
      void transport.close();
      void mcp.close();
    });
    await mcp.connect(transport);
    await transport.handleRequest(req, res, body);
  } catch {
    if (!res.headersSent) reply(503, 'MCP is temporarily unavailable.');
    else res.end();
  } finally {
    active--;
  }
});
server.requestTimeout = 30_000;
server.headersTimeout = 10_000;
server.listen(
  Number(process.env.PORT || 8090),
  process.env.HOST || '127.0.0.1',
);
const cleanup = setInterval(() => {
  for (const [key, value] of attempts)
    if (Date.now() - value.at >= 60_000) attempts.delete(key);
}, 60_000);
cleanup.unref();
for (const signal of ['SIGINT', 'SIGTERM'])
  process.on(signal, () => server.close(() => process.exit(0)));
