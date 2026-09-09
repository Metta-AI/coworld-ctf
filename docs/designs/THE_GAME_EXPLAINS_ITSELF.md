# The game explains itself — moment inventory + plan (Phase 2, epic 16d081ab)

Umbrella task 42879588. Obeys `~/.ctf/knowledge/stranger-walk/00-owner-decisions-2026-09-09.md`
(the journey quiz) and the glory owner model (pinball scoring, many multipliers, jackpots rare
and earned, "why #1 is #1"). Planning only — no code changes ship with this doc.

**Era stamp:** repo at `main 588f1ac7` (GameVersion 61 / GLORYVERSION 16). GLORYVERSION 17 is
staged but not merged (`cbe57d85`, "S6 SHIP DRAFT", also bumps GameVersion 61→62) and retunes
kill/heat/territory/stack deed pricing (`catalogV3Reprice`) — every piece of copy below names the
**deed** (VICTORY, RESCUE, FINAL 8, …) or the **mechanism** (a running multiplier, a shared pact
ring), never a specific ×N value, so it survives that bump unedited.

**This doc does not duplicate sibling lanes' work** — it maps them into one picture and cites them:
`docs/designs/FRONT_DOOR.md` (door lane, phase2-door), `docs/designs/WHY_ONE.md` (why-#1 lane,
phase2-why1), `docs/wiki/RESTRUCTURE-PLAN.md` + `AUDIT.md` (wiki lane), `docs/designs/
ENDCARD_V1_STANDINGS_DELTA.md` (#505, this same worker), the score-bug strip PR (#498) and the
endcard PR (#475).

---

## A. The moments

Each moment: **today** (surface + file:line) · **wrong belief** (real evidence) · **must say**
(public tagging-vocabulary copy) · **data** (on the wire? where) · **surface** · **milestone** ·
**effort**.

### 1. The door's first screen
- **Today:** `softmax.com/paintbot` — league page, live replay, standings, a "Compete → Submit a
  policy" CTA. Its href is literally `/#production` — a no-op anchor, not a submission path
  (`FRONT_DOOR.md` §1a, "THE DOORSTEP BUG", reproduced live 2026-09-09 on the single most
  on-the-nose CTA on the page).
- **Wrong belief:** none logged directly, but real cost — sonnet-a spent 9 of ~15 pre-signup
  navigations inside a wiki banner reading "Verified against GV24 / Glory 12," three eras stale
  at walk time (`FRONT_DOOR.md` table row 2).
- **Must say:** the hook, verbatim (R8): *"My brain fights other people's brains, and that
  produces a legible testbed for agent behavior."* Then why-care, then how-it-works — first
  minute, in that order (R7).
- **Data:** none — static copy + a correct href.
- **Surface:** door page (metta/softmax.com).
- **Milestone:** M1.
- **Effort:** S, platform (metta repo). Owned by `phase2-door`/`door-build`/`door-poc-fix` —
  registered here, not re-planned.

### 2. A round starting (objective, the 16, the zone)
- **Today:** no on-screen objective/rules banner at kickoff — grepped `client/replay_broadcast.
  html` for kickoff/objective/ready copy; the win-condition chip ("LAST TEAM STANDING" / "LAST COG
  STANDING", `endcardWinCondition`, line 6634) is **endcard-only** text, never shown at round
  start. The zone's visual shrink on the board is the only kickoff-time cue.
- **Wrong belief:** none logged for a stranger who visits the door first (M1 took 19s) — but a
  viewer who drops straight into a live/replayed round with no door visit gets zero on-screen
  framing.
- **Must say:** one line at kickoff, e.g. "16 seats drop in. Last one standing wins. The zone
  closes."
- **Data:** on the wire already at frame 1 — roster, `elim`/solo flags, zone geometry
  (`broadcast.nim` state block).
- **Surface:** HUD toast / top-band, first ~3s of a round.
- **Milestone:** M1.
- **Effort:** S, client-only.

### 3. A tag/kill
- **Today:** already well covered. `#killfeed`/`feedRow` (client/replay_broadcast.html:8131,
  `pushFeed`:5930) prints a row in public vocabulary — `"<name> tagged, <hp> hp left"`
  (line ~8197) — for every tag, plus the strip's intent word flips to "tagging" for ~3s
  (`intentWordFor`, line 3505-3517, decay window `INTENT_TAG_WINDOW_TICKS`).
- **Wrong belief:** none found.
- **Must say:** (already correct) — no change.
- **Data:** on the wire (`kill` events).
- **Surface:** kill feed + strip.
- **Milestone:** M2/M3.
- **Effort:** none — verify-only, not a fix.

### 4. A POP (deed minted — which deed, why it paid)
- **Today:** `renderGloryPops` (line 6052) draws the deed label + a ×N or +NG figure
  (`gloryPopText`, line 6025) with a staggered "hero multiplier slams in first, label follows"
  choreography (`HERO_STAGGER_TICKS`, line 6041). Achievement claims render name-only, never an
  amount (line 6026). This is genuinely good, deed-named, tagging-vocabulary copy already.
- **Wrong belief:** sonnet-a's early BELIEF log guessed at "live per-team Glory multiplier
  badges" before confirming the real mechanism via digging — the pop system exists but a
  first-time viewer isn't told **that a pop IS the multiplier changing**, only shown the effect.
- **Must say:** (content is fine) — the gap is a first-appearance legend, not the pop copy itself;
  folds into fix #9 below.
- **Data:** on the wire (`sim.gloryPopsJson()`, broadcast.nim:1108).
- **Surface:** strip / pop overlay.
- **Milestone:** M2/M3.
- **Effort:** none beyond the legend fix (#9).

### 5. The MULTIPLIER moving (heat, pact/joint-act, closing time)
- **Today:** the score-bug's own glory figure renders AS the multiplier once the "recut" economy
  is sampled armed (`renderGloryFigure`, line ~3585-3600, `×2,304` with thousands-grouping and a
  pulse). Heat renders as a flame icon whose class tier (`heat-warm`/`heat-hot`/`heat-blazing`)
  comes from `heatTierFor` (line 3442) — a rate-of-glory-gain heuristic, not a raw wire field.
  **Zero `aria-label`/`title` exists anywhere on the flame, the multiplier figure, the pact ring,
  or the intent word** (grepped the whole file — no hits) — nothing explains any of them on
  hover/tap.
- **Wrong belief:** sonnet-a's logged BELIEF conflated "multiplier badges" with a UI element that
  doesn't exist as badges — the real mechanism (the score figure itself IS the multiplier) had to
  be dug out from the replay rather than read off the screen.
- **Must say:** first appearance per session — "this number is the team's running multiplier,
  every pop stacks it" / "heat = scoring fast, keeps climbing while it's hot."
- **Data:** on the wire (`heat` key, broadcast.nim:416; the glory figure itself, teamGlory). One
  real gap: **no wire flag says which economy (additive v12 vs multiplicative v13 "recut") is
  live** — the client infers it by sampling every team's glory at the first 'playing' frame
  (`sampleRecutArmed`, line ~3512-3525, own comment: "The wire carries NO per-episode flag for
  which economy is live... no realized-ruleset stamp today").
- **Surface:** strip (score-bug figure + flame icon).
- **Milestone:** M2/M3.
- **Effort:** S client-only for the first-appearance legend; **WIRE-OK candidate** for a real
  `economy` stamp replacing the first-frame inference (see Plan §B, batch item).

### 6. A PACT forming/dissolving
- **Today:** shipped in #498 — a shared outline ring, colored in the partner's team color, on
  every member square of both partnered cells (`.br-cell.pact .br-cell-life`, CSS line 375-376;
  JS toggle, line 4219-4221). Reads `tr[team].pact` verbatim off `broadcast.nim`'s
  `pactPartnersJson` (line 367) — no inference. Zero lines on the field, per R11.
- **Wrong belief:** none logged post-#498 (shipped same day as this doc); pre-#498 a pact was
  wire-carried but invisible.
- **Must say:** first appearance — "these two share a pact: they won't fight each other."
- **Data:** on the wire (`pact` key, broadcast.nim:419).
- **Surface:** strip (ring) — no legend today (same gap as #5).
- **Milestone:** M2/M3.
- **Effort:** S client-only (legend, folds into #9).

### 7. A downed/rescue
- **Today:** `downed` state is on the wire and rendered (`p.downed`, broadcast.nim:522/923/964;
  strip intent word "downed", replay_broadcast.html:3507). A RESCUE is a real, priced deed
  (`dRescue`, `glory.nim:2552/3487`, label "RESCUE") and **does** mint a pop via the normal deed
  system. But the **downed state itself has no on-screen label** — grepped for "rescue" across
  `client/replay_broadcast.html`: zero hits. A spectator sees a cog go prone with no text saying
  it can still be rescued, is not yet eliminated, or has a countdown.
- **Wrong belief:** not directly logged (no run described a downed cog), but consistent with the
  same "state has no legend" gap as #5/#6.
- **Must say:** "downed — can still be rescued" as long as the state holds.
- **Data:** on the wire (`downed`, `rescuedTick`, `rescues` — `sim_types.nim:3412/3418`).
- **Surface:** strip / on-cog label.
- **Milestone:** M3.
- **Effort:** S client-only.

### 8. The final four
- **Today:** a real, priced placement-ladder deed (`dFinal8`/`dFinal4`/`dFinal2`, `glory.
  nim:292,2579,2757,2989`) that pops through the normal deed system (#4) the instant the
  threshold crosses.
- **Wrong belief:** none found.
- **Must say:** (already correct via the pop) — no change.
- **Data:** on the wire.
- **Surface:** strip pop.
- **Milestone:** M3.
- **Effort:** none.

### 9. The win
- **Today:** `endcardWinCondition` (line 6598) names the actual rule the server applied (WIPE,
  MERCY, FULL TIME, LAST TEAM STANDING, etc.) — real engine truth, not a guess, with an explicit
  comment trail explaining a #364 regression this code deliberately avoids repeating.
- **Wrong belief:** none found — this surface is already solid.
- **Must say:** (already correct) — no change.
- **Data:** on the wire (`o.endRule`, `o.winner`, `o.draw`, broadcast.nim `over` block, line
  1321+).
- **Surface:** endcard headline.
- **Milestone:** M3.
- **Effort:** none.

### 10. The ENDCARD (what each seat earned and why; standings delta)
- **Today:** `renderEndcard`/`renderEndcardRows`/`renderEndcardBR` (lines 7296/6708/7086) show
  per-seat kills/deaths/captures/badges (`endcardBadge`, line 6647) and the achievement feed
  (broadcast.nim `over.achievements`, per-player rank/xp already on the roster). This is solid
  **within the episode**. It does **not** show season-standings delta — see #505's own verdict.
- **Wrong belief:** opus-a's logged BELIEF: *"league standing = your **best round** (so one
  exceptional round sets your rank)"* — this is **wrong**: standing is a decaying rated EMA
  (`ranking.standing_aggregation: "rated"`, `rated_k: 0.05`, confirmed live,
  `ctf-standing-is-an-ema-not-a-max`), and nothing on the endcard or standings page corrects it.
- **Must say:** "your standing moved because of this episode's score, blended with your recent
  rounds — it decays, it's not a max."
- **Data:** **NOT buildable, even live-only** — `docs/designs/ENDCARD_V1_STANDINGS_DELTA.md`
  (this worker, #505) found three stacked gaps: (1) the client has zero outbound API capability
  by design, (2) no seat→player_id/round_id key reaches the client at all, (3) the leaderboard's
  `recent_rounds` field exists in the schema but is `null` on every entry today — there is no
  "standing before/after this round" anywhere in the public API.
- **Surface:** endcard (v2, blocked).
- **Milestone:** M7/M8.
- **Effort:** L, **platform** (metta) — see Plan §B.

### 11. The STANDINGS page (typical episode vs best round; why #1 is #1)
- **Today:** `metta/web/softmax.com/.../DivisionLeaderboard.tsx` and `UnifiedLeaderboard.tsx`
  (`docs/surfaces/standings.md` in metta) render rank/name/score with medal colors and a "You"
  row — no expand, no "why," confirmed by grep (only navigation `onClick`s, no deed/why content).
- **Wrong belief:** same as #10 (opus-a's "standing = best round"); separately, `season_leg_
  transform: "none"` is confirmed live today (#505's league-settings probe) — the geometric-mean
  "typical episode" framing discussed in the glory lane's S2/S3 rate decision is **not armed**,
  so any copy describing a "typical vs best" transform today would itself be a new wrong belief.
- **Must say:** current, accurate state only — "your rating is a decaying average of your recent
  rounds' scores" (no "typical episode" language until `season_leg_transform` actually changes).
- **Data:** `docs/designs/WHY_ONE.md` (phase2-why1 lane) already specs a **v1, ship-able-now**
  version keyed on real replay data (deeds, share of the lead, round count, delta vs #2) — this
  doc registers it as the top platform-adjacent fix rather than re-deriving it. v2 (brain "style":
  heat/carry/ally-stack tempo) needs S3 risk bands, correctly deferred there.
- **Surface:** standings page (metta).
- **Milestone:** M7/M8 ("WHY #1 IS #1" is R10, the owner's favorite).
- **Effort:** M (v1 deeds), owned by `phase2-why1` — registered, not duplicated.

### 12. A rank moving after a resubmit
- **Today:** sonnet-a's real M8 run (retuned `recall_seconds` 8.0→6.0, resubmitted, "observed rank
  respond," `STATUS-2026-09-09.md`) had to manually diff two standings-page reads — nothing in
  product states "your rank moved by N because of your last change."
- **Wrong belief:** same standing-model gap as #10/#11 generalizes here — without knowing standing
  is an EMA, a rank move after one round looks like full attribution to the latest change when
  it's actually blended with recency-weighted history.
- **Must say:** "rank moved — mostly your latest round, still carrying some of your last N."
- **Data:** same blocker as #10 (no per-round standings-delta anywhere in the API).
- **Surface:** standings page / endcard v2.
- **Milestone:** M8.
- **Effort:** L, platform — same fix as #10, not a separate ask.

---

## B. The plan — ordered PR-sized fixes

Priority = stall length × wrong-belief frequency × cheapness. **Buildable now** = client-only, no
platform/wire dependency. **WIRE-OK** = needs one new/changed field, batched below. **Platform** =
needs metta-side work this repo cannot ship.

| # | Fix | Moment | Milestone | Surface | Data status | Effort | Acceptance check |
|---|-----|--------|-----------|---------|-------------|--------|-------------------|
| 1 | `coworld run-episode --run` argv trap — the CLI's own `--help`/error text (or a scaffolded run command in the starters template) states the one-token-per-flag contract inline, so a builder never has to discover it by trial and error | (build loop, not a viewing moment) | M5 | CLI (`policies/starters/`, `tools/`) | buildable now | S | a fresh `coworld run-episode --help` (or a failing invocation) prints the fix; re-run the exact sonnet-a repro and confirm zero minutes lost |
| 2 | Kickoff objective banner ("16 seats drop in. Last one standing wins. The zone closes.") | round starting | M1 | HUD toast | buildable now | S | screenshot on a real replay, first 3 seconds |
| 3 | Strip legend/first-appearance tooltips: pact ring, heat flame, multiplier figure, intent word, downed state — one `aria-label`/`title` (and a first-appearance toast) each, since none exist today | multiplier, pact, downed | M2/M3 | strip | buildable now | S–M | screenshot showing hover/tap text on each of the four elements on a real replay |
| 4 | Doorstep CTA href fix (`/#production` → the real submit/participate path) | door's first screen | M1 | door page | platform (metta) | S | live click-through test; owned by `phase2-door` — register only, do not duplicate |
| 5 | "Why #1 is #1" v1 (deeds-first expandable standings row) | standings page | M7/M8 | standings page (metta) | buildable now per `WHY_ONE.md`'s own data source (real replays) | M | owned by `phase2-why1` — register only, highest-leverage single fix per the owner's own R10 ruling |
| 6 | Wiki stale-era sweep: `glory-season-2`'s documented `winAsMultiplier` state (says "rolled back," live platform has it armed again) and the 27 pages still stamped GV24/Glory12 | how scoring works | M2 | wiki | buildable now | M | each page's own era banner matches a live probe, not a stale one |
| 7 | GitHub-only sign-in disclosed before the attempt (one line near the sign-in CTA + in the Field Guide's "how to submit" chapter) | (M6 blocker) | M6 | door + wiki | mostly buildable now (wiki copy); CTA line is platform | S | a fresh stranger's transcript shows zero time spent looking for an email/password option |
| 8 | Standing-model correction, everywhere it's implied: endcard, standings page copy, Field Guide — state the EMA/decay model, retire any "your score = your rank" implication | endcard, standings, rank-move | M7/M8 | endcard + standings + wiki | buildable now (copy) | S | copy audit: grep for any "best round"/max-implying language and confirm none remains |
| 9 | Realized-economy wire stamp — replace `sampleRecutArmed`'s first-frame inference with a real `economy` field so a late-joining client (or a client that only sees mid-fight frames) never falls back to "classic, unknown" incorrectly | multiplier | M2/M3 | wire + strip | **WIRE-OK batch** | S | a client that joins after kickoff still renders `×N` correctly on a recut-armed round |
| 10 | Endcard v1 standings-delta, gap 2: seat→player_id/round_id on the `over` control record when the server has a real results URI (a real league match) | endcard, rank-move | M7/M8 | wire | **WIRE-OK batch** | M | a live episode's `over` record carries a resolvable player_id/round_id per seat |
| 11 | Endcard v1 standings-delta, gap 3 (platform, not wire): populate `recent_rounds` on the leaderboard response, or a `/v2/rounds/{id}/standings-deltas` endpoint | endcard, standings, rank-move | M7/M8 | platform (metta) | platform | L | `GET /v2/divisions/{id}/leaderboard?include_recent_rounds=true` returns non-null entries |
| 12 | M6 self-report false positive (a stranger claimed "submitted" without a real call) | (process, not product) | M6 | n/a — `judge.md` already catches this | out of scope | — | no product fix; noting only so it isn't re-discovered as a "gap" |

**WIRE-OK batch proposal (one GameVersion bump):** items #9 and #10 together — a per-episode
`economy` stamp (recut armed/dark) and a per-seat `player_id`/`round_id` pair on the `over` block
when a results URI is configured. Both are additive JSON keys, zero SimServer/Player struct
changes, same shape as `heat`/`pact`'s own earlier "read an existing field onto the chrome" moves.
Needs a WIRE-OK decision from the lead before implementation, per this worker's own scope limits.

**Top 8 by priority** (stall length × frequency × cheapness): #1, #2, #3, #6, #8, #5, #7, #4.

---

## C. The Field Guide (wiki front page)

The wiki lane's own `docs/wiki/RESTRUCTURE-PLAN.md` already lays out an 8-chapter ladder that
matches the owner's question order almost exactly — this section registers it and flags the one
gap it doesn't cover, rather than re-planning it:

1. **What is this** (`main`) — light lead-paragraph refresh, mirrors the door's hook (fix
   `phase2-door` owns).
2. **Why would I care** — **not its own chapter in the current plan**; R7 lists it as a
   make-or-break first-minute question, separate from "what is this." Recommend RESTRUCTURE-
   PLAN.md's chapter-1 refresh explicitly carry the hook sentence (R8) as its own beat, not fold
   silently into genre/format/objective.
3. **How it works (the loop)** (`main`, `episode`, `modes`) — taxonomy only, correctly deferred.
4. **What's happening in a round** (`battle-royale-s2`, NEW, already built and populated —
   162 lines, era-stamped GV61/Glory16) — should link to the in-HUD kickoff banner (fix #2) and
   strip legend (fix #3) rather than restate mechanics the product now explains live.
5. **How scoring works** (`glory-season-2`, `deeds`, `achievements`) — flagged by the wiki lane
   itself as needing a full re-verification pass (the `winAsMultiplier` state is stale, per fix
   #6); should link to the live deed-pop system (#4/#5 moments) and the "why #1 is #1" row (#5 in
   the plan) rather than hand-maintain a static pricing table GLORYVERSION 17 will invalidate.
6. **How to build** (`policies`, `baseline-policy`, `action-mask`, `perception`,
   `submitting-a-policy` protocol half) — unchanged this pass.
7. **How to submit** (`build-and-submit`, NEW, already built and populated — 188 lines) — should
   carry the GitHub-only sign-in disclosure (fix #7) up front, before the CLI steps, since that's
   the wall that actually stopped a real run.
8. **How to read the ladder** (`round`, `elo`, `league`, `champion`) — unchanged this pass; should
   eventually link to the standings-page "why #1 is #1" row (#5) once it ships, and must carry the
   EMA/decay standing-model correction (fix #8) since this is exactly where opus-a's wrong belief
   ("standing = best round") would have been caught by a single accurate sentence.

Each rung stays one screen and points at the in-product explanation (strip legend, kill feed, deed
pop, endcard, standings row) rather than duplicating it — the wiki is the book, not a second copy
of the HUD.
