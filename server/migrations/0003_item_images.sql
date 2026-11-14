-- Images on items. The list on the item row is the only copy of an image's metadata (id, mime,
-- width, height, bytes, sha256), so every read of an item carries it without a join. The bytes
-- sit in a table of their own and are read by one route only.
-- AUTOINCREMENT, so the ID of a removed image is not given to a later one.
ALTER TABLE items ADD COLUMN images TEXT NOT NULL DEFAULT '[]';

CREATE TABLE item_images (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL REFERENCES items(id),
    data BLOB NOT NULL
);
CREATE INDEX item_images_item ON item_images(item_id);
