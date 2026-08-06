# The 4-team raise was the row cover mis-measuring its own band

Measured 2026-08-06 on `maxwell/mapgen-w0-4team` @ 239cb9c, base
`maxwell/mapgen-rebuild` @ 154ecc7. This is the FOURTH standing diagnosis in
this rewrite to be overturned by measurement, after "the suite takes 50
minutes", "shapeRowSpan is the lane blocker", and
`2026-08-06-fill-budget-floor-finding.md`'s floor clamp.

Both previous diagnoses of THIS failure were wrong, and they were wrong the
same way: each reasoned about the geometry instead of rendering it. The task
brief says so explicitly and then does it again; so did I, twice, before the
render settled it. **Render first.**

## What was believed, and what is true

| | claim | status |
|---|---|---|
| task 157ce824 | sparse fills fail routing, dense fills clog, no window between | wrong — no attempt fails routing |
| finding doc @154ecc7 | structure subtraction drives the budget under `FillFloorPermille`, clamp fires every attempt | wrong — on rot90 `structureCount` is 0, the subtraction loop runs ZERO iterations and the clamp never fires |
| measured here | the row cover credits a narrower band than the validator reads, and places ~2x the pickets it needs | fix lands 65% -> 100% |

The floor clamp is real code and is left untouched. It simply is not on the
4-team path: `budget=7058` against `floorWouldBe=2773`, `budgetSkipped=0`.

## The three findings, in the order they were measured

**1. The terrain block emitted NOTHING on 4-team.** `xMin` is
`captureClear + 50`, an inset whose job is to hold terrain off the capture
COLUMN of a 2-team sides board. A rot90 board has no such column. Applied
anyway it left an emission region of 127x397 inside a 408x408 quadrant, and the
street grid — sized for a squarish region — then dropped every shape that
straddled a street, which in a 127px-wide region is all of them. Instrumented
(`-d:mapdbg`): `fill=34 streetDropped=34 survived=0`, on every attempt.

**2. So the whole board WAS the row cover.** On seed 1002, 51 of 53 authored
shapes were pickets, and the pickets alone measured 141 permille of a 178
total against a 170 ceiling. This is why sweeping the fill density 40%->140%
moved cover by 4 permille and why the finding doc's table is flat: the density
knob was not connected to anything. It also explains the render — empty city
blocks with a picket donut around the plaza — and interiorFrac 0.098.

**3. The row cover did not credit its own images.** It scanned
`ax .. min(sightlineHiX, center.x)`; the validator scans
`sightlineLoX .. sightlineHiX`, unclamped. A picket's rot180 image lands at
`x = W-1-x-PicketW`, i.e. x in [435,630] for the placement window — inside the
validator's band, outside the clamped one. So the pass never credited the row
its own image had already blocked, and placed roughly twice the pickets needed.
Seed 1002: 36 pickets / 188 permille -> 15 / 78, and the board validates.

## Results

Clean nimcaches throughout — see the hazard below.

| | before | after |
|---|---|---|
| 4-team valid, 32 seeds | 21/32 (65%) | **32/32 (100%)** |
| 4-team valid, 64 seeds | — | **64/64 (100%)** |
| 4-team median interiorFrac | 0.098 | **0.252** |
| 4-team median staticScore | 0.861 | **0.984** |
| 2-team valid, 40 seeds | 36/40 (90%) | **39/40 (97%)** |
| 2-team seeds LOST | — | **none** |
| 2-team seeds rescued | — | 1015, 1020, 1028 |

On the 36 seeds valid in BOTH builds: median staticScore 0.9719 -> 0.9732,
median interiorFrac 0.3097 -> 0.3033, and 18 of 36 byte-identical. The headline
2-team medians (0.315 -> 0.294) are mostly COMPOSITION: three rescued seeds
join the population and pull the median. `tools/w0_seeds.nim` exists to make
that distinction, because a median over "seeds that validated" is not a
like-for-like comparison when validity itself changed.

Seeds 1015 and 1020 are task fcd2e04d's two failing small 2-team boards. The
finding doc's guess that the two regimes shared one root cause was right; the
root cause was not the one it named.

## Tried and MEASURED WORSE — do not repeat

- **Dense-first density sweep** (so the first validating attempt is the densest
  that fits): 2-team interiorFrac 0.301 -> 0.272, 4-team unmoved. `attempt`
  also drives size, layout and endzone, so reversing the density order changes
  WHICH board wins, not how full one board is.
- **Scoping the band fix to rot90**: 2-team 87% -> 80%. The wider band helps
  mirror boards too; it is a correctness fix, not a 4-team special case.
- The picket-spread cursor IS scoped to rot90, and that is measured: it fixes a
  four-fold-lift pathology, and unscoped it cost 2-team 90% -> 80% and
  interiorFrac 0.315 -> 0.272.

## MEASUREMENT HAZARD — stale nimcache

Two builds of identical source returned DIFFERENT maps for the same seed (52
shapes / 178pm vs 44 / 255pm). It was a stale `~/.cache/nim` entry left by an
earlier session's build of the same tool name against a different `arena.nim`.
Run-to-run was perfectly deterministic, so this does NOT look like flakiness —
it looks like a real effect, and it will silently corrupt any A/B.

**Pass an explicit `--nimcache:` to every measurement build.** Every number in
this document was produced that way.

## Left for Lane B

The full suite was run on BOTH builds, so this is a set difference and not two
counts taken against different trees:

```
baseline @154ecc7   697 OK / 37 FAILED
after    @239cb9c   729 OK /  5 FAILED
  fixed by this change   32
  newly broken            0
  still failing           5   (every one of them already red at baseline)
```

The 32 are the 4-team raise cascade clearing as a group, exactly as the task
predicted — `4-team maps are exactly rot90-fair and deterministic`, `seats deal
round all four teams`, `all four flags start home on their own pedestals`,
`plus layout anchors the four teams on the four arms`, and the rest.

The five survivors PRE-DATE this change; none is a regression from it:

1. `generated-map validation matches the pre-refactor baseline`
2. `shared pool rendering matches the pre-extraction images`
3. `mapPits locks an exact total; odd counts anchor the map center`
4. `mapPitDensity scales the density draw`
5. `the curated pool sits below the hand-authored control`

1-4 are seed-pinned goldens (task a994bbcb). Their diagnosis did move with this
change even though their red/green state did not: (1) now also trips an
IndexDefect because its hard-picked diagnostic seed (2,1020) is one of the
three this fix RESCUED, so `openSightlineRows` comes back empty; (3) seed 1002
now seats 8 pits rather than 12. The pit MECHANISM is intact — `generated maps
dig walkable, team-symmetric trenches` was red at baseline and is now GREEN.

5 is semantic, not churn: a generated pool map now TIES the hand-authored
control at staticScore 1.0, so `best < control` cannot hold (task 05b1d7cd).

The remaining quality gap is visible in the contact sheet: a diagonal "barcode"
motif from the row-cover staircase is still the most legible texture on many
4-team boards, and interiorFrac 0.224-0.252 is short of the control's 0.342.
That is architecture work, not validity work.
