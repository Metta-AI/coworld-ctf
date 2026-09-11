# Phase 5 review: inline-only leaf annotations versus per-proc stackTrace off

Read-only. No code edits in the tree, no timing, no native use, no commit.
Inputs: `P1/RESULT.md`, `P1/perf-flat.txt`, `P1/perf-report-resolved.txt`,
`H3_PROPOSAL.md`, and three scratch generated-code variants described in
section 2.

**Compiler provenance for everything in section 2:** local Nim 2.2.6
(arm64 macOS) with the pinned production flag set `-d:release -d:useMalloc
--threads:on --opt:speed --stackTrace:on -d:noSignalHandler`, C compiled to
assembly by Apple clang 17.0.0 with Nim's own C flags (`-O3
-fno-strict-aliasing -pthread`). The native binaries are Nim 2.2.4 on Linux
amd64 in the Debian bookworm build image, whose C compiler is that image's
gcc; I did not find its version in any retained log. Inlining decisions are
compiler-specific, so the local assembly is evidence about code shape, not
a prediction of the native binary. Where the native P1 profile speaks to
the same question I cite it separately.

## 1. What P1 says about the helpers

Shares are of all 4,098 userspace samples of the baseline-512 process,
activation included. Grouped from `perf-flat.txt` by symbol family:

| Family | Symbols | Self share |
|---|---|---:|
| Legality (`clearanceAt` 4.83, `canStand` 3.15, `cellWalkable` 1.49, `segmentClear` 0.66, `isWall` 0.54, `inBounds` 0.39) | map/planner | 11.1 % |
| Heap (`siftDown` 2.98, `setPosition` 2.37, `swapNodes` 2.27, `pushOrDecrease` 0.49, `siftUp` 0.39, `pop` 0.32) | planner | 8.8 % |
| Cache access (`routeDistanceAt` 1.49, `setRouteDistance` 0.29, `clearRouteCell` 0.29) | cache | 2.1 % |
| Record hash (`hashSlot` 1.17, `ensureRecord` 0.27) | planner | 1.4 % |
| `gridWidth` accessor (0.90, of which 0.68 under `advanceMintSearch`) | map | 0.9 % |

Caller chains in `perf-report-resolved.txt`: the legality family sits
almost entirely under `segmentClear` from `advanceAstar` (H2's target);
`cellWalkable`, `routeDistanceAt`, `gridWidth` and most of `siftDown`,
`setPosition`, `swapNodes` sit under `advanceMintSearch`. So after H1 and
H2 the remaining helper cost is minter-side: about 6.8 % of samples in
`setPosition`, `cellWalkable`, `routeDistanceAt`, `gridWidth`,
`setRouteDistance`, `clearRouteCell` plus the H1-reduced sift bodies.

Two native facts bear directly on the root's question. `setPosition` and
`swapNodes` are standalone symbols with their own self time although they
live in the same translation unit as their callers, so the native C
compiler declined to inline them there. `nodeLess`, also same-unit, has no
standalone samples, so it was inlined. Same-unit availability is therefore
not sufficient for inlining; the body's shape decides.

## 2. Generated-code experiment (local, three variants)

Scratch copies of `src/` only, never the tree. Program: a 32-seat golden-map
drain that exercises the planner and minter. Variants:

- **base**: the tree as it is (H1+H2).
- **inline**: `{.inline.}` on the cross-module and heap leaf helpers:
  `inBounds`, `isWall`, `clearanceAt`, `canStand`, `cellOf`,
  `cellWalkable`, `gridWidth`, `gridHeight`, `width`, `height`,
  `cellCenter` (map); `routeDistanceAt`, `setRouteDistance`,
  `clearRouteCell` (cache); `nodeLess`, `setPosition`, `latticePoint`
  (planner).
- **inline+stOff**: the same helpers with `{.inline, stackTrace: off.}`.

### 2.1 What Nim emits

With `{.inline.}`, `cgen.nim` `genProcNoForward` (ccInline branch) emits
each helper as `static N_INLINE` into every calling module's C, so the
map and cache helpers do become same-unit for the planner. Their bodies
still carry `nimfr_`/`popFrame`, exactly as the root expected. With
`{.inline, stackTrace: off.}` the frame lines disappear from those bodies
(planner-unit frame count 73 to 58) while every non-annotated proc keeps
its frame.

### 2.2 What the C optimizer then does (Apple clang 17, -O3)

Standalone helper bodies still present in the planner unit's assembly,
instruction count / calls / thread-local frame-pointer accesses:

| Helper | base | inline | inline+stOff |
|---|---|---|---|
| `nodeLess` | 68 / 1 / 2 | 68 / 1 / 2 | 19 / 0 / 0 |
| `setPosition` | 66 / 2 / 2 | 66 / 2 / 2 | 18 / 0 / 0 |
| `canStand` | cross-unit call | 105 / 3 / 2 | 58 / 5 / 0 |
| `clearanceAt` | cross-unit call | 122 / 5 / 2 | inlined away |
| `cellWalkable` | cross-unit call | 79 / 4 / 2 | inlined away |
| `routeDistanceAt` | cross-unit call | 65 / 2 / 2 | 25 / 2 / 0 |
| `setRouteDistance` | cross-unit call | 79 / 2 / 2 | 24 / 0 / 0 |

Hot callers, instruction count / `bl` calls:

| Caller | base | inline | inline+stOff |
|---|---|---|---|
| `advanceMintSearch` | 215 / 26 | 294 / 34 | 311 / 33 |
| `siftDown` | 332 / 10 | 332 / 10 | 222 / 6 |
| `siftUp` | 214 / 32 | 214 / 28 | 144 / 11 |
| `pushOrDecrease` | 125 / 24 | 125 / 24 | 129 / 19 |
| `segmentClear` | 234 / 13 | 218 / 12 | 230 / 22 |
| `advanceAstar` | 393 / 39 | 392 / 39 | 390 / 37 |

Readings:

1. **Inline-only changes almost nothing.** With the frame-carrying bodies
   available in the same unit, clang still emits calls to `cellWalkable`,
   `routeDistanceAt`, `setRouteDistance` (from `advanceMintSearch`),
   `setPosition` (from `siftDown`) and `nodeLess` (from `pushOrDecrease`).
   Only the one-load accessor `gridWidth` was inlined. The frame code
   makes each body address-escaping (the `TFrame` local is linked into the
   thread-local chain) and adds a no-return call and the error-flag exit
   path, and the inliner's cost model rejects that. Call count per hot
   function is unchanged or higher (`advanceMintSearch` 26 to 34 because
   the inline bodies now pull in `raiseIndexError2` paths). The native
   `setPosition`/`swapNodes` standalone samples say gcc behaves the same
   way for same-unit bodies of this shape.
2. **The frame is 60-73 % of each leaf helper's instructions.** `nodeLess`
   68 to 19, `setPosition` 66 to 18, `setRouteDistance` 79 to 24,
   `routeDistanceAt` 65 to 25 when only the frame is removed. Instruction
   count is not time, but on helpers this small the frame push, depth
   check, thread-local link and pop are the body.
3. **Removing the frame unlocks inlining only for check-free helpers.**
   `clearanceAt` and `cellWalkable` were inlined away in the third
   variant; `setPosition`, `routeDistanceAt`, `setRouteDistance`,
   `canStand` remained calls even at 18-58 instructions because each keeps
   bounds-check raise paths (`raiseIndexError2` plus the `goto BeforeRet_`
   error-flag exit). Bounds checks are semantics under `-d:release` and
   stay. So even the explicit tradeoff does not turn the minter loop into
   straight-line code; it shortens the helpers and drops 4 of 10 calls
   from `siftDown` and 21 of 32 from `siftUp`.

## 3. Answers to the root's questions

**Can a narrow inline-only candidate preserve full diagnostics and reduce
cross-module calls enough?** No. It preserves diagnostics completely, but
it does not reduce calls: the C optimizer keeps the frame-carrying bodies
out of line, cross-unit or not. Section 2.2 row 1 is the evidence, and P1's
same-unit `setPosition`/`swapNodes` standalone samples are the native
corroboration. Inline-only is not worth a card.

**Does the tiny comparator pay frame bookkeeping?** Yes, and it is most of
its body (68 to 19 instructions), but P1 shows the native compiler already
inlines `nodeLess` into the sift loops, so its frame cost is inside
`siftDown`/`siftUp` self time rather than a separate symbol. The comparator
is the wrong single target; the framed leaf helpers that stay out of line
(`setPosition`, `cellWalkable`, `routeDistanceAt`, `setRouteDistance`,
`gridWidth`, `clearanceAt`, `canStand`, `inBounds`) are where both the
frame cost and the call cost land.

**Is a template a reasonable explicit tradeoff?** For `nodeLess` it is
moot given the above. For the leaf helpers a template would need
`let`-bound arguments at every call site to avoid re-evaluating indexed
expressions, and it would move bounds checks into callers. The per-proc
`{.stackTrace: off.}` pragma (supported for procs by `pragmas.nim:1201`)
is the smaller, more legible form of the same tradeoff and is what
section 2's third variant measured.

## 4. Recommendation

Two exact options remain that reach the minter, ordered by how much
diagnostics they give up:

1. **Fewer calls, frames untouched (no diagnostic tradeoff).** In
   `advanceMintSearch` read `gridWidth` once per pop instead of per use
   (P1: 0.68 % under this caller for a field read), and take the route
   slot once per pop instead of calling `routeDistanceAt`/
   `setRouteDistance` per neighbour. This needs one small exported cache
   accessor or a per-pop `ptr` to the slot, changes no unit or result, and
   keeps every frame. Expected effect is bounded by those symbols' P1
   share (about 2.5 %); it is cheap but small.
2. **Per-proc `{.stackTrace: off.}` on a named leaf set** (with
   `{.inline.}` so the check-free ones can be inlined): `setPosition`,
   `nodeLess`, `inBounds`, `clearanceAt`, `canStand`, `cellWalkable`,
   `cellOf`, `gridWidth`, `routeDistanceAt`, `setRouteDistance`,
   `clearRouteCell`. Diagnostic cost: an `IndexDefect` raised inside one
   of these shows the framed caller as the innermost frame. Section 2
   bounds the mechanical effect (helpers shrink 60-73 %, sift loops lose
   30-40 % of instructions and up to two thirds of their calls). This is
   the only remaining exact lever whose upper bound is in the same range
   as the minter's share of the 512 gap; it must be its own card with the
   H1 heap oracle, H2 segment oracle and cross-build fingerprints rerun.

Order: if the root wants zero diagnostic change, run option 1 first and
expect a small win; otherwise option 2 is the candidate to time. A blanket
or module-wide stack-trace removal is not proposed.

## 5. Limits

- Local assembly is arm64 Apple clang 17; native is amd64 gcc in the
  bookworm image. Inliner thresholds differ; the direction of section 2's
  findings is corroborated by P1's native standalone symbols, the exact
  instruction counts are not.
- Instruction counts are not cycle counts; frame stores to the
  thread-local chain and bounds-check branches have different costs.
- P1 shares include activation and are of the baseline 512 binary without
  H1 or H2.

PHASE 5 READY
