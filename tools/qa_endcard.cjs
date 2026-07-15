// Screenshots the broadcast replay's END-CARD (game-over verdict) through the
// proxy harness, to verify the hearts + decisive-win (+1/-1) copy renders. Uses
// the same proxy/CDN-block setup as qa_aspects.cjs, then clicks the transport's
// jump-to-end control and waits for the gameover phase before shooting.
const path = require('path');
const QA = process.env.QA_DIR || path.join(process.cwd(), 'tools/.qa');
process.env.PLAYWRIGHT_BROWSERS_PATH = process.env.PLAYWRIGHT_BROWSERS_PATH || (QA + '/ms-playwright');
const { chromium } = require(QA + '/node_modules/playwright');
const BASE = process.env.PROXY_BASE || 'http://127.0.0.1:8890';
const VIEWER = process.env.VIEWER_PATH || 'client/replay';
const CDN_HOSTS = (process.env.CDN_HOSTS || 'cdn.jsdelivr.net,unpkg.com,esm.sh').split(',');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1330, height: 700 } });
  for (const h of CDN_HOSTS) await page.route(`**${h}**`, r => r.abort());
  const errs = [];
  page.on('pageerror', e => errs.push(e.message.slice(0, 160)));
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text().slice(0, 160)); });
  await page.goto(`${BASE}/embed?path=${VIEWER}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3000);
  const fr = page.frames().find(f => f.url().includes('/proxy/'));
  if (!fr) { console.log('no viewer frame'); await browser.close(); process.exit(1); }
  // Jump to the end of the replay, then wait for the end-card to become visible.
  await fr.evaluate(() => { const b = document.getElementById('btn-end'); if (b) b.click(); });
  let shown = false;
  for (let i = 0; i < 40; i++) {
    await page.waitForTimeout(500);
    shown = await fr.evaluate(() => {
      const el = document.getElementById('endcard');
      return !!(el && el.classList.contains('on'));
    });
    if (shown) break;
  }
  const card = await fr.evaluate(() => {
    const el = document.getElementById('endcard');
    return el ? el.textContent.replace(/\s+/g, ' ').trim().slice(0, 300) : '(no endcard element found)';
  });
  console.log('endcard visible:', shown);
  console.log('endcard text:', card);
  console.log('errs:', errs.length ? errs : '(none)');
  await page.screenshot({ path: '/tmp/qa_ctf_endcard.png' });
  console.log('shot: /tmp/qa_ctf_endcard.png');
  await browser.close();
})();
