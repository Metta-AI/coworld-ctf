import { chromium } from 'playwright';

const SLOT = process.env.PL_SLOT || '0';
const TOKEN = process.env.PL_TOKEN || '0xBADA55_0';
const PORT = process.env.PL_PORT || '21996';
const PLAY_MS = Number(process.env.PL_PLAY_MS || 150000);

const url = `http://127.0.0.1:${PORT}/client/player?slot=${SLOT}&token=${encodeURIComponent(TOKEN)}&player=1&directAim=1`;

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto(url, { waitUntil: 'domcontentloaded' });
console.log('[play_direct] navigated to', url);
await page.waitForTimeout(2000);
await page.mouse.click(640, 400).catch(() => {});

const dirs = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
const cx = 640, cy = 400, rx = 500, ry = 300;
const endAt = Date.now() + PLAY_MS;
let heldDir = null;
let lastDirSwitch = 0;
let angle = 0;

console.log('[play_direct] entering play loop for', PLAY_MS, 'ms');
while (Date.now() < endAt) {
  const now = Date.now();
  if (heldDir === null || now - lastDirSwitch > 4000) {
    if (heldDir) await page.keyboard.up(heldDir).catch(() => {});
    heldDir = dirs[Math.floor(Math.random() * dirs.length)];
    await page.keyboard.down(heldDir).catch(() => {});
    lastDirSwitch = now;
  }
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
console.log('[play_direct] play loop done');
await browser.close();
console.log('[play_direct] browser closed, exiting');
