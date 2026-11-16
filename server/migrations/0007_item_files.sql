-- Files on items, kept byte for byte with their name. As with images, the list on the item row
-- is the only copy of a file's metadata (id, name, mime, bytes, sha256, upload_id), and the bytes
-- sit in a table of their own that one route reads.
-- AUTOINCREMENT, so the ID of a removed file is not given to a later one.
ALTER TABLE items ADD COLUMN files TEXT NOT NULL DEFAULT '[]';

CREATE TABLE item_files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL REFERENCES items(id),
    data BLOB NOT NULL
);
CREATE INDEX item_files_item ON item_files(item_id);

-- Settings of the server that the owner changes in the app. One row.
CREATE TABLE server_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    file_limit_mb INTEGER NOT NULL DEFAULT 25 CHECK (file_limit_mb BETWEEN 1 AND 100)
);
INSERT INTO server_settings(id) VALUES (1);
