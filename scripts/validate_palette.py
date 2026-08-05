#!/usr/bin/env python3
"""Validate data/team_palette.json — the shared team-color contract.

Checks (see docs/COLOR_CONTRACT.md):
  A. Every pair of vibrant `game` colors is perceptually distinguishable
     (CIEDE2000). Any 4-subset of the palette can be live simultaneously,
     so the WORST pair over the whole palette is the number that matters.
  B. Distinguishability survives the paint-stain rendering: colors are
     darkened 8% and composited at ~40% alpha over terrain. Checked over
     sand terrain (#b8a888) and over paper (#f2e8d8). Blending is done in
     sRGB byte space, matching the canvas renderer.
  C. Ink&print variants (the webpage picker chips) have adequate contrast
     against the paper (#f2e8d8, WCAG >= 3:1 for non-text UI components),
     stay distinguishable from ink near-black (viewer ink #2a1f16 and web
     ink #111827), and no two chips from DIFFERENT slugs collapse into
     each other.
  D. Structural sanity: version, slug uniqueness, first four slugs are the
     wire words with their exact stock hexes, declared `hue` matches the
     hue derived from the `game` hex (ordering rationale can't drift).

No exotic deps — stdlib only. Exit 0 on pass, 1 on any failure.
Usage: python3 scripts/validate_palette.py [path/to/team_palette.json]
"""

import json
import math
import os
import sys

# ---------------------------------------------------------------- constants

PAPER = "#f2e8d8"      # webpage/viewer paper (client/replay_broadcast.html --paper)
TERRAIN = "#b8a888"    # approximate sand terrain tone under paint stains
INK_BLACKS = {
    "viewer-ink #2a1f16": "#2a1f16",   # client/replay_broadcast.html --ink
    "web-ink #111827": "#111827",      # softmax.com --fg (warm near-black)
}

STAIN_DARKEN = 0.92    # stains render the team color darkened 8%
STAIN_ALPHA = 0.40     # ...composited at ~40% alpha over the terrain

# Thresholds (stated in docs/COLOR_CONTRACT.md — change them there too).
T_GAME = 20.0          # CIEDE2000 between any two vibrant game colors
T_STAIN = 8.0          # CIEDE2000 between any two composited stain colors
T_INK_CONTRAST = 3.0   # WCAG contrast ratio of every ink chip vs paper
T_INK_BLACK = 12.0     # CIEDE2000 of every ink chip vs both near-blacks
T_INK_CROSS = 6.0      # CIEDE2000 between ink chips of DIFFERENT slugs
HUE_TOL = 8.0          # declared hue vs hue-from-hex tolerance (degrees)

STOCK = [  # wire word -> exact stock hex (src/ctf/sim_types.nim EndzoneColors)
    ("red", "#e0523a"),
    ("blue", "#3f7cc4"),
    ("green", "#45a85e"),
    ("yellow", "#ddc531"),
]

# ------------------------------------------------------------- color maths


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb_to_hex(rgb):
    return "#%02x%02x%02x" % tuple(int(round(c)) for c in rgb)


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = (srgb_to_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(rgb1, rgb2):
    l1, l2 = luminance(rgb1), luminance(rgb2)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def rgb_to_lab(rgb):
    r, g, b = (srgb_to_linear(c) for c in rgb)
    # sRGB D65 -> XYZ
    x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
    y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
    z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
    xn, yn, zn = 0.95047, 1.0, 1.08883
    eps, kap = 216.0 / 24389.0, 24389.0 / 27.0

    def f(t):
        return t ** (1.0 / 3.0) if t > eps else (kap * t + 16.0) / 116.0

    fx, fy, fz = f(x / xn), f(y / yn), f(z / zn)
    return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


def ciede2000(lab1, lab2):
    """Standard CIEDE2000 (Sharma et al. 2005)."""
    L1, a1, b1 = lab1
    L2, a2, b2 = lab2
    C1 = math.hypot(a1, b1)
    C2 = math.hypot(a2, b2)
    Cbar = (C1 + C2) / 2.0
    G = 0.5 * (1.0 - math.sqrt(Cbar ** 7 / (Cbar ** 7 + 25.0 ** 7)))
    ap1, ap2 = (1 + G) * a1, (1 + G) * a2
    Cp1, Cp2 = math.hypot(ap1, b1), math.hypot(ap2, b2)

    def hp(ap, b):
        if ap == 0 and b == 0:
            return 0.0
        return math.degrees(math.atan2(b, ap)) % 360.0

    hp1, hp2 = hp(ap1, b1), hp(ap2, b2)
    dLp = L2 - L1
    dCp = Cp2 - Cp1
    if Cp1 * Cp2 == 0:
        dhp = 0.0
    elif abs(hp2 - hp1) <= 180:
        dhp = hp2 - hp1
    elif hp2 - hp1 > 180:
        dhp = hp2 - hp1 - 360
    else:
        dhp = hp2 - hp1 + 360
    dHp = 2 * math.sqrt(Cp1 * Cp2) * math.sin(math.radians(dhp) / 2.0)
    Lbp = (L1 + L2) / 2.0
    Cbp = (Cp1 + Cp2) / 2.0
    if Cp1 * Cp2 == 0:
        hbp = hp1 + hp2
    elif abs(hp1 - hp2) <= 180:
        hbp = (hp1 + hp2) / 2.0
    elif hp1 + hp2 < 360:
        hbp = (hp1 + hp2 + 360) / 2.0
    else:
        hbp = (hp1 + hp2 - 360) / 2.0
    T = (1 - 0.17 * math.cos(math.radians(hbp - 30))
         + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6))
         - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    dtheta = 30.0 * math.exp(-(((hbp - 275.0) / 25.0) ** 2))
    Rc = 2.0 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25.0 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * dtheta)) * Rc
    return math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2
                     + Rt * (dCp / Sc) * (dHp / Sh))


def de(hex1, hex2):
    return ciede2000(rgb_to_lab(hex_to_rgb(hex1)), rgb_to_lab(hex_to_rgb(hex2)))


def rgb_hue(rgb):
    r, g, b = (c / 255.0 for c in rgb)
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    if d == 0:
        return 0.0
    if mx == r:
        h = ((g - b) / d) % 6
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return (60.0 * h) % 360.0


def stain(hexcolor, ground):
    """Paint-stain approximation: darken 8%, composite 40% over ground.

    sRGB byte-space blending, matching the canvas renderer.
    """
    src = tuple(c * STAIN_DARKEN for c in hex_to_rgb(hexcolor))
    grd = hex_to_rgb(ground)
    return rgb_to_hex(tuple(STAIN_ALPHA * s + (1 - STAIN_ALPHA) * g
                            for s, g in zip(src, grd)))


# ------------------------------------------------------------------ checks


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        root, "data", "team_palette.json")
    with open(path) as f:
        pal = json.load(f)

    failures = []
    colors = pal.get("colors", [])
    slugs = [c["slug"] for c in colors]

    def fail(msg):
        failures.append(msg)
        print("  FAIL  " + msg)

    def ok(msg):
        print("  ok    " + msg)

    # -- D. structure -------------------------------------------------------
    print("[structure]")
    if pal.get("version") != 1:
        fail("version must be 1, got %r" % pal.get("version"))
    else:
        ok("version 1")
    if len(set(slugs)) != len(slugs):
        fail("duplicate slugs: %s" % slugs)
    for i, (word, hexval) in enumerate(STOCK):
        if i >= len(colors) or colors[i]["slug"] != word:
            fail("colors[%d] must be stock slug %r (wire word), got %r"
                 % (i, word, colors[i]["slug"] if i < len(colors) else None))
        elif colors[i]["game"].lower() != hexval:
            fail("colors[%d] (%s) game hex must be stock %s, got %s"
                 % (i, word, hexval, colors[i]["game"]))
        elif colors[i].get("wire") != word:
            fail("colors[%d] (%s) must declare wire: %r" % (i, word, word))
        else:
            ok("stock slug %-6s = %s (wire word preserved)" % (word, hexval))
    for c in colors[len(STOCK):]:
        if c.get("wire") is not None:
            fail("non-stock slug %r must have wire: null (wire words are "
                 "frozen engine vocabulary)" % c["slug"])
    for c in colors:
        derived = rgb_hue(hex_to_rgb(c["game"]))
        delta = min(abs(derived - c["hue"]), 360 - abs(derived - c["hue"]))
        if delta > HUE_TOL:
            fail("%s: declared hue %d but game hex %s has hue %.0f"
                 % (c["slug"], c["hue"], c["game"], derived))
        if not (2 <= len(c.get("ink", [])) <= 3):
            fail("%s: need 2-3 ink variants, got %d"
                 % (c["slug"], len(c.get("ink", []))))

    # -- A. vibrant game colors --------------------------------------------
    print("[A: game colors pairwise, CIEDE2000 >= %.0f]" % T_GAME)
    worst_a = None
    for i in range(len(colors)):
        for j in range(i + 1, len(colors)):
            d = de(colors[i]["game"], colors[j]["game"])
            pair = "%s/%s" % (slugs[i], slugs[j])
            if worst_a is None or d < worst_a[0]:
                worst_a = (d, pair)
            if d < T_GAME:
                fail("game %-16s dE2000 = %5.1f  (< %.0f)" % (pair, d, T_GAME))
    if worst_a:
        print("  worst pair: %-16s dE2000 = %5.1f" % (worst_a[1], worst_a[0]))

    # -- B. stain rendering -------------------------------------------------
    print("[B: stains (x%.2f, %d%% alpha) pairwise, CIEDE2000 >= %.0f]"
          % (STAIN_DARKEN, int(STAIN_ALPHA * 100), T_STAIN))
    worst_b = None
    for ground, gname in ((TERRAIN, "terrain"), (PAPER, "paper")):
        stains = [stain(c["game"], ground) for c in colors]
        for i in range(len(colors)):
            for j in range(i + 1, len(colors)):
                d = ciede2000(rgb_to_lab(hex_to_rgb(stains[i])),
                              rgb_to_lab(hex_to_rgb(stains[j])))
                pair = "%s/%s on %s" % (slugs[i], slugs[j], gname)
                if worst_b is None or d < worst_b[0]:
                    worst_b = (d, pair)
                if d < T_STAIN:
                    fail("stain %-26s dE2000 = %5.1f  (< %.0f)"
                         % (pair, d, T_STAIN))
    if worst_b:
        print("  worst pair: %-26s dE2000 = %5.1f" % (worst_b[1], worst_b[0]))

    # -- C. ink variants ----------------------------------------------------
    print("[C: ink chips — contrast vs paper >= %.1f, dE vs near-black >= %.0f,"
          " cross-slug dE >= %.0f]" % (T_INK_CONTRAST, T_INK_BLACK, T_INK_CROSS))
    paper = hex_to_rgb(PAPER)
    worst_contrast = worst_black = worst_cross = None
    chips = []  # (slug, hex)
    for c in colors:
        for h in c["ink"]:
            chips.append((c["slug"], h))
    for slug, h in chips:
        cr = contrast_ratio(hex_to_rgb(h), paper)
        if worst_contrast is None or cr < worst_contrast[0]:
            worst_contrast = (cr, "%s %s" % (slug, h))
        if cr < T_INK_CONTRAST:
            fail("ink %s %s contrast vs paper = %.2f (< %.1f)"
                 % (slug, h, cr, T_INK_CONTRAST))
        for bname, bhex in INK_BLACKS.items():
            d = de(h, bhex)
            if worst_black is None or d < worst_black[0]:
                worst_black = (d, "%s %s vs %s" % (slug, h, bname))
            if d < T_INK_BLACK:
                fail("ink %s %s vs %s dE2000 = %.1f (< %.0f)"
                     % (slug, h, bname, d, T_INK_BLACK))
    for i in range(len(chips)):
        for j in range(i + 1, len(chips)):
            if chips[i][0] == chips[j][0]:
                continue  # same slug: variants may sit close by design
            d = de(chips[i][1], chips[j][1])
            pair = "%s %s / %s %s" % (chips[i] + chips[j])
            if worst_cross is None or d < worst_cross[0]:
                worst_cross = (d, pair)
            if d < T_INK_CROSS:
                fail("ink cross-slug %-40s dE2000 = %5.1f (< %.0f)"
                     % (pair, d, T_INK_CROSS))
    if worst_contrast:
        print("  worst contrast vs paper: %-24s = %.2f"
              % (worst_contrast[1], worst_contrast[0]))
    if worst_black:
        print("  worst vs near-black: %-40s dE2000 = %5.1f"
              % (worst_black[1], worst_black[0]))
    if worst_cross:
        print("  worst cross-slug pair: %-40s dE2000 = %5.1f"
              % (worst_cross[1], worst_cross[0]))

    # ----------------------------------------------------------------------
    print()
    if failures:
        print("PALETTE INVALID — %d failure(s)." % len(failures))
        return 1
    print("PALETTE VALID — %d colors, %d ink chips." % (len(colors), len(chips)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
