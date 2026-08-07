# The lane clip finishes: polygons and diagonals are CUT, and the band was never the core

Measured 2026-08-07 on `maxwell/mapgen-city-clip` @ the merge of
`maxwell/mapgen-rebuild` @ 8418626, task eea795c7 (epic LAND THE GENERATOR).

The task this closes was filed as "built, measured, reverted; land it AFTER
the fill-budget fix". Two things turned out to be true that the brief did not
say: the precondition it names does not exist any more, and the change it
describes is not the one that mattered most in the file.

## The precondition, checked first

The brief says to land after the budget arithmetic in
`docs/plans/2026-08-06-fill-budget-floor-finding.md`, because "structure plus
the 55 permille `FillFloorPermille` clamp already busts the 170 ceiling on its
own".

**That mechanism was measured and refuted before this work started.**
`docs/plans/2026-08-06-w0-rowcover-image-credit-finding.md` (branch
`maxwell/mapgen-w0-4team`, @ 239cb9c) instrumented the generator: on the rot90
path `structureCount` is 0, so the subtraction the clamp was supposed to be
repairing runs ZERO iterations and the clamp never fires — `budget=7058`
against `floorWouldBe=2773`, `budgetSkipped=0`. What was actually holding
cover at the ceiling was the row cover scanning a narrower band than the
validator reads and therefore never crediting the rows its own mirror images
had already blocked, which placed roughly twice the pickets needed.

That fix IS on `maxwell/mapgen-rebuild` and is now merged here. The headroom
the sequencing was waiting for exists, and it was measured on this tree before
a line was written:

| control (merge base, no clip) | valid | median cover | ceiling |
|---|---|---|---|
| 2-team, 100 seeds | 98/100 | 150 pm | 170 |
| 4-team, 32 seeds | 32/32 | 161 pm | 170 |

So the precondition is satisfied in substance, by a different fix than the one
named. `map_lanes.LaneTrimMinPx`'s comment, which repeated the refuted claim,
is corrected in the same commit.

## What landed

`clearLanes` trimmed rects and dropped polygons and diagonals whole;
`intrudesOnLane` tested those two kinds on their VERTICES ONLY.

- **Rings** are cut by integer Sutherland-Hodgman against the two horizontal
  half-planes of each lane's core. Integer vertices only, which `sim_types`
  states as a contract: both new vertices of a cut land on the SAME row, which
  is the parity-neutral arrangement `mapgen_vocab.wedgePolygon` documents at
  length, so the mirror image still rasterizes exactly. The vocabulary's rings
  are simple by construction (`ridgeHull` scans a profile rather than tracing a
  contour), and a ring that comes back over `MaxPolygonVerts` is dropped rather
  than shipped past the rasterizer's own contract.
- **Runs** are cut slab by slab along the run's DOMINANT axis, not by the
  45-degree interval subtraction the brief assumed. Desert dunes are emitted at
  an arbitrary `duneAngle`, so "y is monotone along the segment" is not a
  usable trim for a near-horizontal ridge; slabbing handles every angle with
  one rule and merges adjacent survivors back, so an untouched run re-emits
  with its original endpoints.
- **The intrusion test** now asks the same span question the rect branch asks,
  against the footprint `arena.inShape` really paints: a ring's exact vertex
  box, a capsule's segment box grown by its half width.

## Two traps

**1. The duplication trap** (called out in the brief, and real). Emitting both
halves of a shape the band never touched hands back two coincident copies, and
after three lanes eight. A pixel mask cannot see it. The fill BUDGET is spent
per shape, so the map would pay eight times for one mass and stop emitting long
before it was full. Guarded per lane, per piece.

**2. THE BAND IS NOT A SUPERSET OF THE CORE** — this one was not in the brief,
and it is the bigger bug. `clearLanes` short-circuited on `intrudesOnLane`,
which asks the design-width BAND, and passed anything that cleared it through
whole. But over a gate `laneCoreOver` takes the OPENING's own y span, and a
staggered opening need not lie inside the band at all. So cover was handed back
sitting in a gate mouth. Measured on the arena plan: **175 to 450 wall pixels
inside a protected core, per shape.** That hole was there for RECTS too, from
the day the rect trim landed (377070e8), and it is exactly the failure mode
0d3878f was written to close — closed on one path and left open on the other.

Every cut kind now goes through its trim, which asks `laneCoreOver` and so sees
the gates. A shape that touches no core re-emits byte-identical, so this is not
a licence to re-slab the world.

## Results

**Validity, `tools/gen_sweep.nim`, same binaries, explicit `--nimcache`:**

| | base | with the clip |
|---|---|---|
| 2-team, 100 seeds | 98/100, cover 150 pm, interior 0.260 | 98/100, cover 150 pm, interior 0.255 |
| 2-team, 200 seeds | 194/200, cover 153 pm, interior 0.271 | **195/200**, cover 153 pm, interior 0.271 |
| 4-team, 32 seeds | 32/32, 0.991 / 0.276 / 161 pm | **identical in every figure** |

**The 3-valid-seeds-in-100 cost the brief predicted does not appear.** At 200
seeds the clip is +1: the failing set is the same minus seed 1179, which the
clip RESCUES, and no seed is lost. Every remaining failure is `too clogged` at
both ends of its density sweep in both builds.

The 4-team column is a CONTROL, not a result: `archThreeLane` is 2-team only
(`map_archetypes.legalArchetypes`), so a rot90 board never runs `carveLanes`
and therefore never runs `clearLanes`. An unchanged path measuring unchanged is
what it should do. It also means the 2-team sweep is a DILUTED instrument —
one archetype in six carries this change, so ~17 seeds of 100 exercise it at
all. `tools/lane_clip_probe.nim` is the direct instrument.

**Fill survival through the clip, `tools/lane_clip_probe.nim`, seeds 1-6, as a
percentage of emitted area:**

| biome | base | with the clip |
|---|---|---|
| caves | 63 54 73 73 68 86 | identical |
| plains | 20 59 10 100 78 81 | identical |
| city | 20 19 17 18 19 19 | identical |
| forest | 56 94 60 100 67 50 | 56 94 **58** 100 67 50 |
| desert | 13 57 53 0 52 0 | **0 0 0 0 0 0** |

caves, plains and city emit no polygons and no diagonals, so they are a second
control and they are byte-identical.

The probe only feeds a BIOME in as cover, and no biome emits polygons — the
rings come from the vocabulary masses, which the probe does not run. So the
probe measures the diagonal half of this change only. For the polygon half, a
shape-kind census of the SHIPPING generator's own seed set (40 2-team seeds, 38
of which draw a valid map) attributes it directly:

| | rect | disc | diamond | diagonal | polygon |
|---|---|---|---|---|---|
| base | 1100 | 2811 | 159 | 25 | 165 |
| clip | 1096 | 2743 | 159 | 25 | **175** |

+10 rings that used to be dropped whole now survive as cut pieces; -4 rects,
which is the gate-mouth fix taking back cover that was sitting in an opening;
-68 discs, which is the fill BUDGET doing exactly the density regulation the
brief feared it would not — admitting ring area earlier in emission order means
fewer pebbles fit later. That is the regulator working, not validity paying.

**Desert is the diagonal story, and it is not the clip misfiring.** Every slab
of every dune on seed 2 is blocked, and the trace says by what:
`laneFlank` has `widthPx` 68 — EQUAL to `corridorMinPx`, so that lane has zero
slack and its whole band is protected core — and it carries FIVE staggered
gates, which zero the slack outright and stretch the core to the openings' own
y spans: 102 to 160 px tall. A dune is a 56 px capsule, 82 px tall per slab
counting its half width. It does not fit. Seed 2's first dune runs
(438,60)->(316,182), straight down that lane's throat; the old vertex test
cleared it because both ENDPOINTS sit outside the lane while the middle crosses
it, the textbook straddle. It was being shipped as a 56 px wall across a 68 px
corridor. One slab of the second dune does come back FREE and is dropped by the
stub rule (18 px of run against a 56 px thickness — the desert emitter refuses
runs that short when DRAWING them, for the same reason).

Rendered before/after and read by eye: the corridor that dune was lying across
opens from two ~46 px slots to one ~202 px run, the mirror is exact to the
pixel in both, and the cut leaves no sliver — zero surviving components under
one cell, and no 1 px runs anywhere.

**Tests:** 7 new in `tests/test_map_lanes.nim`, and the guarantee is checked in
PIXELS, not bounding boxes — nothing `clearLanes` hands back may paint a pixel
inside a lane's protected core, asked column by column. That assertion is what
caught trap 2; a bounding-box test would have passed. `shard_4` 399 OK / 0
FAILED, `shard_3` clean.

## Left standing, deliberately

**Desert fill does not fit this lane network, and that costs more than cover.**
Cutting it is correct, but a biome whose fill survives at 0% contributes
nothing but structure and pickets to a three-lane board. Rendered, desert loses
~25% of its stone, and worse, its two probe seeds converge: stone IoU between
seeds 2 and 3 goes 0.601 -> 0.962, because the dunes were carrying nearly all
of that biome's seed-to-seed variation. It reaches a shipping board only when
the fill draw is desert AND the archetype is three-lane, about 1 board in 30 at
2 teams, so it is not urgent — but it is the next thing to fix here, and the
fix is UPSTREAM of the clip: thin the ridge, or hand the lane plan to
`genDesertBiome` so a dune is drawn BETWEEN lanes instead of reconciled after
the fact.

**A lane with zero slack cannot carry any cover.** `laneFlank` is planned at
`widthPx == corridorMinPx`, so `laneCoreOver` has nothing to spend and protects
the entire band; five gates then widen the core past the lane itself. That is
what makes the flank uninhabitable for anything thicker than a pebble, and
`map_rules.MaxExposedRunPx` — no route may run 132 px without cover — says a
lane with no cover in it is wrong. The disc branch of `clearLanes` already
argues this in a comment. It is a lane-PLANNING question, not a clip question.

**The polygon cut is whole-ring, not slabbed.** A wide ring under a steeply
descending lane sees that lane's union band over its whole x range and can be
cut harder than it needs to be. Rects solve this by slabbing; slabbing a ring
means clipping against two more half-planes per slab and multiplying the shape
count, which trap 1 says the budget will feel. Measured on the vocabulary's
actual rings the whole-ring cut costs nothing worth that, so it is not done.
