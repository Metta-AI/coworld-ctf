# The 4-team "before" picture: ten seeds, one map, empty blocks

Rendered 2026-08-06 by the epic owner on the base branch before W0 landed.
Sheet: `2026-08-06-sheet-4team-before.png`.

    16 seeds requested, 10 rendered, 6 raised (1012 and 1013 among them)
    mean staticScore 0.835   mean interiorFrac 0.095
    arena control: 1.000 / 0.342

## What the picture shows

Every one of the ten tiles is the same board: a 3x3 lattice of city blocks divided by heavy
straight streets, with a circular plaza at the centre ringed by a scatter of small obstacles.
The blocks themselves are **flat, featureless tan** — empty floor. The play harness's independent
report that "six seeds produce one identical map, four more produce another" is not a subtle
statistical claim; it is visible at a glance.

This is the pinwheel complaint restated. The 4-team branch was given a street grid specifically so
it would stop being a pinwheel, and structurally it did — but with the blocks empty, what remains
reads as one radially-symmetric figure repeated ten times.

## It is the fill-floor bug, and the picture proves the mechanism

`docs/plans/2026-08-06-fill-budget-floor-finding.md` predicted this from the arithmetic alone:
on 4-team, structure drives the fill budget below `FillFloorPermille` (55), so the clamp at
`arena.nim:2073` fires on every attempt and all nine density steps emit the same, minimal fill.

Every visible symptom follows from that one clamp:

- **empty blocks** — the fill is pinned at the floor, so there is nothing to put in them
- **interiorFrac 0.095** — enclosure comes from the fill, and there is almost none
- **seed collapse** — with fill pinned and the street grid near-deterministic, almost nothing
  seed-dependent survives into the geometry
- **"too clogged" at the sparsest setting** — structure alone plus the floor already exceeds 170pm

Four separately-filed problems, one cause. That is the strongest argument that the budget
arithmetic is the right place to fix this and that tuning enclosure on top of it would have been
tuning on top of a clamp.

## Note for the archetype work

The central plaza is present on 10/10 of these tiles AND on 20/20 of the 2-team tiles. Across both
team counts, at every size class, the centre of the map is a fixture. The brief says it must not
be. See `2026-08-06-sheet-2team-verdict.md`.
