#!/usr/bin/env python3
"""Bake data/arena_floor.png: a seamless polished-concrete tile on a HEX grid.

The surface is unchanged — broad troweled mottle, fine aggregate grain, a few
meandering hairline cracks. What changed is the JOINT LATTICE. It used to be a
2x2 grid of 128px square panels, whose seams are a 0/90-degree family; on a
hexagonal board that is the one pattern that argues with every edge of the
hull. The joints now run along a hexagonal honeycomb sharing the hull's own
axes, so the floor's grain and the field's shape agree.

PERIODICITY IS THE HARD PART, and it is why this tile is not square.
`tileSample`/`tileSampleF` are square-torus wraps (`x mod texW`, `y mod texH`),
so the image must contain a whole number of lattice periods on BOTH axes or the
wrap shows as a visible seam. A hex lattice has a rectangular fundamental cell,
but its aspect is sqrt(3):1 — irrational — so no square image can hold an
integer number of REGULAR hexes. Forcing it into 256x256 costs 15% anisotropy
(visibly squashed hexes). Letting the image be 256x296 instead costs 0.13%:

  columns step  COL_DX = 64 px  ->  x period 128, and 256 / 128 = 2 exactly
  rows step     ROW_DY = 74 px  ->  y period  74, and 296 /  74 = 4 exactly

which is a circumradius of 42.67 across and 42.72 down. Both are exact integer
divisions, so the wrap is seamless by construction rather than by tuning.

The cells are pointy-left-right (vertices at 0/60/120/180/240/300 degrees), the
same orientation as the arena hull, so the joints run parallel to the hull's
six edges instead of cutting across them.

The luminance envelope is a CONTRACT with sim.nim's endzone ember glow
(emberThroughCracks, map_art.nim:664): pixels at/above EndzoneFaceLevel (66)
get no glow, pixels at/below EndzoneCrackLevel (34) glow fully. The polished
surface — including the joint bevels — sits safely above 66; only the hairline
crack bottoms dip to ~26..34, so team ember confines to the actual cracks. Break
it and the endzone either floods with team colour or shows no glow at all. The
run prints both figures; check them.

Usage: python3 scripts/art/build_floor.py  (writes data/arena_floor.png)
"""

import numpy as np
from PIL import Image
from pathlib import Path

# Image size and hex lattice. See the module docstring: these four numbers are
# locked to each other, and W % (2 * COL_DX) == 0 and H % ROW_DY == 0 are what
# make the torus wrap seamless.
W, H = 256, 296
COL_DX = 64          # horizontal step between adjacent hex columns (1.5 * R)
ROW_DY = 74          # vertical step within a column (sqrt(3) * R)
assert W % (2 * COL_DX) == 0, "odd/even column offset must repeat across the wrap"
assert H % ROW_DY == 0, "rows must divide the height exactly"

rng = np.random.default_rng(1177)


# Neutral-warm grey ramp (the house style forbids cold blue-slate): each
# pixel's luminance v maps to rgb with a whisper of warmth, never a hue.
def to_rgb(v):
    r = np.clip(v * 1.020 + 1.5, 0, 255)
    g = np.clip(v, 0, 255)
    b = np.clip(v * 0.965 - 1.0, 0, 255)
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def tileable_noise(h, w, cutoff, power):
    """FFT-synthesized noise — periodic by construction, hence seamless."""
    spec = rng.normal(size=(h, w)) + 1j * rng.normal(size=(h, w))
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    f = np.hypot(fx, fy)
    f[0, 0] = 1.0
    falloff = np.where(f <= cutoff, 1.0 / (f ** power), 0.0)
    falloff[0, 0] = 0.0
    field = np.real(np.fft.ifft2(spec * falloff))
    field -= field.mean()
    return field / (field.std() + 1e-9)


# --- Surface: troweled mottle + faint drift + fine grain -------------------
lum = np.full((H, W), 88.0)
lum += tileable_noise(H, W, 0.04, 1.6) * 7.0    # broad trowel blotches
lum += tileable_noise(H, W, 0.12, 1.3) * 4.0    # mid-scale clouding
lum += tileable_noise(H, W, 0.50, 0.9) * 2.2    # fine sanded grain

# Aggregate specks: sparse 1px flecks a touch lighter/darker, plus rare
# pinholes (polished slabs always carry a few).
n_flecks = round(900 * (W * H) / (256 * 256))
ys = rng.integers(0, H, n_flecks)
xs = rng.integers(0, W, n_flecks)
lum[ys, xs] += rng.normal(0, 5.5, n_flecks)
n_pin = round(70 * (W * H) / (256 * 256))
ys = rng.integers(0, H, n_pin)
xs = rng.integers(0, W, n_pin)
lum[ys, xs] -= rng.uniform(14, 26, n_pin)

lum = np.clip(lum, 72, 112)  # polished surface stays above the glow gate (66)

# --- The hex lattice, and every pixel's distance to the nearest joint ------
# The honeycomb is the VORONOI diagram of a triangular lattice of centres, so
# the distance from a pixel to the nearest cell EDGE is exactly half the gap
# between its nearest and second-nearest centre. That formulation needs no
# polygon clipping, no per-edge case analysis, and — given a periodic set of
# centres — is periodic for free.
centres = []
for i in range(W // COL_DX):
    for j in range(H // ROW_DY):
        centres.append((i * COL_DX, j * ROW_DY + (ROW_DY // 2 if i % 2 else 0)))

yy, xx = np.mgrid[0:H, 0:W].astype(float)
d1 = np.full((H, W), 1e9)
d2 = np.full((H, W), 1e9)
for cx, cy in centres:
    # Wrapped copies, so the metric is the torus metric and the tile is seamless.
    for ox in (-W, 0, W):
        for oy in (-H, 0, H):
            d = np.hypot(xx - (cx + ox), yy - (cy + oy))
            closer = d < d1
            d2 = np.where(closer, d1, np.minimum(d2, d))
            d1 = np.where(closer, d, d1)
edge_dist = (d2 - d1) * 0.5

# --- Control joints along the honeycomb edges -----------------------------
# The joints are NOT dark cuts: each is a soft emboss — a light catch right on
# the seam with a shade shoulder beside it — so the lattice reads as panel
# seams in polished concrete, not a painted black grid. Only the hairline
# cracks dip into the ember-glow band; joint pixels stay in no-glow surface
# territory. A wobble keeps the lines from reading machine-perfect.
#
# Keep this TIGHT. The square-panel tile it replaces drew a ~2px hairline and
# was deliberately restrained; a hex lattice has half again as much seam per
# unit area (three edge directions, not two, and smaller cells), so the same
# profile width reads considerably louder. These gaussians are narrowed to
# hold the floor at the old visual weight rather than turning it into a
# honeycomb graphic.
wobble = 0.7 * tileable_noise(H, W, 0.30, 1.0)
t = np.abs(edge_dist + wobble)
joint_bevel = (
    9.0 * np.exp(-((t / 0.55) ** 2))              # light catch on the seam
    - 11.0 * np.exp(-(((t - 1.25) / 0.60) ** 2))  # shade shoulder beside it
)
lum += joint_bevel
lum = np.clip(lum, 72, 112)  # bevels stay inside the no-glow surface band

# --- Hairline cracks: momentum random walks confined to cell interiors ----
# Each cell gets a crack seeded well inside it, walking until it nears a joint.
# `carve` wraps, so a crack that reaches the image edge continues correctly on
# the far side and the tile stays seamless.
depth = np.zeros((H, W))


def carve(y, x, d):
    yy_, xx_ = int(y) % H, int(x) % W
    depth[yy_, xx_] = max(depth[yy_, xx_], d)


def edge_at(y, x):
    return edge_dist[int(y) % H, int(x) % W]


for cx, cy in centres:
    if rng.random() < 0.15:
        continue                       # not every panel is cracked
    ang = rng.uniform(0, 2 * np.pi)
    # Start off-centre so cracks do not all radiate from the cell's middle.
    y = cy + rng.uniform(-12, 12)
    x = cx + rng.uniform(-12, 12)
    steps = rng.integers(30, 70)
    strength = rng.uniform(0.55, 0.9)
    branch_left = 1
    for i in range(steps):
        ang += rng.normal(0, 0.28)
        y += np.sin(ang)
        x += np.cos(ang)
        if edge_at(y, x) < 2.5:
            break                      # never cross a joint
        taper = strength * (1.0 - 0.5 * i / steps)
        carve(y, x, taper)
        # hairline sections read as ~1px; occasionally widen a hair
        if rng.random() < 0.35:
            carve(y + rng.integers(-1, 2), x + rng.integers(-1, 2), taper * 0.45)
        if branch_left and rng.random() < 0.03 and i > 10:
            branch_left -= 1
            by, bx = y, x
            bang = ang + rng.choice([-1, 1]) * rng.uniform(0.7, 1.3)
            for j in range(int(steps * 0.4)):
                bang += rng.normal(0, 0.3)
                by += np.sin(bang)
                bx += np.cos(bang)
                if edge_at(by, bx) < 2.5:
                    break
                carve(by, bx, taper * (1.0 - 0.6 * j / (steps * 0.4)))

# --- Composite: dip lum toward crack-bottom, add a spall highlight --------
# Full depth lands at lum ~27 (below EndzoneCrackLevel 34 -> full ember glow);
# hairline taper passes through the 34..66 partial-glow band naturally.
CRACK_BOTTOM = 27.0
lum = lum * (1.0 - depth) + CRACK_BOTTOM * depth

# 1px light catch on the lower-right of deep cuts: reads as the polished
# edge catching light, and keeps cracks crisp instead of muddy.
spall = np.roll(np.roll(depth, 1, axis=0), 1, axis=1) - depth
lum += np.clip(spall, 0, 1) * 6.0

img = Image.fromarray(to_rgb(np.clip(lum, 24, 118)))
out = Path(__file__).resolve().parents[2] / "data" / "arena_floor.png"
img.save(out)

a = np.asarray(img).astype(int)
l = (a[..., 0] * 30 + a[..., 1] * 59 + a[..., 2] * 11) // 100
print(f"wrote {out}  ({W}x{H}, {len(centres)} hex cells)")
print(f"lum min/max/mean: {l.min()}/{l.max()}/{l.mean():.0f}")
print(f"pixels below CrackLevel(34): {(l <= 34).mean() * 100:.1f}%  "
      f"above FaceLevel(66): {(l >= 66).mean() * 100:.1f}%")

# The contract, asserted rather than eyeballed. The joint bevels are part of
# the polished FACE: if a seam dips under 66 the endzone ember bleeds along the
# whole lattice instead of confining to the cracks.
joint_face = l[(edge_dist < 1.5) & (depth < 0.05)]
print(f"joint-seam pixels (no crack): min lum {joint_face.min()} "
      f"(must stay >= 66)")
assert joint_face.min() >= 66, "joint bevel dipped into the ember-glow band"
# Calibrated against the 2x2-panel tile this replaces, measured, not guessed:
#   <=34 (full glow)   0.011%     <=45 (well into the band)  0.151%
#   >=66 (no glow)    99.07%      min lum 33
# Cracks are hairlines, so the full-glow floor is a few hundredths of a percent
# by design — an earlier draft of this check demanded 0.05% and would have
# failed the tile it was written to protect.
assert l.min() <= 34, "no crack reaches full ember glow — endzone will look dead"
assert (l <= 45).mean() > 0.0005, "too few crack pixels — endzone glow will not read"
assert (l >= 66).mean() > 0.95, "too much of the face glows — endzone will flood"

# Seamlessness, asserted against the DISTRIBUTION of interior transitions, not
# their mean: crossing the wrap must be an unremarkable step, not the biggest
# one in the tile.
#
# Every layer here is periodic by construction — FFT noise, an exactly periodic
# lattice (W % 2*COL_DX == 0, H % ROW_DY == 0), cracks carved through a
# wrapping `carve`, a spall pass built from np.roll — so this is a check on
# that construction, not a tuning knob.
#
# The 2x2-panel tile it replaces would FAIL this, and did not need to pass it:
# it put its joints ON the wrap, so its seam was the single largest transition
# in the image (y-wrap 21.8 against an interior max of 18.4) and was hidden by
# reading as a panel edge. This lattice does not need that trick — its wrap
# lands mid-face — so it can be held to the stricter, honest standard.
row_steps = np.abs(np.diff(l, axis=0)).mean(axis=1)
col_steps = np.abs(np.diff(l, axis=1)).mean(axis=0)
wrap_y = np.abs(l[0, :] - l[-1, :]).mean()
wrap_x = np.abs(l[:, 0] - l[:, -1]).mean()
print(f"wrap step vs worst interior step — "
      f"x: {wrap_x:.2f} vs {col_steps.max():.2f}   "
      f"y: {wrap_y:.2f} vs {row_steps.max():.2f}")
assert wrap_x <= col_steps.max() * 1.1, "the x wrap is the tile's worst seam"
assert wrap_y <= row_steps.max() * 1.1, "the y wrap is the tile's worst seam"
print("contract OK")
