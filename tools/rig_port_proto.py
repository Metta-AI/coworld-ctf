#!/usr/bin/env python3
"""STAGE-2 prototype: composite the articulated cog from the COMMITTED data/rig art,
driven by a faithful port of the FINAL one-sided controller (build_live_html.py).

This is the visual reference the Nim port must reproduce. Works entirely in the
committed 1046x1024 canvas (hub 523,412) so the geometry it proves is exactly what
sim.nim will bake. No /tmp layer dependency.

  python3 tools/rig_port_proto.py --team red --mode turns  --out /tmp/rigview/proto_turns.jpg
  python3 tools/rig_port_proto.py --team red --mode carry  --out /tmp/rigview/proto_carry.jpg
  python3 tools/rig_port_proto.py --team red --mode drive  --out /tmp/rigview/proto_drive.gif
"""
import argparse, math, os
import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RIG = os.path.join(REPO, "data", "rig")
HUB = (523.0, 412.0)                       # committed-canvas pivot (anchors.json)
CANVAS_W, CANVAS_H = 1046, 1024

# committed-frame hips/feet (mapped from 1031-art via scale-about-hub k=1.326, verified).
LEGS = {
    "front_right": dict(hip=(591.4, 353.7), foot=(1027.2, 73.4)),
    "front_left":  dict(hip=(449.1, 363.5), foot=(9.0, 67.3)),
    "rear":        dict(hip=(539.7, 481.0), foot=(518.1, 1031.6)),
}
WHEEL_AXLE = (44.0, 121.2)
ARMS_BONE = (191.5, 613.0)
HEAD_BONE_FRAC = None  # head is on the 1046x1024 canvas already; centroid ~ hub

# FINAL TUNED feel (rig_def.json TUNED)
TUCK, SW = 45.0, 86.0
WFULL = 3.0
BODY_RATE = 2.0
CAST_RATE = 32.0
STOP, REVMAX, COMMIT = 8, 96, 12
TURN = 256


def brads_of(dx, dy):
    if dx == 0 and dy == 0:
        return 0
    b = round(math.atan2(-dy, dx) * (TURN / 2) / math.pi)
    return int(b % TURN)


def bdiff(a, b):
    d = ((a - b) % TURN + TURN) % TURN
    if d > TURN // 2:
        d -= TURN
    return d


def ease(c, t, s):
    return int((c + max(-s, min(s, bdiff(t, c)))) % TURN)


def ease_f(c, t, s):
    return c + max(-s, min(s, t - c))


def b2d(b):
    return b * 360.0 / TURN


class Cog:
    def __init__(self, head=0):
        self.head = head; self.toe = head; self.aim = head
        self.rev = 0; self.w = 0; self.wavg = 0.0; self.turn = 0.0
        self.caster = {k: head for k in LEGS}
        self.lastfoot = {}


def step_drive(cog, vx, vy, aim):
    cog.aim = aim
    speed = abs(vx) + abs(vy)
    if speed < STOP:
        cog.rev = max(0, cog.rev - 1); cog.w = 0
    else:
        travel = brads_of(vx, vy)
        err = b2d(bdiff(travel, cog.head)); off = abs(err); back = off > REVMAX
        cog.rev = min(cog.rev + 1, COMMIT * 2) if back else max(0, cog.rev - 2)
        committed = cog.rev >= COMMIT
        tgt = cog.head if (back and not committed) else travel
        rate = max(BODY_RATE / 2, round(BODY_RATE * STOP * 4 / max(speed, STOP * 4)))
        prev = cog.head
        cog.head = ease(cog.head, tgt, int(rate))
        cog.w = bdiff(cog.head, prev)
        cog.toe = ease(cog.toe, travel, 40)
    t_inst = max(-1.0, min(1.0, b2d(cog.w) / WFULL))
    cog.wavg = cog.wavg * 0.7 + t_inst * 0.3
    cog.turn = ease_f(cog.turn, cog.wavg, 0.12)


# ---- art loading + team-tint (retint yellow paint toward team hue) ----
TEAM_RGB = {"blue": (74, 102, 144), "red": (166, 66, 45)}
_cache = {}


def load(name):
    if name in _cache:
        return _cache[name]
    im = Image.open(os.path.join(RIG, name)).convert("RGBA")
    _cache[name] = im
    return im


def wedge_legs(team):
    """hub-disc + 3 legs from chassis_{team}.png (already team-tinted art)."""
    key = f"wedge_{team}"
    if key in _cache:
        return _cache[key]
    im = load(f"chassis_{team}.png")
    arr = np.array(im); H, W = arr.shape[:2]; a = arr[..., 3]
    yy, xx = np.mgrid[0:H, 0:W]
    ang = (np.degrees(np.arctan2(-(yy - HUB[1]), xx - HUB[0])) + 360) % 360
    r = np.hypot(xx - HUB[0], yy - HUB[1])
    wedges = {"front_right": (330, 82), "front_left": (82, 200), "rear": (200, 330)}
    out = {}
    for leg, (a0, a1) in wedges.items():
        sel = ((ang >= a0) & (ang < a1)) if a0 < a1 else ((ang >= a0) | (ang < a1))
        sel = sel & (r > 70) & (a >= 40)
        la = arr.copy(); la[~sel, 3] = 0
        out[leg] = Image.fromarray(la, "RGBA")
    disc = arr.copy(); disc[(r > 175) | (a < 40), 3] = 0
    out["hub_disc"] = Image.fromarray(disc, "RGBA")
    _cache[key] = out
    return out


def place(canvas, im, bone, px, py, scale, rot_deg):
    """Pin im's bone art-px at canvas (px,py), scaled, rotated rot_deg (CSS +=CW -> negate)."""
    sw, sh = max(1, round(im.width * scale)), max(1, round(im.height * scale))
    scaled = im.resize((sw, sh), Image.LANCZOS)
    bx, by = bone[0] * scale, bone[1] * scale
    diag = int(math.hypot(sw, sh)) + 4
    pad = Image.new("RGBA", (2 * diag, 2 * diag), (0, 0, 0, 0))
    pad.alpha_composite(scaled, (diag - round(bx), diag - round(by)))
    rot = pad.rotate(-rot_deg, resample=Image.BICUBIC, center=(diag, diag))
    canvas.alpha_composite(rot, (round(px - diag), round(py - diag)))


def rot_about(pt, center, ddeg):
    a = -math.radians(ddeg)
    dx, dy = pt[0] - center[0], pt[1] - center[1]
    return (center[0] + dx * math.cos(a) - dy * math.sin(a),
            center[1] + dx * math.sin(a) + dy * math.cos(a))


def render(team, cog, size_px=360, carrying=False, bones=False, hide_head=False):
    """Render one articulated frame to a size_px square (body-centered)."""
    # work canvas at committed resolution, then crop+scale
    cv = Image.new("RGBA", (CANVAS_W * 2, CANVAS_H * 2), (92, 96, 78, 255))
    cx, cy = CANVAS_W, CANVAS_H              # cog center at canvas center of the 2x work img
    off = (cx - HUB[0], cy - HUB[1])
    legs = wedge_legs(team)
    dhead = b2d(cog.head) - 90.0             # forward = north
    t = cog.turn
    left_open = max(0.0, t) * SW
    right_open = max(0.0, -t) * SW
    swing = {"front_right": +TUCK - right_open, "front_left": -TUCK + left_open, "rear": 0.0}

    # foot screen positions (hip rides hub by dHead; foot arcs by dHead+swing about hip)
    hips, feet = {}, {}
    for leg, g in LEGS.items():
        hip_c = rot_about(g["hip"], HUB, dhead)
        hips[leg] = (hip_c[0] + off[0], hip_c[1] + off[1])
        rel = (g["foot"][0] - g["hip"][0], g["foot"][1] - g["hip"][1])
        a = -math.radians(dhead + swing[leg])
        fx = rel[0] * math.cos(a) - rel[1] * math.sin(a)
        fy = rel[0] * math.sin(a) + rel[1] * math.cos(a)
        feet[leg] = (hips[leg][0] + fx, hips[leg][1] + fy)

    # 1) wheels at each foot, castered to foot velocity (finite-diff)
    wheel = load("wheel.png")
    for leg in ("front_right", "front_left", "rear"):
        foot = feet[leg]; last = cog.lastfoot.get(leg)
        veld = cog.caster[leg]
        if last:
            dx, dy = foot[0] - last[0], foot[1] - last[1]
            if math.hypot(dx, dy) > 0.6:
                veld = brads_of(dx, dy)
        cog.caster[leg] = ease(cog.caster[leg], veld, int(CAST_RATE / 360 * TURN))
        place(cv, wheel, WHEEL_AXLE, foot[0], foot[1], 1.0, b2d(cog.caster[leg]) - 90.0)
        cog.lastfoot[leg] = foot

    # 2) legs pinned at own hip, rotated dHead+swing
    for leg in ("rear", "front_left", "front_right"):
        place(cv, legs[leg], LEGS[leg]["hip"], hips[leg][0], hips[leg][1], 1.0, dhead + swing[leg])

    # 3) hub disc rotates with heading, centered on hub
    place(cv, legs["hub_disc"], HUB, cx, cy, 1.0, dhead)

    # 4) arms (if carrying) UNDER head, then head — both aim
    aimrot = b2d(cog.aim) - 90.0
    if carrying:
        place(cv, load(f"arms_{team}.png"), ARMS_BONE, cx, cy, 1.0, aimrot)
    if not hide_head:
        place(cv, load(f"head_{team}.png"), HUB, cx, cy, 1.0, aimrot)

    if bones:
        d = ImageDraw.Draw(cv)
        for leg in LEGS:
            d.line([hips[leg], feet[leg]], fill=(255, 220, 90, 255), width=6)
            d.ellipse([hips[leg][0]-9, hips[leg][1]-9, hips[leg][0]+9, hips[leg][1]+9], fill=(224,144,42,255))
            d.ellipse([feet[leg][0]-8, feet[leg][1]-8, feet[leg][0]+8, feet[leg][1]+8], fill=(42,167,176,255))

    # crop a body-scaled window around the cog center and downscale
    half = 620
    crop = cv.crop((cx - half, cy - half, cx + half, cy + half))
    return crop.resize((size_px, size_px), Image.LANCZOS)


def contact(team, specs, out, cols, hide_head=False):
    tiles = []
    for lab, cog, carry in specs:
        tiles.append((lab, render(team, cog, 320, carrying=carry, bones=True, hide_head=hide_head)))
    rows = (len(tiles) + cols - 1) // cols
    W = cols * 320 + (cols + 1) * 8; H = rows * (320 + 22) + 8
    sheet = Image.new("RGB", (W, H), (30, 32, 28)); d = ImageDraw.Draw(sheet)
    for i, (lab, im) in enumerate(tiles):
        r, c = i // cols, i % cols
        x = 8 + c * (320 + 8); y = 8 + r * (320 + 22)
        d.text((x, y), lab, fill=(235, 235, 225)); sheet.paste(im.convert("RGB"), (x, y + 22))
    sheet.save(out, quality=88); print("wrote", out, sheet.size)


def drive_script(vx, vy, n):
    return [(vx, vy)] * n


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--team", default="red")
    ap.add_argument("--mode", default="turns")
    ap.add_argument("--out", default="/tmp/rigview/proto.jpg")
    a = ap.parse_args()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)

    if a.mode == "turns":
        # simulate to steady poses
        def sim(script, aim):
            c = Cog(head=0)
            for (vx, vy) in script:
                step_drive(c, vx * 6, vy * 6, aim)
            return c
        straight = sim(drive_script(100, 0, 12), 0)
        # continuous CCW curve (left) -> sustained +turnAmt
        cl = Cog(head=0)
        for i in range(40):
            ang = i * 0.12
            step_drive(cl, int(100*math.cos(ang))*6, int(-100*math.sin(ang))*6, 0)
        cr = Cog(head=0)
        for i in range(40):
            ang = i * 0.12
            step_drive(cr, int(100*math.cos(-ang))*6, int(-100*math.sin(-ang))*6, 0)
        rest = Cog(head=64)  # facing north, idle
        contact(a.team, [
            ("REST idle head=N", rest, False),
            ("straight E", straight, False),
            (f"LEFT curve turn={cl.turn:+.2f}", cl, False),
            (f"RIGHT curve turn={cr.turn:+.2f}", cr, False),
        ], a.out, cols=4)
    elif a.mode == "splay":
        # Drive the RENDER directly across the turnAmt range (this is the math being
        # ported). head hidden so leg splay is visible. heading fixed north.
        def posed(turn, head=64, aim=64):
            c = Cog(head=head); c.turn = turn; c.aim = aim
            return c
        contact(a.team, [
            ("turnAmt -1.0 (hard RIGHT)", posed(-1.0), False),
            ("turnAmt -0.5", posed(-0.5), False),
            ("turnAmt  0.0 (rest/narrow)", posed(0.0), False),
            ("turnAmt +0.5", posed(+0.5), False),
            ("turnAmt +1.0 (hard LEFT)", posed(+1.0), False),
        ], a.out, cols=5, hide_head=True)
    elif a.mode == "carry":
        c = Cog(head=0)
        for i in range(30):
            step_drive(c, 100*6, -40*6, 32)   # driving NE, aim ~45
        contact(a.team, [("carrying, aim NE", c, True), ("not carrying", c, False)], a.out, cols=2)
