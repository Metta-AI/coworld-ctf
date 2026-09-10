# C9_FULL_READY: first-hit list candidate over frozen C2, isolated implementation

Peer (Claude) per `C9_IMPLEMENT_REVIEW.md` and `C9_INTEGRATION_NOTES.md`, in
`nav-source-cache` only. The corrected C7 candidate and its test file are
preserved in `full/baseline-c7corrected/` (and in `C7/refcount/`). No
primary, test, viewer, cap or native change; nothing committed.

## 1. Candidate (`full/snapshots/candidate-body_nav.nim`, `full/C9-candidate-over-parent.patch`, 185 lines)

Parent: `full/snapshots/parent-body_nav.nim`, the frozen C2 plus inert C5
markers (byte-identical to the C7 refcount and C8 parents). Changes:

- Slot: `key: int32, listLength: int32, lastUse: uint64`; the length sits
  in the existing padding before `lastUse`, so the slot stays 16 bytes
  (measured: object 1,080 bytes at every range, versus 1,056 in C2; the
  24-byte difference is the `capacity` and `entries` fields, not slot
  growth). Sentinel `-1` = not materialized; `0` is a valid materialized
  empty list handled by the same nonnegative branch.
- Cache: C2's bitmap words and seq unchanged; plus `capacity` (nonzero
  kernel count from the actual kernel at creation: 5,385 at 331 px, 54,173
  at 1050 px and above) and one preallocated `entries` seq of
  `64 * capacity`.
- Miss: exactly C2 (bitmap recording, unchanged `addVisibleCell`), with
  `listLength = -1` set when the victim slot is claimed; that reset is the
  list invalidation on slot reuse.
- Hit: if `listLength < 0`, `materializeVisibleCells` does the C2
  row-major bitmap replay and records each nonzero add as an entry
  (exact: one add per cell per source), then stores the count; otherwise
  `replayListEntries` replays the list. Both read the cache through the
  seat field; no per-cell owner local (generated C below). C2's
  `replayVisibleCells` is removed as dead code.
- Unchanged: key and sequential 64-slot LRU, source order, exact-pixel
  floor, uint32 visit generations, publishing, C5 markers.
- Ledger: `sharedDangerSourceCache = sizeof(object) + bits.capacity * 8 +
  entries.capacity * 8`, with one allocation allowance per seq (two).
- Diagnostics: `dangerSourceCacheCapacity`, `dangerSourceCacheListBytes`,
  `dangerSourceCacheListLengths` (LRU order, `-1` visible); `conversions`
  added to the counters define. No public setter.

## 2. Local checks (`full/local-mac/`)

- Focused cache suite 11 of 11 (`tests/test_shell_body_danger_source_cache.nim`,
  diff over the C7 file in `full/tests/`): the C2 tests with entry-size
  assertions restated as bitmap bytes plus list bytes; capacity-exact
  all-visible source unmaterialized after the miss, exactly 54,173
  entries after the first hit, bit-exact on first and later hits; the
  corrected 63-origin reuse test now also asserts `-1` on the reused slot
  until its first hit; border origins at 331, 1050, 1300, 1600 px on
  miss, first hit and later hit; empty selections between hits leave
  lists and order untouched; ledger payload equals both capacities.
- Body nav rework 16 of 16.
- Nine real traces (`chains.txt`): raster chains, hits and misses
  identical to the C2 parent values; conversions per trace 35, 21, 31,
  17, 92, 70, 97, 84, 18, exactly the sequential count model's
  residencies-with-a-hit (`C9/c9_lazy_list_counts-r050.json`), the first
  check of the count model against an implementation.
- State seam (`tools/check_danger_lazy_list_state.nim`, include-based
  internal seam, not a public API, `state.json`): `-1` after a miss;
  first hit converts once with a positive length; later hit does not
  reconvert; a converted slot forced to length 0 (unreachable in
  production, since the origin cell always has weight 1) adds nothing
  and does not reconvert, leaving only the live close floor. All pass.
- Generated C (native gate flags, `local-mac/generated-c/`): candidate
  `addVisibleCell`, `materializeVisibleCells` and `replayListEntries`
  contain no `eqcopy`, `eqdestroy` or cache local; `rebuildDangerFromPoints`
  keeps one per-source cache alias with one copy and destroy, identical
  in count to the C2 parent's (`parent_rebuildDangerFromPoints.c`), so no
  new ownership work was introduced; the parent's per-hit alias in
  `replayVisibleCells` is gone with that proc.
- Regime diagnostic (Mac, informational, three rounds, 16 seats, 640
  ticks, 1300 px; fingerprint chains identical in every cell):

| map | regime | hits / misses / conversions (candidate) | parent ns per tick | candidate ns per tick | ratio | chains equal |
|---|---|---|---:|---:|---:|---|
| br-gen-5001 | changing_sources | 464 / 2096 / 464 | 3,155,165 | 3,240,389 | 1.027 | True |
| br-gen-5001 | repeated_sources | 120 / 8 / 8 | 45,800 | 26,288 | 0.574 | True |
| br-gen-5204 | changing_sources | 464 / 2096 / 464 | 3,060,552 | 3,104,957 | 1.015 | True |
| br-gen-5204 | repeated_sources | 120 / 8 / 8 | 53,528 | 26,784 | 0.500 | True |
| br-gen-5263 | changing_sources | 464 / 2096 / 464 | 2,941,635 | 3,037,242 | 1.033 | True |
| br-gen-5263 | repeated_sources | 120 / 8 / 8 | 44,021 | 25,439 | 0.578 | True |

  Changing sources (82 percent misses, every hit a first hit and
  therefore a conversion) is 1.5 to 3.3 percent slower here; repeated
  sources (94 percent hits) about half. These are Mac numbers; the
  native screen decides.

## 3. Measured ledger, all 76 maps (isolated tree; `activation.json`, `configured.json`, `ledger_probe.txt`)

Cache field (`sizeof` plus both seq capacities): 2,816,056 B at 331 px,
28,299,832 at 1050, 28,593,208 at 1300, 29,024,312 at 1600 (bitmap grows
with range; list capacity fixed above 1050). Object 1,080 B.

| rows | cache field | worst shared bound | worst total | note |
|---|---:|---:|---:|---|
| 64 non-colossal at 331 px | 2,816,056 | 19,009,622 | 36,244,886 | under the current 32 MiB shared cap |
| 11 configured at 1300 px | 28,593,208 | 60,200,868 | 91,222,052 | under the authorized 64 MiB by 6,907,996 B; the isolated harness still reports `memory_pass false` because its shared-cap constant is 32 MiB and was deliberately not changed |
| colossal at 331 px, isolated | 2,816,056 | 141,134,563 | 269,295,587 | fails 256 MiB by 860,131 B in this isolated tree, whose parent is pre-V1 C2 (uint32 stamps; pre-V1 colossal was 266,538,427). Not an integrated verdict: the integrated C2+V1 colossal total is 229,158,347, and adding this row's exact delta gives 231,915,507, 36.5 MB under the cap |

Deltas versus the isolated C2 parent's own activation run are exactly
2,757,160 B on every 331 px row (field 2,816,056 minus 58,912, plus the
16-byte allowance for the second seq); allocator overhead rises by 16.

Allowances, stated distinctly per `C9_INTEGRATION_NOTES.md`: the cache has
three allocation allowances in integrated root, one for the ref object
and one per seq payload (`bits`, `entries`). This isolated parent omits
the ref-object allowance (frozen, unchanged); the candidate adds the
second seq allowance. On integration, keep the ref-object allowance that
primary already has and add the `entries` allowance: three in total.
The projection in `C9_NATIVE_REVIEW.md` (60,201,132 configured shared)
matches the measured 60,200,868 within 264 bytes.

## 4. Reproducible commands (from the isolated tree root)

Trace inputs: the nine `*.navsrc.txt` files live in root research (the
`cache-trace/runs/<episode>/navsrc.txt` layout, copied to
`research/C2/traces/` in the isolated tree's evidence folder during C2).
Use a variable pointing at wherever root keeps them, for example
`C9_TRACES=<absolute path to research/C2-local/traces>`; the isolated
tree's `docs/.../research/C2/traces` copy is a convenience, not the
canonical location.

```
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk   # this Mac only, see note in section 2 of C7_REFCOUNT_READY
nim c -d:release --hints:off -o:tmp/c9full/test_cache tests/test_shell_body_danger_source_cache.nim && ./tmp/c9full/test_cache     # expect 11 OK
nim c -d:release --hints:off -o:tmp/c9full/test_nav tests/test_shell_body_nav_rework.nim && ./tmp/c9full/test_nav                    # expect 16 OK
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -d:dangerSourceCacheCounters -o:tmp/c9full/replay tools/replay_danger_source_trace.nim
./tmp/c9full/replay "$C9_TRACES/s2_32_679963.navsrc.txt" br-gen-5263 32 1300    # repeat for all nine; chains must equal C2/replay_results.txt
nim c -d:release -d:dangerSourceCacheCounters --hints:off -o:tmp/c9full/state tools/check_danger_lazy_list_state.nim && ./tmp/c9full/state   # expect "pass": true
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on -o:tmp/c9full/bench tools/bench_body_nav_rework.nim
./tmp/c9full/bench --activation > activation.json; echo "activation exit $?"          # expected exit 1: the isolated pre-V1 colossal row fails the 256 MiB total (see section 3); ledger fields are still valid
./tmp/c9full/bench --configured-tick > configured.json; echo "configured exit $?"     # expected exit 1: Mac tick gates and the unchanged 32 MiB shared constant; ledger fields are still valid
```

The two harness runs are separate invocations on purpose: each is
expected to exit 1 for the reasons noted, so chaining them with `&&`
would skip the second. Parse each JSON from its first `{`.

Isolated colossal statement, unambiguous: the colossal memory failure in
this tree's activation report (269,295,587 B against 256 MiB) is a
property of the isolated pre-V1 C2 parent (uint32 visit stamps, 37 MB
larger than the integrated V1 tree) and is not an integrated memory
verdict; the integrated C2+V1 colossal total is 229,158,347 B and this
candidate's exact per-row delta (2,757,160 B at 331 px) projects it to
231,915,507 B, 36.5 MB under the cap. Root's integrated 76-row run is the
verdict.

## 5. Gates not yet run (root-owned, as preregistered in `C9_IMPLEMENT_REVIEW.md`)

Three interleaved C2/candidate trace and changing/repeated regime pairs
per host without counters or Fluffy; per-trace three-repeat median total
ratio at most 1.01 and p95 ratio at most 1.03, each changing-regime
median at most 1.01, each repeated-regime median at most 0.90, every raw
pair reported; quality 3,072 strict on the old hash; then integrated
memory at most 64 MiB shared and 256 MiB total with three allowances,
and m5a configured worst p95 improvement of at least 5 percent before
retaining the extra memory; ordinary and headroom gates absolute and
unchanged. I have no disagreement with those criteria. One note for the
changing-regime limit: on this candidate every hit in that regime is a
conversion, so it is the strictest possible test of the conversion cost.

C9 FULL READY
