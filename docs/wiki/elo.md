*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

Elo is one of two competitive-rating algorithms a Paintbot-family league can
run for its ladder; the other, a direct score-standing algorithm, is
described below. Elo itself is a standard pairwise update against a
400-point logistic divisor, computed once per round from each entrant's
round-aggregated score rather than from any individual match result. Not
every league runs on it, and not every league that does uses the same
settings — each league can switch its ladder on or off, choose which
algorithm it runs, and tune its own K-factor and initial rating
independently of the code defaults below. The flagship classic-mode league
that once ran this way has since split into two leagues: **Campaign**, a
territory-style board with no Elo ladder at all, and **Paintbot (Season
2)**, whose ladder runs the score-standing algorithm below, not Elo — see
[[league]].

### The score-standing algorithm (not Elo)

**Paintbot (Season 2)'s live ladder does not run the pairwise Elo update
below at all.** It ranks entrants directly by score — no opponent-relative
rating, no expected-result calculation — but "ranks by score" is not the
same as "ranks by your best-ever score": see "What your standing means
now" immediately below for how a round's score actually becomes a
standing today. What that score is, and how it rolls episodes up into a
round, is a per-league setting — see [[round]] for Paintbot (Season 2)'s
live values (round score = sum of an entrant's best 12 episode scores that
round; for the live 16-solo battle-royale ladder, where each entrant plays
exactly one episode leg per round, that reduces to a no-op — the round
score is simply that leg's own episode Glory, win or lose).

**What your standing means now, and why the number moved.** As of round
3856, Paintbot (Season 2) stopped ranking entrants by their single best
round ever and started ranking them by their **current form**: a
live-updating weighted average of recent round scores that leans heavily
on the last couple of hours of play and lets older rounds fade. Nothing
was reset — the platform replayed the league's entire round history
through the new formula, and every entrant's `rounds_played` count is
exactly what it always was. Episode scoring itself didn't change either: a
huge round still mints the same huge round score it always did. What
changed is only how a round feeds the number on the board — one enormous
round used to sit there forever as a permanent rank; now it pulls an
entrant's standing up for a while and then fades, the same as it fades for
everyone else. A run of good rounds climbs the board over roughly a dozen
rounds; one lucky round no longer buys a permanent seat at the top.

Your standing is also built from real games only. A stretch of rounds in
late August played out broken and never counted toward anyone's standing
in the first place. The replay that rebuilt today's standings honors that
same boundary — it counted only rounds that ever actually scored, so that
broken stretch is excluded now exactly the way it was excluded then.

### A second K-factor: how "current form" is computed

The weighted average above runs on its own factor, separate from the Elo
K-factor elsewhere on this page — the live service calls it `rated_k`, and
Paintbot (Season 2) currently runs it at **0.05** — confirmed directly
against the league's own live ladder configuration, not merely inferred
from the settling-time math below. Each time an entrant's
round is scored, their standing moves toward that round's score by 5% of
the gap between them:

```
standing = standing + rated_k × (round_score − standing)
```

Applied once per round an entrant plays, this is what produces "current
form": at Paintbot (Season 2)'s live round cadence — a new round roughly
every 10 minutes, confirmed live — a `rated_k` of 0.05 washes out about
half of any one round's weight after roughly a dozen rounds scored, which
on the wall clock lands around two hours. A single spectacular round still
moves the number, but it keeps moving afterward, decaying back toward
whatever an entrant does next, rather than freezing in place as a
permanent high-water mark the way `max` aggregation used to. Standing
starts at 0 for a new entrant, before any round has scored.

### A clamp bounds any one round's pull on the average

The blend above is not applied to a round's raw score unmodified: the live
service can winsorize a round score against the standing it is about to
update, before the 5% blend runs, so that one extreme round cannot move an
entrant's standing by more than a bounded multiple in a single step. This
clamp is a per-league setting, off by default (unset); Paintbot (Season 2)
currently runs it live, confirmed directly against the league's own
configuration, at a multiple of **150** — which bounds the largest possible
single-round move to **8.45×** the standing going in (`1 + rated_k ×
(150 − 1)`), rather than letting an outlier round through unbounded.

A separate, more aggressive rescaling of round scores before they ever
reach the blend above — a signed, sign-preserving log-style transform —
exists in the same configuration schema but is confirmed **off**
(`"none"`) for Paintbot (Season 2) today. If it were switched on it would
change how a round's raw score maps to the `round_score` this section's
formula blends, not the 5% blend itself.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Rating divisor | 400 | — | Standard logistic Elo divisor |
| Code default K-factor | 32 | — | Applies unless a league's own configuration overrides it |
| Code default initial rating | 1500 | — | Every new entrant starts here unless a league overrides it |
| Paintbot (Season 2) `rated_k` | 0.05 | — | A live-service value, not an engine constant; confirmed directly against the league's own configuration |
| Paintbot (Season 2) round-score rule | Sum of best 12 episode scores | — | A live-service value; reduces to a no-op in the live 16-solo battle-royale ladder, where an entrant plays exactly one leg per round |
| Paintbot (Season 2) standing clamp multiple | 150 | — | A live-service value; bounds one round's move to 8.45× the standing going in |
| Paintbot (Season 2) season-leg transform | `none` | — | A live-service value; an alternate log-style rescaling exists in the schema but is off today |
| Paintbot (Season 2) initial standing | 0 | — | A live-service value; every entrant starts here before their first scored round |

## Rules

### The pairwise update

For every pair of entrants scored within the same round, one side's expected
result is the 400-point logistic of the ratings' difference, and each side's
rating then moves by the K-factor times the gap between its actual result
and that expectation:

```
expected(A) = 1 / (1 + 10^((rating(B) − rating(A)) / 400))
new_rating(A) = rating(A) + K × (actual(A) − expected(A))
```

Actual result is 1 for a win, 0.5 for a draw, 0 for a loss. Every pair of
entrants scored in a round is compared exactly once, so an entrant facing
*n* opponents in one round receives *n* separate rating deltas from it, not
one.

### Rated against the round, not the episode

[[round|A round]], not a single [[episode]], is the unit Elo actually
scores. Each entrant's episode scores inside a round are reduced to one
round score before any comparison happens, by that league's own round
scoring rule — the code default is their mean, but a league can override it
to something else (see [[round]]) — and it is that round score two entrants
are compared on.

### Live configuration differs per league

**Whether playing rates you at all, and by how much, depends on which
league you entered.** The formula above is shared code, but each league's
ladder settings — whether it is switched on, its K-factor, its initial
rating — are per-league configuration on the live service, not engine
constants, and they can change at any time independently of the GV/Glory
stamp above. No fixed table of current values is reproduced here for that
reason; these are settings that differ by league and can change.

Within the Paintbot family: **Paintarena** runs the ladder described above.
**Campaign** — the territory-board league descended from the old classic
mode — runs its episodes on a scheduled round cadence but with no Elo ladder
at all; what drives its live leaderboard is a territory-style campaign score
instead, a different scoring concept entirely; see [[league]] and [[round]].
**Paintbot (Season 2)** also does not run this pairwise algorithm — see
the score-standing section above. **Ctf**, a league that once shared
Paintbot's coworld and rules, stopped playing entirely on 2026-08-12 and no
longer runs rounds, so whatever its ladder configuration says currently has
nothing left to apply to. **Elite Paintbot** has no ladder configuration of
this kind at all: its own rating lives in a separate system tied to that
league's own hex-territory competition, not the round/episode ladder this
page documents. That separate system happens to reuse this formula's same
textbook defaults, but one is not the other.

## Gaps

- Whether a league with its ladder switched off leaves rating fully inert,
  or whether some other path still updates it independent of the disabled
  scheduler — not traced to a definitive gate in this pass.
- Where each league's specific K-factor and initial-rating overrides are
  actually configured, and what today's per-league values are — not
  confirmed from any public source in this pass.
- How the territory-style campaign score that drives Campaign's live
  leaderboard is actually computed — out of scope for this page. No
  [[campaign]] page exists yet to answer this; it is not something a reader
  can currently follow this link to.
- Whether any other Paintbot-family league besides Paintbot (Season 2) uses
  the score-standing algorithm instead of Elo — confirmed live only for
  Paintbot (Season 2) and Paintarena (Elo) in this pass.
- `rated_k`'s value (0.05) and Paintbot (Season 2)'s exact aggregation
  settings (`sum_top_k` 12, `round_scoring_rule` "sum", `standing_aggregation`
  "rated", the standing clamp multiple 150, the season-leg transform
  "none", and the initial standing 0) are now confirmed directly against
  the league's own live ladder configuration — no longer inferred. The
  literal per-round update arithmetic shown above is still cross-checked
  only against the observed round cadence and settling time, not a direct
  read of the platform's own update-step source, which lives in a separate
  service this wiki does not track.
- Whether the signed-log-style season-leg transform, if ever armed for
  Paintbot (Season 2), changes anything about the clamp or the 5% blend
  themselves, or only the round score fed into them — not exercised live
  by this league today, so not directly observable.

## Version history

| Version | Change |
| --- | --- |
| Wiki | Added the standing clamp (150), the season-leg transform (`none`), and initial standing (0) — all confirmed live against Paintbot (Season 2)'s own configuration; corrected an internal inconsistency where this page still described standing as "sorted, maximized" alongside the rated-EMA section below; noted the 12-episode round-score sum is a no-op in the live 16-solo battle-royale ladder, where an entrant plays one leg per round. |
| Unrecorded | Paintbot (Season 2)'s standing aggregation changed from `max` (best round ever) to `rated`, live since round 3856: an entrant's standing is now a live-decaying weighted average of their round scores (`rated_k` 0.05), not their single all-time-high round. The full round history was replayed through the new formula; `rounds_played` was not reset. See the new sections above. |
| Unrecorded | The Paintbot (Season 2) cross-reference updated: a round score sums an entrant's best 12 episode scores that round (the best-k guard on `sum` — see [[round]]), not every episode played. |
| Unrecorded | Paintbot (Season 2)'s live round scoring rule changed from `max` to `sum` — the live values above updated to match; the standing aggregation (best round) is unchanged. |
| Unrecorded | The classic-mode "Paintbot" league split into two separate leagues: Campaign (territory board, no Elo) and Paintbot (Season 2), whose live ladder was found running a direct score-standing algorithm rather than Elo — see the new section above. |

## See also

- [[main]] — the portal
- [[round]] — the unit Elo scores against
- [[league]] — where a ladder's configuration lives
- [[episode]] — the match a round's score is built from
- [[glory]] — what the score actually is for Paintbot (Season 2)'s live rated ladder
- [[scoring]] — a different, separate per-player ledger this ladder does not read

## Discussion

Debate about whether a K-factor is too volatile, strategies for climbing a
ladder, and any rating history you tracked yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.

