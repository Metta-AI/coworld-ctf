# Peer review of the native H1 result

Reviewed: root `H1/RESULT.md`, `H1/results.json`, `analyze_h1.py`,
`run_h1.py`, `build_h1_candidate.sh`, and the raw archive
`H1/raw-games.tar.gz` (SHA-256 verified
`117188abeee1edee526362bcab7490fe2cffbe9b2cb3c571ad527198259e13f1`),
re-analysed independently in the peer scratchpad. No code change, no
commit, no native use.

## What I verified independently

- **Measured source is the H1 patch.** `candidate/source.patch` equals the
  tracked-file part of my `H1/H1.patch` (the `body_planner.nim` and
  `shard_2.nim` hunks are byte-identical after dropping index lines); it
  omits only the two untracked test files, which were present on the host
  since the native heap suite ran and passed 6/6, and the nav suite 21/21.
- **Compiler and flags.** Both variants built with Nim 2.2.4 Linux amd64
  and exactly the production flag set including `--stackTrace:on` and
  `-d:shellStaticWasmtime`. The 512 variant differs from 256 only by the
  `ColdPlanBudgetPerTick` substitution.
- **Numbers reproduce.** My own parse of the nine `server.log` files gives
  the same totals, p50/p95/max, deadline misses, pending/no-path/stale
  seat-ticks and semantic-stream hashes as `results.json`, and the same
  paired ratios to four decimals.
- **Semantic exactness holds.** All six 512 runs (three parent, three
  candidate) hash to the same `SHELL_PLAN_BUDGET`/`SHELL_NAV`/
  `SHELL_INSTALL`/`SHELL_MOVEMENT` stream, and all three 256 runs to one
  other. Nav counters are identical across variants at equal budget
  (pending 87, no-path 42, stale 297 at 512).
- **Gate arithmetic is as preregistered.** Median of three paired ratios,
  worst-miss comparison, no dropped runs, no burst exclusion.

## Stage attribution (my addition, from the retained `SHELL_TIMING` rows)

| Run | Frame total (s) | planning_us sum (s) | Non-planning (s) | Misses |
|---|---:|---:|---:|---:|
| parent 256 r1/r2/r3 | 31.26 / 31.16 / 31.20 | 7.98 / 8.01 / 7.98 | 23.28 / 23.15 / 23.22 | 106 / 102 / 104 |
| parent 512 r1/r2/r3 | 34.70 / 34.68 / 34.86 | 10.79 / 10.79 / 10.78 | 23.92 / 23.89 / 24.08 | 187 / 186 / 190 |
| candidate 512 r1/r2/r3 | 33.78 / 35.75 / 33.78 | 9.84 / 10.04 / 9.85 | 23.94 / 25.71 / 23.93 | 161 / 187 / 162 |

Per-repeat candidate512 / parent512 ratios: planning **0.912 / 0.931 /
0.913**; non-planning 1.001 / **1.076** / 0.994; total 0.973 / 1.031 /
0.969.

Reading: H1's effect on the stage it touches is consistent across all
three repeats, an 7-9 % reduction of `shell.planning` (about 0.95 s per
game). The second repeat's total regression is entirely outside planning:
non-planning time rose 1.8 s in that one run while ladder and reflex
sums stayed flat, so it is frame-side or host noise, not the heap. The
parent runs show how unusual that is: their repeat-to-repeat spread on
non-planning time is under 1 %. The root was right to retain the run; it
should also be reported as a non-planning outlier so the H1 effect size
is not understated, and it argues for the stage split being a standing
column in every future screen.

## Concerns

1. **Median-of-three with one outlier is thin evidence.** The pass is
   real on the planning stage, but the whole-frame gate passed 2 of 3
   repeats. If H1+H2 or a later card shows the same pattern, three
   repeats will not separate a 3 % effect from one bad run. Recommend
   five repeats for the H1+H2 screen, or at least a pre-registered rule
   for how a non-planning outlier is reported.
2. **The 512 gap is now quantified and mostly not in A\*.** Candidate512
   planning is 9.84 s against parent256's 7.98 s, and non-planning is
   0.7 s higher at 512 because more cogs move. To meet the 512 target on
   this scenario, planning must fall to roughly 7.2-7.3 s, another 26 %
   below candidate512. H2 reaches only the A* and connector arms. From
   P0, the minter is 5.6 s of the 10.7 s parent512 planning total; H1
   already took its heap share. Unless P1 sampling finds a large minter
   cost outside the heap, no exact mechanism on the current list closes
   this gap, and the mint-elasticity question in PEER_PLAN.md section 5
   will come back with numbers attached.
3. **Deadline misses at 512 remain 1.5-1.8x the 256 count** (161-187 vs
   102-106) even with H1. The miss gate compares candidate512 with
   parent512 for the intermediate screen, which is correct for the card,
   but the 512-versus-256 miss ratio is the number James will ask about.
4. Minor: `run.log` prints `game-r1-b512-s32 complete` twice per repeat
   because parent and candidate share the directory name under different
   parents. Harmless, but a variant prefix in that line would remove an
   ambiguity when reading logs cold.

No correctness or protocol defect found. H1 stands as a provisional,
exact, intermediate optimization on this training scenario; it does not
reach the 512 objective, and the remaining gap sits mainly in the minter.

H1 RESULT REVIEWED
