// HANDS audit regression (.proof/cycle1_hands.json, criterion 3): "The FIRST
// click after page load did not register (0 frames) -- see REGRESSIONS."
// Repro steps are the audit's own: load client/player_client.html FRESH (a
// direct /client/player connection is the fresh-match path a real human
// takes -- owner ruling 9/6, "you begin with the match, not takeover" -- no
// iframe, no takeover.html), then perform exactly ONE deliberate left-click
// on the canvas and check the wire for the attack-bit (0x20) edge pulse
// fireBit() emits (client/player_controls.js:147-154).
//
// Root cause (see client/player_client.html:1051-1060): controlsTick() --
// the only place that reads the mouse-button level and turns it into a
// fire edge -- runs exclusively off an INCOMING server frame
// (w.onmessage -> parseSprite -> sawFrame, player_client.html:891-916).
// Before the very first frame ever lands there is no tick to sample
// anything. A real click's mousedown+mouseup pair is often faster than
// that first round-trip, so `lmb` can flip true then false again with
// zero ticks in between -- the whole press vanishes. Held keys (WASD)
// don't show this because they are usually still down when the first
// tick finally runs; a tap-click usually is not.
//
// This spec is a plain Node script driven with `node`, not @playwright/test
// (no test runner is wired into this repo yet). Needs the `playwright` npm
// package on NODE_PATH/require resolution and a local field to point at:
//   nim c -d:release --hints:off --path:src -o:bin/ctf-server src/ctf.nim
//   COGAME_HOST=127.0.0.1 COGAME_PORT=7419 \
//     COGAME_CONFIG_URI="file://$PWD/config.firstclick.json" ./bin/ctf-server &
//   node tests/playwright/first_click_fires.spec.js http://127.0.0.1:7419
// config.firstclick.json is a solo (minPlayers=1) fresh match: the seat is
// live from tick 0 the instant this page's socket opens -- no takeover, no
// bots, so there is nothing to interfere with the pre-first-frame race this
// spec targets. Exits 0 on PASS (attack bit observed after the single
// click), 1 on FAIL.
const { chromium } = require('playwright');

const BASE = process.argv[2] || 'http://127.0.0.1:7419';
const URL = BASE + '/client/player?token=0xBADA55_0&reconnect=0';

function decodeFrame(payload) {
  let buf;
  if (Buffer.isBuffer(payload)) buf = payload;
  else if (typeof payload === 'string') { try { buf = Buffer.from(payload, 'base64'); } catch { buf = Buffer.from(payload, 'binary'); } }
  else buf = Buffer.from([]);
  return Array.from(buf);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });

  const sentFrames = [];
  page.on('websocket', (ws) => {
    if (!/\/player/.test(ws.url())) return;
    ws.on('framesent', (f) => sentFrames.push(decodeFrame(f.payload)));
  });

  // Load fresh, then fire ONE click on the canvas as fast as the driver can
  // manage -- no settle/seated wait first. That is the exact race the audit
  // hit: a real user's first shot is not polite enough to wait for a frame.
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#c', { state: 'attached' });
  const box = await page.evaluate(() => {
    const r = document.getElementById('c').getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  });
  await page.mouse.move(box.x, box.y);
  await page.mouse.down();
  await page.mouse.up();

  // Give the match a couple of seconds to seat + tick so a wire frame
  // carrying the edge (if any) has time to actually go out.
  await page.waitForTimeout(2500);

  const attackBitSeen = sentFrames.some((b) => b.length >= 2 && (b[1] & 0x20));
  console.log(JSON.stringify({ url: URL, framesSent: sentFrames.length, attackBitSeen, sample: sentFrames.slice(0, 12) }, null, 2));
  await browser.close();
  process.exit(attackBitSeen ? 0 : 1);
})();
