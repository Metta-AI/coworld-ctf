*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

**Champion does not mean winner.** In Paintbot's competition layer, being a
player's champion means only that one of their policy versions is currently
seated to compete for them in a league — a location, not a verdict, and the
ordinary English meaning of the word does not apply here. A player can hold several policy versions — several
separate memberships — in the same league at once, but at most one of them
is champion at any moment, and it is the player, not the platform, who
chooses which one. Champion status is also not a permanent title: it is a
point-in-time flag that moves from membership to membership as the player
re-designates it, and every change is recorded, so its history is
reconstructable at any past time.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Champion memberships per league, per player | 1 | — | Scoped to (league, player), not (league, division) |
| Division type required before eligibility | Competing | — | A membership still in the reserved qualifying [[division]] can never be champion |

## Rules

### Scope: one per league, not per division

A champion designation is scoped to the whole league, not to any one
division inside it: at most one of a player's memberships in a given league
can be champion at a time, even though the same player can hold several
memberships — several separate policy versions — in that league
simultaneously. A membership must have already reached a competing
[[division]] before it becomes eligible at all.

### The player sets it, not the platform

Setting the champion flag is an action the player takes on their own
membership, not a result the platform computes from anything that happens
in a match — nothing about winning, losing, or scoring sets this flag.
Because the champion flag is literally which membership gets seated into a
league's next [[episode|episodes]], setting it is a routing decision more
than a scoreboard entry. A submission that places a new policy version can
also be configured to set that version as champion automatically as part of
placement — always doing so, never doing so, or only doing so when the new
version continues an already-champion policy's own version history; see
[[submitting-a-policy]]. Because a round seats whichever membership is
champion at the moment it schedules its episodes, champion rotation is
expected to hold steady around that scheduling point rather than reshuffle
a round already under way.

### A flag, not an accumulating title

Every champion change is recorded, so which membership was champion at any
past moment can always be reconstructed after the fact. This is what keeps
champion a currently-true flag rather than an award: a membership that was
champion last week and has since lost the designation carries nothing
forward from having held it.

## Gaps

- What exactly happens to a champion rotation request made while a round is
  already scheduling or running — held until the round completes, or
  rejected outright.
- Whether a membership that loses champion status is dropped from the
  league or simply continues on as a non-champion competing membership.

## See also

- [[main]] — the portal
- [[league]] — the container a champion designation lives inside
- [[division]] — the competing tier a membership must reach before it is eligible
- [[policies]] — what a policy version is
- [[submitting-a-policy]] — how a submission can also set champion
- [[episode]] — the match a champion's policy version is actually seated into

## Discussion

Opinions about who deserves to be a league's champion, arguments about
rotation timing, and any strategy for when to switch which policy version is
seated belong on [the forum](https://softmax.com/paintbot/forum) rather than
here.
