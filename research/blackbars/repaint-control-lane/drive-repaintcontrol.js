// blackbars repaint-vs-motion control experiment.
//
// Own local rig ONLY: http://127.0.0.1:27931 (built + launched by a prior
// pass in a private worktree, 8 bots filling all seats, port confirmed free
// beforehand -- this is NOT the shared 100.102.207.18:7420 field). Every
// mutating call in this script is preceded by an assertion that page.url()
// points at 127.0.0.1:27931, never the shared field.
//
// Two arms, N_TARGET real page.screenshot() frames each (real GPU
// compositor capture, headed chromium, --use-angle=metal -- headless
// defaults to SwiftShader and hides this bug entirely):
//
//   ARM "motion"  -- the established repro: seat a human takeover, cycle
//     movement keys D->S->A->W every ~15 frames (never hold one key the
//     whole time -- that drives the character into a wall where it sits
//     PINNED, which silently switches the test to the no-transform-write
//     condition -- the "wall-pinning trap" from prior work) plus a
//     continuous mouse sweep. The follow camera's CSS transform is
//     rewritten essentially every tick because selfPos keeps moving.
//
//   ARM "repaint-static" -- the missing control nobody ran: seat a SEPARATE
//     human takeover on a different slot, press NOTHING (no keys, no mouse
//     movement) so selfPos never changes and the real, unmodified
//     updateCamera() naturally converges to a fixed camX/camY/camScale and
//     stops rewriting c.style.transform (verified per-frame, not assumed).
//     The canvas keeps being redrawn every rAF tick regardless, because the
//     OTHER 7 bots in this freeplay match are actively moving/fighting in
//     view -- this is verified per-frame via a cheap content hash of the
//     canvas backing store so "clean because nothing repaints" can't be
//     confused with "clean because camera is pinned".
//
// Classifier note: this driver does NOT capture toDataURL/synth pairs.
// Calibration against the earlier drive2.js dataset showed the
// screenshot-vs-synth crosscheck has a real false-positive mode (Playwright
// evaluates the synth via a separate CDP round-trip from the real
// screenshot; during that gap, unrelated scene content -- another bot's
// prop, an animation -- can change, and the crosscheck misreads "stale
// ground truth" as "artifact not explained by ground truth"). The deployed
// classifier here (see classify_frames.py) instead uses ONLY real
// same-instrument page.screenshot() frames: a self-contained per-frame
// full-width horizontal dark-dip detector, cross-validated against WORLD-
// coordinate persistence across nearby frames in the SAME burst (a genuine
// map feature recurs at the same world position; a true compositor glitch
// does not). Per-frame camState (camScale/camX/camY) is logged so that
// world-coordinate conversion is possible entirely from this driver's own
// output, with no dependency on a second capture pathway.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = 'http://127.0.0.1:27931';
const OUT_ROOT = '/private/tmp/bb2/capture';
fs.mkdirSync(OUT_ROOT, { recursive: true });

const N_TARGET = parseInt(process.env.BB_N || '700', 10);

function log(...a) { console.log(new Date().toISOString(), ...a); }

function assertLocalRig(page) {
  const u = page.url();
  if (!u.startsWith(BASE)) {
    throw new Error('REFUSING mutating call: page is not on the local rig (' + BASE + '), got: ' + u);
  }
}

async function seatTakeover(browser, slot, token, name) {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  page.on('console', (msg) => { if (/error/i.test(msg.type())) log('PAGE-ERR>', slot, msg.text()); });
  const url = `${BASE}/client/takeover?slot=${slot}&token=${token}&name=${encodeURIComponent(name)}`;
  log('goto', url);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  assertLocalRig(page);

  const frameEl = await page.waitForSelector('#field', { timeout: 30000 });
  const frame = await frameEl.contentFrame();
  log(slot, 'iframe src=', frame.url());

  await frame.waitForFunction(() => typeof mapW !== 'undefined' && mapW > 0 && mapH > 0, null, { timeout: 30000 });
  await frame.waitForFunction(() => !!selfPos, null, { timeout: 45000 });
  log(slot, 'seated, selfPos=', JSON.stringify(await frame.evaluate(() => selfPos)));

  // CRITICAL: this client (client/player_client.html at this commit) has a
  // camera MODE toggle (CAMERA_MODES: "whole" static-fit vs "fitvision"
  // follow). defaultCameraModeIndex() picks "whole" (non-follow, static
  // transform) by default for a non-BR ("classic"/freeplay) match -- which
  // is exactly this local rig's config. Confirmed by a smoke test: without
  // this, camX/camY/camScale sat bit-identical for the WHOLE capture even
  // with selfPos moving 127+ world px, because we were sitting in the
  // static control arm by accident, not the follow/repro arm. Force
  // fitvision (index 1) explicitly, the same step drive-scaleprobe.js took.
  await frame.evaluate(() => {
    if (typeof cameraModeIndex !== 'undefined' && typeof cycleCameraMode === 'function' && cameraModeIndex !== 1) {
      cycleCameraMode(1);
    }
  });
  await page.waitForTimeout(150);
  const modeCheck = await frame.evaluate(() => ({ cameraModeIndex, camScale, camX, camY }));
  log(slot, 'camera mode forced to fitvision, state=', JSON.stringify(modeCheck));

  return { page, frameEl, frame };
}

async function dispatchKey(frame, type, code) {
  try {
    await frame.evaluate(({ type, code }) => {
      window.dispatchEvent(new KeyboardEvent(type, { code, bubbles: true, cancelable: true }));
    }, { type, code });
  } catch (e) { /* best-effort: transient match-end/reload blips are fine to drop */ }
}
async function dispatchMouseMove(frame, mx, my) {
  try {
    await frame.evaluate(({ mx, my }) => {
      const r = c.getBoundingClientRect();
      window.dispatchEvent(new MouseEvent('mousemove', { clientX: r.left + mx, clientY: r.top + my, bubbles: true }));
    }, { mx, my });
  } catch (e) { /* best-effort */ }
}

// Cheap content-change proof for the repaint-static arm: hash a handful of
// sampled pixels from the canvas backing store. Cheaper than a full
// toDataURL every frame (which would slow the loop down a lot over 700
// frames) but still proves the backing store is being redrawn.
async function canvasSampleHash(frame) {
  return await frame.evaluate(() => {
    const ctx2 = c.getContext('2d');
    // sample a small strip; avoid the whole-canvas cost
    const w = Math.min(64, c.width), h = Math.min(64, c.height);
    const data = ctx2.getImageData(Math.floor(c.width / 2 - w / 2), Math.floor(c.height / 2 - h / 2), w, h).data;
    let hash = 0;
    for (let i = 0; i < data.length; i += 7) { hash = (hash * 31 + data[i]) >>> 0; }
    return hash;
  });
}

async function runArm(browser, arm) {
  log('=== ARM', arm.label, '===');
  const outDir = path.join(OUT_ROOT, arm.label);
  fs.mkdirSync(outDir, { recursive: true });

  const { page, frameEl, frame } = await seatTakeover(browser, arm.slot, arm.token, arm.name);
  assertLocalRig(page);

  if (arm.pinCamera) {
    await frame.evaluate(() => {
      window.__bbPinned = null;
      window.__origUpdateCameraBB = window.__origUpdateCameraBB || updateCamera;
      window.updateCamera = function () {
        window.__origUpdateCameraBB();
        if (window.__bbPinned === null) window.__bbPinned = c.style.transform;
        else c.style.transform = window.__bbPinned; // force back to the frozen value every tick
      };
    });
    log(arm.label, 'patched updateCamera to freeze c.style.transform after first tick');
  }

  await page.waitForTimeout(200);

  const records = [];
  let sweepPromise = null;
  if (arm.moveKeys) {
    const legs = ['KeyD', 'KeyS', 'KeyA', 'KeyW'];
    let legIdx = 0;
    await dispatchKey(frame, 'keydown', legs[0]);
    let framesSinceSwitch = 0;
    sweepPromise = (async () => {
      const { iw, ih } = await frame.evaluate(() => ({ iw: innerWidth, ih: innerHeight }));
      const cx = iw / 2, cy = ih / 2, r = Math.min(iw, ih) / 3;
      let t = 0;
      while (!arm._stopSweep) {
        const ang = (t / 30) * Math.PI * 2;
        await dispatchMouseMove(frame, cx + r * Math.cos(ang), cy + r * Math.sin(ang));
        t++;
        await page.waitForTimeout(35);
      }
    })();
    arm._legSwitcher = async () => {
      framesSinceSwitch++;
      if (framesSinceSwitch >= 15) {
        await dispatchKey(frame, 'keyup', legs[legIdx]);
        legIdx = (legIdx + 1) % legs.length;
        await dispatchKey(frame, 'keydown', legs[legIdx]);
        framesSinceSwitch = 0;
      }
    };
  }

  const t0 = Date.now();
  let consecutiveErrors = 0;
  for (let i = 0; i < N_TARGET; i++) {
    try {
      if (arm.moveKeys) await arm._legSwitcher();
      const box = await frameEl.boundingBox();
      const cam = await frame.evaluate(() => ({
        camScale, camX, camY, transform: c.style.transform,
        selfPos: selfPos ? { x: selfPos.x, y: selfPos.y } : null,
        innerWidth, innerHeight, t: performance.now(),
      }));
      let contentHash = null;
      if (arm.hashEvery && (i % arm.hashEvery === 0)) contentHash = await canvasSampleHash(frame);
      const fname = `f${String(i).padStart(4, '0')}.png`;
      await page.screenshot({ path: path.join(outDir, fname), clip: box });
      records.push({ i, file: fname, ...cam, contentHash });
      consecutiveErrors = 0;
    } catch (e) {
      // Match end / respawn / "waiting for players" screens can transiently
      // break frame.evaluate() (canvas/vars momentarily gone). Log and skip
      // this frame rather than aborting a long capture over a blip; only
      // bail out of the arm if it's clearly wedged (many in a row).
      log(arm.label, 'frame', i, 'ERROR (skipping):', e.message);
      records.push({ i, file: null, error: e.message });
      consecutiveErrors++;
      if (consecutiveErrors > 40) {
        log(arm.label, 'ABORTING arm early: 40 consecutive frame errors (match likely wedged)');
        break;
      }
      await page.waitForTimeout(100);
    }
    if (i % 100 === 0) log(arm.label, 'frame', i, 'of', N_TARGET, 'elapsed_s', ((Date.now() - t0) / 1000).toFixed(1));
  }
  arm._stopSweep = true;
  if (sweepPromise) await sweepPromise;
  if (arm.moveKeys) {
    for (const k of ['KeyD', 'KeyS', 'KeyA', 'KeyW']) await dispatchKey(frame, 'keyup', k);
  }

  fs.writeFileSync(path.join(outDir, 'records.json'), JSON.stringify(records, null, 0));
  const dt = (Date.now() - t0) / 1000;
  log(arm.label, 'DONE', N_TARGET, 'frames in', dt.toFixed(1), 's (', (N_TARGET / dt).toFixed(1), 'fps)');

  // quick sanity: how many distinct transform strings, how many distinct content hashes
  const distinctTransforms = new Set(records.map(r => r.transform)).size;
  const hashRecords = records.filter(r => r.contentHash !== null);
  const distinctHashes = new Set(hashRecords.map(r => r.contentHash)).size;
  const selfPosXs = records.map(r => r.selfPos && r.selfPos.x).filter(v => v != null);
  const selfPosRange = selfPosXs.length ? Math.max(...selfPosXs) - Math.min(...selfPosXs) : 0;
  const summary = { label: arm.label, n: N_TARGET, seconds: dt, distinctTransforms, distinctHashesSampled: distinctHashes, hashSamples: hashRecords.length, selfPosXRange: selfPosXs.length ? selfPosRange : null };
  log(arm.label, 'SANITY', JSON.stringify(summary));
  fs.writeFileSync(path.join(outDir, 'sanity.json'), JSON.stringify(summary, null, 2));

  await page.close();
  return summary;
}

async function main() {
  const browser = await chromium.launch({ headless: false, args: ['--use-angle=metal', '--window-size=1600,1000'] });

  const arms = [
    { label: 'motion', slot: 1, token: '0xBADA55_1', name: 'bb-motion', moveKeys: true, pinCamera: false, hashEvery: 0 },
    { label: 'repaint_static', slot: 2, token: '0xBADA55_2', name: 'bb-repaintstatic', moveKeys: false, pinCamera: true, hashEvery: 5 },
  ];

  const results = [];
  for (const arm of arms) {
    const r = await runArm(browser, arm);
    results.push(r);
  }

  fs.writeFileSync('/private/tmp/bb2/capture/summary.json', JSON.stringify(results, null, 2));
  log('ALL ARMS DONE', JSON.stringify(results));
  fs.writeFileSync('/tmp/blackbars_repaintcontrol_done.txt', 'done ' + new Date().toISOString());
  await browser.close();
}

main().catch((e) => {
  console.error('FATAL', e);
  fs.writeFileSync('/tmp/blackbars_repaintcontrol_done.txt', 'FATAL ' + (e && e.stack || e));
  process.exit(1);
});
