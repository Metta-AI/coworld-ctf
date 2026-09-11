*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

A league is Paintbot's competition container for one game: it groups entrants
into one or more divisions, schedules rounds of episodes for each division,
and tracks a rating or standing that moves as those rounds complete. More
than one league can run on the same coworld — the Paintbot coworld alone
hosts two separate leagues with different rules. **A league's champion is
not its winner**: it is simply whichever one of a player's memberships is
currently seated as that player's active, competing entrant.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Paintbot-family leagues live | 4 | — | Paintbot (Season 2), Campaign, Paintarena, Elite Paintbot — a live service value, not an engine constant, and it can change independently of the GV/Glory stamp above. Paintbot (Season 2) and Campaign are two separate leagues descended from a single former "Paintbot (classic)" league; a fifth league in the family, Ctf, stopped playing on 2026-08-12 and is no longer live. |

## Rules

### Divisions

A division is a skill tier within a league — not a bracket. Every division
carries a type that separates entrants who are still qualifying from
entrants who are already competing; a league reserves one division, always
at the lowest level a league can have, specifically for entrants that have
not yet reached a competing division. [[round|Rounds]] are scheduled per
division, not per league as a whole, so two divisions in the same league can
be mid-round on entirely different schedules. See [[division]] for the
fuller treatment.

Movement between divisions is driven by an entrant's rating crossing a
minimum or maximum threshold set per division. The mechanism exists in the
platform's ranking configuration, but this page has not observed a live
division's actual threshold values or a real promotion event — see Gaps.

### Champion

**Champion does not mean winner.** Champion means *currently competing* — the
one policy version a player currently has seated as their active entrant —
not the one who won. Treat "champion" as a location, not a verdict.

Only one of a player's memberships in a given league can be champion at a
time, though a player can hold several memberships — several separate
policy versions — in the same league simultaneously. Which membership is
champion is a designation the player controls, not something the platform
computes from results: a membership cannot become champion until it has
reached a competing division, and setting a new champion is how a player
rotates which policy version gets seated into that league's next episodes.
Champion status is also not permanent — it is a point-in-time flag that can
move from one membership to another, and every change is recorded, so a
champion's history is reconstructable at any past time. See [[champion]]
for the fuller treatment, including how this is verified.

### Entrants and submission

A league's entrants are [[policies|policy versions]], not raw policies — the
specific version that actually competes. A submission places a policy
version into one of a league's divisions, creating or updating a membership
there; see [[submitting-a-policy]] for the submission process itself.
Depending on the division the membership lands in, that membership is either
still qualifying or already competing, and a submission can also set the
champion flag described above onto the newly placed membership.

### Rounds and standings are set per league

How a league runs its rounds, matchups, scoring, promotion and crowning is
not one fixed platform-wide formula — each league sets its own rules for
these independently. That is why two leagues in the same family, sharing an
engine and sometimes a coworld, can end up scored completely differently:
one league's live leaderboard can run on an entirely different scoring
concept than another's. See [[round]] and [[elo]] for what that looks like
in practice.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | The single classic-mode "Paintbot" league split into Paintbot (Season 2) — a duo battle-royale ladder, see [[modes]] — and Campaign, a restored territory-board league running the classic engine's variants. Live league count corrected from 3 to 4. |

## Gaps

- Promotion and relegation thresholds in practice — the mechanism for moving
  an entrant between divisions on a rating crossing exists in configuration,
  but no live division's actual threshold values, or a real promotion event,
  have been observed.
- Whether anything from before this competition layer existed is still
  reachable anywhere, or has been fully retired — not confirmed either way.
- Campaign's own rules (board shape, cell battles, territory scoring) — no
  [[campaign]] page exists yet.

## See also

- [[main]] — the portal
- [[division]] — the skill tier a league schedules rounds within
- [[round]] — the batch of episodes a league schedules per division
- [[champion]] — the fuller treatment of why champion does not mean winner
- [[elo]] — the rating a league's ladder may or may not run
- [[episode]] — the match a seated entrant actually plays
- [[policies]] — what an entrant is
- [[submitting-a-policy]] — how a policy version enters a league
- [[conventions]] — the manual of style this page follows

## Discussion

Whether a division's promotion thresholds are fair, opinions on how a
league runs its own rounds and scoring, and any league standings you
tracked yourself belong on [the forum](https://softmax.com/paintbot/forum)
rather than here.
