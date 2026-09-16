PROCEED P3. Claude re-ran route_index 7/7, body_map 15/15, body_nav 20/20, body_seat 23/23 and both server compile shapes in the worktree; Phase 2 accepted.

Carry-overs (record in LEDGER.md, act on them in the phase named):
- Activation headroom is thin: published:48 sits at 1.93x (cap 2x) on arm64, and index_ms is high where pocket passes are heavy. In Phase 9, if the canonical run breaches 2x on any pool map, the first structural fix is to make the pixel-grid pocket BFS cheaper (seed all uncovered pixels of a component in one multi-source pass, reuse the visited stamp), not to relax the cap.
- Every retained fine point must be reachable by Phase 3 endpoint attach via the per-cell fine-anchor index you added; write that test in Phase 3 (a valid goal whose only anchors are fine points).
- The merge of origin/main is done; GameVersion on main is now 59, so Phase 10 must claim above whatever main has then.

Phase 3 reminders: side-graph A* with the exact octile heuristic in Q4 units; shared generation-stamped scratch; descriptor assembled and validated in scratch before the atomic copy; typed failures leave the previous route untouched; cap instrumentation asserts <=4096 side pops and <=4096 local pops; the legacy planner stays alive and every pre-existing suite stays green. End with the literal line PHASE 3 DONE.
