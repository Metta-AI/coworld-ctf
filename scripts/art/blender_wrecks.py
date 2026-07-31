#!/usr/bin/env python3
"""Crashed-vehicle WRECK sprites for the MW2 Afghan map, rendered top-down.

Afghan's crashed C-130 was collaged from the CLEAN airliner tube sprites and
read as scattered white blocks (the nose as a water tank, the fallen fin as a
paper airplane); the burnt tank wore a teal shipping-container sprite. Every
sprite here is a purpose-modeled original: primitives shaped per-vertex
(taper, droop, planform sweep), torn open with jagged rim teeth, then Displace
modifiers (CLOUDS + VORONOI, seeded via offset Empties -- same recipe as
scripts/art/blender_terrain.py) for crumpled/buckled skin.

Render rig matches blender_props.py / blender_terrain.py (kept import-free so
the files never collide): orthographic top-down camera, sun keyed from the
image UPPER-LEFT at 45 deg (the engine's bevel-light convention), shadow
catcher ground plane baking the contact shadow into alpha, transparent film,
Standard view transform, CYCLES CPU 48 samples, renders at 4x the map-px
footprint to data/props/<name>.png.

Conventions baked into the renders:
  - C-130 kit: fuselage axis VERTICAL in the image, nose at the TOP, whole
    assembly leaned 9 deg clockwise (map heading 009) via lean() -- the
    engine does NOT rotate these sprites. The sun is NOT leaned: light must
    keep coming from the image upper-left.
  - The fallen fin carries its own toppled rotation instead (rotz -31 fits
    the 81x123 frame; reads as wreckage ~140 deg off the hull heading).
  - burnt_tank is hull-axis-vertical with no lean.
  - Afghan's floor is pale sand (~230,215,185): hulls are dulled scorched
    aluminium (mid-grey + metallic speculars + near-black burn streaking),
    never factory white; sand drifts render a shade darker than the floor.

Gotchas inherited / learned:
  - geometry below z=0 still RENDERS through the shadow catcher -> clamp.
  - vertex edits & material Y-gradients need transform_apply first (world
    coords); displacement seeds via offset Empties (OBJECT texture coords).
  - flank markings (cheatline, windows) are radial slabs POKED THROUGH the
    skin, not surface-tangent strips -- displacement makes tangent strips
    sink or float, while a penetrating slab always shows its outer face.
  - no booleans anywhere (a boolean apply eats material slots).

Run:     /opt/homebrew/bin/blender -b -P scripts/art/blender_wrecks.py
         (optionally: ... -- --only c130_mid,burnt_tank)
Verify:  python3 scripts/art/blender_wrecks.py --verify
         (coverage, bbox, mean tone, and the visual-centroid offset from the
         image center in map px -- the placer positions by center)
Preview: python3 scripts/art/blender_wrecks.py --preview
         (writes /tmp/wreck_<name>_v.png: 4x render + 1x map-scale nearest
         blowup, both composited on Afghan sand)
"""
import math
import os
import random
import sys

OUTDIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "props"))

# name -> (map-px w, map-px h); renders at 4x, same contract as props.
WRECKS = {
    "c130_nose": (69, 99),
    "c130_mid": (111, 108),
    "c130_tail": (21, 87),
    "c130_fin": (81, 123),
    "c130_engine": (28, 28),
    "burnt_tank": (42, 57),
}

SAND_RGB = (230, 215, 185)


# --- verification / preview (no bpy: plain python3 + PIL/numpy) --------------

def verify():
    import numpy as np
    from PIL import Image
    for name, (w, h) in WRECKS.items():
        p = os.path.join(OUTDIR, name + ".png")
        if not os.path.exists(p):
            print(f"{name}: MISSING {p}")
            continue
        a = np.asarray(Image.open(p).convert("RGBA"), dtype=np.float64)
        ih, iw = a.shape[:2]
        opaque = a[..., 3] > 128
        solid = a[..., 3] > 200          # excludes the soft baked shadow
        if not solid.any():
            print(f"{name}: EMPTY render")
            continue
        cov = float(opaque.mean())
        tone = a[..., :3][opaque].mean(axis=0)
        rr, cc = np.nonzero(opaque)
        bbox = (cc.min() / 4, rr.min() / 4, cc.max() / 4, rr.max() / 4)
        margin = min(cc.min(), rr.min(), iw - 1 - cc.max(),
                     ih - 1 - rr.max()) / 4.0
        rs, cs = np.nonzero(solid)
        dx = (cs.mean() - (iw - 1) / 2) / 4
        dy = (rs.mean() - (ih - 1) / 2) / 4
        print(f"{name}: {w}x{h} map-px  render {iw}x{ih}  "
              f"coverage {cov * 100:.1f}%  meanRGB "
              f"({tone[0]:.0f},{tone[1]:.0f},{tone[2]:.0f}) vs sand "
              f"{SAND_RGB}  bbox ({bbox[0]:.0f},{bbox[1]:.0f},"
              f"{bbox[2]:.0f},{bbox[3]:.0f})  edge margin {margin:.1f}px  "
              f"centroid offset (dx {dx:+.1f}, dy {dy:+.1f}) map-px "
              f"(+x right, +y down)")


def preview():
    """Side-by-side judge sheet on Afghan sand: 4x render detail (left) and
    the 1x map-px blit blown up 4x nearest (right, what players see)."""
    from PIL import Image
    for name, (w, h) in WRECKS.items():
        p = os.path.join(OUTDIR, name + ".png")
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA")

        def on_sand(img):
            bg = Image.new("RGBA", img.size, (*SAND_RGB, 255))
            bg.alpha_composite(img)
            return bg.convert("RGB")

        big = on_sand(im)
        s = 460.0 / max(big.size)
        big = big.resize((max(1, int(big.width * s)),
                          max(1, int(big.height * s))), Image.LANCZOS)
        small = on_sand(im.resize((w, h), Image.BOX)).resize(
            (w * 4, h * 4), Image.NEAREST)
        hh = max(big.height, small.height)
        sheet = Image.new("RGB", (big.width + small.width + 24, hh),
                          SAND_RGB)
        sheet.paste(big, (0, (hh - big.height) // 2))
        sheet.paste(small, (big.width + 24, (hh - small.height) // 2))
        out = "/tmp/wreck_%s_v.png" % name
        sheet.save(out)
        print("wrote", out, sheet.size)


if "--verify" in sys.argv:
    verify()
    sys.exit(0)
if "--preview" in sys.argv:
    preview()
    sys.exit(0)

import bpy  # noqa: E402  (only under blender -b -P)
from mathutils import Matrix, Vector  # noqa: E402

SC = None
CREATED = []      # wreck objects of the current scene: lean() rotates these


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
    bpy.ops.mesh.primitive_plane_add(size=4000, location=(0, 0, 0))
    bpy.context.active_object.is_shadow_catcher = True
    CREATED.clear()


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
    w, h = WRECKS[name]
    SC.render.filepath = os.path.join(OUTDIR, name + ".png")
    SC.render.image_settings.file_format = "PNG"
    SC.render.image_settings.color_mode = "RGBA"
    bpy.ops.render.render(write_still=True)
    print("rendered", name, w * 4, "x", h * 4)


# --- object helpers ----------------------------------------------------------

def _apply_mod(o, mod):
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def _apply_xform(o):
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def _finish(o, m, bevel=0.0):
    if m is not None:
        o.data.materials.append(m)
    if bevel > 0:
        mod = o.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
    CREATED.append(o)
    return o


def box(cx, cy, cz, sx, sy, sz, m, bevel=0.0, rotz=0.0, rotx=0.0, roty=0.0,
        apply_all=False):
    bpy.ops.mesh.primitive_cube_add(size=1, location=(cx, cy, cz))
    o = bpy.context.active_object
    o.scale = (sx, sy, sz)
    # bevel width is object-space: bake the scale (blender_props gotcha).
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.rotation_euler = (math.radians(rotx), math.radians(roty),
                        math.radians(rotz))
    if apply_all:
        _apply_xform(o)
    return _finish(o, m, bevel)


def cyl(cx, cy, cz, r, depth, m, axis="Z", verts=48, fill="NGON",
        rot=None, apply_all=False):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth,
                                        end_fill_type=fill,
                                        location=(cx, cy, cz))
    o = bpy.context.active_object
    if axis == "X":
        o.rotation_euler[1] = math.radians(90)
    elif axis == "Y":
        o.rotation_euler[0] = math.radians(90)
    if rot is not None:
        o.rotation_euler = [math.radians(a) for a in rot]
    if apply_all:
        _apply_xform(o)
    return _finish(o, m)


def torus(cx, cy, cz, major, minor, m, axis="Z"):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor,
                                     location=(cx, cy, cz))
    o = bpy.context.active_object
    if axis == "X":
        o.rotation_euler[1] = math.radians(90)
    elif axis == "Y":
        o.rotation_euler[0] = math.radians(90)
    return _finish(o, m)


def sphere(cx, cy, cz, r, m, scale=(1, 1, 1), apply_all=False):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=r, location=(cx, cy, cz),
                                         segments=48, ring_count=24)
    o = bpy.context.active_object
    o.scale = scale
    if apply_all:
        _apply_xform(o)
    return _finish(o, m)


def subdiv(o, cuts):
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.subdivide(number_cuts=cuts)
    bpy.ops.object.mode_set(mode="OBJECT")


def displace(o, kind, size, strength, seed, depth=3, axis="NORMAL"):
    """One applied Displace modifier; seed shifts an OBJECT-coords empty so
    every pass samples a different region of the noise field."""
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


def smooth(o, factor=0.5, iters=2):
    mod = o.modifiers.new("smooth", "SMOOTH")
    mod.factor = factor
    mod.iterations = iters
    _apply_mod(o, mod)


def clamp_bottom(o, z=0.15):
    # below-ground geometry still renders through the shadow catcher.
    for v in o.data.vertices:
        if v.co.z < z:
            v.co.z = z


def tube(cy0, cy1, r, cz, m, cuts=12, verts=48):
    """Open-ended fuselage tube along +Y, transforms applied so vertex edits
    and material gradients work in plain world coordinates."""
    o = cyl(0, (cy0 + cy1) / 2.0, cz, r, cy1 - cy0, None, axis="Y",
            fill="NOTHING", verts=verts, apply_all=True)
    subdiv(o, cuts)
    if m is not None:
        o.data.materials.append(m)
    return o


def jag_rim(o, y_end, side, amp, cz, cx=0.0, k=6, seed=0, band=2.5):
    """Tear a tube end-ring into jagged teeth. side=+1 tears a +Y end back
    toward -Y; side=-1 the opposite."""
    rnd = random.Random(seed)
    ph = rnd.uniform(0, 6.28)
    for v in o.data.vertices:
        if abs(v.co.y - y_end) < band:
            th = math.atan2(v.co.z - cz, v.co.x - cx)
            t = min(1.0, 0.5 + 0.5 * math.sin(th * k + ph)
                    + rnd.uniform(0.0, 0.35))
            v.co.y -= side * amp * t
            v.co.x += rnd.uniform(-0.7, 0.7)
            v.co.z += rnd.uniform(-0.9, 0.4)


def jag_x(o, x_end, side, amp, k=1.1, seed=0, band=2.5):
    """Same, for a slab's +-X end (snapped wing stubs)."""
    rnd = random.Random(seed)
    ph = rnd.uniform(0, 6.28)
    for v in o.data.vertices:
        if abs(v.co.x - x_end) < band:
            t = min(1.0, 0.5 + 0.5 * math.sin(v.co.y * k + ph)
                    + rnd.uniform(0.0, 0.4))
            v.co.x -= side * amp * t
            v.co.z += rnd.uniform(-0.5, 0.3)


def drift(cx, cy, rx, ry, h, m, seed):
    """Low wind-banked sand drift squashed against a hull line."""
    o = sphere(cx, cy, 0.0, 1.0, None, scale=(rx, ry, h), apply_all=True)
    displace(o, "CLOUDS", max(rx, ry) * 0.9, h * 0.7, seed)
    clamp_bottom(o, 0.12)
    o.data.materials.append(m)
    return o


def lean(deg=-9.0, dx=0.0, dy=0.0):
    """Bake the assembly heading (map heading 009 -> rotz -9, clockwise in
    image space) into every wreck object. Camera and sun stay fixed: light
    must keep coming from the image upper-left."""
    mtx = (Matrix.Translation((dx, dy, 0.0))
           @ Matrix.Rotation(math.radians(deg), 4, "Z"))
    for o in CREATED:
        o.matrix_world = mtx @ o.matrix_world


# --- materials ---------------------------------------------------------------

def mat(name, color, rough=0.6, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


def noise_mat(name, seed, stops, metal=0.4, rough=0.55,
              streak=(0.10, 0.02, 0.10), burn=None, burn_axis="Y",
              burn_amt=0.5, bump=0.35):
    """Weathered wreck surface: streaked noise -> tone ramp (stops = list of
    (pos, linear-rgb)), optional linear burn gradient darkening toward a tear
    (burn = (from, to) along burn_axis in object coords), fine-noise bump.
    Object coords are the pre-lean model axes (transforms applied at build),
    so streaks stay hull-aligned after lean()."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    ln = nt.links.new
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    co = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = streak
    ln(co.outputs["Object"], mp.inputs["Vector"])
    nz = nt.nodes.new("ShaderNodeTexNoise")
    nz.noise_dimensions = "4D"
    nz.inputs["W"].default_value = seed * 5.13
    nz.inputs["Scale"].default_value = 1.0
    nz.inputs["Detail"].default_value = 4.0
    ln(mp.outputs["Vector"], nz.inputs["Vector"])
    fac = nz.outputs["Fac"]
    if burn is not None:
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        ln(co.outputs["Object"], sep.inputs["Vector"])
        mr = nt.nodes.new("ShaderNodeMapRange")
        mr.inputs["From Min"].default_value = burn[0]
        mr.inputs["From Max"].default_value = burn[1]
        mr.inputs["To Min"].default_value = 0.0
        mr.inputs["To Max"].default_value = burn_amt
        mr.clamp = True
        ln(sep.outputs[burn_axis], mr.inputs["Value"])
        sub = nt.nodes.new("ShaderNodeMath")
        sub.operation = "SUBTRACT"
        ln(fac, sub.inputs[0])
        ln(mr.outputs["Result"], sub.inputs[1])
        fac = sub.outputs["Value"]
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = stops[0][0]
    cr.elements[0].color = (*stops[0][1], 1.0)
    cr.elements[1].position = stops[1][0]
    cr.elements[1].color = (*stops[1][1], 1.0)
    for pos, col in stops[2:]:
        e = cr.elements.new(pos)
        e.color = (*col, 1.0)
    ln(fac, ramp.inputs["Fac"])
    ln(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    n2 = nt.nodes.new("ShaderNodeTexNoise")
    n2.noise_dimensions = "4D"
    n2.inputs["W"].default_value = seed * 2.71 + 3.3
    n2.inputs["Scale"].default_value = 0.45
    n2.inputs["Detail"].default_value = 5.0
    ln(co.outputs["Object"], n2.inputs["Vector"])
    bmp = nt.nodes.new("ShaderNodeBump")
    bmp.inputs["Strength"].default_value = bump
    bmp.inputs["Distance"].default_value = 0.4
    ln(n2.outputs["Fac"], bmp.inputs["Height"])
    ln(bmp.outputs["Normal"], bsdf.inputs["Normal"])
    return m


# scorched aluminium ramp: near-black burn lows -> dull warm alu (never
# factory white, never blue -- the v1 ramp read as shiny silver curtain).
ALU_STOPS = ((0.16, (0.026, 0.024, 0.022)),
             (0.42, (0.135, 0.128, 0.116)),
             (0.62, (0.200, 0.190, 0.172)),
             (0.85, (0.295, 0.282, 0.255)))
# drifts sit within a shade of the pale floor (230,215,185): darker sand
# read as pale-brown eggs lying beside the wrecks.
SAND_STOPS = ((0.20, (0.58, 0.48, 0.33)),
              (0.60, (0.70, 0.60, 0.42)),
              (0.85, (0.80, 0.70, 0.52)))


def sand_mat(seed):
    return noise_mat("sand%d" % seed, seed, SAND_STOPS, metal=0.0, rough=1.0,
                     streak=(0.2, 0.2, 0.2), bump=0.5)


def kit_mats(seed, burn=None, burn_amt=0.55):
    """The shared C-130 palette for one scene. Muted on purpose: the v1
    zinc-chromate ribs read as glow sticks and the cheatline as blue pills."""
    alu = noise_mat("alu%d" % seed, seed, ALU_STOPS, metal=0.38, rough=0.58,
                    streak=(0.05, 0.035, 0.05), burn=burn,
                    burn_amt=burn_amt)
    scorch = mat("scorch%d" % seed, (0.018, 0.015, 0.013), rough=0.85,
                 metal=0.05)
    # muted olive-drab interior frames (zinc chromate, weathered).
    rib = mat("rib%d" % seed, (0.115, 0.115, 0.048), rough=0.7, metal=0.05)
    glass = mat("glass%d" % seed, (0.010, 0.014, 0.020), rough=0.3, metal=0.4)
    cheat = mat("cheat%d" % seed, (0.028, 0.042, 0.082), rough=0.6)
    panel = mat("panel%d" % seed, (0.10, 0.10, 0.095), rough=0.6, metal=0.5)
    return alu, scorch, rib, glass, cheat, panel


# --- the sprites -------------------------------------------------------------

def c130_nose():
    """69x99: crumpled nose/cockpit, radome tip part-buried in a sand drift,
    cockpit window band, torn open at its aft break."""
    name = "c130_nose"
    reset()
    camera(*WRECKS[name])
    alu, scorch, rib, glass, cheat, panel = kit_mats(11, burn=(-18, -47))
    sand = sand_mat(19)

    o = tube(-46, 32, 20, 13, None, cuts=12)
    for v in o.data.vertices:            # gentle taper + droop into the nose
        if v.co.y > 2:
            t = min(1.0, (v.co.y - 2) / 30.0)
            s = 1.0 - 0.42 * t ** 1.6
            v.co.x *= s
            v.co.z = 13 + (v.co.z - 13) * s - 4.5 * t ** 1.6
    jag_rim(o, -46, -1, 7, cz=13, k=6, seed=1)
    displace(o, "CLOUDS", 13, 3.0, 21)
    smooth(o, 0.4, 2)
    displace(o, "VORONOI", 4, 0.9, 22)
    clamp_bottom(o)
    o.data.materials.append(alu)

    # blunt crumpled radome, big enough to keep the C-130 snout stubby.
    radome = sphere(0, 30.5, 8, 11, None, scale=(1.05, 1.15, 0.72),
                    apply_all=True)
    displace(radome, "CLOUDS", 7, 2.0, 23)
    clamp_bottom(radome)
    radome.data.materials.append(mat("radome", (0.055, 0.055, 0.060),
                                     rough=0.7, metal=0.1))

    cyl(0, -38, 13, 17.5, 14, scorch, axis="Y")          # torn-open interior
    torus(0, -43.5, 13, 18.3, 0.9, rib, axis="Y")        # tear frame ring
    box(8, -46.5, 27, 1.4, 5, 1.5, rib, rotz=-8)         # rib stubs past rim
    box(-12, -46.5, 22, 1.4, 5, 1.5, rib, rotz=6)

    # cockpit window band across the crown, kept low-profile.
    box(0, 16, 28.2, 11.5, 7.5, 2.2, glass, rotx=8)
    box(7.8, 14.5, 26.2, 6.5, 6, 1.8, glass, roty=30, rotz=-10)
    box(-7.8, 14.5, 26.2, 6.5, 6, 1.8, glass, roty=-30, rotz=10)

    # circumferential skin-panel seams: they break the long crown highlight
    # that made the tube read as draped fabric.
    torus(0, -30, 13, 20.3, 0.35, panel, axis="Y")
    torus(0, -10, 13, 20.3, 0.35, panel, axis="Y")
    torus(0, 10, 12.6, 19.2, 0.35, panel, axis="Y")

    # cheatline remnant + a few flank windows: radial slabs through the skin.
    for sx in (-1, 1):
        box(sx * 17.2, -24, 24.0, 2.4, 32, 1.4, cheat)
        box(sx * 15.5, 3, 23.5, 2.4, 10, 1.4, cheat)
        for yy in (-34, -27, -20):
            box(sx * 15.8, yy, 26.8, 2.0, 2.4, 2.0, glass)

    box(2, -40, 31.5, 14, 9, 1.4, scorch, rotz=10)       # burn at the tear

    drift(-18, -24, 6, 15, 2.2, sand, 31)                # banked flank drift
    drift(2, 35, 12, 8.5, 2.6, sand, 32)                 # radome burial
    drift(17, 2, 4.5, 10, 1.6, sand, 33)
    box(14, -43, 0.8, 5, 3, 1.4, panel, rotz=33)         # ground shards
    box(-16, -47, 0.6, 4, 2.5, 1.0, scorch, rotz=-20)

    lean()
    render(name)


def c130_mid():
    """111x108: HERO piece -- mid fuselage torn open at its aft break (frame
    ribs in the tear + a crown gash), both wing stubs snapped short (right
    much shorter), buckled skin, cheatline remnant + window rows."""
    name = "c130_mid"
    reset()
    camera(*WRECKS[name])
    alu, scorch, rib, glass, cheat, panel = kit_mats(41, burn=(-8, -44),
                                                     burn_amt=0.6)
    wing_m = noise_mat("wing41", 43, ALU_STOPS, metal=0.38, rough=0.58,
                       streak=(0.02, 0.05, 0.05), burn=(-26, -52),
                       burn_axis="X", burn_amt=0.5)
    sand = sand_mat(49)

    o = tube(-42, 44, 21, 13, None, cuts=12)
    jag_rim(o, -42, -1, 8, cz=13, k=6, seed=3)
    jag_rim(o, 44, 1, 3.5, cz=13, k=9, seed=4)
    displace(o, "CLOUDS", 15, 2.8, 51)
    smooth(o, 0.4, 2)
    displace(o, "VORONOI", 4.5, 1.0, 52)
    clamp_bottom(o)
    o.data.materials.append(alu)

    cyl(0, -36, 13, 18, 13, scorch, axis="Y")            # aft torn interior
    torus(0, -39.5, 13, 18.6, 0.85, rib, axis="Y")       # frame ribs in tear
    torus(0, -34.5, 13, 18.9, 0.8, rib, axis="Y")
    box(14.5, -44.5, 26, 1.8, 6, 1.8, rib, rotz=-10)     # bent rib stubs
    box(-4, -45.0, 33, 1.8, 6, 1.6, rib, rotz=4)
    box(-17, -44, 22, 1.6, 5, 1.6, rib, rotz=14)
    cyl(0, 40.5, 13, 18.5, 8, scorch, axis="Y")          # fwd break, dark end
    for yy in (-28, -6, 18, 38):                         # skin-panel seams
        torus(0, yy, 13, 21.3, 0.35, panel, axis="Y")

    # snapped high-wing stubs across the crown: BOTH short (v1 nearly-full
    # span read as an intact plank lying across the tube), left the longer,
    # hard chord taper + big tear teeth so they read broken off.
    w = box(-8, 6, 33.2, 84, 26, 4.4, None, apply_all=True)
    subdiv(w, 14)
    for v in w.data.vertices:            # chord taper toward the tips
        dx = abs(v.co.x + 8)
        if dx > 12:
            t = min(1.0, (dx - 12) / 30.0)
            v.co.y = 6 + (v.co.y - 6) * (1.0 - 0.45 * t)
    jag_x(w, -50, -1, 7, k=0.9, seed=5)
    jag_x(w, 34, 1, 5.5, k=0.9, seed=6)
    displace(w, "CLOUDS", 9, 2.4, 53)
    w.data.materials.append(wing_m)
    box(35.5, 6, 33.2, 4.5, 16, 5.0, scorch, rotz=-7)    # torn right tip
    box(-42, 8, 33.6, 2.2, 6, 1.4, rib, rotz=78)         # spar past left tear
    # torn engine-mount stump under the long wing's leading edge.
    stub = tube(11, 21, 5.5, 28.5, None, cuts=3, verts=32)
    for v in stub.data.vertices:
        v.co.x -= 30
    jag_rim(stub, 21, 1, 2.5, cz=28.5, cx=-30, k=5, seed=7)
    stub.data.materials.append(alu)
    cyl(-30, 15.5, 28.5, 4.6, 7, scorch, axis="Y")
    # faded roundel on the long wing stub: the aircraft giveaway from above.
    cyl(-32, 8, 36.4, 4.0, 0.9, mat("roundel", (0.030, 0.042, 0.078),
                                    rough=0.65))
    cyl(-32, 8, 36.9, 1.6, 0.7, mat("roundel2", (0.18, 0.165, 0.145),
                                    rough=0.65))

    # crown gash aft of the wing: scorch opening with rib lines across it.
    box(2, -24, 34.8, 13, 16, 2.0, scorch, rotz=12)
    box(-3, -14, 35.0, 10, 10, 1.8, scorch, rotz=-18)
    box(1, -27, 36.2, 9, 1.2, 0.6, rib, rotz=8)
    box(0, -21, 36.3, 9, 1.2, 0.6, rib, rotz=4)
    box(-1, -16, 36.2, 8, 1.1, 0.6, rib, rotz=-6)

    # cheatline remnant + window rows: radial slabs through the skin.
    for sx in (-1, 1):
        box(sx * 17.6, -26, 24.2, 2.4, 24, 1.4, cheat)
        box(sx * 17.6, 14, 24.2, 2.4, 30, 1.4, cheat)
        for yy in range(-32, 37, 9):
            box(sx * 16.4, yy, 27.3, 2.2, 2.4, 2.0, glass)

    drift(19, -6, 5, 16, 2.0, sand, 54)                  # flank drift
    drift(-27, 22, 9, 6, 1.8, sand, 55)                  # against wing LE
    drift(-12, -40, 5, 4, 1.3, sand, 56)
    box(24, -38, 0.7, 6, 3.5, 1.2, panel, rotz=25)       # ground shards
    box(-25, -44, 0.6, 4, 3, 1.0, scorch, rotz=-15)
    box(30, -45, 0.5, 3.5, 2.2, 0.9, panel, rotz=70)

    lean()
    render(name)


def c130_tail():
    """21x87: the slim tail cone lying separate, torn at its wide (upper)
    end where it broke off the fuselage."""
    name = "c130_tail"
    reset()
    camera(*WRECKS[name])
    alu, scorch, rib, glass, cheat, panel = kit_mats(61, burn=(10, 34),
                                                     burn_amt=0.5)
    sand = sand_mat(69)

    o = tube(-33, 33, 6.0, 5.0, None, cuts=10, verts=32)
    for v in o.data.vertices:            # taper wide+torn (top) -> tip
        s = (2.2 + 3.8 * (v.co.y + 33) / 66.0) / 6.0
        v.co.x *= s
        v.co.z = (v.co.z - 5.0) * s + 6.0 * s * 0.85
    jag_rim(o, 33, 1, 4, cz=5.1, k=5, seed=8)
    displace(o, "CLOUDS", 8, 1.1, 71)
    displace(o, "VORONOI", 3, 0.5, 72)
    clamp_bottom(o, 0.12)
    o.data.materials.append(alu)

    cyl(0, 28.5, 5.1, 5.0, 8, scorch, axis="Y")          # torn interior
    torus(0, 31.8, 5.1, 5.4, 0.6, rib, axis="Y")
    sphere(0, -33.5, 2.1, 2.3, alu, scale=(1, 1.1, 0.85), apply_all=True)

    drift(3.6, -12, 1.8, 7, 0.7, sand, 73)
    box(4.5, 22, 0.5, 3, 2, 0.8, panel, rotz=40)

    lean(dx=-1.5)      # recenter: the lean pushes the wide end right
    render(name)


def c130_fin():
    """81x123: the vertical fin fallen FLAT on its side, toppled well off
    the hull heading (rotz -31 in-frame), torn at the root."""
    name = "c130_fin"
    reset()
    camera(*WRECKS[name])
    alu, scorch, rib, glass, cheat, panel = kit_mats(81)
    fin_m = noise_mat("fin81", 83, ALU_STOPS, metal=0.38, rough=0.58,
                      streak=(0.05, 0.025, 0.05), burn=(30, 58),
                      burn_amt=0.42)
    sand = sand_mat(89)

    def planform(o):
        """root (y=+54, torn) -> tip (y=-54): chord taper + aft sweep."""
        for v in o.data.vertices:
            t = (54.0 - v.co.y) / 108.0
            v.co.x = v.co.x * (1.0 - 0.47 * t) + 11.5 * t

    o = box(0, 0, 2.8, 44, 108, 4.2, None, apply_all=True)
    subdiv(o, 16)
    planform(o)
    rnd = random.Random(9)
    for v in o.data.vertices:            # torn root edge
        if v.co.y > 51:
            v.co.y -= (0.5 + 0.5 * math.sin(v.co.x * 0.9 + 1.3)) * 4 \
                + rnd.uniform(0, 1.5)
    displace(o, "CLOUDS", 10, 1.0, 91)
    displace(o, "VORONOI", 3.5, 0.5, 92)
    clamp_bottom(o, 0.1)
    o.data.materials.append(fin_m)

    r = box(8.6, 0, 5.4, 1.4, 108, 1.4, None, apply_all=True)  # rudder line
    subdiv(r, 12)
    planform(r)
    r.data.materials.append(mat("hinge", (0.10, 0.10, 0.11), rough=0.6,
                                metal=0.4))

    box(0, 52, 3.0, 30, 5, 4.6, scorch, rotz=-3)         # scorched torn root
    box(-6, 56, 2.6, 2.0, 7, 2.0, rib, rotz=-6)          # spar stubs
    box(4, 57, 2.4, 1.8, 8, 1.8, rib, rotz=8)

    # faded livery flash bands crossing the full chord near the tip -- the
    # tail-art remnant. planform() keeps them inside the fin outline (the v1
    # bricks overhung the edge and read as stickers).
    for yy, col in ((-30, (0.040, 0.062, 0.125)), (-37.5, (0.24, 0.05, 0.04))):
        b = box(0, yy, 5.0, 40, 4.5, 0.6,
                mat("flash%d" % yy, col, rough=0.6), apply_all=True)
        subdiv(b, 6)
        planform(b)

    box(-15, 44, 0.6, 4, 3, 1.0, panel, rotz=-35)        # shards at the root
    box(10, 47, 0.5, 3, 2.2, 0.9, scorch, rotz=15)

    lean(deg=-31.0)    # toppled rotation replaces the assembly lean
    render(name)


def c130_engine():
    """28x28: torn-off turboprop nacelle, dark intake, bent/snapped prop
    blades splayed at odd angles, scorched aft break."""
    name = "c130_engine"
    reset()
    camera(*WRECKS[name])
    alu, scorch, rib, glass, cheat, panel = kit_mats(101, burn=(-2, -14),
                                                     burn_amt=0.6)
    blade = mat("blade", (0.055, 0.055, 0.060), rough=0.45, metal=0.6)
    sand = sand_mat(109)

    # a lying nacelle read as a bucket/windmill at 28px in v1-v3. Strongest
    # top-down read: the nacelle tipped BACK, intake facing up -- a dark
    # round intake in a cowl ring with bent prop blades radiating from it.
    tilt = math.radians(18)
    axis = Vector((0.0, math.sin(tilt), math.cos(tilt)))
    ctr = Vector((0.0, -1.0, 6.0))
    o = cyl(ctr.x, ctr.y, ctr.z, 7.0, 12.0, None, rot=(18, 0, 0), verts=48,
            apply_all=True)
    subdiv(o, 4)
    displace(o, "CLOUDS", 5, 0.9, 111)
    clamp_bottom(o, 0.12)     # the tilted aft rim dips below the ground
    o.data.materials.append(alu)
    top = ctr + axis * 6.0
    lip = torus(0, 0, 0, 6.3, 0.9, panel)                # cowl lip ring
    lip.matrix_world = (Matrix.Translation(top)
                        @ Matrix.Rotation(tilt, 4, "X"))
    intake = cyl(0, 0, 0, 5.5, 1.6, scorch, verts=48)    # dark intake face
    intake.matrix_world = (Matrix.Translation(top - axis * 0.5)
                           @ Matrix.Rotation(tilt, 4, "X"))
    hub = sphere(0, 0, 0, 1.7, mat("hub", (0.055, 0.055, 0.055),
                                   rough=0.6, metal=0.3), scale=(1, 1, 0.6))
    hub.matrix_world = (Matrix.Translation(top + axis * 0.6)
                        @ Matrix.Rotation(tilt, 4, "X"))
    # bent blades radiating in the tilted intake plane, uneven angles.
    u = Vector((1.0, 0.0, 0.0))
    vv = Vector((0.0, math.cos(tilt), -math.sin(tilt)))
    for ang, ln_, twist in ((35, 9.0, 14), (120, 8.0, -10), (215, 8.6, 8),
                            (305, 5.0, -18)):
        a = math.radians(ang)
        d = u * math.cos(a) + vv * math.sin(a)
        pos = top + d * (ln_ / 2 + 1.4)
        bx = box(0, 0, 0, ln_, 1.7, 0.6, blade)
        bx.matrix_world = (Matrix.Translation(pos)
                           @ Matrix.Rotation(tilt, 4, "X")
                           @ Matrix.Rotation(a, 4, "Z")
                           @ Matrix.Rotation(math.radians(twist), 4, "Y"))
    box(0, -8.5, 1.5, 10, 4, 3, scorch, rotz=5)          # crushed aft rim
    drift(0, -11.5, 4, 1.8, 0.7, sand, 113)
    box(9.5, -6, 0.5, 3, 2, 0.8, panel, rotz=30)

    lean()
    render(name)


def burnt_tank():
    """42x57: burnt-out MBT, hull axis vertical (no lean) -- turret knocked
    askew, barrel drooped off-axis, scorched brown-black, one thrown track,
    burnt ground ring."""
    name = "burnt_tank"
    reset()
    camera(*WRECKS[name])
    hull_m = noise_mat("tankhull", 121,
                       ((0.18, (0.020, 0.017, 0.014)),
                        (0.45, (0.055, 0.040, 0.026)),
                        (0.70, (0.145, 0.070, 0.032)),
                        (0.90, (0.125, 0.115, 0.105))),
                       metal=0.3, rough=0.6, streak=(0.08, 0.05, 0.08),
                       bump=0.4)
    turret_m = noise_mat("tankturret", 123,
                         ((0.18, (0.018, 0.015, 0.012)),
                          (0.50, (0.050, 0.036, 0.024)),
                          (0.75, (0.130, 0.062, 0.030)),
                          (0.92, (0.115, 0.105, 0.095))),
                         metal=0.3, rough=0.6, streak=(0.09, 0.06, 0.09),
                         bump=0.4)
    track = mat("track", (0.030, 0.026, 0.022), rough=0.8, metal=0.25)
    cleat = mat("cleat", (0.085, 0.078, 0.070), rough=0.5, metal=0.5)
    scorch = mat("tscorch", (0.015, 0.013, 0.011), rough=0.9)

    # burnt ground ring under the wreck, ragged edge, proud of the tracks.
    ring = cyl(0, -1, 0.18, 23.5, 0.3, None, apply_all=True)
    ring.scale = (0.85, 0.98, 1.0)
    _apply_xform(ring)
    subdiv(ring, 6)
    displace(ring, "CLOUDS", 9, 2.0, 131, axis="X")
    displace(ring, "CLOUDS", 9, 2.0, 132, axis="Y")
    clamp_bottom(ring, 0.10)
    ring.data.materials.append(mat("burnring", (0.028, 0.024, 0.020),
                                   rough=1.0))

    for sx, y0, y1 in ((1, -24, 22), (-1, -18, 22)):     # left track broken
        t = box(sx * 13.75, (y0 + y1) / 2, 3.2, 8.5, y1 - y0, 6.4, None,
                apply_all=True)
        subdiv(t, 8)
        displace(t, "CLOUDS", 5, 0.9, 133 + sx)
        clamp_bottom(t, 0.1)
        t.data.materials.append(track)
        for yy in range(y0 + 2, y1 - 1, 4):
            box(sx * 13.75, yy, 6.8, 7.4, 1.1, 0.5, cleat)
    # thrown track spilled off the broken left run.
    box(-14.8, -21, 1.0, 6.5, 9, 1.8, track, rotz=20)
    box(-15.8, -19, 2.1, 5.8, 1.0, 0.5, cleat, rotz=20)
    box(-13.6, -23.2, 2.1, 5.8, 1.0, 0.5, cleat, rotz=20)

    hb = box(0, 1, 6.6, 24, 46, 11, None, apply_all=True)
    subdiv(hb, 10)
    for v in hb.data.vertices:           # glacis taper at the bow
        if v.co.y > 15:
            v.co.x *= 1.0 - 0.28 * min(1.0, (v.co.y - 15) / 9.0)
        elif v.co.y < -17:
            v.co.x *= 1.0 - 0.10 * min(1.0, (-17 - v.co.y) / 7.0)
    displace(hb, "CLOUDS", 7, 0.9, 135)
    clamp_bottom(hb, 0.1)
    hb.data.materials.append(hull_m)
    for yy in (-13, -16.5, -20):                         # engine-deck grilles
        box(0, yy, 12.6, 17, 1.6, 0.7, scorch)

    tu = cyl(1.5, 4, 15, 9.5, 7, None)                   # turret, askew
    tu.scale = (1.0, 1.15, 1.0)
    tu.rotation_euler[2] = math.radians(26)
    _apply_xform(tu)
    subdiv(tu, 2)
    displace(tu, "CLOUDS", 6, 0.8, 136)
    tu.data.materials.append(turret_m)
    box(5.2, -3.6, 14.5, 11, 6, 5, turret_m, bevel=0.8, rotz=26)  # bustle
    cyl(-2.1, 4.5, 18.8, 2.5, 0.9, scorch)               # blown-open hatch
    cyl(-9.5, 11, 12.9, 2.7, 0.7, turret_m, rot=(8, 0, 0))  # popped lid

    # drooped, swung barrel: droop about X first, then swing about Z.
    droop = Matrix.Rotation(math.radians(-12), 4, "X")
    swing = Matrix.Rotation(math.radians(20), 4, "Z")
    rot = swing @ droop
    root = Vector((-2.4, 11.5, 15.0))
    box(-2.9, 12.9, 14.7, 4.5, 3.5, 3.5, turret_m, bevel=0.5,
        rotz=20)                                          # gun mantlet
    gunmetal = mat("gunmetal", (0.045, 0.040, 0.036), rough=0.55, metal=0.5)
    bar = cyl(0, 0, 0, 1.8, 16, gunmetal, axis="Y", verts=24, apply_all=True)
    bar.matrix_world = (Matrix.Translation(root) @ rot
                        @ Matrix.Translation((0, 8.0, 0)))
    muz = cyl(0, 0, 0, 2.1, 2.4, scorch, axis="Y", verts=24, apply_all=True)
    muz.matrix_world = (Matrix.Translation(root) @ rot
                        @ Matrix.Translation((0, 15.2, 0)))

    render(name)


def build_all(only=None):
    os.makedirs(OUTDIR, exist_ok=True)
    jobs = {
        "c130_nose": c130_nose,
        "c130_mid": c130_mid,
        "c130_tail": c130_tail,
        "c130_fin": c130_fin,
        "c130_engine": c130_engine,
        "burnt_tank": burnt_tank,
    }
    for name, fn in jobs.items():
        if only and name not in only:
            continue
        fn()
    print("wreck library complete:",
          sorted(n for n in jobs if not only or n in only))


if __name__ == "__main__":
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    build_all(only)
