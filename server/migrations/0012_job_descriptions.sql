-- A line the owner writes about what an agent's scheduled job does, shown when the job is opened
-- on the Agents screen. Kept by the job's name as the agent's report gives it, so a job that is
-- made again under the same name keeps its line. Like a report it is not item data: not in the
-- activity log, the changes feed or a push.
CREATE TABLE job_descriptions (
    actor_id TEXT NOT NULL REFERENCES actors(id),
    job TEXT NOT NULL,
    text TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (actor_id, job)
);
