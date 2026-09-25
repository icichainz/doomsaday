#!/usr/bin/env node
// Composes one side-by-side image per board and flavor:
// design on the left (or on top for the 1440-wide boards), app on the right
// (or below), each at 1x with a thin labelled header.
//
//   node review/tools/make_pairs.mjs            # both flavors
//   node review/tools/make_pairs.mjs free       # one flavor
//
// Output: review/pairs/<flavor>/<Board>.png
//
// No Pillow here, so the composition is a generated HTML page screenshotted
// with the same headless Chrome that renders the boards.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const designDir = path.join(root, 'review', 'design');
const appDir = path.join(root, 'review', 'app');
const pairsDir = path.join(root, 'review', 'pairs');
const workDir = path.join(pairsDir, '_html');

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const GAP = 16;
const HEADER = 22;

/** Boards captured for both flavors, plus the edition-only ones. */
const BOTH = [
  'Main',
  'PairAgent',
  'Dashboard',
  'Alerts',
  'Containers',
  'ContainerDetail',
  'ConfirmStop',
  'Logs',
  'Stacks',
  'Services',
  'Images',
  'Volumes',
  'Networks',
  'ServerSettings',
  'AppSettings',
  'Registries',
  'MainLight',
  'DashboardLight',
  'ContainersLight',
  'DesktopTablet',
  'DesktopOverview',
  'DesktopOverviewLight',
  'DesktopContainers',
  'DesktopConfirm',
  'DesktopResources',
  'DesktopFleet',
  'DesktopLogWall',
  'DesktopPreferences',
];
/** The desktop-tablet round: drawn against Pro, the palette also on Free. */
const DESKTOP_TABLET = [
  'DesktopStacks',
  'DesktopVolumes',
  'DesktopNetworks',
  'DesktopAlerts',
  'DesktopSettings',
  'DesktopRegistries',
  'DesktopPair',
  'DesktopPalette',
  'TabletContainers',
  'TabletStacks',
];
const DESKTOP_TABLET_PRO = DESKTOP_TABLET.flatMap((b) => [b, `${b}Light`]);
const ONLY = {
  free: ['ProLocked', 'ProLimit', 'DesktopPalette'],
  pro: ['ProBrand', ...DESKTOP_TABLET_PRO],
};

/** ProBrand pairs against the sidebar brand alone, so the app shot is cropped. */
const CROP = { ProBrand: { x: 0, y: 0, w: 264, h: 150 } };

/** Width and height straight out of the PNG's IHDR chunk. */
function pngSize(file) {
  const fd = fs.openSync(file, 'r');
  const head = Buffer.alloc(24);
  fs.readSync(fd, head, 0, 24, 0);
  fs.closeSync(fd);
  return { w: head.readUInt32BE(16), h: head.readUInt32BE(20) };
}

function panel(label, file, size, crop) {
  const { w, h } = crop ? { w: crop.w, h: crop.h } : size;
  const inner = crop
    ? `<div style="width:${w}px;height:${h}px;overflow:hidden;position:relative">
         <img src="file://${file}" style="position:absolute;left:${-crop.x}px;top:${-crop.y}px">
       </div>`
    : `<img src="file://${file}" width="${w}" height="${h}" style="display:block">`;
  return `<div style="width:${w}px">
    <div style="height:${HEADER}px;line-height:${HEADER}px;font:600 11px/${HEADER}px ui-monospace,Menlo,monospace;letter-spacing:.9px;color:#9AAAB1">${label}</div>
    <div style="border:1px solid #2A363C">${inner}</div>
  </div>`;
}

function compose(board, flavor) {
  const designFile = path.join(designDir, `${board}.png`);
  const appFile = path.join(appDir, flavor, `${board}.png`);
  if (!fs.existsSync(designFile)) return `no design/${board}.png`;
  if (!fs.existsSync(appFile)) return `no app/${flavor}/${board}.png`;

  const crop = CROP[board];
  const d = pngSize(designFile);
  const a = crop ? { w: crop.w, h: crop.h } : pngSize(appFile);
  // 1440-wide boards stack, everything narrower sits side by side.
  const stack = d.w >= 1100;

  const left = panel('DESIGN', designFile, d);
  const right = panel(`APP · ${flavor}`, appFile, a, crop);

  const width = stack
    ? GAP * 2 + Math.max(d.w, a.w) + 2
    : GAP * 3 + d.w + a.w + 4;
  const height = stack
    ? GAP * 3 + (HEADER + d.h + 2) + (HEADER + a.h + 2)
    : GAP * 2 + HEADER + Math.max(d.h, a.h) + 2;

  const html = `<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;background:#0A0F11}</style></head>
<body><div style="display:flex;flex-direction:${stack ? 'column' : 'row'};gap:${GAP}px;padding:${GAP}px;width:max-content">
${left}
${right}
</div></body></html>`;

  fs.mkdirSync(workDir, { recursive: true });
  const htmlFile = path.join(workDir, `${flavor}-${board}.html`);
  fs.writeFileSync(htmlFile, html);

  const out = path.join(pairsDir, flavor, `${board}.png`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  execFileSync(
    CHROME,
    [
      '--headless=new',
      '--hide-scrollbars',
      '--force-device-scale-factor=1',
      '--disable-gpu',
      '--allow-file-access-from-files',
      `--window-size=${width},${height}`,
      '--virtual-time-budget=3000',
      `--screenshot=${out}`,
      `file://${htmlFile}`,
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  return null;
}

const flavors = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['free', 'pro'];

let bad = 0;
for (const flavor of flavors) {
  for (const board of [...BOTH, ...(ONLY[flavor] ?? [])]) {
    const problem = compose(board, flavor);
    if (problem) {
      bad++;
      console.error(`  SKIP ${flavor}/${board}: ${problem}`);
    } else {
      console.log(`  ok ${flavor}/${board}`);
    }
  }
}
process.exit(bad ? 1 : 0);
