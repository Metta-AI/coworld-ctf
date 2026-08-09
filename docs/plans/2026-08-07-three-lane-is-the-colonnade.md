# three-lane was never the problem — a hard-coded 28 was

2026-08-07, task 897b384c, epic 3757029c. Worktree `~/projects/ctf-threelane`,
branch `maxwell/mapgen-three-lane`, off `maxwell/mapgen-rebuild` at 8418626.

**2-team validity is 40/40 (100%), up from 38/40 (95%). The minimum route count
over the 40 seeds is 3, up from 0. Nothing regressed at 4 teams (32/32 before
and after).** The fix is one expression.

## The claim was true, the explanation was not

`2026-08-06-archetype-fingerprints.md` measured `three-lane` as the only failing
archetype and proposed a cause: three-lane is the OLDEST of the six, it emits
into lane bands with the older clipping path while the five newer archetypes
hand the vocabulary their own compartments, so it must be carrying structure
cost the others shed.

The first half reproduces exactly. The second half is false.

`tools/three_lane_probe.nim` attributes the finished `leftObstacles` to the
LAYER that emitted it — structure, budgeted fill, centre feature, row-cover
pickets — and reads each layer's cover off the validator's own mask by
rasterising a PREFIX of the list. Prefix rasterisation, not an area sum: the
fill layers overlap by construction, so a sum over-counts exactly where it
matters. Matched sample, attempt 0 of each of 40 2-team seeds, so a sick
archetype does not contribute ten times the rows of a healthy one:

    archetype    structure  fill  centre  pickets  total   (permille, marginal)
    warren       124        19    16      8        169
    three-lane    87        33    34      10       165
    field         71        10    20      29       132
    blocks        40        74    35      15       165
    ring          27        55    18      19       120
    hub            0        71    17      25       114

three-lane's structure is 87 permille against warren's 124, and warren is 100%
valid. Its total is 165 — the same as blocks, below warren. **It is not carrying
an unusual structure cost and it is not unusually clogged on average.** The
compartment hypothesis also does not survive its own statement: `field` declares
no compartments either (`map_archetypes.ArchetypePlan.cells` is empty for both)
and `field` is 7/7.

## What it actually is

`centre` — the colonnade of spinning diamonds on the symmetry axis — costs 34
permille of a 170 ceiling on three-lane, and it is UNBUDGETED. The fill budget
in `arena` claims in its own comment to leave "room for the pickets and the
centre feature that are still to come" and reserves nothing for either.

Both failing seeds (1026, 1038) are `small` boards, where the same colonnade
costs 41-48. Swept over all 100 candidates of each seed — the real
`generateCtfMapSelection` cap, not the first K draws — NEITHER seed had a single
draw under the ceiling before this change:

    1038 best of 100:  cover 172 = structure 103 + fill 21 + centre 48 + pickets 0
    1026 best of 100:  cover 171 = structure  93 + fill 31 + centre 41 + pickets 6

1038's fill is already at its FLOOR and its picket count is ZERO. There was
nothing left to give: structure plus centre is 151 permille before anything
optional is drawn.

The cause is a hard-coded literal. `map_rules.BaseCoverSizePx` documents the
contract out loud —

> The STANDARD class's cover-piece width. The generator's discs and diamonds
> carry radius 28, so a piece is 56 px across.

— and `coverSizePx` scales that by `sqrt(class scale)` per class. **Nothing read
it back.** `arena.trySpinner` carried `radius: 28` as a literal, so the spinners
stayed the same absolute size while the interior they are measured against went
to 0.72x on `small`. This is the same defect `laneSeparatorThickPx` already
exists to fix for the separators, and its comment names the same symptom: "a
fixed absolute size while the board shrank, which is what put the small class
over the cover ceiling on structure alone."

The fix is that the spinner radius now comes from `rules.coverSizePx div 2`.

## The blast radius, exhibited rather than asserted

`coverSizePx` is 56 at `standard` BY CONSTRUCTION, so `standard` boards are
unmoved to the pixel and only the other classes can change. That is a checkable
claim, and the curated pool checks it: `tools/pool_class_probe.nim` reports the
20-entry pool as ten `standard` (indices 0,1,2,3,7,9,10,12,13,16) and ten
`small` (4,5,6,8,11,14,15,17,18,19), and the ten `PoolRenderHashes` that moved
are **exactly the ten `small` ones**, with all ten `standard` hashes
byte-identical.

The ten new renders were looked at before the pin was rewritten: mirror symmetry
exact on all ten, none degenerate, archetypes still legible (field at
1006/1041, a room lattice at 1007/1016, lane bands at 1005/1009/1012/1015), the
axis colonnade still present — smaller, as intended, but there, which is what
the spinning-diamond footprint test needs.

## The fingerprint, before and after

2-team, 40 seeds, `tools/archetype_probe.nim`, arena as control
(score 1.000, int 0.342, cover 167pm, routes 8, rooms 7):

    archetype    n   valid BEFORE -> AFTER   int            cover      score
    three-lane   10  8/10 (80%)  -> 10/10    0.329 -> 0.315  161 -> 157  0.785 -> 0.976
    blocks       10  10/10       -> 10/10    0.294 -> 0.287  161 -> 163  0.980 -> 0.982
    ring          3  3/3         -> 3/3      0.205 -> 0.204  151 -> 150  0.977 -> 0.977
    hub           4  4/4         -> 4/4      0.200 -> 0.198  137 -> 146  0.946 -> 0.946
    warren        6  6/6         -> 6/6      0.444 -> 0.463  164 -> 166  0.985 -> 0.992
    field         7  7/7         -> 7/7      0.213 -> 0.224  147 -> 147  0.966 -> 0.962

    ALL           40 38/40 (95%) -> 40/40 (100%)
    routeMin over all seeds:  min 0 -> min 3

Whole-population means over the same 40 seeds, so the aggregate the epic
scorecard reads is stated too: interiorFrac 0.295 -> 0.294, cover 156 -> 157pm.
The validity moved and the population did not, which is the shape a fix wants
— the two seeds that were being rejected joined the population at ordinary
values rather than the distribution shifting under it. 4-team, 32 seeds:
interiorFrac 0.280 -> 0.281, cover 154 -> 155pm.

4-team, 32 seeds: 32/32 before and after. Scores flat (blocks 0.968->0.967,
ring 0.989->0.979, hub 0.938->0.938, warren 0.989->0.987, field 0.994->0.994);
interiorFrac mostly up (warren +0.007, field +0.014, ring +0.001, blocks
-0.006, hub -0.002).

No archetype loses more than 0.014 of interiorFrac or 0.010 of staticScore, and
the two largest moves in each column are UPWARD (warren +0.019 int, +0.007
score at 2 teams). three-lane's staticScore 0.785 -> 0.976 is almost entirely
the two invalid seeds ceasing to score 0: conditional on validity, three-lane
already scored ~0.98, which is another thing the "worst on every axis" reading
had wrong.

The generator's first-attempt pass rate rose on both team counts:
2-team 144/201 (71.6%) -> 149/201 (74.1%), 4-team 126/201 (62.7%) -> 129/201
(64.2%). `tests/fixtures/map-validation-baseline.tsv` was regenerated with
`tools/gen_validation_baseline.nim`, as its own doc instructs; every one of the
79 changed rows moves DOWN in permille or from a rejection to a pass. That is
the generator improving, and the fixture is a record rather than a bar.

## routeMin 0 was a diagnostic artefact, and the hard band IS gating

The task flagged `routeMin 0` on a shipping archetype. It was not shipping.
`archetype_probe` reports the archetype of an INVALID seed by falling back to
`generateMapAttempt(seed, ..., 0)` — candidate 0, unranked — precisely so a
topology that cannot validate is not hidden inside an aggregate. Seed 1038 was
that seed, so its `routeMin 0` was a property of one rejected draw and never of
a board anyone plays.

The hard band is real, and I checked it separately. `staticScore` returns 0.0 on
a `bandHard` breach, and the sweep shows it firing: every three-lane candidate
with `routeCountMin < 2` scores exactly 0.000 while its siblings at 2-5 routes
score 0.9+. There is one residual sharp edge worth knowing about, though it did
not bite here: `selectBestMap` initialises `result.score = -1.0`, so if EVERY
valid candidate of a seed scores 0, the first of them still wins. A hard breach
therefore loses any contest it is in, but cannot lose a contest where every
entrant has breached. After this change the minimum routeMin over 40 shipping
2-team boards is 3, so no seed is in that state today.

## What I tried and it did not work

three-lane is the only archetype that runs a row-cover pass TWICE — once in
`map_lanes.plugOpenRows` inside `carveLanes`, once in `arena`'s `rowCover` block
— and the first works on a shape-span approximation of a problem the second
solves on the real mask. That looked like the older-clipping-path smoking gun.
A/B'd behind a compile flag over the same 40 seeds: dropping the lane pickets
buys 2 permille of cover on three-lane (157 -> 155) and costs 0.011 of
interiorFrac (0.315 -> 0.304) for identical validity (40/40) and identical
staticScore (0.976). It pays for itself in nothing. **Reverted, and the
redundancy theory is refuted rather than left open.**

## The margin that is left, stated as a number

`2026-08-06-cover-headroom-warning.md` should be read with this correction: the
2-team cover budget was not uniformly at its ceiling, and it now has room. But
the room is not evenly spread, and the two seeds this fixed are still the
tightest boards in the population. Candidates passing out of 100 drawn, the four
`small` three-lane seeds:

    1007   0/100 -> 12/91   (hits K=12 and stops)
    1040   0/100 -> 12/91   (hits K=12 and stops)
    1038   0/100 ->  9/100
    1026   0/100 ->  4/100

1026 ships the best of four rather than the best of twelve, so it gets a
board from the 80th percentile of its own range instead of the 92nd. That is
valid and it is honest to say it is thin.

The deferred polygon/diagonal lane clipping (7801f394) was measured at 186
permille against the 170 ceiling and needs roughly 16 permille to land. It will
not find that in three-lane's structure, which is mid-table. The obvious place
to look next is the same layer this task found: the centre feature is 17-35
permille depending only on which `CentrePolicy` an archetype declares, it is
still unbudgeted, and the fill budget still claims to have reserved for it.
Making that claim true is a change to `arena`'s budget block, not to any
archetype.

## Tooling left behind

- `tools/three_lane_probe.nim` — the layer attribution above. Needs
  `-d:maptrace`. Prints `mapFitnessLabel()` in its header so "was the ranker
  even linked" can never be assumed again, mirrors `generateCtfMapSelection`'s
  draw-to-100-until-K-pass loop exactly, and `--attempts=N` takes a matched
  sample across archetypes.
- `tools/pool_class_probe.nim` — each pool entry's size class, so a
  size-class-scoped change can be held to its claimed blast radius entry by
  entry instead of re-pinning 20 hashes on trust.
- `arena.MapGenTrace` / `lastMapGenTrace` — debug-only (`-d:maptrace`) prefix
  boundaries of the four emission layers.
- `arena.MapGenMaxAttempts` is now exported. A probe that re-declared it drew
  the first K CANDIDATES instead of the first K PASSES, and reported seed
  1004's two early survivors as its shipping board when the real selection
  keeps drawing to 100 and ships a different, better one.
