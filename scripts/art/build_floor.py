#!/usr/bin/env python3
"""Bake the arena floor tiles: the default polished concrete plus one tile per
map BIOME.

  data/arena_floor.png          default polished concrete (the classic arena)
  data/arena_floor_caves.png    damp cave rock, no straight joints
  data/arena_floor_forest.png   mossy humus + leaf litter
  data/arena_floor_desert.png   sun-baked cracked mud over pale sand
  data/arena_floor_city.png     asphalt pavers in running bond
  data/arena_floor_plains.png   dry steppe turf with bare dirt seams

Every tile is 256x256 and SEAMLESS by construction (FFT-synthesized noise is
periodic; crack walks either wrap through the modulo carve or stay inside a
panel; the paver and Voronoi grids divide 256 evenly).

THE LUMINANCE CONTRACT (the whole reason these are generated, not painted).
map_art.nim's endzone ember glow (emberThroughCracks) gates on each floor
texel's luminance: at/above EndzoneFaceLevel (66) a pixel takes NO glow,
at/below EndzoneCrackLevel (34) it glows fully, and the band between glows
quadratically. So a floor must keep its SURFACE above 66 and let only its
cracks/joints dip below, or the endzone either floods with flat team color
(too many dark texels) or shows no glow at all (none of them).
check_contract() enforces that on every tile this script writes, measured on
the SAVED PNG's real RGB, and tests/test_map_biome.nim re-checks the same
gates at test time so a hand-edited PNG cannot slip past.

The color ramps are luminance-NORMALIZED: each biome's rgb multipliers are
scaled so 0.30r + 0.59g + 0.11b reproduces the luminance this script gated,
which is what lets a biome be sand-yellow or moss-green and still honor a
contract written in greys.

Usage:
  python3 scripts/art/build_floor.py            # all six tiles
  python3 scripts/art/build_floor.py desert     # one tile by biome name
"""

import sys
import numpy as np
from PIL import Image
from pathlib import Path

SIZE = 256

# --- The contract with map_art.nim (EndzoneFaceLevel / EndzoneCrackLevel) ---
FACE_LEVEL = 66      # at/above this luminance a texel takes NO ember glow.
CRACK_LEVEL = 34     # at/below this luminance a texel glows fully.
CRACK_BOTTOM = 27.0  # luminance a full-depth crack composites down to.
# How much of a tile may sit in the glow band. Under the floor and the endzone
# has no readable glow; over the ceiling and the endzone reads as a flat team
# wash instead of ember through fissures (the L98 #4 regression). The shipped
# concrete measures 0.93%, which is the low end of "reads as cracks".
GLOW_PCT_MIN = 0.30
GLOW_PCT_MAX = 6.00

OUT_DIR = Path(__file__).resolve().parents[2] / "data"


def lum_of(img):
    """The engine's own luminance (map_art.nim emberThroughCracks)."""
    a = np.asarray(img.convert("RGB")).astype(int)
    return (a[..., 0] * 30 + a[..., 1] * 59 + a[..., 2] * 11) // 100


def tileable_noise(rng, size, cutoff, power):
    """FFT-synthesized noise — periodic by construction, hence seamless."""
    spec = rng.normal(size=(size, size)) + 1j * rng.normal(size=(size, size))
    fy = np.fft.fftfreq(size)[:, None]
    fx = np.fft.fftfreq(size)[None, :]
    f = np.hypot(fx, fy)
    f[0, 0] = 1.0
    falloff = np.where(f <= cutoff, 1.0 / (f ** power), 0.0)
    falloff[0, 0] = 0.0
    field = np.real(np.fft.ifft2(spec * falloff))
    field -= field.mean()
    return field / (field.std() + 1e-9)


def walk_cracks(rng, depth, count, steps_lo, steps_hi, strength_lo,
                strength_hi, wander, widen=0.35, branch_chance=0.02):
    """Momentum random walks carved into `depth` (0..1 dip toward the crack
    bottom). The carve is modulo SIZE, so a fissure runs off one edge and back
    on the other and the tile stays seamless."""
    def carve(y, x, d):
        yy, xx = int(y) % SIZE, int(x) % SIZE
        depth[yy, xx] = max(depth[yy, xx], d)

    for _ in range(count):
        y = rng.uniform(0, SIZE)
        x = rng.uniform(0, SIZE)
        ang = rng.uniform(0, 2 * np.pi)
        steps = int(rng.integers(steps_lo, steps_hi))
        strength = rng.uniform(strength_lo, strength_hi)
        branch_left = 1
        for i in range(steps):
            ang += rng.normal(0, wander)
            y += np.sin(ang)
            x += np.cos(ang)
            taper = strength * (1.0 - 0.45 * i / steps)
            carve(y, x, taper)
            if rng.random() < widen:
                carve(y + rng.integers(-1, 2), x + rng.integers(-1, 2),
                      taper * 0.45)
            if branch_left and rng.random() < branch_chance and i > 12:
                branch_left -= 1
                by, bx = y, x
                bang = ang + rng.choice([-1, 1]) * rng.uniform(0.7, 1.3)
                bsteps = max(4, int(steps * 0.4))
                for j in range(bsteps):
                    bang += rng.normal(0, wander * 1.1)
                    by += np.sin(bang)
                    bx += np.cos(bang)
                    carve(by, bx, taper * (1.0 - 0.6 * j / bsteps))


def speckle(rng, lum, count, scale):
    """Sparse 1px flecks: aggregate, mineral grit, litter."""
    ys = rng.integers(0, SIZE, count)
    xs = rng.integers(0, SIZE, count)
    lum[ys, xs] += rng.normal(0, scale, count)


def pits(rng, lum, count, lo, hi):
    """Rare 1px darkenings that stay ABOVE the glow gate — surface detail, not
    cracks. The surface clip in each recipe keeps them out of the ember band."""
    ys = rng.integers(0, SIZE, count)
    xs = rng.integers(0, SIZE, count)
    lum[ys, xs] -= rng.uniform(lo, hi, count)


# ---------------------------------------------------------------------------
# Surfaces. Each returns (lum, depth): the undisturbed surface luminance, and
# how far each pixel dips toward CRACK_BOTTOM. One shared composite turns the
# pair into the final tile, so the contract is applied identically to all six.
# ---------------------------------------------------------------------------

def surface_arena(rng):
    """The shipped polished concrete. UNCHANGED — same rng draws in the same
    order, so this still reproduces data/arena_floor.png byte for byte and
    extending this script never re-skins the classic arena."""
    lum = np.full((SIZE, SIZE), 88.0)
    lum += tileable_noise(rng, SIZE, 0.04, 1.6) * 7.0   # broad trowel blotches
    lum += tileable_noise(rng, SIZE, 0.12, 1.3) * 4.0   # mid-scale clouding
    lum += tileable_noise(rng, SIZE, 0.50, 0.9) * 2.2   # fine sanded grain

    # Aggregate specks: sparse 1px flecks a touch lighter/darker, plus rare
    # pinholes (polished slabs always carry a few).
    n_flecks = 900
    ys = rng.integers(0, SIZE, n_flecks)
    xs = rng.integers(0, SIZE, n_flecks)
    lum[ys, xs] += rng.normal(0, 5.5, n_flecks)
    n_pin = 70
    ys = rng.integers(0, SIZE, n_pin)
    xs = rng.integers(0, SIZE, n_pin)
    lum[ys, xs] -= rng.uniform(14, 26, n_pin)

    lum = np.clip(lum, 72, 112)  # polished surface stays above the glow gate

    depth = np.zeros((SIZE, SIZE))

    def carve(y, x, d):
        yy, xx = int(y) % SIZE, int(x) % SIZE
        depth[yy, xx] = max(depth[yy, xx], d)

    # --- Control joints on tile borders + center lines --------------------
    # Placing joints AT the wrap seam hides it; the 256 tile reads as 2x2
    # polished panels of 128px. The joints are NOT dark cuts: each is a subtle
    # emboss bevel — a soft shade line beside a light catch line — so the grid
    # reads as panel seams in polished concrete, not a painted black grid.
    # Only the hairline cracks dip into the ember-glow band.
    joint_bevel = np.zeros((SIZE, SIZE))
    for c in (0, SIZE // 2):
        for off, dv in ((-2, -5.0), (-1, -13.0), (0, 11.0), (1, 4.5)):
            wobble_r = 1.0 + 0.2 * tileable_noise(
                rng, SIZE, 0.30, 1.0)[(c + off) % SIZE, :]
            wobble_c = 1.0 + 0.2 * tileable_noise(
                rng, SIZE, 0.30, 1.0)[:, (c + off) % SIZE]
            joint_bevel[(c + off) % SIZE, :] += dv * wobble_r
            joint_bevel[:, (c + off) % SIZE] += dv * wobble_c
    lum += joint_bevel
    lum = np.clip(lum, 72, 112)  # bevels stay inside the no-glow surface band

    # --- Hairline cracks: momentum walks confined to panel interiors ------
    # Each panel gets 2-3 cracks seeded off a panel edge. They never cross the
    # edges, so tiling stays seamless without wrap logic.
    panels = [(oy, ox) for oy in (0, 128) for ox in (0, 128)]
    for oy, ox in panels:
        for _ in range(rng.integers(2, 4)):
            edge = rng.integers(0, 4)
            if edge == 0:
                y, x, ang = (oy + 3.0, ox + rng.uniform(20, 108),
                             rng.uniform(0.6, 2.5))
            elif edge == 1:
                y, x, ang = (oy + 125.0, ox + rng.uniform(20, 108),
                             -rng.uniform(0.6, 2.5))
            elif edge == 2:
                y, x, ang = (oy + rng.uniform(20, 108), ox + 3.0,
                             rng.uniform(-0.9, 0.9))
            else:
                y, x, ang = (oy + rng.uniform(20, 108), ox + 125.0,
                             np.pi - rng.uniform(-0.9, 0.9))
            steps = rng.integers(45, 110)
            strength = rng.uniform(0.55, 0.9)
            branch_left = 1
            for i in range(steps):
                ang += rng.normal(0, 0.28)
                y += np.sin(ang)
                x += np.cos(ang)
                if not (oy + 2 < y < oy + 126 and ox + 2 < x < ox + 126):
                    break
                taper = strength * (1.0 - 0.5 * i / steps)
                carve(y, x, taper)
                # hairline sections read as ~1px; occasionally widen a hair
                if rng.random() < 0.35:
                    carve(y + rng.integers(-1, 2), x + rng.integers(-1, 2),
                          taper * 0.45)
                if branch_left and rng.random() < 0.02 and i > 12:
                    branch_left -= 1
                    by, bx = y, x
                    bang = ang + rng.choice([-1, 1]) * rng.uniform(0.7, 1.3)
                    for j in range(int(steps * 0.4)):
                        bang += rng.normal(0, 0.3)
                        by += np.sin(bang)
                        bx += np.cos(bang)
                        if not (oy + 2 < by < oy + 126 and
                                ox + 2 < bx < ox + 126):
                            break
                        carve(by, bx, taper * (1.0 - 0.6 * j / (steps * 0.4)))
    return lum, depth


def surface_caves(rng):
    """Damp cave rock: lumpy swells, mineral grit, and a network of wandering
    fissures. Deliberately has NO straight line anywhere — that is what tells
    it apart from the concrete at a glance."""
    # Keep the LOWEST-frequency energy modest: a tile is only 256 map px, so a
    # strong sub-0.04 term becomes one big blotch that visibly repeats five
    # times across the board (caught on a full-board render). Detail lives in
    # the mid band instead.
    lum = np.full((SIZE, SIZE), 86.0)
    lum += tileable_noise(rng, SIZE, 0.05, 1.7) * 7.0    # boulder swell
    lum += tileable_noise(rng, SIZE, 0.13, 1.4) * 6.5    # damp blotching
    lum += tileable_noise(rng, SIZE, 0.28, 1.1) * 4.0    # pitted rock
    lum += tileable_noise(rng, SIZE, 0.45, 0.85) * 3.0   # wet grit
    # Wet sheen: the high side of the swell catches the light.
    swell = tileable_noise(rng, SIZE, 0.09, 1.4)
    lum += np.clip(swell, 0, None) ** 2 * 4.0
    speckle(rng, lum, 1400, 6.0)
    pits(rng, lum, 220, 8, 16)
    lum = np.clip(lum, 71, 116)

    depth = np.zeros((SIZE, SIZE))
    # Long wrapping fissures, then short spalled flakes off them.
    walk_cracks(rng, depth, count=9, steps_lo=70, steps_hi=150,
                strength_lo=0.65, strength_hi=0.95, wander=0.30,
                widen=0.45, branch_chance=0.035)
    walk_cracks(rng, depth, count=16, steps_lo=8, steps_hi=26,
                strength_lo=0.35, strength_hi=0.7, wander=0.55, widen=0.30)
    return lum, depth


def surface_forest(rng):
    """Forest floor: moss clumps over humus, scattered leaf litter, and the
    dark gaps between litter reading as the crack network."""
    lum = np.full((SIZE, SIZE), 84.0)
    lum += tileable_noise(rng, SIZE, 0.055, 1.6) * 8.5   # moss patches
    lum += tileable_noise(rng, SIZE, 0.16, 1.2) * 7.5    # humus clumping
    lum += tileable_noise(rng, SIZE, 0.55, 0.8) * 3.0    # needle grain
    # Leaf litter: short strokes at random angles, each with a shadow side, so
    # the floor reads as scattered leaves over humus rather than a green wash.
    for _ in range(430):
        y0 = rng.uniform(0, SIZE)
        x0 = rng.uniform(0, SIZE)
        ang = rng.uniform(0, 2 * np.pi)
        ln = int(rng.integers(3, 9))
        val = rng.uniform(7.0, 19.0)
        for t in range(ln):
            yy = int(y0 + np.sin(ang) * t) % SIZE
            xx = int(x0 + np.cos(ang) * t) % SIZE
            lum[yy, xx] += val
            lum[(yy + 1) % SIZE, (xx + 1) % SIZE] -= val * 0.55
    speckle(rng, lum, 900, 5.0)
    lum = np.clip(lum, 70, 116)

    depth = np.zeros((SIZE, SIZE))
    # Root ridges: long, low-wander. Litter shadow gaps: short and deep, so
    # the ember picks out the gaps between leaves.
    walk_cracks(rng, depth, count=6, steps_lo=60, steps_hi=130,
                strength_lo=0.55, strength_hi=0.85, wander=0.22,
                widen=0.30, branch_chance=0.05)
    walk_cracks(rng, depth, count=26, steps_lo=4, steps_hi=13,
                strength_lo=0.50, strength_hi=0.90, wander=0.70, widen=0.25)
    return lum, depth


def surface_desert(rng):
    """Sun-baked mud over pale sand: wind ripples on a bright surface plus a
    Voronoi polygon crack network — the most legible biome from above, and the
    one whose endzone ember reads as a lit crack lattice."""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(float)
    lum = np.full((SIZE, SIZE), 104.0)
    lum += tileable_noise(rng, SIZE, 0.05, 1.6) * 5.5    # dune drift
    lum += tileable_noise(rng, SIZE, 0.5, 0.85) * 2.4    # sand grain
    # Wind ripples: an integer number of periods across the tile keeps them
    # seamless; a noise phase keeps them from reading as a screen pattern.
    phase = tileable_noise(rng, SIZE, 0.08, 1.4) * 9.0
    lum += np.sin(2 * np.pi * 7 * (xx + 0.45 * yy) / SIZE + phase) * 2.8
    speckle(rng, lum, 700, 4.5)
    pits(rng, lum, 120, 6, 14)
    lum = np.clip(lum, 88, 128)

    # Voronoi mud-crack lattice on a torus, with the sample grid warped by
    # noise so the plates are organic rather than crystalline.
    n = 24
    pts = rng.random((n, 2)) * SIZE
    wy = yy + tileable_noise(rng, SIZE, 0.10, 1.3) * 5.0
    wx = xx + tileable_noise(rng, SIZE, 0.10, 1.3) * 5.0
    d = np.empty((n, SIZE, SIZE))
    for i in range(n):
        dy = np.abs(wy - pts[i, 0])
        dy = np.minimum(dy, SIZE - dy)
        dx = np.abs(wx - pts[i, 1])
        dx = np.minimum(dx, SIZE - dx)
        d[i] = np.hypot(dy, dx)
    ds = np.sort(d, axis=0)
    edge = ds[1] - ds[0]                      # 0 exactly on a cell boundary
    depth = np.clip((1.5 - edge) / 1.5, 0, 1) ** 2.0 * 0.95
    # Curling: the mud lifts at the crack, so light catches the plate edge.
    lum += np.clip((3.0 - edge) / 3.0, 0, 1) ** 3 * 5.0
    lum = np.clip(lum, 88, 128)
    # A few hairlines inside the plates.
    walk_cracks(rng, depth, count=10, steps_lo=6, steps_hi=20,
                strength_lo=0.30, strength_hi=0.60, wander=0.50, widen=0.15)
    return lum, depth


def surface_city(rng):
    """Asphalt pavers in running bond: a 64x32 brick grid offset every row,
    with tar mottle and a worn light catch on each paver's top-left. The only
    biome with a hard rectilinear read, which is exactly the point."""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    lum = np.full((SIZE, SIZE), 82.0)
    lum += tileable_noise(rng, SIZE, 0.045, 1.6) * 6.5   # tar pour mottle
    lum += tileable_noise(rng, SIZE, 0.55, 0.85) * 3.2   # aggregate grain
    speckle(rng, lum, 1600, 6.5)
    pits(rng, lum, 160, 6, 13)

    row_h, brick_w = 32, 64
    row = yy // row_h
    offset = (row % 2) * (brick_w // 2)
    local_x = (xx + offset) % brick_w
    local_y = yy % row_h
    # Per-paver tone variation (each brick is its own casting).
    brick_id = (row * 7919 + ((xx + offset) // brick_w) * 104729) % 9973
    tone = ((brick_id * 2654435761) % 1000) / 1000.0
    lum += (tone - 0.5) * 9.0
    # Worn light catch along the top-left edge of every paver.
    lum += np.where(local_y < 2, 5.0, 0.0)
    lum += np.where(local_x < 2, 4.0, 0.0)
    lum = np.clip(lum, 70, 110)

    # Mortar joints: 1px seams on every paver boundary, cut to a depth that
    # lands them INSIDE the ember band rather than at the bottom of it, so the
    # endzone reads as a lit paver grid instead of a solid team wash.
    jitter = tileable_noise(rng, SIZE, 0.35, 1.0) * 0.12
    joint = (local_y >= row_h - 1) | (local_x >= brick_w - 1)
    depth = np.where(joint, np.clip(0.80 + jitter, 0.55, 0.95), 0.0)
    # Cracked asphalt running across a few pavers.
    walk_cracks(rng, depth, count=7, steps_lo=25, steps_hi=70,
                strength_lo=0.50, strength_hi=0.85, wander=0.35, widen=0.25)
    return lum, depth


def surface_plains(rng):
    """Dry steppe turf: horizontally combed blade grain, tussock clumps, and
    sparse bare-dirt seams where the sod has split."""
    lum = np.full((SIZE, SIZE), 92.0)
    lum += tileable_noise(rng, SIZE, 0.05, 1.7) * 6.0    # ground swell
    lum += tileable_noise(rng, SIZE, 0.14, 1.25) * 6.0   # tussock clumps
    # Blade grain: fine noise smeared along one axis so the surface reads as
    # combed grass instead of concrete grit.
    fine = tileable_noise(rng, SIZE, 0.6, 0.7)
    smear = sum(np.roll(fine, k, axis=1) for k in range(-3, 4)) / 7.0
    lum += smear * 6.0
    # Seed heads: bright 1-2px dots on the tussock tops.
    for _ in range(320):
        y0 = int(rng.integers(0, SIZE))
        x0 = int(rng.integers(0, SIZE))
        lum[y0, x0] += rng.uniform(6, 14)
        lum[(y0 + 1) % SIZE, x0] += rng.uniform(2, 6)
    speckle(rng, lum, 800, 4.0)
    lum = np.clip(lum, 74, 118)

    depth = np.zeros((SIZE, SIZE))
    # Bare-dirt seams: few, long, meandering, and cut deep enough that their
    # heads bottom out below CrackLevel (turf is the least fissured biome, so
    # without that the endzone ember would never reach full strength here).
    walk_cracks(rng, depth, count=5, steps_lo=80, steps_hi=170,
                strength_lo=0.80, strength_hi=1.00, wander=0.26,
                widen=0.50, branch_chance=0.04)
    walk_cracks(rng, depth, count=14, steps_lo=4, steps_hi=12,
                strength_lo=0.40, strength_hi=0.75, wander=0.80, widen=0.35)
    return lum, depth


# ---------------------------------------------------------------------------
# Recipes: surface + rng seed + color ramp + final clip + output file. The
# ramp multipliers are luminance-normalized in to_rgb, so the hue is free but
# the contract still holds.
# ---------------------------------------------------------------------------

RECIPES = {
    "arena":  (surface_arena, 1177, (1.020, 1.000, 0.965), (24, 118),
               "arena_floor.png"),
    "caves":  (surface_caves, 2203, (1.055, 0.995, 0.905), (22, 122),
               "arena_floor_caves.png"),
    "forest": (surface_forest, 3307, (0.870, 1.070, 0.760), (22, 122),
               "arena_floor_forest.png"),
    "desert": (surface_desert, 4409, (1.175, 0.985, 0.660), (22, 134),
               "arena_floor_desert.png"),
    # City stays a NEUTRAL-warm asphalt: the house style forbids cold
    # blue-slate, and a b-heavy ramp made the pavers read as blue stone.
    "city":   (surface_city, 5501, (1.020, 0.998, 0.955), (20, 118),
               "arena_floor_city.png"),
    "plains": (surface_plains, 6607, (1.010, 1.045, 0.760), (24, 126),
               "arena_floor_plains.png"),
}


def to_rgb(v, tint):
    """Map a luminance field to rgb through a LUMINANCE-NORMALIZED tint, so
    the saved pixels' engine luminance equals the field this script gated.
    (The default arena ramp keeps its historical +1.5/-1.0 offsets, which is
    what makes its output byte-identical to the shipped tile.)"""
    kr, kg, kb = tint
    if tint == RECIPES["arena"][2]:
        r = np.clip(v * 1.020 + 1.5, 0, 255)
        g = np.clip(v, 0, 255)
        b = np.clip(v * 0.965 - 1.0, 0, 255)
        return np.stack([r, g, b], axis=-1).astype(np.uint8)
    norm = 0.30 * kr + 0.59 * kg + 0.11 * kb
    r = np.clip(v * kr / norm, 0, 255)
    g = np.clip(v * kg / norm, 0, 255)
    b = np.clip(v * kb / norm, 0, 255)
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def check_contract(name, path, img):
    """Measure the SAVED tile against the map_art.nim gates. Raises on a
    violation: a floor that breaks the contract must never reach data/."""
    l = lum_of(img)
    glow_pct = (l < FACE_LEVEL).mean() * 100
    full_pct = (l <= CRACK_LEVEL).mean() * 100
    face_pct = (l >= FACE_LEVEL).mean() * 100
    print(f"  {name:7s} lum min/max/mean {l.min()}/{l.max()}/{l.mean():.1f}  "
          f"face>=66 {face_pct:6.2f}%  glow<66 {glow_pct:5.2f}%  "
          f"full<=34 {full_pct:5.2f}%")
    problems = []
    if glow_pct < GLOW_PCT_MIN:
        problems.append(
            f"only {glow_pct:.2f}% of texels are under FaceLevel {FACE_LEVEL}"
            f" (< {GLOW_PCT_MIN}%): the endzone would show no ember glow")
    if glow_pct > GLOW_PCT_MAX:
        problems.append(
            f"{glow_pct:.2f}% of texels are under FaceLevel {FACE_LEVEL}"
            f" (> {GLOW_PCT_MAX}%): the endzone would flood with team color")
    if l.min() > CRACK_LEVEL:
        problems.append(
            f"no texel reaches CrackLevel {CRACK_LEVEL} (darkest is"
            f" {l.min()}): crack bottoms never glow at full strength")
    if problems:
        raise SystemExit(f"{path.name} breaks the luminance contract: " +
                         "; ".join(problems))


def build(name):
    surface, seed, tint, (clip_lo, clip_hi), out_name = RECIPES[name]
    rng = np.random.default_rng(seed)
    lum, depth = surface(rng)
    # Composite: dip luminance toward the crack bottom (full depth lands at 27,
    # below CrackLevel 34 -> full ember; the tapers cross the partial band on
    # their own), then a 1px light catch on the lower-right of deep cuts, which
    # keeps cracks crisp instead of muddy.
    lum = lum * (1.0 - depth) + CRACK_BOTTOM * depth
    spall = np.roll(np.roll(depth, 1, axis=0), 1, axis=1) - depth
    lum += np.clip(spall, 0, 1) * 6.0
    img = Image.fromarray(to_rgb(np.clip(lum, clip_lo, clip_hi), tint))
    out = OUT_DIR / out_name
    img.save(out)
    print(f"wrote {out}")
    check_contract(name, out, Image.open(out))


if __name__ == "__main__":
    wanted = sys.argv[1:] or list(RECIPES)
    for name in wanted:
        if name not in RECIPES:
            raise SystemExit(
                f"unknown floor '{name}'; known: {', '.join(RECIPES)}")
        build(name)
