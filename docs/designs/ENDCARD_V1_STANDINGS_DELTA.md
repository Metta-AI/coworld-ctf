# Endcard v1 — Standings Delta (Phase 2, epic 16d081ab) — BLOCKED, doc only

Owner decision (`~/.ctf/knowledge/stranger-walk/00-owner-decisions-2026-09-09.md`):
endcard v1 shows each seat's change in SEASON STANDING caused by the episode just
played, before the pact story (v2). This doc is the STEP 1 data-availability check
from the S2-lead task brief — no client/bundle code changes ship with it.

Era stamp: repo at `main 641fe908` (GameVersion 61 / GLORYVERSION 16). All API
probes below were run live against the platform on 2026-09-09 and logged to
`/tmp/endcard-v1/*.log`. League: `league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7`
(Paintbot S2), division `div_aa7825db-262f-4a62-b01a-177c1b48f7ee` (Competition).

## Verdict: NOT buildable now — not even live-only

The task brief's fallback was "v1 may be LIVE-only." It is worse than that: three
independent gaps stack, and none of them is a "wait for the round to finish"
problem — they are missing plumbing.

### Gap 1 — the client has zero outbound API capability

`grep -n "fetch(\|XMLHttpRequest\|new URL(" client/*.html client/*.js
static-replay-viewer/*.js` (excluding the wire websocket URL construction in
`broadcast_core.js:411/415` and `player_client.html:283/437`, which only ever
build the SAME-origin game websocket) returns zero hits for any call to the
Observatory API. Every client HTML/JS file (`global_plus_pov.html`,
`chrome_common.js`, `broadcast_core.js`, `player_client.html`,
`static-replay-viewer/*`) is a pure wire consumer: it reads frames off the game
websocket (or a loaded `.bitreplay`) and renders. This is by design — the
League Replayer and static replay viewer both have to work with no auth and no
network path to `softmax.com` (`ctf-league-replayer-needs-a-loaded-replay`).
Adding a live cross-origin fetch to the endcard is a new capability, not a
data lookup.

### Gap 2 — no seat → player_id key reaches the client at all

The wire's per-player identity is the SEAT NAME, confirmed again here
(`ctf-reward-identity-is-seat-name`): the `over` control record carries
winner/lives/BR placement + per-player kills/deaths/captures/multikills/
teamkills/alive/lives/hp/carry/perks, keyed by seat, never by `player_id`.
`grep -rniE "round_id|episode_id|player_id" client/` returns zero hits in any
client file. The league identity (player_id, policy_version, round_id) is
attached server-side only, at `runtimeConfig.resultsUri` /
`sim.playerResultsJson()` (`src/ctf/server.nim:5798`, doc comment
`server.nim:5749-5757`: "the outcome would otherwise live only at
COGAME_RESULTS_URI, which a spectator with the bytes cannot read"). That
upload is the league-side reporter's job and is never echoed back down to the
client or into the replay file. So even with a hypothetical fetch capability,
the endcard has no key to look up "which player_id/policy_version was seat 7"
for a live episode, and a saved `.bitreplay` has even less — replays carry no
round_id/player_id at all, only seat names and engine state.

### Gap 3 — no populated per-round standing history, even with player_id in hand

Standing is the league's rated EMA over `round_score` (confirmed live,
`GET /v2/leagues/{league}/settings` → `ranking: {algorithm: "score",
round_scoring_rule: "sum", sum_top_k: 12, standing_aggregation: "rated",
rated_k: 0.05, rated_clamp_multiple: 150.0, initial_standing: 0.0,
season_leg_transform: "none"}`, logged
`/tmp/endcard-v1/league_settings_probe.log`). `season_leg_transform: "none"`
also answers the task brief's other open question: the geometric-mean
"Typical episode" transform is NOT armed as of this read — no such label is
needed yet.

The leaderboard endpoint (`GET /v2/divisions/{div}/leaderboard`) returns the
CURRENT standing only (`score` field) plus a `recent_rounds` field that
**exists in the schema but is `null` on every entry**, confirmed live with
`include_recent_rounds=true` (note: the param is a bool, not a count —
`tools/ladder/ctfapi.py`'s `include_recent_rounds=32` default is stale/wrong
type against the current API, 422s until fixed; logged
`/tmp/endcard-v1/leaderboard_probe4.log`). There is no "standing as of round
N" field anywhere in the public API today.

The only known way to reconstruct "standing before this round → standing
after" is `tools/ladder/standing_replay.py`'s full-ledger EMA replay: pull
every completed round in the division (currently ~100 rounds visible per the
`/v2/rounds` pagination window, `ctf-rounds-endpoint-filter-and-offset-traps`),
fetch each round's `results` + `episodes` (2 calls/round), and fold
`standing <- standing + rated_k * (clip(round_score, s/M, s*M) - standing)`
forward from `initial_standing=0` up to and including the round of interest.
That is ~200+ authenticated API calls and real compute — not something a
browser can do at endcard-render time, live or replayed, without a server-side
precompute step.

## What would make v1 buildable

Either of these, metta-side, closes all three gaps at once for the LIVE case
(replay-after-the-fact would still need round_id/player_id burned into the
replay file, a separate ask):

1. **Populate `recent_rounds`** on the leaderboard/standings response with
   `{round_id, standing_before, standing_after}` for at least the entrant's
   most recent round — the field already exists in the schema, it is just
   never filled in. This is the smallest fix: no new endpoint, just wiring an
   existing field.
2. **A per-round standings-delta field** on `GET /v2/rounds/{round_id}` (or a
   new `/v2/rounds/{round_id}/standings-deltas` endpoint) returning
   `{player_id: {rank_before, rank_after, standing_before, standing_after}}`
   computed at round-completion time (the platform already has the full
   history in hand at that moment; this is a write, not a client-side
   replay).

Either one still requires (Gap 1) a client-side fetch capability and (Gap 2) a
seat→player_id key reaching the client — smallest version of Gap 2 is to
extend the `over` control record with `player_id`/`round_id` per seat when the
server was launched with a results URI configured (i.e., a real league match,
not a local dev game), which is a wire change and therefore needs a WIRE-OK
decision from the lead before any implementation.

## Scope of this PR

Doc only. No `client/`, `static-replay-viewer/`, or `src/` changes. No bundle
rebuild required.
