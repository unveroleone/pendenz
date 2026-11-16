-- Images and files become one list. An image is a file with a width and a height, kept in
-- items.files and item_files like any other.
-- Images keep their IDs. Files move up by the highest image ID ever given, so an old file ID
-- never meets an image ID, and the sequence goes on above both, so no removed ID comes back.
-- The activity rows about images stay as they are: they are history.

CREATE TABLE item_attachments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id INTEGER NOT NULL REFERENCES items(id),
    data BLOB NOT NULL
);

CREATE TEMP TABLE merge_offset AS
SELECT
    max(
        coalesce((SELECT seq FROM sqlite_sequence WHERE name = 'item_images'), 0),
        coalesce((SELECT max(id) FROM item_images), 0)
    ) AS images,
    max(
        coalesce((SELECT seq FROM sqlite_sequence WHERE name = 'item_files'), 0),
        coalesce((SELECT max(id) FROM item_files), 0)
    ) AS files;

INSERT INTO item_attachments(id, item_id, data)
SELECT id, item_id, data FROM item_images;

INSERT INTO item_attachments(id, item_id, data)
SELECT id + (SELECT images FROM merge_offset), item_id, data FROM item_files;

-- The images first, then the files, each in the order they had. The list is joined as text:
-- json_group_array with an ORDER BY would quote each entry as a string.
UPDATE items SET files = (
    SELECT json('[' || group_concat(entry, ',' ORDER BY part, at) || ']') FROM (
        SELECT
            0 AS part,
            image.key AS at,
            json_object(
                'id', image.value ->> 'id',
                'name', CASE image.value ->> 'mime' WHEN 'image/png' THEN 'Image.png' ELSE 'Image.jpg' END,
                'mime', image.value ->> 'mime',
                'bytes', image.value ->> 'bytes',
                'sha256', image.value ->> 'sha256',
                'width', image.value ->> 'width',
                'height', image.value ->> 'height'
            ) AS entry
        FROM json_each(items.images) AS image
        UNION ALL
        SELECT
            1,
            file.key,
            json_set(file.value, '$.id', (file.value ->> 'id') + (SELECT images FROM merge_offset))
        FROM json_each(items.files) AS file
    )
)
WHERE images <> '[]' OR files <> '[]';

DELETE FROM sqlite_sequence WHERE name = 'item_attachments';
INSERT INTO sqlite_sequence(name, seq)
SELECT 'item_attachments', images + files FROM merge_offset;

DROP TABLE merge_offset;
DROP TABLE item_images;
DROP TABLE item_files;
ALTER TABLE item_attachments RENAME TO item_files;
CREATE INDEX item_files_item ON item_files(item_id);

ALTER TABLE items DROP COLUMN images;
