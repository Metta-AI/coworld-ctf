// Glory-toast probe — paste into devtools on /client/play (or drive it from
// Playwright with page.evaluate). Returns a PNG data URL of a LIVE frame that
// actually contains a deed toast.
//
// Why this exists rather than "just take a screenshot": a glory pop lives
// GloryFxTicks (~1.7s) and is fov-gated, so it routinely expires inside a
// screenshot round trip. Everything here reads the real #board canvas from
// inside the page, so what it returns is exactly the pixels the player saw --
// it does not synthesise, hold, or slow anything down.
//
//   await probeGloryToast()        -> {baselineAmber, bestAmber, deedsSeen, png}
//
// Open the PNG (or write it to a file) to SEE the toast. `bestAmber` well above
// `baselineAmber` is the signal that ink appeared; the picture is the proof.
// Needs a LIVE ROUND with the seat alive: pops are gated on your own fov, so a
// probe run while dead or in the lobby legitimately finds nothing.
async function probeGloryToast(opts) {
  const o = Object.assign({ cropW: 520, cropH: 380, windowMs: 1600, maxWaitMs: 60000 }, opts || {});
  const board = document.getElementById('board');
  const gr = document.getElementById('glory-red');
  const gb = document.getElementById('glory-blue');
  if (!board || !gr || !gb) throw new Error('not on the live player view');

  const s = document.createElement('canvas');
  s.width = o.cropW; s.height = o.cropH;
  const c = s.getContext('2d');

  function grab() {
    const sx = Math.max(0, (board.width - o.cropW) / 2);
    const sy = Math.max(0, (board.height - o.cropH) / 2);
    c.clearRect(0, 0, o.cropW, o.cropH);
    c.drawImage(board, sx, sy, o.cropW, o.cropH, 0, 0, o.cropW, o.cropH);
    const d = c.getImageData(0, 0, o.cropW, o.cropH).data;
    let amber = 0;
    for (let i = 0; i < d.length; i += 4) {
      // the chip's amber ink, well clear of the brown floor and the team paints
      if (d[i] > 190 && d[i + 1] > 120 && d[i + 1] < 215 && d[i + 2] < 115) amber++;
    }
    return { amber, url: s.toDataURL('image/png') };
  }

  const baselineAmber = grab().amber;
  let best = { amber: -1, url: null }, deedsSeen = 0;
  let last = [gr.textContent, gb.textContent];
  const deadline = Date.now() + o.maxWaitMs;

  while (Date.now() < deadline) {
    const now = [gr.textContent, gb.textContent];
    // A team glory numeral only moves when a deed pays. That is the cue to
    // start grabbing: the pop is being minted right now.
    if (now[0] !== last[0] || now[1] !== last[1]) {
      deedsSeen++; last = now;
      const until = Date.now() + o.windowMs;
      while (Date.now() < until) {
        const shot = grab();
        if (shot.amber > best.amber) best = shot;
        await new Promise(r => setTimeout(r, 110));
      }
      if (best.amber > baselineAmber * 2.2 && best.amber > 90) break;
    }
    await new Promise(r => setTimeout(r, 60));
  }
  return { baselineAmber, bestAmber: best.amber, deedsSeen, png: best.url };
}

if (typeof module !== 'undefined' && module.exports) module.exports = { probeGloryToast };
