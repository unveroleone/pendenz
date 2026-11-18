-- Comments can be edited, marked outdated and deleted. A deleted comment keeps its row with an
-- empty body, so the changes feed can tell the apps that it is gone. edited_at is set by the
-- first change to the text and stays NULL for a comment that was never edited.
ALTER TABLE comments ADD COLUMN version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE comments ADD COLUMN outdated INTEGER NOT NULL DEFAULT 0 CHECK(outdated IN (0, 1));
ALTER TABLE comments ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1));
ALTER TABLE comments ADD COLUMN edited_at TEXT;
