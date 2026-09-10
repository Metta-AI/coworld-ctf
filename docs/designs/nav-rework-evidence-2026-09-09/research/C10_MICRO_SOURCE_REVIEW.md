# C10 three-arm micro: bounded source review

Reviewed, read only, at the frozen hashes in `C10/frozen-input-hashes.txt`
(`c10_replay.nim` 1f9686bc, `check_c10_replay.nim` 0f5bce2d,
`bench_c10_replay.nim` f0c41f43, `run_native.sh` 34374aac,
`parent-body_nav.nim` a0200d40, `base-body_nav.nim` 70472dbf), plus
`C10_MICRO_DECISION.md`, `C10_MICRO_READY.md` and `correctness-v3.json`.
The frozen copies are byte identical to the live nav-deferred-cache tools;
the parent snapshot is byte identical to the live primary `body_nav.nim`
(retained C2 plus V1); the base snapshot differs from the parent only by
the V1/C2 history the runner overlays. No source is changed by this
review; nothing else was examined.

## 1. Verdict

No blocking defect. The two grouped arms are fair to each other, the
safety predicate precedes every unchecked access, the boundary fallback
is checked, exactness holds by construction and is tested against the
scalar per-bit reference on crafted, border and real-map rasters, and the
runner is consistent with the decision. Three non-blocking items follow
in section 5; one of them (the exact statistic for the selection rule)
should be written down before the first timing, as a wording fix to the
decision, not to the tools.

## 2. Helper (`c10_replay.nim`)

- Group selection: `shift = ctz(word) and not 3` is the aligned nibble
  holding the lowest set bit; `k = wordIndex * 64 + shift`; lane i is
  kernel index `k + i` and map cell `gx + i` on the same kernel row and
  map row when the predicate holds. The word is cleared with
  `word and not (15 shl shift)`, so each group is visited once.
- Safety predicate `k + 3 < kernelLen and kx + 3 < diameter and gx >= 0
  and gx + 3 < width and gy >= 0 and gy < height` is evaluated before any
  access through `values` or `kernel`. Those pointers are taken once from
  `addr seat.danger.values[0]` and `unsafeAddr kernel[0]` (both
  bounds-checked at that point); the sequences are not resized during the
  call, so the pointers stay valid. Width, height and kernel length are
  hoisted once. This is the "safety before pointer access" requirement
  met.
- Both grouped paths share everything up to and including the predicate;
  they differ only inside the safe branch. Scalar: four guarded lane
  adds through the hoisted pointers, no division, no bounds checks.
  SIMD: two unaligned loads, one packed add, and either a plain store
  (nibble 15) or `(mask and updated) or (not mask and before)` on SSE2,
  `vbslq_f32` on NEON. The mask is loaded as integers and bit-cast, so no
  float load of a NaN pattern. Inactive lanes are stored back with their
  original bits, negative zero included; nothing outside the four cells
  of the group is read or written.
- Boundary fallback (predicate false) iterates the set lanes of the
  nibble, recomputes the kernel row per lane (a boundary group can
  straddle rows) and uses the original checked sequence indexing. Correct
  and deliberately unchanged from C2's arithmetic.
- Exactness: each visible cell still receives exactly one addition per
  source; groups are processed in ascending index order; lane order inside
  a group is irrelevant because cells are independent. No reassociation,
  no FMA, no fast-math flags in the runner.
- Ownership: the only reference copy is `let cache = seat.dangerSourceCache`
  once per call, exactly what the parent `replayVisibleCells` does, so
  the per-call cost is symmetric. No per-cell owner local, no sequence
  copy.
- `vectorized: static bool` instantiates two procs; the bench selects one
  per binary through the strdefine, so each timed binary carries its own
  path only.

## 3. Correctness tool (`check_c10_replay.nim`)

- Five crafted geometries (diameter 27 with row-crossing full words;
  diameter 327 with a straddling full word, mixed dense rows, all
  visible) now run both arms: SIMD is counted into the JSON row, the
  raster is reset to the same alternating negative-zero pattern, and the
  scalar arm is asserted cell for cell against the same reference. The
  padding invariant and "every set bit lands on its own cell" checks are
  kept. `correctness-v3.json`: five rows, zero mismatches at 104 and 1300
  px.
- Border sweep: a 25 by 25 cell open map, eight origins (four corners,
  four side midpoints), all 16 nibble patterns applied by `k mod 4`, at
  104 and 1300 px, so the box exceeds the grid on every side and both the
  safe path and every fallback condition run with every mask. Reference
  and raster start from the same alternating negative-zero / nonzero
  pattern; SIMD then scalar are each compared bitwise. 256 cases, all
  pass. This is the addition the plan and the decision required.
- The final loop asserts zero SIMD mismatches for every crafted row, so a
  failure aborts the runner before any timing (exit status under `set -e`).

## 4. Bench and runner (`bench_c10_replay.nim`, `run_native.sh`)

- Arm selection is compile-time by `DangerReplayArmLabel` (parent calls
  the production `replayVisibleCells`; scalar and simd call the helper with
  the static flag). Everything else in the timed loop is identical across
  arms: same 64 even-spread origins chosen outside timing (v2 sampling),
  same warm misses outside timing, same batch structure (untimed clear,
  timed `repeats` times 64 replays, untimed hash), same `map.cellOf` and
  base lookup per call, no clocks inside replay, no counters.
- Before the first clock each process replays every origin on a zero
  raster and compares all cells bitwise to the per-bit reference, with a
  `doAssert` on zero mismatches; this is the real-map check the decision
  requires, run for every arm, map, range and repeat.
- Runner: verifies the tree is clean and the tools absent, snapshots the
  original source and compares it to the base snapshot, overlays the
  parent (C2 plus V1), restores on exit, records commit, overlay patch,
  lscpu, input hashes, Nim version and executable hashes; builds the
  check once and runs it pinned before building the three arms; five
  repeats with rotated arm order (each arm occupies each position at
  least once), three maps, both ranges, stride 97, five batches, four
  repeats, CPU 5, one fresh process per cell. Consistent with the
  decision's "five interleaved process triples, five batches, four
  repeats, 64 origins".

## 5. Non-blocking items

1. Statistic for the selection rule, to be fixed in writing before the
   launch: per host, map and range, pair the three arms by repeat index,
   take each arm's `per_replay_ns_median`, form the ratios arm/parent and
   simd/scalar per repeat, and use the median of the five ratios. "Clears
   the 20 percent / 1 percent control screen" then reads arm/parent at
   most 0.80 on each 1300 px map and at most 1.01 on each 331 px map, on
   both hosts; "SIMD improves scalar by at least 5 percent" reads
   simd/scalar at most 0.95 on each 1300 px map on both hosts. Root's
   corrected rule (prefer scalar when SIMD adds under 5 percent; retain
   SIMD only when it clears the control screen and adds at least 5
   percent; otherwise close) is confirmed as stated and is fixed before
   any timing; my earlier "scalar exceeds 20 percent rejects SIMD" wording
   is withdrawn in the plan.
2. The summarizer should also assert that `batch_raster_hashes` are equal
   across the three arms for the same map, range, batch and repeat; the
   accumulated raster after the same replay sequence is deterministic,
   so this is a free cross-arm exactness check on real maps beyond the
   zero-raster comparison.
3. Attribution caveat, not a defect: the grouped scalar arm removes per-
   cell bounds and overflow checks and pointer reloads as well as
   grouping, and the parent keeps them, so a scalar gain is "grouped plus
   hoisted" against production, not grouping alone. That is the
   comparison the decision chose and it is the right one for the
   selection question, since whichever grouped arm advances would carry
   the same hoisting. Cosmetic: the bench header and usage string still
   describe the C6 tool and "parent|candidate"; harmless, and changing
   them would move the frozen hash.

C10 MICRO REVIEW READY
