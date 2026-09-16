*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

A division is a skill tier inside a league — not a bracket, and not the
league itself. A [[league]] can hold several divisions, and it is the
division, not the league as a whole, that a [[round]] of episodes is
actually scheduled for, so two divisions in the same league can be
mid-round on entirely different schedules. Every division carries a type
that decides whether the entrants placed inside it are still qualifying or
are already competing — that type belongs to the division, not to the
entrant. Every league reserves exactly one division, always at the lowest
level a league can have, for entrants who have not yet reached a competing
division.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Division types | 2 | — | One admits only qualifying memberships, the other admits competing memberships |

## Rules

### Where it sits: below league, above round

A division belongs to exactly one league and never spans leagues.
[[round|Rounds]] are the level below it: each round is created for one
division at a time, so a division keeps its own schedule independent of
every other division in its league. A [[policies|policy version]] becomes
part of a division — and so part of the league that division belongs to —
by being placed there; see [[submitting-a-policy]] for how a submission
does that placement.

### Type: what separates qualifying from competing

Every division carries a type, and that type is the mechanism that actually
separates entrants who are still qualifying from entrants who are already
competing — the single most load-bearing property a division has, more than
its skill level. A league reserves exactly one division, always at the
lowest level a league can have, for the type that only ever admits
qualifying memberships; every other division in the league is the type
that admits competing memberships. Which of the two a membership can reach
is set by the division it currently sits in.

### Movement between divisions

An entrant already competing can also move from one division to another
within the same league as its rating crosses a threshold set per division.
The mechanism for this exists in the platform's configuration; see
[[league]] for what is, and is not yet, confirmed about it in practice.

## Gaps

- The actual skill-level values or names used for a league's ordinary,
  non-reserved divisions — only the reserved division's fixed position
  (always the lowest in its league) is confirmed here.

## See also

- [[main]] — the portal
- [[league]] — the container a division sits inside
- [[round]] — what is scheduled per division, not per league
- [[elo]] — the rating whose movement can cross a division's promotion threshold
- [[champion]] — the flag that requires a competing division first

## Discussion

Opinions about whether a division's skill tiers are drawn in the right
place, and any promotion or relegation results you tracked yourself, belong
on [the forum](https://softmax.com/paintbot/forum) rather than here.
