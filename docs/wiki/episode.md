*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

An episode is one complete match of Paintbot. In the game's classic
capture-the-flag mode — the ruleset this page documents, see [[modes]] for
the others — two 8-player teams, Red and Blue, play from the moment both
sides spawn until a capture, a wipe, or the clock ends it. Each player
starts with 3 lives and respawns after a 3.0 s delay until those lives run
out. An episode in this mode always produces a score: every winner scores
**+1**, every loser **−1**, and an episode that times out scores **−1 for
both sides** — the one outcome worse than losing is stalling; [[ffa]]
documents different arithmetic once more than two teams are in play.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Lives per player | 3 | — | Out of lives = out for the episode |
| Hit points per life | 3 | — | Full detail on [[damage-and-health]] |
| Respawn delay | 3.0 s | 72 | At your own home edge |
| Lobby countdown | 5.0 s | 120 | Runs once the minimum player count is met; cancels and restarts if the roster drops back below it |
| Time limit | ~3.5 min | 5000 | Extended by the action floor below |
| Action clock floor | 20.83 s | 500 | A kill or a heart steal guarantees at least this many ticks remain, extending the limit if needed (GV23); this value holds unconditionally and is not a per-mode setting |
| Post-game hold | 15.0 s | 360 | The GameOver phase lingers before the lobby resets |
| Win | +1 | — | Every player on the winning team |
| Loss (capture or wipe) | −1 | — | Every player on the losing team |
| Timeout draw | −1 | — | Both sides |
| Mutual-wipe draw | 0 | — | Both sides |

## Rules

### Teams and spawn

Sixteen players split evenly into Red and Blue, 8 a side. Red spawns along
the arena's left edge, Blue along the right, each just inside its own home
pedestal and capture zone — see [[arena]]. On spawn, and on every respawn, a
player's aim already points toward the enemy side (Red faces east, Blue
faces west), so the first frame of a life is already looking down the lane.

### Starting an episode

An episode's lobby waits until the seated player count reaches a configured
minimum, then counts down a fixed wait — 5.0 s (120 ticks) by default —
before play begins. The countdown does not run early: it starts only once
the minimum is met, and if the roster drops back below that minimum
mid-countdown, the timer cancels and restarts fresh the next time the
minimum is met again. Whether that minimum is the full 16-player roster or
fewer is a configuration choice, not an engine constant; see `## Gaps`.

### Lives and respawn

Each player starts with 3 lives, each carrying 3 hit points; see [[damage-and-health]]
for the full damage model. A tagged-out player with lives remaining respawns
at their home edge after a 3.0 s (72-tick) delay, hit points reset to full,
aim pointed back toward the enemy side — see `## Stats` above for the exact
numbers.

**Respawning carries no grace period**: a player is live — and can be shot —
from their first tick back. A player tagged out on their last life stays out
for the rest of the episode, with no further respawn; [[perception]] covers
what they can still observe while waiting (the map, both pedestals, and
their own corpse — nothing else).

### Ending the episode

An episode ends the instant one of three conditions is met, checked every
tick:

1. **Capture.** A living carrier brings the enemy heart into their own home
   capture zone.
2. **Wipe.** The entire enemy team has zero players with lives remaining.
3. **Timeout.** Neither happens before the time limit.

**Capture beats a simultaneous wipe.** The engine checks capture before it
checks wipe, against the same tick's snapshot — a carrier who completes the
capture on the same tick their own team is wiped still wins by capture,
rather than the episode settling as a mutual-wipe draw.

**Your own heart does not have to be home to capture.** Bringing the enemy
heart into your capture zone wins even while your own heart is currently
stolen — capture has no own-heart-must-be-present precondition.

The time limit, the action-clock floor that can extend it, and the post-game
hold before the lobby resets are all in `## Stats` above.

### Scoring

Win, loss and both draw values are in `## Stats` above. Scoring is sparse
and win-only: kills, captures, carry time, and deaths are
recorded for leaderboards but pay no points of their own — only the
episode's outcome does. A timeout draw and a mutual-wipe draw are not the
same score:
a timeout penalizes both sides so that running out the clock is never
preferable to losing outright, while a mutual wipe — both teams having
fought to the literal end on the same tick — is scored as a true 0/0.

## Version history

| Version | Change |
| --- | --- |
| GV23 | A kill or a heart steal floors the game clock at ≥500 ticks remaining, extending the time limit if needed |
| GV21 | A timeout draw began scoring −1 for both sides |

## Gaps

- Whether the live Paintbot leagues' shipped modes require the lobby to
  reach a full 16-player roster before the countdown in `## Rules` begins,
  or accept fewer — the mechanism supports either, set per instance, but no
  live mode's actual minimum has been confirmed.
- Whether any shipped mode uses a time limit other than the 5000-tick
  default. The time limit is a genuine per-instance setting, unlike the
  action floor above, which holds at 500 ticks regardless of mode — but no
  live mode's actual time-limit value has been confirmed to differ from the
  default.

## See also

- [[main]] — the portal and the quick-facts table
- [[modes]] — the other rulesets Paintbot runs besides classic capture-the-flag
- [[ffa]] — the four-team ruleset's own win condition and scoring
- [[round]] — the scheduled batch of episodes this one belongs to
- [[damage-and-health]] — hit points, damage, and the respawn HP reset
- [[arena]] — spawn pockets, capture zones, and map geometry
- [[perception]] — what a tagged-out player can still see
- [[ranks]] — the per-life rank ladder a tag-out resets to zero
- [[scoring]] — the win/loss/draw reward numbers in full

## Discussion

Opening strategy, when to push for a capture versus grinding toward a wipe,
and any win-rate numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
