# Peer review of the root's H3 implementation

Reviewed read-only: root `H3_CARD.md`, `H3/H3_production.patch`,
`H3/combined.patch`, `H3/parent-*.nim`, `H3/diagnostic_probe.nim`,
`H3/local-diagnostic.log`, `build_h3.sh`, and the three working files in
the root tree. Neither tree was edited; all builds below ran on scratch
copies. Local compiler for anything compiled here: Nim 2.2.6 arm64 with the
production flag set; native verification on Nim 2.2.4 and the image's gcc
stays with the root.

## Scope

- The root's `H3/parent-body_{planner,map,cache}.nim` are byte-identical
  to my H1+H2 tree, so the parent is exactly the accepted H1+H2 source.
- The root's working files equal parent + `H3_production.patch` applied,
  and the patch's only non-comment changes are the eleven signatures named
  in `H3_CARD.md`: `nodeLess`, `setPosition` (planner); `inBounds`,
  `clearanceAt`, `canStand`, `cellWalkable`, `cellOf`, `gridWidth` (map);
  `routeDistanceAt`, `setRouteDistance`, `clearRouteCell` (cache). Each
  gains `{.inline, stackTrace: off.}` and nothing else. Body text is
  unchanged. `body_map.nim` has exactly one `inBounds`, as the brief says.
- No `push`, `checks`, `boundChecks`, `overflowChecks` or `danger` pragma
  appears in the three files; global flags are untouched by the patch.
  `build_h3.sh` records `gcc --version` and the Nim version for the native
  run, as the card requires.

## Exactness

`inline` changes only the C calling convention (the body is emitted as
`static N_INLINE` into each calling unit); `stackTrace: off` removes only
that proc's `nimfr_`/`popFrame` pair. Neither pragma alters evaluation
order, argument semantics, checks, results or unit accounting. Verified on
a scratch tree = my H1+H2 tree with the root's three files dropped in:

| Check | Result |
|---|---|
| test_shell_body_heap_exact (oracle vs production heap) | 6/6 OK |
| test_shell_body_segment_exact (original scan vs production) | 5/5 OK |
| test_shell_body_nav | 21/21 OK |
| `H1/crossbuild_fingerprints.nim` | `ticks=1119 suspension_digest=5936823674378073636 path_digest=3301525546362550601 points=29546`, identical to baseline `6b6b3408`, H1 and H1+H2 |
| runtime-stub `nim check` of `src/ctf.nim` | passes |

## Predicate and error semantics

Generated C for the planner unit under the production flags confirms that
every annotated body keeps its checks while losing its frame:

| Helper | frames | `raiseIndexError` sites | `raiseOverflow` sites |
|---|---:|---:|---:|
| cellWalkable | 0 | 1 | 2 |
| setPosition | 0 | 2 | 0 |
| routeDistanceAt | 0 | 2 | 0 |
| setRouteDistance | 0 | 3 | 0 |
| clearRouteCell | 0 | 3 | 1 |
| clearanceAt | 0 | 1 | 2 |
| cellOf | 0 | 0 | 2 |
| nodeLess, canStand, inBounds, gridWidth | 0 | 0 (none in source) | 0 |

Callers keep theirs: `siftDown`, `advanceMintSearch` and `segmentClear`
each still push one frame. The H2 certificate in `segmentClear` calls the
now-inline `clearanceAt`; its value is unchanged, so the certificate's
proof is unaffected.

## Diagnostic tradeoff

`H3/diagnostic_probe.nim` is the right shape: an out-of-range
`setPosition` from a `{.noinline.}` caller must still raise `IndexDefect`,
the caller must appear in the trace, and the leaf must not (with
`-d:expectLeafFrame` flipping the last assertion for the parent build).
The root's local log shows the trace `diagnostic_probe / diagnosticCaller
/ sysFatal` and the success line. `build_h3.sh` runs the probe on both
parent and candidate natively, which closes the loop on the pinned
toolchain. The lost line is only ever the innermost helper on a bounds
defect that has never been observed; the framed caller and the check
itself remain. The tradeoff is as narrow as the card states.

One depth-related note, not a defect: Nim's call-depth limit counts only
framed procs, so removing eleven leaf frames lowers the counted depth by
at most one at any leaf. No recursion is involved.

## Private-field access through inline bodies

Six of the eleven bodies read private fields (`map.navWidth`,
`map.mapWidth`, `map.clearance`, `map.walkable`, `cache.routeSlots`) and
two use the private templates `pixelIndex`/`gridIndex`. This is safe:
templates expand at the definition site before inlining, Nim's visibility
is a compile-time rule enforced at the definition module, and the C
emitted into the calling units references ordinary struct members whose
type definitions are already emitted there. The scratch build of the
test suites, the cross-build program and the stub server all compiled and
ran with these bodies inlined across `body_planner`, `body_nav`,
`body_cache` and the cover scorer. No new export was added.

## Calling-convention risk

`inline` sets `ccInline` on the proc type, so taking any of these procs
as a value would change its type. A search of `src`, `tests` and `tools`
finds only calls (including `map.gridWidth` method-call syntax), never a
proc value, so nothing else is affected.

## Expectation, so the result is read correctly

From `INLINE_REVIEW.md`, the local assembly showed that removing the
frame shrinks these helpers by 60-73 % and lets clang inline the
check-free ones (`clearanceAt`, `cellWalkable`, `nodeLess`), while the
bounds-checked ones (`setPosition`, `routeDistanceAt`, `setRouteDistance`)
stayed out of line at about a third of their former size. The native gcc
may decide differently. From P1 the eleven helpers carried about 15 % of
baseline-512 samples, of which H2 already removed most of the
`clearanceAt`/`canStand` share; the minter-side remainder is about 7 %.
A pass on the intermediate gate (H512 vs H1+H2 at 512, total <= 0.98) is
plausible; closing the 512-vs-256 gap (H1+H2 sits at 1.009 total, 1.057
p50, 1.027 max, 149 vs 104 misses) from this mechanism alone is not, and
the card rightly does not claim it. If H3 passes stage and misses target,
the remaining exact levers in `NEXT_REVIEW.md` are the primary-lattice
direct record map (A* only) and per-pop hoisting in the mint loop; the
structural mint-elasticity question in `PEER_PLAN.md` section 5 then
returns with numbers.

No correctness, scope or protocol defect found. H3 is exact as
implemented and matches its card.

PHASE 7 READY
