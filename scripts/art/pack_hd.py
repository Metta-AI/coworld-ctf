#!/usr/bin/env python3
"""Pack the nanobanana masters (art/gen/nanobanana-output) into data/hd/*.png.

SCOPE: ENVIRONMENT TILES ONLY (floor, wall). The crew/heart/pedestal masters in
data/hd are the proven-good committed art — do NOT regenerate or repack them
(see feedback_dont_regen_working_art: a wholesale regen turned the soldier into
a "circle person" and the clean heart into a glitchy crystal). Only the two
dungeon-stone tiles are re-arted here.

  TILES (floor, wall) — seamless full-bleed textures sampled `worldX mod width`
  by hd.nim. They must stay OPAQUE RGB and tileable. We only downsize (a resize
  of a seamless texture stays seamless) to keep the repo lean.

The object matte path (seal-then-flood alpha cutout over the #1f1812 plate) is
retained below for reference — it packs OBJECTS (crew/hearts/pedestals) when a
future object master genuinely needs repacking, which is NOT the case now.

Usage: python3 scripts/art/pack_hd.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "art/gen/nanobanana-output"
DST = ROOT / "data/hd"

# master filename → (data/hd name, kind, packed size, matte-band)
# The matte band (lo, hi) is the rgb-distance-from-bg ramp: transparent at lo,
# opaque at hi. The default (13, 42) keeps soft glow. The GEMS use a HIGH band
# so their dark maroon/navy HALO (which sits close to the warm plate color and
# reads as a dirty smudge on the light floor) fades out and only the bright
# faceted body + its tight rim light survive.
GEM_BAND = (55.0, 90.0)
DEF_BAND = (13.0, 42.0)
# ENVIRONMENT-ONLY pack. The crew/heart/pedestal masters in data/hd are the
# proven-good committed art and must NOT be regenerated or repacked (see
# feedback_dont_regen_working_art). Only the two dungeon-stone tiles change.
PLAN = [
    ("a_seamless_tileable_worn_dungeon.png",   "floor.png",         "tile",   512, None),
    ("a_seamless_tileable_medieval_dun_2.png", "wall.png",          "tile",   512, None),
]

# The plate (#1f1812) is itself WARM, so a warmth key fails; and the cool
# grey-blue pedestals are NEGATIVE warmth. The robust key is DISTANCE from the
# corner-sampled bg color: measured, corner pixels stay within ~9 of the bg
# mean while every object body sits at dist > 40.
#
# A HARD threshold mattes a glowing gem's halo (which is close to the warm bg
# color) as ugly binary speckle. Instead alpha is a SOFT RAMP over distance:
# transparent at the bg color, opaque on the object body, a smooth falloff in
# between — so the heart's magical halo reads as light, not noise. A confident
# CORE (dist >= HI) is sealed and border-flooded to kill any disconnected far
# island, but the connected halo ramp survives.
SEAL = 11        # MaxFilter window to dilate/seal the core rim before flood


def isolate(im: Image.Image, band: tuple[float, float]) -> Image.Image:
    lo, hi = band
    a = np.asarray(im.convert("RGB")).astype(np.float32)
    h, w, _ = a.shape

    corners = np.concatenate([
        a[:16, :16].reshape(-1, 3), a[:16, -16:].reshape(-1, 3),
        a[-16:, :16].reshape(-1, 3), a[-16:, -16:].reshape(-1, 3)])
    bg = corners.mean(0)

    dist = np.linalg.norm(a - bg, axis=2)
    soft = np.clip((dist - lo) / (hi - lo), 0.0, 1.0)

    # Confident core → seal → border-flood the TRUE exterior. This removes far
    # specks the soft ramp would otherwise leave floating; the object's own halo
    # stays because it is connected to the sealed core, not reachable from a corner.
    core = dist >= hi
    cm = Image.fromarray((core * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(SEAL))
    sealed = np.asarray(cm) > 128
    field = np.where(sealed[..., None], 0, 255).astype(np.uint8).repeat(3, axis=2)
    cand = Image.fromarray(field, "RGB")
    SENT = (255, 0, 255)
    for xy in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
               (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]:
        ImageDraw.floodfill(cand, xy, SENT, thresh=10)
    exterior = np.all(np.asarray(cand) == SENT, axis=2)

    alpha = np.where(exterior, 0.0, soft * 255.0).astype(np.uint8)
    am = (Image.fromarray(alpha)
          .filter(ImageFilter.MedianFilter(3))
          .filter(ImageFilter.GaussianBlur(1.2)))
    alpha2 = np.asarray(am)

    out = Image.fromarray(np.dstack([a.astype(np.uint8), alpha2]))
    bbox = Image.fromarray((alpha2 > 24).astype(np.uint8) * 255).getbbox()
    if bbox:
        out = out.crop(bbox)
    ow, oh = out.size
    side = max(ow, oh)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(out, ((side - ow) // 2, (side - oh) // 2))
    return sq


def main() -> None:
    DST.mkdir(parents=True, exist_ok=True)
    for master, name, kind, size, band in PLAN:
        src = SRC / master
        if not src.exists():
            print(f"  MISSING {master} -> {name}")
            continue
        im = Image.open(src)
        if kind == "tile":
            out = im.convert("RGB").resize((size, size), Image.LANCZOS)
            opaque = 100.0
        else:
            out = isolate(im, band)
            out = out.resize((size, size), Image.LANCZOS)
            opaque = 100 * (np.asarray(out)[..., 3] > 128).mean()
        dst = DST / name
        out.save(dst)
        kb = dst.stat().st_size / 1024
        print(f"  {name:18s} {kind:6s} {out.size[0]}x{out.size[1]}  opaque {opaque:5.1f}%  {kb:6.0f}KB")
    print("done.")


if __name__ == "__main__":
    main()
