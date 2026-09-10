# V1_REVIEW: byte visit generations for the danger raster workspace

Root follow-up: this preregistration review predates the mutation check. Constant-source repetition did not detect a missing clear; V1_REPORT.md and the final separated-region test supersede that proposed test. dangerFingerprint includes dangerTick as well as values; compare at identical ticks or compare raster bytes directly.

Peer (Claude) review of `V1_REVIEW_REQUEST.md`. Documents only, no source
edit, no speed claim. Source read at 3aeb0398 (`src/shell/body_nav.nim`).
Counts come from the real-episode traces in the trace worktree
(`cache-trace/runs/*/navsrc.txt`) and from the source.

## 1. What the stamp does today

`DangerWorkspace` holds `visited: seq[uint32]` and `visitGeneration: uint32`
(lines 33 to 35). `rebuildDangerFromPoints` calls `nextVisitGeneration` once
per source (line 464); `addVisibleCell` skips a cell whose stamp equals the
current generation and otherwise stamps it and adds the kernel value once
(lines 399 to 407). `nextVisitGeneration` (line 384) clears the whole array
and restarts at 1 when the generation equals `high(uint32)`, otherwise
increments. The invariant the raster depends on is: within one source, a
cell is added at most once; across sources, every cell is addable again.
That holds if and only if no cell carries a stale stamp equal to the
current generation. The full clear at rollover is what guarantees it, and
the generation restarts at 1 (never 0) so cleared cells can never alias.

## 2. Exactness of the uint8 candidate

Changing both fields to `uint8` and the rollover test to `high(uint8)` keeps
the invariant for the same reason: the clear happens before generation 1 is
reused, and between clears the generation strictly increases from 1 to 255,
so no live stamp can equal the current generation unless it was written in
the current source. The comparison, the store, the bounds check, the kernel
index arithmetic, the float add, and the ray control flow are untouched, so
the visited set per source and the order of float additions are identical.
The raster, `dangerFingerprint` (which hashes `dangerTick` and the values
only, not the stamps), the packed Q8 view, and L0/L1 behaviour are
therefore bit-identical for every input. No prior note in the research
folder proposes or rejects narrower stamps; the earlier references
(`CAPACITY_AUDIT.md`, `G1_REVIEW.md`, `MEMORY_SHARING_REVIEW.md`) only
account the array's size, 343 KB per configured seat at 4 bytes per cell.

Two source facts that must move with the change:

- The ledger multiplies capacity by `sizeof(uint32)` (line 197). It must
  become `sizeof(uint8)` (or the element type), otherwise the retained
  ledger, the G1 artifact fields `danger_workspaces`, and the shared-cap
  reports would overstate by 4x. `initDanger` (line 245) allocates with the
  explicit `uint32` type and changes with it.
- `resetNavigationLife` (line 357) does not touch `visited`,
  `visitGeneration`, or the raster; neither does `setSeatActive`. Lives and
  activations therefore never reset the stamp, the generation runs
  monotonically for the seat's whole nav-system lifetime, and a new nav
  system (each episode) starts from zeroed stamps and generation 0. The
  candidate changes nothing here; it only shortens the period between
  clears.

Generated C. The stamp compare becomes a byte load and compare; the store a
byte store. The rollover loop is an idiomatic zero-fill over a `seq`; with
`-d:release` the C compiler is expected to lower it to `memset`, but the
only nimcache I could inspect is a debug test build with line tracing, so
that is an expectation to confirm on the release nimcache, not a verified
fact. Nim unsigned `inc` wraps silently, so the explicit `== high(uint8)`
test is what prevents a wrap to 0 and must stay. The `visited[index] ==
visitGeneration` compare between two `uint8` values has no promotion
surprise in C (both promote to `int` identically).

## 3. Clear frequency, counted, and its tail cost

A clear happens once per 255 sources per seat (generation 1 to 255, then
clear). Counted from the real episodes (per-seat source lookups over a whole
episode, from the trace's `rays` lines):

| run | ticks | max sources per seat | seats over 255 |
|---|---:|---:|---:|
| s2_16_679962 | 2023 | 36 | 0 |
| s2_16_679963 | 2151 | 19 | 0 |
| s2_16_679964 | 2124 | 33 | 0 |
| s2_16_679965 | 3277 | 25 | 0 |
| s2_32_679962 | 2331 | 56 | 0 |
| s2_32_679963 | 2357 | 75 | 0 |
| s2_32_679964 | 3088 | 50 | 0 |
| s2_32_679965 | 3289 | 61 | 0 |

No seat would have crossed a single uint8 wrap in any real baseline
episode; the busiest seat reached 75 sources. The wrap is therefore a
harness and adversarial concern, not a live-play cost, on this workload.

Worst case is the harness cadence the request names: 8 sources every 32
ticks per seat is 8 generations per 32 ticks, so a clear every 1,020 ticks
per seat, about 3 per seat over a 3,072-tick run and about 10 over a
10,000-tick episode. Each clear writes the whole byte array once: 85,814
bytes on the configured 401 by 214 grid, about 405,000 bytes per seat on
colossal if root's 37 MiB figure (3 bytes saved times 32 seats) is taken at
face value; that grid size is implied, not verified here. For comparison
one source costs about 60,000 ray-loop iterations, each with a stamp load
and most with a stamp store plus a float add, so a clear is on the order of
one to seven sources' worth of byte stores and lands once per 255 sources.
Count-wise the tail cost is below 3 percent of the stamp traffic it
replaces; whether it shows in a tick is a timing question. The clear is
also a straight sequential store, the friendliest pattern for the same L2
argument. The uint32 code clears once per 4.29 billion sources, which is
never; that difference is the whole trade.

## 4. Working-set arithmetic (size only, not attribution)

Per source, the rays reach the whole disc of radius 163 cells, which on the
configured grid is nearly the whole array, so the touched set per source is
close to the full arrays:

| array | configured bytes today | with uint8 stamps |
|---|---:|---:|
| `danger.values` (float32) | 343,256 | 343,256 |
| `visited` | 343,256 | 85,814 |
| `sightBlocked` (shared bool) | 85,814 | 85,814 |
| `kernel` (shared float32, 327 by 327) | 427,716 | 427,716 |
| total | 1,200,042 | 942,600 |

The candidate removes 257 KB from a roughly 1.2 MB per-source working set.
That is still above a 512 KiB Zen1 L2 even before `packedWeights` and the
seat's other state, so the request's phrase "fits closer to" is the right
one and "fits" would be wrong. The kernel alone is larger than the saving.
The size change is real and exact; whether it changes the danger slice's
timing is exactly what a paired m5a run would decide, and this review makes
no prediction. A later ablation that also narrows the kernel (for example
float16 or Q8 kernel values, a separate exactness question) would be the
next size lever if V1 measures positive; uint16 stamps are a fallback only
if the clear tail turns out visible, which the counts above make unlikely.

## 5. Regression design: cross real wraps through the public API

The unit tests never wrap today because the uint32 rollover is unreachable.
With uint8 a test can cross wraps quickly, and it should be written so that
a missing or wrong clear is detected, not merely survived:

- Build a small `BodyMap` (a few rooms, some walls) and a `BodyNavSystem`
  with one seat at a short live range (`liveGunRangePx` 64, radius 8) so
  each source is cheap. Use only public entry points: `rebuildDanger*`
  (seat, map, input, tick), `dangerSnapshot*`, `dangerFingerprint*`.
- Reference oracle: a second, freshly constructed system whose seat is
  rebuilt once with the same input. Because a fresh seat has zero stamps
  and generation 0, its raster is the ground truth for that input.
- Drive the first seat through at least 600 sources total (for example 75
  rebuilds of 8 sources), which crosses the 255 boundary twice. Use the
  same eight source points on every rebuild: a stale stamp that survives a
  broken clear then equals the reused generation for exactly the cells
  those sources touch, so the kernel add is wrongly skipped and the
  snapshot differs from the oracle. Compare `dangerSnapshot` and
  `dangerFingerprint` against the oracle after every rebuild, and
  specifically at rebuild indices whose cumulative source count is 255,
  256, 510 and 511.
- Add one rebuild with zero sources and one with a single source between
  wraps to check that the generation still advances per source, not per
  rebuild, and that the close floor pass (which does not use stamps) is
  unaffected.
- Keep the existing "scheduled danger reordering preserves exact packed
  costs" and L0/L1 goldens as they are; they cover the packed path.

This test is independent of timing and runs in milliseconds; it belongs in
`tests/test_shell_body_nav_rework.nim` beside the danger tests.

## 6. Recommendation and bounded preregistration

Recommend proceeding to an isolated measured ablation, not to adoption.

- Change: `visited: seq[uint8]`, `visitGeneration: uint8`, rollover test on
  `high(uint8)`, `initDanger` element type, ledger `sizeof` at line 197.
  Nothing else. No new abstraction: the existing stamp pattern in this file
  and the `uint32` generation stamps in `body_route_index.nim:149` and
  `body_safety_query.nim:25` stay as they are; they have different reset
  paths and are out of scope.
- Exactness gate first: the wrap-crossing regression above, the existing
  danger goldens, and a full-corpus raster fingerprint comparison parent
  versus candidate (every map, the 32-tick cadence, 8 sources, at least
  1,020 ticks so every seat clears at least once). Any fingerprint
  difference rejects.
- Ledger gate: retained bytes must drop by exactly 3 bytes per cell per
  seat and by nothing else; report the new G1 configured and colossal
  ledgers.
- Timing (root's remote queue only, after A3 and H1 free the hosts): paired
  parent/candidate danger-slice and whole-tick measurements on m5a at the
  configured map and range, with the standard repeat pairs. Prediction to
  register: the danger slice does not get slower; any improvement is
  attributed to nothing until a cache-miss counter or a colossal contrast
  says otherwise. Accept only if quality, determinism and ledgers are
  exact; report the timing outcome whether positive or negative.
- Non-goals: no change to the raster type, kernel, ray order, cadence,
  or clear algorithm; no uint16 variant unless the clear tail is measured.

V1 REVIEW DONE
