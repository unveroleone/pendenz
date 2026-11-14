import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { request } from './client.mjs';
import { createMcpServer } from './mcp-tools.mjs';

// Offer only the tools this token may use. If the API cannot be reached at start, offer all of
// them and let each call report the error.
const scopes = await request('/identity').then(
  (identity) => identity.scopes,
  () => null,
);
// This server runs next to the agent, so it can read a file the agent names.
await createMcpServer(request, scopes, { files: true }).connect(
  new StdioServerTransport(),
);
