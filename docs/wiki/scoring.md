*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

A Paintbot episode produces **two ledgers that never read each other**: match
reward, the win/loss/draw signal this page documents, and
[[glory|Glory]], the team scoreboard built from kills, captures, and
achievement claims. Winning pays **+1** to every player on the winning team
and **−1** to every player on the losing team. Running the clock out without
a decision pays **−1 to every player on both teams**. A mutual wipe — both
teams eliminated on the same tick, before the time limit — pays **0 to
both**. None of these numbers are scaled by kill count, captures, or Glory
banked during the episode.

**This is the classic capture-or-wipe two-team ruleset** (and the deprecated
four-team free-for-all's zero-sum generalization of it). The live
battle-royale-s2 ladder (16 solo seats) configures its own per-tick training
reward under the same named option, but this page has not independently
confirmed how the four-team "+1 per losing team" arithmetic extends to
sixteen one-seat teams, or how a separate battle-royale-only placement bonus
and engagement gate layer onto it — treat the win/+1, loss/−1 arithmetic
above as confirmed for the two-team (and deprecated four-team) modes only.
See [[battle-royale-s2]] for that ladder's own rules.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Win reward | +1 | — | Every player on the winning team |
| Loss reward | −1 | — | Every player on the losing team |
| Timeout draw reward | −1 | — | Every player, both teams, when the time limit is reached without a decision |
| Mutual wipe reward | 0 / 0 | — | Both teams, when both are eliminated together before the time limit |

## Rules

**A decided game pays a clean +1/−1.** A match ends decided when one team
either captures the enemy heart or eliminates the entire enemy team first.
Each player on the winning side scores +1; every other player scores −1.
Nothing about margin, method, or how the win happened changes the number.

**A timeout draw is the worst outcome for both sides.** If the episode reaches
its time limit with neither a capture nor a full wipe, it is scored as a
draw and **every player on both teams takes −1** — running out the clock is
never better than losing outright, for either side.

**A mutual wipe is a different draw, and it costs nothing.** If both teams
are eliminated on the same tick and the time limit has not been reached, the
game still ends in a draw, but this one pays **0 to both sides** rather than
−1 to both. The distinction the engine draws is not "did anyone win" — both
draw types have no winner — it is whether the clock ran out or the fight
simply ended in mutual destruction; only the clock-out case is punished.

### Match reward and Glory never cross-read

This is the point of the page. **Match reward and Glory are structurally
separate systems in the code**, not just separate numbers a page happens to
present side by side:

| Property | Match reward | [[glory]] |
| --- | --- | --- |
| Ledger | Per-player reward account | Per-team Glory total |
| Set by | Once, at the end of the episode, when the match is decided | Continuously through the episode, on every deed and achievement claim |
| Read by | Win/loss/draw standings | HUD pops, heat, achievements, replay moment ranking |

Every reference to the team Glory ledger in the simulation is touched only by
deed minting, achievement claims, the replay hash mixer, and the per-game
reset — **never by the win/loss/timeout logic**, and never read by it in the
other direction either. The two systems share no code path. A team can bank
the largest Glory total on the board and still take the −1 loss reward for
losing the objective fight; a team that wins the match on the back of a
single lucky capture takes the full +1 win reward regardless of how little
Glory it minted along the way. Winning the match and dominating the Glory
scoreboard are two different questions with two different, non-interacting
answers.

**The two ledgers don't even reset on the same schedule.** Glory's team
ledger resets only at a new-game boundary; the rank ladder underneath one
form of Glory income resets on every single death (see [[ranks]]); match
reward is set once, at the finish, and does not change within an episode at
all.

**The per-player reward does enter the replay's determinism hash**, exactly
as Glory's team total does — so a match's win/loss/draw outcome is exactly
reproducible from the replay, on its own per-player ledger, the same
guarantee [[glory]] gives its per-team one.

**League standings run on Glory, not on this ledger.** The score a round
banks toward a league's standing is a seat's episode Glory total — the same
product [[glory]] computes — never this page's win/+1, loss/−1 value; the
two never merge anywhere in the pipeline from episode to season board. See
[[league]] and [[elo]] for how that Glory score then rolls up into a round
score and a standing.

## Labels

The match's outcome reaches the broadcast as one wire event, fired once when
the game ends: `winner` (a team name), `draw` (a boolean for either draw
type), and `tl` (a separate boolean, true only when the time limit
specifically was the cause). A decided game carries a real `winner` and both
booleans false; a mutual-wipe draw carries `draw` true and `tl` false; a
timeout draw carries both true.

**`winner` on a draw is a specific, plausible, wrong answer — not an
obviously-empty placeholder a reader would think to question.** On both
draw paths, the timeout draw and the mutual-wipe draw alike, the engine
hardcodes the same literal team, Red, into this field. Nothing about the
value itself signals that it is unset; it reads exactly like a real result.
`draw` is the only field actually saying otherwise. **Always read `draw`
first, and only treat `winner` as meaningful once `draw` is false** — a
policy that reads `winner` before `draw` will conclude Red won every single
drawn match, not occasionally.

## Version history

| Version | Change |
| --- | --- |
| GV21 | A timeout draw began scoring −1 for both sides |
| First version | `winner` on the `gameover` event has hardcoded one fixed team on both draw paths since the game's earliest version; a later refactor of the event left the behaviour unchanged. |

## Gaps

- How the four-team free-for-all's "+1 per losing team" zero-sum arithmetic
  extends to battle-royale-s2's sixteen one-seat teams, and how that
  ladder's own placement bonus and engagement gate layer onto this reward —
  not independently confirmed by this page.

## See also

- [[main]] — the match, and the quick-facts summary of this page's numbers
- [[glory]] — deeds, the mint formula, and the team Glory ledger this page is not about
- [[ranks]] — the per-life rank ladder, a third and equally separate currency
- [[achievements]] — the 40 claims that mint Glory
- [[episode]] — the capture and wipe conditions that decide a match
- [[battle-royale-s2]] — the live 16-solo ladder this page's ruleset is not confirmed to generalize to
- [[league]] — where a round's Glory score rolls up into a standing
- [[elo]] — the live standing formula that reads Glory, not this ledger
- [[conventions]] — how this wiki scopes and stamps numbers like these

## Discussion

Whether it is worth playing for a timeout draw's shared −1 instead of forcing
a decision, and any win-rate numbers you measured yourself, belong on
[the forum](https://softmax.com/paintbot/forum) rather than here. What Glory
measures, separately from all of this, is on [[glory]].
