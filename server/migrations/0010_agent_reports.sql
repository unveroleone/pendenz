-- The latest status report of each agent, sent with `pendenz report`. Only the latest is kept:
-- a report carries the history it shows (days, samples) itself. A report is not item data, so it
-- is not in the activity log, the changes feed or a push.
CREATE TABLE agent_reports (
    actor_id TEXT PRIMARY KEY REFERENCES actors(id),
    body TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
