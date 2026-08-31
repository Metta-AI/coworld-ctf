# Lane A (the body) — consolidated gate report

**Date:** 2026-08-31 · **Branch:** `james/s2-body` · **Tip:** `df743c00`

The body lane's evidence in one document: what landed, what it measures,
what is still open, and which numbers should not be quoted without their
caveat. Every measurement below was run by me (the lane's planner-reviewer)
unless it says otherwise; Codex wrote the code, and its self-reported
numbers were re-run before being recorded here.

## 1. What landed

| Commit | What |
|---|---|
| P0 harness | measurement harness + provisional body-measurement report |
| x86 freeze artifacts | port probe + bench Docker image (devbox vehicle) |
| FL-C | activation-barrier cold-plan pre-warm + lifecycle coverage |
| ruling 10 | planning decoupled from route-field minting |
| view producer | selection model + canonical JSON emit |
| prewarm plans-only | barrier stops warming route fields |
| binary view | fixed-layout binary frame + context |
| `df743c00` | §6.1 fully-resolved validator answer table |

Phases 1, 2 and FL-A/FL-B landed earlier via the first-light merge and are
on `main` already.

## 2. The budget story, start to finish

P0 measured the body lane at **188.98 ms worst-tick p95 against a
10.425 ms allowance** — an 18× failure. Every subsequent ruling was aimed
at a specific term in that number.

| Term | Before | After | By what |
|---|---|---|---|
| 32-seat danger rebuild burst | 108.7 ms | 0.976 ms | rulings 5 (K=32 stagger), 7 (8-source cap), 8 (live gunRange rays) |
| cold planner worst | 65.0 ms | bounded by budget | ruling 6 (256-unit/tick server-wide budget) |
| view build+encode 32 seats | 5.77 ms | 3.51 ms | direct `CanonicalWriter` emit + incremental exact sizing |
| validator deep-wall lookup | 69,500 ns | 42 ns | the answer table (`df743c00`) |
| intent→movement, near goal | 785 ticks (32.7 s) | **1 tick** | ruling 10 |

**M4 re-derivation under the frozen constants** (quiet window, load 1.38):
danger 0.976 + executor 0.883 + cold-plan slice 0.101 = **1.96 ms against
the 2.5 ms everything-else-body share**. K=32 and the 256-unit budget both
stand; K=16 would be 2.94 ms and does not fit.

## 3. Quiet-window addendum

The authoritative M4 pass ran at load 1.38 with nothing else on the
machine, 5 seeds × 50 samples, uptime bracketed between segments. The
stencil segment's end load rose to 3.35 (another lane's Codex woke), but
**every row came in 2–15% faster than the contended P0B pass**, so by the
report's own retake rule no retake was owed. Brackets are recorded honestly
in `quiet-window-run.log` rather than smoothed.

One row is **biased and must not be quoted as-is**: `planning_tick_saturated`
is clear-phase biased — 256 units of raster clearing costs ~1 µs and tells
you nothing about search. The honest figure is derived from the worst mix:
62.7 ms / 159k expansions = 0.394 µs/expansion × 256 = **~0.101 ms/tick**.
The x86 batch inherits the same bias.

## 4. M4 and x86, side by side

x86 numbers are from the prod-mirror devbox under `docker --cpus 1`
(1-vCPU Ice Lake m6i — the hosted floor), one batch, box restored clean.

| Row | M4 p95 | x86 1-vCPU p95 | Ratio |
|---|---|---|---|
| `danger_rebuild_8src_live331` (the hinge) | 0.976 ms | **0.912 ms** | 0.93× |
| `danger` at legacy 1050 range | 4.06 ms | — | 1.42× slower |
| `episode_build` | 434 ms | 963 ms | 2.22× |
| real view frame bytes | 12,202 | 12,202 | exact match |

Two things worth noting. The **hinge number holds on the hosted floor** —
it is actually faster there, so the K=32 derivation does not depend on
Apple silicon. And the x86 penalty appears only at larger working sets
(the 1050-range danger field, the episode build), which is a cache-size
story, not a clock-speed one.

The 12,202-byte exact match across architectures is a checkout-sanity
signal: both platforms built the same tree.

## 5. Reaction latency, and the ruling-10 re-measurement

Measured on the giant BR map under the frozen constants. **These supersede
the freeze table's ruling-10-pending rows.**

| Stimulus → response | Before ruling 10 | After |
|---|---|---|
| intent → movement, **near goal, cold** | 785 ticks (32.7 s) | **1 tick** |
| intent → movement, typical worst, cold | 785 ticks | 496 ticks (20.7 s) |
| intent → movement, far pair, cold | 872 ticks (36.3 s) | 536 ticks (22.3 s) |
| intent → movement, prewarmed typical | 172–176 ticks | unchanged |
| new threat → danger field | ≤31 ticks | unchanged (control) |
| zone shrink → changed waypoint | 64 ticks | unchanged (control) |

The near-goal row is the ruling's proof, and it is pinned as a golden on
the real BR map, not merely measured. The controls not moving is the
evidence that ruling 10 touched planning and nothing else.

The cross-map tail (536 ticks ≈ 22 s) is real and reported rather than
tuned away. The budget-raise lever remains parked.

## 6. The activation barrier — two rows, and only one of them is a lobby wait

This is the number most likely to be misread, so both framings are stated
together and **no delta between them is computed** — they measure different
scenarios.

| Row | p95 | What it is |
|---|---|---|
| `activation_barrier_prewarm32_plans_only` | **5,240 ms** | all 32 seats plan the full map diagonal at once |
| `activation_barrier_prewarm32_representative` | **96.1 ms** | 32 scattered seats, cover-class goals (min 314 / median 331 / max 338 px) |

**55× apart.** The first is a deliberate stress synthetic: `planningGoals`
sends every seat from (16,16) to ~(3194,1696) on a 3211×1713 map. It is a
legitimate worst case and it stays in the probe. **It is not an activation
profile and must never be quoted as a lobby wait** — I made exactly that
error earlier in this lane, escalating a "~13 s x86 lobby wait" built on
it, and the representative row is what retired the claim. At real
activation a seat's first standing order comes from the default play —
cover, zone rotation — which is the 96 ms case, ~213 ms at the x86 ratio.

A related framing correction: the validator table's build row measures the
**entire** episode map rebuild (449.95 ms), not the table's marginal cost.
Against the pre-table episode build of 434 ms the winner propagation costs
**~16 ms**. Both are p95 M4 on a contended machine taken at different
times, so ~16 ms is indicative, not precise — the marginal cannot be
isolated on the current tree because the table now lives inside that build.

## 7. Freeze evidence

The constants freeze rests on measurements from this lane:

- **Atlas thinning + `MaxCoverPostsExamined` = 1,024.** A 33-seed generator
  census under 16 px thinning: min 349, mean 452, **max 543** against the
  1,024 cap — 47% utilisation, 481 of headroom. Pre-thinning the same
  census ran min 1,351 / mean 1,786 / max 2,147, with 29 of 33 seeds
  failing at the old 1,536.
- **Density riders**, both measured and pinned, not asserted: the negative
  control measures **1,309** (≥ cap + 25%), the boundary control
  constructs **957** (just under the cap).
- **`MaxSpatialCallsPerStep` 4 → 2.** Lane C measured the real scorer at
  19.9–20.2 µs/call at the 1,536 cap, linear in the cap, ≈13.3 µs at the
  frozen 1,024; a 192-call ceiling is ≈2.6 ms inside the 4.0 ms share.
- **Validator memory**: 22,001,772 B/component (3211 × 1713 × 4), one spawn
  component on the giant maps, against a 256 MiB cap. The answer table
  keeps this **flat** — it stores winners instead of distances rather than
  in addition to them.
- **Atlas parity**: the port's atlas was ground-truthed byte-exact against
  stencil's own atlas twice (2,564 posts in a 600 px disc, identical; 2,215
  vs 2,217 post- versus cell-centred on a 28 px lattice).

## 8. Coder-model provenance

Per phase, taken from the session status bar rather than the agent's
self-report — they disagreed once, and the status bar is authoritative.

| Phase | Model |
|---|---|
| P0, phases 1–2 | gpt-5.6-sol |
| FL-A | drafted gpt-5.6-sol, completed gpt-5.5 high |
| FL-B, FL-C, freeze package | gpt-5.5 high |
| ruling 10, view producer, prewarm, binary view, validator table | gpt-5.5 high |

The 5.6-sol → 5.5-high switch was a PM-authorised response to three
capacity cuts in one phase. Gates were unchanged across the switch: my disk
reviews and my own test runs are the guarantee, and they are model-agnostic.

## 9. First-light expectations, stated plainly

At first light the cogs **move, rotate with the zone, and hold cover. They
do not shoot.** No weapon path is compiled into the movement-only executor,
so "no-shoot is never violated" is true by construction rather than by
policy. Eliminations come from zone damage only.

First light is a milestone, not a gate. **Gate 1 still requires the
complete set** — full belief, the full CombatPolicy execution contract,
weapons, and the differential.

## 10. Open items

1. **View acceptance, 3.51 ms against 2.5 ms.** Reported as a miss, not
   tuned toward. Settled by mechanism: socket view production staggers by
   seat across the interval window (~6 frames/tick at the default), so the
   32-seat single-tick case is a config floor only. A profiling round is
   deferred, not owed — the encode half is only ~0.15 ms, so ~3.1 ms is
   unprofiled selection overhead if anyone wants it back.
2. **`MaxBinaryContextBytes` = 8,192** is a symmetric, bounded-allocation
   choice, not derived; the constants table now says so.
3. **The old row-major scan is still present** as the validator test
   oracle. Deleting it is a separate step once the table is trusted.
4. **The port loop remains**: full belief (phase 3 remainder), the full
   CombatPolicy contract, weapons including the stencil-exact
   `idleSweepAim` that replaces FL-B's annotated placeholder, then the
   gate-1 differential and adapter deletion.
5. **Lane C's reflex path now runs against the answer table.** Their
   9.9–11.1 ms row needs re-measuring on the new dominant costs; the
   rewire timing is being coordinated through the PM.

## 11. Method notes for the cold reviewer

Three habits produced most of the corrections in this report, and they are
worth knowing when reading it:

- **Every acceptance was measured, not inferred.** The view producer's
  first submission compiled the benchmark and reasoned about it; running it
  showed 278.6 ms against a 2.5 ms budget — an accidental O(n²) where cap
  admission re-encoded the whole model per row. It is 3.51 ms now.
- **Reader/decoder tests anchor on landed contract artifacts**, never on
  bytes the same lane's producer emitted. A self-round-trip cannot catch an
  assumption both halves share. The binary frame's tests use hand-derived
  absolute offsets and an absolute `frame_bytes` tripwire; the JSON frames
  go through the production validator.
- **The reflog is checked at every gate.** The coding agent silently
  rebased this lane onto advanced `main` three times. Every one was
  content-clean — verified by comparing patch-ids before and after, not by
  trusting the commit subjects.
