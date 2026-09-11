# Phase 4 review: next mechanism if H2 is insufficient

Read-only. No code edits, no native use, no new timing, no commit. Inputs:
`H3_PROPOSAL.md`, `P1_SAMPLING_PLAN.md`, `H1_CARD.md`, `H2_CARD.md`,
PEER_PLAN.md, and generated C inspected under the pinned production
flags. **Compiler caveat:** every generated-C observation below comes from
the local Nim 2.2.6 (arm64 macOS) with the production flag set
`-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on
-d:noSignalHandler`. That matches the flags but is not the pinned native
Nim 2.2.4; the frame-emission rules cited are from the same compiler
source family, but native verification of the codegen and any timing
remains with the root.

## 1. Does the tiny comparator pay frame bookkeeping? Yes, verified in C

Method: compiled `H1/crossbuild_fingerprints.nim` with `-c` under the
flags above (a real program, because compiling the planner module alone
dead-code-eliminates every proc and shows nothing) and read the emitted C
for the three planner modules.

Counts of `nimfr_(` frame pushes per module: body_planner 73, body_map 61,
body_cache 32. One per emitted proc; every non-template helper has one.

`nodeLess` as emitted:

```c
N_LIB_PRIVATE N_NIMCALL(NIM_BOOL, nodeLess__...)(HeapNode* a, HeapNode* b) {
    NIM_BOOL result; NIM_BOOL colontmpD_, colontmpD__2, colontmpD__3, colontmpD__4;
    nimfr_("nodeLess", "body_planner.nim");
    ... four-field compare ...
    popFrame();
    return result;
}
```

`nimfr_` expands to a stack `TFrame FR_`, four field stores, and
`nimFrame(&FR_)`, which (system `excpt.nim:569-578`, inlined) reads the
thread-local `framePtr`, computes `calldepth = prev.calldepth + 1`, links
`prev`, stores `framePtr = &FR_`, and compares `calldepth` with the 2000
limit. `popFrame` restores `framePtr` from `prev`. Under `--threads:on`
`framePtr` is `NIM_THREADVAR`, so each push and pop is a TLS access.
`setPosition`, `canStand`, `inBounds`, `clearanceAt`, `cellWalkable`,
`routeDistanceAt` and `setRouteDistance` are emitted the same way; none is
`static N_INLINE`, because none carries `{.inline.}`. `canStand` in turn
calls `inBounds` and `clearanceAt` as separate framed procs, so one
`canStand` is three frame pushes and pops.

Compiler rule (local `compiler/cgen.nim:1281-1296`): the frame is emitted
whenever `optStackTrace` is in the proc's options, independent of calling
convention or `{.inline.}`. `H3_PROPOSAL.md` item 2 is therefore correct:
adding `inline` alone does not remove the frame.

Per sift level in `siftDown` (from the emitted loop): two `nodeLess` calls,
one `setPosition` call, five bounds checks, three overflow-checked index
operations, and the `nimErr_` flag test after each call. So a sift of
depth L performs 3L framed calls. Per pop-plus-push on a heap of tens of
thousands of nodes that is roughly 90 framed calls, before the A* pop's
own `canStand`/`segmentClear`/`ensureRecord`/`heuristic` calls. For the
minter pop it is about the same 90 heap-side framed calls plus 24
`cellWalkable` frames. This is a code-shape fact; its time share is not
measured and is exactly what P1 sampling can see, because `nimFrame` is
not a separate symbol (it is inlined) but the TLS traffic and the
`popFrame` stores land in each helper's self time.

## 2. Template versus explicit per-proc pragma versus blanket removal

Three ways to remove the tiny helpers' frames while keeping global flags:

1. **Template.** Correct and removes the frame. Downside for `nodeLess`:
   a template re-evaluates its arguments, and every call site passes
   `heap.nodes[i]` expressions, so each field read would repeat the
   indexing and bounds check unless the call sites bind `let` copies
   first. That is a larger diff with more surface for a mistake, and the
   oracle test (`tests/body_heap_reference.nim`) would keep comparing a
   proc against a template, which is fine but asymmetric.
2. **Per-proc `{.stackTrace: off.}`.** Nim supports it on procs: local
   `compiler/pragmas.nim:1201-1203` routes `wStackTrace` on
   `skProc`/`skMethod`/`skConverter` into `sym.options`, which is what
   `cgen.nim:1281` consults. This removes only that proc's frame, keeps
   every caller's frame, keeps proc semantics, argument evaluation, bounds
   checks and unit accounting unchanged, and is visible in the source at
   the exact helpers it affects. Combined with `{.inline.}` it also lets
   the C compiler inline the body.
3. **`{.push stackTrace: off.}` over the module or a blanket flag.** Not
   proposed; the verdict excludes it, and it would also strip frames from
   procs that can raise `BodyMapError` (`ensureRecord`, `pushOrDecrease`,
   `advanceReconstruct`), which is exactly where a trace is wanted.

Recommendation: option 2 on a named, reviewed list of leaf helpers that
cannot raise anything except a bounds `IndexDefect`, whose trace then
shows the framed caller instead: `nodeLess`, `setPosition` in the planner;
`inBounds`, `clearanceAt`, `canStand`, `cellWalkable`, `cellOf` in the
map; `routeDistanceAt`, `setRouteDistance` in the cache. The diagnostic
cost is one missing innermost frame line on a defect that today has never
been observed; the callers (`siftUp`, `siftDown`, `segmentClear`,
`advanceMintSearch`) keep theirs. A template is a reasonable second choice
only for `nodeLess` and only with `let`-bound arguments; option 2 is the
more explicit and smaller tradeoff. Either way the change must be its own
card with the H1 heap oracle, the H2 segment oracle and the cross-build
fingerprints rerun, because it alters codegen for the exact procs those
oracles cover.

## 3. Assessment of H3 item 1 (sparse-record lookup)

Sizes on the practice map, with the 64-bit generation stamp the verdict
requires:

| Lattice | Nodes | int32 record + uint64 generation | int64 record + uint64 generation |
|---|---:|---:|---:|
| primary 4 px | 344,487 | 3.9 MiB | 5.3 MiB |
| fallback 2 px | 1,376,342 | 15.8 MiB | 21.0 MiB |
| fallback 1 px | 5,500,443 | 62.9 MiB | 83.9 MiB |
| today's hash (3 x 8 B x 1,048,576) | | 24.0 MiB | |

The root's 63 MiB figure is the 1 px lattice with int32 records. A direct
map for all three lattices is not affordable. The affordable shape is a
direct map for the primary lattice only (+3.9 MiB per seat, +125 MiB at
32 seats, inside the 4x allowance) with the existing hash retained for the
2 px and 1 px fallback steps. Because the hash is sized by record count,
not lattice size, it stays as it is; no memory is saved, only added.
Record numbering is preserved as long as `ensureRecord` is called in the
same order, which it is, so `keys[]`, `closed[]`, `gScore[]`, `cameFrom[]`,
the capacity error and every fingerprint stay identical. The exactness
oracle would be a copy of `SearchStore` plus a randomized
ensure/find/begin comparison, the same shape as the H1 heap oracle, plus
the cross-build fingerprint run. This helps A* only and touches nothing
the minter uses.

## 4. Ranking for the next card, conditional on native results

The decision hinges on what P1 sampling attributes. Two readings:

- **If sampling shows the heap helpers and map leaf helpers with large
  self time** (frame stores, TLS traffic, bounds checks inside
  `nodeLess`/`setPosition`/`canStand`/`cellWalkable`): choose the per-proc
  `{.stackTrace: off.}` card (section 2). It is the only remaining exact
  mechanism that reaches the minter, which carries most of the 512
  regression (PEER_PLAN.md 1.2), and it is a ten-line, reviewable diff.
- **If sampling shows `ensureRecord`/`hashSlot` and cache-miss-bound
  loads dominating A\*** and the minter is already within budget after
  H1: choose the primary-lattice direct map (section 3). It does nothing
  for the minter, so it cannot close a mint-side gap.

Alternatives from PEER_PLAN.md and why they rank lower now: E2 heap
slimming is blocked as written by the no-narrowing rule on generation
stamps (it could still shrink `tie1`/`tie2`/`item` to int32, a 40 to 32
byte node, but that needs its own layout argument and is a smaller win
than either option above); E3 heuristic hoisting is small and A*-only; E4
segment-mask precompute is superseded by H2's 96.5 % certificate hit rate.

Whatever is chosen, one mechanism per card, correctness before timing, and
the same nine-run order and thresholds as `H1_CARD.md`.

## 5. Notes on P1_SAMPLING_PLAN.md

Agree with the plan. Two additions that cost nothing: record whether the
99 Hz sampler resolves inlined `nimFrame` into caller self time (it will,
since it is `static inline`), so frame cost shows up as self time in
`nodeLess`, `setPosition`, `canStand` and friends rather than as a
`nimFrame` symbol; and capture `perf report --no-children` sorted by
symbol for the planner modules alongside the DWARF call-graph view, so the
leaf-helper share is a single number the next card can be predicted
against.

PHASE 4 READY
