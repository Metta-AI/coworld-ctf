# Peer verdict on the native H3 screen and the moving-goal preflight

Read-only recompute from `H3/raw-games.tar.gz` (SHA-256 verified
`bdb7a3b1dfef5e8b7c96b43c522a6856ac9f5666909ba1dc7798a48d53a3819e`),
`H3/results.json`, the archived `build_h3.sh`/`run_h3*.{py,sh}`, the
root's `/tmp/nav512-h3-analysis` extraction, and the H1/H2 archives for
binary provenance. No native use, no edits to root, no commit, no timing.

## 1. Gate verdict, recomputed independently

My parse of the nine `server.log` files reproduces every row in
`results.json` (totals, p50/p95/max, misses, nav counters, semantic
hashes) and the paired ratios to four decimals.

| Pair | total | p50 | p95 | max | misses (cand vs parent) |
|---|---:|---:|---:|---:|---|
| candidate512 / H1+H2 at 512, r1 / r2 / r3 | 0.887 / 0.887 / 0.883 | 0.808 / 0.819 / 0.804 | 0.824 / 0.826 / 0.812 | 0.913 / 0.911 / 0.910 | 29, 28, 25 vs 136, 139, 139 |
| candidate512 / original256, r1 / r2 / r3 | 0.892 / 0.889 / 0.879 | 0.860 / 0.869 / 0.841 | 0.759 / 0.730 / 0.728 | 0.939 / 0.936 / 0.937 | 29, 28, 25 vs 102, 104, 108 |

Every individual pair improves every metric; both registered gates pass
(stage: total <= 0.98 and the rest <= 1.00; target: all <= 1.00 and
worst misses 29 <= 108). All three 512 semantic streams (parent and
candidate) hash to `78d1e387...` and all three 256 streams to
`a2b4288c...`, so same-budget behaviour and repeat determinism hold.
Nav counters at 512 are identical across parent and candidate (pending
87, no-path 42, stale 297). No failed run, no play fault, 1,200 frames
and 32 seats in every run. The run order matches the card.

## 2. Candidate and comparator identity

- `candidate/source.patch` in the archive is byte-identical (ignoring
  index lines) to `H3/combined.patch`; applying `combined.patch` to
  baseline `6b6b3408` reproduces the root's three working files, which
  equal my H1+H2 tree plus the eleven H3 annotations. The candidate
  binary hash is recorded (`d5984cb8...`), built with Nim 2.2.4 and the
  production flags plus the `sed` substitution to 512 on `body_nav.nim`
  only.
- **Provenance gap to close in the report:** the H3 archive's `parent/`
  directory carries no `server-*.sha256`. The card says parent 512 is the
  H2 candidate binary (H2 archive hash `d5bf19a2...`) and parent 256 the
  original (H1 archive hash `802389df...`); `results.json`/`RESULT.md`
  should cite those hashes explicitly and the root should confirm they
  are the files `run_h3.py` executed from `/results/parent/`.

## 3. Where the time went (attribution, not causation)

From the retained `SHELL_TIMING` sums:

| Run | planning (s) | non-planning (s) | reflex (s) |
|---|---:|---:|---:|
| original 256 (r1/r2/r3) | 7.86 / 7.98 / 8.18 | 23.16 / 23.22 / 23.31 | 10.17 / 10.18 / 10.24 |
| H1+H2 at 512 | 7.30 / 7.29 / 7.34 | 23.89 / 23.98 / 24.01 | 10.16 / 10.21 / 10.21 |
| H3 at 512 | 4.22 / 4.24 / 4.07 | 23.45 / 23.50 / 23.62 | 9.78 / 9.83 / 9.84 |

H3 cut the planning stage by 42-45 % against H1+H2 at the same budget
and by 47-50 % against original 256, and non-planning time fell 1.6-2.0 %
against H1+H2, of which the reflex stage accounts for about 0.4 s (the
zone-escape reflex uses the same map helpers). Both arms of planning
moved: the minter-dominated quiet ticks (p50 -19 %) and the A\* bursts
(max -9 %, misses 139 to 29).

**Why my estimate was low.** In `INLINE_REVIEW.md` and `H3_PEER_REVIEW.md`
I bounded H3 by the sampled self time of the eleven helpers (about 15 %
of samples before H2, about 7 % minter-side after) and by instruction
counts in the local arm64 assembly. Those are bounds on the helpers'
own cost, not on what their callers can do once the bodies are inlined:
call and return, argument marshalling, the error-flag test after every
call, and register pressure across the neighbour loops all live in the
callers' self time, and the native GCC evidently inlined more than the
local clang did. I did not measure any of that split, so I cannot say
which of these carried the 3.1 s, only that a sample share of
out-of-line leaf helpers was not an upper bound on the whole-stage
effect of removing their frames. The root's correction stands.

## 4. Moving-goal preflight coverage (pool 505, 32 seats, ORIGINAL at 256, timings excluded)

**Correction (P13).** An earlier version of this heading said the
preflight ran at 512. It ran the original planner at 256: every
`SHELL_PLAN_BUDGET` visit in its log caps at 8,192 units (256 x 32
seats; a 512 pool would show 16,384), and the early planning stage runs
at about 39 ms per tick, which is 8,192 A\* units at the measured
5 us per unit. The runner (`run_case.py`) takes the server binary as an
argument and records no budget itself, so the log is the evidence; the
root is adding a parent-binary hash readback. This correction is
retained deliberately.

| Check | Observed |
|---|---|
| frames / exit | 1,200 `BUDGET_FRAME` rows, exit 0, 73 s wall |
| guest init | 32 `nav_research_moving initialized` logs, one per seat 0-31 |
| seat census | `SHELL_MOVEMENT seats=32` on all 1,201 rows; 32 alive at tick 1200 (`hitPoints` 1000) |
| play faults | 0 |
| installs | 1,925 `rule=nav_research_moving`; carrier 996, hunter 929; `moving_goal:true` on all 1,925 |
| cadence while the play controls a seat | exactly 12 ticks (seat 0: 56 consecutive 12-tick gaps); 1,843 of 1,925 installs on tick ≡ 0 mod 12, the rest at the tick-2/3 first views and seat 10's interleaving with a spray reflex |
| installs per seat | 59-63 |
| planning revisions | 764 `SHELL_PLAN_BUDGET` events; max revision per seat 39-165, above the install count as predicted (moving-goal and stuck replans) |
| earlier attempt | `moving32` on the stale 301 fixture: server exit 1 at startup, retained as a coverage failure |

**The play is silent for all 32 seats from tick 408 to 842 and after
1128.** This is not the play: in those windows `view_us` and `ladder_us`
drop to zero and `reflex_zone_escape` installs take every seat (1,484
reflex installs in the game), and the identical zero-view windows
(432-840, 1152-1200) appear in every H1 and H3 timing game with
`edge_ride`. The engine hands all seats to the native zone-escape reflex
for the phase-1 announce-and-shrink window and again for phase 2, and
plays are not stepped meanwhile. Consequences for the frozen protocol:

- **Coverage limitation, recorded without changing the frozen inputs:**
  while a seat is under reflex control the play is not stepped at all
  (no view, no `play_step`), so the moving play exercises replans for
  roughly 700 of the 1,200 ticks; the same holds for `edge_ride`. The
  card's "12-tick interval scheduling while alive" is true only while the
  play controls the seat; the summary should say "while not under reflex
  control". The frozen six cells stay as they are; this is a statement
  about what they measure.
- The pairing stays fair: both variants at both budgets see the same
  windows, and the reflex's own planning (`planEscapeThroughStage`, the
  largest single stage at about 10 s per game) is inside every frame
  count. But a third of each game measures the reflex, not the plays,
  and that should be explicit when the held-out coverage is described.
- Seat 10's irregular 248-394 stretch is the spray-clearing reflex
  interleaving with the play, with identical bytes re-installed; not a
  fault.

## 5. Verdict

H3 passes both registered gates on the training scenario by my
recomputation, with exact same-budget streams and native full-state
fingerprint parity. Two items for the record before qualification runs:
cite the parent binary hashes in the H3 archive, and state the reflex
windows in every coverage summary. No H4 or direct-lookup work should
start; the frozen six-cell campaign is the next evidence.

PHASE 12 READY
