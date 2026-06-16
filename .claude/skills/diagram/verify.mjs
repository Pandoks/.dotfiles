// Diagram verification harness. Usage: node verify.mjs <path-to-diagram.html>
// Extracts NODES + SC from a generated diagram, replays the engine's grid/layout math,
// and asserts: JS compiles · placeholders filled · node-vs-node no overlap · no arrow
// passes through a third node · every label clears every other label · flow.length ===
// steps.length per scenario · ret flags aligned · every grid node touched by an arrow.
// Exits non-zero and prints a report if anything fails.
//
// NOTE: this is a local, trusted-input check (your own generated file). It uses new
// Function()/eval to load the data block — safe here because the input is a file you
// just wrote, not untrusted user input.
import fs from 'fs';

const path = process.argv[2];
if (!path) { console.error('usage: node verify.mjs <file.html>'); process.exit(2); }
const html = fs.readFileSync(path, 'utf8');

const problems = [];
const ok = [];

// 1. placeholders filled
for (const ph of ['/*__NODES__*/', '/*__SCENARIOS__*/', '__TITLE__', '__BRAND__']) {
  if (html.includes(ph)) problems.push(`unfilled placeholder: ${ph}`);
}
if (!html.includes('/*__NODES__*/')) ok.push('placeholders filled');

// 2. JS compiles
const O = '<scr' + 'ipt>', C = '</scr' + 'ipt>';
const script = html.slice(html.indexOf(O) + O.length, html.lastIndexOf(C));
try { new Function('document', 'window', script.replace(/render\([^)]*\);?\s*$/, '')); ok.push('JS compiles'); }
catch (e) { problems.push('JS syntax error: ' + e.message); }

// 3. extract NODES, ZONE_LABELS, SC + layout metrics
function grab(a, b) { const i = html.indexOf(a); return i < 0 ? '' : html.slice(i, html.indexOf(b, i)); }
let NODES, SC, COLW, COLGAP, ROWH, ROWGAP;
try {
  const metrics = grab('const COLW=', 'const ZONE_COLORS=').split('\n').filter(l => l.includes('const COLW') || l.includes('COL_X') || l.includes('ROW_Y')).join('\n');
  // pull the NODES object (from "const NODES = {" to the "};" before the next function/const)
  function objBlock(start) {
    const si = html.indexOf(start); if (si < 0) return '';
    // find matching close brace by scanning
    let depth = 0, i = html.indexOf('{', si);
    for (; i < html.length; i++) { if (html[i] === '{') depth++; else if (html[i] === '}') { depth--; if (depth === 0) break; } }
    return html.slice(si, i + 1) + ';';
  }
  const sandbox = {};
  const code = objBlock('const NODES =') + '\n' + objBlock('const SC =') + '\n'
    + 'const COLW=560,COLGAP=320,ROWH=300,ROWGAP=120;'
    + 'globalThis.__N=NODES;globalThis.__S=SC;globalThis.__M={COLW,COLGAP,ROWH,ROWGAP};';
  new Function(code)();
  NODES = globalThis.__N; SC = globalThis.__S; ({ COLW, COLGAP, ROWH, ROWGAP } = globalThis.__M);
  ok.push(`parsed ${Object.keys(NODES).length} nodes, ${Object.keys(SC).length} scenarios`);
} catch (e) { problems.push('could not parse NODES/SC: ' + e.message); }

if (NODES && SC) {
  const COL_X = c => 120 + c * (COLW + COLGAP), ROW_Y = r => 220 + r * (ROWH + ROWGAP);
  let LIVE = {};
  const layout = grid => { LIVE = {}; for (const id in grid) { const [c, r] = grid[id]; const n = NODES[id]; if (!n) { problems.push(`grid references unknown node "${id}"`); continue; } LIVE[id] = { x: COL_X(c) + (COLW - n.w) / 2, y: ROW_Y(r) + (ROWH - n.h) / 2, w: n.w, h: n.h }; } };
  const port = (id, side, frac = 0.5) => { const n = LIVE[id]; if (!n) return { x: 0, y: 0 }; if (side === 'r') return { x: n.x + n.w, y: n.y + n.h * frac }; if (side === 'l') return { x: n.x, y: n.y + n.h * frac }; if (side === 't') return { x: n.x + n.w * frac, y: n.y }; return { x: n.x + n.w * frac, y: n.y + n.h }; };
  const pp = s => { const [id, side, frac] = s.split(':'); return port(id, side, frac !== undefined ? +frac : 0.5); };
  const bez = (a, cx, cy, b, t) => { const u = 1 - t; return { x: u * u * a.x + 2 * u * t * cx + t * t * b.x, y: u * u * a.y + 2 * u * t * cy + t * t * b.y }; };
  const PAD = 16, CHARW = 8.4;
  const NETLABEL = { http: 'HTTP', grpc: 'gRPC', pg: 'Postgres', resp: 'RESP', compute: 'compute' };
  const rectsOverlap = (a, b) => !(a.x + a.w + PAD <= b.x || b.x + b.w + PAD <= a.x || a.y + a.h + PAD <= b.y || b.y + b.h + PAD <= a.y);
  const rectHitsNode = r => { for (const id in LIVE) { const n = LIVE[id]; if (!(r.x + r.w <= n.x - 8 || n.x + n.w + 8 <= r.x || r.y + r.h <= n.y - 8 || n.y + n.h + 8 <= r.y)) return true; } return false; };
  const curveHitsNode = (a, b, bow, ex) => { const dx = b.x - a.x, dy = b.y - a.y, len = Math.hypot(dx, dy) || 1, px = -dy / len, py = dx / len; const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, cx = mx + px * bow, cy = my + py * bow; for (const id in LIVE) { if (ex.includes(id)) continue; const n = LIVE[id]; for (let t = 0.03; t <= 0.97; t += 0.02) { const p = bez(a, cx, cy, b, t); if (p.x > n.x - 6 && p.x < n.x + n.w + 6 && p.y > n.y - 6 && p.y < n.y + n.h + 6) return id; } } return null; };
  const resolve = flow => {
    const items = flow.map((f, i) => {
      const o = Object.assign({}, f[3]); const net = o.net || 'http', ep = o.ep || '';
      if (net === 'compute') { const node = LIVE[f[0].split(':')[0]]; const cxn = node ? node.x + node.w / 2 : 0, cyn = node ? node.y + node.h + 70 : 0; const t = (i + 1) + '. compute'; const w = Math.max(t.length + 1, ep.length) * CHARW + 28, h = ep ? 50 : 30; return { compute: true, lcx: cxn, lcy: cyn, w, h }; }
      const a = pp(f[0]), b = pp(f[1]), n = i + 1; const dx = b.x - a.x, dy = b.y - a.y, len = Math.hypot(dx, dy) || 1, px = -dy / len, py = dx / len; const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, bow = o.bow || 0, cx = mx + px * bow, cy = my + py * bow; const lp = bez(a, cx, cy, b, 0.5); const t = n + '. ' + (NETLABEL[net] || net); const w = Math.max(t.length + 1, ep.length) * CHARW + 28, h = ep ? 50 : 30; return { lcx: lp.x, lcy: lp.y, w, h };
    });
    const colliding = i => { const it = items[i], r = { x: it.lcx - it.w / 2, y: it.lcy - it.h / 2, w: it.w, h: it.h }; if (rectHitsNode(r)) return { hit: true, fx: 0, fy: -1 }; let fx = 0, fy = 0, hit = false; for (let j = 0; j < items.length; j++) { if (j === i) continue; const o = items[j], ro = { x: o.lcx - o.w / 2, y: o.lcy - o.h / 2, w: o.w, h: o.h }; if (rectsOverlap(r, ro)) { hit = true; let vx = it.lcx - o.lcx, vy = it.lcy - o.lcy; if (vx === 0 && vy === 0) vy = -1; const m = Math.hypot(vx, vy) || 1; fx += vx / m; fy += vy / m; } } return { hit, fx, fy }; };
    for (let p = 0; p < 400; p++) { let moved = false; for (let i = 0; i < items.length; i++) { const c = colliding(i); if (c.hit) { const m = Math.hypot(c.fx, c.fy) || 1; items[i].lcx += (c.fx / m) * 8; items[i].lcy += (c.fy / m) * 8 - 1; moved = true; } } if (!moved) break; }
    return items;
  };

  for (const key of Object.keys(SC)) {
    const sc = SC[key]; if (!sc.grid || !sc.flow || !sc.steps) { problems.push(`${key}: missing grid/flow/steps`); continue; }
    layout(sc.grid); const ids = Object.keys(sc.grid);
    // node overlaps
    for (let i = 0; i < ids.length; i++) for (let j = i + 1; j < ids.length; j++) { const A = LIVE[ids[i]], B = LIVE[ids[j]]; if (A && B && !(A.x + A.w <= B.x || B.x + B.w <= A.x || A.y + A.h <= B.y || B.y + B.h <= A.y)) problems.push(`${key}: nodes "${ids[i]}" & "${ids[j]}" overlap`); }
    // arrows through nodes
    sc.flow.forEach((f, i) => { if ((f[3] || {}).net === 'compute') return; const h = curveHitsNode(pp(f[0]), pp(f[1]), (f[3] || {}).bow || 0, [f[0].split(':')[0], f[1].split(':')[0]]); if (h) problems.push(`${key}: arrow ${i + 1} (${f[0].split(':')[0]}→${f[1].split(':')[0]}) passes through "${h}"`); });
    // labels
    const items = resolve(sc.flow);
    for (let i = 0; i < items.length; i++) { const it = items[i], r = { x: it.lcx - it.w / 2, y: it.lcy - it.h / 2, w: it.w, h: it.h }; if (!it.compute && rectHitsNode(r)) problems.push(`${key}: label ${i + 1} sits on a node`); for (let j = i + 1; j < items.length; j++) { const o = items[j], ro = { x: o.lcx - o.w / 2, y: o.lcy - o.h / 2, w: o.w, h: o.h }; if (rectsOverlap(r, ro)) problems.push(`${key}: labels ${i + 1} & ${j + 1} overlap`); } }
    // structural
    if (sc.flow.length !== sc.steps.length) problems.push(`${key}: flow has ${sc.flow.length} arrows but steps has ${sc.steps.length}`);
    sc.flow.forEach((f, i) => { const aret = (f[3] || {}).ret ? 1 : 0; const sret = sc.steps[i] ? (sc.steps[i][1] ? 1 : 0) : 0; if (aret !== sret) problems.push(`${key}: step ${i + 1} ret flag mismatch (arrow=${aret} step=${sret})`); });
    const touched = new Set(); sc.flow.forEach(f => { touched.add(f[0].split(':')[0]); touched.add(f[1].split(':')[0]); });
    ids.forEach(id => { if (!touched.has(id)) problems.push(`${key}: node "${id}" in grid but no arrow touches it`); });
  }
}

// 6. HEADLESS RENDER CHECK — catches RUNTIME crashes the static checks can't see
//    (e.g. a malformed arrow that throws during render and silently drops all arrows).
//    Loads the file in a real browser, switches through every tab, and fails on any
//    pageerror or any scenario that renders zero arrows when it declares flow steps.
//    Gracefully skips if Playwright isn't installed (static checks still run).
async function renderCheck() {
  let chromium;
  // Resolve playwright from the target file's repo (walk up for node_modules/playwright),
  // then fall back to a bare import. Skips gracefully if not found anywhere.
  const candidates = [];
  let dir = path.replace(/\/[^/]*$/, '');
  for (let i = 0; i < 8 && dir; i++) { candidates.push(dir + '/node_modules/playwright/index.js'); dir = dir.replace(/\/[^/]*$/, ''); }
  candidates.push('playwright');
  for (const c of candidates) {
    try {
      const url = c.startsWith('/') ? ('file://' + c) : c;
      const mod = await import(url);
      chromium = mod.chromium || (mod.default && mod.default.chromium);
      if (chromium) break;
    } catch { /* try next */ }
  }
  if (!chromium) return { skipped: true };
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));
    page.on('console', m => { if (m.type() === 'error') pageErrors.push('console: ' + m.text()); });
    await page.goto('file://' + (path.startsWith('/') ? path : process.cwd() + '/' + path), { waitUntil: 'networkidle' });
    await page.waitForTimeout(300);
    const tabs = await page.$$('#tabs button');
    const found = [];
    for (let t = 0; t < tabs.length; t++) {
      await tabs[t].click();
      await page.waitForTimeout(150);
      const r = await page.evaluate(() => ({
        title: document.getElementById('pTitle').textContent,
        flowItems: document.querySelectorAll('#flow .flowItem').length,
        steps: document.querySelectorAll('#pSteps .step').length,
      }));
      found.push(r);
    }
    await browser.close();
    return { skipped: false, pageErrors, tabs: found };
  } catch (e) { if (browser) await browser.close().catch(() => {}); return { skipped: false, error: e.message }; }
}

const rc = await renderCheck();
if (rc.skipped) {
  ok.push('render check skipped (Playwright not installed — static checks only)');
} else if (rc.error) {
  problems.push('render check failed to run: ' + rc.error);
} else {
  if (rc.pageErrors.length) rc.pageErrors.forEach(e => problems.push('RUNTIME ERROR during render: ' + e));
  // each scenario should render arrows if it has steps (>1 step implies flows exist)
  rc.tabs.forEach((tb, i) => {
    if (tb.steps > 0 && tb.flowItems === 0) problems.push(`scenario tab ${i} ("${tb.title || 'untitled'}") rendered 0 arrows despite ${tb.steps} steps — likely a malformed arrow crashed render`);
    if (!tb.title) problems.push(`scenario tab ${i} has an EMPTY title (render produced no title — scenario likely crashed)`);
  });
  if (!rc.pageErrors.length) ok.push(`render check passed (${rc.tabs.length} tabs rendered, no runtime errors)`);
}

console.log(`\n=== verify: ${path} ===`);
ok.forEach(o => console.log('  ✓ ' + o));
if (problems.length) { console.log('\n  PROBLEMS:'); problems.forEach(p => console.log('  ✗ ' + p)); console.log(`\n${problems.length} problem(s).`); process.exit(1); }
console.log('\n  ✓ ALL CHECKS PASSED — diagram is well-formed.');
