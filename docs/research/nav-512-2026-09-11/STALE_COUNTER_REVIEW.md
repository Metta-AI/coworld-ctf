# What the stale, no-path, pending and moving counters can and cannot say

Read-only: current local source (`src/shell/body.nim`, `body_nav.nim`,
`episode.nim`, `src/ctf/server.nim`) and the archived current-main
held-out logs. No native access, build, production edit or commit. The
frozen gate is not touched; these counters are diagnostic there and stay
so.

## 1. Exact definitions and where they are measured

Per seat, per tick, inside `actFromBelief` (`body.nim:1318-1352`) and
only on the path where the seat is alive, its standing intent is
`navigate_to`, it has a validated standing goal, it is not fire-frozen,
and it has **not** arrived. Every other seat state (hold intent, arrived,
dead, no goal, fire freeze) leaves `navState = bnsIdle` and is counted in
neither bucket. Reflex-installed `navigate_to` orders go through the
same path, so reflex-driven seats are counted too.

- `bnsNoPath`: `seat.pathLen == 0` (`body_nav.nim:296-297`): the seat has
  no route loaded at all, whether because its first plan has not landed,
  its plan failed (a failed plan keeps `pathLen` 0 until the retry rules
  re-request), or its previous route was replaced by nothing.
- `bnsStalePath`: `pathLen > 0 and pathRevision != revision`
  (`:291-294`): a loaded route whose revision differs from the seat's
  current request revision. That is the whole predicate. It does not
  require a pending plan: the current revision's plan may be computing,
  may have failed (a failed plan is not re-requested every tick; the
  retry rules in `navigationWaypoint` wait for an empty path or a stuck
  follower), or may have been cancelled and idle until the next
  re-request. I have not traced every transition, so this review treats
  stale strictly as "revision mismatch with a route loaded", nothing
  more. It says nothing about whether the old route is still useful.
- `bnsFollowing`: otherwise, i.e. walking the route of the current
  revision.

These are folded into `stalePathSeats` / `noPathSeats`
(`episode.nim:1156-1162`) **before** the tick's planning pass runs.
`pendingPlans` (`:1451`) is `pendingPlanCount()` taken **after** the
planning pass. `BUDGET_SHELL` prints all three per tick; `SHELL_NAV`
prints the seat lists only on 24-tick boundaries or ticks with a
plan-budget event.

`moving` in `SHELL_MOVEMENT` (`server.nim:5228-5244`) counts seats whose
emitted input mask has any direction bit this tick, from any source
(following, stale, reflex). A stale seat whose octant is zero (blocked,
`needsIdleAim`) is not moving; a following or reflex seat is moving
without being stale.

## 2. Consequences for the aggregates

1. **Stale and no-path are not sub-counts of pending on a given tick.**
   They are measured before planning, `pending` after. A plan requested
   and completed in the same tick's pool shows as stale or no-path with
   `pending` 0; a failed plan shows as no-path with no pending plan at
   all. In the archived runs `stale + no_path > pending` on 68-154 ticks
   per run, and on the 32-seat edge cell stale alone (217) exceeds
   pending (129). So `stale + no_path` approximates but does not equal
   "seat-ticks waiting for a route"; no identity should be written down.
2. **Stale and moving are not nested.** Per-tick stale counts exceed
   per-tick moving counts on some ticks in every moving cell (excess of
   108 to 646 seat-ticks per run), which is only possible if some stale
   seats are not moving. A "stale share of moving seat-ticks" therefore
   has no defined numerator-over-denominator meaning, and I do not
   compute one. Per-seat joint state per tick is not in the logs (seat
   ids appear only on boundary and event ticks), so it cannot be
   recovered from the archive either.
3. **What the counters do measure, comparably across budgets:** per
   seat-tick counts of three exclusive follower outcomes for seats that
   are actively navigating and not arrived, and a separate count of
   seats currently routing at end of tick. Comparing them between 256
   and 512 compares two different game trajectories, since the budget
   changes when routes land and therefore where cogs are.

## 3. What can honestly be said about the moving cells

Repeat 1 of each (all three repeats are stream-identical per variant):

| Cell | pending 256 -> 512 | no-path | stale | moving |
|---|---|---|---|---|
| map505-s32-moving | 19,926 -> 17,937 (-10 %) | 9,717 -> 3,399 (-65 %) | 9,285 -> 13,623 (+47 %) | 10,747 -> 16,263 (+51 %) |
| map5001-s16-moving | 9,979 -> 8,792 (-12 %) | 4,840 -> 1,595 (-67 %) | 4,745 -> 6,883 (+45 %) | 5,903 -> 8,511 (+44 %) |
| scale29-s32-moving | 21,397 -> 20,489 (-4 %) | 13,733 -> 10,937 (-20 %) | 6,360 -> 8,232 (+29 %) | 7,643 -> 10,014 (+31 %) |

Established from the definitions plus these numbers:

- Seat-ticks spent routing (`pending`) fell in every moving cell, and
  seat-ticks with no route at all fell sharply. Those are the outcomes
  the 512 budget exists for, and no-path is the state in which a cog
  stands still.
- Stale rose. Stale requires a loaded route whose revision is behind
  the seat's current revision, so it can only rise through more
  seat-ticks in which a seat holds a route and has since been given a
  newer revision (by the play's 12-tick goal changes, by `moving_goal`
  replans, by stuck replans, or by a cancelled-and-idle plan). Fewer
  routeless seat-ticks means more seat-ticks in which a route exists at
  all, and every revision bump on such a seat is a stale tick until the
  new revision's route lands or the seat arrives. That is a consistent
  account of the direction of the change under the definitions; it is
  not a measured decomposition.

**Not established:**

- "Each plan lands sooner." The aggregate declines in pending and
  no-path seat-ticks are sums over two different trajectories with
  different request populations (different positions, different
  revision counts per seat, different reflex windows hit at different
  places). They do not establish anything per request. A per-request
  latency claim needs the request-to-install record proposed in the
  protocol review, which does not exist in these logs. The earlier
  verdict's phrase "each plan lands sooner" is withdrawn to "fewer
  seat-ticks were spent routing or routeless in aggregate".
- That any additional stale seat-tick was "useful" motion or that the
  old route was still good. The counters cannot say whether a stale cog
  was walking toward a goal it would still be given; the movement rise
  shows cogs moving more, not moving well.
- The causal link from the pending/no-path declines to the stale rise.
  It is consistent, not measured; the archive lacks per-seat transition
  data.

## 4. Guarantees, kept separate

- **Same-budget exactness, observed:** at 256, the candidate and the
  original produce identical semantic streams on all six held-out cells
  (current-main correctness games) and on the training map. At 512,
  identical streams between parent and candidate were observed only on
  the training map, in the H1, H2 and H3 screens; no same-budget 512
  comparison has been run on the six held-out cells. Full-state
  fingerprints match within each host on the golden-map workload at
  the default budget.
- **Same-budget exactness, structural expectation:** H1, H2 and H3 are
  each argued and tested to be output-preserving independent of budget
  (heap layout oracle, segment-predicate oracle, frame-only change), so
  the candidate at 512 is expected to reproduce the original planner at
  512 on any input. On that expectation, the counter differences in the
  table are a property of the 512 budget, not of the H1-H3 code. The
  expectation is well supported but, for the held-out cells at 512, it
  is an inference from the mechanism proofs and the training-map
  observations, not a direct observation.
- **Route legality (by construction, unchanged):** every planned edge
  still passes the same `canStand` and `segmentClear` tests; H2 is
  proved to return the same predicate, H1 and H3 change no decision.
  Legality does not depend on budget.
- **Route quality across budgets (not guaranteed identical, not
  measured):** the search algorithm, its heuristic, its cost model and
  its termination and fallback rules are unchanged by H1-H3, so
  whatever guarantees the shipped planner already has at a given budget
  are retained unchanged. This review does not add a cost-optimality
  claim: proving one would require establishing the heuristic's
  properties, the effect of route-field readiness on it, the danger
  field's mutation cadence and the suspension semantics, none of which
  this review did. Across budgets, route-field readiness and replan
  timing differ, so the sequence of routes a cog receives can differ.
  Nothing in the protocol measures route quality across budgets, and
  the stale counter is not such a measure.

## 5. Bottom line

The stale increase is real. On the structural expectation above it is
a budget effect rather than a candidate defect, and under the counter
definitions it is a consistent companion of fewer routeless and fewer
routing seat-ticks in aggregate; neither a per-request latency
improvement nor the causal link is measured. It is not a route quality
measurement in either direction, cannot be normalized against movement,
and should be reported exactly as the protocol frames it: a diagnostic
count reviewed against goals and movement. The frozen gate and the
held-out pass are unchanged by this review.

Revision note (P22): this version withdraws the per-request "lands
sooner" claim, removes an unproved cost-optimality statement, separates
observed same-budget exactness from the structural expectation at 512
on held-out cells, and states the stale predicate exactly.

PHASE 22 READY
