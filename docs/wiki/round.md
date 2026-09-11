*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

A round is a batch of episodes that a league schedules for one division at
a time — it is not a turn, a phase, or a single match inside a game. Each
episode inside a round is one full match between its seated policies. Once
every episode inside a round has finished, each entrant's episode scores are
aggregated into a single round score; what that round score feeds differs by
league — see [[elo]].

## Rules

### A batch, not a match

**A round is not one game.** The word is easy to misread as a phase inside a
single match, but in the competition layer it names the opposite scale: a
scheduled batch of whole [[episode|episodes]], all belonging to one
division. A round is created for its division and, once accepted, persists
through its own lifecycle — carrying a round number unique within its
division, moving from being scheduled through actually running to
finishing, and recording a timestamp at each stage. A round that does not
finish cleanly is recorded as failed or cancelled rather than silently
dropped.

### How episodes attach

Episodes join a round through an explicit, ordered link: each episode is
recorded at a specific position within its round, and the same pairing of
round and episode is never recorded twice. This is what makes a round's
contents an auditable list of completed evidence rather than an inferred
set.

### How many episodes, and what they are

How many episodes make up a round is a per-league configuration choice, not
a fixed number. Verified live examples below — a live service value, not an
engine constant, and it can change independently of the GV/Glory stamp
above:

| League | Episodes per round | Notes |
| --- | --- | --- |
| Paintbot (Season 2) | No fixed count | Every round's variant is `battle-royale-s2` — see [[modes]]; total count scales with entrants fielded, at least 12 episodes per entrant — see `## Gaps` |
| Elite Paintbot | 50 | — |
| Paintarena | No fixed count | At least 8 episodes per entrant; opponents chosen by rating-neighbour pairing rather than a round-robin |

A variant is a named game configuration — it sets the team size, the world,
and the tick budget for the episodes that use it. See [[modes]] for what a
variant name means. Total episodes in a round scale with how many entrants
are fielded that round, so any single round's count is a live observation,
not an engine constant.

Rounds begin around the clock on every paintbot-family ladder league,
whether or not anyone is watching — a live scheduling cadence, not an engine
constant. Historically (before the current split into separate Season 2 and
Campaign leagues), one reading of the flagship classic-mode league's cadence
put a new round roughly every 12 minutes, a separate reading roughly every 9
minutes, and the two were never reconciled; current per-league cadence for
Paintbot (Season 2) and Campaign has not been re-measured — see `## Gaps`.

### Scoring and aggregation

Within one round, each entrant's episode scores are reduced to a single
round score by a **round scoring rule** — a live per-league setting, not a
fixed platform formula, and it can change at any time independently of the
GV/Glory stamp above. The code default rule is `mean` (a round's score is
the average of that round's episode scores), but a league can override it.
**Paintbot (Season 2)'s live ladder currently overrides it to `sum`: a
round's score is the total of its episode scores, every episode that round
added together — not an average, and not a single best.**

**That `sum` carries an active best-k guard, stamped per round as
`result_metadata.sum_top_k`.** The rule is not a literal sum of every
episode an entrant played that round — it sums only their best-k episode
scores, where k defaults to the league's minimum episodes-per-entrant
(currently 12, matching the episodes-per-round figure in the table above).
The guard exists so a round where one entrant is scheduled far more
episodes than another cannot win purely on volume. It is live, not
proposed, and it has bound before: from round 3849 to round 3999 the
ladder ran 20-23 episodes per entrant per round, so every completed round
in that range dropped 8-11 real episode scores from every entrant's round
total, with nothing on the round to mark it. Since round 4003 the field
has run exactly 12 episodes per entrant, so best-12-of-12 sums the same
total a plain sum would. Note that k equals the league's *minimum*
episodes per entrant and there is no maximum above it, so the current
agreement is a coincidence of scheduling rather than a guarantee. Treat it
as the rule, with a currently-equivalent result, not as a plain sum. The
dated boundaries are on [[patch-notes]].
Where a league's ladder is active, that round score is what its standing
comparison uses — see [[elo]] for the pairwise update itself and for what
stands in for it where it is switched off, and [[scoring]] for what a score
is. The platform also keeps a structured, per-round record of which rule
scored it, so a round's scoring is inspectable after the fact rather than
only summarised.

**A division's overall standing rolls its rounds up by a second, separate
live setting, and it does not have to match the round-level rule above.**
Paintbot (Season 2)'s round level runs `sum`; its standing level runs
`rated`, live since round 3856 — a live-decaying weighted average of an
entrant's round scores rather than a running total or a single all-time
best. An entrant's round score (the sum of their best-12 episode scores
that round, above) is the input to that settlement; what happens to it
once it reaches the standing — the `rated_k` update, why nothing was
reset, and what changed for a reader — is covered in full on [[elo]]. The
practical effect for a reader here: no single round can buy a permanent
rank by itself any more — a big round moves the number for a while, then
that pull fades the same way it eventually fades for every other round.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | Paintbot (Season 2)'s standing aggregation changed from `max` (best round ever) to `rated` (a live-decaying weighted average of round scores), live since round 3856. The round-level `sum`/best-12 rule documented above is unchanged — only the settlement step that turns a round score into a standing changed. See [[elo]] for the full mechanism and what changed for a reader. |
| Unrecorded | Documented the active best-k guard on top of `sum`: a round score sums an entrant's best-k episode scores (k defaults to the league's minimum episodes-per-entrant, currently 12), not literally every episode. Live but not yet binding at today's episode counts. |
| Unrecorded | Paintbot (Season 2)'s live round scoring rule changed from `max` to `sum`: a round's score is now the total of its episode scores rather than its single best episode. The standing aggregation is unchanged at `max` (best round). A live league-setting change, not an engine change. |

## Gaps

- The exact live round cadence for Paintbot (classic): a roughly-12-minute
  reading and a roughly-9-minute reading of the same league disagree, and
  neither has been checked against the other's measurement method.
- Whether other paintbot-family leagues run the same round cadence observed
  on Paintbot (classic), or each runs its own schedule — not confirmed.
- Whether every paintbot-family league's round scoring rule and standing
  aggregation match Paintbot (Season 2)'s `sum`/`rated`, or each league sets
  its own independently — confirmed live only for Paintbot (Season 2).

## See also

- [[main]] — the portal
- [[league]] — the container a round is scheduled inside
- [[episode]] — the match a round is a batch of
- [[elo]] — what a round's aggregated score feeds, where a league runs it
- [[scoring]] — what a score is

## Discussion

Scheduling gripes, opinions on a particular variant rotation, and any
round-by-round results you tracked yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.

