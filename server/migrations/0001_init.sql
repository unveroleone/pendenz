CREATE TABLE actors (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('human', 'agent'))
);
INSERT INTO actors(id, name, kind) VALUES
    ('leo', 'Leo', 'human'),
    ('hermes', 'Hermes', 'agent'),
    ('claude-code', 'Claude Code', 'agent'),
    ('dispatcher', 'Dispatcher', 'agent'),
    ('telegram-bridge', 'Telegram bridge', 'agent');

-- One counter for the changes feed. Every row write takes the next value in its transaction.
CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value INTEGER NOT NULL
) WITHOUT ROWID;
INSERT INTO meta(key, value) VALUES ('seq', 0);

-- icon is the name of a symbol the app draws next to the name. NULL means the app's default.
CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    icon TEXT,
    seq INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX projects_seq ON projects(seq);

-- due_at and remind_at hold local time with the offset of due_tz, as the API returns them.
-- due_utc and remind_utc are the same instants in UTC, used only for sorting and range queries.
-- remind_utc is the effective reminder: remind_at, or due_at when that has a time.
-- position is the manual order inside the inbox or a project, highest first. A new item gets its
-- sequence number, so it lands on top. A client that reorders sends a value between two neighbours.
CREATE TABLE items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo', 'doing', 'done')),
    project_id TEXT REFERENCES projects(id),
    priority INTEGER NOT NULL DEFAULT 0 CHECK(priority BETWEEN 0 AND 4),
    position REAL NOT NULL,
    tags TEXT NOT NULL DEFAULT '[]',
    checklist TEXT NOT NULL DEFAULT '[]',
    due_at TEXT,
    due_tz TEXT,
    due_utc TEXT,
    remind_at TEXT,
    remind_utc TEXT,
    repeat_rule TEXT,
    agent_stage TEXT NOT NULL CHECK(agent_stage IN ('new', 'none', 'gathering', 'needs_answer', 'ready', 'running', 'review', 'declined')),
    hidden_from_agents INTEGER NOT NULL DEFAULT 0 CHECK(hidden_from_agents IN (0, 1)),
    created_via TEXT NOT NULL CHECK(created_via IN ('app', 'siri', 'share', 'shortcut', 'telegram', 'mcp')),
    source_url TEXT,
    archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
    trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0, 1)),
    completed_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    seq INTEGER NOT NULL,
    created_by TEXT NOT NULL REFERENCES actors(id),
    updated_by TEXT NOT NULL REFERENCES actors(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK((due_at IS NULL) = (due_tz IS NULL)),
    CHECK((due_at IS NULL) = (due_utc IS NULL)),
    CHECK(repeat_rule IS NULL OR due_at IS NOT NULL)
);
CREATE UNIQUE INDEX items_seq ON items(seq);
-- Most rows end up done. These cover the open ones, which is what lists and reminders ask for.
-- A query has to repeat the WHERE terms as literals for SQLite to pick a partial index.
CREATE INDEX items_open ON items(id) WHERE status <> 'done' AND trashed = 0 AND archived = 0;
CREATE INDEX items_due ON items(due_utc, id) WHERE due_utc IS NOT NULL AND status <> 'done' AND trashed = 0 AND archived = 0;
CREATE INDEX items_remind ON items(remind_utc, id) WHERE remind_utc IS NOT NULL AND status <> 'done' AND trashed = 0 AND archived = 0;
CREATE INDEX items_archived ON items(id) WHERE archived = 1 AND trashed = 0;
CREATE INDEX items_trashed ON items(id) WHERE trashed = 1;

CREATE TABLE comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL REFERENCES items(id),
    author_id TEXT NOT NULL REFERENCES actors(id),
    body TEXT NOT NULL,
    seq INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX comments_item ON comments(item_id, id);
CREATE UNIQUE INDEX comments_seq ON comments(seq);

-- A note is markdown text. Its first line is its title. Pinned notes sort first.
CREATE TABLE notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    body TEXT NOT NULL,
    project_id TEXT REFERENCES projects(id),
    pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0, 1)),
    hidden_from_agents INTEGER NOT NULL DEFAULT 0 CHECK(hidden_from_agents IN (0, 1)),
    trashed INTEGER NOT NULL DEFAULT 0 CHECK(trashed IN (0, 1)),
    version INTEGER NOT NULL DEFAULT 1,
    seq INTEGER NOT NULL,
    created_by TEXT NOT NULL REFERENCES actors(id),
    updated_by TEXT NOT NULL REFERENCES actors(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX notes_seq ON notes(seq);
CREATE INDEX notes_listed ON notes(pinned DESC, updated_at DESC, id DESC) WHERE trashed = 0;

CREATE TABLE activity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER REFERENCES items(id),
    note_id INTEGER REFERENCES notes(id),
    actor_id TEXT NOT NULL REFERENCES actors(id),
    action TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX activity_item ON activity(item_id, id);
CREATE INDEX activity_note ON activity(note_id, id) WHERE note_id IS NOT NULL;
CREATE TRIGGER activity_no_update BEFORE UPDATE ON activity BEGIN SELECT RAISE(ABORT, 'Activity is append-only'); END;
CREATE TRIGGER activity_no_delete BEFORE DELETE ON activity BEGIN SELECT RAISE(ABORT, 'Activity is append-only'); END;

-- One row per paired iPhone, iPad or Mac. Its token is a row in tokens that names the device, so
-- a device is revoked by revoking that token.
CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE tokens (
    id TEXT PRIMARY KEY,
    actor_id TEXT NOT NULL REFERENCES actors(id),
    label TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    scopes TEXT NOT NULL,
    device_id TEXT UNIQUE REFERENCES devices(id),
    revoked INTEGER NOT NULL DEFAULT 0 CHECK(revoked IN (0, 1)),
    expires_at TEXT,
    last_used_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- A pairing code is stored as a hash and deleted when it is used. created_by is the device that
-- showed it, or NULL for a code from the server's command line.
CREATE TABLE pairing_codes (
    code_hash TEXT PRIMARY KEY,
    created_by TEXT REFERENCES devices(id),
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) WITHOUT ROWID;

-- A key remembers which row its request wrote. A retry reads that row again, so no copy of
-- the response is stored and the usual visibility check applies.
CREATE TABLE idempotency (
    actor_id TEXT NOT NULL REFERENCES actors(id),
    key TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    resource TEXT NOT NULL CHECK(resource IN ('item', 'comment', 'project', 'note')),
    resource_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY(actor_id, key)
) WITHOUT ROWID;
