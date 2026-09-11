# WIN BANKS THE LADDER — decision brief (not an implementation)

Status: **DECISION BRIEF ONLY.** Docs-only pass, read-only against every live system
(GET only, no settings POST, no deploy). Ships no code, no `GLORYVERSION` bump, no
`GameVersion` bump, no league-settings change. Every option below is a menu item for
the owner to pick from, not a plan already underway.

Era stamp: coworld-ctf `paintbot-v0.7.397` (tag `9aff25f8`, "GLORYVERSION 18 =
paintbot-v0.7.397 (S8, scoring only; GV stays 63)") / GameVersion **63** / GLORYVERSION
**18**, 2026-09-11. Current worktree HEAD is `paintbot-v0.7.399`; the two commits
between are wiki re-traces only, not scoring changes, so this era stamp is still exact
for scoring. Epic: `16d081ab` (THE WHOLE); program: GLORY GRADIENT.

## The owner's ruling (2026-09-11, verbatim)

> "once the glory scoring gradient is sorted, we need to add back the win condition.
> you only bank your glory toward the LADDER if you win (still get glory for the
> episode but it doesn't count toward the ladder)."

Two effects, kept distinct throughout this brief: **episode glory** (what a seat earns
this match — the tags/deeds ledger, the rail, the endcard) stays as-is for everyone.
**Ladder standing** (the season board) is the thing gated on winning.

---

## 1. Prior art — what "add back" refers to

There are two different mechanisms already in the code, and it is worth being precise
about which one "the win condition" means, because only one of them is a candidate for
"add back":

| Mechanism | What it does | Where | Status |
|---|---|---|---|
| **Win-weighted episode glory** | The winning seat's *episode* glory is already multiplied hard: a flat ×8 fold for a solo winner, plus a ×2/×3/×4 placement ladder for reaching the final 8/4/2 (cumulative ×24 for surviving to the final two, before the win-fold). This is "the win condition" as a **scoring** mechanic — it already exists and is live. | source: `src/ctf/glory.nim:3354-3373` (`RecutWinFactorBRSolo* = 8`, doc comment "REPLACING the retired dVictory deed"); `src/ctf/glory.nim:2629-2637` (dFinal8/4/2 ×2/×3/×4 comment, "Winner cumulative ×2×3×4 = ×24"); gate flag `GameConfig.winAsMultiplier*` at `src/ctf/sim_types.nim:2954` | **Armed live** since build `0.7.344` (GV57 part B) per memory `ctf-winasmultiplier-flips-at-gv57.md`, after a 2026-09-04 rollback and re-arm once `zoneBlocksRevive` + `deedMintCaps` shipped. **This memory's own warning stands: it is a boolean flag that can flip with no code change — re-verify before relying on it for anything owner-facing.** Not re-confirmed live this pass (see §"not verified"). |
| **Win-gated ladder banking** | Whether a round's score counts toward the *season standing* at all, conditioned on having won. | — | **Does not exist today, in either era.** No memory file, and no code read this pass, describes an S1 CTF-era mechanic where the ladder itself ignored a non-winning round's score. `ctf-doctrine-s1-both-levers-no-go.md` is an unrelated crowd300/endgame experiment; `ctf-br-score-function-inverts-our-thesis.md` is corrected in its own text to be about an **external, someone-else's** BR engine's scoring, not ours. `ctf-br-ships-as-league.md` only establishes that BR ships as its own league with its own Elo/standings — it says nothing about win-gating. **Honest conclusion: there is no prior "add back" target to restore for ladder-banking specifically — every round's score has always fed the standing today, win or lose (§2).** The owner's "add back" most plausibly refers to reapplying the *win-is-what-counts* principle already proven at the episode-glory layer, one level up, to the ladder. |

The current S2 battle-royale (16 solo seats, `variant_rotation: ["battle-royale-s2"]`,
live-confirmed this pass, see §2) reports one glory number per seat per round, with
exactly one winner per round — BR is **draw-free by construction** (`src/ctf/sim.nim:6087-6097`,
`brTiebreakWinner`: "a STRICT TOTAL ORDER: a timeout can never be a draw"), so "who won"
is never ambiguous or tied at the engine layer.

---

## 2. How a seat's glory reaches the ladder today

```
sim (glory.nim/sim.nim, per-seat product score)
   -> reported per-seat episode reward (the RL reward channel; NOT the `over`/endcard
      display wire, which carries zero glory/XP/rank fields per ctf-reward-identity-is-seat-name.md)
   -> metta ingests it as `episode_score` per (episode, policy_version_id)
      (`round_lifecycle.py:2646` `score_by_pv[...].score` / `:2657` `result.avg_reward`)
   -> `score_round()` aggregates one score per policy for the round under
      `round_scoring_rule` (`round_lifecycle.py:2446-2660`)
   -> `rankings/score.py:_clamp_rated_contribution` winsorizes it
   -> standing = standing + rated_k * (clamped - standing)   [the EMA, score.py:127-130]
```

**Live settings, read this pass** (`GET /v2/leagues/league_b8fa9b35-ac22-48cf-a03f-07b397aff1c7/settings`,
elevated, 2026-09-11 — read-only, no write): `standing_aggregation="rated"`, `rated_k=0.05`
(half-life 13.5 rounds), `rated_clamp_multiple=150.0` (armed), `round_scoring_rule="sum"`,
`sum_top_k=12`, `season_leg_transform="none"`, `team_count=16`, `variant_rotation=["battle-royale-s2"]`.
For a 16-solo-seat BR round each policy plays exactly one episode leg that round, so
`sum_top_k=12` is a no-op here (`min(12, legs_scored=1)=1`): **the round score is simply
that seat's own episode glory, unconditionally, win or lose.** That is the literal fact
this ruling changes.

**Two findings from reading metta `origin/main` fresh this pass (not in any cached
probe doc — the 2026-09-08 probe said `season_leg_transform` was "still OPEN/unmerged";
that has moved):**

1. **The signed-log2 season transform and its sign-aware clamp fix are now live on metta
   `main`**, despite the associated PRs (#22166/#22168/#22172/#22174/#22177) all showing
   `state: closed, merged: false` via `gh api` — this is the known Graphite-cascade trap
   (`metta-graphite-land-hides-merges.md`: a stacked PR's content can land on main while
   its own PR object is closed unmerged). Confirmed by reading the live file content, not
   the PR state: `_clamp_rated_contribution` (`rankings/score.py:41-98`) now clamps on
   `abs(round_score)`/`abs(standing)` and reapplies the round's own sign unconditionally —
   **this is a general fix, not gated on `season_leg_transform`**, so the old
   negative-round-flips-positive bug (`ctf-rated-clamp-sizing-post-gv57.md`) is closed for
   any future round, regardless of which option below ships.
2. **`season_leg_transform` is confirmed live-armed as `"none"`** for the one `rated`
   league (read above) — the log2 transform exists in code but is not turned on for
   Paintbot S2 today.
3. **The platform already has a `round_scoring_rule = "win"` enum value, wired
   end-to-end** (`commissioner_schema.py:47-53` `ScoringRule`; `round_lifecycle.py:2668-2677`).
   Today it replaces a policy's round score with its **win rate** (`wins / episodes_played`)
   — it throws away glory magnitude entirely, so it is *not* the owner's ask as-is, but it
   proves the win/loss bookkeeping (`episode_wins_by_policy`, `episodes_played_by_policy`,
   `record_episode_placement_outcomes` at `commissioners.py:742-764`) already exists and is
   already exercised in production code, not a green-field addition (relevant to Option P's
   blast radius, §4).
4. **Platform "won" ≠ engine "won."** `record_episode_placement_outcomes` (`commissioners.py:758-764`)
   determines the winner as **whichever seat(s) reported the highest score that episode**
   — it has no visibility into the engine's own `brPlacements()`/`finishGame(winner)` flag.
   Under the armed win-factor/placement economy the true winner is *usually* also the
   highest scorer (the ×8 win-fold and the ×24 placement ladder are large), but nothing
   guarantees it — a finalist with a big kill/heat/stack round could in principle
   out-score a passive winner. **The engine's own winner flag is exact; the platform's
   inferred one is a proxy.** This is the central technical argument for Option G over
   Option P (§3 vs §4).

---

## 3. Option G — game-side gate

**Mechanism:** at finalize, the sim reports a second number alongside (not instead of)
today's episode glory — call it *banked glory* — computed as `episodeGlory if isWinner
else 0` (or a small nonzero floor, owner's choice). The rail/endcard keep showing full
episode glory unchanged; only the number that flows into the platform's per-episode
reward/score channel changes.

- **Blast radius:** touches the reward-emission path in `src/ctf/server.nim` (identity
  keyed by seat name per `ctf-reward-identity-is-seat-name.md`) and reads the sim's own
  `brPlacements()`/`finishGame(winner: Team, ...)` (`src/ctf/sim.nim:6100,6118`) — a flag
  the engine already computes and already gates the win-fold on. **Not verified this
  pass:** the exact file/line where the sim's per-seat episode score is serialized into
  the value metta ingests as `episode_score`/`avg_reward` (§2) — I traced metta's
  consumption of that number but not coworld-ctf's emission of it; this is the single
  most important open trace before anyone implements this option.
- **Wire/GameVersion:** if the emitted number is a NEW field alongside the existing
  reward (not a mutation of it), no `GameVersion` bump is structurally required by the
  pattern the GLORY GRADIENT S0 season-rule probe used for its own platform-side, no-sim-touch
  changes; if it instead *replaces* the value already on the reward channel, that is a
  scoring-visible change and should carry a `GLORYVERSION` bump under this repo's own
  convention (every prior scoring change in this file bumps it).
- **What the platform sees:** identical to a hypothetical Option P outcome numerically
  (zero for 15/16 seats), but keyed on the engine's own exact winner, not the platform's
  score-inferred proxy (§2, finding 4).
- **No metta click required:** this is the option that ships without waiting on the
  owner's eleven open metta PRs.

## 4. Option P — platform-side gate

**Mechanism:** the season rule counts only the winning seat's round contribution, e.g.
a new `round_scoring_rule` value (`win_gated_sum` or similar) that is `sum`'s existing
logic (`round_lifecycle.py:2388-2413`) but zeroes every non-winning policy's leg before
the top-k slice — sitting next to the already-shipped `"win"` rule (§2, finding 3) rather
than needing new plumbing invented from nothing.

- **Blast radius:** `commissioner_schema.py` (`ScoringRule` enum, +1 literal),
  `round_lifecycle.py` `_score_entries`/`score_round` (+1 branch, mirroring the existing
  `"win"` branch at `:2668-2677`), the "must mirror" DTO duplication
  `orchestration/activities.py` already calls out for `sum_top_k`/`rated_k`-shaped fields,
  plus a new unit test alongside `test_score_ranking.py`'s style. This is genuinely
  metta/app_backend platform code — none of it touches `glory.nim`, `sim.nim`, or the
  wire.
- **Correctness gap:** inherits §2 finding 4 — "winner" here means "highest reported
  score," not the engine's placement flag. For BR under the armed win-factor/placement
  economy this is very likely to agree with the true winner in practice (untested this
  pass), but it is a proxy, not a guarantee, and it silently disagrees with what the rail
  and endcard call "the winner" if it ever diverges.
- **Timing:** the owner's eleven open metta PRs (season-rule family: #22166/#22168/#22172/#22174/#22177
  and siblings) show `merged: false` via the GitHub API for every one checked, though
  their *content* is confirmed live on `origin/main` (§2 finding 1 — the Graphite-cascade
  trap, not a stalled review). **What this implies for timing:** the code-landing
  mechanism for this family is already proven to work around the approval wall via
  cascade merges, so "0/11 merged today" is not by itself evidence that a new PR in this
  family would stall — but every prior PR in the family that needed a genuinely fresh,
  standalone review (not a cascade rider) hit `ctf-metta-approval-wall-and-api-traps.md`'s
  non-author-approval requirement (Claude commit trailer -> `mergeStateStatus: BLOCKED`).
  Budget for that wall, not for eleven separate blockers.

## 5. Option H — hybrid / soft gate

One paragraph, because that is all the case supports: **winner banks 100%, every other
seat banks its placement legs only (dFinal8/4/2, ×2/×3/×4) with the win-fold and
non-placement deed/heat/stack multipliers zeroed before it reaches the ladder.** This
keeps "climbing the bracket" visible to the season board (a final-4 finish still moves
your standing a little) while still making outright winning the only way to bank the
*full* round, softening the "15/16 seats contribute nothing" shock in §6. The reason
this is not promoted to a full option here: it requires the platform to distinguish
placement-leg glory from the rest of a seat's product at the point of ingestion, which
today it cannot (the ingested number is one scalar per seat, §2) — it would need Option
G's game-side split (report two numbers) as a prerequisite either way, so it is really
"Option G, with a softer floor" rather than an independent mechanism. Include it in the
decision menu as a floor-value choice under G, not as its own row.

---

## 6. Consequences, modelled with digits

**Gate on the "gradient sorted" question first (§8) — these numbers describe the
economy the win-gate would sit on top of, not a settled target.**

Best available real data is the frozen GV62 census (`~/.ctf/knowledge/glory-gradient/data/gv62/`,
24 rounds r4611-r4635, 341 episodes, 5,456 seat-episodes, dated 2026-09-09, one
GLORYVERSION behind today's stamp; the S8 bump to 18 is documented "scoring only" with no
catalog-table changes named, so treated as still representative). A live re-run for
today's era (v0.7.397) is in progress in this session under a sibling agent
(`/tmp/glory-census/`) but has no synthesized report as of this writing — not cited as a
result, only as "in flight."

- **Structural skew that already exists, before any win-gate:** in the top-decile
  seat-episodes (the top 10% by glory, n=555), **22.7% are the episode's winner** —
  winners are only 1/16 = 6.25% of all seats, so a winning seat is already **3.6× more
  likely than base rate** to be at the top of the *episode* glory distribution. This is
  the "why bank only the winner" case largely already made by the existing economy, before
  any ladder gate is added — the win-fold and placement ladder already concentrate glory
  on winners; a win-gate concentrates it completely.
- **1 winner / 16 seats per round means 15/16 round contributions go to zero (or floor)
  under Option G/P.** Under the live `rated_k=0.05` EMA (half-life 13.5 rounds,
  `ctf-standing-is-an-ema-not-a-max.md`), a leader who stops winning retains
  `0.95^n` of any single round's contribution to their standing after `n` non-winning
  rounds: **n=5 -> 77%, n=10 -> 60%, n=20 -> 36%, n=40 -> 13%, n=65 -> 3.6%.** This is the
  same math already validated against the real board (~1e-4% average relative error) —
  applying a zero every non-winning round does not change the *decay* mechanism, it
  changes how often a *nonzero* update happens. **Not modelled this pass:** a live
  round-by-round per-pv trace for the top 8 standing holders (would need a fresh
  multi-round per-pv history pull beyond this brief's read-only spot-checks) — the
  reordering claim ("how fast a leader falls") is illustrated by the decay curve above,
  not measured against real win/loss sequences for named pv ids.
- **Sign-flip / clamp risk: CLOSED, independent of which option ships.** The clamp's
  sign-aware fix (§2 finding 1) is unconditional on `standing >= 0` — a round score of
  exactly zero (Option G/P's outcome for 15/16 seats) is never negative, so it cannot
  trigger the old sign-flip bug even though that bug is what originally motivated
  caution here. The historical exposure (`ctf-rated-clamp-sizing-post-gv57.md`,
  `ctf-rated-standing-decays-per-subject.md`) was about the pre-recut *additive* economy's
  negative round scores (46% of all-time rounds negative, last one round 3709,
  2026-09-02); the armed recut economy has produced **zero negative rounds in the most
  recent 100 completed rounds** (live DB read, `00k-live-league-audit-2026-09-09.md`) and
  a win-gate's zero floor does not reintroduce them.
- **Cap-hit:** GV62 census shows **0/5456 = 0.000%** of seat-episodes at/over the product
  cap (2^24 = 16,777,216); of winners specifically, **0/336 = 0.000%**. The cap is not
  currently a factor in who wins a round's glory contest — no evidence the win-gate
  would interact with cap saturation either way at today's tuning.
- **Ties: cannot happen.** BR is draw-free by construction (§1, `brTiebreakWinner`) —
  every round has exactly one winner, never zero, never two. Neither Option G nor P needs
  a tie-break rule.
- **Monet (house policy), by pv id:** not resolved this pass — doing this properly means
  citing Monet's current champion `pv_` id from the GV62 cohort-attribution data
  (`01e-gv62-cohort-attribution-2026-09-09.md`) rather than its display name, and that
  file was not opened in this pass. Flagged as an open item for whoever picks an option,
  not fabricated here.

---

## 7. What the player sees

| Surface | Today | Under Option G/P | Must NOT change |
|---|---|---|---|
| Left rail (in-match glory ledger) | Full episode glory, every seat, every round | **Unchanged** — rail shows the same full episode glory regardless of banking | Owner ruling: left rail is the default glory ledger, always, every route/embed (`maxwell-left-rail-is-the-default-glory-ledger.md`) — a win-gate must not become an excuse to hide or discount the rail for non-winners |
| Endcard | Full episode glory + placement + achievement badges | **Unchanged**, same reasoning | Grayed-out badges that fill with colour when lit stay as designed (`maxwell-glory-rulings-placement-popup-visibility.md`) — badges are earned regardless of banking |
| Standings row / season board | Every round's glory counts | Only banked (winning) rounds move the number; a prolific non-winner's standing decays per §6's curve | Must not relabel "Champion" as "the winner" — Champion is the league's designated representative/eligibility flag, unrelated to this ruling (`maxwell-champion-is-not-an-achievement.md`); a win-gate changes what banks toward *standing*, not who is Champion |
| Popup / "×N" pop | Only fires ≥2× per the owner's ruling | **Unchanged** — banking status is a ladder-side fact, not a pop-worthy in-match event; do not add a new popup for "this glory didn't bank" | Never pop at ×1.00, never pop under ×2 (`maxwell-glory-rulings-placement-popup-visibility.md`) |

The one thing every option must get right: **a non-winning player should see their full
glory, exactly as designed, and separately and legibly understand that this round's
score did not move the season board** — the owner's own phrasing ("still get glory for
the episode but it doesn't count toward the ladder") is a two-fact statement, and hiding
either fact from the player recreates the old "repriced with no digits" mistake
(`maxwell-glory-rulings-placement-popup-visibility.md`'s root cause).

---

## 8. Sequencing

The owner's own conditional — "once the glory scoring gradient is sorted" — names a gate
this brief does not clear. The owner-signed target (`docs/designs/glory/TARGET-DISTRIBUTION.md`):
**TOP ~100× a typical round, JACKPOT ~1000× median, cap-hit 0.1-1%.** Measured against
that target:

| Metric | Owner target | GV62 measured (2026-09-09) | S1 baseline (pre-recut, for scale) |
|---|---|---|---|
| p99/p50 (TOP ratio) | ~100× | **16,384×** — 164× too hot | 24,576× |
| p99.9/p50 (JACKPOT ratio) | ~1000× | 16,384× (p99.9 = p99 at this sample size) | 920,420× |
| cap-hit | 0.1-1% | **0.000%** — undershooting | 0.020% |
| CHOSEN share (top decile) | (no explicit target; the S4 freeze criterion was ">=50%") | **contested**: 71.1% frozen (PR #491) vs ~47% per an unresolved rig amendment (repricer script found uncommitted; resolution pending PR #501) | 11.4% |

None of the three signed ratios are inside their target band yet, and the CHOSEN-share
number this program would use to certify "the gradient rewards skill, not just
placement/constant legs" is **internally unresolved** (two conflicting figures, no
landed reconciliation). **This brief's own recommendation: that is the gate. Do not
schedule a win-gate implementation until a future census reads TOP/JACKPOT within
shouting distance of ~100×/~1000× and CHOSEN-share has one number, not two.** This
document ships no code and starts no clock on that gate — it exists so the choice is
ready the moment the gate clears.

---

## 9. Decision menu

1. **Which option?** G (game-side, exact winner, ships without metta) / P (platform-side,
   proxy winner, rides existing `ScoringRule` plumbing, needs a metta PR to land past the
   approval wall) / H (soft gate — really "G with a placement-leg floor," not
   independent).
2. **Floor for non-winners' banked contribution:** exactly 0, or a small nonzero floor
   (and if nonzero, is it a flat number or the placement-leg-only value from Option H)?
3. **When:** now (accepting the gradient is not yet at target, §8), or gated on a future
   census clearing the ~100×/~1000×/CHOSEN-resolved bar named in §8?
4. **If Option P:** accept "highest reported score" as "winner" (a proxy, §2 finding 4),
   or require it to read the engine's own placement flag first (which pushes P toward
   needing a sim-side signal anyway, narrowing the G/P gap)?
5. **Player-facing framing:** is "this glory didn't count toward the ladder" surfaced
   anywhere explicit (a rail/endcard label), or left implicit (the standings row simply
   doesn't move)? §7 flags this as the fact most likely to get missed the way placement
   repricing did in September.

---

## What was not verified

- The exact coworld-ctf file/line that emits the per-seat episode score into the value
  metta ingests as `episode_score`/`avg_reward` (§3) — traced metta's consumption, not
  this repo's emission point.
- `GameConfig.winAsMultiplier`'s current live-armed boolean was not re-confirmed via a
  fresh manifest GET this pass (the guessed endpoint 404'd); relying on the dated memory
  read (`ctf-winasmultiplier-flips-at-gv57.md`, confirmed True as of build 0.7.344) plus
  the absence of any later rollback mentioned in era-boundary commits since.
- Whether "platform-inferred winner" (highest reported score) ever actually disagrees
  with the engine's own placement-1 team in real play — asserted as a theoretical gap
  from source, not measured against real episodes.
- A live per-pv, round-by-round standing trace for the top 8 pv ids (§6's reordering
  claim is illustrated with the general decay formula, not a fresh 40-round pull).
- Monet's current champion pv id (needed to name it correctly in §6) — not looked up
  this pass.
- Today's in-flight v0.7.397/GV63 census (`/tmp/glory-census/`, a sibling agent's work)
  has no synthesized verdict as of this writing; §6/§8 cite the frozen GV62 census
  instead and say so.
