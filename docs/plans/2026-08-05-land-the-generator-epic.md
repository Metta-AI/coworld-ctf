# LAND THE GENERATOR — execution plan

_2026-08-05. Harness epic `3757029c`. Branch `maxwell/mapgen-rebuild`, worktree
`~/projects/coworld-ctf-mapgen`. Successor to the rewrite brief; read
`2026-08-05-mapgen-handoff.md` first for the state, then this for the ordering._

---

## The headline has changed

The previous handoff led with **"the shipping generator calls none of them."**
That is done. `arena.nim` now calls `map_lanes`, `mapgen_biomes` and
`mapgen_vocab`; the column lattice is deleted and the sightline-repair
prosthetic is deleted rather than reimplemented.

The new headline is: **it is wired, it is not landed.**

| | 2-team | 4-team | control (`arena`) |
|---|---|---|---|
| valid | 90% | **68%** | — |
| staticScore | 0.972 | 0.861 | 1.000 |
| interiorFrac | **0.315** | **0.098** | 0.342 |
| cover | 163pm | 149pm | 167pm |

Suite: **37 failures** (was 0). 50-map sheet: mean 0.953 / 0.252, visibly
varied. 2-team clears the brief's `>= 0.30` enclosure bar. 4-team does not, and
4-team is why the suite is red.

---

## The one bottleneck

**~32 of the 37 failures are 4-team tests that never run their assertions.**
They call `generateCtfMap` and get a raise — *"no valid layout in 100
attempts"*. They are not fairness or logic regressions. Fix 4-team validity and
they should clear as a group.

That is why there is a single blocking task, and why fanning out before it lands
wastes agents.

---

## Lanes, not a queue

The contention point is `src/ctf/arena.nim`. Nearly every quality task wants to
edit it, so naive parallelism produces merge pain rather than speed. Four lanes
touching disjoint files:

| lane | files | parallel? |
|---|---|---|
| **A** | `arena.nim` | **SERIAL — one agent at a time** |
| **B** | tests, fixtures, docs | parallel, mostly after W0 |
| **C** | `tools/` and `map_metrics.nim` | **parallel, starts NOW** |
| **D** | `map_lanes.nim`, independent modules | **parallel, starts NOW** |

**Lanes C and D start immediately, alongside W0.** They have no dependency on
it. Lane B mostly waits, because it re-pins against generator output.

```
   W0 ─────────────────────────────────────────►  (Lane A, blocks B and the rest of A)
   157ce824  4-team connectivity via burrow
      │
      ├── A ──►  b7f44fb5 4-team enclosure ──►  10fc7a24 archetypes ──►  49cb2dce corridor 68px
      │
      └── B ──►  c752704b pool + hashes + pool-review
                 78d0db3c pit/trench/window expectations

   C (now) ──►  3811876a gameplay + heatmaps
                945a5b9e staticScore vs play   ⚠ WINDOW CLOSING
                4fb75b77 fix the measuring stick

   D (now) ──►  fcd2e04d small-board structure cost
                377070e8 clearLanes clips city
                d768ba09 GV39 fairness bundle

   GATE  ──►    d4196468 closeout scorecard   (last, one agent, after everything)
```

**Sequencing notes that save rework**

- `377070e8` (city clipping) should land **before** `10fc7a24` (archetypes) —
  city is the closest thing we have to the "blocks" archetype and is currently
  clipped to nothing.
- `fcd2e04d` (small boards) should land **before** `c752704b` (pool) — otherwise
  the pool gets curated with both small seeds excluded and the size-class quota
  skews.
- `49cb2dce` (corridor 68) invalidates the validation baseline, so re-generate
  it **after** that lands, not before. Coordinate with `c752704b`.
- `4fb75b77` (measuring stick) **changes the metrics**. Everything measured
  before it is on a different ruler — which is why the closeout gate re-measures.

---

## Two things that are genuinely urgent

**1. The staticScore validation window is closing** (`945a5b9e`). The experiment
needs a real score spread to correlate against, and the new generator medians
0.972 — it is the saturating generator the original warning was about. The
spread is still recoverable (the attempt density sweep varies fill 40–136%, and
commit `a4efeb4` is the pre-rewire tree), but every tuning decision in this epic
is currently steered by a surrogate that has **never been validated against
play at all**.

**2. Bug A of the GV39 bundle is more likely to bite than when it was filed**
(`d768ba09`). The anchor seam contradicts itself over two 1-px columns per
board. The old lattice missed those columns *by luck*; the new generator emits
organic dithered edges and polygon masses across a much wider footprint.

---

## Working rules, learned expensively

1. `nim c -d:release -r tests/tests.nim` from the worktree root. **Always
   `-d:release`** — debug is 10–50× slower through per-pixel map code. The suite
   is ~7 minutes; the CI-binding number is the slowest shard, ~3 minutes.
2. **This machine's wall-clock timings are worthless under fleet load.** An
   *unchanged* shard drifted +10.4% CPU and 2.1× wall between back-to-back runs.
   Measure CPU time and always re-measure a control you did not change, in the
   same batch. A whole task was once filed on a "50 minute suite" that was 7.1
   minutes plus load.
3. **Commit every green increment.** The machine sleeps without warning and
   usage limits hit mid-task. `git stash create` does **not** capture untracked
   files — bank with a real commit.
4. **Run `arena` as CONTROL in every batch.** A metric that flags the control is
   wrong; one that skips it is worse. Both have happened here.
5. **Look at the output.** The rubric and the eye disagree and the eye is
   currently right: the shape scoring best per unit cover renders as a
   *barcode*, second-best as *confetti*, and a crude mix was the best-looking map
   produced. `tools/map_sheet.nim` prints the score beside the picture for
   exactly this reason. Three iterations were lost on 4-team by reasoning instead
   of rendering — when the board was finally rendered, the model of the failure
   was simply wrong.
6. You may freely break **seed→map** identity. You may **not** break **spec→map**
   identity — replays pin `mapSpec`.
7. Never report a count without its fraction. Merge ≥3 seeds before judging. A
   capture *ends* the episode, so episode length is itself an outcome.
8. `AGENTS.md` requires `docs/pool-review.html` to ship with any pool/generator
   change. It is currently missing for the whole rewrite.

---

## Verify commands every task should know

```
nim c -d:release -o:/tmp/gensweep tools/gen_sweep.nim
/tmp/gensweep 20 2 && /tmp/gensweep 16 4          # validity, score, enclosure, cover

nim c -d:release -o:/tmp/mapsheet tools/map_sheet.nim
/tmp/mapsheet 50 /tmp/sheet2.png                  # 2-team contact sheet — LOOK AT IT
/tmp/mapsheet 30 /tmp/sheet4.png 4                # 4-team

nim c -d:release -o:/tmp/openrow tools/lane_openrow_probe.nim
/tmp/openrow --cover=caves 1 2 3                  # per-row open/carved/empty attribution

nim c -d:release -o:/tmp/vocab tools/vocab_bench.nim && /tmp/vocab table   # enclosure per item
nim c -d:release -o:/tmp/biome tools/biomekit.nim && /tmp/biome table      # per biome
```

`tests/timing_formatter.nim` + `tests/timed_shard_N.nim` answer *"what is
actually slow"* — use them before optimising anything about the suite.

---

## Definition of done

- suite **0 failures**
- 2-team **and** 4-team ≥ 95% valid
- `interiorFrac` ≥ 0.30 on **both** team counts
- `staticScore` no worse than the old 0.939 mean
- repair-plug share 0% (already true — confirm it stayed true)
- a 50-map sheet an observer can **name archetypes from**
- pool re-curated, `docs/pool-review.html` shipped
- ≥ 1 measured **play** result per team count, with the arena as control

A lens with no measurement scores **zero**, not "assumed fine".
