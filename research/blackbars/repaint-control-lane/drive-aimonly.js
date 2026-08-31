// AIM-ONLY, camera-completely-static experiment -- the cell Maxwell's own
// observation says is the real trigger ("the banding only affects the fog
// of war shadowed areas... it updates every tick when i aim or move").
// Every PRIOR experiment (this session's motion/repaint_static arms, and
// the whole prior investigation) varied movement; nobody isolated aim.
//
// Design: seat a human takeover, press ZERO movement keys for the entire
// capture (selfPos never changes -> camera transform target never changes
// -> c.style.transform naturally stays static, verified per-frame, not
// forced/patched this time) while continuously sweeping the mouse in a
// fast circle so the vision cone -- and therefore the fog layer (id=4,
// confirmed live via layers.get(4), same MapLayerType/ZoomableLayerFlag as
// the map layer, drawn into the one visible canvas via the same
// x.drawImage(layer.canvas,0,0) path) -- recomputes every tick.
//
// N_TARGET real page.screenshot() frames, own local rig only
// (127.0.0.1:27931). Classify with the same validated classify_burst.py
// (0% FN / 5.6% FP on the hand-labelled calibration set, top/bottom-margin
// screenshot-seam bug already fixed).

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = 'http://127.0.0.1:27931';
const OUT_DIR = '/private/tmp/bb2/capture/aim_only';
fs.mkdirSync(OUT_DIR, { recursive: true });
const N_TARGET = parseInt(process.env.BB_N || '700', 10);

function log(...a) { console.log(new Date().toISOString(), ...a); }

async function main() {
  const browser = await chromium.launch({ headless: false, args: ['--use-angle=metal', '--window-size=1600,1000'] });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  page.on('console', (msg) => { if (/error/i.test(msg.type())) log('PAGE-ERR>', msg.text()); });

  const url = `${BASE}/client/takeover?slot=4&token=0xBADA55_4&name=bb-aimonly`;
  log('goto', url);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (!page.url().startsWith(BASE)) throw new Error('REFUSING: not on local rig');

  const frameEl = await page.waitForSelector('#field', { timeout: 30000 });
  const frame = await frameEl.contentFrame();
  await frame.waitForFunction(() => typeof mapW !== 'undefined' && mapW > 0, null, { timeout: 30000 });
  await frame.waitForFunction(() => !!selfPos, null, { timeout: 45000 });
  await frame.evaluate(() => { if (cameraModeIndex !== 1) cycleCameraMode(1); });
  await page.waitForTimeout(200);
  log('seated, camera forced to fitvision, selfPos=', JSON.stringify(await frame.evaluate(() => selfPos)));

  async function dispatchMouseMove(mx, my) {
    try {
      await frame.evaluate(({ mx, my }) => {
        const r = c.getBoundingClientRect();
        window.dispatchEvent(new MouseEvent('mousemove', { clientX: r.left + mx, clientY: r.top + my, bubbles: true }));
      }, { mx, my });
    } catch (e) { /* best-effort across transient match-end blips */ }
  }

  const { iw, ih } = await frame.evaluate(() => ({ iw: innerWidth, ih: innerHeight }));
  const cx = iw / 2, cy = ih / 2, r = Math.min(iw, ih) / 3;

  const records = [];
  let consecutiveErrors = 0;
  const t0 = Date.now();
  let ang = 0;
  for (let i = 0; i < N_TARGET; i++) {
    // fast sweep: full revolution roughly every ~25 captured frames, i.e.
    // aim direction changes noticeably every single tick, matching "it
    // updates every tick when i aim".
    ang += (2 * Math.PI) / 25;
    await dispatchMouseMove(cx + r * Math.cos(ang), cy + r * Math.sin(ang));
    try {
      const box = await frameEl.boundingBox();
      const cam = await frame.evaluate(() => ({
        camScale, camX, camY, transform: c.style.transform,
        selfPos: selfPos ? { x: selfPos.x, y: selfPos.y } : null,
        innerWidth, innerHeight,
      }));
      const fname = `f${String(i).padStart(4, '0')}.png`;
      await page.screenshot({ path: path.join(OUT_DIR, fname), clip: box });
      records.push({ i, file: fname, ...cam });
      consecutiveErrors = 0;
    } catch (e) {
      log('frame', i, 'ERROR (skipping):', e.message);
      records.push({ i, file: null, error: e.message });
      consecutiveErrors++;
      if (consecutiveErrors > 40) { log('ABORTING: 40 consecutive errors'); break; }
      await page.waitForTimeout(100);
    }
    if (i % 100 === 0) log('frame', i, 'of', N_TARGET, 'elapsed_s', ((Date.now() - t0) / 1000).toFixed(1));
  }

  fs.writeFileSync(path.join(OUT_DIR, 'records.json'), JSON.stringify(records, null, 0));
  const dt = (Date.now() - t0) / 1000;
  const distinctTransforms = new Set(records.map(r => r.transform)).size;
  const selfPosXs = records.map(r => r.selfPos && r.selfPos.x).filter(v => v != null);
  const selfPosYs = records.map(r => r.selfPos && r.selfPos.y).filter(v => v != null);
  const summary = {
    label: 'aim_only', n: N_TARGET, seconds: dt, fps: N_TARGET / dt,
    distinctTransforms,
    selfPosXRange: selfPosXs.length ? Math.max(...selfPosXs) - Math.min(...selfPosXs) : null,
    selfPosYRange: selfPosYs.length ? Math.max(...selfPosYs) - Math.min(...selfPosYs) : null,
  };
  log('DONE', JSON.stringify(summary));
  fs.writeFileSync(path.join(OUT_DIR, 'sanity.json'), JSON.stringify(summary, null, 2));
  fs.writeFileSync('/tmp/blackbars_aimonly_done.txt', 'done ' + new Date().toISOString());
  await browser.close();
}

main().catch((e) => {
  console.error('FATAL', e);
  fs.writeFileSync('/tmp/blackbars_aimonly_done.txt', 'FATAL ' + (e && e.stack || e));
  process.exit(1);
});
