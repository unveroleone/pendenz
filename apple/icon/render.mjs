// Renders the app icon with Apple's ictool, the command line side of Icon
// Composer, and tiles the results into one sheet: the six appearances on top
// and the small Mac sizes below. This is the real Liquid Glass, not a mock.
//
//   node apple/icon/render.mjs                 Mac renders into apple/icon/out
//   node apple/icon/render.mjs --platform iOS  the iPhone and iPad shape
//   node apple/icon/render.mjs path/to.icon    another Icon Composer document
//
// The sheet is out/sheet.svg, and out/sheet.svg.png when Quick Look can
// rasterize it.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args.splice(i, 2)[1];
};
const platform = flag('--platform', 'macOS');
const out = flag('--out', path.join(here, 'out'));
const doc = args[0] ?? path.join(here, '..', 'Pendenz', 'AppIcon.icon');

const developer = execFileSync('xcode-select', ['-p']).toString().trim();
const ictool = path.join(
  developer,
  '..',
  'Applications',
  'Icon Composer.app',
  'Contents',
  'Executables',
  'ictool',
);
fs.mkdirSync(out, { recursive: true });

function render(name, rendition, size, scale) {
  const file = path.join(out, `${name}.png`);
  execFileSync(ictool, [
    doc,
    '--export-image',
    '--output-file',
    file,
    '--platform',
    platform,
    '--rendition',
    rendition,
    '--width',
    String(size),
    '--height',
    String(size),
    '--scale',
    String(scale),
  ]);
  return file;
}

const appearances = [
  'Default',
  'Dark',
  'ClearLight',
  'ClearDark',
  'TintedLight',
  'TintedDark',
];
const sizes = [128, 64, 32, 16];
const image = (file, x, y, s) =>
  `<image x="${x}" y="${y}" width="${s}" height="${s}" xlink:href="data:image/png;base64,${fs.readFileSync(file).toString('base64')}"/>`;

// The sheet is square because Quick Look crops thumbnails to a square.
const W = 1632;
let sheet =
  `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 ${W} ${W}" width="${W}" height="${W}">` +
  `<defs><linearGradient id="wall" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e58a5a"/><stop offset=".5" stop-color="#8a5fd0"/><stop offset="1" stop-color="#1f6f8f"/></linearGradient></defs>` +
  `<rect width="100%" height="100%" fill="url(#wall)"/>`;
appearances.forEach((rendition, i) => {
  const file = render(rendition, rendition, 512, 1);
  sheet += image(file, 24 + (i % 3) * 536, 24 + Math.floor(i / 3) * 536, 512);
});
sheet +=
  `<rect x="24" y="1100" width="780" height="500" rx="24" fill="#ececec"/>` +
  `<rect x="828" y="1100" width="780" height="500" rx="24" fill="#1e1e1e"/>`;
let x = 60;
for (const px of sizes) {
  sheet += image(render(`default-${px}`, 'Default', px, 2), x, 1140, px * 2);
  sheet += image(render(`dark-${px}`, 'Dark', px, 2), x + 804, 1140, px * 2);
  x += px * 2 + 40;
}
sheet += '</svg>';

const sheetPath = path.join(out, 'sheet.svg');
fs.writeFileSync(sheetPath, sheet);
try {
  execFileSync('qlmanage', ['-t', '-s', String(W), '-o', out, sheetPath], {
    stdio: 'ignore',
  });
  console.log(path.join(out, 'sheet.svg.png'));
} catch {
  console.log(sheetPath);
}
