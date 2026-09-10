# "Why #1 is #1" — expandable standings row (Phase 2b, epic 16d081ab)

Owner's favourite legibility idea (journey-quiz decision R10, internal tracking,
not public): an expandable row under the
standings leader. **Deeds first** (causal, derivable now from real replays — this
doc + `tools/glory/why_one.py`). **The brain's style second** (heat/carry/ally-
stack tempo — needs S3 risk bands before it can be shown; placeholder here).
Rejected by the same decision: a one-line "why the winner won" gimmick on the
endcard, and any 16-player tally (messy).

Era stamp: this repo is at `main 9b6019aa` (GameVersion 61 / GloryVersion 16 per
PR #477, merged but **not yet live** on any Paintbot build). The LIVE platform,
read 2026-09-09, is still on coworld_version 0.7.36x / wire GameVersion 59-60 /
GloryVersion 15 — the same era the S1 census (PR #483) and its addenda (#488,
`maxwell/glory-attribution`) measured. Every number below is READ from that live
era, not from repo HEAD; re-run `tools/glory/why_one.py` before reusing any of it
once GloryVersion 16 goes live (`discover_cohort.py`'s method, unchanged).

## 1. Row content spec

### v1 — DEEDS (ship-able now, this PR)

For the current #1 (or any requested rank), over a recency window of completed
rounds:

- **Which named scoring events (tags/marks in public vocabulary) built the
  lead**, each as a share of the defining match's own magnitude — a deed's
  share already includes any ground/heat/ally-stack bonus baked in by the sim
  at mint time (v1 does not peel those apart, see v2 below).
- **How many rounds the lead rests on** — not "since when," but a weighted
  count: which specific recent rounds still meaningfully move the standing
  today, using the same EMA the ladder itself runs (`rated_k=0.05`,
  `rated_clamp_multiple=150`, half-life ≈ 13.9 rounds).
- **Recency** — the served rating is an exponential moving average
  (`ctf-standing-is-an-ema-not-a-max`), not a lifetime max; the row must say
  "as of the last N rounds," never imply a permanent trophy.
- **Delta vs #2** — the lead's size stated as a percentage of the leader's own
  standing (never a bare number — design-system.md's "don't show a number
  without context").

Every number carries: a share (% of what), a rank/comparison (vs #2, vs the
window), and a count (how many rounds/mints it rests on) — no bare stat tiles.

### v2 — STYLE (placeholder, not built here — needs S3 risk bands)

The same recut fold also carries a HEAT / CARRY / ALLY-STACK / ENEMY-GROUND
sub-factor inside each deed's folded amount (`ctf-heat-is-unexploited-by-the-
field`, `ctf-monet-matches-leaders-on-economy`). Peeling that apart into "this
brain runs hot / plays it safe / never leaves home ground" is a real, already-
prototyped measurement (S1b `attribution_decompose.py`, branch `maxwell/
glory-attribution`, 100.00% reconciled) but requires a PRIVATE, ANALYSIS-ONLY
instrumented `extract_events` binary that patches one debug field in a local
copy of `src/ctf/sim.nim` — never shipped, never landed, and out of this task's
boundary (no engine/wire changes). It is also gated on the owner's S3 risk-band
work per the task brief. The row's UI reserves a second, initially-locked
section for it (see the mock) so v1 doesn't need a redesign when v2 lands.

## 2. Exact copy for today's real #1

Generated 2026-09-09 by `tools/glory/why_one.py --rank 1 --window 150` against
the live S2 league (`league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7`, division
`div_aa7825db-262f-4a62-b01a-177c1b48f7ee`). Full JSON:
`/tmp/why_one/report.json` (not committed — regenerate on demand, the platform
moves hourly).

Identity, per doctrine (`ctf-no-source-attribution-in-public`, `identity rule`
— cite the policy_version id, never a name-prefix attribution): **pv
`6d278f56-2c12-4ce7-8de7-20ec020d74c8` (v38)**. The live board today happens to
label this entrant `apex:v38` and player `softmaxclaudius-t2` — that label is
the entrant's own public choice already visible on the leaderboard row this
expands under; this doc does not add or launder any naming of our own.

> **#1 · pv `6d278f56` · standing 647,002**
> Leading #2 by **146,140 (23% of this lead's own standing)**. Rank #1 for the
> last **21 of the last 150 rounds** sampled.
>
> **This lead rests on 3 rounds, not a long streak.** Three matches in the last
> 150 — r4506, r4510, r4528 — each hit the platform's absolute score ceiling in
> a single match (2^24, the recut product cap) and together explain roughly
> **84% of the current standing's weight** (46% / 21% / 17%). The most recent
> one is fully decoded below; the other two happened in an older scoring build
> this tool can't yet re-decode locally (see the gap below — the fact that they
> hit the ceiling is still directly observable from the platform's own
> reported scores, just not their deed breakdown).
>
> **What round r4528 was actually made of** (won, hit the score ceiling — the
> true total before the ceiling was ~15x higher):
> - **CLOSING × 6 — 40%.** Survived six separate ticks of the tightening zone.
>   This is the single biggest leg, and most of it is staying alive, not
>   fighting.
> - **Longshot (rank-climb, first to claim it this match) — 13%.**
> - **The win itself — 11%.** Every win folds in a flat ×8; winning is an
>   adversarial outcome (15 other seats + the zone), not something the row can
>   claim as "skill."
> - **FIRST! tag — 9%.** First tag of the match.
> - **LONGSHOT tag — 7%.** A kill from long range.
> - **Survived to the final 2 — 7%. Final 4 — 6%. Final 8 — 4%.** Placement
>   milestones for outlasting the field; each mints once, automatically, for
>   surviving that deep.
> - **Clean Sheet (rank-climb) — 4%.** Free for any seat with zero
>   friendly-fire incidents — most solo seats get this by default.
>
> *Read together: this match's score is dominated by surviving the zone and
> making the final two, not by a string of kills — one LONGSHOT and one FIRST!
> tag are the only kill-credit lines in the whole breakdown.*

## 3. Where this row lives

Two candidate surfaces, and they are **not the same repo**:

- **softmax.com Observatory's League standings list** (the "You tab standings
  column" / league leaderboard the owner is picturing when they say "standings
  row") — this is the natural home: a ranked list of many entrants, exactly
  where an expandable per-row disclosure belongs (design-system.md §4's
  disclosure pattern: the row itself becomes the card's header when expanded).
  **This surface lives in the `metta` monorepo (`web/softmax.com`), not in
  `coworld-ctf`.** Per standing doctrine (`ctf-nav-is-james-we-supply`), nav
  and this page are James's; our job is to hand over the adapted spec (this
  doc) and, if asked, a coded component — never to merge it ourselves from
  here. **Nothing in this PR touches that repo.**
- **Our own `client/league_replayer.html`** (built into
  `static-replay-viewer/league.html`) — a small **head-to-head "standing
  footer"** already shipped in this repo, showing rank/score for the TWO
  competitors in whatever match replay is loaded (Observatory injects it via
  a `?standings=` base64 param: `{division, competitors:{red,blue},
  ladder:[{name,rank,score,you}]}`). This is buildable from `coworld-ctf`
  without touching James's nav — but it is a 2-competitor footer inside a
  single match replay, not a ranked list, so at most it could grow a compact
  "why" teaser for the seat being watched, not the full expandable row the
  owner described. **This PR does not touch it** — the task boundary requires
  the lead's explicit GO before any `static-replay-viewer` rebuild, and this
  surface would need a real product decision about whether a 2-up footer is
  even the right home for the idea.

**What this PR actually delivers, fully inside `coworld-ctf`, no nav touched:**
the data tool (`tools/glory/why_one.py`) and a **static, standalone HTML mock**
(`docs/designs/why-one/index.html`) of the row in house style — a design
artifact for the owner/James conversation, not a wired surface.

## 4. API / data gap

Checked directly against the live API (not assumed):

- **`GET /v2/divisions/{id}/leaderboard`** — the only public standings
  endpoint — returns `rank, player_id, player_name, score, score_label,
  rounds_played, episode_wins, episodes_played, win_rate, policy_label,
  recent_rounds`. `episode_wins`/`episodes_played`/`win_rate` are `null` on
  this league; **`recent_rounds` is `null` even with
  `include_recent_rounds=true`** (a second, smaller gap worth flagging — the
  field this call is supposed to populate never does, on this league, as of
  2026-09-09). **No `pv_id` and no deed/episode data at all** — the
  policy_version id has to be read from a DIFFERENT endpoint
  (`GET /v2/rounds/{id}` → `results[].policy_version.id`) per round, not from
  the leaderboard row.
- **There is no server-side "why" endpoint anywhere in the public API.** The
  only way to get a deed breakdown is to download the raw replay
  (`episodes[].replay_url` from `GET /v2/rounds/{id}/episodes`) and run a wire
  decoder against it — exactly what `why_one.py` does. This is the load-
  bearing gap: **the platform can tell you a rank and a score, never a
  reason.** Any real "why #1 is #1" surface needs either (a) this kind of
  offline replay-decode job run periodically and cached, or (b) a new
  platform endpoint that surfaces the same per-deed ledger server-side. This
  PR does neither — it proves the decode is possible and exact (see
  Verification), not that it is cheap enough to run live on every leaderboard
  render (150 rounds × up to 12 episodes/round × a replay download + a Nim
  subprocess is not a page-load operation).
- **The replayer's injected `standings.ladder[]` schema**
  (`{name, rank, score, you}`) has no field for deed data either — extending
  the small standing-footer surface (§3) would need Observatory to inject
  more, or our client to make its own authenticated call, either of which is
  new scope beyond this task.

## 5. Verification

`tools/glory/why_one.py`, run read-only against the live league:

- Standings/round pulls reuse `tools/ladder/{ctfapi,standing_replay}.py`
  (already in this repo) — same cache, same `pull_ledger`-shaped round
  records, same served EMA constants (`rated_k=0.05`,
  `rated_clamp_multiple=150.0`, `sum_top_k=12`, confirmed live via
  `GET /v2/divisions?league_id=...` → `settings.ladder.ranking`, 2026-09-09).
- Deed decode **never trusts an unreconciled result**: it downloads the real
  replay, extracts it with a locally-built `extract_events` (the S1 census's
  own binaries, not
  committed here — private per-machine build artifacts, same as the census's
  own doctrine), reconstructs the seat's final score by the exact recut-fold
  method (seed 1, fold `amount>1` events, halve per friendly-fire, ×8 on win,
  cap at 2^24), and **only accepts the decode if it reproduces the
  platform's own `participant_scores` value exactly**. Round r4528's decode
  reconciled to `16,777,216` (the cap) exactly. Rounds r4506/r4510 were tried
  and **discarded, not guessed**: both replay hash-mismatch against the two
  locally available extractors, meaning they are from an earlier
  GloryVersion/GameVersion sub-era than the census cohort covers (their
  `coworld_version`s, 0.7.357/0.7.359, predate the census's 0.7.361 floor) —
  reported as a named gap in the tool's own output, never silently
  misattributed (this is exactly the failure mode `tools/glory/README.md`'s
  own "TRAP" section warns about).
- The defining-episode picker ranks candidates by **EMA-weighted
  contribution to the CURRENT standing**, not raw score — three rounds tied
  at the exact product cap (2^24) on the first pass, and a naive
  highest-score-first pick would have surfaced the three OLDEST, undecodable
  ones instead of the most recent, decodable, highest-weight one (r4528).
  Fixed and re-verified (see `tools/glory/why_one.py`'s `defining` selection
  comment).

## 6. Not verified / open risks

- **The EMA reconstruction is a labeled estimate, not exact.** The
  `rated_k*(1-rated_k)^k` weighting used for "how much of the standing each
  round explains" ignores clamp interactions (`rated_clamp_multiple=150`);
  replaying the served formula itself over the 150-round window reproduces
  the live leaderboard standing within ~5% (647,002 reconstructed component
  math vs the live board), not exactly — a full reproduction needs this
  player's entire ~800-round history, not just a window. Good enough to rank
  which rounds matter; not exact enough to cite as the standing's precise
  decomposition.
- **Two of the three "cap cluster" rounds are not deed-decoded** (§4/§5) —
  the row's honest copy above says so explicitly rather than inferring their
  contents from r4528's pattern. A same-recipe guess would be exactly the
  kind of confident-wrong attribution the census's own doctrine warns
  against.
- **This is one specific #1 on one specific day.** The tool supports
  `--rank N` for any row and was only exercised at rank 1 for this doc; it
  has not been run across all 16 ranks or checked for a rank whose lead is
  NOT cap-driven (a "genuinely graded" leader would produce a very different,
  probably more interesting, row — worth a follow-up pass).
- **Style v2 is unbuilt**, by design (see §1) — the mock's second section is
  a visibly-locked placeholder, not a stub that silently shows nothing.
- **No load-testing of the decode cost** for a live "expand this row" click —
  see the API/data gap note on why this can't be an on-demand page-load
  operation as built today.
