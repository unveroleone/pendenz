// Draws the three icon directions as one contact sheet, a row per appearance,
// for a quick look without a browser.
//
//   node apple/icon/studies/sheet.mjs
//   node apple/icon/studies/sheet.mjs default,dark,clearDark,tintLight
//
// Writes apple/icon/out/studies.svg, and studies.svg.png when Quick Look can
// rasterize it.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { MODES, DEFS, GLYPHS } from './glyphs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, '..', 'out');
fs.mkdirSync(out, { recursive: true });

const names = Object.keys(GLYPHS);
const rows = (process.argv[2] ?? 'default,dark,clearLight,tintDark').split(',');
const backgrounds = {
  default: ['#fbfbf9', '#dadad6'],
  dark: ['#2c2c2f', '#070708'],
  clearLight: ['rgba(255,255,255,.34)', 'rgba(255,255,255,.2)'],
  clearDark: ['rgba(10,10,12,.5)', 'rgba(10,10,12,.62)'],
  tintLight: ['#7db4ff', '#3b82f6'],
  tintDark: ['#232326', '#050506'],
};

// The sheet is square because Quick Look crops thumbnails to a square.
const S = Math.max(names.length, rows.length) * 1100 + 76;
let sheet =
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${S} ${S}" width="${S / 2}" height="${S / 2}">` +
  `<style>:root{--tint:#3b82f6;--tint-hi:#9cc4ff}</style><defs>${DEFS}`;
for (const [mode, [top, bottom]] of Object.entries(backgrounds)) {
  sheet += `<linearGradient id="bg-${mode}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient>`;
}
sheet +=
  `<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e58a5a"/><stop offset=".5" stop-color="#8a5fd0"/><stop offset="1" stop-color="#1f6f8f"/></linearGradient></defs>` +
  `<rect width="100%" height="100%" fill="url(#wall)"/>`;
rows.forEach((mode, r) =>
  names.forEach((name, c) => {
    sheet += `<g transform="translate(${76 + c * 1100} ${76 + r * 1100})"><rect width="1024" height="1024" rx="230" fill="url(#bg-${mode})"/>${GLYPHS[name](MODES[mode])}</g>`;
  }),
);
sheet += '</svg>';

const sheetPath = path.join(out, 'studies.svg');
fs.writeFileSync(sheetPath, sheet);
try {
  execFileSync('qlmanage', ['-t', '-s', '1800', '-o', out, sheetPath], {
    stdio: 'ignore',
  });
  console.log(path.join(out, 'studies.svg.png'));
} catch {
  console.log(sheetPath);
}
