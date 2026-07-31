#!/usr/bin/env python3
"""Sculpted 3D TERRAIN library for the MW2 Afghan map, rendered top-down.

The first Afghan terrain was unions of primitive discs and was rejected:
"these are procedural circles you placed around... they can be real 3d
assets." Every family here is therefore a genuinely sculpted organic mesh:

  - a single subdivided base mesh (box / uv-sphere / ico-sphere), never a
    union of primitives,
  - pre-shaped in Python (spine bend, end taper, crest humps, superellipse
    talus falloff, radial modulation) so no silhouette is a circle or a box,
  - then Displace modifiers driven by legacy CLOUDS + VORONOI noise textures
    (seed = a per-family offset empty feeding OBJECT texture coords), with a
    Smooth pass between the big and fine displacements,
  - mesas get a soft-clamped flat top AFTER the big displacement so the rim
    stays crumbled while the plateau reads flat.

Render setup matches scripts/art/blender_props.py (kept import-free so the
two files never collide): orthographic top-down camera, sun keyed from the
image upper-left at 45 deg (the engine's bevel-light convention), shadow
catcher ground plane baking contact shadow into alpha, transparent film,
Standard view transform, CYCLES CPU 48 samples, renders at 4x the map-px
footprint to data/props/<family>.png.

LOOK: weathered desert rock. Afghan's floor is pale sand (~230,215,185), so
rock albedo is pinned well below it (rendered top mid-tones ~RGB 120-150) --
the mud-wall lesson: a true-to-life tone vanishes into the floor from above.
A noise-driven two-tone ramp + stretched strata band varies the tint, a
height ramp darkens bases/canyon floors, fine noise drives shader bump.

cave_massif: one 500x260 mass with a WINDING roofless canyon (the "cave")
boolean-cut through it by a lofted trapezoid-prism cutter following
canyon_path(). The cut leaves a thin dark rock floor slab (CANYON_FLOOR_Z),
mouths open on the west and east sides, and the S-bend blocks any straight
sightline. After the cut a per-map-px heightfield is raycast and saved to
/tmp/cave_massif_height.npy as geometric ground truth for --verify.

Run:    /opt/homebrew/bin/blender -b -P scripts/art/blender_terrain.py
        (optionally: ... -- --only mesa_a,cave_massif)
Verify: python3 scripts/art/blender_terrain.py --verify
        (PIL+numpy+scipy: alpha coverage, mean tone, and for cave_massif the
        passage min width / mouth count / no-straight-sightline check, both
        pixel-based and against the raycast heightfield)
"""
import math
import os
import random
import sys

OUTDIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "props"))

# family -> (map-px w, map-px h); renders at 4x, same contract as props.
FOOTPRINTS = {
    "mountain_wall_a": (400, 120),
    "mountain_wall_b": (400, 120),
    "mountain_wall_c": (400, 120),
    "cave_massif": (500, 260),
    "mesa_a": (200, 160),
    "mesa_b": (200, 160),
    "boulder_a": (60, 50),
    "boulder_b": (60, 50),
}

CANYON_FLOOR_Z = 1.8     # top of the rock floor slab left under the canyon
CANYON_BLOCK_Z = 12.0    # rock above this height counts as wall/obstacle
HEIGHT_NPY = "/tmp/cave_massif_height.npy"


def canyon_path(t):
    """Winding canyon centerline, t in [0,1]; west mouth -> east mouth."""
    x = -265.0 + 530.0 * t
    y = (42.0 * math.sin(t * math.pi * 2.0 - 0.85)
         + 13.0 * math.sin(t * math.pi * 4.3 + 1.1))
    return x, y


# --- verification (no bpy: plain python3 + PIL/numpy/scipy) -----------------

def _passage_metrics(obstacle, walk, hull, seeds):
    """Min passage width (px of the given grid), mouth count/sides, and
    whether a straight sightline connects the seeds."""
    import numpy as np
    from scipy import ndimage
    dist = ndimage.distance_transform_edt(walk)
    inside = walk & hull
    (r0, c0), (r1, c1) = seeds
    best = 0
    for wpx in range(2, 90):
        m = inside & (dist >= wpx / 2.0)
        lab, _ = ndimage.label(m)
        if lab[r0, c0] > 0 and lab[r0, c0] == lab[r1, c1]:
            best = wpx
        elif best:
            break
    # mouths: wide-passage pixels touching the outside of the massif hull.
    core = inside & (dist >= 10)
    rim = ndimage.binary_dilation(~hull, iterations=3)
    lab, n = ndimage.label(core & rim)
    mouths = []
    h, w = obstacle.shape
    for i in range(1, n + 1):
        rr, cc = np.nonzero(lab == i)
        if rr.size < 12:
            continue
        r, c = rr.mean(), cc.mean()
        d = {"W": c, "E": w - c, "N": r, "S": h - r}
        mouths.append(min(d, key=d.get))
    # straight sightline between the seeds?
    ts = np.linspace(0.0, 1.0, 1200)
    rr = np.clip((r0 + (r1 - r0) * ts).astype(int), 0, h - 1)
    cc = np.clip((c0 + (c1 - c0) * ts).astype(int), 0, w - 1)
    sightline = not obstacle[rr, cc].any()
    return best, mouths, sightline


def verify():
    import numpy as np
    from PIL import Image
    from scipy import ndimage

    sand = np.array([230.0, 215.0, 185.0])
    for name, (w, h) in FOOTPRINTS.items():
        p = os.path.join(OUTDIR, name + ".png")
        if not os.path.exists(p):
            print(f"{name}: MISSING {p}")
            continue
        im = np.asarray(Image.open(p).convert("RGBA"), dtype=np.float64)
        ih, iw = im.shape[:2]
        opaque = im[..., 3] > 128
        cov = float(opaque.mean())
        tone = im[..., :3][opaque].mean(axis=0)
        rr, cc = np.nonzero(opaque)
        bbox = (cc.min(), rr.min(), cc.max(), rr.max())
        print(f"{name}: {w}x{h} map-px  render {iw}x{ih}  "
              f"coverage {cov * 100:.1f}%  meanRGB "
              f"({tone[0]:.0f},{tone[1]:.0f},{tone[2]:.0f})  "
              f"sand ({sand[0]:.0f},{sand[1]:.0f},{sand[2]:.0f})  "
              f"bbox {bbox}")

    # --- cave passage: pixel-based (the render users see) ------------------
    p = os.path.join(OUTDIR, "cave_massif.png")
    if not os.path.exists(p):
        return
    w, h = FOOTPRINTS["cave_massif"]
    im = Image.open(p).convert("RGBA").resize((w, h), Image.BOX)
    a = np.asarray(im, dtype=np.float64)
    alpha = a[..., 3]
    lum = (0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2])
    rock = alpha > 128
    # canyon floor renders lum ~44-51 (z-darkened slab, mostly in wall
    # shadow), rock tops ~120: 70 splits them with margin on both sides.
    dark = lum < 70.0
    obstacle = rock & ~dark
    hull = ndimage.binary_fill_holes(
        ndimage.binary_closing(obstacle, iterations=45))
    walk = ~obstacle
    seeds = []
    for t in (0.12, 0.88):
        x, y = canyon_path(t)
        seeds.append((int(round(h / 2 - y)), int(round(w / 2 + x))))
    wid, mouths, sight = _passage_metrics(obstacle, walk, hull, seeds)
    print(f"cave_massif PIXEL passage: min width {wid} map-px "
          f"(threshold alpha>128 rock, lum<70 floor), mouths {mouths}, "
          f"straight sightline {'YES - BAD' if sight else 'no (good)'}")

    # --- cave passage: geometric ground truth (raycast heightfield) --------
    if os.path.exists(HEIGHT_NPY):
        H = np.load(HEIGHT_NPY)
        obstacle = H >= CANYON_BLOCK_Z
        walk = ~obstacle
        hull = ndimage.binary_fill_holes(
            ndimage.binary_closing(obstacle, iterations=45))
        wid, mouths, sight = _passage_metrics(obstacle, walk, hull, seeds)
        print(f"cave_massif GEOMETRY passage: min width {wid} map-px "
              f"(rock z>={CANYON_BLOCK_Z} blocks), mouths {mouths}, "
              f"straight sightline {'YES - BAD' if sight else 'no (good)'}")
    else:
        print(f"cave_massif GEOMETRY passage: {HEIGHT_NPY} not found "
              "(rerun the blender build)")


if "--verify" in sys.argv:
    verify()
    sys.exit(0)

import bpy      # noqa: E402  (only under blender -b -P)
import bmesh    # noqa: E402
from mathutils import Vector  # noqa: E402

SC = None


def reset():
    global SC
    bpy.ops.wm.read_factory_settings(use_empty=True)
    SC = bpy.context.scene
    SC.render.engine = "CYCLES"
    SC.cycles.samples = 48
    SC.cycles.use_denoising = True
    SC.cycles.device = "CPU"
    SC.render.film_transparent = True
    SC.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("w")
    SC.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.75, 0.78, 0.9, 1.0)
    bg.inputs[1].default_value = 0.4
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3.2
    sun_data.angle = 0.15
    sun = bpy.data.objects.new("sun", sun_data)
    # -Z rotated by (X:-45, Z:45) -> light travels (+X, -Y, -Z): FROM the
    # image upper-left, the engine's bevel-light convention.
    sun.rotation_euler = (math.radians(-45), 0, math.radians(45))
    SC.collection.objects.link(sun)
    bpy.ops.mesh.primitive_plane_add(size=6000, location=(0, 0, 0))
    bpy.context.active_object.is_shadow_catcher = True


def camera(w, h):
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(w, h)
    cam_data.clip_end = 2000
    cam = bpy.data.objects.new("cam", cam_data)
    cam.location = (0, 0, 500)
    SC.collection.objects.link(cam)
    SC.camera = cam
    SC.render.resolution_x = w * 4
    SC.render.resolution_y = h * 4


def render(name):
    w, h = FOOTPRINTS[name]
    SC.render.filepath = os.path.join(OUTDIR, name + ".png")
    SC.render.image_settings.file_format = "PNG"
    SC.render.image_settings.color_mode = "RGBA"
    bpy.ops.render.render(write_still=True)
    print("rendered", name, w * 4, "x", h * 4)


# --- sculpting helpers ------------------------------------------------------

def _apply_mod(o, mod):
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def ground_box(sx, sy, sz, cuts=(39, 2)):
    """Subdivided box sitting on the ground plane, transforms applied."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0.5))
    o = bpy.context.active_object
    o.scale = (sx, sy, sz)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    for c in cuts:
        bpy.ops.mesh.subdivide(number_cuts=c)
    bpy.ops.object.mode_set(mode="OBJECT")
    return o


def displace(o, kind, size, strength, seed, depth=3, axis="NORMAL"):
    """One applied Displace modifier; seed shifts an OBJECT-coords empty so
    every family/pass samples a different region of the noise field."""
    tex = bpy.data.textures.new("t%d" % seed, kind)
    if hasattr(tex, "noise_scale"):
        tex.noise_scale = size
    if hasattr(tex, "noise_depth"):
        tex.noise_depth = depth
    emp = bpy.data.objects.new("seed%d" % seed, None)
    emp.location = ((seed * 97.13) % 449.0, (seed * 57.71) % 383.0,
                    (seed * 31.9) % 211.0)
    SC.collection.objects.link(emp)
    mod = o.modifiers.new("disp", "DISPLACE")
    mod.texture = tex
    mod.strength = strength
    mod.direction = axis
    mod.texture_coords = "OBJECT"
    mod.texture_coords_object = emp
    _apply_mod(o, mod)


def smooth(o, factor=0.5, iters=3):
    mod = o.modifiers.new("smooth", "SMOOTH")
    mod.factor = factor
    mod.iterations = iters
    _apply_mod(o, mod)


def clamp_bottom(o, z=0.25):
    for v in o.data.vertices:
        if v.co.z < z:
            v.co.z = z


def flatten_top(o, top, keep):
    """Soft-clamp everything above `top` (keep = residual slope kept)."""
    for v in o.data.vertices:
        if v.co.z > top:
            v.co.z = top + (v.co.z - top) * keep


def assign_mat(o, m):
    """Assign into slot 0. A boolean modifier apply ADDS an empty slot 0
    (faces all index it), so a plain append lands in slot 1 and the rock
    renders default-white -- put the material where the faces point."""
    if o.data.materials:
        o.data.materials[0] = m
    else:
        o.data.materials.append(m)


def rock_material(name, seed, base, dark, tint, tint_amt=0.22,
                  zdark=(0.0, 16.0, 0.55), scale_big=0.02, bump=0.4):
    """Weathered desert rock: noise two-tone + stretched strata band on the
    base color, a height ramp that darkens low rock (canyon floors, talus
    bases), fine-noise bump. All coords are Object (== world, transforms
    applied) so the pattern is anchored to the sculpt."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    ln = nt.links.new
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.94
    co = nt.nodes.new("ShaderNodeTexCoord")
    n1 = nt.nodes.new("ShaderNodeTexNoise")           # patchy two-tone
    n1.noise_dimensions = "4D"
    n1.inputs["W"].default_value = seed * 7.31
    n1.inputs["Scale"].default_value = scale_big
    n1.inputs["Detail"].default_value = 5.0
    ln(co.outputs["Object"], n1.inputs["Vector"])
    mp = nt.nodes.new("ShaderNodeMapping")            # strata: xy squashed
    mp.inputs["Scale"].default_value = (0.06, 0.06, 1.0)
    ln(co.outputs["Object"], mp.inputs["Vector"])
    n2 = nt.nodes.new("ShaderNodeTexNoise")
    n2.noise_dimensions = "4D"
    n2.inputs["W"].default_value = seed * 3.77 + 9.1
    n2.inputs["Scale"].default_value = 0.12
    n2.inputs["Detail"].default_value = 2.0
    ln(mp.outputs["Vector"], n2.inputs["Vector"])
    m2 = nt.nodes.new("ShaderNodeMath")
    m2.operation = "MULTIPLY"
    ln(n2.outputs["Fac"], m2.inputs[0])
    m2.inputs[1].default_value = tint_amt
    mad = nt.nodes.new("ShaderNodeMath")
    mad.operation = "MULTIPLY_ADD"
    ln(n1.outputs["Fac"], mad.inputs[0])
    mad.inputs[1].default_value = 1.0 - tint_amt
    ln(m2.outputs["Value"], mad.inputs[2])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = 0.24
    cr.elements[0].color = (*dark, 1.0)
    cr.elements[1].position = 0.52
    cr.elements[1].color = (*base, 1.0)
    e = cr.elements.new(0.80)
    e.color = (*tint, 1.0)
    ln(mad.outputs["Value"], ramp.inputs["Fac"])
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")       # height shading
    ln(co.outputs["Object"], sep.inputs["Vector"])
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = zdark[0]
    mr.inputs["From Max"].default_value = zdark[1]
    mr.inputs["To Min"].default_value = zdark[2]
    mr.inputs["To Max"].default_value = 1.0
    mr.clamp = True
    ln(sep.outputs["Z"], mr.inputs["Value"])
    vm = nt.nodes.new("ShaderNodeVectorMath")
    vm.operation = "MULTIPLY"
    ln(ramp.outputs["Color"], vm.inputs[0])
    ln(mr.outputs["Result"], vm.inputs[1])
    ln(vm.outputs["Vector"], bsdf.inputs["Base Color"])
    n3 = nt.nodes.new("ShaderNodeTexNoise")           # fine grain bump
    n3.noise_dimensions = "4D"
    n3.inputs["W"].default_value = seed * 1.93 + 4.2
    n3.inputs["Scale"].default_value = 0.5
    n3.inputs["Detail"].default_value = 6.0
    ln(co.outputs["Object"], n3.inputs["Vector"])
    bmp = nt.nodes.new("ShaderNodeBump")
    bmp.inputs["Strength"].default_value = bump
    bmp.inputs["Distance"].default_value = 0.6
    ln(n3.outputs["Fac"], bmp.inputs["Height"])
    ln(bmp.outputs["Normal"], bsdf.inputs["Normal"])
    return m


# --- the families -----------------------------------------------------------

def mountain_wall(name, seed, wid, hgt, bendf, humpf):
    """Elongated ridge segment 400x120: tapered/bent box spine, TENT cross
    section (high crest line falling to sloped flanks -- a flat-topped box
    read as a slab with a dark rim cliff), then noise."""
    reset()
    camera(400, 120)
    o = ground_box(356, wid, hgt, cuts=(39, 2))
    hx, hy = 178.0, wid / 2.0
    for v in o.data.vertices:
        t = v.co.x / hx                       # -1 .. 1 along the spine
        env = max(0.0, 1.0 - t * t) ** 0.55   # rounded, tapering ends
        ytap = 0.30 + 0.70 * env
        v.co.y *= ytap
        q = min(1.0, abs(v.co.y) / (hy * ytap))   # 0 spine .. 1 edge
        v.co.z *= ((0.18 + 0.82 * env) * humpf(t)
                   * (1.0 - 0.78 * q ** 1.7))     # tent profile
        v.co.y += bendf(t)                    # spine curvature
    displace(o, "CLOUDS", 55, 24.0, seed, depth=3)
    smooth(o, 0.5, 3)
    displace(o, "VORONOI", 8, 5.0, seed + 7)
    clamp_bottom(o)
    assign_mat(o, rock_material(
        name, seed,
        base=(0.290, 0.240, 0.190), dark=(0.150, 0.120, 0.095),
        tint=(0.340, 0.250, 0.165), zdark=(0.0, 18.0, 0.62)))
    render(name)


def cave_massif():
    """500x260 rock mass with a winding roofless canyon cut through it."""
    name, seed = "cave_massif", 900
    reset()
    camera(500, 260)
    o = ground_box(436, 220, 58, cuts=(49, 2))
    hx, hy = 218.0, 110.0
    for v in o.data.vertices:
        u = abs(v.co.x) / hx
        w = abs(v.co.y) / hy
        r = (u ** 5 + w ** 5) ** 0.2          # superellipse edge metric
        fall = min(1.0, max(0.08, (1.12 - r) / 0.32))
        v.co.z *= fall ** 0.7                 # talus falloff to the rim
    displace(o, "CLOUDS", 65, 30.0, seed, depth=3)
    smooth(o, 0.5, 3)
    displace(o, "VORONOI", 9, 6.0, seed + 7)
    clamp_bottom(o)
    # winding canyon cutter: lofted trapezoid prism (wider at the top so the
    # walls read from above), flat bottom just above the floor slab.
    n = 72
    pts = [canyon_path(i / (n - 1.0)) for i in range(n)]
    bm = bmesh.new()
    rows = []
    for i, (x, y) in enumerate(pts):
        x0, y0 = pts[max(0, i - 1)]
        x1, y1 = pts[min(n - 1, i + 1)]
        tx, ty = x1 - x0, y1 - y0
        length = math.hypot(tx, ty)
        nx, ny = -ty / length, tx / length
        w = 20.0 * (1.0 + 0.18 * math.sin(i * 0.53 + 2.1))
        wt = w * 1.6
        rows.append([bm.verts.new((x - nx * w, y - ny * w, CANYON_FLOOR_Z)),
                     bm.verts.new((x + nx * w, y + ny * w, CANYON_FLOOR_Z)),
                     bm.verts.new((x + nx * wt, y + ny * wt, 96.0)),
                     bm.verts.new((x - nx * wt, y - ny * wt, 96.0))])
    for a, b in zip(rows, rows[1:]):
        for k in range(4):
            bm.faces.new((a[k], a[(k + 1) % 4], b[(k + 1) % 4], b[k]))
    bm.faces.new(rows[0])
    bm.faces.new(rows[-1][::-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new("cutter")
    bm.to_mesh(me)
    bm.free()
    cutter = bpy.data.objects.new("cutter", me)
    SC.collection.objects.link(cutter)
    # wobble the canyon walls in-plane only (z untouched keeps the floor).
    displace(cutter, "CLOUDS", 26, 5.0, seed + 41, axis="X")
    displace(cutter, "CLOUDS", 26, 5.0, seed + 42, axis="Y")
    mod = o.modifiers.new("cut", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.object = cutter
    try:
        mod.solver = "EXACT"
    except TypeError:
        pass
    _apply_mod(o, mod)
    bpy.data.objects.remove(cutter, do_unlink=True)
    # geometric ground truth for --verify: top height per map px.
    import numpy as np
    w, h = FOOTPRINTS[name]
    H = np.full((h, w), -1.0, dtype=np.float32)
    down = Vector((0.0, 0.0, -1.0))
    for rr in range(h):
        y = h / 2.0 - (rr + 0.5)
        for cc in range(w):
            hit, loc, _, _ = o.ray_cast(
                Vector((-w / 2.0 + (cc + 0.5), y, 400.0)), down)
            if hit:
                H[rr, cc] = loc.z
    np.save(HEIGHT_NPY, H)
    assign_mat(o, rock_material(
        name, seed,
        base=(0.285, 0.235, 0.185), dark=(0.145, 0.115, 0.090),
        tint=(0.330, 0.240, 0.160),
        zdark=(6.0, 18.0, 0.07)))   # canyon floor slab goes near-black
    render(name)


def mesa(name, seed, rx, ry, rz, cz, top, mods):
    """200x160 rounded plateau: radially-modulated squashed sphere, big
    noise, then a soft-clamped flat top with crumbling edges."""
    reset()
    camera(200, 160)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=1.0, segments=160,
                                         ring_count=80, location=(0, 0, cz))
    o = bpy.context.active_object
    # poles to +-x FIRST: a pole at the plateau center leaves a triangle-fan
    # that flatten_top turns into a radial "fingerprint" across the top.
    o.rotation_euler[1] = math.pi / 2
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    o.scale = (rx, ry, rz)
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
    for v in o.data.vertices:
        th = math.atan2(v.co.y / ry, v.co.x / rx)
        m = 1.0
        for amp, k, ph in mods:
            m += amp * math.sin(k * th + ph)
        v.co.x *= m
        v.co.y *= m
    displace(o, "CLOUDS", 40, 18.0, seed, depth=3)
    smooth(o, 0.5, 3)
    flatten_top(o, top, 0.10)
    displace(o, "VORONOI", 6, 3.5, seed + 7)
    flatten_top(o, top + 2.5, 0.45)
    clamp_bottom(o)
    assign_mat(o, rock_material(
        name, seed,
        base=(0.305, 0.240, 0.180), dark=(0.150, 0.115, 0.085),
        tint=(0.360, 0.255, 0.160), tint_amt=0.30,
        zdark=(0.0, 16.0, 0.62)))
    render(name)


def boulder(name, seed, rocks):
    """60x50 rubble cluster: individually sculpted displaced ico-spheres."""
    reset()
    camera(60, 50)
    m = rock_material(name, seed,
                      base=(0.275, 0.235, 0.195), dark=(0.140, 0.115, 0.092),
                      tint=(0.320, 0.250, 0.180),
                      zdark=(0.0, 10.0, 0.62), scale_big=0.08, bump=0.5)
    for i, (cx, cy, r, sq, ang) in enumerate(rocks):
        bpy.ops.mesh.primitive_ico_sphere_add(
            subdivisions=4, radius=r, location=(cx, cy, r * sq * 0.62))
        o = bpy.context.active_object
        o.scale = (1.15, 0.9, sq)
        o.rotation_euler[2] = math.radians(ang)
        bpy.ops.object.transform_apply(location=True, rotation=True,
                                       scale=True)
        displace(o, "CLOUDS", r * 1.2, r * 0.75, seed + 11 * i, depth=3)
        displace(o, "VORONOI", r * 0.5, r * 0.16, seed + 11 * i + 5)
        clamp_bottom(o)
        assign_mat(o, m)
    render(name)


def build_all(only=None):
    os.makedirs(OUTDIR, exist_ok=True)
    jobs = {
        "mountain_wall_a": lambda: mountain_wall(
            "mountain_wall_a", 101, 68, 54,
            bendf=lambda t: 10.0 * math.sin(t * math.pi * 1.05 + 0.1),
            humpf=lambda t: 1.0 + 0.18 * math.sin(t * 3.1 * math.pi + 0.4)),
        "mountain_wall_b": lambda: mountain_wall(
            "mountain_wall_b", 202, 60, 60,
            bendf=lambda t: 11.0 * math.sin(t * math.pi * 2.1 - 0.4),
            humpf=lambda t: 1.0 + 0.22 * math.sin(t * 4.4 * math.pi + 1.7)),
        "mountain_wall_c": lambda: mountain_wall(
            "mountain_wall_c", 303, 74, 46,
            bendf=lambda t: 12.0 * math.sin(t * math.pi * 1.6 + 2.2),
            humpf=lambda t: 1.0 + 0.15 * math.sin(t * 2.2 * math.pi + 2.9)),
        "cave_massif": cave_massif,
        "mesa_a": lambda: mesa(
            "mesa_a", 404, 76, 58, 40, 10, 28,
            mods=((0.11, 3, 0.7), (0.07, 7, 2.3))),
        "mesa_b": lambda: mesa(
            "mesa_b", 505, 72, 62, 44, 12, 33,
            mods=((0.12, 4, 1.9), (0.06, 6, 0.4))),
        "boulder_a": lambda: boulder(
            "boulder_a", 606,
            rocks=((-8, 3, 14, 0.75, 15), (10, -6, 10, 0.85, 130),
                   (13, 9, 7, 0.9, 260), (-17, -10, 6, 0.8, 60))),
        "boulder_b": lambda: boulder(
            "boulder_b", 707,
            rocks=((6, 4, 15, 0.7, 200), (-12, -4, 11, 0.9, 40),
                   (-2, -15, 7, 0.85, 300))),
    }
    for fam, fn in jobs.items():
        if only and fam not in only:
            continue
        fn()
    print("terrain library complete:",
          sorted(f for f in jobs if not only or f in only))


if __name__ == "__main__":
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    build_all(only)
