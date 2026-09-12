# Peer verdict on the current-main m5a held-out campaign

Independent recomputation from `current-main/performance-rows.json`,
`performance-verdict.json`, and the raw archive
`current-main/raw-games.tar.gz` (SHA-256 computed locally:
`a97e024912d845c63b66432f0424f76b94f150651f987e0080a498ae127f66e2`; no
sidecar file yet), extracted into the peer scratchpad. Gates are the
frozen `qualification/PROTOCOL.md`. No native access, build, source edit
or commit.

## 1. Verdict recomputed: pass on all six cells

Per cell, median of three paired candidate-512 / original-256 ratios and
worst deadline-miss counts:

| Cell | total | p50 | p95 | max | worst misses cand / orig | repeat-exact |
|---|---:|---:|---:|---:|---|---|
| map505-s16-edge-r331 | 0.938 | 0.896 | 0.932 | 0.908 | 3 / 3 | yes |
| map5001-s32-edge-r1050 | 0.849 | 0.927 | 0.675 | 0.913 | 8 / 57 | yes |
| scale29-s32-edge-r497 | 0.868 | 0.815 | 0.862 | 0.905 | 228 / 352 | yes |
| map505-s32-moving-r497 | 0.821 | 0.817 | 0.672 | 0.896 | 600 / 1008 | yes |
| map5001-s16-moving-r331 | 0.826 | 0.762 | 0.623 | 0.917 | 1 / 10 | yes |
| scale29-s32-moving-r1050 | 0.846 | 0.820 | 0.844 | 0.917 | 834 / 1061 | yes |

Every median is below 1.00, every candidate worst-miss count is at or
below the original's (equal only on the 16-seat edge cell, 3 versus 3),
and every variant's semantic stream repeats exactly across its three
runs. My numbers equal the root's `performance-verdict.json` to four
decimals. **All 18 individual pairs improve all four timing metrics**;
the weakest single pair is map505-s32-moving-r497 repeat 2 at max 0.983,
the strongest p95 is 0.613 on the 16-seat moving cell.

## 2. Raw archive: coverage and metrics reproduced for all 36 runs

From each run's `server.log`: exit code 0, no `failure.json`, exactly
1,200 `BUDGET_FRAME` rows covering ticks 1..1200, an init log for every
configured seat under the case's play, `SHELL_MOVEMENT seats=` equal to
the seat count on every row, zero play faults. Total, p50, p95, max,
deadline misses and the semantic hash recomputed from the logs are
identical to `performance-rows.json` for all 36 runs. `performance.log`
shows 36 `START` and 36 `complete` lines and no failure. The archive's
copies of `assets.json`, both rows files and both verdict files are
byte-identical to the tree copies; `image-id.txt` records the Docker
image digest (`sha256:5629fc83...`).

Budget identity from the logs: candidate runs reach visits of 16,384
units on 32-seat cells and 8,192 on 16-seat cells (the 512 pools); the
original never exceeds 8,192 and 4,096. On scale29-s32-edge the
candidate's largest visit was 15,675, so that cell never saturated its
pool.

Also in the archive and consistent: the twelve same-budget correctness
games (six cells, original 256 versus candidate 256, all streams equal)
and the six training-confirmation games (median total 0.884, p50 0.842,
p95 0.738, max 0.936; worst misses 31 versus 109; repeat-exact; pass).

## 3. Navigation counters (diagnostic, as the protocol says)

Pending and no-path seat-ticks are lower for the candidate in every cell.
**Stale seat-ticks are higher for the candidate in all three moving
cells** (13,623 vs 9,285; 6,883 vs 4,745; 8,232 vs 6,360) and lower in
the edge cells. Reviewed against goals and movement as the protocol
asks: in those cells the candidate's cogs move far more (sum of
`moving=` counts 16,263 vs 10,747; 8,511 vs 5,903; 10,014 vs 7,643),
install counts are about equal, and replan revisions per seat are
similar or lower. A "stale" tick is a seat following its previous
revision's path while a newer request is pending; with `moving_goal`
replans every 12 ticks and cogs actually travelling, more of the
follower's ticks fall inside that window even though each plan lands
sooner. This is consistent with the mechanism and is not a route-quality
measurement; it should be reported beside the wins, not folded into
them.

## 4. Limitations and things that are not wins

- **The 32-seat stress cells miss the 24 Hz deadline on most frames for
  both variants** (originals 1,008 and 1,061 misses of 1,200; candidate
  600 and 834). The pass is relative; on this single pinned m5a core the
  moving-goal stress at 32 seats is not a deadline-meeting workload for
  either binary. The 32-seat scale-2.9 edge cell also misses on about a
  quarter of frames at 256 (352) and a fifth at 512 (228).
- **Zone-escape reflex windows** suspend play stepping for roughly a
  third of every game (P12 finding); both variants include them, and
  the moving play's replan load covers about 700 of 1,200 ticks.
- **One host, one core, pinned.** Common production families and
  unpinned execution are the fleet card's job and are not covered here.
- **No sidecar hash file for `raw-games.tar.gz` yet**; the hash above
  should be recorded beside it as for H1-H3.
- The training pass on the current base is confirmation of the already
  passed H3 target, not a new selection; the held-out pass is on six
  frozen cells, three maps and two plays, and says nothing about other
  maps, policies or contention.

## 5. Verdict

The current-main candidate at 512 passes the frozen six-cell held-out
protocol on m5a by my independent recomputation: every median ratio
below 1.00, every worst-miss count not above the original's, every stream
repeat-exact, full coverage on all 36 runs, and raw logs reproducing the
recorded metrics exactly. The stale-tick increase in the moving cells is
reported as a diagnostic finding with its mechanism, not as a failure.
No production or fleet claim follows from this until the fleet card
runs.

PHASE 20 READY
