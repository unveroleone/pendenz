-- The APNs token of a paired device. With it the server can ask the app on that device to sync
-- after a change, through the push relay.
CREATE TABLE push_tokens (
    device_id TEXT PRIMARY KEY REFERENCES devices(id),
    token TEXT NOT NULL,
    environment TEXT NOT NULL CHECK(environment IN ('sandbox', 'production')),
    -- New with every registration and never used twice. An answer about an older registration
    -- that arrives late names it and so cannot remove a newer one.
    registration TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- One device holds a token. A phone that is paired again takes its token along.
CREATE UNIQUE INDEX push_tokens_token ON push_tokens(environment, token);
