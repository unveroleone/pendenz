// The three icon directions from the first round, drawn for the browser:
// Zettelspiess (spike), unfinished check and empty brackets. The glass here is
// faked with SVG filters so the directions can be compared on a page. The real
// icon is drawn by ../generate.mjs and rendered by Icon Composer.
//
// The canvas is 1024 x 1024. build.mjs inlines this file into the preview page
// and drops the leading "export" of each declaration, so the rest has to run
// in a browser as it is.

export const MODES = {
  default: { label: 'Default', ink: 'url(#ink-dark)', fx: 'url(#fx-on-light)', baseOp: 1, face: 'rgba(255,255,255,.16)', hole: 'rgba(255,255,255,.85)', accent: '#ff3b30', ghostFill: 'rgba(255,255,255,.6)', ghostStroke: 'rgba(0,0,0,.2)', slip: [0.82, 0.6, 0.42] },
  dark: { label: 'Dark', ink: 'url(#ink-light)', fx: 'url(#fx-on-dark)', baseOp: 0.6, face: '#ffffff', hole: 'rgba(0,0,0,.7)', accent: '#ff453a', ghostFill: 'rgba(255,255,255,.13)', ghostStroke: 'rgba(255,255,255,.42)', slip: [0.92, 0.62, 0.4] },
  clearLight: { label: 'Clear, light', ink: 'url(#ink-light)', fx: 'url(#fx-clear)', baseOp: 0.6, face: '#ffffff', hole: 'rgba(0,0,0,.28)', accent: '#ffffff', ghostFill: 'rgba(255,255,255,.22)', ghostStroke: 'rgba(255,255,255,.6)', slip: [0.9, 0.6, 0.4] },
  clearDark: { label: 'Clear, dark', ink: 'url(#ink-light)', fx: 'url(#fx-on-dark)', baseOp: 0.6, face: '#ffffff', hole: 'rgba(0,0,0,.5)', accent: '#ffffff', ghostFill: 'rgba(255,255,255,.14)', ghostStroke: 'rgba(255,255,255,.45)', slip: [0.88, 0.58, 0.38] },
  tintLight: { label: 'Tinted, light', ink: 'url(#ink-light)', fx: 'url(#fx-clear)', baseOp: 0.6, face: '#ffffff', hole: 'rgba(0,0,0,.25)', accent: '#ffffff', ghostFill: 'rgba(255,255,255,.24)', ghostStroke: 'rgba(255,255,255,.6)', slip: [0.92, 0.62, 0.42] },
  tintDark: { label: 'Tinted, dark', ink: 'url(#ink-tint)', fx: 'url(#fx-on-dark)', baseOp: 0.6, face: 'var(--tint-hi)', hole: 'rgba(0,0,0,.7)', accent: 'var(--tint-hi)', ghostFill: 'rgba(255,255,255,.08)', ghostStroke: 'var(--tint)', slip: [0.92, 0.62, 0.4] },
};

export const DEFS = `
<linearGradient id="ink-dark" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#343434"/><stop offset="1" stop-color="#0a0a0a"/></linearGradient>
<linearGradient id="ink-light" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#dcdcdc"/></linearGradient>
<linearGradient id="ink-tint" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color:var(--tint-hi)"/><stop offset="1" style="stop-color:var(--tint)"/></linearGradient>
<filter id="fx-on-light" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024" color-interpolation-filters="sRGB">
  <feGaussianBlur in="SourceAlpha" stdDeviation="6" result="bump"/>
  <feSpecularLighting in="bump" surfaceScale="7" specularConstant="0.9" specularExponent="26" lighting-color="#ffffff" result="spec"><feDistantLight azimuth="235" elevation="34"/></feSpecularLighting>
  <feComposite in="spec" in2="SourceAlpha" operator="in" result="specIn"/>
  <feGaussianBlur in="SourceAlpha" stdDeviation="16" result="sh"/><feOffset in="sh" dy="16" result="shOff"/>
  <feComponentTransfer in="shOff" result="shadow"><feFuncA type="linear" slope="0.3"/></feComponentTransfer>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/><feMergeNode in="specIn"/></feMerge>
</filter>
<filter id="fx-on-dark" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024" color-interpolation-filters="sRGB">
  <feGaussianBlur in="SourceAlpha" stdDeviation="18" result="sh"/><feOffset in="sh" dy="18" result="shOff"/>
  <feComponentTransfer in="shOff" result="shadow"><feFuncA type="linear" slope="0.55"/></feComponentTransfer>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="fx-clear" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024" color-interpolation-filters="sRGB">
  <feGaussianBlur in="SourceAlpha" stdDeviation="14" result="sh"/><feOffset in="sh" dy="12" result="shOff"/>
  <feComponentTransfer in="shOff" result="shadow"><feFuncA type="linear" slope="0.26"/></feComponentTransfer>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>`;

function spike(m) {
  const slip = (cy, rot, op) => `<g filter="${m.fx}" opacity="${op}"><g transform="translate(512 ${cy}) scale(1 .42) rotate(${rot})"><rect x="-240" y="-175" width="480" height="350" rx="48" fill="${m.ink}"/></g></g>`;
  return `<g transform="translate(0 -26)">
  <g filter="${m.fx}"><path d="M337 812A175 70 0 0 1 687 812L687 844A175 70 0 0 1 337 844Z" fill="${m.ink}" opacity="${m.baseOp}"/><ellipse cx="512" cy="812" rx="175" ry="70" fill="${m.face}"/></g>
  <ellipse cx="512" cy="812" rx="24" ry="10" fill="${m.ink}"/>
  <path d="M488 812L506 215Q512 170 518 215L536 812Z" fill="${m.ink}"/>
  ${slip(680, -40, m.slip[2])}${slip(575, 22, m.slip[1])}${slip(470, -16, m.slip[0])}
  <ellipse cx="512" cy="473" rx="31" ry="13" fill="${m.hole}"/>
  <g transform="translate(512 470) scale(1 .42) rotate(-16)"><rect x="66" y="66" width="124" height="48" rx="24" fill="${m.accent}"/></g>
  <g filter="${m.fx}"><path d="M498.3 472L506 215Q512 170 518 215L525.7 472Z" fill="${m.ink}"/></g>
  </g>`;
}

function check(m) {
  return `<g transform="translate(512 512) scale(1.08) translate(-512 -512)">
  <g filter="${m.fx}"><g transform="translate(595 512) rotate(-51.84)"><rect x="-333" y="-66" width="666" height="132" rx="66" fill="${m.ghostFill}" stroke="${m.ghostStroke}" stroke-width="10"/></g></g>
  <g filter="${m.fx}"><g transform="translate(347.5 639.5) rotate(45)"><rect x="-182.6" y="-66" width="365.2" height="132" rx="66" fill="${m.ink}"/></g></g>
  </g>`;
}

function brackets(m) {
  return `<g transform="translate(512 512) scale(1.1) translate(-512 -512)">
  <g filter="${m.fx}"><rect x="386" y="386" width="252" height="252" rx="60" fill="${m.ghostFill}" stroke="${m.ghostStroke}" stroke-width="9"/></g>
  <g filter="${m.fx}" fill="${m.ink}" stroke="${m.ink}" stroke-width="32" stroke-linejoin="round"><path d="M262 270L432 270L432 330L322 330L322 694L432 694L432 754L262 754Z"/><path d="M762 270L592 270L592 330L702 330L702 694L592 694L592 754L762 754Z"/></g>
  </g>`;
}

export const GLYPHS = { spike, check, brackets };
export function glyphSvg(name, mode, size) {
  return `<svg viewBox="0 0 1024 1024" width="${size}" height="${size}" aria-hidden="true">${GLYPHS[name](MODES[mode])}</svg>`;
}
