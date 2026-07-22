#!/usr/bin/env python3
"""Reproduce the cog rest pose from the 2D-sprite-rigger export, then articulate.

Replicates the rigger's per-layer transform EXACTLY:
    stage = translate(pivotRef) . rotate(restRot) . scale(scale) . translate(-boneArt)
i.e. the part's boneArt pixel is pinned at pivotRef, and the art is scaled + rotated
about that bone. Sources are the SEPARATE complete layers (no occlusion gap),
retinted per team from yellow.

Pass --pose rest to just reassemble (validate vs screenshot). Later poses drive the
legs/wheels via the differential-steer kinematics.
"""
import argparse, base64, io, json, math, os
import numpy as np
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COG_LAYERS = "/tmp/cog_layers.json"
RIG_LAYERS = "/tmp/rig_layers.json"
TEAM_RGB = {"blue": (74, 102, 144), "red": (166, 66, 45)}

# --- rig geometry (866x848 reference frame) ---
# Head + legset scales/pivots are the authoritative export. Wheel MOUNTS, however, are
# taken from the MEASURED fork tips of the legset art (the export's hand-placed wheel
# pivots were inconsistent -- the rear used a -408 artifact -- so they're not trusted).
# The legset's bone@art(520,569) is the REAR HIP (below the hub); the true body hub
# (ring center) maps to ref BODY_HUB. Legs hinge about BODY_HUB; feet at the fork tips.
REF = (866, 848)
BODY_HUB = (438, 257)              # legset hub-ring center in ref frame (true body pivot)
FOOT_R = 660.0                     # fork-tip radius from hub (measured, ~658-666)
LEG_DIR = {"front_right": 32.0, "front_left": 148.0, "rear": 270.0}  # deg, 0=E CCW, y-up
WHEEL_REST_ROT = {"front_right": -133, "front_left": 131, "rear": 1}


def foot_ref(leg, extra_deg=0.0):
    """Fork-tip (wheel mount) in ref px for a leg at its current absolute direction."""
    d = math.radians(LEG_DIR[leg] + extra_deg)
    return (BODY_HUB[0] + FOOT_R * math.cos(d), BODY_HUB[1] - FOOT_R * math.sin(d))


EXPORT = {
    "legset": dict(pivot=(433, 475), scale=1.191, rot=0, bone=(520, 569)),
    "head":   dict(pivot=(437, 323), scale=0.430, rot=0, bone=(217, 257)),
    "wheel_fr":   dict(pivot=foot_ref("front_right"), scale=0.444, rot=-133, bone=(47, 132)),
    "wheel_fl":   dict(pivot=foot_ref("front_left"),  scale=0.444, rot=131,  bone=(47, 132)),
    "wheel_rear": dict(pivot=foot_ref("rear"),        scale=0.451, rot=1,    bone=(47, 132)),
}
# which source art each part uses, and that art's original frame
SRC = {
    "legset":     ("cog", "legset", 1031),   # resize cog_layers legset -> 1031 wide
    "head":       ("cog", "head", None),      # native 434x514
    "wheel_fr":   ("rig", "wheel", None),     # native 84x250
    "wheel_fl":   ("rig", "wheel", None),
    "wheel_rear": ("rig", "wheel", None),
}
Z = {"wheel_fr": 0, "wheel_fl": 0, "wheel_rear": 0, "legset": 1, "head": 2}


def load_layer(which, name, target_w):
    path = COG_LAYERS if which == "cog" else RIG_LAYERS
    d = json.load(open(path))
    im = Image.open(io.BytesIO(base64.b64decode(d[name]["b64"]))).convert("RGBA")
    if target_w and im.width != target_w:
        f = target_w / im.width
        im = im.resize((int(round(im.width * f)), int(round(im.height * f))), Image.LANCZOS)
    return im


# --- legset cut into hub disc + 3 independent legs (ART = 1031-wide legset frame) ---
LEGSET_ART_W = 1031
_legset_cache = {}


def legset_art_hub():
    im = load_layer("cog", "legset", LEGSET_ART_W)
    a = np.array(im.split()[3]); H, W = a.shape; solid = a >= 40
    ys, xs = np.where(solid); cx0, cy0 = xs.mean(), ys.mean()
    hole = [(xx, yy) for yy in range(int(cy0) - 140, int(cy0) + 140)
            for xx in range(int(cx0) - 140, int(cx0) + 140)
            if 0 <= xx < W and 0 <= yy < H and not solid[yy, xx]
            and (xx - cx0) ** 2 + (yy - cy0) ** 2 < 130 ** 2]
    hole = np.array(hole)
    return im, (hole[:, 0].mean(), hole[:, 1].mean())


LEG_WEDGE_ART = {  # angular wedge (deg about art hub) that isolates each leg
    "front_right": (350, 90), "front_left": (95, 200), "rear": (200, 350)}


def leg_parts():
    """Return {hub_disc, front_right, front_left, rear} as (RGBA img, art-hub xy).
    hub_disc = material within r<=HUB_R (covers the center); each leg = its angular
    wedge with r>HUB_INNER so the leg root still reaches under the disc (no gap)."""
    if _legset_cache:
        return _legset_cache
    im, (hx, hy) = legset_art_hub()
    arr = np.array(im); H, W = arr.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    ang = (np.degrees(np.arctan2(-(yy - hy), xx - hx)) + 360) % 360
    r = np.hypot(xx - hx, yy - hy)
    HUB_R, HUB_INNER = 175.0, 70.0
    disc = arr.copy(); disc[r > HUB_R, 3] = 0
    _legset_cache["hub_disc"] = (Image.fromarray(disc, "RGBA"), (hx, hy))
    for leg, (a0, a1) in LEG_WEDGE_ART.items():
        if a0 < a1:
            sel = (ang >= a0) & (ang < a1)
        else:  # wraps through 0/east
            sel = (ang >= a0) | (ang < a1)
        sel = sel & (r > HUB_INNER)
        la = arr.copy(); la[~sel, 3] = 0
        _legset_cache[leg] = (Image.fromarray(la, "RGBA"), (hx, hy))
    return _legset_cache


def retint(im, rgb):
    arr = np.array(im); a = arr[..., 3]
    r, g, b = arr[..., 0].astype(int), arr[..., 1].astype(int), arr[..., 2].astype(int)
    mx = np.maximum(np.maximum(r, g), b); mn = np.minimum(np.minimum(r, g), b)
    paint = (a >= 40) & ((mx - mn) > 35) & (mx > 70)
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    k = np.clip(lum / 175.0, 0.0, 1.35)
    out = arr.copy()
    for c, tv in enumerate(rgb):
        out[..., c] = np.where(paint, np.clip(k * tv, 0, 255).astype(np.uint8), arr[..., c])
    return Image.fromarray(out, "RGBA")


def place(im, bone, pivot, scale, rot_deg, canvas, extra_rot=0.0, pivot_override=None):
    """Pin im's `bone` px at `pivot` (ref/canvas px), scaled, rotated by rot_deg+extra_rot
    about the bone. Matches the rigger transform. Returns compositing onto canvas."""
    piv = pivot_override if pivot_override else pivot
    total_rot = rot_deg + extra_rot
    # scale first
    sw, sh = max(1, int(round(im.width * scale))), max(1, int(round(im.height * scale)))
    scaled = im.resize((sw, sh), Image.LANCZOS)
    bx, by = bone[0] * scale, bone[1] * scale
    # rotate about the scaled bone: expand, track where bone goes
    # PIL rotate is CCW for positive angle; rigger rot° is CSS rotate = CW positive.
    # So use -total_rot to match screen (CSS) convention.
    rot = scaled.rotate(-total_rot, resample=Image.BICUBIC, expand=True, center=(bx, by))
    # after expand, the center point (bx,by) moved; compute new bone location
    a = math.radians(-(-total_rot))  # PIL rotates by angle; find bone in expanded frame
    # Simpler: rotate a tiny marker canvas to find bone — but PIL keeps `center` fixed only
    # without expand. With expand, offset = how much the bbox grew on top-left.
    # Use matrix: bone stays at same *absolute* position if we don't expand; with expand PIL
    # shifts so nothing clips. Recompute bone via rotating (bx,by) about (bx,by) = itself,
    # then add expand offset (rot.size - scaled.size)/2 ... but center rotation with expand
    # places the ROTATION CENTER at the new image center only if center is image center.
    # To be exact, do NOT use expand; use a big pre-padded canvas.
    raise RuntimeError("use place2")


def place2(im, bone, pivot, scale, rot_deg, canvas):
    """Exact pin: composite `im` scaled by `scale`, rotated `rot_deg` (CSS/CW positive)
    about its `bone`, so bone lands at `pivot` on canvas. No expand math — rotate on a
    padded square big enough to hold any rotation, tracking the bone analytically."""
    sw, sh = max(1, int(round(im.width * scale))), max(1, int(round(im.height * scale)))
    scaled = im.resize((sw, sh), Image.LANCZOS)
    bx, by = bone[0] * scale, bone[1] * scale
    # pad to a square canvas centered so we can rotate about (bx,by) without expand
    diag = int(math.hypot(sw, sh)) + 4
    pad = Image.new("RGBA", (2 * diag, 2 * diag), (0, 0, 0, 0))
    # place scaled so its bone sits at pad center (diag,diag)
    ox, oy = diag - int(round(bx)), diag - int(round(by))
    pad.alpha_composite(scaled, (ox, oy))
    # now rotate about pad center = about bone. CSS positive = CW = PIL negative.
    rot = pad.rotate(-rot_deg, resample=Image.BICUBIC, center=(diag, diag))
    # bone is at pad center (diag,diag); land it at pivot
    canvas.alpha_composite(rot, (int(round(pivot[0] - diag)), int(round(pivot[1] - diag))))


# preview canvas: big + centered on the hub so the fully-splayed rig never clips
# (the 866x848 ref frame is smaller than the splayed rig). PAD offsets ref->canvas.
PVW = (1500, 1500)
PAD = (PVW[0] // 2 - BODY_HUB[0], PVW[1] // 2 - BODY_HUB[1])


def build(team, pose="rest", extra=None):
    canvas = Image.new("RGBA", PVW, (92, 96, 78, 255))
    extra = extra or {}
    for part in sorted(EXPORT, key=lambda k: Z[k]):
        e = EXPORT[part]
        which, name, tw = SRC[part]
        im = load_layer(which, name, tw)
        if which == "cog":  # yellow body parts get tinted; wheel stays black
            im = retint(im, TEAM_RGB[team])
        piv = e["pivot"]; rot = e["rot"]
        ov = extra.get(part, {})
        # articulation: pivot may be replaced (dx,dy) and rotation offset (drot)
        piv = (piv[0] + ov.get("dx", 0) + PAD[0], piv[1] + ov.get("dy", 0) + PAD[1])
        rot = rot + ov.get("drot", 0)
        place2(im, e["bone"], piv, e["scale"], rot, canvas)
    return canvas


LEGSET_SCALE = 1.191     # legset art(1031) -> ref, from the export


def build_anim(team, bodyHeading, wheelToe, w, aim=None, bg=(92, 96, 78, 255)):
    """Composite the ARTICULATED rig: independent legs (each swings about the hub),
    hub disc on top of the leg roots, wheels castered at live fork tips, head aiming.
    All angles in screen degrees (0=E, CCW+, y-up)."""
    canvas = Image.new("RGBA", PVW, bg)
    hub = (BODY_HUB[0] + PAD[0], BODY_HUB[1] + PAD[1])
    parts = leg_parts()
    dHead = bodyHeading - REST_HEADING
    swing = max(-SWING_MAX, min(SWING_MAX, SWING_GAIN * w))
    leg_swing = {"front_right": +swing, "front_left": -swing, "rear": +0.30 * swing}

    def tint_wheel(im):
        return im  # tire stays black (team-neutral)

    # z-order: wheels (bottom) < legs < hub disc < head (top)
    # 1) wheels at each live fork tip, castered to travel
    wheel = load_layer("rig", "wheel", None)
    for leg in ("front_right", "front_left", "rear"):
        legAng = LEG_DIR[leg] + dHead + leg_swing[leg]
        foot = foot_ref(leg, dHead + leg_swing[leg])
        footc = (foot[0] + PAD[0], foot[1] + PAD[1])
        sc = 0.451 if leg == "rear" else 0.444
        # wheel rolls along its +y long axis; caster so +y points along wheelToe.
        # tire art faces "up" at rot 0 => rolling north(90). rot to reach wheelToe:
        wheel_rot = -(wheelToe - 90.0)
        place2(wheel, (47, 132), footc, sc, wheel_rot, canvas)

    # 2) three legs, each rotated about the hub by heading + its swing
    legimg = {}
    for leg in ("rear", "front_left", "front_right"):
        im, (ahx, ahy) = parts[leg]
        im = retint(im, TEAM_RGB[team])
        rot = -(dHead + leg_swing[leg])          # screen CCW -> CSS CW
        place2(im, (ahx, ahy), hub, LEGSET_SCALE, rot, canvas)

    # 3) hub disc (covers leg roots, rotates with heading)
    disc, (ahx, ahy) = parts["hub_disc"]
    disc = retint(disc, TEAM_RGB[team])
    place2(disc, (ahx, ahy), hub, LEGSET_SCALE, -dHead, canvas)

    # 4) head aims (independent). If aim is None, head faces forward with the body.
    e = EXPORT["head"]
    head = load_layer("cog", "head", None)
    head = retint(head, TEAM_RGB[team])
    head_dir = aim if aim is not None else bodyHeading
    # head pivot rides with the body hub; here we keep it centered on the hub.
    head_piv = (hub[0] + (e["pivot"][0] - BODY_HUB[0]),
                hub[1] + (e["pivot"][1] - BODY_HUB[1]))
    place2(head, e["bone"], head_piv, e["scale"], -(head_dir - 90.0), canvas)
    return canvas


# --- differential-steer kinematics (port of stepCogDrive intent) ---
# All angles here in degrees, screen convention (0=E, CCW+, y-up). The controller
# gives us: bodyHeading (chassis facing), wheelToe (travel dir the wheels roll),
# turnRate w (deg/frame, + = turning left/CCW), reversing (bool).
SWING_GAIN = 2.2         # deg of front-leg swing per deg/frame of turn rate
SWING_MAX = 34.0         # cap on front-leg swing
REST_HEADING = 90.0      # forward = north

def crop_around_hub(img, half=430):
    cx, cy = PVW[0] // 2, PVW[1] // 2
    return img.crop((cx - half, cy - half, cx + half, cy + half))


def contact_sheet(team, specs, out, cols=None, label_h=22):
    """specs = [(label, bodyHeading, wheelToe, w, aim), ...]"""
    from PIL import ImageDraw
    tiles = []
    for (lab, bh, wt, w, aim) in specs:
        im = crop_around_hub(build_anim(team, bh, wt, w, aim)).resize((300, 300))
        tiles.append((lab, im))
    cols = cols or len(tiles)
    rows = (len(tiles) + cols - 1) // cols
    W = cols * 300 + (cols + 1) * 8
    H = rows * (300 + label_h) + 8
    sheet = Image.new("RGB", (W, H), (30, 32, 28))
    d = ImageDraw.Draw(sheet)
    for i, (lab, im) in enumerate(tiles):
        r, c = i // cols, i % cols
        x = 8 + c * (300 + 8); y = 8 + r * (300 + label_h)
        d.text((x, y), lab, fill=(235, 235, 225))
        sheet.paste(im, (x, y + label_h))
    sheet.save(out, quality=86)
    print("wrote", out, sheet.size)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--team", default="blue")
    ap.add_argument("--mode", default="turns")       # rest | turns | strip
    ap.add_argument("--out", default="/tmp/rig_anim.jpg")
    a = ap.parse_args()
    if a.mode == "rest":
        img = crop_around_hub(build_anim(a.team, 90, 90, 0, 90))
        img.convert("RGB").save(a.out, quality=86); print("wrote", a.out, img.size)
    elif a.mode == "turns":
        # forward, hard-left (w>0), hard-right (w<0); head aims forward
        contact_sheet(a.team, [
            ("straight  head=N  w=0",      90, 90,   0, 90),
            ("hard LEFT  w=+12",           90, 128, +12, 90),
            ("hard RIGHT w=-12",           90, 52,  -12, 90),
            ("turning L, aim EAST",       110, 128, +10, 0),
        ], a.out, cols=4)
    elif a.mode == "gif":
        # Smooth animated drive: cruise east -> turn to north -> cruise -> turn back
        # to east, head holding aim north-ish the whole time (decoupled). Real controller.
        import drive_sim as DS
        st = DS.init_state(0); aim = 64  # aim ~north-east, held
        # velocity script (vx,vy): east cruise, then north, then east again, then reverse
        script = ([(100, 0)] * 6 + [(0, -100)] * 14 + [(100, 0)] * 8 +
                  [(-100, 0)] * 10 + [(100, 0)] * 6)
        frames = []; prev_h = st["bodyHeading"]
        for (vx, vy) in script:
            st = DS.step(st, vx, vy, DS._brad2deg(aim))
            w = DS.short_diff(st["bodyHeading"], prev_h); prev_h = st["bodyHeading"]
            im = crop_around_hub(build_anim(a.team, st["bodyHeading"], st["wheelToe"],
                                            w, DS._brad2deg(aim))).resize((360, 360))
            frames.append(im.convert("P", palette=Image.ADAPTIVE))
        gif = a.out if a.out.endswith(".gif") else "/tmp/rig_drive.gif"
        frames[0].save(gif, save_all=True, append_images=frames[1:], duration=90,
                       loop=0, disposal=2)
        print("wrote", gif, len(frames), "frames")
    elif a.mode == "strip":
        # A scripted drive that mirrors stepCogDrive: start heading east(0), then
        # travel turns to north -> body eases around, front legs swing by turn rate,
        # wheels caster to travel. head holds aim east the whole time (decoupled).
        import drive_sim as DS
        st = DS.init_state(0)                # facing east
        aim = 0                              # head aims east throughout
        # velocity script: drive north (vx=0, vy=-fast) so travel=90; body must turn E->N
        script = [(0, -100)] * 10
        specs = []
        prev_h = st["bodyHeading"]
        for i, (vx, vy) in enumerate(script):
            st = DS.step(st, vx, vy, aim)
            w = DS.short_diff(st["bodyHeading"], prev_h)   # deg/frame turn rate
            prev_h = st["bodyHeading"]
            if i % 2 == 0:
                specs.append((f"f{i} h={st['bodyHeading']:.0f} toe={st['wheelToe']:.0f} w={w:+.0f}",
                              st["bodyHeading"], st["wheelToe"], w, aim))
        contact_sheet(a.team, specs, a.out, cols=5)
