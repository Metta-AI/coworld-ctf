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
Paintbot (Season 2) currently runs it at **0.02** (retuned down from
0.05, live since 2026-09-15T21:15Z) — confirmed directly
against the league's own live ladder configuration, not merely inferred
from the settling-time math below. Each time an entrant's
round is scored, their standing moves toward that round's score by 2% of
the gap between them:

```
standing = standing + rated_k × (round_score − standing)
```

Applied once per round an entrant plays, this is what produces "current
form": a `rated_k` of 0.02 washes out
about half of any one round's weight after roughly 35 rounds scored.
Paintbot (Season 2)'s round cadence is itself not fixed: a new round
starts roughly every 10 minutes while a policy has been submitted in the
last 60 minutes, and roughly every 30 minutes once nothing new has been
submitted for that long (a fresh submission wakes it back to 10) — so 35
rounds lands around 6 hours of wall clock during an active stretch, and
considerably longer overnight when the ladder is idle. A single spectacular round still
moves the number, but it keeps moving afterward, decaying back toward
whatever an entrant does next, rather than freezing in place as a
permanent high-water mark the way `max` aggregation used to. Standing
starts at 0 for a new entrant, before any round has scored.

### A clamp bounds any one round's pull on the average

The blend above is not applied to a round's raw score unmodified: the live
service can winsorize a round score against the standing it is about to
update, before the 2% blend runs, so that one extreme round cannot move an
entrant's standing by more than a bounded multiple in a single step. This
clamp is a per-league setting, off by default (unset); Paintbot (Season 2)
currently runs it live, confirmed directly against the league's own
configuration, at a multiple of **150** — which bounds the largest possible
single-round move to **3.98×** the standing going in (`1 + rated_k ×
(150 − 1)`), rather than letting an outlier round through unbounded.
Under the log-scale scoring live since 2026-09-15, that bound sits far above
any real round score — a round scores tens of points while the bound is
hundreds — so in practice the clamp does not bite; the 3.98× figure is the
ceiling on a single round's pull, not a typical move.

A separate, more aggressive rescaling of round scores before they ever
reach the blend above — a signed, sign-preserving log-style transform —
exists in the same configuration schema but is confirmed **off**
(`"none"`) for Paintbot (Season 2) today. If it were switched on it would
change how a round's raw score maps to the `round_score` this section's
formula blends, not the 2% blend itself.

### A leg only banks on a win — everything else is zero

Live since 2026-09-15, on top of the blend above: an entrant's episode
score only counts toward that round at all if it was the top score (or
tied for it) among the episode's other scored seats that round — a loss
counts as a zero for that leg, the same zero whether it lost by a hair or
by the whole board. What a winning leg actually banks is not its raw
score but a signed, sign-preserving log-base-2 rescaling of it: doubling
the raw score of a leg you already won only adds one point to what it
banks, while turning a leg from a loss into a win adds that leg's entire
banked value — winning more often moves the round score far more than
scoring bigger within the wins you already have.

### What the board shows is not what you're ranked by

Standing is tracked, and ranked, in the same log space the paragraph
above banks legs in — but the number shown on the leaderboard is
converted back out of log space for readability before it's displayed.
Because of that conversion, a gap between two displayed numbers reads as
multiplicative even though the underlying ranking value the platform
actually compares is additive: a small move in true standing can look
like a large jump (or drop) in the number on the board.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Rating divisor | 400 | — | Standard logistic Elo divisor |
| Code default K-factor | 32 | — | Applies unless a league's own configuration overrides it |
| Code default initial rating | 1500 | — | Every new entrant starts here unless a league overrides it |
| Paintbot (Season 2) `rated_k` | 0.02 | — | A live-service value, not an engine constant; confirmed directly against the league's own configuration. Retuned 0.05 → 0.02, live since 2026-09-15T21:15Z |
| Paintbot (Season 2) round-score rule | Sum of best 12 episode scores | — | A live-service value; reduces to a no-op in the live 16-solo battle-royale ladder, where an entrant plays exactly one leg per round |
| Paintbot (Season 2) standing clamp multiple | 150 | — | A live-service value; bounds one round's move to 3.98× the standing going in |
| Paintbot (Season 2) season-leg transform | Win-gated signed log-base-2 | — | A live-service value; armed since 2026-09-15, replacing `none` — see the sections above |
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
- `rated_k`'s value (0.02, retuned from 0.05 on 2026-09-15) and Paintbot
  (Season 2)'s exact aggregation settings (`sum_top_k` 12,
  `round_scoring_rule` "sum", `standing_aggregation` "rated", the standing
  clamp multiple 150, the season-leg transform now armed — win-gated
  signed log2, replacing "none" — and the initial standing 0) are now
  confirmed directly against the league's own live ladder configuration —
  no longer inferred. The literal per-round update arithmetic shown above
  is still cross-checked
  only against the observed round cadence and settling time, not a direct
  read of the platform's own update-step source, which lives in a separate
  service this wiki does not track.
- Whether the signed-log-style season-leg transform, now armed for
  Paintbot (Season 2), changes anything about the clamp or the 2% blend
  themselves, or only the round score fed into them before either runs —
  not independently confirmed in this pass which of the two it is.
- Whether the log-base-2 rescaling and win-gate above also apply to any
  paintbot-family league besides Paintbot (Season 2) — confirmed live only
  for Paintbot (Season 2) in this pass.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | Clarified that the standing clamp does not bind under the log-scale scoring live since 2026-09-15. |
| Unrecorded | From round #5519 (2026-09-17), the round score under the new rescaling below is a true sum of an entrant's scored legs; rounds #5393–#5518 divided that sum by the number of legs instead, so standings from the two windows are not directly comparable. |
| Unrecorded | Paintbot (Season 2)'s `rated_k` retuned 0.05 → 0.02, and a win-gate plus a signed log-base-2 rescaling of the round score both armed, live from 2026-09-15T21:15Z — see the new sections above. |
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

