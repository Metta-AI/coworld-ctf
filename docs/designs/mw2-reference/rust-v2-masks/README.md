# Rust v2 raster masks

Canvas-scale single-channel PNGs (1040x972, wall = white 255, floor = black 0)
for the Rust rebuild plan in `docs/designs/rust-layout-v2.md`. These are the
authoritative collision geometry — the doc's tables and these masks were
emitted from the same shape list, so they agree pixel-for-pixel. Rasterize
directly (OR the two masks together for the full wall layer); do NOT re-trace
them into polygons (that is the failure mode that fragmented Afghan's massif).

## Split

| file | white px | contents |
|---|---|---|
| `terrain.png` | 343,902 | everything that reads as ground/boundary: the out-of-bounds dune band from every canvas edge in to the yard wall, the yard perimeter wall itself (the playable boundary on all four sides), and the west-wall guard box. Equivalent to: full canvas filled, floor rect (204,106) 801x831 carved, plus box (204,469) 12x21. |
| `structures.png` | 70,087 | every built thing inside the yard, doors already carved: canopy shed + stub + annex, NW shed + annex, long container + annex, vat battery plinth (solid H), workshop + yard walls + windbreak, garage L, small container, SE shed + L wall, big fuel tank (rotated) + head skid, south diagonal container (rotated), south room, warehouse L + nook annex, conveyor works (hopper + chute + slab), drum tank disc, pump house, the derrick (4 legs, porch wall, south band, east wall, pump skid), gallery hall, 2 leaning planks (rotated), 18 pipe-trestle piers 9x9, 4 barrel discs r14. |

## Exclusions (in the reference but deliberately NOT in the masks)

- **Pipe tubes** — all three dotted pipe runs (west road pipeline, west feed
  pipe, big east pipe) are elevated walk-unders in the real map; only their
  9x9 trestle piers carry collision. The tubes are overhead art.
- **Truck** on the west road at ref (35..45, 28..55) — canvas ~(252,157) 30x81
  prop, art only.
- **Three dark crates** on the warehouse north side, ref (40..55, 203..207) —
  15px art props at (270,684) (291,684) (312,684).
- **Vat cylinders** (the four circles in the NE battery) — the plinth beneath
  them is solid in `structures.png`; the circles themselves are top-down art.
- **Interior catwalk dots** drawn inside the canopy shed and the gallery hall
  (minimap overhead-walkway notation, not walls).
- **Oil-stain / scorch shading** and the HUD tint of the source minimap.
- Rust's minimap frame contains **no Domination/objective icons** to strip;
  the small circle NW of the tower is the drum tank (a real object — kept as
  a solid r16 disc).

## Provenance

Measured from the 292x292 playable frame of
`docs/designs/mw2-reference/rust.png` (frame origin (140,115) in the 512
original, PLATES fractions (0.275, 0.225, 0.845, 0.795), rot=0), contrast
stretched, thresholded at 185, component-labelled and read off at ref-pixel
precision. Transform to this canvas: `canvas = (3*rx + 147, 3*ry + 73)`.
