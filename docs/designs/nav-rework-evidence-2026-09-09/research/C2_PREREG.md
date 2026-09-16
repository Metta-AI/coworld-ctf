# C2 preregistration: shared source-visibility bitmap cache (isolated ablation)

Owner: peer (Claude), worktree `nav-source-cache`, branch `james/nav-source-cache`,
parent f9dff753 (A2; no V1/H1/A3). Root owns native timing and adoption.
Written before any source edit, per `CACHE_IMPL_REQUEST.md`.

## Hypothesis

A system-shared, 64-entry LRU of per-origin visibility bitmaps over the
kernel box removes the ray walk on repeated origins while producing
bit-identical rasters, packed weights, and corpus quality hashes. On the
real 16/32-seat baseline traces the LRU-64 model removed 0.25 to 0.58 of
ray-loop iterations (`cache-trace/CACHE_TRACE_RESULT.md` revision 2); the
implementation's hit counts on those same ordered source sequences must
reproduce the model's counts. Whether removed iterations become removed
milliseconds is root's native question; no speed is claimed here.

## Design as preregistered (corrections from the request applied)

- Entry: one bitmap of `(2r+1)^2` bits over the kernel box, stored as
  `uint64` words in one shared `seq[uint64]` of `64 * words` (no per-entry
  allocations). Words: `((2r+1)^2 + 63) div 64`. At r = 163 (1300 px):
  1,671 words = 13,368 bytes; at r = 42 (331 px): 113 words = 904 bytes.
- Key: origin 8 px cell index within the nav system's grid. The cache is
  constructed by `newBodyNavSystem` beside `DangerGeometry`, held by every
  seat as a separately named shared ref (`dangerSourceCache`), and dies
  with the system. No invalidation path: everything an entry depends on
  (`sightBlocked`, perimeter, radius, kernel, grid) is immutable for the
  system's life. `DangerGeometry` stays immutable.
- Selection: fixed 64 slots `(key, lastUse)`, linear key scan, victim =
  first empty slot else the smallest `lastUse` with the lowest slot index
  breaking ties, monotonic clock. Deterministic given the request order
  (seat index order within a tick). Pointer identity selects nothing.
- Miss: the victim slot is claimed, its words zeroed, and the unchanged
  production ray walk records each first-visit cell (the branch that stores
  the stamp) as one bit directly into the slot. No scratch, no copy. A
  partially filled slot is never observable: one source is built serially
  and the slot is only readable through the same seat-serial rebuild path.
- Hit: no `nextVisitGeneration`, no rays; scan the words, and for each set
  bit `k` add `kernel[k]` to `values[(o.y - r + k div d) * W + (o.x - r + k mod d)]`.
  No bounds check: recorded cells were in-grid for this exact origin and
  the key is the origin. No geometry pointer compare: ownership makes it
  an invariant, which the tests prove instead.
- Exact source order and per-source close floor interleaving are kept: for
  each source in order, kernel adds (rays or replay), then the live
  exact-pixel close floor. Only the cell order within one source's kernel
  adds may differ, which is exact because every cell receives at most one
  kernel add per source (stamp dedupe on a miss, bitmap uniqueness on a
  hit) and additions to distinct cells are independent; per-cell float
  sequences are identical, including any zero or signed-zero kernel
  values, because the replayed adds are the same adds.
- Ledger: new field `sharedDangerSourceCache` = `sizeof(cache[]) +
  bits.capacity * 8`, plus one allocator allowance for the seq, counted
  into `total`. Non-colossal shared retained bytes therefore rise by
  855,552 + object size + 16, under the current 32 MiB cap and needing no
  raise; the colossal 256 MiB total is unchanged in kind.
- Diagnostics: `-d:dangerSourceCacheCounters` exposes hit/miss counters;
  a public order accessor (keys by `lastUse`) mirrors `duckKeys` and costs
  nothing in production. A trace replay tool feeds recorded ordered source
  points into the selected-source seam via `include` of the module
  (private field access), clearly labelled diagnostic; it does not
  fabricate self positions or re-run selection.

## Measurements to preregister (root runs native; peer runs local counts)

1. Exactness: focused tests compare float bytes and packed weights of a
   cached system against a freshly built system (whose first rebuild is
   all misses through the unchanged ray code) after hit-producing
   sequences; corpus `--quality` must reproduce the frozen danger hashes
   and route hash (`ee2488d3...`) with 31,814,084 pops on the frozen
   331 px corpus.
2. Regimes, reported separately and never pooled: miss-only (every origin
   distinct), repeated-hit (static synthetic origins), and real-trace
   replay (the nine `navsrc.txt` sequences on their pool maps at 1300 px).
   The real-trace hit counts must equal `cache_sim.py` LRU-64 hits per
   trace. Static repeated synthetic hits alone do not justify adoption.
3. Ledger: activation report shows the new field exactly and totals rise
   by exactly that amount on every pool map, configured and colossal.
4. Native timing (root, after V1 releases m5a): paired parent/candidate
   danger-slice and whole-tick in the standard interleaved pairs at
   frozen 331 px and configured 1300 px; prediction: not slower in the
   miss-only regime, faster only in proportion to counted hits. A negative
   is preserved.

## Stop conditions

Any raster, packed-weight, or corpus hash difference rejects. Any
non-determinism of the slot order under a fixed sequence rejects. A ledger
total above the caps rejects.
