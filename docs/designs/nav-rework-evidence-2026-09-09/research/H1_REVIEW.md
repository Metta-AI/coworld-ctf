# H1_REVIEW: zero heuristic allowance for one exact zero-cost goal attachment

Peer (Claude) read-only review of `H1-source.patch` (candidate versus parent
1598713c, parent identical to the research worktree's
`src/shell/body_route_query.nim`) per `H1_REVIEW_REQUEST.md` and
`H1_PREREG.md`. Documents only; no production query change; no timing claim.
Root screens quality in its isolated checkout.

## 1. The change

Two identical hunks, lines 604 and 629. `allowance` becomes 0 when
`job.goalNode >= 0` and stays `PortalAnchorRingCells * NavCell * 23`
(4 cells, 8 px, 23 per px, 736 Q4) otherwise. The heuristic term everywhere is
`max(0, octileFine(point, request.goal) - allowance)`, so the candidate
simply uses the full octile estimate for jobs whose goal attached as exactly
one node at zero cost. Nothing else in the file changes (diff of the two
snapshots shows only those hunks).

## 2. When `goalNode >= 0` holds, and what it guarantees

`attachments` (line 437) returns a single zero-cost node only on its early
path: the endpoint has both coordinates divisible by `BodyFineStepPx = 4`,
the node index is in range, and the fine standable bit is set. Any other
endpoint goes through the ring search and every attachment there carries a
positive integrated cost, so `goals.len == 1 and goals.costs[0] == 0`
identifies the exact-node case and nothing else. In that case
`request.goal == graph.finePoint(job.goalNode)` exactly, so
`octileFine(goalPoint, request.goal) = 0` and the search's termination value
at the goal is `g(goalNode) + goalCost = g(goalNode)`.

Lifetime: `job.goalNode` is assigned once in `beginBodyRouteSearch` (line
596) and read only in `spendBodyRoutePops` (`mixedActive`, line 660, and the
candidate's allowance). The job is the seat's resumable search; `goalNode`
is not modified between `begin` calls, and a new `begin` resets it to -1
before recomputing. So both allowance sites see the same value for the
whole life of one job, which is what the stale-entry check needs
(section 4).

## 3. Consistency of the full octile estimate: holds through fine and contracted edges

Claim: for every relaxation the code performs, `h(u) <= cost(u, v) + h(v)`
with `h(p) = octileFine(p, goal)` and no allowance.

Costs. `integratedMixedCost` (line 396) splits a segment into
`parts = ceil(max(|dx|, |dy|) / 4)` sub-steps with rounded intermediate
points and prices each sub-step at `mixedStepCost(factor, diagonal)` with
`factor = 65536 + profileWeight * value`, `value >= 0` (masked to 15 bits)
and `profileWeight` in {256, 640, 64} (lines 369 to 371), so `factor >=
65536` and each sub-step costs at least 64 (orthogonal) or 91 (diagonal).
The blocked-cell multiplier and the hazard term
(`hazardStepCostQ4`, `body_hazard.nim:144`, which returns 0 or a positive
multiple of the physical step) only add. So every sub-step costs at least
its base.

Heuristic. `octileFine` floors each axis difference to 4 px units and takes
`90 * min + 64 * (max - min)`. The octile function is a metric on the
integer lattice, so for lattice points p, q and any goal g,
`|h(p) - h(q)| <= octile(|p.x - q.x| / 4, |p.y - q.y| / 4)`: the per-axis
floored distances change by at most the true lattice change (when g lies
between p.x and q.x the two floors sum to at most `|p.x - q.x| / 4`), and
octile is monotone in each argument.

Fine edges. A fine edge is one 4 px lattice move, `parts = 1`, priced 64 or
91, and the octile change is at most 64 or 90. Consistent.

Contracted (bridge) edges. The bridge relaxation (line 690 onward) sums
`integratedMixedCost` over consecutive bridge nodes and pushes with
`octileFine(previous, goal)` where `previous` is the last bridge node's
point, the same point the pop-side recompute uses. For any lattice segment
of `parts` sub-steps, the major axis changes in every sub-step and the minor
axis changes in at least `|dminor| / 4` of them, so the cost is at least
`91 * (|dminor| / 4) + 64 * (parts - |dminor| / 4)`, which is at least the
octile change between the endpoints. Summing over the chain gives
consistency for the whole bridge. The A1 two-hop shortcut does not alter
this: it only changes which bridge nodes exist, not how they are priced.

Admissibility at the goal. Since `h(goalNode) = 0` and `goalCost = 0`, the
value compared against `job.bestCost` at every pop is a lower bound on any
completion through that node. With a consistent h the first settled goal is
optimal and the `entry.f >= job.bestCost` stop is exact.

The previous `max(0, h - 736)` is also consistent (subtracting a constant
and clamping never increases differences), so the candidate does not change
the class of heuristic, only its tightness for the exact case.

## 4. Queue ordering assumptions: unaffected

The Dial queue (line 474 onward) keys by `f mod bucketCount`, records the
exact `queuedF`, lowers `currentF` on any push below it, and pops by scanning
upward for an entry whose `queuedF` equals `currentF`. It therefore assumes
nothing about the f range or monotonicity for correctness; a wider f range
costs scan time only. The stale-entry test at line 634 recomputes
`g + max(0, h - allowance)` and discards entries whose queued f differs; that
is why the two allowance sites must agree for a job, which section 2 shows
they do. If a future edit changed one site only, every entry would be
discarded as stale and searches would silently never settle; a single
helper taking `job` would remove that coupling without a new retained field.

## 5. Quality and tie caveats (for the screen, not objections)

- Equal-cost alternatives can settle in a different order: f values for
  exact-goal jobs rise by up to 736 relative to today, buckets shift, and
  FIFO order within a bucket changes. Route hashes may change among
  equal-cost routes; the prereg already requires reporting them.
- Pops should not increase for exact-goal jobs (tighter consistent h settles
  a subset), but this is a per-request count claim to be measured, not
  assumed; earlier completion also changes which tick a route installs and
  therefore SJF admission order for the other seats.
- Off-lattice goals are untouched. Observation, outside H1's scope and not
  claimed as a result: the same argument suggests the full octile to the
  endpoint is admissible for ring attachments as well, because every
  attachment cost is itself an integrated cost of at least its octile. Root
  may want a separate note on why 736 was introduced before anyone widens
  H1.
- Pre-existing, not H1: `candidate64 < high(int32)` is checked before
  adding h, so `candidate + h` can overflow `int32` near the top of the
  range; h is up to about 736 larger now. Real g values are far from the
  limit, so this is a note, not a finding.

## 6. Verdict

The restricted change is exact: consistency and admissibility hold for fine
and contracted edges with the full octile bound whenever the goal attached
as one zero-cost lattice node, the job-lifetime of `goalNode` keeps both
sites in agreement, and the Dial queue needs no ordering assumption that
the change could violate. Quality can still move through tie order, so the
3,072-case screen remains the gate, as the prereg says.

H1 REVIEW DONE
