# WF0 implementation plan — not implemented

Parent: 067a4af2, after P1 and the main 3c127d1c merge. Preregister WF0 before editing. Preserve the parent body_nav source. The proof and 885 standalone differential trials are in DANGER_WAVEFRONT_REVIEW.md.

## Representation and construction

Use ordinary integer fields initially. Config validates only positive gunRange, so do not assume a fixed maximum radius or narrow coordinates based on the measured radius 163. Keep geometry under the shared immutable reference owner. Add relative-cell records `(point: BodyPoint, rangeStart, rangeCount: int)`, a flat array of inclusive ray-ID ranges `(first, last: int)`, and shell offsets. Variable-length ranges avoid assuming the observed maximum of two ranges holds for every input.

Allocate exact capacities. Count ray events by relative cell, prefix-sum those counts, then walk the rays again to fill a flat membership array in ray-ID order. Count contiguous ranges before allocating the final arrays. Emit cells by Manhattan shell: for each shell and x, use y = ±(shell - abs(x)) within the radius, emitting y = 0 once. Include an offset sentinel. Temporary arrays contribute activation time and transient memory; report both.

Sort ray IDs by angle using integer half-plane and cross-product comparisons with a deterministic coordinate tie-break. Do not use atan2, pointers or hash iteration. Preserve the original perimeter and kernel. A pure iterator can reproduce D0a's decision recurrence and emit both diagonal side cells before the target; use it in both construction passes.

## Runtime

Add a small per-seat `seq[uint64]` of active rays, allocated once and counted in dangerWorkspaces and allocator overhead. This fits the public seat.rebuildDanger interface. Keep the existing visited workspace for the initial ablation.

For each source, fill the active words, mask unused final bits, and add the origin as before. For each Manhattan shell, first clear memberships for blocked or out-of-grid cells, then add the unchanged kernel value once to each cell with an active member. Keep source order, the close-floor pass and the maximum scan unchanged. Inclusive-range clear/test helpers must avoid shifting by 64. Breaking after a shell when every active word is zero is exact. Keep compiler bounds and overflow checks.

## Memory and experiments

Count actual retained capacities. Ordinary integer layouts may add about 4 MiB at radius 163. The current configured shared maximum is 31,607,620 bytes, so 36 MiB (2.25x the original 16 MiB) may be needed. That is within James's permission, but change the current 32 MiB cap only when measured footprint justifies it. Give both timing arms the same cap. Preserve old failures; do not raise total/colossal limits or waive activation.

Counter-hypothesis: individual rays terminate quickly at real walls, while a naive wavefront may scan many inactive cells. Open-disc event counts do not establish a speedup. Run three paired m5a measurements and full m8i quality against the fresh 067 parent. Compare real-map rasters on all 76 maps at ranges 331 and 1300 through the public danger API, plus named same-shell side/target-wall cases. Preserve source and binary hashes. Reject and restore the parent if the candidate loses. No runtime flag, alternate visibility rule or new dependency.

## Prepared hosts

Both owned hosts have `~/coworld-nav-wavefront-20260909` at 067a4af2. The verified bundle SHA256 is `934cc4f4c01d20fab44eaa3994b349eb9da83555cd938d35d96ab0d21e5f44c5`. Use the runtime under `~/coworld-nav-throughput-20260909/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api`; the new worktrees have no separate runtime bundle.

Use `~/.local/bin/nimby` 0.1.26, pinned by the Dockerfile, and `~/.nimby/nim-2.2.6/bin/nim` for native ablations. Bundled Nimby 0.2.3 was the wrong executable and refused workspace setup; its failed logs are retained. Actual Docker Nim 2.2.4 qualification remains separate.
