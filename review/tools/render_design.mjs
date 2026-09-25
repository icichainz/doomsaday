#!/usr/bin/env node
// Renders the `design/*.dc.html` boards to static HTML and then to PNG with
// headless Chrome. The real design-canvas runtime is not available here, so
// this re-implements just enough of it: the component's `renderVals()`, the
// `{{hole}}` placeholders, `sc-for`, `sc-if` and `dc-import`.
//
//   node review/tools/render_design.mjs            # every board
//   node review/tools/render_design.mjs Main Logs  # only these
//
// Output: review/design/<Board>.png (and the intermediate HTML in
// review/design/_html/<Board>.html).

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const designDir = path.join(root, 'design');
const outDir = path.join(root, 'review', 'design');
const htmlDir = path.join(outDir, '_html');

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// ---------------------------------------------------------------- board file

/** Reads one board and pulls it apart into helmet, body and script. */
function readBoard(name) {
  const file = path.join(designDir, `${name}.dc.html`);
  const src = fs.readFileSync(file, 'utf8');

  const xdc = between(src, '<x-dc>', '</x-dc>');
  if (xdc == null) throw new Error(`${name}: no <x-dc> element`);

  const helmet = between(xdc, '<helmet>', '</helmet>') ?? '';
  const body = xdc.replace(/<helmet>[\s\S]*?<\/helmet>/, '');

  const scriptOpen = src.match(/<script type="text\/x-dc"[^>]*>/);
  if (!scriptOpen) throw new Error(`${name}: no x-dc script`);
  const scriptStart = scriptOpen.index + scriptOpen[0].length;
  const scriptEnd = src.indexOf('</script>', scriptStart);
  const code = src.slice(scriptStart, scriptEnd);

  const propsAttr = scriptOpen[0].match(/data-props='([^']*)'/);
  const propsSpec = propsAttr ? JSON.parse(decodeEntities(propsAttr[1])) : {};

  const preview = propsSpec.$preview ?? { width: 390, height: 844 };
  const defaults = {};
  for (const [key, spec] of Object.entries(propsSpec)) {
    if (key === '$preview') continue;
    defaults[key] = spec && typeof spec === 'object' ? spec.default : spec;
  }
  return { name, helmet, body, code, defaults, preview };
}

function between(s, open, close) {
  const a = s.indexOf(open);
  if (a < 0) return null;
  const b = s.indexOf(close, a + open.length);
  if (b < 0) return null;
  return s.slice(a + open.length, b);
}

function decodeEntities(s) {
  return s
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>');
}

// ------------------------------------------------------------------- DCLogic

class DCLogic {
  constructor(props) {
    this.props = props ?? {};
    this.state = null;
  }
  setState() {}
}

/** Runs the board's `renderVals()` with the defaults from `data-props`. */
function valuesOf(board, props) {
  const make = new Function('DCLogic', `${board.code}\nreturn Component;`);
  const Component = make(DCLogic);
  const instance = new Component({ ...board.defaults, ...props });
  return instance.renderVals() ?? {};
}

// ---------------------------------------------------------------- expression

/** `a.b.c` against a scope, or a `true`/`false` literal. */
function lookup(expr, scope) {
  const e = expr.trim();
  if (e === 'true') return true;
  if (e === 'false') return false;
  if (e === 'null') return null;
  if (/^-?\d+(\.\d+)?$/.test(e)) return Number(e);
  let value = scope;
  for (const part of e.split('.')) {
    if (value == null) return undefined;
    value = value[part];
  }
  return value;
}

const HOLE = /\{\{([^{}]*)\}\}/g;

/** Substitutes every `{{hole}}` in a run of text or in one attribute value. */
function fill(text, scope) {
  return text.replace(HOLE, (_, expr) => {
    const value = lookup(expr, scope);
    if (value == null || typeof value === 'function') return '';
    return String(value);
  });
}

function truthy(expr, scope) {
  const value = lookup(expr, scope);
  return !!value && value !== 'false';
}

// ------------------------------------------------------------------ rewriting

/** Drops event handlers and turns React-ish attributes into HTML ones. */
function normaliseTag(tag) {
  let out = tag
    .replace(/\s+on[A-Z][A-Za-z]*\s*=\s*"[^"]*"/g, '')
    .replace(/\s+on[A-Z][A-Za-z]*\s*=\s*'[^']*'/g, '')
    .replace(/\s+hint-[a-z-]+\s*=\s*"[^"]*"/g, '')
    .replace(/\bdefaultValue\s*=/g, 'value=');
  out = out.replace(/\s+defaultChecked\s*=\s*"([^"]*)"/g, (m, v) =>
    v === 'true' ? ' checked' : '',
  );
  return out;
}

/** Fills the holes in every tag and text run of a plain (non-block) chunk. */
function plain(html, scope) {
  // Tags first, so an attribute's value is filled and then normalised.
  return html.replace(/<[^>]+>/g, (tag) => normaliseTag(fill(tag, scope)))
    .replace(HOLE, (m, expr) => {
      const value = lookup(expr, scope);
      if (value == null || typeof value === 'function') return '';
      return escapeText(String(value));
    });
}

function escapeText(s) {
  return s.replace(/&(?![a-zA-Z#][a-zA-Z0-9]*;)/g, '&amp;').replace(/</g, '&lt;');
}

function parseAttrs(tagBody) {
  const attrs = {};
  const re = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*"([^"]*)"/g;
  let m;
  while ((m = re.exec(tagBody))) attrs[m[1]] = m[2];
  return attrs;
}

const BLOCKS = ['sc-for', 'sc-if', 'dc-import'];

/** The first block tag at or after `from`, with its matching close. */
function nextBlock(html, from) {
  let best = null;
  for (const tag of BLOCKS) {
    const i = html.indexOf(`<${tag}`, from);
    if (i >= 0 && (best == null || i < best.at)) best = { tag, at: i };
  }
  if (!best) return null;
  const { tag, at } = best;
  const openEnd = html.indexOf('>', at);
  const attrs = parseAttrs(html.slice(at + tag.length + 1, openEnd));
  // Matching close, counting nested tags of the same name.
  const close = `</${tag}>`;
  const open = `<${tag}`;
  let depth = 1;
  let i = openEnd + 1;
  while (depth > 0) {
    const nextOpen = html.indexOf(open, i);
    const nextClose = html.indexOf(close, i);
    if (nextClose < 0) throw new Error(`unclosed <${tag}>`);
    if (nextOpen >= 0 && nextOpen < nextClose) {
      depth++;
      i = nextOpen + open.length;
    } else {
      depth--;
      i = nextClose + close.length;
      if (depth === 0) {
        return {
          tag,
          attrs,
          start: at,
          innerStart: openEnd + 1,
          innerEnd: nextClose,
          end: i,
        };
      }
    }
  }
  return null;
}

/** Expands one board body against a scope, importing other boards as needed. */
function expand(html, scope, ctx) {
  let out = '';
  let cursor = 0;
  for (;;) {
    const block = nextBlock(html, cursor);
    if (!block) {
      out += plain(html.slice(cursor), scope);
      return out;
    }
    out += plain(html.slice(cursor, block.start), scope);
    const inner = html.slice(block.innerStart, block.innerEnd);

    if (block.tag === 'sc-for') {
      const listExpr = (block.attrs.list ?? '').replace(/^\{\{|\}\}$/g, '');
      const as = block.attrs.as ?? 'item';
      const list = lookup(listExpr, scope) ?? [];
      for (const [index, item] of [...list].entries()) {
        out += expand(inner, { ...scope, [as]: item, $index: index }, ctx);
      }
    } else if (block.tag === 'sc-if') {
      const valueExpr = (block.attrs.value ?? '').replace(/^\{\{|\}\}$/g, '');
      if (truthy(valueExpr, scope)) out += expand(inner, scope, ctx);
    } else {
      const name = block.attrs.name;
      const props = {};
      for (const [key, raw] of Object.entries(block.attrs)) {
        if (key === 'name' || key.startsWith('hint-')) continue;
        props[key] = fill(raw, scope);
      }
      out += renderBody(name, props, ctx);
    }
    cursor = block.end;
  }
}

/** The expanded body of one board, used both at the top and by dc-import. */
function renderBody(name, props, ctx) {
  if (ctx.stack.includes(name)) throw new Error(`dc-import cycle at ${name}`);
  ctx.stack.push(name);
  const board = readBoard(name);
  const scope = valuesOf(board, props);
  const body = expand(board.body, scope, ctx);
  ctx.stack.pop();
  return body;
}

/** One board as a standalone static HTML document. */
function renderPage(name) {
  const board = readBoard(name);
  const ctx = { stack: [] };
  const body = renderBody(name, {}, ctx);
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${name}</title>
${board.helmet.trim()}
<style>html,body{margin:0;padding:0}</style>
</head>
<body>
${body.trim()}
</body>
</html>
`;
  return { html, preview: board.preview };
}

// ---------------------------------------------------------------------- main

const names = process.argv.slice(2).length
  ? process.argv.slice(2).map((a) => a.replace(/\.dc\.html$/, ''))
  : fs
      .readdirSync(designDir)
      .filter((f) => f.endsWith('.dc.html'))
      .map((f) => f.replace(/\.dc\.html$/, ''))
      .sort();

fs.mkdirSync(htmlDir, { recursive: true });

let failures = 0;
for (const name of names) {
  try {
    const { html, preview } = renderPage(name);
    const left = html.match(/\{\{/g);
    if (left) console.warn(`  ! ${name}: ${left.length} unfilled {{ }}`);
    const htmlFile = path.join(htmlDir, `${name}.html`);
    fs.writeFileSync(htmlFile, html);
    const png = path.join(outDir, `${name}.png`);
    execFileSync(
      CHROME,
      [
        '--headless=new',
        '--hide-scrollbars',
        '--force-device-scale-factor=1',
        '--disable-gpu',
        `--window-size=${preview.width},${preview.height}`,
        '--virtual-time-budget=6000',
        `--screenshot=${png}`,
        `file://${htmlFile}`,
      ],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    );
    const size = fs.statSync(png).size;
    console.log(`  ok ${name} ${preview.width}x${preview.height} ${size} B`);
  } catch (error) {
    failures++;
    console.error(`  FAIL ${name}: ${error.message}`);
  }
}
process.exit(failures ? 1 : 0);
