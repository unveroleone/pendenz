# How Pendenz works

This document explains how Pendenz is built and why. It is for people who host their own server and for people who want to change the code. How to run a server is in [self-hosting.md](self-hosting.md).

## The parts

Pendenz has four parts:

- **The server** ([`server/`](../server)): Rust with Axum, and one SQLite database through sqlx. It holds every item, note and project, and it is the only place that decides who may see what.
- **The apps** ([`apple/`](../apple)): one SwiftUI project for iPhone, iPad and a native Mac app (not Catalyst), plus a widget extension. They keep a local copy of the data and work without a connection.
- **The agent tools** ([`server/src/agent/`](../server/src/agent)): part of the same Rust binary. A hosted MCP endpoint at `/mcp`, an MCP server over stdio (`pendenz mcp`) and a CLI. All three reach the data only through the API, with the agent's own token.
- **The push relay** ([`relay/`](../relay)): a Cloudflare Worker that holds the APNs key and can send one thing, a silent "sync now" push.

```
  iPhone, iPad, Mac app          Siri, Shortcuts, widgets
            \                        /
             \                      /
          Pendenz server (Rust, SQLite)  ----> push relay ----> APNs
             /                      \
            /                        \
   MCP server (stdio or hosted)     CLI
            |                        |
          an agent               scripts, cron jobs
```

The apps and the agents use the same HTTP API under `/api`. There is no separate API for agents: an agent is an identity with its own token, and the server treats it differently in a few places described below.

## The item model

### One kind of item

There is one kind of item. A task, a to-do and a reminder are the same row. A reminder is an item with a date. That item shows in Reminders and in its project or the inbox, at the same time.

The reason is that people do not sort their life into tasks and reminders. "Renew the passport" is a task until it has a date, and then it is also a reminder. With two kinds of row, every item would need a decision at capture and a migration later.

An item has a title (up to 240 characters), a description in markdown (up to 20,000), a status (`todo`, `doing`, `done`), a priority from 0 to 4, tags, a checklist, an optional project, a due date, a reminder time, a repeat rule, a manual position and an optional source URL. The fields as stored are in [`0001_init.sql`](../server/migrations/0001_init.sql).

The checklist is a list of lines inside the item, each with an ID, a text and a tick. It is stored on the item row and synced with it. There are no nested subtasks, because a list inside a list turns a capture tool into a project planner.

### Dates and reminders

- `due_at` is either a day (`2026-11-13`) or a local time with its offset (`2026-11-13T09:00:00+01:00`). `due_tz` is the IANA zone the time belongs to. It defaults to the server's zone (`PENDENZ_TIMEZONE`). Input without an offset is read as local time in that zone.
- A time in the hour that is skipped in spring moves one hour forward. A time in the hour that repeats in autumn means the first of the two.
- An item reminds at `remind_at`, or at `due_at` when that has a time. A day-only item without `remind_at` does not remind.
- So a thing with a real deadline gets the deadline as its due time and the moment to start as its reminder.

The server also stores both instants in UTC (`due_utc`, `remind_utc`), only for sorting and range queries. Clients never send them.

### Repeating items

A repeating item is one row. `repeat_rule` is a subset of RFC 5545: `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `BYDAY` for weekly rules and `BYMONTHDAY` for monthly ones. A monthly rule remembers its day, so the 31st comes back to the 31st after a short month. The code is in [`repeat.rs`](../server/src/repeat.rs).

A repeating item is never done. Setting it to done moves `due_at` to the first occurrence after now, moves `remind_at` by the same number of days, unticks the checklist and leaves the item open. Only the server works this out. If each device created the next copy itself, two devices could both create one.

### The inbox and projects

An item without a project is in the inbox, with or without a date. A project groups items and notes. It has a name and an optional icon, which is the name of a symbol. The server does not know the symbols; the app offers a fixed set. Projects have no color, because the app keeps color for state (see "App architecture").

Project IDs are readable slugs made from the name, such as `home-lab`. A client may send its own ID, so a project made without a connection keeps the ID its items were already filed under. Names are unique without regard to case.

The inbox and each project have a manual order through `position` on the item, highest first. A new item gets its sequence number as its position, so it lands on top. A client that reorders sends a number between the two new neighbours.

### Notes versus items

A note is context. An item is something to do. Notes do not have a status, a date or a reminder, and agents do not pick up work from them.

A note is a plain markdown text of up to 100,000 characters, stored as typed (only `\r\n` becomes `\n`). It has no title field: the first line is the title. It can belong to a project, be pinned, be hidden from agents and be locked. There are no folders and no rich text. The app shows the markdown as typed and does not render it.

A note can be turned into an item in the app, as a whole or from selected text. The first line is read the way quick add reads it and becomes the title.

### Done, archive and trash

These are three different things, and none of them deletes anything:

- **Done** means finished. Completed items are listed in Completed in the app.
- **Archived** means the owner decided not to do it.
- **Trashed** is for mistakes and duplicates. Everything in the trash can be put back.

Nothing is deleted for good and the trash is never emptied. The server keeps trashed rows, so a device that was offline for weeks still learns that a row went to the trash. Files on items are the exception, see "Files".

## The server

### Data model

| Table | Holds |
|---|---|
| `items` | Items, with the checklist, tags and file list as JSON columns |
| `comments` | Progress notes on an item, mostly from agents, including deleted ones (`deleted = 1`) |
| `notes` | Notes |
| `projects` | Projects, including deleted ones (`deleted = 1`) |
| `item_files` | The bytes of files, pictures among them, one row per file |
| `server_settings` | One row: the settings the owner changes in the app (the largest file, the price of a kWh) |
| `activity` | The append-only history of every change |
| `actors` | The owner and the agents |
| `tokens` | Hashed bearer tokens with their scopes, and the device a token belongs to |
| `devices`, `pairing_codes` | Paired devices and one-time codes |
| `push_tokens` | The APNs token of each paired device |
| `idempotency` | Which row each idempotency key wrote |
| `meta` | The one sequence counter |

`activity` has triggers that refuse every update and delete. Every edit writes a row there with the values from before, so a later edit never loses what an earlier one wrote. For a note's text that means the whole text from before.

A migration that is committed is never edited again. sqlx compares each file's hash with the one stored in the database, and a server with an edited migration does not start on an existing database. Every schema change is a new file in [`server/migrations/`](../server/migrations). SQLite runs a migration in one transaction, where foreign keys cannot be switched off; [`0002_project_delete.sql`](../server/migrations/0002_project_delete.sql) shows how a table that others point at is made again with `PRAGMA defer_foreign_keys = ON`.

### One writer

Every write to an item, comment, project, file or note goes through `write` in [`items.rs`](../server/src/items.rs):

1. It checks the `write` scope and reads the `Idempotency-Key` header.
2. It takes one process-wide writer lock.
3. It opens a `BEGIN IMMEDIATE` transaction, which takes SQLite's write lock at the start. A deferred transaction that reads first can fail with "database is locked" when another connection writes before it.
4. It checks the key, does the write, records the key and commits.
5. After the commit it wakes the push sender.

One writer at a time is plenty for one person and a few agents, and it removes a whole class of races. SQLite runs in WAL mode, so reads do not wait for the writer.

The device and push token routes ([`devices.rs`](../server/src/devices.rs), [`push.rs`](../server/src/push.rs)) are the exception: they take the writer lock and `BEGIN IMMEDIATE` themselves and use no idempotency key.

### Idempotency keys

Every write needs an `Idempotency-Key` of 1 to 128 characters. The server stores, per identity, the key, a fingerprint of the request (method, path and body) and which row it wrote. A retry with the same key and the same request returns that row as it is now, without writing again. The same key with a different request is refused.

The server stores no copy of the response. A retry reads the row again through the same visibility check as any read, so an item that was hidden in the meantime answers 404 to an agent that retries. Keys count per identity, not per token, and are kept for 30 days.

The reason for keys on every write is the outbox in the app and agents on unreliable connections: a request whose answer was lost can be sent again safely.

### Versions and conflicts

Items and notes have a `version`. An update must send the version it read, and an old version gets 409. The server does not merge. The client reads the row again and decides.

The app applies its change on top of the new row and sends it again (see "Sync in the app"), so in effect the later edit wins per field, and the activity log keeps the value it replaced. With one person on a few devices, real conflicts are rare.

Two writes take no version on purpose:

- `PATCH /api/notes/<id>` with `{"append": "text"}` adds text at the end of the note inside the write transaction. An agent that adds to a note uses this, so it cannot overwrite what the owner typed in between.
- Projects have no version. The later edit wins.

### The changes feed

Every write takes the next number from one counter in `meta` and stores it as the row's `seq`. `GET /api/changes?cursor=<n>&limit=<m>` returns items, comments, projects and notes whose `seq` is above the cursor, oldest first, with `has_more` and the next cursor. A row appears once, in its current state, at the number of its latest write. Trashed and archived rows are included. The code is in [`changes.rs`](../server/src/changes.rs).

This one endpoint serves the apps and agents. A client stores the cursor and asks again. There are no tombstones: a deleted project is a row with `deleted: true`, and a trashed item is a row with `trashed: true`.

If the server was restored from a backup and its counter is behind the client's cursor, the answer is `reset: true` with cursor 0, and the client starts from the beginning.

`GET /api/reminders?after=<time>` is a second, smaller feed for scripts that send reminders themselves: the open items whose reminder time lies between `after` and now, and the `until` value to send next time. The server keeps no "sent" state.

### Hidden from agents

Any item or note can be hidden from agents with `hidden_from_agents`. For an agent token a hidden row does not exist: it is missing from lists, the changes feed and reminders, and reads and writes answer 404. Comments on a hidden item are left out too.

Only the owner's tokens can set or clear the flag. An agent that sends the field at all gets 403. Hiding a row later only stops future reads; what an agent already read stays wherever it put it.

The rule lives in one place per kind: `visible_item` in [`items.rs`](../server/src/items.rs), `visible_note` in [`notes.rs`](../server/src/notes.rs), and the same SQL condition `(? OR hidden_from_agents = 0)` in the list and feed queries. A new route that reads or writes an item or note has to go through one of these.

This flag is the one barrier between agents and private data. The model provider of an agent sees everything the agent reads, so the owner needs a way to keep a row away from it.

### Locked notes

A note can be locked (`locked`). The lock is not an access rule: `visible_note` and the hidden filter do not look at it. It does two things:

- The app keeps locked notes out of the Notes list and its search, in Locked Notes, the first row of Notes. Going in asks for Face ID or Touch ID once, and the notes in there open without another question. Leaving the app closes the lock, and with it Locked Notes. A note that is locked or unlocked while it is open stays open and takes the window to its side. Spotlight and Shortcuts still find a locked note by its title, and open it in Locked Notes after the same question.
- An agent still reads the note, marked `locked: true`, and the tool instructions tell it to use the text only for the task at hand and never to save or copy it.

Anyone may lock a note, agents included, because an agent knows when it writes something private. Only the owner's tokens can remove a lock (`guard_unlock` in [`notes.rs`](../server/src/notes.rs)); an agent whose write would unlock gets 403. An agent can still edit and append to a locked note, and the lock stays.

The lock is a gate in the app, not encryption. The text sits in the database, the backups and every device's local store like any other note. A note that agents must not read should be hidden instead.

### Comments

A comment is a progress note on an item: a question, a plan, a result. Agents write most of them. A plan goes out of date, and an agent that reads its own old plan back takes it for the current one. So a comment can be edited, marked outdated and deleted. The code is in [`comments.rs`](../server/src/comments.rs).

- `POST /api/items/<id>/comments` takes `{"body"}`, 1 to 10,000 characters.
- `PATCH /api/items/<id>/comments/<comment>` takes the comment's `version` and `body`, `outdated` or both. A changed text sets `edited_at`. A stale version answers 409, like an item.
- `DELETE /api/items/<id>/comments/<comment>` takes no fields. The row stays with `deleted: true` and an empty body, because the changes feed has no tombstones: that row is how the apps learn the comment is gone. `GET /api/items/<id>` leaves deleted comments out and lists the rest oldest first.

The author owns a comment. An agent may change and delete only the comments its own actor wrote; one of another actor's answers 403. The owner's tokens may change any comment, since the owner decides what holds on their own list. This is the one place where an agent's write depends on who wrote the row: an item can be edited by any agent that sees it (see "Kept simple on purpose").

The routes work like the file routes: they check the item with the hidden filter and look the comment up by its ID and the item's ID together, and a trashed item takes no change to its comments. The activity log records `comment_updated` with the comment's ID, whether the text changed and the new `outdated` value, and `comment_deleted` with the ID. It never holds the text, so a deleted comment leaves no text on the server, apart from the backups made before. Copies that a device or an agent already read stay where they are.

`outdated` marks a comment that no longer holds. Nothing is hidden: `get_item` puts a `notice` next to it that tells the agent not to rely on it, and the app shows it dimmed with an "Outdated" label.

In the app, the comments are a section of the item detail ([`ItemCommentsSection.swift`](../apple/Pendenz/Views/ItemCommentsSection.swift)), there only when the item has any. It shows the latest comment, and a row above it opens the earlier ones, so the order stays oldest first without a long list on every item. A comment shows its author ("You" for the owner, an agent by its name) and its time, and a long text shows six lines until it is tapped. A long press or a right click copies, edits, marks as outdated or deletes it; on the iPhone and iPad a swipe does the same. The app does not add comments yet.

The app keeps the comments it gets from the changes feed on disk and removes a deleted one there. Their authors' names come from `GET /api/bootstrap`, asked once per launch for an author ID the device does not know yet, and are kept per server. Edits and deletions go through the outbox like every other change; a 409 reads the item's comments again (`GET /api/items/<id>`) and sends the change on top of them.

### Files

An item can carry up to 40 files of any kind, pictures among them, kept byte for byte under their name. The metadata (`id`, `name`, `mime`, `bytes`, `sha256`, `upload_id`, and `width` and `height` for a picture) is a JSON list on the item row, the only copy, so every read of an item carries it without a join. No PATCH can write it. The bytes are in `item_files` in the same database, so the backup stays one file. The code is in [`files.rs`](../server/src/files.rs).

- `POST /api/items/<id>/files` takes the file itself as the body, not JSON: base64 would make it a third larger and hold it twice. The type is the `Content-Type` (anything that is not a plain `type/subtype` is stored as `application/octet-stream`), the name comes percent-encoded in `Pendenz-File-Name`, and `Pendenz-Upload-Id` is an optional name of the sender's own for this upload. A name with a slash, a backslash or a control character, `.`, `..` or more than 255 bytes is refused.
- The body is read and hashed before the writer lock, which is never held while bytes still arrive, and at most two uploads are read into memory at once. The upload route of 0.2.0 counts against the same two, because its JSON body is read before its handler runs. Then it goes through the same writer as every other change (`items::commit`). The fingerprint covers the hash, the name, the type and the upload ID.
- A JPEG, PNG, GIF, WebP or HEIF file gets its `width` and `height`, read from its first bytes whatever the sender calls it. That is what makes it a picture, which the app shows as a thumbnail. One with more than 40 million pixels stays a file without a size, because whoever draws it would need the memory.
- A retry with a used key is answered before the size is checked. A limit lowered between an upload and its retry must not refuse a file the server already holds. Only a new upload is checked, against the limit as it is inside the transaction.
- The upload ID tells the app which file its upload became. The hash cannot: the same bytes can be on an item twice, and the app removes the file of an upload that was taken back while it was on its way.
- `GET /api/items/<id>/files/<file>` returns the bytes with the stored type as a download (`Content-Disposition: attachment`), with `nosniff` and `Content-Security-Policy: sandbox`, so a web page among the files is never run in a browser. It works for a trashed item too. At most four downloads hold a file in memory at once. The permit belongs to the file's bytes and goes with the last of them, after it is sent or the client goes away, so many slow readers cannot fill the memory.
- `DELETE /api/items/<id>/files/<file>` removes the file for good. Backups made before keep it. A trashed item takes no new file and loses none.

All three check the item with the hidden filter and look the file up by its ID and the item's ID together. A file must never be found by its ID alone, or an agent could reach the file of a hidden item through an item it may see.

The app scales a photo (from the library, the camera, the clipboard or a dropped picture) to 2048 pixels on its long side and writes it as JPEG before it is queued. That also drops the EXIF data, so no location reaches the server or an agent. A chosen file is kept as it is, even when it is a picture. The Attachments section shows the pictures as thumbnails, then the other files, then one menu to add either. A list row marks both with one paperclip.

Images and files were two lists until 0.3.0 (`items.images` and `item_images` beside the files). Migration [`0008_merge_attachments.sql`](../server/migrations/0008_merge_attachments.sql) made one list of them: the images kept their IDs and became files named `Image.jpg` or `Image.png`, and the files moved up by the highest image ID ever given, so no two share an ID.

The apps of 0.2.0 knew images only. For them an item still lists its JPEG and PNG pictures under `images`, in the old shape, and the old routes stay in [`images.rs`](../server/src/images.rs): `POST /api/items/<id>/images` with `{"mime", "data"}` in base64 (JPEG or PNG, at most 5 MB and 40 megapixels, with a body limit of 8 MB where every other JSON route has 1 MB) stores a file, and `GET` and `DELETE /api/items/<id>/images/<image>` reach only the pictures among the files. Agents get no `images` list. The list and the routes go together once no 0.2.0 app is left.

### Settings

`GET /api/settings` answers `{"file_limit_mb", "file_limit_ceiling_mb", "energy_price_chf"}`. Every page of the changes feed and the bootstrap carry the same object, so a device learns a new limit with its next sync. `energy_price_chf` is the price of a kWh in Swiss francs for the cost of a machine's energy on the Agents screen, null until set; the key is always there, so the app offers the field only on a server that has it. `PATCH /api/settings` with `{"file_limit_mb": n}`, `{"energy_price_chf": x}` (0 to 100, or null to clear) or both is for the owner's devices only, like the device routes: it takes the writer lock and `BEGIN IMMEDIATE` itself, needs no idempotency key because it sets a value, records the change in the activity log and wakes the push sender.

The largest file is 1 to 100 MB, 25 MB by default, counted in megabytes of a million bytes as the apps show sizes. The ceiling of 100 MB is fixed in the server: it is the body limit of the upload route, and a Cloudflare Tunnel refuses larger bodies anyway. A lower limit counts for files added from then on; files already attached stay.

### Deleting a project

`DELETE /api/projects/<id>` moves every item and note of the project to the inbox in the same transaction, each with a write of its own (a new version and sequence number), so the changes feed tells every client. That includes done, archived, trashed and hidden rows. The agent that deletes gets the project's row back and nothing about the hidden rows.

The project's row stays with `deleted: true`. Its name is free again, but its ID is never given to a new project: a new "Home" after a deleted `home` is `home-2`. So a change that an offline device still has queued for the old project cannot land in a new one. A later write that names the deleted project is not refused: the row lands in the inbox (`settle_project`). Every SQL query that lists or checks projects adds `AND deleted = 0`.

## Identities

### The owner and agents

A server belongs to one person, the owner. Their actor ID is `owner` (`auth::OWNER`). Every paired device and the server's command line act as the owner. Every other actor is an agent, made with `pendenz add-agent --id <id> --name <name>`.

Agents get their own identity and tokens so the activity log and `created_by`/`updated_by` show who wrote what. Separate tokens are for attribution, not for fine-grained limits. The server tells the two kinds apart by `actors.kind` (`human` or `agent`), and that is what the hidden filter and the lock checks look at.

### Tokens and scopes

Tokens are `pdz_` plus 64 hex characters, stored as a SHA-256 hash. They are issued with `pendenz issue-token --actor <id> --label <text> --scopes <list> [--days <n>]`, listed with `list-tokens` and revoked with `revoke-token`.

| Scope | Allows |
|---|---|
| `read` | Lists, details, the changes feed, files, the settings |
| `write` | Every write that goes through `write` |
| `propose` | Reserved; nothing uses it yet |
| `approve` | Device routes: pairing codes, the device list, revoking; changing the settings |
| `telegram` | Only for the identity `telegram-bridge`, which gets no other scope. Items it adds are marked as captured through Telegram |
| `report` | Sending the agent's own status report (`PUT /api/agents/me/report`), and nothing else |

A token without `read` gets only a receipt from a write (the ID and version), never the stored row. This is for capture-only tokens, such as a shortcut that adds items: it can write, also with the hide flag, but cannot read anything back.

### Device pairing

A new device is paired with a one-time code:

- A code is ten characters in two groups, such as `48TQY-AA7ZA`, from 30 letters and digits that are not mistaken for each other. That is about 49 bits. It works once, for ten minutes, and is stored as a hash. Input is read without the hyphen, spaces and case.
- The first code comes from `pendenz pairing-code` on the server. A paired device makes the next one with `POST /api/pairing-codes`.
- `POST /api/pair` takes `{"code", "name"}`, uses the code up and answers once with the device's token: the owner's identity with the scopes `read`, `write`, `propose` and `approve`, without an expiry. It is the only API route without a token, added to the router after the auth layer on purpose.
- `GET /api/devices` lists the devices with their last use, and `DELETE /api/devices/<id>` revokes one. Revoking removes its push token and the unused codes it created.

The device routes, `PATCH /api/settings` and `PUT /api/agents/<id>/job-description` need a human token with `approve` (`require_owner`). Nothing else in the API needs `approve` today.

### Connecting an agent

An agent can be connected from the app, the way a device is paired. `POST /api/agent-codes` (owner with `approve`) makes a one-time code with a name and the scopes: `report` alone, or `report`, `read` and `write`. `POST /api/agent-codes/redeem` takes the code without a token, uses it up and creates the agent and its token in the same transaction, like `/api/pair`. The code is stored as a hash, works once and for ten minutes. The scopes come from the code, never from the agent, and are filtered to those an agent may hold. A lost answer leaves an agent without a working token: the owner revokes it and makes a new code.

`DELETE /api/agents/<id>` (owner with `approve`) revokes every token of an agent and removes its report and the lines about its jobs. The actor stays, so the activity log and the rows it wrote still name it.

### What agents can never do

These hold in the server, not in the tool instructions:

- See, read or write a hidden item or note, or its comments and files.
- Change or delete a comment that another actor wrote.
- Set or clear `hidden_from_agents`.
- Remove the lock of a note.
- Get the `approve` scope. `issue-token` refuses it for an agent.
- Make pairing codes, list or revoke devices, register a push token, or change the largest file size.

Everything else the app can do with items, notes and projects, an agent can do too: create, edit, complete, reorder, comment and change its own comments, add and remove files, make, rename and delete projects, write and append to notes.

### Local mode

`PENDENZ_AUTH_MODE=token` is the normal mode. `local` is for development: it starts only on a loopback address, refuses requests whose `Host` is not a loopback name, and treats a request without a token as the owner. Never expose it.

## Sync in the app

### Local store

Every screen reads from one `Store` in memory, never from a request of its own ([`Store.swift`](../apple/Pendenz/Model/Store.swift)). The store is filled from disk at launch, so the lists are there before the server answers.

On disk ([`LocalStore.swift`](../apple/Pendenz/Model/LocalStore.swift), SwiftData) are all rows the server has sent, each as JSON with plain keys, the cursor and the outbox. The API uses snake case keys; the disk encoder has no key strategy, because names such as `itemID` do not survive the round trip. The rows belong to one server address. With another address the rows and the outbox are deleted.

The store has a format number. A build that needs something new from the stored rows raises it and makes one pass over them at launch, or drops them and loads everything again from cursor 0.

### Outbox

A change made in the app goes into the outbox (`enqueue`), shows at once and is sent in the order it was made, with one idempotency key for all its retries. What the screens show is the server's rows with the outbox laid over them. Nothing else in the app writes to the API directly, so every change also works without a connection; the device routes and the largest file are the exceptions (see "Session and store"). A file waits for its upload as a copy in `Application Support/WaitingFiles`, made before its outbox entry and sent from the disk, so a large file is never read into memory. Copies of the server's files lie in `Caches/Files` under their SHA-256, checked against it after the download.

A sync sends the outbox first, then pages through `GET /api/changes`. A row only replaces one with a lower `seq`. It runs at launch, when the app comes to the front, after a silent push, on pull to refresh and after every change made in the app. While the server cannot be reached the outbox waits and tries again every 20 seconds.

Answers are handled like this:

- **400, 404 or 405 with the API's own error text from a server older than the app needs**: the change waits for the server's update (see below).
- **409**: the app reads the row again and sends the same change on top of it with a new key, up to three times in one sync. After that the change waits for the next sync.
- **404**: dropped without a message; the row is gone.
- **Any other 4xx with the API's own error text** (400, 403, ...): the change is refused for good, dropped and named in a message.
- **401**: the device was revoked. The app drops the token and shows the pairing screen.
- A 4xx without the API's error text came from something in between (a proxy, a wrong address) and leaves the change in the outbox.

### An app newer than its server

The Mac app updates itself, so an app can be newer than the server it is paired with. Every answer of the server names its version in the header `Pendenz-Version`; a server from before the header counts as 0.1.0. The app knows the oldest server it works with (`ServerVersion.minimum`), raised whenever the app starts to send a route, a method or a field that an older server does not know. Versions are ordered as in semantic versioning, so a release candidate comes before its release.

An older server answers what it does not know with 404 (a route), 405 (a method) or 400 (a field). From a server below the minimum such an answer to a write does not count as a refusal: the change is marked held (`heldFor`, kept on disk) and the outbox goes on with the changes that do not depend on it. Depending means the same item or note, a new or moved item or note filed into a project whose change waits, and any change to a project, because project names are unique across projects. A held change keeps its key, its place and its file.

When a sync sees a server at or above the minimum, the marks are cleared and the waiting changes go out in their old order in one more pass of the same sync. One that is refused then is handled like any other refusal. Until then the Tasks list and Settings say which version the server runs, which one the app needs and how many changes wait. Nothing in the app is hidden, and a proxy in front of the server has to pass the header on.

The decision rests on the refusing answer's own header, not on a version seen earlier, because a server can be restored or rolled back. Agents and the CLI have no outbox and see the server's refusal as it is.

### Local IDs

An item or note added without a connection gets an ID below zero until the server answers. A local ID is never reused within a launch: `serverIDs` and `noteServerIDs` keep leading the old ID to the row it became, so a change queued against the local ID reaches the right row. A file added to such an item follows it to its server ID.

Anything that may outlive the launch only uses IDs above zero: widget rows, Shortcuts entities, notification actions. A local ID means another row after the next launch.

Projects have no local ID. The app makes the ID from the name (`Project.makeID`) and sends it along, and never reuses the ID of a deleted project (`usedProjectIDs`).

### Reminders as local notifications

Reminders are local notifications that the app schedules from synced data ([`Reminders.swift`](../apple/Pendenz/Model/Reminders.swift)). They fire without a network and when the server is down. The server has no scheduler and sends no alerts.

- The app schedules the nearest 60 reminders (iOS keeps 64 per app) and works out the difference whenever the items change and when it comes to the front.
- A notification counts the seconds to its moment, so a change of time zone on the device does not move it.
- Under the item's title a notification shows the due date and the project, then the start of the description as plain text, line by line ([`ReminderText.swift`](../apple/Pendenz/Model/ReminderText.swift)). The due date is worded for the moment the notification fires: a reminder set for the evening before says "Due tomorrow, 18:00". One that stays on the lock screen keeps that wording, next to the time the system prints for its arrival. An edit of anything it shows replaces a waiting notification.
- It removes a notification already shown when its item was completed or its reminder moved, but only once a sync in this launch has brought the store up to date (`isCurrent`). Before that, an item may only be missing because its rows are still loading.
- A notification has the actions Done, In 1 Hour and Tomorrow. They go through the outbox like any change, so they reach the other devices. `Session` carries them out, not a view, because the system may start the app in the background for an action.

### Push through the relay

After a change the server asks the app on every other paired device to sync. The push carries no text, shows nothing and needs no permission. The app syncs and works out its reminders again. That way a reminder made on another device or by an agent gets scheduled on a closed iPhone, a notification for an item completed elsewhere leaves the lock screen, and the lists are current when the app opens.

On the server ([`push.rs`](../server/src/push.rs)):

- A device registers its APNs token with `PUT /api/push-token`, with the environment (`sandbox` for a development build, `production` otherwise).
- One sender task. `write` wakes it after a commit, not for a retry that wrote nothing. It collects changes for 2 seconds, sends to every device with a push token, and then waits 20 seconds before the next push. A device is left out only when every change of the round came from it.
- `PENDENZ_PUSH_RELAY` names the relay and `PENDENZ_PUSH_RELAY_KEY` its secret. Without the first the server sends nothing and still stores the tokens.
- A token the relay reports as `gone` or `invalid` is removed, but only the registration that was sent, so a late answer about an old registration cannot remove a newer one.
- A failed request to the relay is logged and not retried. The next change sends a push, and the app syncs when it comes to the front anyway.

The relay ([`relay/src/index.js`](../relay/src/index.js)) takes `POST /v1/push` with `{"kind": "sync", "devices": [{"token", "environment"}]}`, up to 16 devices. For each it sends APNs a background push with priority 5, the collapse ID `sync`, kept for an hour, and the body `{"aps":{"content-available":1}}`. It answers one word per device: `sent`, `gone`, `invalid`, `limited` or `failed`. It signs the APNs provider token with WebCrypto and keeps it for 45 minutes. It stores nothing and logs no device token. It has rate limits per device token and per caller address, and while `RELAY_SECRET` is set it accepts only callers that send it.

Silent pushes are best effort. iOS allows a few an hour, delays them in Low Power Mode, and delivers none to an app the user swiped away. On the Mac they can be held for many minutes. A reminder made a few minutes before it is due can still arrive late.

### Why a relay

An APNs key belongs to the Apple developer team that publishes the app. A self-hosted server cannot have it, and it should not: the key could push to every installation. So the key lives in a relay, and the server names devices to it.

The relay is built so it cannot leak anything. The caller chooses neither the payload nor the topic, so the relay can only ever say "sync now", and it never sees an item, a note or a title. The app then fetches the data from the server it is paired with, over that server's own TLS connection.

The relay for the published app is not open to other servers yet. Until it is, a self-hosted server runs without `PENDENZ_PUSH_RELAY`, and the apps sync at launch and when they come to the front. Reminders still work, because they are local. Someone who builds the app under their own bundle ID and Apple team can deploy `relay/` with their own key and point their server at it.

## The agent interface

### MCP tools

The tools are defined once, with their descriptions and input schemas in [`tools.json`](../server/src/agent/tools.json) and the server instructions in [`instructions.txt`](../server/src/agent/instructions.txt), and carried out in [`tools.rs`](../server/src/agent/tools.rs). They are served two ways: over stdio (`pendenz mcp`, [`stdio.rs`](../server/src/agent/stdio.rs)), running next to the agent, and as a hosted stateless endpoint (`POST /mcp`, [`hosted.rs`](../server/src/agent/hosted.rs)) that takes the caller's own Pendenz token. A token only gets the tools its scopes allow.

The hosted endpoint runs in the API's process, but it does not touch the database for the tools. Each call goes through the API router in process, with the caller's token, so it passes the same authentication, scope checks, hidden filter and idempotency as a request from outside. Only the token check at the door reads the token store directly. The stdio server and the CLI call the API over HTTPS. This keeps one place that decides what a token may see.

The protocol is the official Rust SDK's, [rmcp](https://crates.io/crates/rmcp) ([`server.rs`](../server/src/agent/server.rs)). It handles the `initialize` handshake of the versions up to `2025-11-25` and the per-request flow of `2026-07-28` (no handshake, `server/discover`, the method in a header), stdio framing and stateless Streamable HTTP with JSON answers. Pendenz keeps three things of its own in front of and behind it: the door of the hosted endpoint (host, origin, rate and concurrency limits, the token check and the body size, in `hosted.rs`), the tool definitions in `tools.json`, which are served as they are written, and the argument checks in `schema.rs`, which fill in defaults and trim text before a tool runs. The first version of the tools ran on Node with the official TypeScript SDK; the regression tests in `server/tests/` were recorded from it and hold every tool to the same answers.

The door checks the token before it counts anything. The rate limit is then 180 requests a minute per token, with at most 32 requests served at once. A request without a valid token costs one lookup, as it does on `/api`, and is never counted, so it cannot use up an agent's budget. The endpoint trusts no header that names the client's address, so it works the same behind Cloudflare, Caddy or any other proxy.

| Tool | Does | Scope |
|---|---|---|
| `workspace` | Who the agent is, its scopes, the time zone, the actors, the projects and the allowed values | read |
| `list_items`, `get_item` | Compact rows with a filter and a sort (`manual` adds positions); one item in full | read |
| `create_item`, `update_item` | Create, and edit with the version | write |
| `add_comment` | A progress note on an item | write |
| `update_comment`, `delete_comment` | Change the text of an own comment or mark it outdated; delete one | write |
| `get_item_file`, `remove_item_file` | Show a file to the model (text up to 1 MB, a picture up to 5 MB, otherwise its name, type and size); remove one | read, write |
| `add_item_file` | Attach a local file of any kind (stdio only) | write |
| `create_project`, `update_project`, `delete_project` | Make, rename, re-icon and delete a project | write |
| `search_notes`, `get_note` | Notes as title and preview; one note in full | read |
| `create_note`, `update_note`, `append_note` | Write a note; change it with its version; add to its end without one | write |
| `changes` | Items, comments and projects since a cursor | read |

Some choices in them:

- `changes` leaves notes out. Notes are context, not work to pick up, and they can be long. An agent finds them with `search_notes`.
- `list_items` and the write tools return compact rows with descriptions cut at 200 characters. `get_item` returns the full item with its comments, oldest first, and only the latest changes from its history (`activity`, 10 by default), because the history is the bulky part. An outdated comment carries a `notice` that it no longer holds.
- `add_item_file` exists only over stdio, where a path means a file next to the agent. The hosted server would have to fetch an address or take megabytes of base64 from a model.
- `get_item_file` reads the item's list first and fetches the bytes only for what it can show, so a large file is never pulled through the hosted endpoint.
- A locked note comes from `get_note` with a `notice` next to the text, and from the list tools with its title and no preview, as in the app.
- Every item has an `agent_stage` for the agent loop: `new` waits for triage, then `none`, `gathering`, `needs_answer`, `ready`, `running`, `review` or `declined`. An item the owner adds starts at `new`, one an agent adds at `none`. `update_item` (and `PATCH /api/items/<id>`) sets it for any token. When the owner changes the title or the description and sends no stage, the server puts the item back to `new`, unless it is `running` or `review`, so an agent finds what to triage with `list_items` and `stage: new` and needs no cursor of its own. The activity log records each change of stage. An agent closes an item itself when its work is done (status `done`, stage `none`) instead of leaving it for the owner, so the MCP tools no longer offer `review`; the API still accepts it, for items already there.
- Every write tool takes an optional `key`. An agent that retries after a timeout sends the same key and arguments, and the write cannot apply twice. Without one the adapter makes a fresh key per call.

The server instructions tell the agent how to write titles, dates and notes, how to handle versions and conflicts, and what a locked or hidden row means. They are part of the design: the lock rule for agents is an instruction, not a barrier.

### Status reports

An agent's machine sends a status report every two minutes with `pendenz report` (see [self-hosting.md](self-hosting.md#status-reports)). The server keeps the latest report per agent in `agent_reports` and nothing older: a report carries the history it shows, 30 days of usage and 24 hours of samples. The Agents screen in the app reads them from `GET /api/agents`, which only a human token with `read` may call, together with each agent's scopes, its last use and what it did today from the activity log.

- **Not item data.** A report is no write through `write`: it is not in the activity log, which would grow by a row every two minutes, not in the changes feed and not pushed. The route takes the writer lock itself and needs no idempotency key, since a repeat replaces the same row.
- **Checked and bounded.** The server parses the report into its own types, refuses unknown fields and other schema versions, cuts texts, lists and counts to fixed bounds, and stores what it parsed. A report older than the stored one does not replace it, and one dated more than five minutes ahead is refused.
- **Generic.** The report format knows agents, accounts, jobs, running sessions and a machine, not a particular agent. The sources for Hermes Agent and Claude Code live in the report command, and anything else can send a report file.
- **Money and limits apart.** An account is either paid per token, shown with its estimated cost, or a plan, shown with its limit windows and tokens and never with money. Hermes keeps running totals per session, so the report command remembers the totals it saw last and counts what grew since on the day it grew.
- **The collector follows the server.** The scheduled report job updates its own binary to the release the server names in `Pendenz-Version`, after the report and never past that version, so a collector cannot send fields its server refuses. The download is trusted as `install.sh` trusts it: the release on GitHub over TLS and the release's `SHA256SUMS`. A bad release spreads to agent machines once the servers run it; `--no-update` on the job stops that.
- **What a job does.** Opening a job on the Agents screen shows one line about it. The owner writes it in the app (`PUT /api/agents/<id>/job-description`, owner with `approve`, kept in `job_descriptions` by agent and job name, given with each agent in `GET /api/agents` as `job_descriptions`, a list of `{job, text}`), or with `pendenz set-job-description` on the server. Until then the app shows the first sentence of the description of the skill the job runs, which the collector sends as the job's `skill_summary`. Never the job's prompt: a report carries no prompt text. A line is kept by the job's name, so a job made again under the same name keeps it; the route refuses an agent without a working token, so a line cannot come back after a revoke. Like a report, a line is not item data.
- **Energy.** A Mac can send its energy and CPU temperature with the machine (`host.energy`): this month and the last in kWh with the hours measured and the highest and median temperature, the machine's current month (`this_month`, so the apps never guess it in their own calendar), and the last minute's watts and temperature, each with its time. A month with temperatures but no power readings has no kWh. The collector adds them up, not the server: the energy sampler (`pendenz report energy`, a LaunchAgent from `report install --energy`) reads the System Management Controller every five seconds without root and keeps a day's totals and a histogram of temperatures, and the report sends the months. That keeps "a report carries the history it shows": no samples reach the server, and no table grows. `powermetrics` was not used: on Apple silicon it needs root, has no temperatures and estimates only the CPU, GPU and Neural Engine. The cost is the energy at today's price (`energy_price_chf` in the settings), worked out in the app.
- **Freshness.** The app shows a report as stale after ten minutes on the server's clock, so a machine that stopped sending is told apart from an agent whose gateway is down, which the report itself says.

### CLI

The `pendenz` binary has the same calls as the tools ([`cli.rs`](../server/src/agent/cli.rs): `list`, `get`, `create`, `update`, `comment`, `comment-update`, `comment-delete`, `add-file`, `get-file`, `notes`, `note-append`, `project-delete`, `changes` and so on) plus `reminders` for scripts. It reads `PENDENZ_API_URL` and `PENDENZ_API_TOKEN`, prints JSON and needs no database. A new tool goes into `tools.json` and `tools.rs`, with the same call in `cli.rs` and steps in `server/tests/agent.rs`.

## App architecture

### Session and store

`Session` ([`Session.swift`](../apple/Pendenz/Model/Session.swift)) owns the pairing and the `Store`. No pairing means no store, and the app shows the pairing screen. The server address, the token and the device ID are one Keychain entry, readable after the first unlock and never part of a backup or iCloud. The app follows no redirect, so the token never goes to another host, and it takes only `https`, except for a server on the same device.

Only `Session` and Settings talk to the device routes and the settings route. The device list and the largest file are the two screens that ask the server directly, because they mean nothing without a connection. The file slider sends its value when it is let go; without an answer it asks the server what it holds and shows that, so it never shows a limit the server does not have. The last limit the server confirmed is kept per server, and the app refuses a file over it before it is queued. Without a known limit the server decides.

Several system features start the app in the background with no window: a notification action, a widget tick, a Siri action, a silent push. So their handlers are set by `Session` in its `init` (`onAction`, `onPush`, `WidgetActions.complete`, `ControlActions.newItem`), never by a view. They schedule reminders before they sync, because the app may be ended right after the handler returns.

### Widgets

The widget extension ([`PendenzWidgets/`](../apple/PendenzWidgets)) holds no token and makes no request. It reads one file, `Widgets.json` in the app group's folder (`WidgetFile` in [`Shared/`](../apple/Shared)). The app writes it at the end of each store update and when an order changes, and asks the widgets to draw again only when the content changed, because reloads count against a daily budget. A widget is therefore as fresh as the app's last sync. The file is removed when the pairing ends.

The lock screen widget (`LockWidget`, iPhone and iPad only, since the Mac has no lock screen families) uses the list widget's setting and timeline, so both draw the same rows from the same file. It shows the count and the next items and has no tick: a tap opens the list.

The tick on a widget row is `CompleteItemIntent`, which runs in the app's process (`allowedExecutionTargets` is `.main`) and goes through the outbox. It carries the due date its row showed. For a repeating item the app syncs first and completes it only if that is still the item's date, because completing moves such an item on and a widget can be behind.

Code that both targets use lives in `apple/Shared/`.

### App Intents and Siri

The actions for Siri and Shortcuts are in [`Intents/`](../apple/Pendenz/Intents): Add Item, Add Note, Complete Item, Open List, Open Item, Open Note and Find Items. Add Item reads its title the way quick add does, so a date and `#project` in the text are understood.

- An action that reads rows takes the store from `Session.freshIntentStore()`, which syncs once for a few seconds when the launch has not synced yet.
- An action that changes something writes through the outbox and ends with `Session.settleIntent`, which waits for the server for at most eight seconds, so Siri does not hang on a slow connection.
- Entities offered to a picker have IDs above zero, because a shortcut may keep them.
- A note entity carries no text that Shortcuts can read, so a shortcut is no way around the lock.
- Siri answers on a locked iPhone, so nothing that lists items or notes works while the device is locked: the queries take their store from `Session.listingIntentStore()`, which refuses while protected data is closed, and Complete Item asks to unlock first (`authenticationPolicy`). A query has no `authenticationPolicy`, and the system closes protected data a few seconds after the device locks, which is the window Find Items leaves. Add Item and Add Note give nothing away and still work on a locked device, so an item can be added hands-free; a saved or spoken project is still found for them, and only the list of all projects waits for the unlock.

The control "New Item" for Control Center, the lock screen and the Action button is `NewItemIntent` in `Shared/`, declared in the widget extension and carried out in the app. What an action wants shown goes through `OpenRequest`, which `RootView` carries out.

### Spotlight

`SpotlightFeed` ([`SpotlightFeed.swift`](../apple/Pendenz/Intents/SpotlightFeed.swift)) indexes the open items and the notes on the device and runs every call to the index in one queue. It sends only what changed, two seconds after the last change. A locked note is indexed by its title alone, and a lock takes the text out of the index at once. Until a launch has synced, only locks are passed on, so a note locked on another device does not get its old text indexed. The index is emptied when the pairing ends.

### Conventions in the interface

- The app is black and white. The tint is the label color, and color is kept for state, such as red for overdue. Liquid Glass takes its color from what is behind it, so color in the chrome would carry nothing.
- Quick add is one line. It understands dates, times, repeats and `#project` in English and German ([`QuickAddParser.swift`](../apple/Pendenz/Model/QuickAddParser.swift)), and shows what it understood as chips.
- The app asks only before what cannot be taken back: unpairing, revoking a device, deleting a project, removing an attachment and deleting a comment. Always as an alert with the red action and Cancel. Moving something to the trash never asks, because "Put Back" undoes it, and a question before every trash teaches the hand to confirm without reading.
- Each list keeps its own sort order on each device. Manual order is the only one in which rows can be dragged.

## Kept simple on purpose

Pendenz is for one person and a few agents. Many protections that a multi-user system needs were left out, because their cost is real and the risk they cover is small here. Each has a known way up if it starts to hurt. Please start a discussion before adding one of these back.

| Kept simple | What can happen | If it hurts |
|---|---|---|
| Agent tokens are plain read and write | An agent can edit any item it can see, not only its own. Comments are the exception: an agent changes only its own | Narrower scopes with a check on every route |
| Agents may complete items | An agent could close an item the owner had not reviewed. The activity log shows who | A rule that only a device completes an item an agent worked on |
| The later edit wins per field | Two devices editing the same note offline: one text ends up only in the activity log | Show both versions and let the owner pick |
| Reminders are local, and push only asks the app to sync | A reminder made elsewhere shortly before it is due can be late. With more than 60 pending and an app not opened for weeks, later ones wait | An alert push at the due time, with a notification extension that fetches the text so the relay never sees it |
| Knowing a device's push token is enough to make the relay push to it | A server that once had the token can keep waking the app. The push carries nothing | A grant per installation that the app can take back |
| The relay's rate limits are per location and approximate | A flood with made-up tokens costs requests | A total budget with a switch that closes the relay |
| The sync after a push sends the outbox first | A change the server keeps failing on holds back the pull | Pull first when a push woke the app |
| A locked note is a gate in the app, not encryption | Anyone with the database, a backup or an unlocked device's file system reads it | Encrypt on the device with a key behind Face ID, which would also hide it from agents and search |
| The lock rule for agents is an instruction | An agent that ignores it, or a tool that logs every result, keeps the text | Hide the note from agents |
| One sequence counter for all rows | An agent can tell that something it cannot see was written. It learns no content | A separate sequence for what agents may see |
| No tombstones for hidden rows | A comment written while an item was hidden is not sent to an agent after unhiding. It sees it when it reads the item | New sequence numbers for the comments on unhiding |
| Notes are searched with `LIKE` | Slow with many thousand long notes | SQLite FTS5 |
| A position is a plain number between its neighbours | After about 50 moves into the same gap the order falls back to the ID | Renumber the list when a gap gets too small |
| The pairing route takes any number of guesses | A code has about 49 bits and lives ten minutes. A flood costs a read each | A limit per address at the proxy |
| A lost answer to a pairing uses the code up | The device shows as paired and never used | Let the device send a key so a retry gets the same token |
| Device tokens never expire | A token copied from a device works until it is revoked | An expiry that the app renews while in use |
| Every saved note edit keeps the text from before | A long note edited often grows the log by its length each time | Keep one earlier text per device and hour |
| A repeating time keeps its wall clock | An item that repeats between 02:00 and 03:00 moves to 03:00 in spring and stays there | Store the intended time of day with the rule |
| Only the server works out a repeat | A repeating item completed offline is missing from the lists until the server answers | Work out the next date in the app too |
| The app sends a completion two seconds after the tap, so it can be taken back | An app closed in those two seconds sends it at the next launch | Send at once and undo with a second request |
| A revoked device keeps its rows until it is paired or unpaired | Someone with that unlocked device's file system could read them | Delete them on the 401 |

Left out of the product on purpose: folders for notes, rich text, nested subtasks, colors per project, a manual order of projects, a web app, and emptying the trash.

## Not built yet

[ROADMAP.md](../ROADMAP.md) lists what is planned. The `propose` scope is reserved for later and changes nothing today.
