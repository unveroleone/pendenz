-- A server belongs to one person, the owner. Their actor ID was "leo"; it is "owner" from here
-- on, in every table that points at it. The owner keeps the name they had, except on a server
-- that starts for the first time, where the name is "Owner" until set-owner-name changes it.
--
-- A migration runs in one transaction, where foreign keys cannot be switched off. They are
-- checked at its end instead: by then every row points at "owner".
PRAGMA defer_foreign_keys = ON;

UPDATE actors SET
    id = 'owner',
    name = CASE
        WHEN EXISTS (SELECT 1 FROM tokens) OR EXISTS (SELECT 1 FROM items)
            OR EXISTS (SELECT 1 FROM notes) OR EXISTS (SELECT 1 FROM projects)
            OR EXISTS (SELECT 1 FROM activity)
        THEN name
        ELSE 'Owner'
    END
WHERE id = 'leo';

UPDATE items SET created_by = 'owner' WHERE created_by = 'leo';
UPDATE items SET updated_by = 'owner' WHERE updated_by = 'leo';
UPDATE comments SET author_id = 'owner' WHERE author_id = 'leo';
UPDATE notes SET created_by = 'owner' WHERE created_by = 'leo';
UPDATE notes SET updated_by = 'owner' WHERE updated_by = 'leo';
UPDATE tokens SET actor_id = 'owner' WHERE actor_id = 'leo';
UPDATE idempotency SET actor_id = 'owner' WHERE actor_id = 'leo';

-- The activity log is append-only. Its guard is lifted for this one change and put back as it
-- was. The JSON in detail keeps the old ID where an event named an actor: it is history.
DROP TRIGGER activity_no_update;
UPDATE activity SET actor_id = 'owner' WHERE actor_id = 'leo';
CREATE TRIGGER activity_no_update BEFORE UPDATE ON activity BEGIN SELECT RAISE(ABORT, 'Activity is append-only'); END;

-- The first migration added agents for one particular setup. A new server starts without them;
-- one that has used an agent keeps it. add-agent makes them again where they are wanted.
DELETE FROM actors
WHERE id IN ('hermes', 'claude-code', 'dispatcher', 'telegram-bridge')
    AND NOT EXISTS (SELECT 1 FROM tokens WHERE actor_id = actors.id)
    AND NOT EXISTS (SELECT 1 FROM items WHERE created_by = actors.id OR updated_by = actors.id)
    AND NOT EXISTS (SELECT 1 FROM notes WHERE created_by = actors.id OR updated_by = actors.id)
    AND NOT EXISTS (SELECT 1 FROM comments WHERE author_id = actors.id)
    AND NOT EXISTS (SELECT 1 FROM activity WHERE actor_id = actors.id)
    AND NOT EXISTS (SELECT 1 FROM idempotency WHERE actor_id = actors.id);
