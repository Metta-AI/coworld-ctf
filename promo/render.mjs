// Render promo HTML pages to exact-pixel PNGs.
//   node promo/render.mjs <page.html> <W> <H> <out.png> [dpr]
//   node promo/render.mjs --all          (renders everything in promo/manifest.json)
import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

async function shoot(browser, page_rel, w, h, out, dpr = 2) {
  const ctx = await browser.newContext({
    viewport: { width: w, height: h },
    deviceScaleFactor: dpr,
  });
  const page = await ctx.newPage();
  const url = 'http://localhost:8899/promo/pages/' + path.basename(page_rel);
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(350);
  const el = await page.$('.frame');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  await (el || page).screenshot({ path: out, omitBackground: true });
  await ctx.close();
  console.log(`OK ${path.basename(out)}  ${w}x${h}@${dpr}x`);
}

const browser = await chromium.launch();
const args = process.argv.slice(2);

if (args[0] === '--all') {
  const man = JSON.parse(fs.readFileSync(path.join(ROOT, 'promo/manifest.json'), 'utf8'));
  for (const a of man) {
    try {
      await shoot(browser, a.page, a.w, a.h, path.join(ROOT, 'promo/out', a.out), a.dpr ?? 2);
    } catch (e) { console.log(`FAIL ${a.out}: ${e.message}`); }
  }
} else {
  const [p, w, h, out, dpr] = args;
  await shoot(browser, p, +w, +h, path.isAbsolute(out) ? out : path.join(ROOT, out), dpr ? +dpr : 2);
}
await browser.close();
