// Fog-layer-specific 3-way instant comparison, per Maxwell's direct
// observation: "the banding only affects the fog of war shadowed areas...
// it updates every tick when i aim or move". FogLayerId=4 (src/ctf/global.nim),
// same MapLayerType/ZoomableLayerFlag as the map layer -- confirmed it goes
// through the SAME x.drawImage(layer.canvas,0,0) compositing path into the
// one visible canvas `c`, not a separate DOM/CSS layer (grepped, then
// verified live prod serves byte-identical layer machinery via a read-only
// curl). This script empirically checks whether that reading holds by
// grabbing the fog layer's OWN offscreen canvas content directly.
//
// Own local rig only (127.0.0.1:27931). Zero WASD (selfPos frozen -> camera
// transform naturally static, verified not assumed) + continuous mouse
// sweep (aim changes every tick -> vision cone / fog recompute every tick,
// per Maxwell's report).

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = 'http://127.0.0.1:27931';
const OUT = '/private/tmp/bb2/fogcheck';
fs.mkdirSync(OUT, { recursive: true });
function log(...a) { console.log(new Date().toISOString(), ...a); }

async function main() {
  const browser = await chromium.launch({ headless: false, args: ['--use-angle=metal', '--window-size=1600,1000'] });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  const url = `${BASE}/client/takeover?slot=3&token=0xBADA55_3&name=fogcheck`;
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  if (!page.url().startsWith(BASE)) throw new Error('not on local rig, aborting');

  const frameEl = await page.waitForSelector('#field', { timeout: 30000 });
  const frame = await frameEl.contentFrame();
  await frame.waitForFunction(() => typeof mapW !== 'undefined' && mapW > 0, null, { timeout: 30000 });
  await frame.waitForFunction(() => !!selfPos, null, { timeout: 45000 });
  await frame.evaluate(() => { if (cameraModeIndex !== 1) cycleCameraMode(1); });
  await page.waitForTimeout(200);

  const layerInfo = await frame.evaluate(() => {
    return [...layers.entries()].map(([id, l]) => ({ id, type: l.type, flags: l.flags, w: l.width, h: l.height }));
  });
  log('layers present:', JSON.stringify(layerInfo));

  await frame.evaluate(() => {
    window.__grabFog = function () {
      const fog = layers.get(4);
      if (!fog || !fog.canvas) return null;
      return fog.canvas.toDataURL('image/png');
    };
  });

  const cx = 800, cy = 500, r = 250;
  let t = 0;
  const N = 40;
  for (let i = 0; i < N; i++) {
    const ang = (t / 20) * Math.PI * 2;
    await frame.evaluate(({ mx, my }) => {
      const rect = c.getBoundingClientRect();
      window.dispatchEvent(new MouseEvent('mousemove', { clientX: rect.left + mx, clientY: rect.top + my, bubbles: true }));
    }, { mx: cx + r * Math.cos(ang), my: cy + r * Math.sin(ang) });
    t++;

    const cam = await frame.evaluate(() => ({ camScale, camX, camY, transform: c.style.transform, selfPos: selfPos ? { x: selfPos.x, y: selfPos.y } : null }));
    const [mainUrl, fogUrl] = await frame.evaluate(() => [c.toDataURL('image/png'), window.__grabFog()]);
    const box = await frameEl.boundingBox();
    await page.screenshot({ path: path.join(OUT, `f${String(i).padStart(3, '0')}_screenshot.png`), clip: box });
    fs.writeFileSync(path.join(OUT, `f${String(i).padStart(3, '0')}_main.png`), Buffer.from(mainUrl.split(',')[1], 'base64'));
    if (fogUrl) fs.writeFileSync(path.join(OUT, `f${String(i).padStart(3, '0')}_fog.png`), Buffer.from(fogUrl.split(',')[1], 'base64'));
    fs.writeFileSync(path.join(OUT, `f${String(i).padStart(3, '0')}_cam.json`), JSON.stringify(cam));
    if (i % 10 === 0) log('frame', i, JSON.stringify(cam));
    await page.waitForTimeout(30);
  }

  fs.writeFileSync('/tmp/fogcheck_done.txt', 'done ' + new Date().toISOString());
  log('DONE');
  await browser.close();
}

main().catch((e) => { console.error('FATAL', e); fs.writeFileSync('/tmp/fogcheck_done.txt', 'FATAL ' + e.stack); process.exit(1); });
