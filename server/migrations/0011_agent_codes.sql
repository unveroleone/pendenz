-- A one-time code that connects an agent: the owner makes it in the app, and `pendenz connect`
-- on the agent's machine trades it for a new agent and its token. Stored as a hash, used once,
-- ten minutes long, like a pairing code. The scopes are chosen when the code is made.
CREATE TABLE agent_codes (
    code_hash TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    scopes TEXT NOT NULL,
    created_by TEXT REFERENCES devices(id),
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
