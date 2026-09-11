# H3 implementation: explicit diagnostic tradeoff in eleven leaf helpers

Status: local diagnostic probe passed; native correctness/build running.
Root tree nav-budget-screen, parent is the accepted H1+H2 source preserved in
H3/parent-body_*.nim. H3/H3_production.patch contains only this mechanism;
H3/combined.patch is the full candidate against6b6b3408 for native restoration.

Added inline and stackTrace:off to nodeLess/setPosition in body_planner;
inBounds/clearanceAt/canStand/cellWalkable/cellOf/gridWidth in body_map; and
routeDistanceAt/setRouteDistance/clearRouteCell in body_cache. No module-wide
pragma, compiler flag changes, layout changes, new allocations, search change,
unit/budget change or bounds-check relaxation. The measured baseline for H3's
incremental gate is the H1+H2 binary at512, and the goal baseline is original256.

The diagnostic tradeoff is intentional: these tiny helpers do not add their
own Nim stack frame. Their framed caller remains visible if a bound check
raises. The runtime's sysFatal frame can also appear; "caller remains" does
not mean runtime machinery disappears. Parent and candidate probe builds use
--stackTrace:on, the same deliberate invalid heap position and the same named
noinline diagnosticCaller. Parent requires setPosition in the trace, candidate
requires its absence; both require IndexDefect and diagnosticCaller. Local
candidate Nim2.2.6 passes (H3/local-diagnostic.log). Native probes use pinned
Nim2.2.4 and GCC in the production build image.

Rationale: P1 sampling finds significant leaf-access cost under the minter,
which H2's A*-only certificate cannot eliminate. Peer-generated C/assembly
shows frame bookkeeping dominates the local helper instruction count, while
ordinary inline annotations preserve most out-of-line calls. These are reasons
to test, not measured proof of the candidate's speed. Every native timing run
will be retained under the frozen H3_CARD.md criteria.

No GameVersion, viewer or public budget change yet. This remains uncommitted
research pending qualification and the required final viewer rebuild.
