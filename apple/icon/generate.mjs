// Writes the layers of the app icon (the Zettelspiess) as flat SVG files into
// apple/Pendenz/AppIcon.icon/Assets. Icon Composer adds the glass, so the layers
// carry shapes and plain fills only.
//
//   node apple/icon/generate.mjs           rewrite the layers, keep icon.json
//   node apple/icon/generate.mjs --json    also rewrite icon.json from this file
//
// icon.json is only written when it is missing or when --json is passed, so
// glass settings changed in Icon Composer survive a new set of layers.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const writeJson = args.includes('--json');
const out =
  args.find((a) => !a.startsWith('--')) ??
  path.join(here, '..', 'Pendenz', 'AppIcon.icon');
fs.mkdirSync(path.join(out, 'Assets'), { recursive: true });

// The canvas is 1024 x 1024. DY moves the whole drawing up so it sits centred.
const DY = -26;
const K = 0.5522847498;
const INK = '#141414';
const RED = '#ff3b30';
const f = (n) => +n.toFixed(2);

// A rounded rectangle lying on a slip, seen from above: rotated around the
// spike, then flattened on the y axis.
function plane(cx, cy, rot, x, y, w, h, r) {
  const a = (rot * Math.PI) / 180;
  const c = Math.cos(a);
  const s = Math.sin(a);
  const P = (px, py) =>
    `${f(cx + px * c - py * s)} ${f(cy + DY + 0.42 * (px * s + py * c))}`;
  const x2 = x + w;
  const y2 = y + h;
  const k = r * (1 - K);
  return (
    `M${P(x + r, y)}L${P(x2 - r, y)}C${P(x2 - k, y)} ${P(x2, y + k)} ${P(x2, y + r)}` +
    `L${P(x2, y2 - r)}C${P(x2, y2 - k)} ${P(x2 - k, y2)} ${P(x2 - r, y2)}` +
    `L${P(x + r, y2)}C${P(x + k, y2)} ${P(x, y2 - k)} ${P(x, y2 - r)}` +
    `L${P(x, y + r)}C${P(x, y + k)} ${P(x + k, y)} ${P(x + r, y)}Z`
  );
}

function ellipse(cx, cy, rx, ry) {
  const y = cy + DY;
  return `M${cx - rx} ${y}A${rx} ${ry} 0 1 0 ${cx + rx} ${y}A${rx} ${ry} 0 1 0 ${cx - rx} ${y}Z`;
}

const svg = (d, fill, evenOdd) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">` +
  `<path d="${d}" fill="${fill}"${evenOdd ? ' fill-rule="evenodd"' : ''}/></svg>\n`;

const slip = (cy, rot) => plane(512, cy, rot, -240, -175, 480, 350, 48);
const spike = () => `L506 ${215 + DY}Q512 ${170 + DY} 518 ${215 + DY}`;

const layers = {
  'base-side': svg(
    `M337 ${812 + DY}A175 70 0 0 1 687 ${812 + DY}L687 ${844 + DY}A175 70 0 0 1 337 ${844 + DY}Z`,
    INK,
  ),
  'base-top': svg(ellipse(512, 812, 175, 70), INK),
  needle: svg(
    `M488 ${812 + DY}${spike()}L536 ${812 + DY}A24 10 0 0 1 488 ${812 + DY}Z`,
    INK,
  ),
  'slip-bottom': svg(slip(680, -40), INK),
  'slip-middle': svg(slip(575, 22), INK),
  // The top slip has a hole where the spike comes through.
  'slip-top': svg(slip(470, -16) + ellipse(512, 473, 31, 13), INK, true),
  mark: svg(plane(512, 470, -16, 66, 66, 124, 48, 24), RED),
  // The part of the spike above the top slip, drawn again in front of it.
  tip: svg(`M498.3 ${472 + DY}${spike()}L525.7 ${472 + DY}Z`, INK),
};

for (const [name, body] of Object.entries(layers)) {
  fs.writeFileSync(path.join(out, 'Assets', `${name}.svg`), body);
}

// Ink layers are near black by default and white in dark. They are also white
// in "tinted", the mono appearance that the clear and the tinted icons are
// derived from. Mono turns luminance into opacity, so dark ink would vanish.
const gray = (v) => ({ solid: `extended-gray:${v.toFixed(5)},1.00000` });
const ink = (name, tone = 1) => ({
  'image-name': `${name}.svg`,
  name,
  glass: true,
  'fill-specializations': [
    { appearance: 'dark', value: gray(tone) },
    { appearance: 'tinted', value: gray(tone) },
  ],
});
const group = (groupLayers, translucency) => ({
  layers: groupLayers,
  shadow: { kind: 'neutral', opacity: 0.5 },
  translucency: {
    enabled: translucency !== null,
    value: translucency ?? 0.5,
  },
});

// Groups run from front to back. Icon Composer shows at most four.
const document = {
  fill: { 'automatic-gradient': 'extended-gray:0.93000,1.00000' },
  'fill-specializations': [{ appearance: 'dark', value: 'system-dark' }],
  groups: [
    group(
      [
        ink('tip'),
        {
          'image-name': 'mark.svg',
          name: 'mark',
          glass: false,
          'fill-specializations': [{ appearance: 'tinted', value: gray(0.42) }],
        },
      ],
      null,
    ),
    group([ink('slip-top')], 0.3),
    group([ink('slip-middle'), ink('slip-bottom')], 0.6),
    group([ink('needle'), ink('base-top'), ink('base-side', 0.62)], null),
  ],
  'supported-platforms': { squares: 'shared' },
};

const jsonPath = path.join(out, 'icon.json');
if (writeJson || !fs.existsSync(jsonPath)) {
  fs.writeFileSync(jsonPath, `${JSON.stringify(document, null, 2)}\n`);
  console.log(`wrote ${Object.keys(layers).length} layers and icon.json to ${out}`);
} else {
  console.log(`wrote ${Object.keys(layers).length} layers to ${out}, kept icon.json`);
}
