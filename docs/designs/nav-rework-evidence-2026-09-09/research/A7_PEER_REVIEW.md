# A7_PEER_REVIEW: early visited rejection in pixelPathInBox

Peer (Claude) documents-only review of `A7_PROPOSAL.md`. No implementation.
Source read: `pixelPathInBox` in `body_route_index.nim` (A4 baseline plus
the A6 screen arms in `nav-validation-symmetry`), A6 counters and traces.

## 1. Correctness: the move is exact

The neighbour loop today, per `delta` in `NavNeighbors`: compute `next`;
`continue` if outside the box; compute `nextLocal`; `continue` if not
standable (eager: scratch array; direct: `canStand`; lazy: memo);
if `exactEdges` and diagonal, `continue` unless both side pixels are
standable; `continue` if `visitedGeneration[nextLocal] == generation`;
otherwise stamp, set parent, enqueue.

A7 moves the visited test to immediately after `nextLocal`. For every
neighbour exactly one of two things holds:

- It is already visited. Today it reaches `continue` either through a
  failed standability or side test or through the visited test; in every
  path the outcome is `continue` with no state change, because all three
  tests are pure reads of immutable terrain or of the current generation's
  stamps (the lazy memo's first-read initialization is a cache of a pure
  function and is observable only through later reads that return the
  same value). A7 reaches `continue` at the visited test. Same outcome,
  same state.
- It is not yet visited. A7 runs the standability and side tests exactly
  as today, in the same order, and enqueues iff today enqueues; the stamp,
  parent link and queue position are written by the same statements.

So the queue sequence, `parent` chain, `reachedTarget`, `targetRef`, the
reconstructed path and the segment-clear simplification are identical for
every search, including `exactEdges` searches, generation rollover, and
invalid-start returns (unchanged, earlier in the proc). Nothing else in
the index reads the scratch. The start pixel is stamped before the loop,
so neighbours pointing back at it are rejected at the visited test in
both versions. No observable side effect exists to suppress: the only
things that change are read counts, which are visible solely through the
define-gated `pixelStandability` counters (`readRequests`,
`canStandEvaluations`), and those would drop by design; there is no
production counter. That intentional difference should be stated in the
preregistration so a counter diff is not mistaken for a behaviour diff.

## 2. What it can save (bound from the A6 counters, not a prediction)

A6 measured, on map 48 per construction: 457 pixel searches, 6.30 million
standability read requests, 1.93 million eager fills. Reads per search
are about 13.8 thousand against boxes of at most 4,225 pixels, so most
neighbour tests land on already visited pixels (a flood fills a region
once but tests each pixel from up to eight sides). A7 therefore removes
the standability read for roughly the visited majority of the 6.3 million
requests: in the eager arm that is one array read per rejected neighbour
(the visited read remains), in the lazy arm one stamp compare and
possibly a first-read compute, in the direct arm one `canStand` call.

Against the A5 m8i profile (index 252 ms, pocket connectors 134 ms, of
which the pixel-search stages are roughly 80 ms across coverage resolve,
graph joins and final pending), a saving of a few million single-byte
reads is on the order of a few milliseconds, that is low single-digit
percent of index time. The proposal's own 5 percent index-time threshold
is therefore at the upper end of what the read counts allow; it may not
be met even if the change is exact and slightly positive. On m5a the
host factor is about 3.3 on every stage (`A5_NATIVE_REVIEW.md`), so the
proportion is the same and the ratio problem is not closed by it: m5a
needs the index plus nav terms to fall from 1.40 to 1.0 of the body-map
term to reach 2x, roughly a 29 percent reduction, and A7 is not that.

## 3. Alternative

None better within "no memory, no ordering, no gates". The one related
representation idea (a single scratch byte carrying both the visited
stamp and the standability bit, halving cache traffic per neighbour test)
is a larger change with its own rollover semantics and is not what A7
proposes; it should not be folded in. Boost's discovery-state ordering is
the right reference for the loop shape and confirms no library is needed
for moving one predicate in a private loop.

## 4. Worth testing?

Yes, cheaply, and with the threshold stated as what it is. The change is
exact by the argument above, costs nothing in memory or code size, and
the four-arm ablation (eager, eager plus early visited, lazy, lazy plus
early visited) reuses the A6 crafted, rollover, 173,424-search chain and
76-map identity tools without new work. Recommendation: run it as
proposed but preregister two outcomes rather than one gate: (a) the exact
checks must all hold, and (b) report the index-time change per arm on
both hosts against the 5 percent threshold, treating a 1 to 4 percent
gain as a real but sub-threshold result to be banked with A6's lazy arm
rather than adopted alone. Combined lazy plus early-visited is the arm
most likely to show anything, since it removes both the fill and most
memo work; eager plus early-visited is the smallest change if the lazy
arm is not adopted. Do not integrate on the Mac or on a single host.

A7 REVIEW READY
