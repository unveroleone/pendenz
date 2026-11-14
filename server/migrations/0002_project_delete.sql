-- A project can be deleted. Its row stays with deleted = 1, so the changes feed can tell every
-- client. No item or note points at it any more, and its name is free for a new project: the
-- name is unique only among the projects that are not deleted.
--
-- SQLite cannot take the UNIQUE off a column, so the table is made again. A migration runs in
-- one transaction, where foreign keys cannot be switched off. They are checked at its end
-- instead: by then every project is back under its ID.
PRAGMA defer_foreign_keys = ON;

CREATE TABLE projects_before AS SELECT * FROM projects;
DROP TABLE projects;

-- icon is the name of a symbol the app draws next to the name. NULL means the app's default.
CREATE TABLE projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    icon TEXT,
    deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1)),
    seq INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
INSERT INTO projects(id, name, icon, deleted, seq, created_at)
    SELECT id, name, icon, 0, seq, created_at FROM projects_before;
DROP TABLE projects_before;

CREATE UNIQUE INDEX projects_seq ON projects(seq);
CREATE UNIQUE INDEX projects_name ON projects(name) WHERE deleted = 0;
