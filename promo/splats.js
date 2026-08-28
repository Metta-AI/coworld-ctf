// ── THE SPLATS ARE THE GAME'S OWN ──────────────────────────────────────────
// Ported pixel-for-pixel out of src/ctf/global.nim — same integer hash, same
// droplet offsets, same wobble, same fade stages — so these are the exact
// shapes the engine stamps on the floor, not an impression of them:
//
//   buildHitSparkSprite (21x21, HitSplatCoreR 6.0) — the on-hit paint splat:
//     a wet glossy core with a hash-perturbed irregular edge, SIX flung
//     droplets ringed around it, a bright sheen lobe up-left, and a thin dark
//     contour of the same hue so it pops off a dark floor.
//   buildSplatterSprite (13x13) — the puddle: a dense blob thinned by a
//     per-pixel hash dither, sparser as the stage climbs.
//
// Recolored to the two team paints, which Maxwell has explicitly sanctioned.
// The three color transforms are the sprite's own: paint lightens the base so
// it never muddies, sheen runs near-white, contour is a deep version of the
// SAME hue (never brown — this is paint, not blood).
var RED = '#e0523a', BLUE = '#3f7cc4';   // the two team paints (--red / --blue)
var HIT_SIZE = 21, HIT_CORE_R = 6.0, PUDDLE_SIZE = 13, SPLAT_STAGES = 4;
// Order matters only for callers that ask for a partial droplet count (see
// `drops` on a spot / `dropCount` on buildHitSplat) — they take the first N.
// Full-droplet callers (the default, every existing asset) draw all six
// regardless of order, so this reorder is a no-op for them.
var DROPLETS = [[9,4,2.6], [2,9,1.8], [-8,-3,2.4], [7,-6,2.0], [-6,7,2.2], [-9,2,1.7]];

// global.nim's pixel hash, in uint32 (Math.imul keeps the 32-bit wrap honest).
function hashNoise(x, y) {
  var n = (Math.imul(x, 374761393) + Math.imul(y, 668265263)) >>> 0;
  return Math.imul(n ^ (n >>> 13), 1274126177) >>> 0;
}
function rgbOf(hex) {
  var m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  return { r: parseInt(m[1], 16), g: parseInt(m[2], 16), b: parseInt(m[3], 16) };
}
function spriteCanvas(w, h) {
  var cv = document.createElement('canvas'); cv.width = w; cv.height = h; return cv;
}

// buildHitSparkSprite
function buildHitSplat(hex, stage, dropCount) {
  var base = rgbOf(hex);
  var paint = { r: (base.r * 3 + 255) >> 2, g: (base.g * 3 + 255) >> 2, b: (base.b * 3 + 255) >> 2 };
  var sheenC = { r: (base.r + 765) >> 2, g: (base.g + 765) >> 2, b: (base.b + 765) >> 2 };
  var edge = { r: (base.r * 2 / 5) | 0, g: (base.g * 2 / 5) | 0, b: (base.b * 2 / 5) | 0 };
  var c = (HIT_SIZE - 1) / 2;
  var fade = 1.0 - 0.62 * (stage / (SPLAT_STAGES - 1));
  var coreR2 = HIT_CORE_R * HIT_CORE_R;
  var cv = spriteCanvas(HIT_SIZE, HIT_SIZE);
  var ictx = cv.getContext('2d');
  var img = ictx.createImageData(HIT_SIZE, HIT_SIZE);
  for (var y = 0; y < HIT_SIZE; y++) {
    for (var x = 0; x < HIT_SIZE; x++) {
      var dx = x - c, dy = y - c, d2 = dx * dx + dy * dy;
      var noise = hashNoise(x, y);
      var wobble = ((noise >>> 16) % 7) - 3;              // -3..+3 px
      var coreEdge = HIT_CORE_R + wobble * 0.5;
      var inShape = d2 <= coreEdge * coreEdge;
      var onEdge = d2 > (coreEdge - 1.6) * (coreEdge - 1.6) && inShape;
      if (!inShape) {
        var dn = (dropCount == null) ? DROPLETS.length : Math.min(dropCount, DROPLETS.length);
        for (var k = 0; k < dn; k++) {
          var ox = DROPLETS[k][0], oy = DROPLETS[k][1], dr = DROPLETS[k][2];
          var ddx = x - (c + ox), ddy = y - (c + oy), dd2 = ddx * ddx + ddy * ddy;
          if (dd2 <= dr * dr) { inShape = true; onEdge = dd2 > (dr - 1.0) * (dr - 1.0); break; }
        }
      }
      if (!inShape) continue;
      var sxr = dx + 2.0, syr = dy + 2.0;
      var sheen = d2 <= coreR2 && (sxr * sxr + syr * syr) <= 5.2 * 5.2 && ((noise >>> 9) % 5) > 0;
      var col = onEdge ? edge : (sheen ? sheenC : paint);
      var i = (y * HIT_SIZE + x) * 4;
      img.data[i] = col.r; img.data[i + 1] = col.g; img.data[i + 2] = col.b;
      img.data[i + 3] = Math.max(0, Math.min(255, Math.round(255 * fade)));
    }
  }
  ictx.putImageData(img, 0, 0);
  return cv;
}

// buildSplatterSprite — the puddle. Late stages shade darker in-engine; these
// stay on the bright paint so a decorative puddle never reads as a scab.
function buildPuddle(hex, stage) {
  var base = rgbOf(hex);
  var half = PUDDLE_SIZE >> 1;
  var cv = spriteCanvas(PUDDLE_SIZE, PUDDLE_SIZE);
  var ictx = cv.getContext('2d');
  var img = ictx.createImageData(PUDDLE_SIZE, PUDDLE_SIZE);
  for (var y = 0; y < PUDDLE_SIZE; y++) {
    for (var x = 0; x < PUDDLE_SIZE; x++) {
      var dx = x - half, dy = y - half, d2 = dx * dx + dy * dy;
      if (d2 > half * half) continue;
      var noise = hashNoise(x, y);
      var density = 120 - stage * 25 - d2 * 2;
      if (((noise >>> 16) % 100) < density) {
        var i = (y * PUDDLE_SIZE + x) * 4;
        img.data[i] = base.r; img.data[i + 1] = base.g; img.data[i + 2] = base.b;
        img.data[i + 3] = 255;
      }
    }
  }
  ictx.putImageData(img, 0, 0);
  return cv;
}

var spriteCache = {};
function sprite(kind, hex, stage, dropCount) {
  var key = kind + hex + stage + '_' + (dropCount == null ? 'all' : dropCount);
  if (!spriteCache[key]) {
    spriteCache[key] = kind === 'hit' ? buildHitSplat(hex, stage, dropCount) : buildPuddle(hex, stage);
  }
  return spriteCache[key];
}

// Where the paint landed. `px` is the pixel scale (these are 21px and 13px
// sprites, drawn big with smoothing OFF so they stay crisp game pixels).
// `rot` is in QUARTER turns only — an arbitrary angle would resample the pixel
// grid and soften the very thing that makes them read as the game's art.

// ── Reusable promo API ─────────────────────────────────────────────────────
// paintSplats(canvasEl, spots, opts) — stamp the engine's real splat sprites.
// spots: [{x,y,k:'hit'|'puddle',c:RED|BLUE,st:0..3,px,a,rot,flip}]
//   x,y are 0..1 fractions of the canvas box; px is the pixel scale.
window.PB_RED = RED; window.PB_BLUE = BLUE;
window.paintSplats = function (canvas, spots, opts) {
  opts = opts || {};
  var box = canvas.parentElement.getBoundingClientRect();
  var W = opts.w || Math.round(box.width);
  var H = opts.h || Math.round(box.height);
  var dpr = opts.dpr || 1;
  canvas.width = Math.round(W * dpr);
  canvas.height = Math.round(H * dpr);
  canvas.style.width = W + 'px';
  canvas.style.height = H + 'px';
  var ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  ctx.imageSmoothingEnabled = false;
  for (var i = 0; i < spots.length; i++) {
    var sp = spots[i];
    var cv = sprite(sp.k, sp.c, sp.st || 0, sp.drops);
    var s = cv.width * (sp.px || 10);
    ctx.save();
    ctx.globalAlpha = sp.a == null ? 0.7 : sp.a;
    ctx.imageSmoothingEnabled = false;
    ctx.translate(Math.round(sp.x * W), Math.round(sp.y * H));
    if (sp.rot) ctx.rotate(sp.rot * Math.PI / 2);
    if (sp.flip) ctx.scale(-1, 1);
    ctx.drawImage(cv, Math.round(-s / 2), Math.round(-s / 2), Math.round(s), Math.round(s));
    ctx.restore();
  }
};
