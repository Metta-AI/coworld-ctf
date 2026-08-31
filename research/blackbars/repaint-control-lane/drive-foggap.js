// Direct interpolation-state instrumentation, NO screenshots. Confirms (or
// refutes) the fog-run-glide-desync mechanism on ground truth, not pixels.
//
// Hooks updateInterpolation() in the page's own JS realm (the exact
// function that computes dispX/dispY via Math.round(lerp(from,x,t)) for
// every object, fog runs included -- see client/player_client.html ~L616).
// After each real call, scans `objects` for layer===FOG_LAYER_ID(4)
// entries, builds each run's rect from its sprite's width/height, finds
// pairs that are ADJACENT in the AUTHORITATIVE (server-sent) x/y/w/h --
// i.e. should be touching with zero gap -- and checks whether their
// CURRENT interpolated dispX/dispY are still touching. A nonzero gap in
// display space between two runs whose target rects are exactly adjacent
// is the mechanism: a transient exposure of the map layer underneath.
//
// Runs at real rAF cadence inside the page (no CDP round-trip per sample),
// while a real aim sweep is driven continuously from Node. Log is
// accumulated in-page and pulled once at the end.

const { chromium } = require('playwright');
const fs = require('fs');

const BASE = 'http://127.0.0.1:27932';
const FOG_LAYER_ID = 4;
function log(...a) { console.log(new Date().toISOString(), ...a); }

async function main() {
  const browser = await chromium.launch({ headless: false, args: ['--use-angle=metal', '--window-size=1600,1000'] });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  page.on('console', (msg) => log('PAGE-CONSOLE>', msg.type(), msg.text()));
  page.on('pageerror', (err) => log('PAGE-ERROR>', err.message));
  const url = `${BASE}/client/takeover?slot=7&token=0xBADA55_7&name=foggap`;
  log('goto', url);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  log('goto done, url=', page.url());
  if (!page.url().startsWith(BASE)) throw new Error('REFUSING: not on local rig');

  const frameEl = await page.waitForSelector('#field', { timeout: 30000 });
  log('found #field iframe');
  const frame = await frameEl.contentFrame();
  log('got contentFrame, src=', frame.url());
  await frame.waitForFunction(() => typeof mapW !== 'undefined' && mapW > 0, null, { timeout: 30000 });
  log('mapW ready');
  await frame.waitForFunction(() => !!selfPos, null, { timeout: 90000 });
  log('selfPos ready');
  await frame.evaluate(() => { if (cameraModeIndex !== 1) cycleCameraMode(1); });
  log('seated, camera forced to fitvision, selfPos=', JSON.stringify(await frame.evaluate(() => selfPos)));

  await frame.evaluate((FOG_LAYER_ID) => {
    window.__fogGapLog = [];
    window.__fogTickCount = 0;
    window.__origUpdateInterpolationFG = window.__origUpdateInterpolationFG || updateInterpolation;
    window.updateInterpolation = function (now) {
      const animating = window.__origUpdateInterpolationFG(now);
      window.__fogTickCount++;
      const fogObjs = [];
      for (const o of objects.values()) {
        if (o.layer !== FOG_LAYER_ID) continue;
        const sprite = sprites.get(o.spriteId);
        if (!sprite) continue;
        fogObjs.push({ id: o.id, x: o.x, y: o.y, dispX: o.dispX, dispY: o.dispY, w: sprite.width, h: sprite.height, gliding: movingObjects.has(o) });
      }
      let maxAbsGapH = 0, maxAbsGapV = 0, nGapEventsH = 0, nGapEventsV = 0, nPairsH = 0, nPairsV = 0;
      const events = [];
      for (let i = 0; i < fogObjs.length; i++) {
        for (let j = 0; j < fogObjs.length; j++) {
          if (i === j) continue;
          const A = fogObjs[i], B = fogObjs[j];
          // horizontal adjacency in TARGET space: B directly right of A, same row
          if (B.y === A.y && B.x === A.x + A.w) {
            nPairsH++;
            const gap = B.dispX - (A.dispX + A.w);
            if (gap !== 0) {
              nGapEventsH++;
              if (Math.abs(gap) > Math.abs(maxAbsGapH)) maxAbsGapH = gap;
              events.push({ kind: 'H', a: A.id, b: B.id, gap });
            }
          }
          // vertical adjacency in TARGET space: B directly below A, overlapping x-range
          if (B.y === A.y + A.h && !(B.x + B.w <= A.x || A.x + A.w <= B.x)) {
            nPairsV++;
            const gap = B.dispY - (A.dispY + A.h);
            if (gap !== 0) {
              nGapEventsV++;
              if (Math.abs(gap) > Math.abs(maxAbsGapV)) maxAbsGapV = gap;
              events.push({ kind: 'V', a: A.id, b: B.id, gap });
            }
          }
        }
      }
      if (nGapEventsH > 0 || nGapEventsV > 0) {
        window.__fogGapLog.push({
          t: now, nFog: fogObjs.length, nPairsH, nPairsV,
          nGapEventsH, nGapEventsV, maxAbsGapH, maxAbsGapV,
          events: events.slice(0, 8),
        });
      }
      return animating;
    };
  }, FOG_LAYER_ID);
  log('hooked updateInterpolation for fog-gap scanning');

  async function dispatchMouseMove(mx, my) {
    try {
      await frame.evaluate(({ mx, my }) => {
        const r = c.getBoundingClientRect();
        window.dispatchEvent(new MouseEvent('mousemove', { clientX: r.left + mx, clientY: r.top + my, bubbles: true }));
      }, { mx, my });
    } catch (e) { /* best-effort */ }
  }

  const { iw, ih } = await frame.evaluate(() => ({ iw: innerWidth, ih: innerHeight }));
  const cx = iw / 2, cy = ih / 2, r = Math.min(iw, ih) / 3;

  const DURATION_MS = parseInt(process.env.BB_DURATION_MS || '20000', 10);
  const t0 = Date.now();
  let ang = 0;
  log('starting aim sweep for', DURATION_MS, 'ms (zero WASD, mouse only)');
  let lastCheckpoint = Date.now();
  while (Date.now() - t0 < DURATION_MS) {
    try {
      ang += (2 * Math.PI) / 25;
      await dispatchMouseMove(cx + r * Math.cos(ang), cy + r * Math.sin(ang));
      await page.waitForTimeout(16); // ~60Hz input rate -- fast, continuous aim churn
      if (Date.now() - lastCheckpoint > 4000) {
        lastCheckpoint = Date.now();
        const partial = await frame.evaluate(() => ({ tickCount: window.__fogTickCount, gapLog: window.__fogGapLog }));
        fs.writeFileSync('/private/tmp/bb2/foggap_aimsweep_partial.json', JSON.stringify(partial));
        log('checkpoint: ticks=', partial.tickCount, 'gapEvents=', partial.gapLog.length);
      }
    } catch (e) {
      log('sweep tick error (continuing):', e.message);
      if (page.isClosed()) { log('page closed, aborting sweep loop early'); break; }
    }
  }

  let result;
  try {
    result = await frame.evaluate(() => ({
      tickCount: window.__fogTickCount,
      gapLog: window.__fogGapLog,
    }));
  } catch (e) {
    log('FATAL: could not retrieve log at end:', e.message);
    result = { tickCount: -1, gapLog: [], error: e.message };
  }
  log('DONE. total interpolation ticks:', result.tickCount, 'ticks with a gap event:', result.gapLog.length);
  fs.writeFileSync('/private/tmp/bb2/foggap_aimsweep.json', JSON.stringify(result, null, 2));
  fs.writeFileSync('/tmp/foggap_done.txt', 'done ' + new Date().toISOString());
  await browser.close();
}

main().catch((e) => { console.error('FATAL', e); fs.writeFileSync('/tmp/foggap_done.txt', 'FATAL ' + e.stack); process.exit(1); });
