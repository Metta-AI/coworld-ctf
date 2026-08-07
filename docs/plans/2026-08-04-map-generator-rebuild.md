# Map Generator Rebuild — Plan

> **SUPERSEDED IN PART, and kept because `map_score.nim` and `burrow.nim` cite
> its section numbers as the design authority.** Written before the hexagon
> landed. The best-of-K ranker, the named RNG sub-streams and the
> metrics/score split all shipped as described; the board it fills is now a
> hexagon and the generator is 2-team only. See `docs/HEX_BLAST_RADIUS.md`.


**Status:** proposed, 2026-08-04
**Goal:** an infinite supply of genuinely GOOD competitive maps — maps that look
good, feel good, and play well (fair fights, decisive winners, even chances) — at
every size class, for 2/3/4/6-team modes, with biomes.
**Companion plan:** `2026-08-04-hex-arena-conversion.md`. The generator targets
hex geometry; the coordinate kernel (`src/ctf/hex.nim`) is a shared dependency.

---

## 0. Why the current generator produces mediocre maps

Measured, not asserted. From `tests/fixtures/map-validation-baseline.tsv` (402
checked-in cases, seeds 1000–1200):

```
teams=2: 193/201 = 96.0% first-attempt pass
teams=4: 112/201 = 55.7% first-attempt pass
failures: 81 open horizontal sightline, 12 no-route-to-center, 3 too clogged
```

**At 96% pass, the validators are not selecting anything.** They are a crash
guard, not a quality filter. `AGENTS.md` states the philosophy outright —
*"anything that passes is fair game."* That is precisely the problem: the
validators encode "not broken", never "good".

Seven more specific defects:

1. **There is one structure, and it is a picket fence.** Every 2-team map is N
   evenly-spaced vertical columns of periodic blobs at
   `colX = xMin + ((2·col+1)·(xMax−xMin)) div (2·columns)` — uniform, never
   jittered. The four "column families" (`colStubs/colDiamonds/colDiscs/
   colChevrons`) are four *skins on the same slot*. This is re-rolled column
   noise, not structural variety.
2. **No lane, room, chokepoint, power position, or flow concept exists in the
   code.** Grep confirms it. The generator has no idea where a fight would
   happen. `defaultCtfRooms` is HUD label rectangles, not authored rooms.
3. **Nothing is scored.** `validateGeneratedMap` returns a string; empty ships.
   There is no fitness, no ranking, no comparison between two valid maps.
4. **Cover has no spatial intent.** Cover is one scalar, `coverPermille` in a
   40–170 band over the whole interior. A map with all its cover in one corner
   and an empty midfield scores identically to a well-distributed one.
5. **The sightline-repair pass is the generator fighting its own validator.** It
   drops r28 diamonds at random column x's until every 4px row is blocked. The
   shipping commit is candid: without it *"mirror-symmetric maps almost never
   survive (the first pool scan came out 100% rot180)"*. `mapgen_styles`'
   `verticalAnchors` is the same hack, duplicated into all four "different"
   styles — they all wear the same prosthetic spine.
6. **Only *horizontal* sightlines are checked, on a 4px grid, as a binary.** A
   clean diagonal or vertical spawn-to-spawn lane passes. A 400px lane and a 40px
   lane are both "blocked".
7. **Nothing scales structurally with size.** `scaledGenShell` says it: *"Obstacle
   SIZES never scale."* A giant 3211×1713 board is the standard map photocopied at
   260% — same 28px pebbles, more of them, further apart.

And: **"the curated pool" was never curated.** `gen_map_pool.nim` = "the first 20
seeds that don't fail a validator, subject to a size/shape quota." No human
picked a map; no map was ranked, compared, or playtested.

---

## 1. The single highest-impact change

**Rank candidates. Stop accepting the first valid one.**

`generateCtfMap` returns the first of up to 100 attempts that passes — i.e. a
uniformly random valid map, **the 50th percentile of the generator's own quality
range**. Collecting K valid candidates and shipping the best lifts that to the
K/(K+1) percentile:

| K | attempts (at ~60% pass) | percentile |
|---|---|---|
| 8 | ~13 | 89th |
| 32 | ~53 | 97th |

At ~10–30 ms per standard-size generation+validation (measured: the editor's full
`POST /api/map` round trip including PNG encode is 49 ms at standard, 226 ms at
giant), K=32 costs about a second. **This requires no new geometry — only a
scalar score.** Everything else in this plan exists to make that score good.

---

## 2. Architecture

### 2.1 Sub-streams, not one flat RNG stream

Today the generator has **one flat splitmix64 stream**, so inserting a draw at
position *k* re-deals every map from every seed, re-curates the pool, and moves
every regression baseline. The existing escape hatch (`seed xor const` for the
endzone archetype) is the right idea used once; it is what let compact endzones
ship with 29/29 column maps byte-identical and **no GameVersion bump**.

**Make it structural: one derived stream per stage** — `hash(seed, "layout")`,
`hash(seed, "terrain")`, `hash(seed, "cover")`, `hash(seed, "pickups")`,
`hash(seed, "biome")`, `hash(seed, "decor")`. Then any stage can gain draws
without disturbing the others. This is the difference between "adding an
archetype re-curates the pool" and "adding an archetype is a local change".

Adopt Cogs-vs-Clips' scene-graph RNG discipline wholesale: one root seed, every
stage gets an independently *spawned* child generator, any stage individually
pinnable. Plus their **two-seed split**: `--map-seed` = layout, `--seed` =
sim/policy RNG.

Safety net already exists: replays pin `mapSpec` and playback never re-runs the
generator. **You are free to break seed→map identity; you are not free to break
spec→map identity.**

### 2.2 Generate in the fundamental domain, then lift

Non-negotiable for exact fairness. Generate terrain in one wedge (1/2, 1/3, 1/4
or 1/6 of the hex depending on mode), then apply the symmetry orbit in **cube
coordinates**. Never repair the assembled map — a repair pass run globally is the
classic cause of a fairness metric drifting off 1.000.

The ordering problem this creates is real and Cogs-vs-Clips does **not** solve
it: their `MakeConnected` is inherently global and asymmetric (it picks *the*
largest component and `argmin`s a single cheapest cell), and naively mirroring
after burrowing gives symmetric geometry with asymmetric tunnels.

**Resolution: carve a G-invariant central hub first and pin it.** Then the
connectivity proof reduces to a local check: *if the wedge's open space is
connected and touches the hub, the whole lifted map is connected.* An O(|F|)
check instead of a global flood. Size the hub at **r ≈ 0.4–0.7 R** so crossing it
exposes you for roughly one gun range — which also gives CTF/FFA the contested
midfield it wants, and solves the C6 fixed-centre-cell problem.

### 2.3 Pipeline

Adapted from the Cogs-vs-Clips scene graph, with fairness inserted:

| # | Stage | Guarantees |
|---|---|---|
| 0 | Root seed → per-stage sub-streams | full determinism from one int |
| 1 | Size class + team count → hex shell | aspect ∈ [0.866,1.155]; hex boundary ring |
| 2 | **G-invariant hub** carved and pinned | the connectivity anchor |
| 3 | Base biome over the **wedge** | terrain shell |
| 4 | Biome overlay zones (BSP partition, ~60% fill) | ≤ `max_zone_fraction` each |
| 5 | Structure pass (lanes/rooms/chokepoints — §4) | the actual map design |
| 6 | **Burrow** (§3) *inside the wedge* | wedge open space is one component |
| 7 | **Lift by symmetry orbit** in cube coords | exact fairness by construction |
| 8 | Pickup + spawn placement (§5) | safe/contested split, Poisson-separated |
| 9 | Hex silhouette / edge erosion | non-rectangular, readable boundary |
| 10 | Hard gates → static score → rank (§6) | ship the best of K |

Stage 9's model is Cogs-vs-Clips' `AsteroidMask`, which cuts inward-tapering
triangles from anchors along each edge. **Replace "four edges" with "six" and you
get a ragged hex silhouette for free.** It is size-conditional there
(auto-enabled at `min(w,h) ≥ 80`) — a good precedent for our size-class rules.

---

## 3. The burrow tool

Ported from `mettagrid/mapgen/scenes/make_connected.py`. This is the single most
valuable algorithm found in the research, and it is ~170 lines.

**What it does:** guarantees the map's open space is exactly one connected
component by digging the *cheapest possible* tunnels — preferring to route
through existing corridors, punching walls only at their thinnest points, and
destroying placed objects only as a last resort.

**Cost model — the entire tuning surface, and it is well-chosen:**
```
WALL_COST_RATIO   = 10   # walking 10 open cells == digging through 1 wall
OBJECT_COST_RATIO = 50   # removing 1 object == digging through 5 walls
```
The *ratio* is all that matters: `reuse corridors ≫ dig rock ≫ bulldoze content`.

**Algorithm:** label components → pick the largest as the anchor → one multi-source
weighted BFS via **Dial's algorithm** (J+1 = 51 circular FIFO buckets, since with
integer weights bounded by J a monotone Dijkstra frontier spans at most J+1 cost
values) computing min-cost-to-anchor + a predecessor pointer for every cell in
`O(n·J)` with no heap → for each orphan component take `argmin` of the cost over
the *whole component* (this is what produces "punch through at the thinnest
section") → walk predecessors back, digging → **assert exactly one component**.

**Deterministic: there is no RNG in it at all.**

**Five things that must change for our engine:**

1. **Width-1 corridors are useless to us.** Dig with a brush radius ≥ agent
   radius + margin. Target ≥ `MinCorridorWidth`; see §4 rule 5 on raising it.
2. **It silently deletes buildings.** `_dig_path` overwrites any non-empty cell.
   Nothing logs it. Add an audit.
3. **Run it inside the fundamental domain**, before the symmetry lift (§2.2).
4. Component labelling only sees literal `"empty"`; a region whose only floor is
   an object tile is invisible to it. Define our passable set explicitly.
5. Their only recovery is a bare `assert`. We need reject-and-reroll instead —
   we have a 100-attempt budget and now a ranking loop.

Also worth porting: `EnsureHubReachableJunction`, their second narrower repair
pass, which guarantees a contestable objective within a distance band of each
hub (`min_distance=4` prevents gluing it to the hub wall and trivializing the
objective). ⚠️ It **silently no-ops** if impossible — make ours reject.

---

## 3.5 Measured: on a hexagon the binding constraint is CONNECTIVITY, not lanes

**Finding, 2026-08-05.** Re-curating the pool after the hex conversion scanned 68
seeds and rejected 6. Of those 6: **five were `no 26px route to the center`**, one
was the cover budget, and **not one was an open sightline on any of the three hex
axes.**

That inverts the pre-hex picture. On the square generator, **81 of 97** recorded
failures were open *horizontal* sightlines — lanes were the binding constraint,
and the generator carried an entire sightline-repair pass (dropping r28 diamonds
at random column x's until every 4px row was blocked) whose only job was to
appease that validator. `mapgen_styles`' `verticalAnchors` was the same hack
duplicated into all four styles.

On a hexagon that pressure appears to lift, and connectivity through the hull
takes its place.

**Caveats — this is a strong hint, not a settled result.** One scan; an *adapted*
generator that was deliberately not rebuilt; 2-team only; and the hull-void
corners are a large new source of unreachable area that a rebuilt generator may
stop producing.

**Why it matters before §4 is built.** The structure pass below is scoped
substantially around lane and sightline control — max open run, vertex-disjoint
routes, chokepoint isovists. Those remain right as *quality* targets. But if the
measured *failure* mode is connectivity, then the cheap accept/reject gate and
the expensive scoring layer are pulling on different ropes, and the pass should
lead with reachability rather than treat it as a late validator.

It is also the first field evidence bearing on §2.2's proposal to **carve a
G-invariant central hub first and pin it**, under which connectivity reduces to a
local check on the wedge. The open question, worth one cheap probe before
designing: of those `no route to the center` rejections, does the break sit at
the **hull edge** (terrain crowding the six boundary faces) or in the
**interior**? Edge → the fix is a boundary apron. Interior → the hub-first carve
is the right shape.

### 3.5.1 SUPERSEDED — the connectivity failures were a bug, and the real constraint is the cover budget

**Correction, later on 2026-08-05.** §3.5's reading did not survive Stage 2, and it
is worth recording *why* rather than deleting it.

Those `no route to the center` rejections were **not a property of hexagons**. The
sightline-repair pass was converging its plugs into a **ring that sealed the
core**: 19 of 19 connectivity rejections had 95–98% of the floor reachable with
only the centre cut off. With plugs scattered instead, **connectivity rejections
are zero**.

The measured steady state, over 400 seeds at **79.5% raw pass**: **74 too clogged,
7 open sightline, 1 endzone gate, 0 connectivity.** The binding constraint is the
**cover budget** — three axes of lane-blocking collide with a `CoverPermilleMax`
calibrated for *one*, so "too clogged" is ~90% of rejections.

**That is a design input for §4, not a tuning knob.** The cover band was derived
on a board with one lane family; a hexagon has three, so blocking them all
necessarily spends more wall. Re-derive the band from the hex lane geometry rather
than raising the ceiling until maps pass.

**And the tuning trap, stated because it was declined once already.** Raising the
lane threshold from 80% to 90% of board width lifts the pass rate to 93% — but a
chord at 87% of the standard board is **843px, inside the 1050px gun range**, i.e.
a real firing lane. That buys the number by excusing exactly what the rule exists
to refuse. Any future pass-rate improvement should be checked against this: does
it remove the defect, or redefine it away?

**The methodological lesson is the durable part.** A failure distribution measured
on a pipeline that still contains a bug describes the bug, not the domain. §3.5
was hedged as "one scan, adapted generator, 2-team only" and those hedges were the
right ones — but the hedge that would actually have caught it is *"and the
pipeline is not yet known-good."*

## 4. What the generator must actually build

The MW2 study is the calibration source. Every number below is measured, with the
default `arena` as the control.

**The conversion invariant — the single biggest finding.** Afghan and Scrapyard
both had *a flag stand standing in the open*: **6–7%** and **9–12%** of ground
within 200px of the pedestal was cover, against **10–25% on every map that
converted**. Neither ever scored — Afghan 0-of-21 then 0-of-17, Scrapyard 0-of-10.
After the fix, Scrapyard went **18 steals → 6 captures with every episode ending
in a capture**.
→ **Rule: 10–25% wall fraction within 200px of each pedestal.**

**Complementary:** the stand *ring* itself must be 70–90% open at
r ≈ captureRadius+30, with |red−blue| < 0.25. Open at the stand, cover in the
approach annulus.

**Spawn placement.** Respawn waves must not land inside the capture circle. The
first Rust field test converted **0 of 22** because both spawn zones were centred
on their stands, so every wave materialised inside the circle the carrier was
running toward. Terminal hit it again at 47px.
→ **Rule: `dist(nearest spawn-zone point, home) > captureRadius + 6`; prefer 70–380px.**

**Midfield crossings, not openness.** The control divides a 73%-open midfield into
**5 distinct ways across**. Favela measured 73% open in **one 486px span** and
played as a corridor.
→ **Rule: ≥3 distinct midfield gaps, each ≥30px — and always report the fraction beside the count.**

**Interior / enclosure.** The architecture-vs-scatter discriminator: floor with
≥6 of 8 directions blocked within 120px. Control (honest scatter) = **33%**;
shipped pack = **39–61%**.
→ **Rule: interior fraction clearly above 33%.**

**Cover budget.** MW2 reference plates measure ~54% open playable space, ~28%
structure. Brief target **18–30% wall coverage**; above ~35% it stops being a
field and becomes a maze. ⚠️ **Our current `CoverPermilleMin/Max` is 40–170 =
4–17%, well below that band.** Decide this explicitly.

**Lane widths.** 60–110px lanes (player is 13px solid / 34px drawn); chokepoints
narrow to 30–45px, tight but never impassable.

**Shape vocabulary.** *"No more than half your shapes should be plain
rectangles."* Doritos, cans, snakes, beams/wedges (*"these do the most work
visually"*), temples, and **bunker clusters — 2–3 shapes of different kinds
grouped with a gap.** Organic terrain via massifs: a chain of discs of varying
radius walked along a jittered spine, unioned into a lumpy mass whose outline
never repeats; two near-parallel spines with a gap = a cave.

**Trenches are our verticality substitute** (fast in / slow out, 1/3 fire rate,
70% of shots fly over). Budget **3–8 per map**; place at exposed crossings, at
chokepoints you want contested slowly, and one or two near a pedestal approach.
*"Punctuation, not paving."* Currently they're parasitic on column slots and
**disabled entirely on 4-team maps.**

**From the external research, the structural rules the generator lacks:**

- **Cap the maximum unbroken open run at ~125px.** TTK is 1.0–1.9s at 66px/s, so
  lethal exposure distance is 66–125px. The hand-tuned arena's in-column vertical
  period is 88–120px — *it already satisfies this*. Compute as P95 of the distance
  transform over walkable cells.
- **Require ≥3 vertex-disjoint routes between every base pair.** Split each cell
  into in/out nodes with capacity 1, unit-capacity max-flow. Flow = independent
  flank routes; min-cut × cell size = the tightest bottleneck in px. **k=1 is a
  fatal CTF map.** This is the three-lane doctrine made computable.
- **Assert no single point covers all chokepoints.** Chokepoints = distance-
  transform local minima on the medial axis that are genuine cut vertices; then
  verify no cell's range-capped (1050px) isovist contains all of them.
- **Model where the fight will happen and put cover there.** The "collision
  point" = the equidistant frontier of a multi-source BFS from all N bases.
  Assert cover density and route count are *above* map average there. The
  documented failure this catches is a map whose collision point lands in a
  cover-free area.
- **Split parameters by visibility regime.** small/standard/large are
  occlusion-limited (an unoccluded cone covers 1.9–4.4× the whole map); giant is
  mixed; colossal is range-limited (12%). One parameter set cannot serve both: on
  small maps sightline control is 100% of the design, on colossal it is encounter
  *density*. **This is the answer to "different sizes need different rules."**
  (Note `GrenadeMaxRange = MapWidth/5` scales with the map while `gunRange` does
  not — on colossal the grenade out-ranges the gun.)
- **Raise `MinCorridorWidth` toward 68px or justify 26px.** Two drawn cog bodies
  abreast need 2×34 = 68px; Source's published minimum hallway is 64u ≈ 68px. Our
  26px clears the 12px solid footprint but not the 34px silhouette, so two cogs
  in a corridor visually overlap. Our column *spacing* of 72px already matches
  the rule; the corridor minimum doesn't.
- **Place spawns by graph heuristic.** *"Central hubs and dead ends are a bad
  choice; rooms with 2 or 3 exits are usually best."* Validated at +26%
  time-to-find, +21% distance covered vs uniform (n=27, p=0.002).
- **Place pickups half-safe/half-contested:** maximise `1 − |2·(P_safe/P) − 1|`.

---

## 5. Biomes

Two independent systems studied; take the *layering discipline* from
Cogs-vs-Clips and the *look* from Muster.

**Cogs-vs-Clips biomes are additive wall-writers**, not exclusive terrains, and
selection is a **BSP partition + weighted random pick** with `~60%` of zones
filled — so ~40% stay bare base biome. *That stochastic partial coverage is the
"blending"*; there is no noise blend or Voronoi. Each zone is then shrunk to a
centered sub-rect (`BoundedLayout`) and the gap is the soft seam. Zone count is
`O(area)`, clamped [3,48].

The five biomes, with direct transferability notes:

| biome | algorithm | maps onto our primitives |
|---|---|---|
| `caves` | cellular automata (fill 0.4, 3 steps, birth 5 / death 3) | discs; densest — use as a *base*, weighted 0 as an overlay |
| `forest` | seeded clumpy monotone growth (seed 0.03, growth 0.5) | scattered discs; sparsest |
| `desert` | rotated striated dunes: `(x·cosθ + y·sinθ) mod period < width` | **`shapeDiagonal` almost 1:1** — a pure analytic field |
| `city` | jittered rect blocks on a `pitch` lattice + forced road stripes | oriented bars; the only biome guaranteeing baseline connectivity |
| `plains` | random-walk pebble clusters from a lattice of anchors | small disc clusters; the default base |

Every biome but `plains` ends with the same `dither_edges(prob=0.15, depth=5)`
pass — a vectorized BFS from the wall/open boundary with linear falloff, flipping
cells with distance-weighted probability. **That single shared pass is what gives
the whole map visual coherence.** ⚠️ It is symmetry-destroying: it must run
*inside* the fundamental domain, before the lift.

**Hard constraint: a biome must change the look and the texture of cover, never
the competitive skeleton.** Lanes, chokepoints, route counts, and the collision
point are decided by the structure pass (§4) and are biome-invariant. The biome
paints; it does not lay out. Score every biome against the same static rubric and
reject any biome/size pairing whose score distribution differs materially.

**Muster** supplies the art-side model: biome → tileset/palette → renderer. Our
engine currently tiles **one** `data/arena_floor.png`, and `map_art.nim` reads it
unconditionally, so per-biome floors need (a) a texture set, (b) an existence
check with a named error, and (c) a CI `test -f` guard — an untracked floor PNG
crashes boot for that map only, and `.gitignore` opens with `*` which is exactly
how such a file gets silently omitted. Also note `replay-viewer/config.nims`
preloads the **entire** `data/` dir into every wasm viewer, so per-biome textures
ship to every browser — budget it.

---

## 6. Scoring: hard gates, static score, simulated score

### Layer 1 — hard gates (reject)
Existing `validateGeneratedMap` + : 0 open cross-field lanes on `minWall` **in all
3 hex axis directions** (the current scan is horizontal-only) • 0 stranded
occupiable cells (1px flood with the real 13px footprint — *not* strided; a
stride-3 flood produced 3 phantom cells on Rust) • all pickups/spawn seats
`canOccupy` • corridors ≥ minimum • ≥3 vertex-disjoint base-pair routes • spawn
zone clear of the capture circle • per-team fairness **exactly 1.000**.

### Layer 2 — static score (ranks every candidate, sub-second)
Computable on the existing 8px `FovCellSize` grid:

- stand-side cover fraction within 200px → target [0.10, 0.25]
- stand ring openness → [0.70, 0.90], inter-team delta < 0.25
- interior/enclosure fraction → above control's 33%
- wall coverage → target band (decide 18–30% vs current 4–17%)
- P95 open run → ≤ ~125px
- midfield crossing count (≥3) **and** open fraction
- vertex-disjoint route count + min-cut widths
- chokepoint set; no single isovist covers all of them
- collision-point cover density and route count vs map average
- rect/bar share of shapes ≤ 0.5
- trench count 3–8, on floor, team-comparable
- detour ratio, used-space fraction, visibility-graph degree distribution
  (mean, P95/P50, entropy)

Score **against the default arena as control**, in every batch.

### Layer 3 — simulated score (top-k only)
The MW2 loop, generalized: record N headless episodes, extract per-tick per-seat
positions, compute conversion rate, carry lanes, lanes used, dead floor, largest
unvisited region, death spread, balance entropy `B = −Σ(kᵢ/K)·log_N(kᵢ/K)` (log
base N = team count, so it is [0,1] for 2/3/4/6), pace, and fight-time fraction.

Simulate with **deliberately mismatched agents** (gun-only vs spray-heavy) — a
balance metric measured with identical agents on a symmetric map is definitionally
1.0 and carries no signal.

⚠️ If respawns are randomised, kill-balance is a weak map signal; spend the
budget on pace and fight-time instead.

### The five meta-rules (each was learned the hard way)

1. **Run the default arena as control in every batch. A metric that flags your
   control is wrong; a metric that *skips* your control is worse.** Both happened.
2. **Never report a count without its fraction.** Three metrics started as counts
   and a count cannot tell "one narrow doorway" from "one enormous gap" — both
   score 1. The stand metric called an 81%-open ring "1 approach, a turkey shoot".
3. **Merge ≥3 seeds before judging.** One 1725-tick episode read Rust as 53% dead
   floor; across three it is 22%.
4. **A capture ENDS the episode**, so episode length is itself an outcome and
   dead space is not comparable between a map decided at half the tick limit and
   one that runs to it. Print each episode's length and result.
5. **Pick thresholds against the control, not out of the air**, and print a
   "tight" warning near every bound so slack stays visible rather than silently
   spent by the next change.

**And one from the bot side:** a bot bug once masqueraded as a map defect —
Afghan converted 0-of-43 until a plain arena on the *same enlarged canvas* also
converted nothing. The defect followed the canvas, not the map (the carrier ran
home to an edge-depth x that the wider canvas put outside the capture circle).
**If the generator changes canvas size, re-validate the baseline bot's home-run
logic before reading conversion as a map score.**

---

## 7. Tooling to build

The measurement substrate mostly exists but is not wired into a loop.

**Already ours:** `tools/extract_events.nim --frames` emits per-tick per-seat
`(x,y,aim,hp,flags)` + per-team flag position and carrier, at zero extra cost on
the existing hash-validated re-simulation — **this is the travel-heatmap
substrate.** `tools/map_render.nim` has six analysis overlays. `tools/ladder/
scout.py`'s `Side`/`tally`/`report` layer is verified 88/88 against the platform's
own scores and consumes only `extract_events` JSONL — point it at *local* replays
and it is the fitness scaffolding, ~150 lines already written. `tools/
stuck_analysis.nim` reports stall **coordinates** — a direct terrain-trap signal.
`tools/dump_map_specs.nim` is the sha1 regression harness.
`tests/fixtures/map-validation-baseline.tsv` is 402 pinned outcomes.

**The gap:** there is no `tools/map_eval.nim` that loops
generate → validate → score → simulate → rank. `tools/benchmark_game.nim` already
has 90% of the orchestration (build → config → server → 32 bots → wait → parse
summary); it needs `COGAME_SAVE_REPLAY_URI` and an `--episodes N` loop.

**Also port from MW2:** `mw2_playtest.py`'s `report()` (returns a flat metric
dict, ready to weight), `merge()` (multi-seed), and `heatmap()` — whose design is
worth copying verbatim: paper base so **unvisited floor reads pale and dead space
is immediately visible**, rank-normalized occupancy *so one camper cannot flatten
the map*, warm/cool team tint, and overlays z-ordered carry-routes → capture
circles → spawn zones → death rings. Plus `mw2_structure.py`'s `enclosure()`
(pure numpy, runs on a bare wall mask, the highest-value single static metric).

Performance budget: standard map generate+validate ≈ 10–30 ms release; a headless
episode runs ~2.15× realtime at 32 seats on a giant map (~97 s for 5000 ticks).
So static scoring is free and simulation is the budget. **Debug builds are 10–50×
slower through per-pixel map code — always `-d:release`.**

---

## 8. Stages

1. **Fitness harness first.** `tools/map_eval.nim` + the ported metrics + heatmap.
   Calibrate every threshold against the current `arena` and pool. *Build the
   measuring stick before changing what it measures.*
2. **Ranking loop.** Best-of-K on the *existing* generator. Ship it. This alone
   should be a visible quality jump and it validates the score.
3. **Hex structure pass.** Lanes / rooms / chokepoints / collision point in the
   fundamental domain, on the hex lattice. Replaces the column picket fence.
4. **Burrow port** + the hub-anchored local connectivity proof.
5. **Biome layer** — the five algorithms, the shared dither pass, per-biome floor
   textures, and the biome-invariance assertion.
6. **Size-class rule sets** split by visibility regime; team-count rule sets for
   2/3/4/6.
7. **Re-curate the pool** with the ranker; regenerate `docs/pool-review.html`
   (AGENTS.md requires it in the same change) and the validation baseline.
8. **Field validation** — hosted A/B of generated maps vs the current pool.

## 9. Non-goals

- Not replacing the hand-authored `arena`. It is the **control**, it is the
  league default, and `AGENTS.md` forbids flipping the default without an explicit
  ask. It must keep working unchanged.
- Not migrating the MW2 pack (branch-only, pre-dates the sim split). Its *study*
  is the input here; the six maps are a separate decision.
- Not building a level editor UX. `tools/map_editor` gets ported by the hex epic,
  not extended by this one.
</content>
</invoke>
