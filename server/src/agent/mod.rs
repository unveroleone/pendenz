// The agent side of the server: the hosted MCP endpoint at /mcp, the stdio MCP server
// (`pendenz mcp`) and the command line for agents and scripts. All three reach the data only
// through the API, with the agent's own token.
pub mod cli;
mod client;
pub mod hosted;
mod protocol;
mod schema;
pub mod stdio;
mod tools;
