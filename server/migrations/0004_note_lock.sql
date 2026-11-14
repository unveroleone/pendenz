-- A locked note asks for Face ID or Touch ID before the app shows its text. The flag says
-- nothing about who may read the row: an agent still gets a locked note, marked as one.
ALTER TABLE notes ADD COLUMN locked INTEGER NOT NULL DEFAULT 0 CHECK(locked IN (0, 1));
