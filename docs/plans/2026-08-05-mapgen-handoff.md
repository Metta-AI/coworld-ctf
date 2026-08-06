# Map generator work — handoff

_2026-08-05. Everything below is on branch `maxwell/mapgen-rebuild` in the worktree
`~/projects/coworld-ctf-mapgen`, unless stated otherwise._

---

## Start here

1. **`docs/plans/2026-08-05-generator-rewrite-brief.md`** — the spec for the work that
   remains. Read it completely.
2. **`docs/plans/2026-08-05-mapgen-rebuild-plan.md`** — the ranked ordering and the
   decisions behind it.
3. **`docs/research/*.md`** — 7,580 lines across five surveys. Reference, not required
   reading, but every non-obvious claim in the brief traces back to one of them.

Then run this and look at the output, because it is the whole problem in one picture:

```
nim c -d:release -o:/tmp/map_sheet.out tools/map_sheet.nim
/tmp/map_sheet.out 50 /tmp/sheet2.png        # 2-team
/tmp/map_sheet.out 30 /tmp/sheet4.png 4      # 4-team
```

---

## The honest state

**Fifty generated maps are still one map.** The board sheet shows a vertical column lattice
mirrored left-right (2-team) or a pinwheel of radial arms (4-team). The rubric scores that
at mean 0.939 and is content; the eye needs two seconds.

**The reason is not subtle and it is the most important thing on this page:**

```
arena.nim references mapgen_biomes: 0
arena.nim references mapgen_vocab:  0
arena.nim references map_lanes:     0
arena.nim references mapgen_graph:  0
arena.nim references burrow:        0
```

A shape vocabulary, five biome algorithms, lane carving with a Menger certificate and a
scene-graph prototype were all built, tested and measured — and **the shipping generator
calls none of them.** Each is imported only by its own test and a probe tool. Nothing a
player can see has changed. **Wiring that up is the first task of the next epic and the
only one that matters until it is done.**

---

## Update, later on 2026-08-05: the wiring is now de-risked and unblocked

Three things changed since the above was written. The headline — the shipping
generator still calls none of these modules — is UNCHANGED.

**1. The lane blocker is fixed** (task `76332cf1`, commit `aae19bd`). The
standing diagnosis was that `shapeRowSpan` over-claims for "some shape kind".
It does not. `tools/lane_openrow_probe.nim` classifies every pixel of every
surviving open row and reported `carved=0 empty=806` on all of them: the cover
never arrived at all. The failure was also bigger than filed — 18-23 open rows
on 3 of 3 seeds, in contiguous BANDS. Cause: every gate was centred on its
lane's centreline, so a lane's openings all overlapped there and the centre
rows threaded every one of them; and the fast lane had NO gates while the mid
lane had one. **One gate cannot break its own lane.** Openings now alternate
between the lane's two edges, every lane gets at least two, and the opening is
clamped to `gw < W/2` — exactly when two openings at `+-(W-gw)/2` are disjoint.
Open rows: **0 on 6 of 6 seeds**. The fast lane is no longer gate-free, which
is a deliberate character change.

**2. The architecture is measured, not assumed.** Neither layer stands alone:

| composition | valid | note |
|---|---|---|
| biome fill ALONE (`biomekit table`) | **0/6 on every one of the five** | every failure an open sightline; openP95 639-1215px; interiorFrac 0.046-0.138 vs control 0.342 |
| lanes ALONE | valid | structure-only cover 120-126 permille, 44-50 permille of headroom under the 170 ceiling |
| **lanes + biome fill** | **29/30** (5 biomes x 6 seeds) | 0 open rows throughout, cover 120-163 permille |

The lone failure is desert seed 2 at 172 permille — a budget to reconcile, not
a structural defect. The seam already exists: `carveLanes(..., cover)` hands
the fill through `clearLanes`. **This is the strongest evidence yet that
"skeleton first, fill second" is right, and it is now a measurement rather
than a design argument.**

**3. Organic AND asymmetric AND fair is not a contradiction, and the rule is
one line:** fairness is enforced by the LIFT, not by the shapes. Generate in
the fundamental domain, lift by the orbit, and any amount of noise, dither or
irregularity inside that domain is free — it lifts to an exactly fair board.
What breaks fairness is noise applied AFTER the lift, which is why
`ditherEdges` is symmetry-destroying by construction and REQUIRES a
`fundamentalDomain`. Keep noise a TEXTURE layer downstream of structure (§8 of
the brief: thresholded noise cannot make rooms at any threshold our cover cap
allows); marching squares into `shapePolygon` is the sanctioned route.

⚠️ **One defect found while measuring, filed as `8bc05407`:** `clearLanes`
clips the ENTIRE city biome away — its cover contribution is zero on 5 of 6
seeds, while caves/forest contribute 16-42 permille. It almost certainly
REJECTS long axis-aligned blocks whole instead of trimming them. City is the
closest thing we have to the brief's "blocks" archetype, so this silently
collapses the fill vocabulary to pebble-shaped biomes.

---

## What DID land, and is real

| module | what it gives you |
|---|---|
| `src/ctf/map_metrics.nim` | ~45 metrics, `evaluateMap`, `staticScore` -> [0,1], bands each carrying the arena control's value |
| `src/ctf/map_rules.nim` | per-visibility-regime targets + the population resolver (size from the roster) |
| `src/ctf/map_seed.nim` | one derived RNG substream per NAMED scene; a new scene disturbs no existing stream |
| `src/ctf/map_lanes.nim` | k-fold disjoint burrow **with a Menger certificate** (route count guaranteed, 3/3 seeds) + the length-aware corridor/chokepoint predicate |
| `src/ctf/mapgen_vocab.nim` | 8 organic constructors, sizing derived from `map_rules`, ranked by enclosure per unit cover |
| `src/ctf/mapgen_biomes.nim` | 5 ported Cogs-vs-Clips terrains + shared dither + edge mask |
| `src/ctf/mapgen_graph.nim` | scene-graph prototype, `interiorFrac` 0.345 vs the control's 0.342 |
| `src/ctf/burrow.nim`, `hex.nim` | connectivity repair (Dial's, zero RNG); cube coords + D6 symmetry |
| `arena.selectBestMap` | generator-AGNOSTIC best-of-K — takes a candidate callback, drives any generator |
| biome art | `MapBiome` on `CtfMap`, per-biome floors behind a named error, 5 committed textures, spec round-trip |
| **GV38** | grenade + shout pinned to `GunRange div 4` = 262px on every board |
| tooling | `map_sheet`, `mapgen_defect_probe`, `mapgen_defect_render`, `map_eval`, `biomekit`, `vocab_bench`, `lane_probe`, `mask_parity_probe`, `gen_validation_baseline` |

Measured improvements that ARE in the shipping path: best-of-K selection (median
`staticScore` 0.840 -> 0.901 over 150 held-out seeds, 123 improved / 27 unchanged / **0
regressed**) and population-driven sizing.

---

## Three shipped fairness bugs — all found by measurement, none by code review

Each was hidden behind a test that looked green.

1. **`pointInPolygon` strict straddle** — a vertex whose neighbours straddle its scan row had
   BOTH edges skipped, inverting row parity, so **the two teams got different walls**.
   Measured 8,770 asymmetric wall px (19%) on the shipped `caves` style. Live since GV37.
   **FIXED** (needed two changes, half-open y plus explicit on-boundary; the test that let it
   ship sampled every 9th pixel and now sweeps every pixel).
2. **Anchor seam off-by-one** — anchors placed at `width - x` while shapes mirror at
   `width - 1 - x`, so `mapProtectedFloorAt` contradicts itself over 522px per standard
   board. Any obstacle on a spawn-pocket edge is stone for one team and floor for the other.
   **DIAGNOSED, fix written into `axisHomeHi`'s doc comment, NOT applied** — it moves a spawn
   by one pixel, which is a sim change breaking 22 tests including replay hashes. Needs a
   GameVersion bump. Task `a3fca5b0`.
3. **Even-sided boards** — protected geometry anchors on `size div 2`, whose mirror differs by
   one when the side is even. Proven independent of #2 by exact parity correlation.
   **DIAGNOSED, not fixed.** Task `0fe60f8f`.

**Recommendation: fix #2 and #3 together in one GV39 + one fixture re-record.** A branch
`maxwell/mapgen-gv39-fairness` has 5 commits of in-flight work on exactly this; it is
UNMERGED and incomplete (the agent was stopped by a usage limit mid-bump). Either finish it
or restart from the diagnoses, but do not merge it half-done.

---

## Numbers that are not what you would assume

- **`GunRange = 1050` is a REACH, not an engagement range.** 32 aim slots, no aim assist, and
  the gun samples the 13px SOLID body. `R_slot = 14/tan(5.625deg) = 142px`; P(hit) is 0.47 at
  300px and **0.14 at "gun range"**. Three constants converge on ~260px. **Any density or
  encounter law on gun or vision range is overstated 12-16x.**
- **Movement is L-infinity, not Euclidean** — 41% heading anisotropy, isometry group D4. So
  3- and 6-team maps carry an irreducible **15.5% travel-speed penalty for one team in
  three**. No board shape fixes it; it is a game-design decision.
- **Stated rules diverged from enforced ones**: design intends >=3 vertex-disjoint routes,
  the band enforces **>= 2**. Stand-side cover has **no absolute floor**, only a fairness
  SPREAD — and a spread cannot express a floor, so two equally naked stands both pass. That
  is the one causally-established property in the suite going unenforced.
- **The metrics have known blind spots** (task `846fb654`): the hard validator scans
  horizontal rows ONLY, so a diagonal sightline of any length is invisible — and the longest
  open line on our own control turns out to BE diagonal (arena-large 1185px, longer than a
  gun range). Chokepoint detection has no pinch length. The isovist cut is 4x too wide.

---

## The trap, stated once more because it is the easiest thing to get wrong

**The rubric and the eye disagree, and right now the eye is right.** Measured twice,
independently, by different agents: the shape item scoring BEST per unit cover renders as a
**barcode**; second-best as **confetti**; a crude random mix scored mid-table and was the
best-looking map produced. A fix that "improved every metric" made maps look worse.

`tools/map_sheet.nim` prints the score beside the picture for exactly this reason. **If the
generator scores well and the sheet looks like wallpaper, it optimised the metric and lost
the game.**

Also live: `staticScore` is a hand-written surrogate for play quality that **has never been
validated against actual play** (task `145f1af0`). That experiment is time-sensitive — it
needs the OLD generator's 0.717-0.932 score spread to compute a correlation, and a
saturating new generator destroys the measuring instrument.

---

## Branches and worktrees

**Integration: `maxwell/mapgen-rebuild`** — everything merged, tree clean, suite green.

Merged and safe to delete: `mapgen-fitness`, `mapgen-sizeclass`, `mapgen-biome-art`,
`mapgen-bestofk`, `mapgen-lanes`, `mapgen-shape-vocab`, `mapgen-biome-algos`,
`mapgen-design`, `mapgen-audit`, `mapgen-range-pin`, and all five `mapgen-research-*`.

**UNMERGED, deliberately:**
- `maxwell/mapgen-gv39-fairness` — 5 commits, incomplete GameVersion bump (see above)
- `maxwell/mapgen-rewrite` — 1 WIP commit; the rewrite was redirected mid-flight from a
  parallel track to wiring the shipping generator, so start it from the brief rather than
  from that commit

Worktrees live under `~/projects/coworld-ctf-*`. Each needs `nim.cfg` copied in — it is
untracked and builds fail without it.

---

## Working rules that were learned expensively

- `nim c -d:release -r tests/tests.nim` from the worktree root. **ALWAYS `-d:release`** —
  debug is 10-50x slower through per-pixel map code. The suite is **7.1 minutes** (425 s,
  734 tests) end to end, and the CI number is the slowest SHARD, ~3 minutes.
  ⚠️ **This machine's wall-clock timings are worthless under fleet load.** The "~50 minutes"
  that task `31d2bec3` was filed on is not reproducible: measured back to back, an UNCHANGED
  shard drifted +10.4% in CPU time and 2.1x in wall clock purely from other agents running.
  Measure CPU time (`/usr/bin/time -p`, user+sys), and re-measure a control you did not
  change in the same batch — otherwise you will attribute the fleet to your own change.
- The K=8-on-giant-boards diagnosis in that task was **wrong on both halves** and is worth
  knowing about, because it is the shape of mistake this codebase invites: the pool holds NO
  giant boards (the population resolver moved 2-team pool generation to {small, standard}),
  and a full 20-map pool sweep is 23.3 s, so the three sweeps could not have been 50 minutes
  of anything. `tests/timing_formatter.nim` + `tests/timed_shard_N.nim` answer "what is
  actually slow" directly — use them before optimising. What they found was one duplicate
  full-pool sweep in each slow shard, now shared through `helpers.cachedCtfMap`.
- **Commit every green increment.** The machine sleeps without warning and usage limits hit
  mid-task. Several agents lost hours today; the ones that committed incrementally lost
  seconds. `git stash create` does NOT capture untracked files, so bank with a real commit.
- Run the hand-authored `arena` as CONTROL in every batch. A metric that flags your control
  is wrong; one that skips it is worse. Both happened.
- Never report a count without its fraction. Merge >= 3 seeds before judging. A capture ENDS
  the episode, so episode length is itself an outcome.
- You may freely break seed->map identity. You may **not** break spec->map identity —
  replays pin `mapSpec`.
- AGENTS.md requires `docs/pool-review.html` to ship with any pool/generator change. There is
  a baseline regenerator now: `tools/gen_validation_baseline.nim`.
