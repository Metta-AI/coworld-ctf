> **Root final collection update:** C10 finished after this peer handoff and failed the m5a actual-trace limit. It is rejected for adoption; no integrated qualification or rerun. See [final result](C10_FULL_PARK_RESULT.md). The primary research checkpoint is f6f1e965 in nav-throughput-research; nav-deferred-cache is an isolated experimental tree. The historical pending/restart statements below are superseded by the final park archive.

# Park handoff: Claude peer (nav throughput co-research), 2026-09-10

Written at James's wrap instruction (`WRAP_REQUEST.md`). Purpose: let a
future session resume without repeating any finished experiment or
re-deriving a settled negative. Root (Codex) owns merge, cleanup, native
hosts and the memory update; this file is the peer's durable state.
Companion: `PEER_HANDOFF_C9.md` (chronological log), `SCOREBOARD.md`
(one line per unit), `LEDGER.md`, `NEXT.md`, `ACCEPTANCE_MAP.md`.

## 1. State at park

Retained in the primary (nav-deferred-cache at eaa208bd plus root's later
checkpoints; each with a `*_REPORT.md`/`*_STATUS.md`): W1, W2, R1, W6, W7
(ray sampling and sight predicate), M1/M2/M3 (memory accounting), D0a
(incremental danger-ray decision), P1 (streaming packed dilation), S1
(positive Q8), CAP32 (32 MiB shared, 256 MiB total), A2 and A4 (coarse
legality symmetry), V1 (byte visit stamps), H1 (exact-goal octile bound),
C2 (64-slot shared source-visibility bitmap cache). Quality hash after H1:
ee2488d3...; pre-H1 hash 5a134021... is the one the isolated screens
compare against.

Rejected, with the evidence that closed them (do not resample):
- WF0/WF1 wavefront (`WF0_REPORT.md`, `WF1_PROPOSAL.md`).
- D1 incremental kernel index (`D1_REPORT.md`).
- A3 inline predicate; A7 early-visited (3.8 percent m5a, below 5);
  A6 lazy standability (m8i +3.5 to 4.1 percent, m5a follow-up did not
  integrate); A8 failed-search memo (m8i 6.16, m5a 4.97 against 5 percent
  both-host; `A8_MEMO_SCREEN_RESULT.md`, `A8_MEMO_SOURCE_REVIEW.md`).
- C3 row cursor, C4 raster reuse (count screen), C6 full-word runs, C7
  eager list (v1 ownership defect then corrected version), C8 zero-weight
  omission, C9 first-hit list (m8i pass, m5a changing-source 1.2 to 1.6
  percent over 1.01; `C9_NATIVE_FULL_RESULT.md`, `C9_FULL_REVIEW.md`,
  `C9_DIAG_REVIEW.md`).

Pending, root-owned:
- C10 grouped four-cell SIMD replay: native micro passed both hosts
  (SIMD/parent 0.29 to 0.45 at 1300 px; `C10_NATIVE_MICRO_RESULT.md`,
  `C10_MICRO_RESULT_REVIEW.md`); full-source candidate frozen under
  `C10/full/` and reviewed (`C10_FULL_SOURCE_REVIEW.md`); five-pair
  native full screen was running on both hosts at park (m8i 54502, m5a
  76802). Screen: per-trace median total at most 1.01 and p95 at most
  1.03, changing-source median at most 1.01, repeated at most 0.90, exact
  chains, quality on the pre-H1 hash. If it passes: integrated
  qualification (76-map memory, configured tick, at least 5 percent worst
  configured p95 gain before retention, absolute gates unchanged).
- C11 close-floor row intervals: exactness proved, unimplemented
  (`C11_COUNT_REVIEW.md` sections 2 to 8; `C11/`). Root's halfWidth
  table (191 bytes, domain-independent) verified against isqrt and all
  39,555 membership cases. Needs an isolated implementation with its own
  bitwise exactness tool before any micro.

Unfinished gates (none closed by this programme):
- Whole-body tick on m5a: worst configured p95 6.485 ms on br-gen-5120
  (32 seats, stuck replans; C2 state) against 4.0 ms; the danger fill
  tick sets it (replay 2.35 ms, refresh 1.01, close floor 0.43, max 0.28,
  clear 0.08 on that map; planning flat 1.6 ms on every map). Whether
  m5a defines the gate is James's ruling (`ACCEPTANCE_MAP.md` line 156).
- Activation ratio 2x non-colossal: still failing on most maps on both
  hosts (A4 state 76/76 memory, m5a 62/76 time after A6 qualification).
- Throughput doubling: not established; pops per ms unchanged in kind.
- Phase 10/11 items in `NEXT.md` (fixtures at final budget, containment
  pair, canonical Docker, latency rows, budget selection, docs audit).

## 2. Evidence you can trust, and how to read it

- Every unit has frozen sources (parent and candidate snapshots with
  SHA-256), a runner script that restores source on exit, raw per-process
  JSON, executable hashes, lscpu and an evaluator script under
  `research/<UNIT>/` or `research/<UNIT>-<host>/`. Summaries are
  derivable from raw files; I recomputed C9 and C10 independently and
  they matched.
- Real-episode traces: nine `navsrc.txt` traces under `cache-trace/`
  from actual S2 baseline clients (four seeds at 16 and 32 seats plus a
  randomized smoke), replayed by `tools/replay_danger_source_trace.nim`
  in nav-source-cache. LRU-64 hit rates 25 to 58 percent.
- Fluffy stage splits: `C5-m5a-stage-summary.json`, `C5_M5A_REVIEW.md`
  (danger fill composition), `A5_NATIVE_REVIEW.md` (index construction).
  These are attributions and scale estimates, never speed results or
  ceilings.
- Configured whole-body rows with breakdown: `C2-m5a/configured.json`
  (all 11 maps, per-stage p95); `C3-configured-native-summary.json`.

## 3. Practices that held up (keep them)

- Preregister the threshold, the pairing statistic and the sample size
  before any timing. Statistic used throughout: fresh process per arm,
  interleaved or rotated order, median of per-process medians, ratio per
  pair, median of pair ratios, every raw pair reported; a map failure is
  never averaged away.
- Counts first. A trace-driven or code-derived count that can reject a
  mechanism before implementation saved several units (C4, WF1 killed;
  C2, C10 advanced on counts).
- Exactness before clocks: bitwise raster comparison, raster hash chains,
  identical ordered inputs and cache counters, quality hash on the corpus;
  crafted geometries for boundaries plus real-map comparison in the same
  process that times.
- Control arms to attribute mechanisms (grouped scalar next to grouped
  SIMD); ownership checks in generated C (the C7 v1 `eqcopy`/`eqdestroy`
  per cell); no per-cell ref-owner locals.
- Hoisting matters in Nim release builds: bounds and overflow checks,
  checked division, and `-fno-strict-aliasing` pointer reloads sit in hot
  loops; a "grouped scalar" arm removing them gained about 27 percent on
  replay by itself.
- Documents in files, sentinels in the pane, durable handoff before
  compaction. Peer writes only peer-owned trees and named research files.

## 4. Misreadings to avoid

- Per-trace improvements do not offset a failed preregistered regime
  gate (C9). Construction-only gains never count toward the tick gate.
- Hot micro averages are not bounds on cold per-origin costs; counts make
  a mechanism unlikely, not impossible (C9 conversions).
- Normalized-identical disassembly does not exclude absolute placement or
  data-placement effects; m5a three-pair noise is 0.8 to 2.0 percent, the
  size of the 1.01 limit, so use five pairs there.
- Summed per-stage p95 values are approximate prioritization, not an
  exact ceiling; planning being flat across maps does not prove the pop
  loop cannot contribute.
- A 4.97 versus 5 percent miss (A8) is a negative by rule and not
  statistically resolved; do not resample to cross the same line.
- Fluffy "fill" ticks in C5 are seat-rebuild ticks, not cache misses;
  `transientPeakBytes` is a max over allocation points, not a sum.
- Nim `div` truncates toward zero (C11 endpoints need floor division);
  the standard library has no integer square root; `cellOf` clamps while
  the close floor measures from the original pixel; a `seq` header is 16
  bytes under ORC.
- Local: zsh does not word-split unquoted variables; nested heredoc
  delimiters; this Mac needs `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
  per build command. Mac timings are informational only.

## 5. Peer-owned trees at park (nothing committed in them)

- `nav-source-cache`: frozen C9 candidate `src/shell/body_nav.nim`
  (ad45ee07...), its tests and tools, plus replay/regime/count tools and
  the `tmp/c9review` counts. Isolated candidates must not be merged into
  production; the tools and tests are research artifacts.
- `nav-source-trace`: trace instrumentation and runner.
- `nav-validation-symmetry`: root-owned now (A4, A5 markers, A6 arms).
- Research documents live under `docs/designs/nav-rework-evidence-2026-09-09/research/`
  in the nav-throughput-research worktree; root merges.

## 6. Smallest restart steps

1. Read this file, `NEXT.md`, `SCOREBOARD.md` (tail), and root's park
   document; confirm the primary checkpoint and quality hash.
2. Resolve C10: read `C10-full-*/DONE` and run `C10/full/summarize_native.py`
   on both host folders; if the screen passed, run the integrated
   qualification root registered; if it failed on m5a changing regimes,
   apply `C9_DIAG_REVIEW.md` and close it.
3. C11: implement the halfWidth table in an isolated tree exactly as
   `C11_COUNT_REVIEW.md` section 6 describes, with a Nim exactness tool
   that compares cell sets against the literal predicate on real maps and
   off-map sources, then the section 8 micro. Expected value about 0.3 ms
   per fill tick on m5a; stack member only.
4. After any retained unit, re-profile the danger fill tick (C5 tooling)
   and redo the section 1 scale estimate from `NEXT_THROUGHPUT_UNIT_PLAN.md`
   before choosing the next unit; remaining candidates there are the max
   and clear passes and the map-size-dependent weight refresh.
5. Ask James for the two rulings that no experiment can settle: whether
   m5a defines the tick gate, and whether any danger semantics (cadence,
   source count, support, close radius) may change.

PARK HANDOFF READY
