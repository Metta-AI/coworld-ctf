import { chromium } from 'playwright';

const SLOT = process.env.PL_SLOT || '0';
const TOKEN = process.env.PL_TOKEN || '0xBADA55_0';
const PORT = process.env.PL_PORT || '21999';
const PLAY_MS = Number(process.env.PL_PLAY_MS || 150000);

const url = `http://127.0.0.1:${PORT}/client/takeover?slot=${SLOT}&token=${encodeURIComponent(TOKEN)}&name=ProofLedger`;

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
page.on('console', (msg) => { /* swallow */ });
await page.goto(url, { waitUntil: 'domcontentloaded' });
console.log('[play_human] navigated to', url);

async function waitDriving(timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const state = await page.locator('#state').textContent().catch(() => '');
    if (state && state.toLowerCase().includes('driving')) return true;
    await page.waitForTimeout(300);
  }
  return false;
}

const driving = await waitDriving(20000);
console.log('[play_human] driving state reached:', driving);

// Click into the field iframe to ensure keyboard focus lands on the player client.
try {
  const fieldBox = await page.locator('#field').boundingBox();
  if (fieldBox) {
    await page.mouse.click(fieldBox.x + fieldBox.width / 2, fieldBox.y + fieldBox.height / 2);
  }
} catch (e) {
  console.log('[play_human] focus click failed:', e.message);
}

const dirs = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
const fieldBox = await page.locator('#field').boundingBox();
const cx = fieldBox ? fieldBox.x + fieldBox.width / 2 : 640;
const cy = fieldBox ? fieldBox.y + fieldBox.height / 2 : 500;
const rx = fieldBox ? fieldBox.width * 0.42 : 500;
const ry = fieldBox ? fieldBox.height * 0.42 : 300;

const endAt = Date.now() + PLAY_MS;
let heldDir = null;
let lastDirSwitch = 0;
let angle = 0;

console.log('[play_human] entering play loop for', PLAY_MS, 'ms');
while (Date.now() < endAt) {
  const now = Date.now();
  if (heldDir === null || now - lastDirSwitch > 4000) {
    if (heldDir) await page.keyboard.up(heldDir).catch(() => {});
    heldDir = dirs[Math.floor(Math.random() * dirs.length)];
    await page.keyboard.down(heldDir).catch(() => {});
    lastDirSwitch = now;
  }
  // Sweep the mouse in a circle around the field center to scan for targets
  // with aim assist doing the fine correction.
  angle += 0.35;
  const mx = cx + Math.cos(angle) * rx;
  const my = cy + Math.sin(angle) * ry;
  await page.mouse.move(mx, my, { steps: 2 }).catch(() => {});
  await page.keyboard.down('z').catch(() => {});
  await page.waitForTimeout(120);
  await page.keyboard.up('z').catch(() => {});
  await page.waitForTimeout(60);
}
if (heldDir) await page.keyboard.up(heldDir).catch(() => {});

console.log('[play_human] play loop done, checking final status');
const finalStatus = await page.locator('#detail').textContent().catch(() => '<unknown>');
console.log('[play_human] final detail:', finalStatus);

await browser.close();
console.log('[play_human] browser closed, exiting');
