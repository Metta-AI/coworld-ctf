# Platform legibility data — scoping doc (epic 16d081ab)

Both owner-decided legibility pieces are blocked on the same missing platform
data: **"why #1 is #1"** (`docs/designs/WHY_ONE.md`, PR #497, `tools/glory/why_one.py`
runs OFFLINE against replays) and **endcard v1 = standings delta**
(`docs/designs/ENDCARD_V1_STANDINGS_DELTA.md`, branch `maxwell/endcard-standings-delta`,
not yet merged — verdict "NOT buildable now"). This doc is the metta-side
platform scoping both blockers share, so one metta worker can build from it.

Era stamp: `coworld-ctf main 641fe908` (GameVersion 61 / GLORYVERSION 16,
confirmed live in `src/ctf/sim_types.nim:115` / `src/ctf/glory.nim:301`);
`metta main 68d5c831`.

## 1. What's there today, cited

**`recent_rounds` is schema-ready but the ladder algorithm never fills it.**
The public field (`app_backend/src/metta/app_backend/v2/models.py:3502`,
`LeaderboardEntryPublic.recent_rounds`) is fed from
`orchestration/models.py:776` (`LeaderboardRow.recent_rounds: list[LeaderboardRecentRound] | None = None`).
Two producers exist:
- **Commissioner-owned leagues** (custom scoring, e.g. `pipeline.py`'s
  container path, `commissioners.py:577` `build_recent_rounds`) DO populate it
  — they embed round history when the commissioner publishes its own
  leaderboard snapshot.
- **Platform ladder leagues** — S2 Paintbot's own league, confirmed running
  `standing_aggregation: "rated"` (`ladders/config.py:460`) — go through
  `ScoreRankingAlgorithm.leaderboard()`
  (`app_backend/src/metta/app_backend/v2/ladders/rankings/score.py:212-228`).
  Its `LeaderboardRow(...)` construction never passes `recent_rounds`, so it
  defaults to `None`. Worse: `leaderboard()`'s only input,
  `RankingLeaderboardEntry` (`ladders/rankings/base.py:22-31`), carries just
  `ranking: LadderRankingState` — the CURRENT standing, no round history at
  all — so even wiring the field through `leaderboard()` needs new data
  reaching that call, not just a missing kwarg. **This is the root cause of
  the null, not a bug in the response schema.**

**Per-round data the platform already persists per subject.** `round_results`
(`app_backend/src/metta/app_backend/v2/models.py:2904-2932`, table
`RoundResult`) stores one row per `(round_id, policy_version_id)`: `rank`,
`score`, and an extensible `result_metadata JSONB` column — already the
natural per-subject-per-round home. Standing itself is NOT snapshotted
per-round anywhere (no `standing_history`/`ledger` table exists — grepped
metta-wide); only the current `LadderRankingState.standing` lives in
`league.commissioner_state`, overwritten in place. But the live settlement
path — `apply_ladder_round_update` → `build_round_update`
(`ladders/updater.py:314-377`) → `algorithm.apply_round`
(`ladders/rankings/score.py:97-150`) — has BOTH the pre-round standing
(`standings_by_subject[key].standing.ranking.standing`, read before line 377's
call) and the post-round standing (same field, mutated by `apply_round`) in
hand at the exact same call site, every round, for every scored subject. The
platform can compute "standing before/after a round" **exactly**, server-side,
with zero new queries — it just isn't captured anywhere today.
`backfill_score_standings` (`score.py:254-285`) independently proves the
history is sound: it replays `apply_round` over historical round-score
entries and reproduces the current state exactly, confirming per-round score
entries are durable and the algorithm is order-replayable.

**No per-round deed/glory breakdown exists anywhere platform-side.** The game
reports only totals. `src/ctf/server.nim:5798`
(`runtimeConfig.writeResults(scoresJson)`, guarded by the `resultsUri.len > 0`
branch whose doc comment at `server.nim:5754-5756` says the outcome "would
otherwise live only at COGAME_RESULTS_URI") uploads `sim.playerResultsJson()`
→ `ctfPlayerResultsJson` (`src/ctf/roster.nim:889-1015` for BR/classic). Its
JSON carries, per seat: one glory **total** (`scores[slot] = sim.teamGlory[team]`,
comment at `roster.nim:921-944`), `win`, `kills`, `teamKills`, `hitDamage`,
`teamHitDamage`, `deaths`, `captures`, `shotsFired`, `shotsHit`, and an
`achievements` string-id list — no per-tag magnitude (no CLOSING×N, LONGSHOT,
FIRST!, Clean Sheet amounts). This matches WHY_ONE.md's own finding
byte-for-byte: the only way to a deed breakdown today is decoding the raw
replay offline, exactly what `why_one.py` does.

## 2. Minimal platform additions

### (a) Populate `recent_rounds` — v1, no wire change, unblocks endcard v1

At the settlement call site identified above
(`ladders/persistence.py:205-225`, immediately around `build_round_update`),
capture `standing_before`/`standing_after`/`rank_before`/`rank_after` per
scored subject — the values already exist in local variables at that point —
and write them into that subject's `RoundResult.result_metadata` (JSONB,
already extensible, no migration required for the write). Then extend
`ScoreRankingAlgorithm.leaderboard()` (`score.py:212-228`) to look up each
subject's last N `round_results` rows (already joinable by
`policy_version_id`) and populate `LeaderboardRow.recent_rounds` from that
metadata. Source: `round_results` table + this new metadata field. Cost:
one indexed query per division-leaderboard build (already `idx_round_results_round_id_rank`
exists; a `policy_version_id, created_at` index may be worth adding). No
game-side change — **WIRE-OK not needed**, app_backend only.

### (b) "Why-leader" summary — recommend the no-wire v1 first

Two tiers, in order:
- **v1 (no wire): "the lead rests on N rounds; top rounds by EMA weight."**
  Computable entirely from `round_results.score` + the `rated_k`/
  `rated_clamp_multiple` config already served
  (`GET /v2/leagues/{league}/settings`) by replaying the same
  `rated_k*(1-rated_k)^k` weighting `why_one.py` already uses client-side —
  server-side this is exact (full history in the DB), not the ~5% estimate
  the doc's §6 flags for the offline client-side replay. This ships the
  "how many rounds / which ones" half of the WHY_ONE.md v1 spec without
  touching the game.
  - **v2 (needs WIRE-OK): full deed decomposition** (CLOSING×N / LONGSHOT /
  FIRST! / placement %s) requires the game's results JSON to carry a
  per-seat deed ledger, not just totals — a change to
  `ctfPlayerResultsJson` (`roster.nim:889`) and the results schema
  (`coworld_manifest_paintbot.json`, `additionalProperties: false`). Out of
  scope until the lead makes that call; `why_one.py`'s offline replay-decode
  remains the only source for deed-level "why" until then.

## 3. Sequenced steps for a metta worker

**Step 1 (PR-sized): populate `recent_rounds` for rated-ladder leagues.**
- Add `standing_before`/`standing_after`/`rank_before`/`rank_after` capture
  in `ladders/persistence.py` around the `build_round_update` call, written
  to `RoundResult.result_metadata`.
- Wire `ScoreRankingAlgorithm.leaderboard()` to read recent `round_results`
  per subject and populate `LeaderboardRow.recent_rounds`.
- Acceptance: `curl 'https://.../v2/divisions/{div}/leaderboard?include_recent_rounds=true'`
  on a rated-ladder division returns non-null `recent_rounds` with
  `standing_before`/`standing_after` per entry (extend
  `LeaderboardRecentRoundPublic`, `models.py:3422-3451`, with those two
  fields). Unit test: a rated-ladder fixture asserting
  `entries[0].recent_rounds[0].standing_after - standing_before` matches a
  hand-computed `rated_k` blend (mirror `test_score_ranking.py`'s existing
  rated-aggregation tests).
- Client-side consumer: the endcard's **shell page** (per
  ENDCARD_V1_STANDINGS_DELTA.md Gap 1/2 — the wasm client has no fetch
  capability and no player_id key; only a shell-hosted, authenticated page
  can call this endpoint) fetches this leaderboard endpoint directly. No
  wire change, no `static-replay-viewer` rebuild.

**Step 2 (PR-sized, optional/follow-on): server-side EMA-weight summary.**
- A small endpoint or leaderboard-row addition: for a given subject, "top N
  rounds by EMA-weighted contribution to current standing" (exact replay of
  `apply_round`'s math over the subject's full `round_results` history).
  Feeds the WHY_ONE.md v1 row's "rests on N rounds" line without a replay
  decode.
- Acceptance: a test asserting the weights sum to ~1.0 and the top-weighted
  round matches an independently-computed reference (mirror
  `why_one.py`'s own approach, now exact instead of ~5%-estimated).
- Explicitly NOT in scope for either step: any per-deed/tag breakdown (needs
  WIRE-OK, §2(b) v2) and the League Replayer's `standings.ladder[]` footer
  (a separate, smaller surface — see WHY_ONE.md §3 — untouched by this doc).
