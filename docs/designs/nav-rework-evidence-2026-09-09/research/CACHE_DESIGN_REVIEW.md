# CACHE_DESIGN_REVIEW: smallest measured shared source-visibility cache ablation

Peer (Claude) design review per `CACHE_DESIGN_REQUEST.md`. Documents only;
no source change. Evidence: the corrected real-trace results in
`cache-trace/CACHE_TRACE_RESULT.md` (revision 2), the replacement-policy
comparison in `cache-trace/policy_sim_results.txt` (`policy_sim.py`), and
the danger rebuild source at 3aeb0398 (`src/shell/body_nav.nim`). Sizes are
arithmetic from the source; hit rates are counts from the real traces; no
timing is predicted.

## 1. What is being cached, precisely

For one source at 8 px cell `o`, the rebuild does, in this order:

1. `nextVisitGeneration`; `addVisibleCell(o)`; for each perimeter offset,
   `castRay` which calls `addVisibleCell` at every step until a wall. Each
   `addVisibleCell` adds `kernel[(gy - o.y + r) * d + (gx - o.x + r)]` to
   `values[gy * W + gx]` at most once per source (stamp dedupe).
2. The close floor: for every cell in the square of `closeCells` around
   `o`, if the cell centre is within `closeRange` of the source's exact
   pixel, `values += 0.5`.

Then the next source. After all sources, one max pass.

The visible set `V(o)` (the cells that receive a kernel add for origin `o`)
depends only on `sightBlocked` (static map geometry), the perimeter and
radius (live range), and `o`. It does not depend on the seat, the tick, the
source's exact pixel, or the other sources. That is the cacheable object.
The close floor depends on the exact pixel and stays live and uncached.

## 2. Exactness: per-cell float order

Claim: replaying `V(o)` in any cell order gives the same raster as the ray
walk, provided sources are replayed in the same order and each source's
close floor follows its own kernel adds.

Proof. Fix a cell `c`. Across the rebuild, `values[c]` starts at 0 and
receives a sequence of float additions. Within source `s`, the stamp makes
the kernel add for `c` happen at most once, and the close floor add for `c`
happens at most once, after the kernel add (the close loop runs after the
ray loop within the same source iteration). Additions to different cells
are independent memory. So the sequence seen by `values[c]` is exactly
`[k_s(c)] [0.5]` per source `s` in source order, where each bracket is
present or absent. The order in which the ray walk visits other cells
during source `s` never changes when `c`'s own add happens relative to
`c`'s other adds. A replay that, for source `s`, applies `k_s(c)` for every
`c in V(o_s)` in row-major order and then the live close floor produces
the same per-cell sequence, so the same float result for every cell, and
therefore the same maximum and the same packed Q8 view. The proof does not
depend on the cell order within a source; it depends on (a) exactly-once
kernel adds per cell per source, (b) unchanged source order, (c) the close
floor of source `s` applied after source `s`'s kernel adds and before
source `s+1`'s. A replay must respect (b) and (c) and must not merge the
kernel adds of two sources or apply floors out of order.

`k_s(c)` is `kernel[offset(c, o_s)]`, computed from the cell and the
origin; the cache stores membership only, never kernel values, so a shared
kernel change (there is none; it is immutable per system) could not
desynchronise anything.

## 3. Entry representation and size bounds

Compared representations:

| representation | bytes per entry (radius 163) | notes |
|---|---:|---|
| list of int32 cell indices | up to 4 x |V(o)|, worst about 335 KB (disc of 83,655 cells clipped to 85,814) | size depends on visibility; needs a length; variable |
| list of uint32 box-local offsets | same bound | same problem |
| bitmap over the kernel box (327 x 327 bits) | 13,368 bytes fixed | replay scans 1,671 uint64 words; kernel index is the bit position; grid clipping applied at replay |

The bitmap wins on every axis that matters here: fixed size, no length
field, the bit index is already the kernel index, and replay is a
sequential scan with a per-set-bit kernel load and float add. Size is a
function of the live range only: `((2r + 1)^2 + 63) div 64 * 8` bytes,
13,368 at 1300 px (r = 163) and 912 at 331 px (r = 42). It is the same on
colossal and configured maps because the box is range-sized, not
map-sized. This meets "avoid map-sized per-seat retained arrays": the cache
is system-shared, per-entry range-sized, and its capacity is fixed.

Capacity: 64 entries. Ledger: 64 x 13,368 = 855,552 bytes of bitmaps plus
the slot table (64 x (key int32 + valid + lastUse uint64) about 1 KB). Well
under both the current 32 MiB shared cap and the permitted 64 MiB; it does
not need the raise. Memory is counted from `capacity` of the backing seq,
as in the existing ledger (`retainedNavigationBytes`), and added as a new
named field so G1 artifacts show it.

Hit-rate evidence for 64 (from the real traces, LRU-64, total ray steps
removable): 0.25 to 0.42 at 16 seats, 0.44 to 0.58 at 32 seats; unbounded
is within 0.03 of 64 in every run.

## 4. Bounded deterministic selection: reuse the duck-slot pattern

`body_cache.nim` already has the exact shape needed: a fixed
`array[N, Slot]` with `key`, `valid`, `value`, `lastUse` and a
monotonic `clock`, evicting the smallest `lastUse` (per-seat duck cache).
The proposal lifts that pattern to the nav system with N = 64, key = origin
cell index, value = the bitmap. Selection is deterministic because
requests arrive in seat-index order within a tick and the clock is a plain
counter. The `body_safety_query.nim` generation-stamped open-addressing
table is the other existing pattern; it is built for per-query scratch and
resets by generation, which is not what a cross-tick cache wants, so the
duck-slot shape fits better. No new abstraction: one object type, one
lookup proc, one insert proc, mirroring `duckFor`.

Replacement policy, measured on the real traces (`policy_sim_results.txt`):

| run | LRU 64 | FIFO 64 | FIFO 32 | direct-mapped 64 | direct 128 | direct 256 |
|---|---:|---:|---:|---:|---:|---:|
| s2_16_679962 | 0.399 | 0.399 | 0.393 | 0.362 | 0.362 | 0.368 |
| s2_16_679963 | 0.418 | 0.418 | 0.418 | 0.390 | 0.411 | 0.418 |
| s2_16_679964 | 0.418 | 0.418 | 0.411 | 0.373 | 0.395 | 0.410 |
| s2_16_679965 | 0.253 | 0.253 | 0.253 | 0.245 | 0.253 | 0.253 |
| s2_32_679962 | 0.502 | 0.479 | 0.425 | 0.421 | 0.455 | 0.469 |
| s2_32_679963 | 0.578 | 0.566 | 0.529 | 0.534 | 0.557 | 0.566 |
| s2_32_679964 | 0.450 | 0.421 | 0.363 | 0.359 | 0.397 | 0.415 |
| s2_32_679965 | 0.436 | 0.423 | 0.401 | 0.355 | 0.400 | 0.421 |

LRU-64 is the best or tied in every run; direct-mapped needs 256 slots to
approach it at 32 seats. A 64-slot linear scan for the key (64 int32
compares) is negligible against one source's 60,000 ray steps, so LRU-64
with linear key search is the recommended shape; no hash table.

## 5. Identity and invalidation

Key space is per nav system. The cache object is owned by `BodyNavSystem`,
constructed in `newBodyNavSystem` alongside `dangerGeometry`, so it is born
empty with the geometry it describes and dies with the system; a new
episode, map, or range creates a new system and therefore a new empty
cache. There is no invalidation path because nothing an entry depends on
can change during a system's life: `sightBlocked`, `perimeter`, `radius`
and `kernel` are immutable after construction (the `DangerGeometry` ref is
shared read-only by all seats). Seats, lives, activations and the L0/L1
logic do not touch it. A defensive check that the geometry ref in the cache
equals the seat's geometry ref costs one pointer compare per lookup and
makes the invariant visible in tests.

## 6. Miss and hit work

Miss (today's path plus recording): run the rays exactly as now; in the
first-visit branch of `addVisibleCell` (where the stamp is stored) also set
bit `(gy - o.y + r) * d + (gx - o.x + r)` in a scratch bitmap that was
cleared before the source. After the ray loop, copy the scratch bitmap into
the selected slot (13,368 bytes) and set the key. Extra work per miss: one
bitmap clear, one bit set per unique visible cell, one 13 KB copy. The ray
loop itself is unchanged, so a miss can never produce a different raster.

Hit: skip `nextVisitGeneration` and the rays entirely; for each set bit at
box position `(bx, by)`, compute `gx = o.x - r + bx`, `gy = o.y - r + by`,
skip if outside the grid, then `values[gy * W + gx] += kernel[by * d + bx]`.
No stamp compare or store. Then the live close floor as now. Per hit that
is one sequential 13 KB scan plus |V(o)| kernel loads and float adds,
against about 60,000 ray steps each carrying a wall test, a stamp load and
mostly a stamp store plus the same float add. The trace's steps count is
the exact number of removed loop iterations per hit; the number of float
adds is unchanged by construction.

Grid clipping on replay: the ray walk never adds out-of-grid cells
(`addVisibleCell` returns on bounds), and `sightCellBlocked` treats
out-of-grid as blocked so rays stop at the edge; the recorded bitmap
therefore contains only in-grid cells for that origin, and the replay
bounds check is redundant but harmless. Because entries are keyed by
origin cell, an entry is never replayed for a different origin, so the
clipping question does not arise across origins.

## 7. Proof tests

1. Exactness golden, all maps: for every pool, configured, and colossal
   map at 331 and 1300 px, drive a seat through a scripted source sequence
   that produces hits (repeat origins across seats and across rebuilds,
   including the same origin from two seats in one tick pair and an origin
   that returns after eviction) and compare `dangerSnapshot` bit-for-bit
   against a fresh cache-less system built with the same sequence. Also
   compare `dangerFingerprint` and the packed Q8 view.
2. Order independence witness: a map where two sources share visible
   cells; compare against the reference with sources in both orders;
   results must differ between orders (float non-associativity, when it
   does) exactly as the reference differs, proving the replay follows
   source order rather than being accidentally order-free.
3. Close floor exactness: two sources in the same 8 px cell with different
   exact pixels; the kernel part hits the cache, the floors must differ
   exactly as in the reference.
4. Eviction determinism: 65 distinct origins, then re-request the first;
   assert a miss, then re-request the second-oldest and assert a hit, and
   assert the slot table's keys equal the reference sequence (mirrors the
   existing `duckKeys` golden).
5. Identity: two nav systems on the same map at different ranges; the same
   origin must miss in each and never cross over; assert entry sizes differ
   (912 versus 13,368 bytes).
6. Ledger: assert the new field equals `capacity * entryBytes` exactly and
   that total retained bytes rise by only that amount on every map.
7. Counts, not static synthetic sources: build with a define-gated counter
   of hits and misses (or extend `DangerRebuild` with a hit count under the
   same define) and replay the real `navsrc.txt` source sequences through
   the public `rebuildDanger` API on the matching pool maps; the measured
   hit count must equal `cache_sim.py`'s LRU-64 hits for that trace. That
   ties the implementation to the real-trace evidence instead of a
   synthetic pattern.

## 8. Rollout on native hosts (root-owned runs)

- Frozen 331 px corpus map: exactness golden and ledger only; expected hit
  rate is not measured there (no real trace), so no timing claim from it.
- Configured 1300 px, brpool16 maps 5204, 5263, 5001: replay the real
  traces through the harness for hit counts (test 7), then paired
  parent/candidate danger-slice and whole-tick timing on m5a in the
  standard interleaved pairs, after V1 finishes with the host. Preregister:
  danger slice not slower on any pair; report removed ray steps as counted,
  not inferred.
- Colossal: exactness golden and ledger; the entry size is unchanged, so
  the only colossal-specific question is the cap ledger, which rises by
  about 0.86 MB.
- Report hit and miss counts from the runs themselves (define-gated
  counter), never from the simulator alone.

## 9. What this does not do

It does not reduce the per-source float adds, the close floor, the max
pass, or the packed publish; those are the same on a hit and a miss. It
removes ray iterations on hits only, at the measured rates above. It does
not touch selection, cadence, L0/L1, admission, or any cap. If the paired
timing shows no danger-slice improvement at those hit rates, the negative
is preserved and the shared-source direction closes.

CACHE DESIGN REVIEW DONE
