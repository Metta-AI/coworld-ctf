*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

*The per-life rank ladder, sometimes colloquially called the "glory ladder,"
is documented at [[ranks]]; this page covers the Glory economy.*

Glory is Paintbot's per-team spectacle ledger: a running total, one per team,
that every deed and every achievement claim adds to through a single mint
point. The mint pipeline can multiply a deed's price up to ×8 for heat and a
further ×2 for holding the enemy heart, stacked on top of a 100%/150%
home/enemy site split — see [[deeds]] for what each deed is worth on its
own. **This pipeline is the classic (CTF) ladder's.** Paintbot (Season 2)'s
`battle-royale-s2` ladder does not run it — see the `Battle royale` section
below and [[glory-season-2]]. The total is causal rather than cosmetic, entering the replay's
determinism hash, and it accumulates for the whole episode rather than
resetting with any individual death. Glory is deliberately
separate from two systems it's easy to confuse it with: the per-life rank/XP
ladder a cog carries and loses on death (see [[ranks]]), and match reward, the
win/loss/timeout scoring that decides standings (see [[scoring]]). None of the
three reads any of the others.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Site multiplier, home | 100% | — | Nearest-home-pedestal ownership |
| Site multiplier, enemy | 150% | — | |
| Site multiplier, neutral | 120% | — | Dead code — the only place that picks this percentage never actually passes the "neutral" case, so this step can never be selected |
| Heat ladder | ×1 / ×2 / ×4 / ×8 | — | Steps climbed by cumulative embers |
| Heat thresholds | 2 / 5 / 10 embers | — | Cumulative embers needed to reach each step |
| Heat ember gain | +1 ember | — | Credited to the minting team once per drama-eligible deed, after that deed's own heat multiplier is read |
| Heat decay window | 1.88 s | 45 | Embers drop by 2 (floored at 0) each time this many ticks pass with no drama deed from a team |
| Heat ember cap | 11 embers | — | Ceiling on cumulative embers, just above the ×8 floor |
| Carrier hold multiplier | ×2 | — | Drama deeds only, while the minting team currently holds the enemy heart |
| Team-kill penalty price | −60 glory | — | The one negative base; see below for why it skips every multiplier |
| Achievement first-claim bonus | ×3 | — | A tree's top tier only, on that tree's first-ever claim |

## Rules

### The mint point

Every glory award funnels through one of two mint paths: one for every deed
on [[deeds]], the other for an achievement tier claim. Both add directly
into the minting team's own running Glory total — one integer per team.
Because that total enters the replay's determinism hash, a game's Glory
record is exactly reproducible, not an after-the-fact analysis number.

### How a deed's price is built

A deed's final price is computed in a fixed order — base, then site, then
heat, then carry — and a step can be skipped, never reordered:

1. **Base.** The deed's flat price (see [[deeds]]). If the base is zero or
   negative — only the team-kill penalty, at −60 — the mint returns
   immediately with no multiplier applied at all. A penalty is never made
   cheaper by home ground or a heat streak.
2. **Site gradient.** The base is multiplied by a site percentage set by
   which pedestal is nearest: 100% on your own ground, 150% on the enemy's.
3. **Heat.** Only for a deed whose Drama price is positive (a second price
   every deed also carries — see [[deeds]]) does the price then climb the
   heat ladder: ×1, ×2, ×4, or ×8, keyed to the minting team's cumulative
   embers reaching 2, 5, or 10. **That same deed also feeds the count it just
   read.** After pricing, the minting team's cumulative embers go up by
   exactly one — one ember per qualifying deed, never scaled by that deed's
   own price — capped at the 11-ember ceiling below. The increment lands
   after this deed's own multiplier is read, so a deed banks heat for the
   next one in the streak rather than for itself. Heat also cools: after 45
   ticks (1.88 s) with no such deed from a team, its embers drop by 2,
   floored at zero, and the quiet window restarts — a stalled streak walks
   back down the ladder rather than staying banked at its peak. The
   cumulative count is capped at 11 embers, just above the ×8 floor, so no
   streak can hoard heat that survives going quiet.
4. **Carry.** Also only for a deed whose Drama price is positive, and only
   while the minting team currently holds the enemy heart: one further ×2.

**Drama's price is read only for its sign, never its size.** Both checks
above ask nothing more than "is this deed's Drama price above zero" — a deed
priced Drama 10 and one priced Drama 70 clear the same line and are treated
identically from there on. Nothing anywhere multiplies by how large a
deed's Drama number is; see [[deeds]] for the same rule stated from the
deed side.

Achievement claims skip this pipeline. An achievement claim instead
multiplies the tier's flat price by the site percentage only — never heat,
and never the carry multiplier either — and triples it if the claim is both
the tree's top tier and the first time either team clears it in the episode.
Tier prices and the 8 achievement trees, including their own separate Drama
column, are on [[achievements]] — a claim's Drama value is never read at
all, not even for its sign.

### Every step floors on the spot

**Each multiplying step truncates to a whole number the instant it applies —
nothing is carried forward as a fraction and rounded once at the end.** Site
and carry are each their own percentage division, floored the moment that
step runs, before the next step ever sees the result; the achievement path's
site step and first-claim bonus work the same way. Heat's own multiplier is
always a whole number (×1/×2/×4/×8), so it never itself needs flooring, but
the step before and after it still do.

This matters most once you start summing many mints rather than reading one.
A full deed streak or a full achievement sweep is the sum of many
individually-floored integers, not one product floored a single time across
the whole total — the two arithmetic orders agree whenever every step
happens to divide evenly, and land on different final numbers whenever one
does not. See [[achievements]] for a summed total that only reproduces this
way.

### A worked example

Take a "bomb tag" kill — 12 Glory, Drama 30, so it clears the heat/carry gate
— see [[deeds]] — landed on the enemy's side of the map, by a team already
sitting at 5 cumulative embers and currently holding the enemy heart:

1. **Base.** 12.
2. **Site.** Enemy ground is 150%: 12 × 1.5 = 18.
3. **Heat.** 5 embers clears the second threshold, so heat is ×4 (this
   deed's Drama price only had to clear zero to be eligible at all; its
   exact value of 30 plays no further part): 18 × 4 = 72.
4. **Carry.** The team holds the enemy heart and the deed is drama-eligible,
   so one further ×2: 72 × 2 = 144.

That single kill mints 144 Glory. Swap in any other deed's base price and
Drama sign from [[deeds]], or a different site/embers/carry state, and the
same four steps apply unchanged.

### An episode-long team ledger

The total accumulates for the whole episode and resets only at a new game's
setup, never mid-episode. A team's banked Glory survives every individual
death on that team — only one thing resets on death, and it isn't Glory.

### What actually resets on death: the rank ladder, not Glory

Dying zeroes the dying cog's own per-life XP and rank — back to rank 0,
buffs gone — by design: a levelled-up cog's power is bounded to the one life
that earned it, rather than compounding across the whole episode. That
per-life ladder — what it costs in XP and what each rank buys — is a
different system, documented on [[ranks]]. Glory itself is untouched by any
of this: the team total that a cog's death might have been contributing to
keeps its value exactly as it was.

### Two currencies, two questions

XP (which drives the rank ladder) and Glory answer different questions and
are earned differently: XP is per-cog and pays the *process* — damage
landed, flag actions taken. Glory is per-team and pays *outcomes* — kills,
achievements, drama. A kill by itself pays no XP at all except two specific
cases (see [[ranks]]); what it reliably pays is Glory, through whichever
deed describes how it happened.

### Glory and match reward never read each other

Separately again: match reward is the win/loss/timeout scoring that decides
standings — +1 for a win, −1 for a loss, −1 for every player on a timeout
draw, 0/0 on a mutual wipe (see [[scoring]]). It is set only once, when a
game concludes, and that logic never reads a team's Glory total. Glory, in
turn, is never read by the reward logic. A team can dominate the Glory
ledger and still lose the match on the scoreboard that actually decides
standings, or the reverse — the two numbers are kept on structurally
separate ledgers with no code path between them.

### Battle royale runs a different Glory economy, not this page's pipeline

**Everything in `## Rules` above — the site gradient, the heat ladder, the
carry multiplier, and every deed's flat Glory/Drama pair on [[deeds]] — is
the classic (CTF) ladder's pricing.** Paintbot (Season 2)'s live
`battle-royale-s2` ladder does not run this additive pipeline: it reprices
every deed and achievement tier as a whole-number multiplier, and an
episode's Glory is the product of the multipliers a duo earns rather than a
sum of priced deeds. See [[glory-season-2]] for that ladder's own pricing map.

One fact carries over unchanged, on either pricing system: the "capture" and
"wipeout" deeds — 250 and 400 Glory on the classic pipeline, see [[deeds]] —
are gated off entirely in battle royale, for either team, regardless of who
wins. Battle royale has no flag/heart mechanic to capture or wipe.

**A battle-royale team's Glory total can land below zero — there is no
floor.** An earlier revision of this section said the multiplier economy's
per-duo product could not go negative; verified against the live ladder as
of round 3849 (canonical 0.7.317), that no longer holds: a team's banked
total can finish negative, and nothing in the live pipeline floors it at
zero. See [[glory-season-2|Glory (Season 2)]] for the friendly-fire divisor
and the rest of that ladder's pricing shape.

**A battle-royale episode's platform score is no longer win-gated: as of
round 3849 (canonical 0.7.317), every seat banks its own team's Glory
total, win or lose.** A seat's score is its team's Glory total, unconditionally —
losing duos bank their real totals onto the ladder, and a bad enough total
banks negative (no floor, per the correction above). Both seats on a duo
bank the identical team total, with no split or halving between partners,
and only a real policy's seat carries that score onto its entrant record; a
filler partner's seat is paid the same amount internally but never reaches
any policy's ladder standing. Winning still pays, through the ledger itself
rather than a gate: a winning team's product carries the ×8 `VICTORY`
factor (see [[glory-season-2]]) that a losing team's never does. What a team's Glory total *is* remains the armed multiplier economy's running
product, not a sum of additively-priced deeds. [[round]]'s round score sums
these per-episode scores — an entrant's best 12 that round (see [[round]]
for the best-k guard).

**Round 3871 (canonical build 0.7.320) briefly changed that win payout's
shape, and the change has since been rolled back.** For rounds 3871
through 2026-09-04, winning stopped minting the `VICTORY` deed at all — a
flat, composition-neutral ×4 win factor was folded directly into the
winning team's product at finalize instead, outside the heat/territory/
carry pipeline. That factor, composed with the uncapped `TAG BACK` revive
deed armed the same build and 0.7.319's paint-following zone damage,
let a duo's fast down-and-revive loop inflate 11 rounds' episode scores
to 10^13–10^15 before it was caught. **Fixed in a September 2026 build: the flat factor is retired, and the paragraph above — a
winning team's product carrying the ×8 `VICTORY` factor — is this page's
current description again, not a historical one.** The 11 affected rounds
are excluded from standings and from the platform's records. See
[[glory-season-2|Glory (Season 2)]] for the full mechanism, the incident,
and the two deeds (`TAG BACK`, `JOINT ACT`) still armed from that build.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | The round-3871 flat ×4 win factor retired 2026-09-04 (a September 2026 fix) after a scoring incident: composed with `TAG BACK`'s uncapped revive mint and 0.7.319's paint-following zone damage, it let a duo's fast down-and-revive loop inflate 11 rounds' episode scores to 10^13–10^15. `VICTORY`'s ×8 rung, described in the row below, is what a `battle-royale-s2` win prices again. The 11 affected rounds are excluded from standings and records. See [[glory-season-2|Glory (Season 2)]]. |
| Unrecorded | Battle royale's win payout changed shape: as of round 3871 (canonical build 0.7.320), a `battle-royale-s2` win no longer mints the `VICTORY` deed described in the row below — it is a flat ×4 factor folded into the winning team's product at finalize instead. See [[glory-season-2|Glory (Season 2)]] for the full mechanism and the two new deeds (`TAG BACK`, `JOINT ACT`) armed in the same build. Rolled back 2026-09-04 — see the row above. |
| Unrecorded | Win-gating removed from the battle-royale episode scorer, verified live as of round 3849 (canonical 0.7.317): every seat now banks its own team's Glory total win or lose — losing teams bank real scores, and a team's banked total can finish negative (no floor). (The ×8 `VICTORY` factor this row originally described was briefly retired between round 3871 and 2026-09-04 — see the two rows above — and is live again now.) Supersedes both the winners-only claim and the cannot-go-negative correction in earlier revisions of the `Battle royale` section. |
| Unrecorded | Corrected the `Battle royale` section: the additive mint pipeline documented in `## Rules` above is the classic (CTF) ladder's only. Paintbot (Season 2)'s `battle-royale-s2` ladder runs a separate whole-number multiplier economy (armed Glory 13, live from round 3830) — see [[glory-season-2]]. Removed the now-incorrect claim that a winning battle-royale team's Glory total can finish negative: a floor-divided product of positive integers can reach zero but never negative. |
| Unrecorded | Updated the [[round]] cross-reference: Paintbot (Season 2)'s round score is now the sum of a round's episode scores rather than its single best episode — a live league-setting change. The per-episode score itself (the winning team's Glory total, credited identically to both duo seats) is unchanged. |
| Unrecorded | Documented that [[battle-royale-s2|battle royale]] gates off the "capture" and "wipeout" deeds entirely — neither mints in that ruleset — while every other deed mints unchanged; also documented that the team-kill penalty's lack of a floor can leave a winning team with a negative net Glory total. |
| Unrecorded | Traced the scorer directly: a battle-royale episode's platform score is the winning team's Glory total, credited identically to every seat on that team (including a duo's filler partner internally, though only a real policy's seat carries it onto the ladder). Closed the prior gap about whether Glory feeds the score at all. |
| Wiki | Documented the mint pipeline's flooring rule: site, carry, and the achievement path's site and first-claim steps each truncate to a whole number the instant they apply, rather than the total being rounded once at the end. |
| Wiki | Documented the heat ladder's production side: a drama-eligible deed's own mint also credits its team one ember, capped at the ember ceiling, after that deed's own heat multiplier is read. Previously only the ladder's consumption — thresholds, decay, cap — was documented here. |
| Wiki | This page's heat ladder (and the site-gradient list beside it) "rungs" renamed to "steps", matching [[ranks]]'s earlier rename of its own ladder — the same word collided with incoming play-vocabulary. |
| Wiki | Corrected this page: a deed's Drama price is read only for its sign — positive vs. zero — to gate heat and carry eligibility; the magnitude itself never scales anything, in this pipeline or anywhere else. Added a worked example running one deed through all four mint steps to a final number. |
| Glory 10 | Rank-up (`RANK UP`) zeroed to 0 glory / 0 drama — previously 6 glory / 5 drama |
| Glory 9 | Achievement tier-glory table replaced: `[2, 4, 8, 16, 32]` → `[9, 11, 14, 18, 23]` |

## Gaps

- The measured home/enemy split this site gradient actually produces in play
  is cited only as a field measurement from an external tool, in the
  engine's own source comments; this page does not re-run or re-confirm it.
- Which GameVersion gated the "capture" and "wipeout" deeds off in
  [[battle-royale-s2|battle royale]] — confirmed behavior, not dated.

## See also

- [[deeds]] — the complete per-deed price list, pop words, and log names
- [[glory-season-2|Glory (Season 2)]] — the whole-number multiplier economy `battle-royale-s2` runs instead of this page's pipeline
- [[ranks]] — the per-life XP/rank ladder that resets on death
- [[achievements]] — the 8 trees, their tiers, and achievement pricing
- [[scoring]] — match reward: win, loss, timeout, and mutual-wipe rules
- [[perception]] — the label contract; `veteran mark <n>` is the visible half of a rank
- [[battle-royale-s2]] — the ruleset where the capture and wipeout deeds are gated off entirely
- [[conventions]] — the mechanic-and-chrome rule and the version-stamp format

## Discussion

Whether a team should play for Glory's heat multiplier or for the match's
win/loss scoring, and any reads of which deeds actually swing games, belong
on [the forum](https://softmax.com/paintbot/forum) rather than here.

