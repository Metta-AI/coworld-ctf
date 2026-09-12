# Report claim audit (Intel pending)

Audited against completed evidence: `QUALIFICATION.md`,
`current-main/RESULT.md`, `fleet/C6A_RESULT.md`, `README.md`,
`STALE_COUNTER_REVIEW.md`. Read-only; no native use, build, source edit
or commit. Intel remains pending everywhere and this review adds no
shipping claim.

## 1. Claims checked and confirmed

- **Numbers.** Every percentage in `current-main/RESULT.md` (six cells,
  four metrics, misses) and `fleet/C6A_RESULT.md` (four cells) matches
  my independent recomputations to the printed precision, as do the
  README's training-confirmation figures (total -11.6 %, p50 -15.8 %,
  p95 -26.2 %, max -6.4 %, misses 31 vs 109) and its held-out ranges
  (total -6.2 % to -17.9 %, p95 -6.8 % to -37.7 %).
- **"Every individual pair improved all four metrics."** True for the 18
  m5a held-out pairs, the 3 training pairs and the 12 c6a pairs.
- **Base provenance.** `983880f5` exists and runtime sources (`src`,
  `replay-viewer`, `nimby.lock`) are byte-identical from `58e6c947`
  through it; the intervening commits are wiki, docs and a glory
  catalogue tool. The candidate checkpoint `c651dec9` was shown in P18 to
  be the built candidate source.
- **Exactness statements** are now correctly scoped: 256 same-budget
  equality observed on all six held-out cells, 512 equality observed on
  the training screens only, mechanism proofs as the structural
  expectation. The stale-counter caveats in RESULT.md restate the P22
  corrections accurately.
- **Status lines.** `QUALIFICATION.md` and `C6A_RESULT.md` say Intel is
  running or pending. `RESULT.md`'s closing "common-family and unpinned
  qualification remains pending" predates c6a and is now half stale;
  `README.md`'s "Common production CPU families and unpinned server
  execution remain to be qualified" and "Fleet qualification is next" are
  likewise behind by one campaign. Both should say c6a passed, Intel
  running.
- The c6a peer note about the image digest was my error; the digest is
  at `instance.image_id` in `host.json`. Root's correction stands.

## 2. Remaining overclaims and imprecisions

1. **"Gives each configured cog a share of a pool"** (QUALIFICATION.md).
   The pool is `512 x configured seats`, spent plans-first in a persisted
   round robin where one seat's visit may consume the entire pool, with
   the field minter taking whatever is left; it is not a per-cog share,
   and it scales with configured seats, not live ones. Say "a pool of
   512 units per configured seat per tick, shared by all seats".
2. **Work-unit semantics are named but not defined.** A reader cannot
   tell from the reports what one unit buys. State the charged arms once:
   one endpoint-scan candidate, one connector candidate, one A\* heap
   pop, one predecessor link, one path-reversal swap, one route-field
   raster cell cleared, one route-field Dijkstra pop; nothing else is
   charged (danger rebuilds, follower, cover queries are outside the
   pool). Add the consequence that mattered throughout the campaign: a
   full route-field mint costs about 86k units on the practice-sized map,
   so the minter spends whatever the plans leave on most ticks and its
   cost scales with the pool. This is why p50 was the hard metric and why
   "512" is not "twice the A\* work".
3. **"Full planner-state fingerprints match between original and
   candidate within each toolchain."** True for the golden-map diagnostic
   workload at the default pool; say "on the diagnostic workload at the
   default pool", since no fingerprint run was made at 512.
4. **Diagnostic tradeoff understated.** "Traces omit the selected helper
   frames" is right, but the report should say what a defect trace loses
   in practice: because selected helpers call each other
   (`canStand -> clearanceAt -> inBounds`), a bounds defect inside one
   loses up to that whole chain and shows the nearest non-selected framed
   caller (`ROOT_REVIEW_NOTES.md`). It should also say this is a
   permanent production diagnostic change, that the global
   `--stackTrace:on` flag is untouched, and name where the eleven-helper
   list must be kept documented (see section 4).
5. **"No memory-cap increase was needed"** is correct; the report could
   add the stronger true statement that no allocation changed at all, so
   the 4x allowance was never used.
6. **Minor wording.** "Deliberate bounds defect verifies that errors are
   still reported" covers the one-helper `setPosition` path only; the
   chain case is argued, not tested.

## 3. Missing durable links

`QUALIFICATION.md` links only the two result files, the counter review,
README and RAW_ARTIFACTS. A reader arriving cold should also be able to
reach, from it: the frozen cards with their sidecar hashes
(`qualification/PROTOCOL.md`, `current-main/CARD.md`, `fleet/CARD.md`),
the asset pins (`current-main/assets.json`, `ASSET_PROVENANCE.md`), the
build evidence (`current-main/builds.tar.gz`), the validation record
(`checks/at46dd/RESULT.md`, `checks/viewer-at-c651.txt`), the peer
verdicts it cites (`HELD_OUT_PEER_VERDICT.md`, `C6A_PEER_VERDICT.md`,
`H3_PEER_VERDICT.md`, all present in root), the restore audit
(`RESTORE_REVIEW.md`, `RESTORE_CLOSURE.md`), `HARDWARE.md`, and
`LESSONS.md`. One "Evidence index" list would do it.

## 4. What integration must do before the production budget changes

Concrete, from the code and tests as they stand; none of it is done by
the research checkpoint, which keeps the default at 256.

- **The budget is a compile-time constant**, `ColdPlanBudgetPerTick` in
  `src/shell/body_nav.nim`, not a config field. Changing it changes
  replay determinism, so it requires a `GameVersion` bump
  (`sim_types.nim`, currently "63"), regeneration of all nine committed
  `.bitreplay` fixtures with their `record_*.sh` recipes, a viewer
  rebuild and sim-sources stamp per AGENTS.md, and the documentation
  audit before commit.
- **Tests that pin 256:** `tests/test_shell_body_nav.nim` (`workUnits ==
  256` at lines 453, 598; the `planBudgetPerTick` test at 643-652; the
  golden `cold_plan_budget_256_round_robin` test and its
  `assertBudgetBound` at 848-894, whose reference paths and traces are
  computed against the pool size); `tests/test_shell_body_seat.nim:233`.
  These must be re-derived, not just renamed.
- **Stale tool:** `tools/bench_body_port.nim:634,660` already assert the
  single-seat budget against a pooled system and fail today; a budget
  change should fix or retire them rather than leave a second wrong
  constant.
- **Documentation pinning 256:** the design's runtime section
  (`docs/designs/strategy-play-calling-shell-2026-08-29.md:3432-3446`),
  and the `body_nav.nim` module comment (its "few milliseconds" sentence
  was already corrected in `c651dec9`; the 256 figure remains).
- **Diagnostic tradeoff record:** add the eleven-helper list and its
  rationale to AGENTS.md or the shell design so a future maintainer does
  not re-add frames or silently extend the set; add a note that
  `test_shell_body_segment_exact` must be rerun whenever
  `buildClearance` changes, since the H2 proof depends on it.
- **Deployment caveat to carry forward:** on the m5a-class core the
  32-seat stress workloads miss the 24 Hz deadline on most frames at
  either budget; on c6a they meet it. The fleet inventory shows one m5a
  node among 49; a rollout note should say what happens on that class.
- **Nothing here is a knob for operators:** `containment.nim` gates are
  cpu-time gates on other stages and are unaffected; the planning stage
  is outside the body-tick gate by design (`body_nav.nim:21`).

## 5. Verdict on the reports

No false claim of qualification: m5a held-out and c6a are stated as
passed, Intel as pending, publication and the default as unchanged. The
items above are precision fixes (pool and unit semantics, fingerprint
scope, diagnostic-loss wording), a few stale status sentences, one
evidence index, and the integration checklist that a budget change will
need. No new experiment is required for any of them.

PHASE 24 READY
