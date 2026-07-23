# Rig art blocker (2026-07-23)

## The quality gap is a BROKEN ART EXPORT, proven — not a code/tint bug.
The rich cyan-faced cog Maxwell wants is `data/soldier_red.png` (the one-piece CvC
cog) and the hi-res `data/cog_base_{red,blue}.png` (legs+wheels) / `data/cog_head_
{red,blue}.png` (body+visor). The plan (Maxwell's, correct): keep cog_head whole on
top (occludes the central leg joins), cut the 3 legs from cog_base (they attach at
the sides, unoccluded), rotate them ±~30 about their hips, caster the wheels.

BLOCKER: `cog_head_{red,blue}.png` and `cog_base_*` were exported WITHOUT real
transparency — the alpha is ~97-100% opaque and the "background" is the
transparency CHECKERBOARD flattened into RGB (corner luminance alternates ~0 and
~50-100, regular period). So there's no clean alpha to composite. cog_base happens
to composite OK because the wedge-cut discards the matte with the non-leg sectors;
cog_head has no angular structure to cut by, so the checker stays around the cube.
Every algorithmic knockout (CC, erode/dilate, density filter, luminance, near-black
color) either keeps checker specks or eats the cog's own dark outlines/visor,
because the cog's outline luminance overlaps the checker's.

## What IS correct and committed (branch maxwell/cog-base-turret-split):
- Geometry/bones/hips/feet: match the tool export EXACTLY (verified numerically).
- Leg swing: rest +/-45, hard-turn one-sided to +/-75 at sw=120 — matches tool.
- Wheels seated at fork tips (fixed the double-boardScale bug).
- Sprite-id collision fixed (+ compile-time guard).
- Heart cradled ON TOP in the arms, no longer occluded (z fix).
- Tint matches the tool's formula (verified pixel-equal).
Currently renders the `data/rig/validated/*` parts, which are CLEAN but LOWER
quality (flatter, the tool's own input) than soldier_red.

## To finish (needs Maxwell / clean art):
Re-export cog_base_{team} + cog_head_{team} WITH REAL ALPHA (transparent bg, not a
flattened checker). Then: legs = wedge-cut cog_base (existing geometry), head =
cog_head whole on top. Drop-in: point ensureRigLoaded at the clean parts; the FK/
scale/z are all already correct. The head bone = artHub (523,412) on the 1046 frame;
scale so the cube reads ~SoldierBodyPx.
