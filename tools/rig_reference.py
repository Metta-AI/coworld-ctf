#!/usr/bin/env python3
"""AUTHORITATIVE rig reference: reproduces the validated final compositor
(build_live_html.py render + rig_preview.py place2) using the exact validated
parts from data/rig/validated/. This is the pixel target the Nim port must match.
Everything here transcribes the approved session's math — no new geometry.

  python3 tools/rig_reference.py --mode poses --out /tmp/rigview/REF_poses.jpg
"""
import argparse, json, math, os
from PIL import Image, ImageDraw
import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAL = os.path.join(REPO, "data", "rig", "validated")
G = json.load(open(os.path.join(VAL, "geometry.json")))
HUB = G["artHub"]
NAT = G["native"]
TEAM_RGB = {"blue": tuple(G["teamRGB"]["blue"]), "red": tuple(G["teamRGB"]["red"])}
PARTS = G["parts"]

# Final TUNED feel (rig_def.json TUNED) — the numbers the live tool shipped.
TUCK, SW = 45.0, 86.0
# On-map size: pick SIZE so the head reads ~28px (head art h=514 * SIZE*native.head).
# 514 * SIZE * 0.6006 = 28  ->  SIZE = 0.0907. This is the ONE size dial.
SIZE = 0.0907

_cache = {}


def load(name):
    if name in _cache:
        return _cache[name]
    im = Image.open(os.path.join(VAL, name + ".png")).convert("RGBA")
    _cache[name] = im
    return im


def retint(im, rgb):
    """Desaturate the yellow paint to luminance, remultiply toward the team hue —
    the exact rig_preview.py/​build_live_html tint (paint pixels only)."""
    arr = np.array(im).astype(int); a = arr[..., 3]
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    mx = np.maximum(np.maximum(r, g), b); mn = np.minimum(np.minimum(r, g), b)
    paint = (a >= 40) & ((mx - mn) > 35) & (mx > 70)
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    k = np.clip(lum / 175.0, 0.0, 1.35)
    out = arr.copy()
    for c, tv in enumerate(rgb):
        out[..., c] = np.where(paint, np.clip(k * tv, 0, 255), arr[..., c])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def place(canvas, im, bone, pivot, scale, rot_deg):
    """Pin im's bone art-px at canvas pivot, scaled, rotated rot_deg (CSS+=CW→negate)."""
    sw, sh = max(1, round(im.width * scale)), max(1, round(im.height * scale))
    sc = im.resize((sw, sh), Image.LANCZOS)
    bx, by = bone[0] * scale, bone[1] * scale
    diag = int(math.hypot(sw, sh)) + 4
    pad = Image.new("RGBA", (2 * diag, 2 * diag), (0, 0, 0, 0))
    pad.alpha_composite(sc, (diag - round(bx), diag - round(by)))
    rot = pad.rotate(-rot_deg, resample=Image.BICUBIC, center=(diag, diag))
    canvas.alpha_composite(rot, (round(pivot[0] - diag), round(pivot[1] - diag)))


def art_to_screen(pt, dhead, S, center):
    a = -math.radians(dhead)
    dx, dy = pt[0] - HUB[0], pt[1] - HUB[1]
    rx = dx * math.cos(a) - dy * math.sin(a)
    ry = dx * math.sin(a) + dy * math.cos(a)
    return (center[0] + rx * S, center[1] + ry * S)


def render(team, turnAmt, aimDeg=90.0, headingDeg=90.0, carrying=False, size_px=300, bones=False):
    S = SIZE * NAT["legset"]; wS = SIZE * NAT["wheel"]; hS = SIZE * NAT["head"]
    W = 220; C = (W // 2, W // 2)
    cv = Image.new("RGBA", (W, W), (60, 64, 52, 255))
    dhead = headingDeg - 90.0
    t = turnAmt
    left_open = max(0.0, t) * SW; right_open = max(0.0, -t) * SW
    swing = {"front_left": -TUCK + left_open, "front_right": TUCK - right_open, "rear": 0.0}
    hips, feet = {}, {}
    for leg in ("front_right", "front_left", "rear"):
        hips[leg] = art_to_screen(PARTS[leg]["hip"], dhead, S, C)
        fp = PARTS[leg]["foot"]; hp = PARTS[leg]["hip"]
        rel = (fp[0] - hp[0], fp[1] - hp[1]); tot = math.radians(dhead + swing[leg])
        rx = rel[0] * math.cos(-tot) - rel[1] * math.sin(-tot)
        ry = rel[0] * math.sin(-tot) + rel[1] * math.cos(-tot)
        feet[leg] = (hips[leg][0] + rx * S, hips[leg][1] + ry * S)
    # wheels (bottom): rest caster = along the leg's travel; here point along +y (north).
    wheel = load("wheel")
    for leg in ("front_right", "front_left", "rear"):
        # caster rest: point the wheel along the foot's radial (toward travel); at rest,
        # north. Use the leg swing direction as a stand-in for the on-map caster.
        place(cv, wheel, PARTS["wheel"]["axle"], feet[leg], wS, 0.0)
    # legs pinned at their own hip
    for leg in ("rear", "front_left", "front_right"):
        place(cv, retint(load(leg), TEAM_RGB[team]), PARTS[leg]["hip"], hips[leg], S, dhead + swing[leg])
    # hub disc
    place(cv, retint(load("hub_disc"), TEAM_RGB[team]), PARTS["hub_disc"]["bone"], C, S, dhead)
    # arms (under head) if carrying, then head — both aim
    if carrying:
        place(cv, retint(load("arms"), TEAM_RGB[team]), PARTS["arms"]["bone"], C, hS, aimDeg - 90.0)
    place(cv, retint(load("head"), TEAM_RGB[team]), PARTS["head"]["bone"], C, hS, aimDeg - 90.0)
    if bones:
        d = ImageDraw.Draw(cv)
        for leg in hips:
            d.line([hips[leg], feet[leg]], fill=(255, 220, 90, 200), width=2)
    return cv.resize((size_px, size_px), Image.LANCZOS)


def sheet(team, specs, out):
    tiles = [(lab, render(team, **kw)) for lab, kw in specs]
    W = len(tiles) * 300 + (len(tiles) + 1) * 8; H = 300 + 30
    s = Image.new("RGB", (W, H), (30, 32, 28)); d = ImageDraw.Draw(s); x = 8
    for lab, im in tiles:
        d.text((x, 6), lab, fill=(235, 235, 225)); s.paste(im.convert("RGB"), (x, 26)); x += 308
    s.save(out, quality=92); print("wrote", out, s.size)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--team", default="red")
    ap.add_argument("--out", default="/tmp/rigview/REF_poses.jpg")
    a = ap.parse_args()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    sheet(a.team, [
        ("rest (turn 0)", dict(turnAmt=0.0)),
        ("LEFT (turn +1)", dict(turnAmt=1.0)),
        ("RIGHT (turn -1)", dict(turnAmt=-1.0)),
        ("carry, aim NE", dict(turnAmt=0.0, aimDeg=45.0, carrying=True)),
    ], a.out)
