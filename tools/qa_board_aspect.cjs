// Geometry rig for the broadcast client's fit: how much of the embed box the
// composition actually uses, per BOARD SHAPE.
//
// Why this exists: `relayout()` is the only place that decides the stage's
// outer aspect, and its inputs are the board's native size plus the two
// reserved chrome bands. Both of those move — four-team games draw SQUARE
// rot90 maps (arena.nim `mapSymmetry: rot90`), and the bands re-measure with
// --hudscale — so the only honest way to check "does the board fill the box"
// is to run the REAL page's own relayout at a real container size and measure
// the resulting rectangles.
//
// It serves client/ over http (so art/ and chrome_common.js resolve exactly as
// they do from the native server) and splices a STUB BroadcastCore over the
// BROADCAST_CORE marker: the stub reproduces broadcast_core's `computeFit`
// verbatim, which is what makes the reported board rect trustworthy — a canvas
// whose element is wider than the map letterboxes INSIDE itself, and that
// letterbox is invisible to `getBoundingClientRect`. No wasm, no replay bytes,
// no GPU: this measures layout, and layout is all it claims to measure.
//
// Usage:
//   QA_DIR=<dir with node_modules/playwright> node tools/qa_board_aspect.cjs
// Optional: OUT_DIR (screenshots, default /tmp/qa_board_aspect).

const path = require('path');
const fs = require('fs');
const http = require('http');

const ROOT = process.cwd();
const QA = process.env.QA_DIR || path.join(ROOT, 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH =
  process.env.PLAYWRIGHT_BROWSERS_PATH || QA + '/ms-playwright';
const { chromium } = require(QA + '/node_modules/playwright');
const OUT = process.env.OUT_DIR || '/tmp/qa_board_aspect';

// The stub core. Same surface replay_broadcast.html consumes (start, ingest,
// sendCommand, clickMap, getTransform, setViewportFit, getPaceStats, stop) and
// the same contain-fit maths as broadcast_core.js `computeFit`, so getTransform
// reports the real drawn rect. `__qaBoard` is the native map size under test;
// `__qaFrame` pushes a state frame through the page's own onText path.
const STUB_CORE = `<script>
window.__qaBoard = { w: 1235, h: 659 };
window.BroadcastCore = { create: function (opts) {
  var scale = 1, offsetX = 0, offsetY = 0;
  function computeFit() {
    var c = opts.canvas;
    var dpr = window.devicePixelRatio || 1;
    var cssW = c.clientWidth || c.width / dpr;
    var cssH = c.clientHeight || c.height / dpr;
    scale = Math.min(cssW / window.__qaBoard.w, cssH / window.__qaBoard.h);
    offsetX = (cssW - window.__qaBoard.w * scale) / 2;
    offsetY = (cssH - window.__qaBoard.h * scale) / 2;
  }
  window.__qaFrame = function (state) { opts.onText(JSON.stringify(state)); };
  return {
    start: function () { computeFit(); opts.onStatus('open'); },
    ingest: function () {},
    sendCommand: function () {},
    clickMap: function () {},
    getTransform: function () {
      return { scale: scale, offsetX: offsetX, offsetY: offsetY,
               nativeW: window.__qaBoard.w, nativeH: window.__qaBoard.h };
    },
    setViewportFit: computeFit,
    getPaceStats: function () { return { enabled: false }; },
    stop: function () {}
  };
} };
</script>`;

// A four-team frame: the shape that draws a square map AND the widest chrome
// (four plates, two per side). Two-team frames are a strict subset.
function frame(teams) {
  const seatsPer = 4;
  const roster = [];
  let slot = 0;
  const names = ['richard-h', 'gradient-ghost', 'hivemind-7', 'cold-diffusion',
                 'paint-it-black', 'wetwork', 'nine-lives', 'basilisk'];
  teams.forEach((team, ti) => {
    for (let i = 0; i < seatsPer; i++) {
      roster.push({ s: slot, team, name: names[(ti * seatsPer + i) % names.length],
                    lives: 2, alive: true, hp: 3 });
      slot++;
    }
  });
  const tr = {};
  teams.forEach((team, i) => { tr[team] = { lives: 12 - i, flag: 'home', score: 0 }; });
  return { t: 1200, mt: 5000, ph: 'playing', sp: 1, teams: tr, roster,
           policies: {}, events: [] };
}

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
               '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml',
               '.woff2': 'font/woff2', '.json': 'application/json' };

function serve(clientDir) {
  const page = fs.readFileSync(path.join(clientDir, 'replay_broadcast.html'), 'utf8')
    .replace('<!-- CHROME_COMMON -->',
             '<script>' + fs.readFileSync(path.join(clientDir, 'chrome_common.js'), 'utf8') + '</script>')
    .replace('<!-- BROADCAST_CORE -->', STUB_CORE);
  const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/' || url === '/client/replay') {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(page);
      return;
    }
    const file = path.join(clientDir, url.replace(/^\/client\//, '').replace(/^\//, ''));
    if (!file.startsWith(clientDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404); res.end('nope'); return;
    }
    res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(fs.readFileSync(file));
  });
  return server;
}

// Container boxes, measured from the surfaces that actually embed this client.
// `watch_stage` is the /watch featured stage (web/softmax.com WatchTheater:
// `aspect-10/7`), at 1440x900 where it renders 748x517 — the box in the bug
// report. The rest are REPLAY_DESIGN §2's targets.
// BOXES=800x600,517x517 replaces the list, for answering "what would this
// client do if the embed were shaped differently" without editing the file.
const BOXES = process.env.BOXES
  ? process.env.BOXES.split(',').map((s) => {
      const [w, h] = s.trim().split('x').map(Number);
      return { label: w + 'x' + h, w, h };
    })
  : [
      { label: 'watch_stage_748x517', w: 748, h: 517 },
      { label: 'wide_1330x700', w: 1330, h: 700 },
      { label: 'featured_1040x694', w: 1040, h: 694 },
      { label: 'floor_640x360', w: 640, h: 360 },
      { label: 'portrait_390x780', w: 390, h: 780 },
    ];

// Board shapes the game actually serves. The square is the four-team rot90 draw
// (arena.nim: "4 draws a square rot90 corner/plus map"); the wide one is the
// hand-tuned default arena (sim_types.nim MapWidth x MapHeight).
const BOARDS = [
  { label: 'arena_1235x659', w: 1235, h: 659, teams: ['red', 'blue'] },
  { label: 'square_900x900', w: 900, h: 900, teams: ['red', 'blue', 'green', 'yellow'] },
];

async function measure(page, box, board) {
  await page.setViewportSize({ width: box.w, height: box.h });
  await page.evaluate((b) => { window.__qaBoard = { w: b.w, h: b.h }; }, board);
  await page.evaluate((f) => { window.__qaFrame(f); }, frame(board.teams));
  await page.evaluate(() => window.dispatchEvent(new Event('resize')));
  // The locker-room curtain fades out on the first frame; wait it out so the
  // screenshots show the chrome being measured rather than the loading art.
  await page.waitForTimeout(1400);
  return page.evaluate(() => {
    const r = (id) => {
      const el = document.getElementById(id);
      if (!el) return null;
      const b = el.getBoundingClientRect();
      return { x: Math.round(b.x), y: Math.round(b.y),
               w: Math.round(b.width), h: Math.round(b.height) };
    };
    const vp = r('viewport'), stage = r('stage'), canvas = r('board');
    // The canvas ELEMENT is not the drawn map: broadcast_core contain-fits the
    // map inside it, and that inner letterbox is what a rect can't see.
    const tr = window.__qaBoard;
    const el = document.getElementById('board');
    const cssW = el.clientWidth, cssH = el.clientHeight;
    const scale = Math.min(cssW / tr.w, cssH / tr.h);
    const drawn = { w: Math.round(tr.w * scale), h: Math.round(tr.h * scale) };
    return {
      box: { w: vp.w, h: vp.h },
      stage, canvas, drawn,
      scorebug: r('scorebug'), transport: r('transport'),
      // THE BLACK BARS, and only them: the box less the composition. Chrome is
      // not a bar — a scorebug column occupies width the same way the top band
      // occupies height. What the bug report is about is the space the stage
      // fails to claim, PLUS the canvas's own internal letterbox (the map drawn
      // smaller than its canvas element), which is invisible to a rect.
      barsW: (vp.w - stage.w) + (canvas.w - drawn.w),
      barsH: (vp.h - stage.h) + (canvas.h - drawn.h),
      column: document.getElementById('stage').classList.contains('sidebug'),
      hudscale: getComputedStyle(document.documentElement)
        .getPropertyValue('--hudscale').trim(),
    };
  });
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const server = serve(path.join(ROOT, 'client'));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const rows = [];
  for (const board of BOARDS) {
    for (const box of BOXES) {
      const page = await browser.newPage({ viewport: { width: box.w, height: box.h } });
      const errs = [];
      page.on('pageerror', (e) => errs.push(e.message.slice(0, 160)));
      page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text().slice(0, 160)); });
      await page.goto(base + '/client/replay', { waitUntil: 'load' });
      const m = await measure(page, box, board);
      const tag = board.label + '__' + box.label;
      await page.screenshot({ path: path.join(OUT, tag + '.png') });
      rows.push({ tag, ...m, errs: errs.length ? errs.slice(0, 3) : undefined });
      await page.close();
    }
  }
  await browser.close();
  server.close();
  for (const row of rows) {
    console.log(
      row.tag.padEnd(38),
      'box', String(row.box.w).padStart(4) + 'x' + row.box.h,
      '| play', String(row.drawn.w).padStart(4) + 'x' + row.drawn.h,
      '| BARS w', String(row.barsW).padStart(4), 'h', String(row.barsH).padStart(3),
      '| bug', String(row.scorebug.w).padStart(3) + 'x' + String(row.scorebug.h).padStart(3),
      '| transport h', String(row.transport.h).padStart(3),
      '| column', row.column ? 'yes' : ' no',
      '| hudscale', row.hudscale,
      row.errs ? '| ERR ' + row.errs.join(' ') : '');
  }
})().catch((e) => { console.error(e); process.exit(1); });
