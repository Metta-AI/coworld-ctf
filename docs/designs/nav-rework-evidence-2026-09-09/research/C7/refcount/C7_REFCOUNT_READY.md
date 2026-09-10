# C7_REFCOUNT_READY: per-cell reference ownership removed from addVisibleCell

Peer (Claude) per `C7_REFCOUNT_REVIEW.md`, in `nav-source-cache` only. The
C7 full v1 candidate, patch, readiness note and hashes are preserved under
`C7/full/v1/` and the v1 source under `refcount/snapshots/v1-body_nav.nim`.
No primary, cap, policy or native change; nothing committed.

## 1. The correction (`refcount/corrected-over-v1.patch`, 22 lines, `addVisibleCell` only)

v1 opened `let cache = seat.dangerSourceCache` in the first-visit path,
which under ORC is an owning `ref` alias created per nonzero first visit
and destroyed on every return. The corrected candidate reads the cache
through the seat field directly, as C2 did for its bitmap, keeping scalar
locals only (`slot`, the entry offset). Nothing else changed:
`replayVisibleCells` still takes its once-per-hit alias (separate
question, left alone), no pointers, casts, pragmas, lifetime helpers,
policy, capacity or cap changes. `corrected-over-parent.patch` (210 lines)
is the cumulative candidate over the frozen C2 parent.

## 2. Generated C proof (`refcount/local-mac/addVisibleCell_v1.c`, `addVisibleCell_corrected.c`)

Both snapshots were built through the harness with the native gate flags
(`-d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed
--stackTrace:on`) into separate nimcaches, and the `addVisibleCell`
function was extracted from the module's C file:

| snapshot | C lines | `eqcopy` calls | `eqdestroy` calls | `DangerSourceCache` locals |
|---|---:|---:|---:|---:|
| v1 | 131 | 1 | 4 | 1 |
| corrected | 118 | 0 | 0 | 0 |

v1's single `eqcopy` runs on every nonzero first visit and the four
`eqdestroy` calls cover the return paths (including already-visited,
out-of-grid and zero-weight returns, where the alias was created and
destroyed for nothing); the corrected function has no cache local, copy or
destroy at all. `nimIncRef` and `nimDecRefIsLast` do not appear in either
function body because they live inside the `eqcopy` and `eqdestroy`
bodies, as root's inspection noted.

## 3. Exactness (`refcount/local-mac/`)

Focused cache suite 10 of 10 (including the corrected 63-origin stale-slot
test), body nav rework 16 of 16, and the nine real-trace chains, hits and
misses identical to the C2 parent values. Rasters and counts are
preserved by construction: the change is the alias, not the arithmetic.

Environment note: this session's `SDKROOT` pointed at a nix Apple SDK
whose headers were not found by clang mid-session; the builds above were
run with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` for
the commands only. No system or repository setting was changed.

## 4. What this does and does not settle

- The v1 native result (m8i, 27 pairs, totals 1.48 to 1.67 of parent, all
  p95 worse) was measured with the per-cell ownership overhead in the miss
  loop. My earlier attribution of the local changing-source regression to
  streaming entry stores alone is therefore unsupported and is withdrawn
  to a hypothesis: the ownership copy and destroy per first visit is
  proven in the generated C, and its share of the slowdown is not yet
  measured. `C7_FULL_READY.md` section 4 should be read with that
  correction.
- Root's new C2-versus-corrected pairs decide; the target is no material
  miss regression with the trace benefit intact. If the corrected
  candidate still regresses misses, the remaining suspects are the entry
  stores themselves and the larger slot region, and C9's deferred
  materialization stays the counted alternative.

## 5. Freeze

`refcount/snapshots/{parent,v1,corrected}-body_nav.nim`, both patches,
the test file, `SHA256SUMS`, the C snippets, logs and chains. The tree's
`src/shell/body_nav.nim` is the corrected candidate (hash in
`SHA256SUMS`); reverting to v1 or parent is copying the respective
snapshot back.

C7 REFCOUNT READY
