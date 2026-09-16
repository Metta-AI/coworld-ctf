# C7_FULL_READY: 64-slot ray-order list cache, isolated full candidate

Peer (Claude) per `C7_IMPLEMENT_REVIEW.md`, in `nav-source-cache` only.
All prior snapshots were preserved first (`C7/full/baseline/`: the screen
source with the C6/C8 arms, tests and tools; the C2, C8 and C7 v2
snapshots are untouched in their folders). No primary source, cap
constant, or native change; nothing committed. Root owns both hosts and
the integrated ledger.

## 1. The candidate (`full/snapshots/candidate-body_nav.nim`, `full/C7-candidate-over-parent.patch`, 206 lines)

Parent is `full/snapshots/parent-body_nav.nim`, byte-identical to the C8
parent (frozen C2 plus inert C5 markers, no C3, C6 or C8 arms). The
candidate contains no experimental booldefines (verified by grep) and
changes only the cache representation:

- `DangerSourceEntry` (`gridIndex: int32, weight: float32`, 8 bytes, no
  padding) and `DangerSourceCacheSlot` (`key: int32, length: int32,
  lastUse: uint64`, 16 bytes, no padding). One system-owned
  `seq[DangerSourceEntry]` of `64 * capacity` replaces the bitmap seq
  directly; the same ref is held by every seat; `capacity` is the count
  of nonzero cells of the actual kernel at cache creation (5,385 at 331
  px, 54,173 at any range of 1050 px or more). No observed-max bound and
  no overflow rule: a source can first-visit each kernel index at most
  once (visit stamps) and zero-weight cells are never recorded, so a slot
  can never exceed its capacity; the capacity-exact test below fills one
  to exactly that length.
- Miss: victim slot claimed with `length = 0`; the unchanged ray walk's
  first-visit branch keeps its stamp, loads the weight, returns if it is
  exactly zero (the C8 identity, proven in `C8_ZERO_REVIEW.md`), otherwise
  appends `(index, weight)` at `slot * capacity + length` and adds that
  same weight. Ray order is therefore the recorded order.
- Hit: replay the slot's `length` entries in order, one add each.
- Unchanged: key and LRU policy (64 slots, `sourceCacheSlot`,
  `sourceCacheVictim`), source order, the exact-pixel close floor, ray
  traversal and perimeter, visit-generation semantics, publishing, and
  the C5 markers (`danger.hit.replay`, `danger.miss.rays`).
- Ledger: `sharedDangerSourceCache = sizeof(cache[]) + entries.capacity *
  8`, plus the one existing seq allowance; pool cap constants untouched.
- Diagnostics: `dangerSourceCacheCapacity`, `dangerSourceCacheLengths`
  (per-slot lengths in LRU order) added beside the existing order and
  entry-bytes accessors; counters stay behind the existing define.

## 2. Exactness (`full/local-mac/`)

- Focused cache suite 10 of 10: the seven C2 tests with their entry-size
  assertions updated to the measured representation (capacity times 8
  bytes: 43,080 at 331 px, 433,384 at 1300 px) without weakening the
  raster and LRU checks, plus three list-risk tests: an all-visible
  source on a 2800 by 2800 px open map fills a slot to exactly 54,173
  entries and replays bit-exactly; the stale-entry test (corrected per
  `C7_FULL_ROOT_NOTES.md`) fills one slot with a long list, adds 63 other
  unique origins so the cache is full with the long source least recently
  used, asserts the long key is still cached and first in LRU order,
  misses on a short source and asserts the long key is gone with the
  cache still full, so the short list overwrote exactly the long slot
  whose length was measured; the following hit replays only the shorter
  list and matches an independent uncached raster; corner and edge
  origins at 331, 1050, 1300
  and 1600 px map every entry to the right cell on both the recording
  miss and the replaying hit.
- Body nav rework suite 16 of 16.
- Nine real source traces through the counted replay tool: input
  sequence, hits, misses, per-rebuild raster mismatches (0) and the
  raster chain hashes identical to the C2 parent values recorded in
  `C2/replay_results.txt`.
- Primary multi-range border test: covered by the new border test above;
  the byte-stamp rollover test is not applicable to this isolated
  uint32-stamp parent and was not copied. Primary tests are unchanged.

## 3. Capacity ledger across ranges (`full/local-mac/ledger.txt`)

| range px | capacity | entry bytes per slot | `sharedDangerSourceCache` |
|---:|---:|---:|---:|
| 331 | 5,385 | 43,080 | 2,758,176 |
| 1050 | 54,173 | 433,384 | 27,737,632 |
| 1300 | 54,173 | 433,384 | 27,737,632 |
| 1600 | 54,173 | 433,384 | 27,737,632 |

Object 1,056 bytes; the figures match `C7_MEMORY_REVIEW.md` within its
32-byte metadata estimate. Against the integrated ledgers that review
substituted, the configured 1300 px shared bound is 59.35 MB (7.4 MiB
under the authorized 64 MiB, 25.8 MB over the current 32 MiB) and the
conservative colossal total 257.2 MB; the exact 76-row ledger is root's
integrated step.

## 4. Regime diagnostics (`tools/bench_danger_regimes.nim`, Mac, informational, three rounds)

16 seats, cadence 32, 640 ticks, 1300 px, full scheduled rebuilds with
hashes outside timing; fingerprint chains identical between arms in every
cell.

| map | regime | scheduled visits | hits / misses | parent ns per tick | candidate ns per tick | ratio |
|---|---|---:|---|---:|---:|---:|
| br-gen-5001 | changing_sources | 320 | 464 / 2096 | 3,219,678 | 4,059,494 | 1.261 |
| br-gen-5001 | repeated_sources | 320 | 120 / 8 | 49,997 | 27,243 | 0.545 |
| br-gen-5204 | changing_sources | 320 | 464 / 2096 | 3,080,903 | 4,029,029 | 1.308 |
| br-gen-5204 | repeated_sources | 320 | 120 / 8 | 54,194 | 27,708 | 0.511 |
| br-gen-5263 | changing_sources | 320 | 464 / 2096 | 2,960,242 | 3,812,144 | 1.288 |
| br-gen-5263 | repeated_sources | 320 | 120 / 8 | 47,105 | 25,296 | 0.537 |

Two results, both to be taken to native before any conclusion:

- Repeated sources (94 percent hits): the candidate roughly halves the
  per-tick cost, consistent with the C7 v2 micro.
- Changing sources (82 percent misses): the candidate is 26 to 31 percent
  slower per tick on this host. This is the miss-path recording cost the
  review predicted might appear: each first-visited nonzero cell now
  writes an 8-byte entry into a 433 KB slot region instead of one bit in a
  13 KB word array, and the miss ray walk is the dominant cost of this
  regime. It is a negative row and is reported as such. On the real
  traces (25 to 58 percent hits) the net effect depends on the mix and on
  how the native host prices streaming 8-byte stores against the bitmap's
  L1-resident read-modify-writes; the Mac numbers do not settle it.

If the native changing-source or trace-total rows confirm the miss
regression, the representation as implemented fails the preregistered
"no material miss regression" gate. One exact alternative worth a
separate arm in that case, not implemented here: keep C2's bitmap
recording on misses (13 KB per source) and materialize a slot's list on
its first hit from the bitmap in one row-major pass, so misses cost
exactly C2 and only repeat hits pay for and profit from the list; whether
that wins depends on how many keys are hit more than once (the trace
model's distinct-key counts say many keys are hit only once).

## 4a. Freeze corrections per `C7_FULL_ROOT_NOTES.md`

- The `addVisibleCell` comment now says "zero kernel weight, i.e. beyond
  min(live range, DangerLosRangePx)" rather than "beyond 1050 px", which
  was wrong at 331 px. Comment-only change; the focused suite was rerun
  (10 of 10) and the candidate snapshot, patch and hashes were refrozen.
- Allowance: the isolated C2 parent omitted the 16-byte owner allocation
  allowance for the cache seq, so this tree's ledger figures above omit
  it too; root's integrated source already includes that allowance and
  preserves it on application. The ledger line in the candidate adds the
  seq allowance the same way the parent did; nothing here changes that
  accounting.
- Tools actually needed from `full/baseline/` and the tree for this unit:
  `tools/replay_danger_source_trace.nim` and
  `src/shell/body_nav_source_trace_replay.nim` (nine-trace chains),
  `tools/bench_danger_regimes.nim` (new, regime diagnostic),
  `tools/bench_body_nav_rework.nim` (harness with the C2 ledger fields).
  The C6 and C7 v2 screen tools (`bench_danger_replay`,
  `check_danger_fullword_replay`, `bench_danger_list_replay`,
  `check_danger_list_capture`) belong to closed or completed screens and
  are archived under `C6/tools/` and `C7/tools/`; they read the removed
  bitmap fields and are not part of this candidate. Unrelated repository
  tools copied into `full/baseline/` can be excluded from the evidence
  commit.
- Both-host v2 micro passed per `C7_NATIVE_MICRO_REPORT.md`; A7 failed the
  5 percent both-host threshold and stays unintegrated; primary remains C2.

## 5. Root's native gate, restated

Three interleaved trace and regime pairs on both hosts, unprofiled full
quality on the old hash, then the integrated 76-row memory and whole-body
runs. Success needs an actual trace total benefit, no material miss
regression, and exact outputs; the micro and the repeated-source rows are
not sufficient, and the changing-source rows above are the risk.

## 6. Cleanup and ownership

Tree state: candidate `src/shell/body_nav.nim` (no defines), updated
focused test file, the trace replay tool unchanged, C6 and C7 screen tools
still present but not building against the list representation (they read
the removed bitmap fields; they belong to closed screens and are archived),
the new regime tool. Reverting to the parent is copying
`full/snapshots/parent-body_nav.nim` back and restoring the baseline test
file. `tmp/c7full/` holds the raw local outputs (copied to `full/local-mac/`).

C7 FULL READY
