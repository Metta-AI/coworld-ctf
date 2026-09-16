# A8_COUNT_REVIEW: identical pixel-search input recurrence, counts-only proposal

Peer (Claude) documents-only review of `A8_COUNT_PROPOSAL.md`. No
implementation; root owns the diagnostic in `nav-early-visited`.

## 1. Are the proposed inputs complete?

`pixelPathInBox(start, center, targets, scratch, exactEdges)` reads: the
box derived from `center`; `canStand` over the box (immutable clearance
of the `BodyMap`); `routePoint(target)` for each target (positive refs
decode from the cell index and the fixed grid width, negative refs from
the fixed fine lattice, per root's audit and the earlier A0/A1 reviews);
the BFS over `NavNeighbors` with per-call generation-stamped visited and
target marks (`beginSearch` bumps the generation, so nothing survives
between calls except a rollover clear that changes no result); and, on
success, `segmentClear` for the path simplification, again immutable.
`exactPixelPathInBox` may call it twice (a retry with `exactEdges` when
the first pass reaches a target without a legal path), and the wrapper
at `pixelPathInBox` level captures both calls as separate keys. So
`(start, center, exactEdges, targets in order)` plus the map is a
complete input for the result `(reachedTarget, targetRef, points)`, with
one caveat the proposal already handles: target order matters when two
targets decode to the same pixel (the first in list order wins the mark),
so the key must keep order and must not sort or deduplicate. The
output-equality check in the diagnostic is still the right proof; the
audit supports it but does not replace it.

## 2. What the existing counts already say about the thresholds

From the A6 counters on map 48 (`A6/A6_SCREEN_REPORT.md`): 457
`pixelPathInBox` calls per construction (the `searches` counter is
incremented at entry, so it includes `exactEdges` retries, of which there
were 3), 6.30 million standability read requests, so about 13.8
thousand reads per call, which means most calls explore the whole box
and fail. Consequences for the proposal's screen:

- "At least 1,000 calls on map 48" cannot be met: the constructor makes
  457 per build. Either the threshold is meant per pool run (11
  configured maps together) or it should be restated as an absolute
  dequeue saving; as written it fails on count before any recurrence is
  measured, which would close A8 for the wrong reason.
- The "25 percent of raw BFS dequeues from repeated empty-result keys"
  criterion is the meaningful one, since failed searches are the
  expensive ones (they exhaust the box). Dequeues per call should be
  captured, as proposed, rather than assumed from reads.

## 3. Where recurrence can and cannot appear

Repeated inputs arise in two places: `resolvePocketPending` re-runs
`resolvePocketSeed` for the same unresolved point across passes (with
`pathStart` advanced), and the join loop tries many candidates. In both,
the target list is `pocketGoals(point, targetGraph)` plus every
`fineTarget` within the 32 px box whose pixel component matches; the
fine-target list grows as paths are added during coverage, so a repeated
point often carries a superset target list on the later pass and the
exact key differs even though a failed result cannot change when the
added targets lie outside the reachable region. An exact-key cache would
correctly miss those, so the count as specified measures the cacheable
recurrence, which is the honest quantity. I recommend one extra
diagnostic-only count beside it: recurrence by `(start, center,
exactEdges)` alone with outcome comparison, to report how much of the
repeated work is exact-key-cacheable versus lost to target growth. If
most repeats fall in the second bucket, the exact cache is worth little
and a different argument (result monotonicity for failed searches, which
would need its own proof) would be the next question, not this one.

## 4. Points to fix in the diagnostic design

- Reset the table at every `initPixelSearchScratch`, as proposed, and
  also record which stage owns the scratch (sides versus pocket
  connectors) so recurrence is attributed by stage as A5 attributed time.
- Key copies and result copies are diagnostic-build only; the wrapper
  must always execute the raw search and only compare, never substitute.
- Count dequeues per call and per outcome class (failed or empty,
  reached-but-no-path after simplification, success), and report the
  three classes separately for repeated keys; also report distinct keys
  per stage so the transient memory of any later cache can be bounded
  from measured maxima, not assumed.
- Verify the negative-ref decode independently as root's audit says, by
  asserting in the diagnostic that `routePoint(ref)` for every target
  equals a recomputation from the map dimensions.
- Scope: map 48 plus a few configured maps, with the per-map call counts
  reported next to the recurrence so the 1,000-call figure can be
  re-examined against real numbers.

## 5. Judgment

Worth counting, with the call-count threshold corrected before the run:
the inputs are complete, the mechanism (repeated failed searches across
pending passes) is plausible from the A5 and A6 counts, and the
diagnostic as designed is safe and cheap. A recurrence count is the right
next step before any cache; any later implementation must audit
generation rollover, transient bounded memory, invalidation at scratch
reset, and re-prove the 76 indices and full quality, as the proposal
says.

A8 COUNT REVIEW READY
