# Held-out qualification protocol

Frozen before candidate held-out performance runs. Candidate source and binary
hashes must be attached before execution. H3 or a later candidate may enter
only after passing its registered training stage and the 512-versus-256 training
target. Changing the candidate requires a new complete qualification campaign.

## Inputs

Use the six configurations in proposed-configs/manifest.json, with their exact
SHA256 hashes. That directory name is historical; this card freezes those bytes.
The three maps are certified pool entries 505 and 5001 and the first passing
scale-2.9 generated map, seed 5120918. No candidate timings informed selection.
The rejected old map fixtures and seven rejected generated seeds remain in the
archive. Practice and the golden fixture are identical and count as one map.

| Case | Map | Seats | Range | Play | Health |
|---|---|---:|---:|---|---:|
| map505-s16-edge-r331 | 505 | 16 | 331 | edge_ride | 3 |
| map5001-s32-edge-r1050 | 5001 | 32 | 1050 | edge_ride | 3 |
| scale29-s32-edge-r497 | scale 2.9 | 32 | 497 | edge_ride | 3 |
| map505-s32-moving-r497 | 505 | 32 | 497 | moving | 1000 |
| map5001-s16-moving-r331 | 5001 | 16 | 331 | moving | 1000 |
| scale29-s32-moving-r1050 | scale 2.9 | 32 | 1050 | moving | 1000 |

The moving play alternates carrier/hunter profiles and opposite zone-quarter
goals every 12 view ticks. It is a deliberate replan stress case. The edge
cases retain ordinary health and represent complete real games. Each run must
cover 1,200 frames and initialize every configured guest without play faults.
An early ending or invalid input is a coverage failure, never a performance
win. Preserve it and preregister any replacement before running the replacement;
it cannot rescue or erase the original campaign result.

This six-cell design replaces the peer's ten-cell proposal to keep the first
held-out screen bounded while covering every map and workload, both seat
counts, and three ranges. It does not claim a complete Cartesian product.

## Execution and comparison

Use the unchanged finite process lifecycle in run_case.py, the production
Nim 2.2.4/GCC 12.2 build flags and the same timers as the training screen.
One game at a time; no overlapping compilation, compression or profiling.
On m5a pin all server threads to logical CPU 5, clients to CPUs 6 and 7.
Keep the full frame, including guest bursts, logging and replay work.

Run three process repetitions of all six cells (36 games), in manifest order
within each repetition. Pair original 256 with candidate 512. Alternate pair
order by (zero-based case index + zero-based repeat index) parity: even starts
with original, odd starts with candidate. No warmup removal, dropped frames,
replacement of slow runs, outlier filtering or window selection.

Report per-cell median paired ratios of total, p50, p95 and maximum frame time.
Every ratio must be <=1.00, and the candidate's worst deadline-miss count across
three repetitions must not exceed the parent's worst count. Every cell must
pass; no averaging away a losing workload. A deadline miss is ns*24>1e9.
Keep every raw run and report the three pairs, not only their medians.

## Correctness and coverage

Before timing, run the heap and segment oracles and navigation suite on the
candidate. For each of the six cells, run candidate at 256 once and original at
256 once and compare the exact deterministic semantic log stream (installs,
movement, nav, planning accounting). These are correctness runs, excluded from
acceptance timings. Each timed variant must also repeat the same semantic
stream across its three runs. Budget 512 is allowed to change trajectory and
completion times relative to 256; same-budget behavior is not allowed to change.

Record pending/no-path/stale seat-tick counts for all runs, and review any
increase against the corresponding goals and movements. They are diagnostic
counts, not a substitute for route legality or a demand that different game
trajectories have identical counts. The existing exact segment oracle and
same-budget streams enforce unchanged route choices and unit accounting.
Check actual moving-play installs for both profiles and moving_goal=true,
12-tick interval scheduling while alive, plus observed planning revisions.

Memory accounting must preserve the existing capacities, allocations and
layouts. Confirm activation and retained memory on the largest test map and a
colossal geometry against original. Any increase requires its own explicit
budget comparison (non-colossal user allowance is up to 4x, not a target).

## Further qualification before a production recommendation

A passing m5a campaign still needs the production-linked and runtime-stub
builds, full required tests, viewer rebuild and independent source review.
Repeat representative edge and moving cases on common production AMD c6a and
Intel c8i-flex families, with pinned and unpinned server execution. Freeze
that hardware card before its runs; report each environment separately.
Investigate the original Mac/Linux internal-hash difference and establish
cross-platform path/output determinism without hiding raw state differences.
No live budget change or publication follows automatically from this card.
