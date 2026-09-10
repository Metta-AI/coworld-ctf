# Capacity audit: logical length versus allocated capacity in the retained ledgers

Written 2026-09-09 by Claude (peer) at Codex's request. Source review of the ledgers and of
every sequence they count, plus Nim 2.2.6 runtime source for the allocation rules. No source
edits. Companion to `MEMORY_SHARING_REVIEW.md` and Codex's
`GEOMETRY_ACCOUNTING_CORRECTION.md`.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. The rules that decide allocated size (Nim 2.2.6, ORC, `-d:useMalloc`)
- A `seq` payload is one allocation of `align(sizeof(NimSeqPayloadBase), elemAlign) +
  cap * elemSize` (`seqs_v2.nim:41-47`); the header holds `cap` (8 bytes). The ledgers'
  `SequenceAllocationOverhead = 16` covers that header plus a guess at malloc's chunk
  overhead; glibc malloc adds 8 to 16 bytes and rounds to 16, so 16 is approximately right
  per sequence, not exact.
- `newSeq[T](n)`: `cap == len == n` exactly.
- `add` on a full sequence: `newCap = max(resize(oldCap), len + addlen)` with
  `resize(old) = 4 if old <= 0; old * 2 if old < 65536; old + old div 2 otherwise`
  (`sysstr.nim:25-28`, the `resize` `seqs_v2` uses). So a sequence grown by `add` ends with
  capacity between `len` and about `2 * len` (below 65,536 elements) or `1.5 * len` (above),
  and `len` alone understates the allocation by up to that factor.
- Copy (`=copy`/`=dup`): `newSeqPayload(s.len, ...)` (`assign.nim:48`): a copy allocates
  exactly `len`. That is why the old per-seat geometry copies were exact-length while the
  original, grown by `add`, may carry slack; M1's shared `ref` retains the grown original.
- `capacity()` is exported from `system` (`seqs_v2.nim:188`), so a ledger can report the
  allocated size directly rather than infer it from `len`.

## 2. Every ledgered sequence, by construction

### `retainedNavigationBytes` (`body_nav.nim:155-205`)
| Field | Built by | Capacity vs len | Notes |
|---|---|---|---|
| `dangerGeometry.kernel` | `newSeq(diameter^2)` | exact | |
| `dangerGeometry.perimeter` | `add` per unique offset | **may exceed len** | 236 points at 331 px, 924 at 1,300; grown from 4 by doubling, so capacity is the next power-of-two-ish step: 256 at 331 (slack 20 x 16 B = 320 B), 1,024 at 1,300 (slack 100 x 16 B = 1,600 B). Before M1 each seat's copy was exact-length; after M1 the one shared original carries this slack. Small in absolute terms; the ledger should still say so |
| `seat.danger.values` | `newSeq(size)` | exact | per seat |
| `seat.dangerWorkspace.visited` | `newSeq(size)` | exact | per seat |
| `seat.packedWeights` | `newSeq(cellCount)` in the constructor and in `rebuildPackedWeights` on a length mismatch | exact | swapped with the scratch under L1; both exact |
| `packedWeightScratch` | `newSeq` | exact | |
| `dangerTrace` | `newSeq(traceCapacity)` | exact | |
| `seat.cache` | `new` + inline array | n/a | `sizeof` of the object; no seq inside `DuckSlot` today |

### `bodyMixedGraphBytes` (`body_route_query.nim:780-822`)
| Field | Built by | Capacity vs len |
|---|---|---|
| `legality.legal`, `legality.standable` | `newSeq` (116-117) | exact |
| `cellForNode`, `fineForCell`, `anchorForCell`, `anchorNode`, `wallBand`, `bridgeOffset`, `bridgeLen` | `newSeq` (243-249) | exact |
| `bridgeNodes` | `add path` per bridge (307) | **may exceed len**: this is the largest add-grown sequence in any ledger. Its final length is the sum of all bridge chain lengths (int32 each); grown from empty by doubling up to 65,536 elements then by 1.5x, so allocated capacity can be up to 1.5x (or 2x below 262 KB) of the counted bytes. On the giant maps, where `mixed_graph` is 28.3 MB and already over the pool cap, this is the one place where `len` accounting could materially understate the allocation; the exact figure needs `capacity()` |
| workspace `g`, `parent`, `parentBridge`, `goalCost`, `state`, `goalStamp`, `reconstruct` | `newSeq(count)` (525-531) | exact |
| queue `head`, `tail`, `touchedGeneration`, `next`, `previous`, `bucket`, `queuedF` | `newSeq` (533-539) | exact |

### `retainedIndexBytes` (`body_route_index.nim`, 19 sequences)
All 19 (`legalMoves`, `roomOf`, `localIndex`, `roomCellStart`, `roomCells`,
`roomSideStart`, `roomSides`, `sides`, `portalNext`, `segments`, `cells`, `arcStart`, `arcs`,
`sideComponent`, `cellComponent`, `pockets`, `pocketCells`, `fineAnchorStart`,
`fineAnchors`) are finalised by `newSeq` or `setLen` to a computed count; `index.cells` in
particular is `newSeq[int32](intraCells + crossingCells)` (1046), and the `add` calls found
by grep are on local `path.cells`/`result.cells` builders (411, 1357, 1361), not the retained
field. The ledger adds 16 bytes per non-empty sequence. `setLen` on an empty sequence
allocates exactly the requested capacity, so these are exact. Two of the following payloads
(`portalNext`, `cells`) are released by `releaseFollowingPayload` (`index.cells = @[]`, 1779),
after which they are empty and counted as zero: correct.

### `retainedBytes` for the hazard overlay and safe cache (`body_hazard.nim:55-73`)
`arrival`, `roomMaxArrival`, `segmentArrivalMin/Max`, `safeDistQ4`, `safeNext`, `roomHasDry`:
all `newSeq` to a computed count (103-104, 220-222 and the segment extrema builder). Exact.

### `safetyScratch.retainedBytes`
Not re-read line by line here; it is a fixed activation-sized scratch (`newBodySafetyScratch`)
and the same audit pattern applies. Flag for Codex's `capacity()` pass rather than assert.

## 3. What this changes about earlier claims
- Every "exact ledger" statement was exact only for `newSeq`-built sequences. Two ledgered
  sequences are `add`-grown: `dangerGeometry.perimeter` (negligible slack, and before M1 the
  per-seat copies were exact-length) and `mixedGraph.bridgeNodes` (potentially up to 1.5x to
  2x of its counted bytes). All 16 MiB pool and 256 MiB total verdicts so far rest on
  length-based counts for `bridgeNodes`; the true allocation is at least the counted figure,
  so passes are not proven and failures stand. This is the logical-versus-allocated
  distinction Codex asked to record.
- `rss_delta_bytes` in the activation row is the only allocation-level evidence in the
  current artifacts and it includes everything else in the process; it bounds but does not
  isolate.

## 4. Recommendation (for Codex; no edits by me)
1. Ledger from `capacity()`: in the three byte procs, replace `x.len * sizeof(T)` with
   `x.capacity * sizeof(T)` for every counted sequence (or report both as `logical_bytes` and
   `allocated_bytes`), and gate on allocated. For exact-built sequences the two are equal, so
   the only rows that move are `bridgeNodes` and `perimeter`.
2. Make the two `add`-grown sequences exact at the end of activation: `newSeqOfCap` with the
   final count when it is known in advance (the perimeter count is computable from the
   radius before the loop; the bridge total is not known until the walk), or copy into a
   fresh exact-length sequence once at the end of `newBodyMixedGraph` (one transient copy at
   activation, then the slack is freed). Both are exact behaviour changes only in memory.
3. Add a ledger self-test: for every counted sequence `capacity == len` after activation,
   which fails loudly if a future change introduces an `add`-grown retained sequence.
4. Until 1 is in, label the M1 and later activation rows "logical bytes; `bridgeNodes` and
   `perimeter` allocation may exceed by up to 2x of their own counted size" rather than
   "exact".
