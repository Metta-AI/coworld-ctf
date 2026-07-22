#!/usr/bin/env python3
"""Extract articulated-rig segment masters from the SEPARATELY-RENDERED layers.

Why the separate layers (not slices of the assembled cog_base master): in the
assembled art each leg is partially occluded by the central body, so a leg cut
from it is missing the pixels tucked under the body -- rotate/swing it and a GAP
opens under the body. The sprite editor re-rendered each part WHOLE for exactly
this reason. So the segment sources are the editor layer exports:

  /tmp/cog_layers.json : legset (Y body+hub+forks, wheels removed), head (turret)
  /tmp/rig_layers.json : wheel  (one clean top-down tire, forks removed)

Those layers are painted YELLOW/neutral. Team color is applied by DESATURATING the
yellow paint to luminance, then RE-TINTING toward the team hue (multiply-by-hue),
which preserves the painted shading/weathering. Non-paint pixels (black tire, grey
metal joints) are left untouched.

Outputs (PNG, RGBA, straight alpha) into data/rig/:
  chassis_{team}.png - the Y body + hub + empty forks (complete, team-tinted)
  leg_{team}.png     - ONE leg wedge-cut from the legset, hub-centered (reused x3)
  head_{team}.png    - the turret cube+visor (team-tinted; cyan visor preserved)
  wheel.png          - one black caster tire, axle-centered, team-neutral

Plus data/rig/anchors.json with pivots/mounts/axle, all in the OUTPUT canvas space
(we render every part onto the shared 1046x1024 master canvas at the master scale,
hub at the shared pivot, so sim.nim can treat them uniformly).
"""
import base64, io, json, os
import numpy as np
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "data", "rig")
COG_LAYERS = "/tmp/cog_layers.json"
RIG_LAYERS = "/tmp/rig_layers.json"

# Shared canvas + pivot (master space, matches cog_base/cog_head 1046x1024).
CANVAS = (1046, 1024)
PIVOT = (523.0, 412.0)

# Legset layer geometry (measured): hub-hole center in layer px + layer->master scale.
LEGSET_HUB = (346.0, 271.0)
LEGSET_FACTOR = 1046.0 / 680.0        # legset layer is 680 wide; map to master canvas w
# Head layer: cube-center in layer px (visor toward -y). The head layer is ALREADY at
# master scale (434px layer cube -> 435px master cube, factor ~1.0), unlike the legset.
HEAD_CENTER = (216.0, 262.0)          # measured cube centroid in head-layer px
HEAD_FACTOR = 1.0046                  # head-layer -> master scale (near-identity)

# Team accent (sampled from the assembled team masters' body paint).
TEAM_RGB = {"blue": (74, 102, 144), "red": (166, 66, 45)}
# Leg wedge: front-right leg lives between these master-space angles (deg, 0=E CCW),
# wrapping through east. Cut lines are the gap midpoints between legs.
LEG_WEDGE = (330.0, 90.0)             # keep ang>=330 or ang<90


def layer(path, name):
    d = json.load(open(path))
    meta = d[name]
    im = Image.open(io.BytesIO(base64.b64decode(meta["b64"]))).convert("RGBA")
    return im, meta


def retint(arr, rgb):
    """Desaturate the saturated (yellow paint) pixels to luminance, then multiply
    by the team hue. Leaves near-grey / near-black pixels (metal, tire) alone."""
    out = arr.copy()
    a = arr[..., 3]
    r, g, b = arr[..., 0].astype(int), arr[..., 1].astype(int), arr[..., 2].astype(int)
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    sat = mx - mn
    paint = (a >= 40) & (sat > 35) & (mx > 70)      # the yellow body paint
    lum = (0.299 * r + 0.587 * g + 0.114 * b)       # perceptual luminance
    # Normalize luminance so the yellow's typical brightness maps to full team color,
    # keeping relative shading. Yellow paint lum ~ 150-210; scale around ~175.
    k = np.clip(lum / 175.0, 0.0, 1.35)
    for c, tv in enumerate(rgb):
        nc = np.clip(k * tv, 0, 255).astype(np.uint8)
        out[..., c] = np.where(paint, nc, arr[..., c])
    return out


def place_on_canvas(im, layer_hub, factor):
    """Scale a layer to master scale and paste so its hub lands on PIVOT."""
    sw, sh = int(round(im.width * factor)), int(round(im.height * factor))
    scaled = im.resize((sw, sh), Image.LANCZOS)
    hubx, huby = layer_hub[0] * factor, layer_hub[1] * factor
    offx, offy = int(round(PIVOT[0] - hubx)), int(round(PIVOT[1] - huby))
    canvas = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    canvas.paste(scaled, (offx, offy), scaled)
    return canvas


def save(im, path):
    im.save(path)
    print(f"  wrote {path}  {im.size[0]}x{im.size[1]}")


def main():
    os.makedirs(OUT, exist_ok=True)
    anchors = {"canvas": list(CANVAS), "pivot": {"x": PIVOT[0], "y": PIVOT[1]},
               "leg_wedge_deg": list(LEG_WEDGE), "teams": {}, "wheel": {}}

    # --- legset -> chassis + one leg (both on the shared canvas, hub at pivot) ---
    legset_im, legset_meta = layer(COG_LAYERS, "legset")
    legset_canvas = place_on_canvas(legset_im, LEGSET_HUB, LEGSET_FACTOR)
    legset_arr = np.array(legset_canvas)

    # angle map about pivot on the master canvas
    H, W = CANVAS[1], CANVAS[0]
    yy, xx = np.mgrid[0:H, 0:W]
    ang = (np.degrees(np.arctan2(-(yy - PIVOT[1]), xx - PIVOT[0])) + 360) % 360
    r = np.hypot(xx - PIVOT[0], yy - PIVOT[1])

    # chassis = the central hub/body ONLY (r <= HUB_R). The 3 legs are separate moving
    # objects drawn on top; if the static forks stayed in the chassis they'd show
    # through when a leg swings far. Keeping just the hub disc gives a complete body
    # silhouette under the legs with nothing poking out. The moving legs each carry
    # their own root overlap into the hub, so no gap opens.
    HUB_R = 150.0
    chassis_arr = legset_arr.copy()
    chassis_arr[r > HUB_R, 3] = 0
    save(Image.fromarray(chassis_arr, "RGBA"), os.path.join(OUT, "chassis_yellow.png"))

    # one leg wedge (front-right): keep leg material (r>90) in the wedge; the hub
    # disk stays with the chassis, not the leg.
    lo, hi = LEG_WEDGE
    # keep the leg root reaching in under the hub (r>70) so it connects with no gap;
    # the chassis hub disc (r<=150) is drawn under it, so the overlap is hidden.
    wedge = ((ang >= lo) | (ang < hi)) & (r > 70)
    leg_arr = legset_arr.copy()
    leg_arr[~wedge, 3] = 0
    save(Image.fromarray(leg_arr, "RGBA"), os.path.join(OUT, "leg_yellow.png"))

    # --- head/turret from the head layer ---
    head_im, head_meta = layer(COG_LAYERS, "head")
    # place head so its cube center sits at pivot (visor toward -y = north). Head layer
    # is already at master scale, so use HEAD_FACTOR (~1.0), NOT the legset factor.
    head_canvas = place_on_canvas(head_im, HEAD_CENTER, HEAD_FACTOR)
    save(head_canvas, os.path.join(OUT, "head_yellow.png"))

    # --- wheel: clean tire from rig_layers, axle-centered, team-neutral ---
    wheel_im, wheel_meta = layer(RIG_LAYERS, "wheel")
    wa = np.array(wheel_im)
    ys, xs = np.where(wa[..., 3] >= 40)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    wheel_crop = wheel_im.crop((x0, y0, x1 + 1, y1 + 1))
    # axle = tire centroid in cropped frame
    wc = np.array(wheel_crop)
    wys, wxs = np.where(wc[..., 3] >= 40)
    axle = (float(wxs.mean()), float(wys.mean()))
    save(wheel_crop, os.path.join(OUT, "wheel.png"))
    anchors["wheel"] = {"w": wheel_crop.width, "h": wheel_crop.height,
                        "axle_x": round(axle[0], 1), "axle_y": round(axle[1], 1),
                        "roll_axis": "long/+y"}

    # wheel mounts (leg fork tips) in master canvas space: farthest leg pixel per
    # leg lobe. Measured from the placed legset.
    la = np.array(legset_canvas)[..., 3] >= 40
    mounts = []
    for name, (a0, a1) in [("front_right", (10, 85)), ("front_left", (125, 175)),
                           ("rear", (240, 300))]:
        m = la & (ang >= a0) & (ang < a1) & (r > 150)
        if not m.any():
            continue
        rr = np.where(m, r, 0)
        thr = np.percentile(r[m], 96)
        sel = m & (r >= thr)
        fys, fxs = np.where(sel)
        cx, cy = float(fxs.mean()), float(fys.mean())
        mounts.append({"leg": name, "x": round(cx, 1), "y": round(cy, 1),
                       "angle_deg": round((np.degrees(np.arctan2(
                           -(cy - PIVOT[1]), cx - PIVOT[0])) + 360) % 360, 1),
                       "radius": round(float(np.hypot(cx - PIVOT[0], cy - PIVOT[1])), 1)})

    # --- tint both teams ---
    for team, rgb in TEAM_RGB.items():
        for part in ("chassis", "leg", "head"):
            arr = np.array(Image.open(os.path.join(OUT, f"{part}_yellow.png")))
            tinted = retint(arr, rgb)
            save(Image.fromarray(tinted, "RGBA"),
                 os.path.join(OUT, f"{part}_{team}.png"))
        anchors["teams"][team] = {"rgb": list(rgb), "wheel_mounts": mounts}

    with open(os.path.join(OUT, "anchors.json"), "w") as f:
        json.dump(anchors, f, indent=2)
    print(f"  wrote {os.path.join(OUT, 'anchors.json')}")
    print("mounts:", json.dumps(mounts, indent=1))
    print("wheel:", json.dumps(anchors["wheel"]))


if __name__ == "__main__":
    main()
