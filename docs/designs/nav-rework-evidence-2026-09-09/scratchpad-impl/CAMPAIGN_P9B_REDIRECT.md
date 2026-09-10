P9B REDIRECT (read with CAMPAIGN_P9B.md; this changes the priority order). Claude read P9_INVESTIGATION.md. Findings accepted: the predecessor-cycle fix stays; the 35 ms query is O(arcs x segment cells + chains x cells) re-pricing of static paths per seat per query; corridor refinement helps (p95 20 % -> 7 %) but cannot reach 3 % because room choice is static and carrier-danger maxima stay at 86 %.

Conclusion James has already stated: room navigation must be danger-sensitive. The gate compares us to a fine-grid search with the full dynamic cost, so the only way to match it is to SEARCH with the full dynamic cost. The task's original "no full-board search" rule was motivated by the old planner's cost shape (per-seat map-sized workspaces, 4 px lattice, resumable multi-tick work, hundreds of ticks); James has authorised trying anything that improves accuracy and time, so measure the following as IDEA 0, ahead of everything else:

IDEA 0 — synchronous bounded weighted A* on the 8 px nav grid.
- Graph: nav cells over `legalMoves` (the same legality the index proved), diagonal 181 / orthogonal 128 Q4, the existing integer danger (profile-weighted), blocked x8, and the elapsed-tick hazard price, i.e. the oracle's cost function on the 8 px grid.
- Heuristic: octile static distance to the goal cell (admissible because every weight is >= 1). Try also the tighter admissible bound min over goal-room portal sides p of (octile(cell, p) + staticChainDist(p -> goal)) only if octile alone is too loose.
- Workspace: ONE shared generation-stamped workspace sized by nav-cell count (g int64/int32, parent int32, stamp uint32, heap), never per seat; ~1 MB on pool maps, ~9 MB colossal; count it in retained shared bytes.
- Bound: fixed pop cap (try 16,384, 32,768, 65,536); on cap hit, fall back to the hierarchical route (which stays as the guaranteed-bounded backbone, the hint/steering source, and the coverage proof). Report fallback rates per stratum.
- Endpoints: the existing exact pixel connectors (attach ring <= 4 cells) at both ends; the route ends at goal.goalPoint.
- Descriptor: the path is a cell list; store it as the local leg (raise RouteLocalLegCap to what the corpus needs, measured, and assert at activation), or stream it in chunks; report the longest path in cells across the corpus.
- Follower: unchanged (K = 6 smoothing from the real position).
- Expected: inflation on ALL strata close to the no-danger strata today (p95 ~1-2 %, max ~7.7 % from 8 px geometry and smoothing); per-query cost on the order of the old 4 px planner's 1.3-6 ms far-route cost divided by ~4 for the coarser grid. Measure both, plus pops per query.

IDEA 0b — per-tick query budget. With Idea 0 a 16-seat first-goal burst may exceed the body slice. Add a deterministic per-tick budget of K route constructions (seat-index order, try K = 2, 4, 8); seats over budget steer toward the goal this tick (they already move) and construct on a later tick. Measure body-slice p95/max at 16/32 seats and the worst time-to-route in ticks. Also measure a POP budget per tick as the alternative (resume a suspended search next tick from the shared workspace is NOT allowed since the workspace is shared; keep it simple: whole queries only).

Keep ideas 1-8 from CAMPAIGN_P9B.md, but re-order: after Idea 0/0b, do the hierarchical query cost reductions (per-seat per-generation memo so repeated queries and the fallback are cheap; lazy chain pricing only for sides the A* pops; room-summary first-pass scoring), then follower smoothing (5), then the rest. Also add the corpus's follower-executed path measurement Codex proposed.

Scoreboard rows as specified; end each round with P9B ROUND <n> DONE. Do not touch the containment gate or the corpus.
