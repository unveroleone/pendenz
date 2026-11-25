-- Files on notes, kept like the files on items: the list on the note row is the only copy of
-- their metadata, and the bytes sit in a table of their own. A file is always looked up together
-- with its note, so its ID needs to be unique among the note files only.
-- AUTOINCREMENT, so the ID of a removed file is not given to a later one.
ALTER TABLE notes ADD COLUMN files TEXT NOT NULL DEFAULT '[]';

CREATE TABLE note_files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id INTEGER NOT NULL REFERENCES notes(id),
    data BLOB NOT NULL
);
CREATE INDEX note_files_note ON note_files(note_id);
