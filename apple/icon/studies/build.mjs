// Builds the comparison page for the three icon directions into
// apple/icon/out/pendenz-icon-studies.html. The page shows each direction in
// the six appearances and at Dock and Home Screen sizes.
//
//   node apple/icon/studies/build.mjs
//
// page.html is written for a host that wraps it in a document, so this also
// writes local-preview.html with a document shell that opens from disk.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFS } from './glyphs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, '..', 'out');
fs.mkdirSync(out, { recursive: true });

const glyphs = fs
  .readFileSync(path.join(here, 'glyphs.mjs'), 'utf8')
  .replace(/^export /gm, '');
const page = fs
  .readFileSync(path.join(here, 'page.html'), 'utf8')
  .replace('<!--DEFS-->', () => DEFS)
  .replace('/*GLYPHS*/', () => glyphs);

fs.writeFileSync(path.join(out, 'pendenz-icon-studies.html'), page);
fs.writeFileSync(
  path.join(out, 'local-preview.html'),
  '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}</style></head><body>' +
    page +
    '</body></html>',
);
console.log(path.join(out, 'local-preview.html'));
