# C6_MICRO_REPORT: full-word replay arm, isolated micro screen (local counts and exactness)

Peer (Claude) screen per `C6_ROOT_REVIEW.md`, in `nav-source-cache` only
(frozen C2 over f9dff753 with the C5 v2 markers; C5 v2 bytes archived in
`C6/baseline/` and identical to the parent snapshot). No primary or native
edits; nothing committed. The 16 to 30 percent full-word share from
`C6_REVIEW.md` is a descriptive screen, not a passed preregistered gate.
Mac timings below are informational; root's five paired m8i runs decide.

## 1. The arm

`replayVisibleCells` gains one branch under `DangerReplayFullWords`
(`{.booldefine.}`, default false, so the tree is byte-for-byte C2 unless
the define is passed): if a word equals `high(uint64)`, its 64 consecutive
kernel indices are added as contiguous spans split at kernel-row
boundaries, then `continue`; otherwise the unchanged C2 sparse loop runs.
No C3 cursor (C3 is provisional and not built on). No new memory, no
change to source order, floor interleaving, bitmap, LRU, or ledger.
`C6-candidate-over-C5v2.patch` (38 lines) is the materialized candidate
without the define; `snapshots/parent-body_nav.nim` is the C5 v2 bytes;
both build and pass the focused cache suite when placed in the tree
(`local-mac/check_snap_*.log`).

## 2. Exactness

- Crafted diagnostic `tools/check_danger_fullword_replay.nim` (include,
  private cache state constructed directly; the kernel is overwritten with
  a distinct nonzero value per index so a wrong index cannot hide behind
  the production kernel's zeros at the box edge; padding kept zero). Cases:
  diameter 27 all visible (11 full words, all crossing rows), diameter 27
  three full words crossing rows plus sparse bits, diameter 327 one full
  word straddling a row plus sparse and two partial words, diameter 327
  eleven dense rows plus sparse (56 full words, 10 crossing), diameter 327
  all visible (1,670 full words, 321 crossing, 106,929 cells). Both arms:
  every set bit lands on its own cell and zero float-bit mismatches
  against the per-set-bit reference formula (`local-mac/check_*.json`).
- Focused cache suite: 7 of 7 in both arms.
- Nine real traces through the replay tool: raster chain hashes identical
  between arms and identical to the C2 values recorded in
  `C2/replay_results.txt`, zero raster mismatches (`local-mac/chains_*.txt`).
- Microbench: per origin, one replay on a zero raster compared cell by
  cell with the reference formula, zero mismatches on every map and range;
  batch raster hashes identical between arms.

## 3. Microbench (`tools/bench_danger_replay.nim`)

Include-based, tools only. Fixed origins: every 1,400th cell in raster
order whose centre is standable, at most 64 so every warmed bitmap stays
resident (44 to 49 origins per map). Each origin is warmed by one miss
rebuild outside timing. A batch clears the raster untimed, times 20
repeats of `replayVisibleCells` over all origins with one monotonic clock
around the whole batch, then hashes the raster untimed; five batches per
run, three interleaved rounds per arm locally. No counters, no clocks in
the replay.

Mac arm64, informational (ns per replay, median of batch medians over
three rounds; ranges are round-to-round spread):

| map | range px | origins | set bits per origin | full words per origin | parent | candidate | ratio |
|---|---:|---:|---:|---:|---:|---:|---:|
| br-gen-5120 (configured 3) | 1300 | 44 | 9,903 | 38.4 | 159,267 (154,218 to 159,741) | 129,699 (127,457 to 130,553) | 0.814 |
| br-gen-5120 | 331 | 44 | 3,037 | 7.5 | 47,950 | 42,573 | 0.888 |
| br-gen-5204 | 1300 | 45 | 11,852 | 40.3 | 188,774 | 158,823 | 0.841 |
| br-gen-5204 | 331 | 45 | 3,382 | 5.0 | 53,545 | 50,415 | 0.942 |
| br-gen-5263 | 1300 | 49 | 8,707 | 25.7 | 140,427 | 123,486 | 0.879 |
| br-gen-5263 | 331 | 49 | 2,770 | 2.0 | 43,834 | 42,512 | 0.970 |

Full words hold 19 to 25 percent of set bits on these origins, in line
with the trace screen. On this host the 1300 px rows are 12 to 19 percent
faster per replay and the 331 px rows 3 to 11 percent; that is consistent
with the arm removing the per-bit scan for a quarter of the cells and is
not a native result. Hypothesis for root's run, kept separate from bounds:
at least 10 percent lower median per-replay time in the 1300 px rows on
m8i, identical hashes, no material change to the nine-trace rebuild time.

## 4. Native recipe (`run_c6_micro.sh`)

Builds parent and candidate microbench binaries with the frozen gate flags
and no diagnostic defines, runs five interleaved rounds per arm over the
six map and range pairs on CPU 5, records every exit code, then builds
both replay binaries and diffs the nine-trace chains. Outputs
`micro_results.jsonl`, `chains-*.txt`, `chains-diff.txt`,
`exit-codes.txt`, hashes and logs.

## 5. Bounds versus hypotheses

Bound: the arm can only remove per-bit work on the 16 to 30 percent of
replayed cells inside full words, only on cache hits, and only in the
replay stage; the miss ray walk, the floor, the pack and the first-fill
structure of the configured rows (`C5/v2`) are untouched. Whole-body
effect is therefore some fraction of the replay's share of a rebuild, not
a number this screen can state. Hypothesis: the micro gain above survives
on m8i. If it does not reach 10 percent in the 1300 px rows, C6 closes
without a primary change, per the root review.

## 6. Cleanup and ownership

Tree state: C5 v2 plus the define-guarded arm in `body_nav.nim` and two
new tools; `tmp/c6/` holds binaries and raw results (copied to
`local-mac/`). Reverting C6 is applying `C6-screen-over-C5v2.patch` in
reverse. Raw count tools and results from the descriptive screen stay
under `research/peer-proofs/`.

C6 MICRO READY
