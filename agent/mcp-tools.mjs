import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import {
  imageBody,
  imageId,
  itemId,
  PROJECT_ICONS,
  projectId,
  query,
} from './client.mjs';

const SERVER_INSTRUCTIONS = [
  'Pendenz is the private store of one person, the owner, for tasks, reminders and notes. workspace.actors names the owner (the actor of kind human). Write everything in the language the owner used for that item or note.',
  'IDs: an item is shown to the owner as P-<id>, for example P-12. Tools accept P-12 or 12.',
  'Before creating: search with list_items (q) for an open item that already covers it, and update that one instead.',
  'Titles say the thing to do in plain words, as the owner would write it: "Call the dentist", "Renew the passport". Details, links and context go into the description.',
  'Dates: due_at is either a day (2026-11-13) or a local time (2026-11-13T09:00). Times are local to the zone from workspace unless the owner names another place; then set due_tz. Never convert to UTC yourself. Work out "tomorrow" or "next Monday" from the current date in that zone.',
  'Reminders: an item with a time in due_at reminds the owner at that time. Set remind_at only when the reminder should come at another time than the due time, or when a day-only item needs one. A day-only item without remind_at sends no reminder.',
  'Repeats: repeat_rule needs due_at. A repeating item is one item: setting it to done moves it to its next date, leaves it open and unticks its checklist for the next round. Do not create one item per occurrence.',
  'Status: todo, doing, done. Set doing when work on it has started, done when it is finished. Use add_comment for progress and results; anything still open belongs in the description or the checklist.',
  'Edits need the version from your last read. On a conflict read the item again and apply your change to the new state.',
  'Projects group items and notes. An item without a project is in the inbox. Create, rename, re-icon or delete a project only when the owner asks for it. A deleted project does not come back.',
  'Order: the inbox and each project have an order the owner sets by hand. list_items with sort manual shows it, with a position on every row, highest first. To move an item, set its position to a number between those of its two new neighbours, or above the highest to put it on top. Leave position alone otherwise.',
  'Notes are plain markdown texts without a title field: the first line is the title. They hold context, not things to do; something to do is an item. Find notes with search_notes and read one with get_note before you rely on it. To add to a note use append_note, which cannot overwrite what the owner typed in the meantime. Use update_note with a new body only to rewrite a note, and only when the owner asks for it.',
  'Writing a note: keep it very short. Plain text that reads well as typed, because the app does not render markdown: a title line, then short lines or "- " points. Only the facts the owner needs, no introduction, no summary, no headings, tables or bold.',
  'Images: an item can carry images, listed under images in get_item with an id each. Look at one with get_item_image when it matters for the task. Remove one only when the owner asks for it; a removed image does not come back.',
  'Trash (trashed: true) is for mistakes and duplicates. Archive (archived: true) is for things the owner decided not to do. Neither is a way to finish an item.',
  'Locked notes: a note whose text is private is locked, and the app then asks the owner for Face ID before it shows the text. You can still read it and add to it, and it is marked locked: true. Use its text only for the task you are on. Never save it or a summary of it to a memory, a journal or a log, never copy it into another note, an item, a comment or a message, and quote from it to the owner only as far as the task needs. search_notes shows a locked note by its title alone. Lock a note yourself (locked: true) when the owner asks for it or when you write something private into it, such as health, money or access details. Only the owner can remove a lock.',
  'The owner can hide items and notes from agents. They do not appear here at all, so one that the owner mentions may be missing: say that you cannot see it instead of creating a copy.',
  'Keys: give every write a key of your own that names the action, for example "tg-4812-create". If the call fails with a network error or times out, repeat it with the same key and the same arguments, so it cannot apply twice. A write without a key is a new action every time.',
].join('\n');

// Marks a tool result that is MCP content already.
const CONTENT = Symbol('content');

const COMPACT_DESCRIPTION = 200;

// A list row for an agent: enough to pick the right item, without full descriptions.
function compact(item, withPosition = false) {
  // A token without the read scope only gets a receipt with the id and version.
  if (item.title === undefined) return item;
  const row = {
    id: item.id,
    ref: `P-${item.id}`,
    title: item.title,
    status: item.status,
    version: item.version,
  };
  for (const field of [
    'project_id',
    'due_at',
    'due_tz',
    'remind_at',
    'repeat_rule',
    'source_url',
  ])
    if (item[field] !== null) row[field] = item[field];
  if (item.priority) row.priority = item.priority;
  if (withPosition) row.position = item.position;
  if (item.tags.length) row.tags = item.tags;
  if (item.agent_stage !== 'none') row.agent_stage = item.agent_stage;
  if (item.images?.length) row.images = item.images.length;
  if (item.checklist.length)
    row.checklist = `${item.checklist.filter((line) => line.done).length}/${item.checklist.length} done`;
  if (item.description)
    row.description =
      item.description.length > COMPACT_DESCRIPTION
        ? `${item.description.slice(0, COMPACT_DESCRIPTION)}… (get_item for the rest)`
        : item.description;
  return row;
}

const NOTE_PREVIEW = 200;

// Sent with the text of a locked note, so the rule is next to the text it is about.
const LOCKED_NOTICE =
  'The owner locked this note. Use its text only for the task you are on: do not save it or a summary of it to a memory, a journal or a log, and do not copy it into another note, an item, a comment or a message.';

// A list row for a note: its first line as the title and the start of the rest. A locked note
// keeps the rest to itself, as its row in the app does.
function compactNote(note) {
  // A token without the read scope only gets a receipt with the id and version.
  if (note.body === undefined) return note;
  const [title, ...rest] = note.body.trim().split('\n');
  const text = rest.join('\n').trim();
  const row = {
    id: note.id,
    title: title.replace(/^#+\s*/, '').slice(0, 240),
    version: note.version,
    updated_at: note.updated_at,
    length: note.body.length,
  };
  if (note.project_id !== null) row.project_id = note.project_id;
  if (note.pinned) row.pinned = true;
  if (note.trashed) row.trashed = true;
  if (note.locked) row.locked = true;
  else if (text)
    row.preview =
      text.length > NOTE_PREVIEW
        ? `${text.slice(0, NOTE_PREVIEW)}… (get_note for the rest)`
        : text;
  return row;
}

// `files` is set by the stdio server, which runs next to the agent and can read its files. The
// hosted server cannot, so it offers no tool that takes a path.
export function createMcpServer(
  request,
  scopes = null,
  { files = false } = {},
) {
  const server = new McpServer(
    { name: 'pendenz', version: '0.1.0' },
    { instructions: SERVER_INSTRUCTIONS },
  );
  const id = z
    .union([
      z.number().int().positive(),
      z.string().regex(/^([Pp]-)?[1-9]\d*$/),
    ])
    .describe('Item ID, as P-12 or 12.');
  const key = z
    .string()
    .min(1)
    .max(128)
    .optional()
    .describe(
      'A name you choose for this write, such as "tg-4812-create". Repeating the call with the same key and arguments returns the first result and writes nothing.',
    );
  const status = z
    .enum(['todo', 'doing', 'done'])
    .describe('todo = not started, doing = in progress, done = finished.');
  const fields = {
    title: z.string().trim().min(1).max(240),
    description: z
      .string()
      .max(20000)
      .describe('Markdown. Details, context and links.'),
    status,
    project_id: z
      .string()
      .min(1)
      .nullable()
      .describe('Project ID from workspace.projects. Null means the inbox.'),
    priority: z
      .number()
      .int()
      .min(0)
      .max(4)
      .describe('0 = none, 1 = low, 2 = medium, 3 = high, 4 = urgent.'),
    tags: z
      .array(z.string().min(1).max(40).regex(/^\S+$/, 'A tag has no spaces.'))
      .max(12)
      .describe('Lowercase words without spaces. Replaces the whole list.'),
    checklist: z
      .array(
        z.strictObject({
          id: z
            .string()
            .max(36)
            .optional()
            .describe(
              'Keep the id of an existing line. Leave out for a new line.',
            ),
          text: z.string().trim().min(1).max(500),
          done: z.boolean().optional(),
        }),
      )
      .max(100)
      .describe(
        'Ordered steps inside the item. Replaces the whole list, so send every line you want to keep.',
      ),
    due_at: z
      .string()
      .nullable()
      .describe(
        'A day (2026-11-13) or a local time (2026-11-13T09:00). Null clears it.',
      ),
    due_tz: z
      .string()
      .nullable()
      .describe(
        'IANA zone for due_at, such as Europe/Zurich. Leave out to use the zone from workspace.',
      ),
    remind_at: z
      .string()
      .nullable()
      .describe(
        'Local time of the reminder (2026-11-12T18:00) when it differs from due_at. Null clears it.',
      ),
    repeat_rule: z
      .string()
      .nullable()
      .describe(
        'FREQ=DAILY, WEEKLY, MONTHLY or YEARLY, optionally ;INTERVAL=2, ;BYDAY=MO,TH (weekly), ;BYMONTHDAY=31 (monthly). Needs due_at. Null stops the repeat.',
      ),
    source_url: z
      .string()
      .url()
      .max(2000)
      .nullable()
      .describe('The page or message the item came from. Do not invent one.'),
  };
  const position = z
    .number()
    .finite()
    .describe(
      'Place in the manual order of its list, highest first. A number between the positions of the two neighbours it should sit between; read them with list_items and sort manual.',
    );
  const noteId = z
    .union([z.number().int().positive(), z.string().regex(/^[1-9]\d*$/)])
    .describe('Note ID from search_notes.');
  const noteFields = {
    body: z
      .string()
      .min(1)
      .max(100000)
      .describe('Markdown. The first line is the title.'),
    project_id: z
      .string()
      .min(1)
      .nullable()
      .describe('Project ID from workspace.projects. Null means no project.'),
    pinned: z.boolean().describe('Pinned notes are listed first.'),
    locked: z
      .literal(true)
      .describe(
        'Locks the note: the app asks the owner for Face ID or Touch ID before it shows the text. For private text. Only the owner can remove a lock.',
      ),
  };
  function tool(
    name,
    needs,
    description,
    inputSchema,
    action,
    destructive = false,
  ) {
    if (scopes && !scopes.includes(needs)) return;
    server.registerTool(
      name,
      {
        description,
        inputSchema: z.strictObject(inputSchema),
        annotations: {
          readOnlyHint: needs === 'read',
          destructiveHint: destructive,
          idempotentHint: needs === 'read',
          openWorldHint: false,
        },
      },
      async (args) => {
        try {
          const result = await action(args);
          // A tool that answers with something other than JSON text, such as an image.
          if (result?.[CONTENT]) return { content: result[CONTENT] };
          return {
            content: [{ type: 'text', text: JSON.stringify(result) }],
          };
        } catch (error) {
          return {
            isError: true,
            content: [{ type: 'text', text: error.message }],
          };
        }
      },
    );
  }
  tool(
    'workspace',
    'read',
    'Who you are, your scopes, the time zone for dates, all projects with their IDs and icons, and the allowed values. Call it once before your first write.',
    {},
    () => request('/bootstrap'),
  );
  tool(
    'list_items',
    'read',
    'List items as compact rows (long descriptions are cut; use get_item for one item in full). Shows open items by default. Returns at most limit rows; when has_more is true, call again with a higher offset.',
    {
      status: z
        .enum(['open', 'todo', 'doing', 'done', 'all'])
        .default('open')
        .describe('open = todo and doing.'),
      project: z
        .string()
        .min(1)
        .optional()
        .describe('A project ID, or "inbox" for items without a project.'),
      q: z
        .string()
        .optional()
        .describe('Text that the title or description contains.'),
      tag: z.string().optional(),
      priority: z.number().int().min(0).max(4).optional(),
      due_after: z
        .string()
        .optional()
        .describe(
          'Day or local time, inclusive. With due_before: a date range.',
        ),
      due_before: z
        .string()
        .optional()
        .describe(
          'Day or local time, exclusive. For "due today or overdue" send tomorrow\'s date here.',
        ),
      sort: z
        .enum([
          'newest',
          'oldest',
          'edited',
          'due',
          'priority',
          'title',
          'manual',
        ])
        .default('newest')
        .describe(
          'due = soonest first, undated last. manual = the order the owner set by hand in the inbox or a project; use it with project, and each row then carries its position.',
        ),
      archived: z.boolean().optional().describe('True lists the archive.'),
      trashed: z.boolean().optional().describe('True lists the trash.'),
      limit: z.number().int().min(1).max(200).default(30),
      offset: z.number().int().min(0).max(1000000).default(0),
    },
    async ({ status, ...filters }) => {
      const result = await request(
        `/items${query({ ...filters, status: status === 'all' ? undefined : status })}`,
      );
      return {
        items: result.items.map((item) =>
          compact(item, filters.sort === 'manual'),
        ),
        has_more: result.has_more,
      };
    },
  );
  tool(
    'get_item',
    'read',
    'One item in full: every field, its current version, all comments, and the latest changes (who changed which field from what to what).',
    {
      id,
      activity: z
        .number()
        .int()
        .min(0)
        .max(100)
        .default(10)
        .describe('How many of the latest changes to include.'),
    },
    ({ id, activity }) => request(`/items/${itemId(id)}${query({ activity })}`),
  );
  tool(
    'create_item',
    'write',
    'Add an item. Only the title is required; it lands in the inbox unless project_id is set. Check list_items first so you do not add a duplicate. Returns the new item as a compact row with its id and version.',
    {
      item: z.strictObject({
        title: fields.title,
        description: fields.description.optional(),
        status: status.optional(),
        project_id: fields.project_id.optional(),
        priority: fields.priority.optional(),
        tags: fields.tags.optional(),
        checklist: fields.checklist.optional(),
        due_at: fields.due_at.optional(),
        due_tz: fields.due_tz.optional(),
        remind_at: fields.remind_at.optional(),
        repeat_rule: fields.repeat_rule.optional(),
        source_url: fields.source_url.optional(),
        position: position.optional(),
      }),
      key,
    },
    async ({ item, key }) =>
      compact(
        await request('/items', { method: 'POST', body: item, key }),
        item.position !== undefined,
      ),
  );
  tool(
    'update_item',
    'write',
    'Change an item. Send its current version and only the fields that change. status done finishes it (a repeating item moves to its next date instead, stays open and gets its checklist unticked). archived or trashed move it out of the lists; false brings it back. Returns the item as a compact row with its new version.',
    {
      id,
      version: z
        .number()
        .int()
        .positive()
        .describe('The version from your last read of this item.'),
      changes: z
        .strictObject({
          ...fields,
          position,
          archived: z.boolean(),
          trashed: z.boolean(),
        })
        .partial()
        .refine(
          (changes) => Object.keys(changes).length > 0,
          'Include at least one field to change.',
        ),
      key,
    },
    async ({ id, version, changes, key }) =>
      compact(
        await request(`/items/${itemId(id)}`, {
          method: 'PATCH',
          body: { ...changes, version },
          key,
        }),
        changes.position !== undefined,
      ),
  );
  tool(
    'add_comment',
    'write',
    'Add a note to an item: progress, a result, a decision. Comments cannot be edited or removed.',
    { id, body: z.string().trim().min(1).max(10000), key },
    ({ id, body, key }) =>
      request(`/items/${itemId(id)}/comments`, {
        method: 'POST',
        body: { body },
        key,
      }),
  );
  const image = z
    .union([z.number().int().positive(), z.string().regex(/^[1-9]\d*$/)])
    .describe("Image ID from the item's images list in get_item.");
  tool(
    'get_item_image',
    'read',
    'Look at one image of an item. get_item lists the images of an item with their ids, sizes and types. Returns the image itself.',
    { id, image },
    async ({ id, image }) => {
      const { mime, data } = await request(
        `/items/${itemId(id)}/images/${imageId(image)}`,
        { binary: true },
      );
      return {
        [CONTENT]: [
          { type: 'image', data: data.toString('base64'), mimeType: mime },
        ],
      };
    },
  );
  if (files)
    tool(
      'add_item_image',
      'write',
      'Attach an image file from this machine to an item: a JPEG or PNG of at most 5 MB and 40 million pixels. An item holds at most 20 images. Returns the item as a compact row with its new version.',
      {
        id,
        path: z
          .string()
          .min(1)
          .describe('Absolute path of the image file on this machine.'),
        key,
      },
      async ({ id, path, key }) =>
        compact(
          await request(`/items/${itemId(id)}/images`, {
            method: 'POST',
            body: await imageBody(path),
            key,
          }),
        ),
    );
  tool(
    'remove_item_image',
    'write',
    'Remove one image from an item, only when the owner asks for it. This cannot be undone. Returns the item as a compact row with its new version.',
    { id, image, key },
    async ({ id, image, key }) =>
      compact(
        await request(`/items/${itemId(id)}/images/${imageId(image)}`, {
          method: 'DELETE',
          body: {},
          key,
        }),
      ),
    true,
  );
  const icon = z
    .enum(PROJECT_ICONS)
    .describe(
      'The symbol the app draws next to the project. "number" is the plain # every project starts with.',
    );
  tool(
    'create_project',
    'write',
    'Create a project, only when the owner asks for one. Check workspace.projects first. An icon that fits the name helps the owner find it. Returns the project with the ID to use as project_id.',
    { name: z.string().trim().min(1).max(80), icon: icon.optional(), key },
    ({ name, icon, key }) =>
      request('/projects', {
        method: 'POST',
        body: icon ? { name, icon } : { name },
        key,
      }),
  );
  tool(
    'update_project',
    'write',
    'Rename a project, change its icon, or both, only when the owner asks for it. The ID stays, so its items and notes keep their project. Returns the project.',
    {
      id: z.string().describe('Project ID from workspace.projects.'),
      name: z.string().trim().min(1).max(80).optional(),
      icon: icon.optional(),
      key,
    },
    ({ id, name, icon, key }) => {
      const body = {};
      if (name !== undefined) body.name = name;
      if (icon !== undefined) body.icon = icon;
      if (!Object.keys(body).length)
        throw new Error('Send a name, an icon or both.');
      return request(`/projects/${projectId(id)}`, {
        method: 'PATCH',
        body,
        key,
      });
    },
  );
  tool(
    'delete_project',
    'write',
    'Delete a project, only when the owner asks for this project to be deleted. Its items and notes stay and lose the project: the items are in the inbox afterwards. This cannot be undone, the project does not come back and its ID is not given out again. Returns the project with deleted: true.',
    { id: z.string().describe('Project ID from workspace.projects.'), key },
    ({ id, key }) =>
      request(`/projects/${projectId(id)}`, {
        method: 'DELETE',
        body: {},
        key,
      }),
    true,
  );
  tool(
    'search_notes',
    'read',
    'List notes as compact rows: the first line as the title and the start of the rest (get_note for the full text). A locked note has locked: true and no preview. Pinned notes first, then the last edited. With q only notes whose text contains it. Returns at most limit rows; when has_more is true, call again with a higher offset.',
    {
      q: z.string().optional().describe('Text that the note contains.'),
      project: z
        .string()
        .min(1)
        .optional()
        .describe('A project ID, or "none" for notes without a project.'),
      trashed: z.boolean().optional().describe('True lists the trash.'),
      limit: z.number().int().min(1).max(200).default(30),
      offset: z.number().int().min(0).max(1000000).default(0),
    },
    async (filters) => {
      const result = await request(`/notes${query(filters)}`);
      return {
        notes: result.notes.map(compactNote),
        has_more: result.has_more,
      };
    },
  );
  tool(
    'get_note',
    'read',
    'One note in full, with its current version. A locked note comes with a notice on how its text may be used.',
    { id: noteId },
    async ({ id }) => {
      const { note } = await request(`/notes/${Number(id)}`);
      return note.locked ? { ...note, notice: LOCKED_NOTICE } : note;
    },
  );
  tool(
    'create_note',
    'write',
    'Add a note. Check search_notes first for a note that already covers the subject, and append to that one instead. Keep it very short and in plain text: a title line, then only the facts the owner needs. Returns the note as a compact row with its id and version.',
    {
      note: z.strictObject({
        body: noteFields.body,
        project_id: noteFields.project_id.optional(),
        pinned: noteFields.pinned.optional(),
        locked: noteFields.locked.optional(),
      }),
      key,
    },
    async ({ note, key }) =>
      compactNote(await request('/notes', { method: 'POST', body: note, key })),
  );
  tool(
    'update_note',
    'write',
    'Change a note. Send its current version and only the fields that change. A body replaces the whole text, so read the note with get_note first; to add text use append_note. trashed moves it to the trash; false brings it back. locked: true locks it. Returns the note as a compact row with its new version.',
    {
      id: noteId,
      version: z
        .number()
        .int()
        .positive()
        .describe('The version from your last read of this note.'),
      changes: z
        .strictObject({ ...noteFields, trashed: z.boolean() })
        .partial()
        .refine(
          (changes) => Object.keys(changes).length > 0,
          'Include at least one field to change.',
        ),
      key,
    },
    async ({ id, version, changes, key }) =>
      compactNote(
        await request(`/notes/${Number(id)}`, {
          method: 'PATCH',
          body: { ...changes, version },
          key,
        }),
      ),
  );
  tool(
    'append_note',
    'write',
    'Add text at the end of a note, on a new line. Needs no version: the text goes after whatever the note holds at that moment, so nothing the owner wrote meanwhile is lost. Returns the note as a compact row with its new version.',
    {
      id: noteId,
      text: z
        .string()
        .min(1)
        .max(20000)
        .describe(
          'Markdown. Start it with an empty line to set it apart from the text before.',
        ),
      key,
    },
    async ({ id, text, key }) =>
      compactNote(
        await request(`/notes/${Number(id)}`, {
          method: 'PATCH',
          body: { append: text },
          key,
        }),
      ),
  );
  tool(
    'changes',
    'read',
    'Everything that changed since a cursor: items, comments and projects in their current state, oldest change first. Notes are left out; find them with search_notes. A project with deleted: true is gone, and its items are in the inbox. Store the returned cursor and send it next time. When reset is true, your cursor is no longer valid: start again from 0.',
    {
      cursor: z.number().int().min(0).default(0),
      limit: z.number().int().min(1).max(500).default(50),
    },
    async (args) => {
      const page = await request(`/changes${query(args)}`);
      // Notes are context to search, not work to pick up, and a note can be long.
      return {
        ...page,
        changes: page.changes.filter((change) => change.type !== 'note'),
      };
    },
  );
  return server;
}
