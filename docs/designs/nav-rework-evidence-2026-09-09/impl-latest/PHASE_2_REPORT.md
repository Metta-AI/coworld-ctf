# Phase 2 report — immutable shared route index qualified

## Status

Phase 2 is **complete** at commit `71e2d2d1`. The RESOLVE4 pixel-grid
connectors close every validator-component pocket across all 64 published
Season 2 maps, arena, and the supported four-team colossal fixture without
raising the fixed 32 px connector box or changing the 64 px portal-cluster
constant. The focused route-index suite passes 7/7; the existing body-map and
body-nav suites pass 15/15 and 20/20; runtime-linked and runtime-stub server
checks both pass.

The final uninterrupted 66-map qualification has zero uncovered validator
pixels in every row. Pool maxima are 1.9298x combined activation and 1,399,698
retained bytes, below the 2x / 16 MiB gates. Colossal is 2.1146x and 26,709,081
retained bytes, below the 3x / 32 MiB gates. Non-validator islands remain
explicitly counted as unreachable and are not represented.

## Phase boundary

Commands:

```sh
git fetch --prune origin
git rev-parse --abbrev-ref HEAD
git rev-list --left-right --count HEAD...origin/main
git rev-parse origin/main
git status --short --branch
```

Exit code: `0`.

Output before Phase 2 changes:

```text
james/s2-nav-rework
2       0
52103b107832e12f30a719dd299bc7636c3dd12f
## james/s2-nav-rework...origin/main [ahead 2]
```

The branch was already current, so no merge/rebase was needed. Incoming
`origin/main` contained no Phase 2 body/episode drift to reconcile.

## Completed checkpoint 1 — compact frozen corpus

Commit:

```text
7e1364c0 test: compact shared-navigation route corpus
```

Changes:

- `tools/build_nav_route_corpus.nim` emits exactly one compact JSON case per
  line while keeping the top-level metadata readable.
- `tests/nav_route_corpus_support.nim` freezes
  `NavCorpusSourceCommit = "52103b107832e12f30a719dd299bc7636c3dd12f"`.
- The writer and reader both require that literal provenance.
- The 3,072-case corpus fell from 155,151 lines / 3,519,081 bytes to 3,082
  lines / 2,130,507 bytes without changing cases.

Fresh writer reproduction:

```sh
/tmp/build_nav_route_corpus_p2 /tmp/nav_route_corpus.p2.final.json
cmp tests/fixtures/shell/nav_route_corpus.json /tmp/nav_route_corpus.p2.final.json
wc -l -c tests/fixtures/shell/nav_route_corpus.json /tmp/nav_route_corpus.p2.final.json
shasum -a 256 tests/fixtures/shell/nav_route_corpus.json
```

Exit code: `0`.

Output excerpt:

```text
wrote 3072 cases to /tmp/nav_route_corpus.p2.final.json
    3082 2130507 tests/fixtures/shell/nav_route_corpus.json
    3082 2130507 /tmp/nav_route_corpus.p2.final.json
aefb19ecf5159288f78c041429c81523b02c641f0e186cdd2de37958db871de7  tests/fixtures/shell/nav_route_corpus.json
```

`cmp` produced no output, proving byte identity.

## Completed checkpoint 2 — one canonical legality predicate

Commit:

```text
24b05e1d shell: centralize body navigation legality
```

Changes:

- `src/shell/body_map.nim` now owns and exports `NavNeighbors`, exact
  `segmentClear`, and `legalNavMove`.
- `src/shell/body_planner.nim` consumes those exports and no longer carries a
  duplicate neighbor table or segment predicate.
- A map name is retained by `BodyMap`, allowing later activation failures to
  name the map.

The new focused test was written first. Its initial compile failed as expected
because `shell/body_route_index` and the new exports did not exist:

```sh
nim check -d:noSignalHandler --threads:on --path:src tests/test_shell_body_route_index.nim
```

Exit code: `1`.

Representative errors:

```text
cannot open file: shell/body_route_index
undeclared identifier: 'NavNeighbors'
undeclared field: 'mapName'
```

Legacy body-nav validation after centralization:

```sh
nim c -r -d:release --path:src -o:/tmp/test_shell_body_nav_p2 tests/test_shell_body_nav.nim
nim c -r -d:release --path:src -o:/tmp/test_shell_body_map_p2 tests/test_shell_body_map.nim
```

Both exit codes: `0`.

Output excerpts:

```text
[Suite] shell body seat navigation
  [OK] route and duck caches are bounded, pinned, LRU, and non-minting
  ...
  [OK] follower corridor, octants, and stuck state match stencil
```

All 20 body-nav tests passed.

```text
[Suite] shell body immutable episode map
  [OK] component-by-component static fields match the pinned stencil golden
  ...
  [OK] invalid spawn fails the activation build
```

All 15 body-map tests passed.

## Initial route-index checkpoint (historical)

Files were intentionally left uncommitted at the first gate:

```text
 M src/shell/body_route_index.nim
 M tests/test_shell_body_route_index.nim
?? tools/qualify_body_route_index.nim
```

That WIP implemented the 8 px immutable route index, exact retained arrays,
reusable build scratch, fixed clockwise anchor rings, bounded crossings,
packed next-hop fields, deterministic fingerprints, and the verdict's 32,767
edge-ID activation assertion. Activation errors name both the map and choke.

Focused validation:

```sh
nim c -r -d:release --path:src -o:/tmp/test_shell_body_route_index_p2 tests/test_shell_body_route_index.nim
```

Exit code: `0`.

Output:

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
```

The focused green result is not enough to commit because the all-map gate
fails.

## Original binding crossing failure

Commands:

```sh
nim c -d:release --path:src -o:/tmp/qualify_body_route_index_p2 tools/qualify_body_route_index.nim
/tmp/qualify_body_route_index_p2 --quick
```

Compile exit code: `0`. Run exit code: `1`.

Output:

```text
map  size_px nav_cells walkable rooms portals sides portal_field_cells segments crossings segment_cells arcs graph_components standable_px covered_px uncovered_px component_hash retained_bytes transient_bytes body_map_ms index_ms activation_ratio
body_route_index.nim(375) buildSides
Error: unhandled exception: body route index map 'br-gen-20049' choke 47 has no crossing within +-4 cells and 64 pops [BodyMapError]
```

The full command is designed to emit one row per each of the 64 published maps,
the arena, and the four-team colossal map. Because the first published map
fails activation, no qualification row can be retained for any map and no
retained/transient-byte or build-time comparison can yet be reported.

## Failure diagnosis

A scratch-only diagnostic inspected exactly map `br-gen-20049`, choke 47 under
the same anchor ring and crossing box:

```sh
nim c -r -d:release --path:src -o:/tmp/p2_choke_diag \
  /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/p2_choke_diag.nim
```

Exit code: `0`.

Output:

```text
map=br-gen-20049 choke=47 pos=(x: 1551, y: 1193) cell=(x: 193, y: 149) rooms=6/11 candidates=6/3 direct=0 min_chebyshev=4 global_found=true global_steps=96 global_visited=9240 local4_found=true local4_steps=8 local4_visited=29
first_a=(x: 195, y: 148) component=1
first_b=(x: 191, y: 148) component=1
```

Observed facts:

- Both anchor sides are in the same pixel component.
- There is no direct legal pair among the fixed 8 px anchor candidates.
- The local 8 px graph cannot connect them inside the existing box.
- The global 8 px graph reaches the other side only by a 96-step detour after
  visiting 9,240 nodes; enlarging the local box would encode the wrong route.
- A 4 px connector exists inside the current 32 px box in 8 steps and visits
  only 29 nodes.

This is not a pop-cap problem. Raising 64 pops cannot create an edge absent
from the local 8 px graph, and enlarging the box would admit a long global
detour. Per the Phase 2 plan, qualification stopped instead of weakening the
bound.

## Authorized resolution and proof

`RESOLVE_P2.md` authorized the proposed negative-`int32` representation and
fixed 4 px contingency. The WIP now implements:

- direct legal 8 px crossing first;
- one 64-pop 8 px search inside the fixed +/-4-cell box;
- one 256-pop 4 px search in the same box;
- exact `segmentClear` validation for every retained fine step;
- true pixel-distance Q4 static lengths;
- containing-8-px-cell decoding for later danger, blocked-cell, and hazard
  sampling;
- sparse pocket connectors when the exhaustive pixel proof requires them;
- separate graph seeds for pixel components with no portal-side node;
- no fine points in rooms, portal fields, or ordinary intra-room segments.

The fine-grid index includes one of 16 deterministic 4 px phases. Crossings use
phase `(0,0)` because coarse centers lie on it; a pocket uses the phase passing
through its first uncovered pixel. The negative reference remains exactly
`-1 - fineGridIndex` and is independently decodable.

Focused proof:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_p2_current \
  tests/test_shell_body_route_index.nim
```

Exit code: `0`.

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
```

Quick qualification after moving the exhaustive proof out of the production
construction path:

```sh
nim c -d:release --path:src \
  -o:/tmp/qualify_body_route_index_p2_resolved \
  tools/qualify_body_route_index.nim
/tmp/qualify_body_route_index_p2_resolved --quick
```

Compile exit code: `0`. Run exit code: `1` after the first row passed and the
arena failed activation.

```text
published:00:br-gen-20049  2271x1212  42733  33011  14  51  102  357834  528  51  1  2  10  40  26202  1056  2  2121275  2121275  0  0x233dfa45c47feb91  1000515  299959  207.195  140.693  1.6790
body_route_index.nim(619) buildSides
Error: unhandled exception: body route index map 'arena' choke 81 has no side anchor for room 6 within 4 cells [BodyMapError]
```

The passing row means:

- 1 fine portal crossing;
- 2 pocket connectors;
- 10 retained fine points / 40 added bytes;
- 2,121,275 of 2,121,275 standable pixels covered;
- 1,000,515 retained bytes and 299,959 transient bytes;
- BodyMap 207.195 ms, index 140.693 ms, combined activation 1.6790x
  (under the 2x pool limit).

## Current side-anchor gate failure

The arena miss is real, not a tie/order defect:

```sh
nim c -r -d:release --path:src -o:/tmp/p2_arena_anchor_diag \
  /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/p2_arena_anchor_diag.nim
```

Exit code: `0`.

```text
map=arena choke=81 pos=(x: 848, y: 273) center=(x: 106, y: 34) clearance=8 rooms=6/22
room=6 first_ring=5 count=1 cells=@[(x: 105, y: 29)]
  cell=(x: 105, y: 29) point=(x: 844, y: 236) pixel_component=1
room=22 first_ring=1 count=1 cells=@[(x: 105, y: 35)]
  cell=(x: 105, y: 35) point=(x: 844, y: 284) pixel_component=1
```

A scratch-only global-nearest anchor census then covered all 64 published maps,
arena, and colossal:

```sh
nim c -r -d:release --path:src -o:/tmp/p2_anchor_census \
  /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/p2_anchor_census.nim \
  > /tmp/p2_anchor_census.out
awk -F'\t' '/^MISS/ {miss++; maps[$2]=1; split($5,a,"="); \
  if (a[2]+0>max) max=a[2]+0} /^ROW/ {rows++} END {for (m in maps) \
  mapCount++; printf "rows=%d misses=%d maps_with_miss=%d max_ring=%d\\n", \
  rows, miss, mapCount, max}' /tmp/p2_anchor_census.out
```

Exit code: `0`.

```text
rows=66 misses=68 maps_with_miss=26 max_ring=29
```

Representative extremes:

```text
MISS  published:06:br-gen-20930  choke=53  room=4  ring=18
MISS  published:17:br-gen-22338  choke=43  room=1  ring=29
MISS  published:63:br-gen-26528  choke=71  room=1  ring=16
MISS  arena                         choke=81  room=6  ring=5
ROW   size:colossal  chokes=1032  max_ring=4  over4=0
```

Therefore a ring-5 exception is not sufficient. Raising the global ring to 29
would also place many two-sided anchors outside the fixed +/-4-cell crossing
box, so it would not preserve the ratified local-portal design. Per the Phase 2
plan, this new all-map anchor failure stops the phase for review rather than
silently changing either bound.

Recommended next review question: whether these far incident-room associations
should be excluded/re-derived as non-local BodyMap chokes, or whether the route
index needs a separately bounded side-attachment path from the choke to a
distant coarse room anchor. Widening `PortalAnchorRingCells` alone is not a
complete fix.

## RESOLVE2 checkpoint — portals derive from the coarse room raster

Commits:

```text
585ea565 shell: qualify fine route-index coverage
ebb0c525 shell: derive portals from coarse room boundaries
```

`585ea565` isolates the authorized sparse 4 px crossings, pocket connectors,
and exhaustive coverage qualifier. `ebb0c525` then implements the binding
two-pass derivation:

- Pass A scans row-major legal 8 px cross-room moves, groups unordered room
  pairs, clusters at the single `PortalClusterSeparationPx = 64` constant, and
  picks maximum-clearance representatives with the specified stable ties.
- Pass B uses BodyMap chokes only when no Pass-A anchor is inside the fixed
  +/-4-cell box. It chooses the first walkable A in ring order, searches for a
  reachable different-room B using direct, 64-pop 8 px, then 256-pop 4 px
  search, and derives both rooms from `roomOf`.
- Identical canonical Pass-B room/anchor pairs dedupe. Failed hints increment
  `droppedChokes`; they do not fail activation or reuse choke room labels.
- The qualifier now reports chokes, portals, sides, dropped chokes, maximum
  room degree, and arcs.

Fail-before-fix command:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_p2_portal_red \
  tests/test_shell_body_route_index.nim
```

Exit code: `1`.

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
body_route_index.nim(619) buildSides
Unhandled exception: body route index map 'arena' choke 81 has no side anchor
for room 6 within 4 cells [BodyMapError]
  [FAILED] portal sides come from their own coarse room anchors
```

Focused green command:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_p2_portals \
  tests/test_shell_body_route_index.nim
```

Exit code: `0`.

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
  [OK] portal sides come from their own coarse room anchors
```

Quick qualification command:

```sh
nim c -d:release --path:src \
  -o:/tmp/qualify_body_route_index_p2_resolve2 \
  tools/qualify_body_route_index.nim
/tmp/qualify_body_route_index_p2_resolve2 --quick |
  tee /tmp/p2_resolve2_quick.tsv
```

Exit code: `0`.

```text
map                         chokes portals sides dropped max_degree arcs uncovered retained activation
published:00:br-gen-20049       51      51   102       0         15 1032         0   998527     1.6957
arena                            90      90   180       2         11 1038         0   276406     1.6654
```

Both maps stay well below a ~2x topology expansion relative to the census, so
the 64 px cluster constant was not raised to 128 px.

## Current full-qualification gate failure

The first wrapper used zsh's read-only `status` name and failed before it could
report the program result:

```text
zsh:1: read-only variable: status
```

The corrected command was:

```sh
/tmp/qualify_body_route_index_p2_resolve2 \
  > /tmp/p2_resolve2_full.tsv 2> /tmp/p2_resolve2_full.err
p2_exit_code=$?
tail -n 8 /tmp/p2_resolve2_full.tsv
sed -n '1,120p' /tmp/p2_resolve2_full.err
exit $p2_exit_code
```

Exit code: `1`.

```text
published:00:br-gen-20049  2271x1212  42733  33011  14  51  51  102  0  15  357834  516  51  1  2  10  40  25813  1032  2  2121275  2121275  0  0x233dfa45c47feb91  998527  299959  194.262  138.278  1.7118
body_route_index.nim(1226) buildPocketConnectors
Error: unhandled exception: body route index map 'br-gen-20184' leaves 562 standable pocket pixels unresolved; first=(x: 1971, y: 575); no 4 px connector within 32 px and 256 pops [BodyMapError]
```

The exact scratch diagnostic command:

```sh
nim c -r -d:release --path:src --path:src/ctf --path:src/shell \
  -o:/tmp/p2_resolve2_pocket_diag \
  /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/p2_resolve2_pocket_diag.nim
```

Exit code: `0`.

```text
map=br-gen-20184 point=(x: 1971, y: 575) coarse=(x: 246, y: 71) standable=true pixel_component=2 coarse_walkable=false coarse_graph=0 goals=0
fine_path_points=0
nearest_anchored_ring=-1 count=0
component_pixels=72 bbox=(1971,575)-(1992,580) fine_phase0=4 first_fine=(x: 1976, y: 576) max_distance_squared_from_first=257
unrepresented_component=2 pixels=72 coarse_cells=0 fine_phase0=4 bbox=(1971,575)-(1992,580)
unrepresented_component=3 pixels=7 coarse_cells=0 fine_phase0=0 bbox=(229,1178)-(235,1178)
```

This was the representation diagnosis before RESOLVE3. `RESOLVE3_P2.md`
supersedes the proposed fine-only anchors: these two components cannot contain
a cog or ValidatedGoal and must be counted rather than represented.

## RESOLVE3 scoping attempt and validator-component stop

The uncommitted scoping attempt:

- retains validator component IDs and spawn points in `BodyMap` behind bounded
  read-only accessors;
- seeds and builds fine pocket connectors only for validator components;
- asserts each validator component has an anchored coarse cell and every spawn
  point's coarse cell is anchored, naming map and component on failure;
- adds `unreachable_components` and `unreachable_px` qualification columns;
- counts all standable pixels while requiring connector coverage only for
  validator-component pixels.

Fail-before-fix command:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_p2_resolve3_red \
  tests/test_shell_body_route_index.nim
```

Exit code: `1` at the expected pre-scoping island failure:

```text
body route index map 'br-gen-20184' leaves 562 standable pocket pixels unresolved;
first=(x: 1971, y: 575); no 4 px connector within 32 px and 256 pops
[FAILED] coverage excludes islands that cannot contain a validated endpoint
```

Post-scoping focused command:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_p2_resolve3 \
  tests/test_shell_body_route_index.nim
```

Exit code: `1`.

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
  [OK] portal sides come from their own coarse room anchors
body_route_index.nim(1263) buildPocketConnectors
Unhandled exception: body route index map 'br-gen-20184' leaves 483 standable
pocket pixels unresolved; first=(x: 1884, y: 648); no 4 px connector within
32 px and 256 pops [BodyMapError]
  [FAILED] coverage excludes islands that cannot contain a validated endpoint
```

The BodyMap provenance/accessor portion passes independently:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_map_p2_resolve3 tests/test_shell_body_map.nim
```

Exit code: `0`; all 15 tests passed.

The remaining point was diagnosed with the scratch-only copy of the fixed
search, plus an unbounded version and an exhaustive local two-segment scan:

```sh
nim c -r -d:release --path:src --path:src/ctf --path:src/shell \
  -o:/tmp/p2_resolve3_validator_diag \
  /private/tmp/claude-501/-Users-jamesboggs-coding-coworlds-coworld-ctf/3d57efa8-dd72-43f4-8a00-809d9728282b/scratchpad/impl/p2_resolve2_pocket_diag.nim
```

Exit code: `0`.

```text
map=br-gen-20184 point=(x: 1884, y: 648) coarse=(x: 235, y: 81) standable=true pixel_component=1 coarse_walkable=false coarse_graph=0 goals=24
fine_path_points=0
unbounded_fine_pops=9 reached=(x: 0, y: 0)
two_segment_anchor=(x: -1, y: -1)
nearest_anchored_ring=2 count=5
unrepresented_component=2 pixels=72 coarse_cells=0 fine_phase0=4 bbox=(1971,575)-(1992,580)
unrepresented_component=3 pixels=7 coarse_cells=0 fine_phase0=0 bbox=(229,1178)-(235,1178)
```

The next review question is whether pocket corridors may use deterministic
phase-changing exact edges between the already encoded fine points, or whether
the 4 px contingency needs a different local graph construction. Raising the
pop or connector caps cannot fix this case: the current phase graph is fully
exhausted after 9 pops, and no <=32 px two-segment bridge exists.

## Documentation audit

The `audit-documentation` skill was run before the Phase 2 commits. No
authoritative repo documentation update is required yet: the compact corpus is
a test-fixture representation change, legality centralization does not change
behavior, and the committed index is not integrated into production routing.
The approved design remains the source for the index, while this report and
`LEDGER.md` record the newly discovered qualification facts.

The replay viewer and GameVersion remain deliberately deferred to Phase 10 by
the implementation brief.

## Pre-RESOLVE4 Git state (historical)

```sh
git status --short --branch
git log --oneline origin/main..HEAD
```

Exit code: `0`.

Output:

```text
## james/s2-nav-rework...origin/main [ahead 7]
 M src/shell/body_map.nim
 M src/shell/body_route_index.nim
 M tests/test_shell_body_map.nim
 M tests/test_shell_body_route_index.nim
 M tools/qualify_body_route_index.nim
ebb0c525 shell: derive portals from coarse room boundaries
585ea565 shell: qualify fine route-index coverage
e8a7b75a shell: add shared body route index
24b05e1d shell: centralize body navigation legality
7e1364c0 test: compact shared-navigation route corpus
7f589dc2 test: pin shared-navigation liveness failures
f289a8ee test: freeze shared-navigation route corpus
```

No push, PR, Asana mutation, viewer rebuild, or GameVersion change was made.

> **Codebase friction: 4/5.** The validator provenance cleanly defines which
> components matter, but the 8 px room raster and fixed-phase 4 px contingency
> still do not model every corridor inside a real validator component. Exact
> predicates make the failure trustworthy; the mismatch only becomes visible
> through an exhaustive per-pixel proof.

## RESOLVE4 completion checkpoint

Commit:

```text
71e2d2d1 shell: connect pixel-grid route pockets
```

The final connector implementation:

- runs deterministic 8-connected pixel BFS in `NavNeighbors` order inside the
  fixed `+-32` px / 4,225-pixel box, with `canStand` recorded for every pixel;
- accepts anchored coarse centers and already retained fine points, stopping
  at the first target reached;
- simplifies the discovered route with farthest-first exact `segmentClear`
  string-pulling and stores true pixel-distance Q4 lengths;
- chains new connectors in row-major seed order and fails activation if a
  validator pixel remains unresolved;
- adds the pixel-grid third attempt after Pass B's 8 px and 4 px searches;
- retains a compact coarse-cell-to-fine-anchor index for Phase 3 endpoint
  attachment;
- joins coarse graph fragments only after an exact pixel connector proves they
  belong to one physical component;
- leaves rooms, portal fields, and ordinary segments on the 8 px grid.

Safe coarse-cell interiors are not enumerated into the deferred validation
queue: the 1-Lipschitz clearance field proves every pixel in a cell has an
exact segment to its center when center clearance exceeds `PlayerHalf` plus
that cell's actual trailing-edge radius. Boundary cells still receive the
full pixel census. This reduced the slowest pool map's index build from roughly
230 ms to 191.328 ms in the final uninterrupted run without weakening the
coverage check.

## Final focused and compatibility validation

Focused route-index command:

```sh
nim c -r -d:release --path:src \
  -o:/tmp/test_shell_body_route_index_resolve4_final \
  tests/test_shell_body_route_index.nim
```

Exit code: `0`.

```text
[Suite] immutable shared body route index
  [OK] canonical legality matches the old planner predicate
  [OK] index validates and is deterministic
  [OK] edge width and named activation failures fail closed
  [OK] fine crossing fallback stays sparse and decodes to coarse sampling
  [OK] portal sides come from their own coarse room anchors
  [OK] coverage excludes islands that cannot contain a validated endpoint
  [OK] pixel pocket connectors cover every validator endpoint
```

Legacy compatibility and server-shape commands:

```sh
export WASMTIME_C_API="$PWD/tools/runtime_spike/.deps/installed/aarch64-macos/wasmtime-c-api"
export C_INCLUDE_PATH="$WASMTIME_C_API/include"
export LIBRARY_PATH="$WASMTIME_C_API/lib"
export DYLD_LIBRARY_PATH="$WASMTIME_C_API/lib"
nim c -r -d:release -d:noSignalHandler --threads:on --path:src \
  -o:/tmp/test_shell_body_map_p2_resolve4 tests/test_shell_body_map.nim
nim c -r -d:release -d:noSignalHandler --threads:on --path:src \
  -o:/tmp/test_shell_body_nav_p2_resolve4 tests/test_shell_body_nav.nim
nim check -d:noSignalHandler --threads:on src/ctf.nim
env -u WASMTIME_C_API nim check -d:noSignalHandler --threads:on src/ctf.nim
```

All four exit codes: `0`.

```text
[Suite] shell body immutable episode map
  ...
  [OK] invalid spawn fails the activation build
15/15 passed

[Suite] shell body seat navigation
  ...
  [OK] follower corridor, octants, and stuck state match stencil
20/20 passed

runtime-linked src/ctf.nim: [SuccessX]
runtime-stub src/ctf.nim: [SuccessX]
```

The three standalone Phase 1 post-change navigation laws remain deliberately
red and outside the shards until Phase 7, as ratified in D006. No existing
body-map or body-nav regression was introduced.

## Final full qualification

This was one uninterrupted invocation from committed tree `71e2d2d1`:

```sh
nim c -d:release --path:src \
  -o:/tmp/qualify_body_route_index_p2_resolve4_commit \
  tools/qualify_body_route_index.nim
/tmp/qualify_body_route_index_p2_resolve4_commit | \
  tee /tmp/p2_resolve4_commit_full.tsv
```

Compile exit code: `0`. Qualification exit code: `0`. All 66 required rows:

```text
map	size_px	nav_cells	walkable	rooms	chokes	portals	sides	dropped_chokes	max_room_degree	portal_field_cells	segments	crossings	fine_crossings	pocket_connectors	fine_points	fine_point_bytes	segment_cells	arcs	graph_components	standable_px	covered_px	uncovered_px	unreachable_components	unreachable_px	component_hash	retained_bytes	transient_bytes	body_map_ms	index_ms	activation_ratio
published:00:br-gen-20049	2271x1212	42733	33011	14	51	51	102	0	15	357834	516	51	1	2	13	52	25813	1032	1	2121275	2121090	0	1	185	0xe80a107d84d3a89f	1169511	299959	207.529	139.087	1.6702
published:01:br-gen-20184	2271x1212	42733	34053	20	50	48	96	0	18	433100	569	48	0	13	45	180	33442	1138	1	2180243	2180164	0	2	79	0xd07c393cc835d19d	1281761	243682	212.034	153.799	1.7253
published:02:br-gen-20708	2271x1212	42733	33213	17	46	46	92	0	15	289472	394	46	0	9	19	76	17973	788	1	2131392	2131392	0	0	0	0xc3e4ad4418278643	1066281	214748	198.437	124.986	1.6299
published:03:br-gen-20798	2271x1212	42733	33632	20	42	42	84	0	14	270633	332	42	0	6	13	52	17687	664	1	2159029	2159029	0	0	0	0x0aff4b9700bd2272	1045486	278166	203.095	121.779	1.5996
published:04:br-gen-20822	2271x1212	42733	34259	22	48	50	100	0	13	296091	423	50	0	3	6	24	17715	846	1	2199524	2193534	0	3	5990	0x3c3cd624e9d8af31	1077056	226884	212.321	125.820	1.5926
published:05:br-gen-20894	2271x1212	42733	32955	20	56	55	110	0	18	344199	533	55	0	12	28	112	25199	1066	1	2113656	2113656	0	0	0	0x569832a3dd0e5b1b	1154388	329559	203.163	134.711	1.6631
published:06:br-gen-20930	2271x1212	42733	32256	29	56	52	104	3	15	268226	385	52	0	9	20	80	19418	770	1	2069921	2047165	0	3	22756	0xd10eefa3778f98cc	1047007	230991	200.849	126.619	1.6304
published:07:br-gen-21170	2271x1212	42733	33498	22	56	55	110	1	17	386188	596	55	0	16	41	164	31264	1192	1	2152096	2143297	0	1	8799	0x3d9c56114820422e	1225269	214452	209.003	143.761	1.6878
published:08:br-gen-21378	2271x1212	42733	34529	26	57	57	114	0	22	415076	612	57	0	0	0	0	34609	1224	1	2219429	2215777	0	2	3652	0x422436dd866206ce	1271693	354349	209.048	155.858	1.7456
published:09:br-gen-21450	2271x1212	42733	34704	26	61	61	122	1	18	360826	635	61	1	10	42	168	26702	1270	2	2227852	2214303	0	1	13549	0x5601445c37f90466	1187963	341325	206.521	141.807	1.6866
published:10:br-gen-21686	2271x1212	42733	33990	23	59	58	116	0	19	323617	596	58	0	8	17	68	26305	1192	1	2185774	2182075	0	1	3699	0xd7342c98b25bfb4a	1144622	238576	202.704	132.448	1.6534
published:11:br-gen-21704	2271x1212	42733	34097	21	57	58	116	0	20	328382	593	58	1	8	20	80	26085	1186	1	2192696	2192696	0	0	0	0x43b376bd703068db	1148819	232064	313.978	133.182	1.4242
published:12:br-gen-21849	2271x1212	42733	33951	15	37	37	74	0	14	326726	324	37	0	0	0	0	18197	648	1	2179729	2179690	0	1	39	0xbc75bb358e1ae1cd	1104127	373478	220.985	133.112	1.6024
published:13:br-gen-21884	2271x1212	42733	33655	21	50	49	98	0	15	339602	487	49	1	16	41	164	23998	974	1	2162934	2162022	0	2	912	0x5f0c879fe37d9e31	1146079	303733	215.357	136.655	1.6345
published:14:br-gen-21944	2271x1212	42733	33827	22	58	57	114	0	16	387860	596	57	1	10	31	124	31721	1192	1	2171024	2171024	0	0	0	0xc5cec6bd44f15ed3	1229945	230288	211.953	161.793	1.7633
published:15:br-gen-22010	2271x1212	42733	34218	24	75	77	154	0	28	463714	1108	77	0	1	2	8	47346	2216	1	2199097	2199097	0	0	0	0x3d109279136c696e	1388715	203241	203.125	154.966	1.7629
published:16:br-gen-22178	2271x1212	42733	32278	26	55	52	104	3	14	327117	455	52	0	24	66	264	21151	910	1	2076619	2076507	0	1	112	0xbd0579adfbefadd4	1116050	232619	202.482	136.240	1.6728
published:17:br-gen-22338	2271x1212	42733	33660	26	46	43	86	2	11	238875	263	43	0	1	2	8	9462	526	1	2163636	2149721	0	2	13915	0xc4db4948c43c9300	978344	385873	203.562	117.681	1.5781
published:18:br-gen-22358	2271x1212	42733	33474	22	58	60	120	0	17	319738	615	60	0	11	25	100	26484	1230	1	2153408	2153408	0	0	0	0xeb4aae7960afa443	1140271	244829	206.147	132.218	1.6414
published:19:br-gen-22436	2271x1212	42733	33665	22	45	47	94	0	11	252404	349	47	0	9	28	112	13605	698	1	2159086	2135841	0	2	23245	0x0afac9fab4855d50	1012033	188700	200.931	117.970	1.5871
published:20:br-gen-22446	2271x1212	42733	34579	21	51	51	102	0	16	359235	497	51	0	0	0	0	23204	994	1	2220931	2220931	0	0	0	0xf63d9e5e2fcd49cc	1166012	290228	198.959	135.792	1.6825
published:21:br-gen-22508	2271x1212	42733	33672	25	69	67	134	0	16	295275	641	67	0	17	44	176	22154	1282	1	2163412	2144969	0	3	18443	0x1c74bf0e562a7238	1100784	170942	204.741	127.650	1.6235
published:22:br-gen-22527	2271x1212	42733	32173	16	42	40	80	1	15	303818	360	40	1	1	14	56	18135	720	1	2066646	2066636	0	1	10	0x042c537c08e71e67	1075367	309061	199.627	143.451	1.7186
published:23:br-gen-22548	2271x1212	42733	33873	27	42	39	78	3	14	326403	257	39	2	16	74	296	15577	514	1	2174329	2167851	0	1	6478	0x31a4a430ceeca77e	1091556	584970	203.942	140.882	1.6908
published:24:br-gen-22574	2271x1212	42733	34180	21	49	45	90	2	15	263565	340	45	0	3	7	28	13641	680	1	2194735	2194735	0	0	0	0xa79e66f4cc3925c0	1024722	314685	198.548	126.944	1.6394
published:25:br-gen-22650	2271x1212	42733	33752	33	61	59	118	0	11	258476	373	59	1	3	11	44	13481	746	1	2165860	2165138	0	2	722	0x1eafeb148a4a488d	1019145	219521	199.664	122.972	1.6159
published:26:br-gen-22772	2271x1212	42733	33423	26	50	50	100	0	16	305202	460	50	2	7	38	152	21105	920	1	2135975	2128046	0	3	7929	0x288de66698303745	1097987	269730	200.173	129.551	1.6472
published:27:br-gen-22850	2271x1212	42733	34147	14	31	32	64	0	17	390091	303	32	0	5	10	40	18836	606	1	2191277	2191277	0	0	0	0x7a941d38c61d46ba	1170068	556628	195.250	138.522	1.7095
published:28:br-gen-23168	2271x1212	42733	33199	14	42	41	82	2	18	389493	471	41	1	15	48	192	21865	942	1	2130903	2130761	0	2	142	0x865f2dcce153b998	1184650	436452	204.848	141.888	1.6927
published:29:br-gen-23312	2271x1212	42733	34781	19	72	72	144	0	20	484325	1005	72	0	9	20	80	45283	2010	1	2233585	2233585	0	0	0	0xf9060a1162a36776	1399698	335479	197.762	159.858	1.8083
published:30:br-gen-23355	2271x1212	42733	33283	13	41	41	82	1	13	273636	342	41	0	3	9	36	15519	684	1	2136556	2136556	0	0	0	0xa26e34241e05269f	1038569	280238	204.201	118.876	1.5822
published:31:br-gen-23424	2271x1212	42733	33660	25	43	42	84	1	13	305694	335	42	1	6	39	156	16069	670	1	2160183	2156657	0	3	3526	0x541c3e5c07ad8616	1074423	215377	200.479	126.153	1.6293
published:32:br-gen-23457	2271x1212	42733	33924	16	53	54	108	0	19	337291	569	54	0	0	0	0	27626	1138	1	2176866	2176866	0	0	0	0x6b701c3ea5fd6665	1161808	203500	199.030	130.069	1.6535
published:33:br-gen-23479	2271x1212	42733	32684	15	38	38	76	0	15	260116	298	38	0	2	4	16	15374	596	1	2100847	2100847	0	0	0	0x9694767fbf5d2c80	1020341	230806	200.818	118.657	1.5909
published:34:br-gen-23546	2271x1212	42733	33728	26	60	59	118	1	18	354549	586	59	0	0	0	0	26002	1172	1	2166633	2166605	0	1	28	0x8a43634892c80e16	1172678	219632	200.728	133.339	1.6643
published:35:br-gen-23660	2271x1212	42733	33276	22	53	53	106	0	21	354260	552	53	0	5	11	44	30392	1104	1	2133991	2133991	0	0	0	0x79dfe815037a0788	1186845	272024	199.074	134.701	1.6766
published:36:br-gen-23691	2271x1212	42733	32246	17	40	38	76	2	14	272780	290	38	1	10	29	116	15520	580	1	2070313	2070313	0	0	0	0xe3829dbf1cfa44fe	1031901	300773	205.976	122.132	1.5929
published:37:br-gen-23712	2271x1212	42733	33790	30	92	96	192	0	21	403527	1127	96	3	4	30	120	44018	2254	2	2173008	2166832	0	1	6176	0xc0014530c191324d	1315192	191327	205.762	142.762	1.6938
published:38:br-gen-23732	2271x1212	42733	34195	23	57	57	114	1	26	476871	689	57	0	8	21	84	39033	1378	1	2194190	2194163	0	1	27	0x932b3447ee255d98	1352928	399600	201.895	155.961	1.7725
published:39:br-gen-23829	2271x1212	42733	33807	13	38	38	76	0	14	344117	347	38	0	0	0	0	20057	694	1	2169924	2169924	0	0	0	0xcc9e7ec635a0dd17	1129234	310874	196.198	130.751	1.6664
published:40:br-gen-23894	2271x1212	42733	32366	20	46	47	94	0	20	393524	459	47	1	2	19	76	25406	918	1	2085091	2078631	0	1	6460	0x7cada8ecfa14a40e	1198857	465978	197.611	138.475	1.7007
published:41:br-gen-23942	2271x1212	42733	32961	30	62	59	118	1	17	314078	556	59	3	29	99	396	22793	1112	1	2114250	2114250	0	0	0	0x4765c83f37e6516d	1116511	195508	193.605	136.183	1.7034
published:42:br-gen-24008	2271x1212	42733	32801	23	44	45	90	0	14	241538	311	45	0	1	1	4	14296	622	1	2102483	2102483	0	0	0	0x8022d30ae28e137c	998683	208162	203.442	116.561	1.5729
published:43:br-gen-24030	2271x1212	42733	34157	28	55	52	104	1	17	308061	432	52	2	2	11	44	19391	864	1	2190995	2190989	0	3	6	0x2ddd2ea106bd5706	1095762	284863	202.809	129.308	1.6376
published:44:br-gen-24248	2271x1212	42733	33870	26	58	56	112	2	18	322005	519	56	0	13	35	140	24967	1038	1	2176031	2174511	0	1	1520	0x1998bca8d8b97dd0	1134562	219965	200.921	133.516	1.6645
published:45:br-gen-24288	2271x1212	42733	34755	23	51	53	106	0	17	364592	508	53	0	5	11	44	21255	1016	2	2234558	2217556	0	1	17002	0xc50e515f9ac08449	1164969	293817	202.449	137.354	1.6785
published:46:br-gen-24540	2271x1212	42733	32433	31	56	53	106	1	16	320625	428	53	1	8	32	128	20531	856	2	2081598	2067020	0	3	14578	0xebcedda554eb2c81	1106178	274762	206.506	128.973	1.6245
published:47:br-gen-24632	2271x1212	42733	34333	23	49	49	98	1	16	319101	413	49	0	12	28	112	19158	826	1	2207646	2207646	0	0	0	0x495d00ace942df71	1106102	264106	204.826	131.206	1.6406
published:48:br-gen-24678	2271x1212	42733	32441	27	55	53	106	2	14	287867	412	53	2	11	46	184	17906	824	1	2081090	2078923	0	2	2167	0x92ed7bb803362356	1062480	291720	205.768	191.328	1.9298
published:49:br-gen-24962	2271x1212	42733	34621	20	56	54	108	0	25	409266	718	54	0	5	10	40	35345	1436	1	2223174	2221654	0	1	1520	0x69f449131f5d8ed9	1273031	472157	201.945	152.455	1.7549
published:50:br-gen-24968	2271x1212	42733	33300	26	50	49	98	1	13	311844	392	49	1	16	56	224	18629	784	1	2140227	2138916	0	3	1311	0x4307c3ff0988f57d	1092089	210641	200.065	134.267	1.6711
published:51:br-gen-25118	2271x1212	42733	33875	20	49	49	98	0	16	305210	454	49	0	11	28	112	20010	908	2	2175135	2143301	0	1	31834	0x194247e2b1214d12	1095215	270618	205.665	127.973	1.6222
published:52:br-gen-25268	2271x1212	42733	33877	25	57	56	112	1	14	351176	499	56	1	5	18	72	21921	998	1	2180259	2180008	0	2	251	0xa2b409caeaa06e5d	1150545	309283	404.059	135.338	1.3349
published:53:br-gen-25466	2271x1212	42733	34140	23	50	50	100	0	13	292046	418	50	1	8	39	156	17397	836	1	2192135	2186845	0	2	5290	0x938d2cf3946879a2	1071371	238761	206.045	167.657	1.8137
published:54:br-gen-25706	2271x1212	42733	34521	20	51	49	98	3	14	328150	438	49	1	4	26	104	19112	876	1	2223816	2217844	0	1	5972	0x424d0b11e124042d	1116343	242905	224.695	131.478	1.5851
published:55:br-gen-25748	2271x1212	42733	33193	23	54	54	108	0	13	328897	469	54	0	4	10	40	24367	938	1	2135445	2135445	0	0	0	0xddb7fc8d91f29192	1134078	235024	205.374	132.014	1.6428
published:56:br-gen-25898	2271x1212	42733	34385	24	46	47	94	0	17	359350	477	47	0	4	8	32	22264	954	1	2205507	2192907	0	3	12600	0x7dce94956ea3b512	1160895	290561	211.068	136.689	1.6476
published:57:br-gen-25952	2271x1212	42733	33743	18	48	48	96	0	16	329280	485	48	1	6	16	64	21655	970	1	2168975	2168975	0	0	0	0x7b024c83830c6660	1126189	223147	205.139	132.130	1.6441
published:58:br-gen-26151	2271x1212	42733	32846	16	40	40	80	0	12	286437	297	40	0	0	0	0	17493	594	1	2107115	2107115	0	0	0	0xe827f335aedfbc64	1055758	315536	198.064	122.646	1.6192
published:59:br-gen-26174	2271x1212	42733	32673	21	46	48	96	0	14	318721	404	48	0	3	6	24	19201	808	1	2097915	2093497	0	2	4418	0xdca9a8a8040d8df4	1098514	259037	205.191	128.863	1.6280
published:60:br-gen-26258	2271x1212	42733	33069	27	68	68	136	1	17	332118	593	68	0	8	17	68	25325	1186	1	2125290	2125290	0	0	0	0xbb75b6112728cb0d	1145843	228105	204.124	133.788	1.6554
published:61:br-gen-26340	2271x1212	42733	32494	28	49	49	98	0	11	247679	335	49	0	11	18	72	14524	670	1	2081112	2077011	0	3	4101	0xdb53960fcf21ed2c	1005948	296481	202.817	137.864	1.6797
published:62:br-gen-26474	2271x1212	42733	34131	23	49	50	100	0	19	342947	464	50	0	7	16	64	23828	928	2	2192864	2166671	0	2	26193	0x762d278132aa5aa2	1149496	245088	210.116	136.362	1.6490
published:63:br-gen-26528	2271x1212	42733	32722	23	74	70	140	3	19	393415	811	70	0	22	64	256	34544	1622	1	2096765	2096453	0	2	312	0x7614b1b3da0519c0	1251148	250453	203.468	147.736	1.7261
arena	1235x659	12628	9172	35	90	92	184	0	11	74272	540	92	10	4	57	228	7886	1080	1	590595	590595	0	0	0	0xf73a8a02fc7ce24c	330420	91464	62.225	37.157	1.5971
size:colossal	4992x4992	389376	349201	209	1032	1031	2062	0	59	14159361	19006	1031	1	3	8	32	1340938	38012	1	22322852	22322828	0	24	24	0x7e16751ee2d0f28b	26709081	1912715	2806.360	3127.957	2.1146
```

Gate maxima:

- Pool activation: `1.9298x` on `published:48:br-gen-24678` (`<=2x`).
- Pool retained bytes: `1,399,698` on `published:29:br-gen-23312`
  (`<=16 MiB`).
- Pool transient bytes: `584,970` on `published:23:br-gen-22548`.
- Pool fine points: `99` and pocket connectors: `29`, both on
  `published:41:br-gen-23942`.
- Colossal activation: `2.1146x` (`<=3x`); retained bytes:
  `26,709,081` (`<=32 MiB`); transient bytes: `1,912,715`.
- Every row reports `uncovered_px = 0`.

The 64 px portal-cluster separation remains unchanged. The final pool maxima
are room degree 28 and 2,254 directed arcs, below the earlier census maxima
of degree 46 and 4,374 undirected intra-room pairs. Colossal is degree 59
versus census 55 and 38,012 directed arcs versus 27,460 directed intra-room
census arcs (1.38x, before accounting for crossing arcs), still below the
RESOLVE2 approximately-2x escalation threshold.

The performance evidence is local arm64/macOS development evidence, as Phase 2
requires. The implementation brief reserves canonical linux/amd64 Docker
performance gating for Phase 9; these numbers are not presented as that later
gate.

## Resumption merge and final Git state

At resumption, the WIP was stashed, `origin/main` at
`f374a18b2cffa6b1106c5ac3d81fd248018f378d` was merged as `dcd14d13`, and
the WIP was restored. The merge touched `src/shell/episode.nim` (56 additions,
6 deletions) and `src/ctf/server.nim`, but no `src/shell/body*.nim` file.
The final linked/stub checks above cover that incoming episode drift.

Final freshness/status commands:

```sh
git fetch --prune origin
git rev-list --left-right --count HEAD...origin/main
git status --short --branch
git log --oneline origin/main..HEAD
```

Exit code: `0`.

```text
10      0
## james/s2-nav-rework...origin/main [ahead 10]
71e2d2d1 shell: connect pixel-grid route pockets
dcd14d13 Merge remote-tracking branch 'origin/main' into james/s2-nav-rework
db22311b shell: scope route coverage to validator components
ebb0c525 shell: derive portals from coarse room boundaries
585ea565 shell: qualify fine route-index coverage
e8a7b75a shell: add shared body route index
24b05e1d shell: centralize body navigation legality
7e1364c0 test: compact shared-navigation route corpus
7f589dc2 test: pin shared-navigation liveness failures
f289a8ee test: freeze shared-navigation route corpus
```

The final repo worktree is clean. No push, PR, Asana mutation, GameVersion
change, fixture re-recording, or viewer rebuild was made.

## Final documentation audit

The required `audit-documentation` pass found no shipped documentation update
for this checkpoint. `BodyRouteIndex` remains an internal, not-yet-integrated
Phase 2 artifact; the approved plan explicitly reserves the public navigation
and design rewrite for Phase 10. The implementation's exported fine-anchor
accessors have local doc comments and regression coverage. This report and
`LEDGER.md` are the authoritative phase records.

> **Codebase friction: 3/5.** Exact `BodyMap` predicates and the exhaustive
> qualifier gave strong signal, but one physical pixel component could be
> split into several coarse route graphs. Proving and joining those fragments
> required tracing both representations and retaining fine anchors; the
> clearance field then supplied a clean proof that avoided enumerating safe
> cell interiors.
