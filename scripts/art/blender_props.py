#!/usr/bin/env python3
"""Models + renders the MW2 map-pack PROP LIBRARY as real top-down sprites.

Maxwell: "stop using procedural shapes. i want to use actual objects. using
blender we can do this." Every family here is a real modeled object (simple
primitives, no photo textures) rendered by Blender with:

  - an ORTHOGRAPHIC camera looking straight down -Z (map view, no perspective),
  - a sun keyed from the image UPPER-LEFT at 45 deg, matching the engine's
    carved-bevel light direction, with a shadow-catcher ground plane so each
    prop bakes a soft contact shadow into its alpha,
  - transparent film, Standard view transform (no Filmic/AgX wash), so the
    sprite composites flat onto the painted board.

Each family renders at 4x its typical collision footprint (a 140x42 container
-> 560x168) to data/props/<family>.png. sim.nim composites them over the
EXACT collision shapes via CtfMap.props (see blitPropSprites); the carved
textured-stone material stays underneath as the base for any transparent
pixel, so art and geometry can never disagree.

Run:  /opt/homebrew/bin/blender -b -P scripts/art/blender_props.py
Then: python3 scripts/art/blender_props.py --sheet   (PIL contact sheet only)
"""
import math
import os
import sys

OUTDIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "props"))

# family -> (footprint w, footprint h) in map px; renders at 4x.
FAMILIES = {}


def contact_sheet():
    """PIL contact sheet on a mid-grey board for a one-look review."""
    from PIL import Image
    files = sorted(f for f in os.listdir(OUTDIR) if f.endswith(".png"))
    pad, cell_h = 12, 200
    tiles = []
    for f in files:
        im = Image.open(os.path.join(OUTDIR, f)).convert("RGBA")
        s = min(1.0, cell_h / im.height, 560 / im.width)
        tiles.append((f, im.resize((max(1, int(im.width * s)),
                                    max(1, int(im.height * s))))))
    w = max(t.width for _, t in tiles) + 2 * pad
    h = sum(t.height + pad for _, t in tiles) + pad
    sheet = Image.new("RGBA", (w, h), (126, 82, 52, 255))
    y = pad
    for _, t in tiles:
        sheet.alpha_composite(t, (pad, y))
        y += t.height + pad
    out = "/tmp/prop-sheet.png"
    sheet.convert("RGB").save(out)
    print("wrote", out, "with", [f for f, _ in tiles])


if "--sheet" in sys.argv:
    contact_sheet()
    sys.exit(0)

import bpy  # noqa: E402  (only under blender -b -P)

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
    # Shadow catcher ground: bakes the contact shadow into the alpha.
    bpy.ops.mesh.primitive_plane_add(size=4000, location=(0, 0, 0))
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


def mat(name, color, rough=0.6, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


def _finish(o, m, bevel=0.0):
    if m is not None:
        o.data.materials.append(m)
    if bevel > 0:
        mod = o.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
    return o


def box(cx, cy, cz, sx, sy, sz, m, bevel=0.0, rotz=0.0, rotx=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=(cx, cy, cz))
    o = bpy.context.active_object
    o.scale = (sx, sy, sz)
    # Bake the scale into the mesh: a bevel modifier's width is measured in
    # OBJECT space, so beveling a unit cube that is merely display-scaled
    # rounds the whole box into a blob (the v1 "teal fish" container).
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.rotation_euler[0] = math.radians(rotx)
    o.rotation_euler[2] = math.radians(rotz)
    return _finish(o, m, bevel)


def cyl(cx, cy, cz, r, depth, m, axis="Z", verts=64, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth,
                                        location=(cx, cy, cz))
    o = bpy.context.active_object
    if axis == "X":
        o.rotation_euler[1] = math.radians(90)
    elif axis == "Y":
        o.rotation_euler[0] = math.radians(90)
    return _finish(o, m, bevel)


def torus(cx, cy, cz, major, minor, m, axis="Z"):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor,
                                     location=(cx, cy, cz))
    o = bpy.context.active_object
    if axis == "X":
        o.rotation_euler[1] = math.radians(90)
    return _finish(o, m)


def sphere(cx, cy, cz, r, m, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=r, location=(cx, cy, cz),
                                         segments=48, ring_count=24)
    o = bpy.context.active_object
    o.scale = scale
    return _finish(o, m)


def cone(cx, cy, cz, r1, r2, depth, m, axis="Z"):
    bpy.ops.mesh.primitive_cone_add(radius1=r1, radius2=r2, depth=depth,
                                    location=(cx, cy, cz), vertices=48)
    o = bpy.context.active_object
    if axis == "X":
        o.rotation_euler[1] = math.radians(90)
    return _finish(o, m)


def render(name, w, h):
    FAMILIES[name] = (w, h)
    SC.render.filepath = os.path.join(OUTDIR, name + ".png")
    SC.render.image_settings.file_format = "PNG"
    SC.render.image_settings.color_mode = "RGBA"
    bpy.ops.render.render(write_still=True)
    print("rendered", name, w * 4, "x", h * 4)


# --- the families -----------------------------------------------------------

def prop_container():
    """Corrugated shipping container, 140x42 (Rust yard; Terminal carts)."""
    reset(); camera(140, 42)
    steel = mat("cargo", (0.05, 0.17, 0.19), rough=0.65, metal=0.25)
    dark = mat("cargo_dark", (0.03, 0.11, 0.13), rough=0.7, metal=0.25)
    box(0, 0, 13, 138, 40, 26, steel, bevel=0.8)
    # roof corrugation: ribs across the width, spaced along the length.
    x = -60
    while x <= 60:
        box(x, 0, 26.6, 2.4, 37, 1.5, steel)
        x += 8.6
    # door end (+X): header line + hinges read as the "door" end from above.
    box(67, 0, 13.6, 3.2, 41, 27.2, dark)
    box(67, 0.5, 27.4, 3.2, 1.6, 1.2, dark)
    # corner castings.
    for sx in (-67, 67):
        for sy in (-18.6, 18.6):
            box(sx, sy, 27.0, 4.5, 4.5, 2.0, dark)
    render("container", 140, 42)


def prop_fuel_tank():
    """Riveted fuel/oil tank, disc r58 (Rust). Center vent covers the
    concentric r20 'tank vent' collision disc."""
    reset(); camera(116, 116)
    rust = mat("tank", (0.40, 0.24, 0.14), rough=0.6, metal=0.35)
    dark = mat("tank_dark", (0.24, 0.13, 0.08), rough=0.7, metal=0.3)
    cyl(0, 0, 22, 57, 44, rust)
    torus(0, 0, 44, 55.5, 1.6, dark)          # top rim weld
    torus(0, 0, 44.2, 38, 1.1, dark)          # plate seam
    cyl(0, 0, 46, 19, 8, dark)                # center vent drum (r20 collider)
    cyl(0, 0, 50.6, 15.5, 2.0, rust)          # vent cap
    cyl(37, 20, 44.6, 2.4, 34, dark, axis="X")  # radial top pipe
    cyl(-30, -30, 44.6, 2.0, 30, dark, axis="Y")
    render("fuel_tank", 116, 116)


def prop_barrel():
    """Oil drum, disc r20 (Rust yard clusters)."""
    reset(); camera(40, 40)
    body = mat("drum", (0.36, 0.11, 0.07), rough=0.55, metal=0.4)
    dark = mat("drum_dark", (0.18, 0.06, 0.04), rough=0.65, metal=0.35)
    cyl(0, 0, 14, 19, 28, body)
    torus(0, 0, 28, 18, 1.4, body)            # top chime
    cyl(0, 0, 28.3, 16.2, 1.0, dark)          # inset lid
    cyl(7.5, 0, 29.1, 2.6, 1.4, body)         # bung
    cyl(-7.5, 0, 29.1, 1.8, 1.4, body)        # vent bung
    render("barrel", 40, 40)


def prop_crate():
    """Planked wooden crate, 52x52 typical (also blitted at 26x26)."""
    reset(); camera(52, 52)
    wood = mat("wood", (0.33, 0.21, 0.11), rough=0.85)
    wood2 = mat("wood2", (0.28, 0.17, 0.09), rough=0.85)
    box(0, 0, 14, 50, 50, 28, wood2, bevel=1.0)
    for i, y in enumerate((-17, 0, 17)):      # top planks with visible gaps
        box(0, y, 29.2, 50, 15.2, 2.4, wood if i != 1 else wood2, bevel=0.4)
    for y in (-23, 23):                       # edge battens
        box(0, y, 30.4, 50, 3.6, 2.6, wood, bevel=0.4)
    render("crate", 52, 52)


def prop_duct():
    """Galvanized duct run, 120x20 typical (Highrise runs; Terminal
    scanners + jet bridge blit it shorter/rotated)."""
    reset(); camera(120, 20)
    zinc = mat("zinc", (0.42, 0.44, 0.46), rough=0.35, metal=0.85)
    dark = mat("zinc_dark", (0.26, 0.28, 0.30), rough=0.45, metal=0.8)
    box(0, 0, 7, 118, 17, 14, zinc, bevel=1.0)
    for x in (-36, -12, 12, 36):              # segment flanges
        box(x, 0, 7.4, 2.6, 18.2, 15.0, dark)
    for x in (-58, 58):                       # end collars
        box(x, 0, 7.2, 3.6, 18.2, 14.8, dark)
    for x in (-48, -24, 0, 24, 48):           # top vent slats
        box(x, 0, 14.6, 7, 12, 0.9, dark)
    render("duct", 120, 20)


def prop_shanty_roof():
    """Gabled shanty roof, 64x48, terracotta with a zinc patch (Favela)."""
    reset(); camera(64, 48)
    terra = mat("terra", (0.42, 0.16, 0.08), rough=0.8)
    terra2 = mat("terra2", (0.36, 0.13, 0.07), rough=0.8)
    zinc = mat("roof_zinc", (0.40, 0.42, 0.43), rough=0.4, metal=0.7)
    tilt = 22
    dz = 24 * math.sin(math.radians(tilt)) / 2
    for side, m in ((1, terra), (-1, terra2)):
        box(0, side * 12.4, 12 + dz, 63, 26.5, 2.2, m,
            rotx=-tilt * side)
        # corrugation ridges running down the slope, tilted WITH it.
        x = -28
        while x <= 28:
            box(x, side * 12.4, 12 + dz + 1.6, 1.8, 25, 1.5, m,
                rotx=-tilt * side)
            x += 5.6
    # patchwork zinc sheet on one slope corner.
    box(20, 13.4, 12 + dz + 1.1, 20, 23, 1.2, zinc, rotx=-tilt)
    cyl(0, 0, 12 + 2 * dz + 1.2, 1.8, 62, terra, axis="X")  # ridge cap
    render("shanty_roof", 64, 48)


def prop_fuselage():
    """747 fuselage tube, 410x46, nose toward -X (Terminal)."""
    reset(); camera(410, 46)
    white = mat("hull", (0.80, 0.81, 0.83), rough=0.45)
    band = mat("livery", (0.10, 0.19, 0.42), rough=0.5)
    dark = mat("hull_dark", (0.16, 0.17, 0.20), rough=0.5)
    cyl(0, 0, 22, 22, 408, white, axis="X", verts=96)
    cyl(-107, 0, 37, 11, 86, white, axis="X")   # upper-deck hump
    cyl(-193, 0, 22, 22.3, 9, dark, axis="X")   # cockpit window band
    cyl(185, 0, 22, 22.3, 13, band, axis="X")   # tail livery band
    cyl(60, 0, 22, 22.2, 6, band, axis="X")     # mid livery ring
    box(-5, 0, 6, 74, 44, 12, white, bevel=2.5)  # wing-root fairing
    render("fuselage", 410, 46)


def prop_nose():
    """747 radome dome, disc r23; cockpit toward +X (fuselage side)."""
    reset(); camera(46, 46)
    white = mat("nose", (0.80, 0.81, 0.83), rough=0.45)
    dark = mat("nose_dark", (0.16, 0.17, 0.20), rough=0.5)
    sphere(0, 0, 18, 22, white, scale=(1, 1, 0.85))
    # radome seam ring: reads as the nose-cone joint from above.
    torus(0, 0, 32, 13, 0.7, dark)
    render("nose", 46, 46)


def prop_wing():
    """Wing slab, 146x20, root at -X tip at +X (also the tailplanes)."""
    reset(); camera(146, 20)
    grey = mat("wing", (0.70, 0.71, 0.74), rough=0.5)
    dark = mat("wing_dark", (0.42, 0.43, 0.46), rough=0.55)
    o = box(0, 0, 26, 144, 18, 5, grey, bevel=1.0)
    for v in o.data.vertices:                   # taper toward the tip
        if v.co.x > 0:
            v.co.y *= 0.55
    box(-20, -2.5, 29.2, 88, 1.2, 0.5, dark)    # spar line
    box(-45, 4, 29.2, 40, 1.1, 0.5, dark)       # flap line
    render("wing", 146, 20)


def prop_engine():
    """Engine nacelle, disc r15; intake toward -X (nose direction)."""
    reset(); camera(30, 30)
    steel = mat("nacelle", (0.58, 0.59, 0.62), rough=0.3, metal=0.8)
    dark = mat("intake", (0.08, 0.08, 0.10), rough=0.5)
    cyl(0.5, 0, 12, 12, 25, steel, axis="X")
    torus(-12, 0, 12, 11.2, 1.5, steel, axis="X")  # intake lip
    cyl(-11.6, 0, 12, 10.2, 1.6, dark, axis="X")   # intake fan disc
    cone(13.4, 0, 12, 9.5, 5.5, 4, steel, axis="X")  # exhaust taper
    render("engine", 30, 30)


def prop_tower_leg():
    """Lattice derrick leg, 28x28 (Rust tower)."""
    reset(); camera(28, 28)
    red = mat("derrick", (0.38, 0.12, 0.07), rough=0.6, metal=0.3)
    dark = mat("derrick_dark", (0.22, 0.07, 0.04), rough=0.65, metal=0.3)
    for sx in (-11, 11):
        for sy in (-11, 11):
            box(sx, sy, 25, 5, 5, 50, red)      # corner posts
    for y in (-12, 12):                         # top ring frame
        box(0, y, 48, 28, 3.6, 3.6, red)
    for x in (-12, 12):
        box(x, 0, 48, 3.6, 28, 3.6, red)
    box(0, 0, 42, 33, 3, 3, dark, rotz=45)      # cross braces
    box(0, 0, 42, 33, 3, 3, dark, rotz=-45)
    render("tower_leg", 28, 28)


def prop_tail_fin():
    """747 tail cone + vertical fin seen edge-on, 26x38 (Terminal)."""
    reset(); camera(26, 38)
    white = mat("tail", (0.80, 0.81, 0.83), rough=0.45)
    band = mat("tail_livery", (0.10, 0.19, 0.42), rough=0.5)
    cone(0, 0, 19, 18.5, 6.5, 26, white, axis="X")
    o = box(-3, 0, 34, 17, 3.2, 22, band)       # fin blade along the axis
    for v in o.data.vertices:                   # sweep: top edge shifts aft
        if v.co.z > 0:
            v.co.x += 4
    render("tail_fin", 26, 38)


def prop_helipad_parapet():
    """Concrete helipad parapet wall, 96x26 (Highrise)."""
    reset(); camera(96, 26)
    conc = mat("conc", (0.50, 0.48, 0.45), rough=0.85)
    cap = mat("cap", (0.58, 0.56, 0.53), rough=0.8)
    dark = mat("joint", (0.30, 0.29, 0.27), rough=0.85)
    box(0, 0, 6, 94, 20, 12, conc, bevel=0.8)
    box(0, 0, 13, 95, 24, 2.6, cap, bevel=0.8)  # coping cap
    for x in (-32, 0, 32):                      # expansion joints
        box(x, 0, 13.2, 1.2, 24.4, 2.8, dark)
    render("helipad_parapet", 96, 26)


def prop_qalat_wall():
    """Mud-brick compound wall, 92x18 (Afghan's two qalats).

    Rendered as a horizontal run and reused rotated for the north-south
    segments, so one sprite covers every wall on both compounds.
    """
    reset(); camera(92, 18)
    # Deliberately much darker than Afghan's sand floor. The first version
    # used a true mud colour (0.46, 0.35, 0.22) which rendered within a shade
    # of the ground, and full-width joint ribs standing proud of the coping —
    # from above the wall vanished into the floor and the ribs read as the
    # rungs of a ladder rather than as brickwork.
    mud = mat("mud", (0.33, 0.24, 0.145), rough=0.92)
    cap = mat("mud_cap", (0.40, 0.30, 0.18), rough=0.9)
    joint = mat("mud_joint", (0.22, 0.155, 0.09), rough=0.95)
    box(0, 0, 7, 90, 16, 14, mud, bevel=1.2)
    box(0, 0, 15, 91, 17, 2.4, cap, bevel=1.2)      # weathered coping
    # Courses: inset, shallow, and sparse, so they read as texture on a solid
    # wall rather than as separate objects.
    x = -34
    while x <= 34:
        box(x, 0, 16.0, 0.9, 12.0, 0.5, joint)
        x += 22.5
    render("qalat_wall", 92, 18)


def prop_qalat_hut():
    """Flat-roofed mud outbuilding, 46x40 (Afghan qalat outbuildings)."""
    reset(); camera(46, 40)
    # Same contrast rule as the wall: Afghan's floor is pale sand, so a
    # true mud tone disappears into it from directly above.
    mud = mat("hut", (0.35, 0.26, 0.16), rough=0.92)
    roof = mat("hut_roof", (0.30, 0.22, 0.135), rough=0.95)
    beam = mat("hut_beam", (0.19, 0.135, 0.08), rough=0.95)
    box(0, 0, 9, 44, 38, 18, mud, bevel=1.0)
    box(0, 0, 19, 45, 39, 2.6, roof, bevel=1.0)
    # roof beams poking past the parapet, the giveaway of a mud roof.
    for y in (-12, 0, 12):
        box(24, y, 19.4, 8, 2.4, 2.2, beam)
    render("qalat_hut", 46, 40)


def prop_hull_section():
    """Cut fuselage section stood on edge, 24x100 (Scrapyard stand shelters).

    A boneyard shelters behind sawn airframe, not masonry, so this is a hull
    slice: skin panel with frame ribs and a torn edge.
    """
    reset(); camera(24, 100)
    skin = mat("hull", (0.62, 0.62, 0.64), rough=0.45, metal=0.6)
    rib = mat("hull_rib", (0.44, 0.45, 0.47), rough=0.55, metal=0.5)
    grime = mat("hull_grime", (0.30, 0.29, 0.28), rough=0.8, metal=0.2)
    box(0, 0, 11, 22, 98, 22, skin, bevel=0.7)
    y = -42
    while y <= 42:                                  # frame ribs across it
        box(0, y, 22.6, 23, 2.6, 1.8, rib)
        y += 12
    box(0, -49, 11, 23.5, 3.0, 23, grime)           # torn cut ends
    box(0, 49, 11, 23.5, 3.0, 23, grime)
    render("hull_section", 24, 100)


if __name__ == "__main__":
    os.makedirs(OUTDIR, exist_ok=True)
    for fn in (prop_container, prop_fuel_tank, prop_barrel, prop_crate,
               prop_duct, prop_shanty_roof, prop_fuselage, prop_nose,
               prop_wing, prop_engine, prop_tower_leg, prop_tail_fin,
               prop_helipad_parapet, prop_qalat_wall, prop_qalat_hut,
               prop_hull_section):
        fn()
    print("prop library complete:", sorted(FAMILIES))
