#!/usr/bin/env node
import { writeFile } from 'node:fs/promises';
import {
  imageBody,
  imageId,
  itemId,
  noteId,
  projectId,
  query,
  request,
} from './client.mjs';

const usage = `Pendenz

Set PENDENZ_API_URL and PENDENZ_API_TOKEN. Output is JSON.

  workspace
  list [--status open|todo|doing|done] [--project ID|inbox] [--q TEXT] [--tag TAG]
       [--priority 0..4] [--due_after DATE] [--due_before DATE] [--sort newest|due|manual|...]
       [--archived true] [--trashed true] [--limit N] [--offset N]
  get ID [--activity N]
  create --json '{"title":"...","due_at":"2026-11-13T09:00"}'
  update ID --json '{"version":1,"status":"done"}'
  comment ID --body TEXT
  add-image ID FILE
  get-image ID IMAGE --out FILE
  remove-image ID IMAGE
  project --name NAME [--icon SYMBOL]
  project-update ID [--name NAME] [--icon SYMBOL]
  project-delete ID
  notes [--q TEXT] [--project ID|none] [--trashed true] [--limit N] [--offset N]
  note ID [--activity N]
  note-create --json '{"body":"Title\\n\\nText"}'
  note-update ID --json '{"version":1,"pinned":true}'
  note-append ID --text TEXT
  changes [--cursor N] [--limit N]
  reminders --after TIME [--until TIME]

Item IDs are written P-12 or 12, note IDs are plain numbers. An image is a JPEG or PNG of at
most 5 MB; its ID is in the item's images list. An item's place in the manual
order of its list is its position, highest first: update it to a number between two neighbours.
A note with "locked": true is private to the owner: use its text for the task at hand only,
and do not save or copy it anywhere. You can lock a note with "locked": true; only the owner
removes a lock. Write notes very short and in plain text: a title line, then only the facts
the owner needs.
Every write takes --key KEY; reuse the key when you retry the same action after a network
error, so it cannot apply twice.
`;

function options(values) {
  const result = {};
  for (let i = 0; i < values.length; i += 2) {
    if (!values[i]?.startsWith('--') || values[i + 1] === undefined)
      throw new Error('Expected --option value pairs.');
    result[values[i].slice(2)] = values[i + 1];
  }
  return result;
}

function json(text) {
  try {
    const value = JSON.parse(text ?? '');
    if (value && typeof value === 'object' && !Array.isArray(value))
      return value;
  } catch {
    // Reported below.
  }
  throw new Error('Pass --json with a JSON object.');
}

const [command, ...args] = process.argv.slice(2);
try {
  let result;
  if (!command || ['help', '--help', '-h'].includes(command)) {
    console.log(usage);
  } else if (command === 'workspace') {
    result = await request('/bootstrap');
  } else if (command === 'list') {
    result = await request(`/items${query(options(args))}`);
  } else if (command === 'get') {
    const id = itemId(args.shift());
    result = await request(`/items/${id}${query(options(args))}`);
  } else if (command === 'changes') {
    result = await request(`/changes${query(options(args))}`);
  } else if (command === 'reminders') {
    result = await request(`/reminders${query(options(args))}`);
  } else if (command === 'create') {
    const opts = options(args);
    result = await request('/items', {
      method: 'POST',
      body: json(opts.json),
      key: opts.key,
    });
  } else if (command === 'update') {
    const id = itemId(args.shift());
    const opts = options(args);
    result = await request(`/items/${id}`, {
      method: 'PATCH',
      body: json(opts.json),
      key: opts.key,
    });
  } else if (command === 'comment') {
    const id = itemId(args.shift());
    const opts = options(args);
    result = await request(`/items/${id}/comments`, {
      method: 'POST',
      body: { body: opts.body ?? '' },
      key: opts.key,
    });
  } else if (command === 'add-image') {
    const id = itemId(args.shift());
    const body = await imageBody(args.shift());
    result = await request(`/items/${id}/images`, {
      method: 'POST',
      body,
      key: options(args).key,
    });
  } else if (command === 'get-image') {
    const id = itemId(args.shift());
    const image = imageId(args.shift());
    const opts = options(args);
    if (!opts.out) throw new Error('Pass --out with the file to write.');
    const { mime, data } = await request(`/items/${id}/images/${image}`, {
      binary: true,
    });
    await writeFile(opts.out, data);
    result = { file: opts.out, mime, bytes: data.length };
  } else if (command === 'remove-image') {
    const id = itemId(args.shift());
    const image = imageId(args.shift());
    result = await request(`/items/${id}/images/${image}`, {
      method: 'DELETE',
      body: {},
      key: options(args).key,
    });
  } else if (command === 'project') {
    const opts = options(args);
    const body = { name: opts.name ?? '' };
    if (opts.icon !== undefined) body.icon = opts.icon;
    result = await request('/projects', {
      method: 'POST',
      body,
      key: opts.key,
    });
  } else if (command === 'project-update') {
    const id = projectId(args.shift());
    const opts = options(args);
    const body = {};
    if (opts.name !== undefined) body.name = opts.name;
    if (opts.icon !== undefined) body.icon = opts.icon;
    result = await request(`/projects/${id}`, {
      method: 'PATCH',
      body,
      key: opts.key,
    });
  } else if (command === 'project-delete') {
    const id = projectId(args.shift());
    const opts = options(args);
    result = await request(`/projects/${id}`, {
      method: 'DELETE',
      body: {},
      key: opts.key,
    });
  } else if (command === 'notes') {
    result = await request(`/notes${query(options(args))}`);
  } else if (command === 'note') {
    const id = noteId(args.shift());
    result = await request(`/notes/${id}${query(options(args))}`);
  } else if (command === 'note-create') {
    const opts = options(args);
    result = await request('/notes', {
      method: 'POST',
      body: json(opts.json),
      key: opts.key,
    });
  } else if (command === 'note-update') {
    const id = noteId(args.shift());
    const opts = options(args);
    result = await request(`/notes/${id}`, {
      method: 'PATCH',
      body: json(opts.json),
      key: opts.key,
    });
  } else if (command === 'note-append') {
    const id = noteId(args.shift());
    const opts = options(args);
    result = await request(`/notes/${id}`, {
      method: 'PATCH',
      body: { append: opts.text ?? '' },
      key: opts.key,
    });
  } else {
    throw new Error('Unknown command. Run with --help.');
  }
  if (result !== undefined) console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
