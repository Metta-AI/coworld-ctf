P9B REDIRECT 5 (after round 4). R4.4 accepted as the candidate production shape: R3.3 graph + width-1 Dial + one resumable workspace, B=12,288, steering while waiting. James will decide on the route-latency tail and the colossal budget; round 5 gives him numbers and shrinks the tail where it can, still as measurement commits.

R5.1 Tail reduction without more per-tick time (measure each on the 18 scheduler rows, report time-to-route p50/p95/max per row and the slice p95/max):
  a. Shortest-job-first admission: order the pending FIFO by the octile Q4 estimate start->goal (stable seat index as tie-break) so short routes land first; report both the median and the tail, and the determinism fingerprints.
  b. Two-phase admission: run each new request for a small pop quota (e.g. 1,024) immediately in its arrival tick; routes that finish (near goals) install at once, the rest queue. Report how many first-goal routes complete in-tick per roster.
  c. Per-pop micro-optimisation on the Dial loop from 182 ns toward ~100 ns: structure-of-arrays for g/parent/state, branchless neighbour loop over the 8-bit legality mask, avoiding the stale-decrease check when the queued g equals the stamped g, prefetch of the eight neighbour rows. Report ns/pop and the resulting time-to-route at the same 3 ms slice (raise B proportionally to keep the slice at ~3.1 ms).
  d. Warm start for replans: when the goal moved sub-threshold or the profile changed, seed the new search from the previous route's cells (bounded) and report pops saved on the moving-goal rows.

R5.2 Gameplay cost of steering while waiting. On the first-goal burst rows, for each seat measure remaining geodesic distance to goal (from the R3.1 exact 4 px legality, static) at ticks 24/48/96/172 under (i) R4.4 scheduling and (ii) an idealised zero-latency route, and report the ratio; also count seats that steer into a dead end (no-progress ticks) before their route lands. This tells James what the tail costs in play, not just in ticks.

R5.3 Colossal fit, concrete: implement the smallest retained set you identified (int16 8 px weight tables per seat, compact active-node workspace instead of the dense full-board arrays, and a proposal for what of the hierarchical index survives as the hint/steering/coverage backbone) as measurement code, and report exact bytes on colossal and on the largest pool map, plus any per-pop cost change. Do not change caps.

R5.4 Parallel workspaces, measured but not proposed: K = 2 and 4 independent workspaces each owning one in-flight request, single-threaded round-robin (no threads), same total B; report whether the tail improves at equal per-tick cost (it should not by much; this is to close the question).

End with P9B ROUND 5 DONE on its own line. No production cuts, no cap changes, no tests/tests.nim.
