# Peer handoff for context recovery (Claude peer, tmux `nav-research-peer`)

Written 2026-09-10 at root's request after C9 FULL READY. If the peer
session is compacted or restarted, resume from here; do not restart any
completed experiment.

## Standing rules (unchanged)

Documents and peer-owned isolated trees only. Production source, root
checkouts, viewer, caps, and both native hosts are root-owned; no commits,
push, PR, Asana, or publishing; no threshold or gate changes; no
percentile arithmetic across stages; no speed claims from source or counts;
preserve negatives; never re-run to fabricate provenance. Sentinels end
each unit; wait for PROCEED.

## Where things stand

- Primary source: retained C2 (bitmap source-visibility cache, 64-slot
  LRU) with V1, A4, H1 integrated by root. C3, C6, C8 rejected; A6 and A7
  unintegrated (A7 failed the 5 percent both-host threshold). Eager C7
  list (v1 and ownership-corrected) closed as a mechanism result, not an
  adoption (`C7_REFCOUNT_PEER_REVIEW.md`).
- C9 first-hit list candidate is frozen and under native test:
  - Candidate `src/shell/body_nav.nim` in `nav-source-cache`, SHA-256
    `ad45ee0733ddc65081d6883e02c493ef4b45b230b2177baaa6f177d1cdeba6ac`;
    frozen parent `13f5191480dd7995e72cd2b684b1cafac93b45c2bf9e58ebf31f7d8e306545d9`.
  - Evidence: `research/C9/full/` (snapshots, patch, tests, tools, local
    checks, measured 76-row ledger, generated C, `C9_FULL_READY.md` with
    corrected commands), `research/C9/` (count model, memory calc, micro),
    `C9_NATIVE_REVIEW.md` (revised plan and estimate).
  - Root native runs in flight: m8i PID 50020 and m5a PID 71922 via
    `run_c9_full.sh` (three interleaved C2/candidate trace and regime
    pairs per host, no counters or Fluffy; then quality on the old hash;
    then integrated memory and configured whole-body). Preregistered
    screen: per-trace median total ratio at most 1.01 and p95 at most
    1.03, changing-regime median at most 1.01, repeated-regime at most
    0.90, every raw pair reported; integrated memory at most 64 MiB shared
    (three allowances: ref object plus two seqs) and 256 MiB total; m5a
    configured worst p95 improvement at least 5 percent before retaining
    the extra memory. Peer has no disagreement with these criteria.
- A8 (pixel-search input recurrence): counts-only proposal reviewed in
  `A8_COUNT_REVIEW.md`; root ran the count (`A8_COUNT_RESULT.md`,
  `A8/local-mac`): map 48 has 457 calls and 805,625 dequeues, of which
  189 repeated empty failures over 266 distinct pocket keys account for
  44.3 percent of dequeues with zero result mismatches; configured maps
  3, 5, 6 show no repeats. Peer's implementation review is written
  (`A8_IMPLEMENTATION_REVIEW.md`): recommends a per-start latest-failed-key
  memo in the pixel search scratch with explicit byte accounting and an
  entry cap, and a native screen of at least 5 percent lower map 48 index
  time on both hosts with exact 76-index and quality proofs. Root accepted
  the direction with two corrections (`A8_ROOT_REVIEW.md`): the counts
  did not record reuse distances, so "a 16-entry ring loses every repeat"
  is unproven, and a std table's private capacity must not be stated from
  an unverified growth formula in measured transient stats. Root is
  extending the count to all 76 maps with a complete ordered per-call
  key/outcome/dequeue/target-count trace, then replaying bounded first-N
  and LRU caches (16/64/128/256/512) and the per-start latest-failure
  memo, reporting actual hit and dequeue savings and the maximum copied
  target payload; v1 diagnostic and results preserved; no memoization
  yet. Root notes only 253 distinct failed keys on map 48 (442 failures
  minus 189 repeats), so a 256-entry ordinary seq cache with measured
  lookup cost is a live option. Native criteria unchanged: at least 5
  percent median index gain on both hosts, exact 76 indices and full
  quality, final activation gate absolute. Root also created
  `nav-deferred-cache` at primary checkpoint eaa208bd for optional
  integrated C9 preparation (no edits, no cap change). Peer's next input
  is either the C9 native results or the extended A8 counts; nothing to
  implement or research until root sends results.
- Isolated trees: `nav-source-cache` holds the C9 candidate (tests and
  tools updated; screen tools from closed units archived under C6/C7 and
  not building against the candidate); `nav-validation-symmetry` holds
  A4 plus A5 markers plus A6 arms (root-owned now); `nav-source-trace`
  holds the trace instrumentation. Nothing is committed in any of them.
- Local environment note: this Mac's `SDKROOT` pointed at a nix Apple SDK
  whose headers clang stopped finding mid-session; local builds use
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` per
  command. No system or repository setting was changed.

## Update 2026-09-10 (later): C9 native full result and A8 array plan

- C9 full native result (`C9_NATIVE_FULL_RESULT.md`): m8i passes all 17
  checks; m5a passes all 9 traces (totals 0.9036 to 0.9866) and all 4
  repeated-source checks but fails three changing-source medians
  (br-gen-5001 1.0140, br-gen-5263 1.0164, colossal 1.0119 against 1.01;
  br-gen-5204 0.9962). No adoption, threshold unchanged,
  nav-deferred-cache frozen.
- Peer review written: `C9_FULL_REVIEW.md`. Key finding: root's primary
  changing regime (`tools/bench_body_danger_cache.nim`) is 98.2 to 99.6
  percent misses with 6 to 27 conversions per 1,536 lookups (counts-only
  run of that tool with a `conversions` output line against the frozen
  candidate; evidence and fingerprint match to all 48 native rows under
  `C9/full/review-counts/`). The conversion cost bound is 0.01 to 0.03
  percent of the regime total on m5a against a measured 1.2 to 1.6
  percent excess, so conversions do not explain it; the miss path's Nim
  source is byte identical to C2. Justified diagnostics, in order: m5a
  disassembly comparison of the miss-path machine code in the two frozen
  binaries (no timing), then a parent-versus-parent null pair set on m5a
  to size the tool's pair noise (parent run-to-run spread is 0.8 to 2.0
  percent there). Not justified: per-tick class split, all-miss control,
  any new optimization. Do not restart any of this.
- A8 (`A8_FULL_COUNT_RESULT.md`): 76 maps counted, only map 48 repeats,
  first-N 128-record inline array serves all 189 hits. Peer review
  written: `A8_ARRAY_PLAN_REVIEW.md`, accepting the plan (purity of the
  search verified from source; default failed return; record layout and
  sizeof; accounting; generality statement; tests; A4 base labeling).
  Root owns the code and native jobs.

- C9 diagnostic decision (`C9_DIAG_DECISION.md`): root disassembled the
  frozen binaries on m5a (`C9/disassembly/`): castRay instruction-identical
  and shifted by exactly 64 bytes; rebuildDangerFromPoints +56 bytes with
  only slot-offset, list-dispatch and register-rename changes; no spill or
  inlining regression. Peer wrote `C9_DIAG_REVIEW.md` and corrected
  `C9_FULL_REVIEW.md`: the micro conversion figure is an average hot cost,
  not a bound, so conversion is "unlikely under that cost model", not
  "ruled out"; absolute code placement, data placement and m5a pair noise
  remain open. C9 stays rejected; no timing or implementation for it.
  Root owns A8 implementation in nav-deferred-cache (current A4 source);
  peer must not edit A8 code or run native jobs. Handoffs stay in this
  repository; no external memory updates unless James asks.

- A8 memo implementation (`A8_MEMO_IMPLEMENTATION.md`): root implemented
  the 128-record memo in nav-deferred-cache (live source equals the frozen
  `A8/memo/candidate-body_route_index.nim`; C9 source there is restored, so
  that tree is now A8 experimental, not frozen C9). Peer wrote
  `A8_MEMO_SOURCE_REVIEW.md`: no exactness defect; five focused tests,
  counts (189 hits, 448,841 dequeues, equal to the model), 76-map identity
  against `A8/full-identity/parent.json`, generated C (no scratch copy)
  all checked. Root owns the native screen (map 48, 5 percent, both
  hosts). C9 wording corrections applied per
  `C9_DIAG_WORDING_FOLLOWUP.md` (no categorical "no instruction-level
  mechanism", sourceCacheSlot alignment change noted, uncited hardware
  sensitivity claim removed).

- A8 native screen (`A8_MEMO_SCREEN_RESULT.md`): m8i 6.16 percent, m5a
  4.97 percent against the 5 percent both-host rule; closed as a negative,
  no resample, no adoption. Peer confirmed in section 5 of
  `A8_MEMO_SOURCE_REVIEW.md`. Exactness evidence preserved (189 hits,
  76-map identity). Do not restart A8.

- Next-unit plan (`NEXT_UNIT_REQUEST.md`): A8 review corrected (paths
  comparison verified: 11 cases and real_map48 equal to
  A7/local/eager-arms-v2.json, 173,424 searches, 12 exact-edge
  differences, chain 4D841154B18CFF53; "not noise-limited" claim
  removed). `NEXT_THROUGHPUT_UNIT_PLAN.md` written: the m5a configured
  failure is the danger fill tick (danger p95 2.05 to 4.19 ms tracks the
  worst tick; planning flat 1.6 ms on all 11 maps); ceiling arithmetic
  says no single exact unit closes the gate. Ranked: 1 C10 grouped
  four-cell replay (root's counts 98.8 to 99.7 percent safe groups;
  accepted for tools-only micro with a grouped-scalar control arm, five
  m5a changing-regime pairs, portability gate; prototype reviewed, two
  correctness additions pending), 2 close-floor row spans (exact, from
  code reading), 3 remaining raster passes and refresh (counts first).
  Waiting for explicit implementation authorization; root owns C10 code.

- C10 micro (`C10_MICRO_DECISION.md`, `C10_MICRO_READY.md`): root
  accepted the three-arm ablation with a corrected selection rule (prefer
  scalar unless SIMD adds at least 5 percent after clearing the 20/1
  control screen; else close), cautioned that my plan's stage sums are
  approximate prioritization, not a ceiling; plan amended accordingly.
  Frozen tools reviewed in `C10_MICRO_SOURCE_REVIEW.md`: no blocking
  defect; safety predicate precedes unchecked access; both grouped arms
  fair; crafted, 256 border/mask and real-map bitwise checks pass; three
  non-blocking items (write the ratio statistic before launch, assert
  cross-arm batch raster hashes, attribution caveat). Root launches the
  native micro; peer waits.

- C11 close-floor intervals (`C11_COUNT_REQUEST.md`,
  `C11_COORDINATE_NOTE.md`): `C11/c11_close_floor_intervals.py` proves
  the isqrt row-interval formula equals the primary predicate on 39,555
  cases (all radii 0..190, 64 phases, clipping, 23,875 off-map sources
  with clamped origins) with zero differences; review in
  `C11_COUNT_REVIEW.md` (Nim floor-division and no-isqrt cautions, runtime
  form recommended over phase tables, proposed micro at 0.50 stage limit).
  Not authorized for implementation.
- C10 native micro passed both hosts; SIMD/parent 0.29 to 0.45 at 1300
  px; recomputed independently in `C10_MICRO_RESULT_REVIEW.md` (all 12
  rows match root to 1e-12). Full-source candidate frozen under
  `C10/full/` reviewed in `C10_FULL_SOURCE_REVIEW.md`: replay body equals
  the proven prototype, scalar fallback on non-x86/arm64 targets, 256 B
  mask constant counted per system, runner and evaluator match the
  five-pair screen; no blocking defect. Root runs the native full screen.

- C11 table follow-up (`C11_ROOT_REVIEW.md`): storage corrected (uint8
  for L; 3,136 pairs); root's 191-byte halfWidth table verified against
  isqrt (18,336 entries) and all 39,555 membership cases (same hash);
  geometry/range contract verified from the constructor. Appended to
  `C11_COUNT_REVIEW.md` section 6. Unimplemented proposal.
- Parked at James's wrap instruction (`WRAP_REQUEST.md`):
  `PARK_HANDOFF_CLAUDE.md` is the durable restart document.

## What the peer is doing now

Parked. No follow-on work. Resume from `PARK_HANDOFF_CLAUDE.md`. On either, read root's request file first and follow it.

C9 DOCS HANDOFF READY (updated for C9 full result and A8 array plan; peer standing by)
