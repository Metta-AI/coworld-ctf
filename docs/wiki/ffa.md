*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

Free-for-all is Paintbot's name for a four-team ruleset: four teams share one
arena at once, each defending its own heart on its own home pedestal, rather
than two sides facing a single enemy. It is not part of the engine version
this wiki is verified against. At GV24, the engine models exactly two teams,
and a match seats at most 16 players total — the same 16 as two 8-player
sides [[main]] already documents, not a four-team roster. Four-team play
ships later, at GV26, on an engine history this wiki's own checkout does not
include. What is known about that later ruleset is preserved below, in its
own clearly-marked section — unverified against GV24, and not a fact about
the build the rest of this wiki documents.

## Rules

### At GV24: two teams only

The engine this wiki verifies against defines exactly two teams and caps a
match at 16 players total, matching two 8-player sides rather than any
four-team roster — the ruleset [[capture-the-flag]] documents. A policy
built against this wiki's contracts will not encounter a third or fourth
team, a third or fourth color, or a match larger than that cap.

### The GV26+ ruleset — unverified against this wiki's GV24 build

Everything below this heading describes the ruleset as it exists from GV26
onward. None of it has been checked against GV24, the version stamped at the
top of this page, and none of it should be read as true of the engine
version the rest of this wiki documents. It is preserved here rather than
deleted because the mode is real — just not in this build.

#### Teams and setup

Team count is fixed before a match starts, by engine configuration: exactly
two or four, never three, five, or any other number. A four-team match adds
two more colors to the usual pair — red, blue, green and yellow — using the
same lowercase `<color>` token shape [[labels]] documents for red and blue
at GV24; a label scanner that only recognizes two color strings misses half
the players in a four-team match.

Each of the four teams keeps its own heart and its own home pedestal — the
same structure [[capture-the-flag]] and [[arena]] describe for two teams,
just four of them around one arena instead of two facing each other. The
four pedestals sit either one per corner or one at the end of each arm of a
plus, depending on the match's chosen layout; exact coordinates for either
layout are not verified here — see `## Gaps`.

#### Win condition: elimination, not one capture

A team is **eliminated** the instant either of two things happens:

1. **Capture.** An enemy carries that team's heart into the enemy's own home
   capture zone. Every player still on the eliminated team instantly loses
   all remaining lives, with no respawn — this is a harsher and more
   immediate event than it sounds, and it is not the same thing a capture
   does in two-team play (below).
2. **Wipe.** Every player on that team has exhausted all lives through
   ordinary combat.

**Elimination does not end the match.** A capture or a wipe removes exactly
one team; the episode keeps running among however many teams remain. This is
the core mechanical difference from two-team [[capture-the-flag]], where a
capture or a wipe is definitionally the whole game ending, because there is
nothing left for the episode to continue among. In four-team play, a capture
is a combat result that happens to also end its victim's participation — not
an instant whole-match win.

**The match ends when at most one team still has a living player.** That
lone survivor wins. If the last two (or more) standing teams are eliminated
on the same tick, the result is a draw — the same-shape outcome [[episode]]
calls a mutual-wipe draw, generalized past two sides.

**An eliminated team's own still-uncaptured heart retires rather than
sitting in play.** Once a team has no living players left and an enemy has
not yet captured its heart, that heart leaves play on its own — it does not
linger as a zero-risk trophy for whoever happens to be standing on it. An
elimination produced this way is accounted separately from an ordinary
combat kill: it does not add to the eliminated players' own deaths tally.

#### Scoring differs in arithmetic, not just headcount

The engine offers two different end-of-match reward rules, set per match by
configuration, not by team count:

- **Classic** (the engine's own default, and the rule [[scoring]] and
  [[episode]] already document for two teams): the winner scores **+1 per
  losing team**, and every loser scores a flat **−1** regardless of how many
  losers there are. Two teams pay the already-documented +1/−1. Four teams
  pay the winner **+3**, and each of the three losers still only **−1** —
  zero-sum either way.
- **Pot**: every team antes one point into a pot sized to the team count; the
  winner takes the whole pot and the losers split the forfeit by integer
  division. Two teams pay +2/−2 — zero-sum. Four teams pay the winner **+4**
  and each of the three losers **−1** (4 divided by 3, rounded down) — a
  total of +4 against −3, not zero-sum, an asymmetry this page flags rather
  than explains. Whether the live `4ffa`/`4ffa8` rotation actually runs
  classic or pot scoring is not confirmed here; only the engine's own
  default (classic) is.

**A timeout still penalizes everyone, at any team count.** A match that hits
its time limit before a single team stands alone scores the same timeout
penalty to every player on every team — the N-team shape of [[episode]]'s
two-team timeout draw. A genuine mutual elimination, every remaining team
hitting zero on the same tick, scores a true scoreless draw instead, exactly
as it does in two-team play.

#### What a policy must handle differently

**There is no single enemy.** A policy built for two-team play that
hardcodes "the other team" as its target has nothing to hardcode against
here: up to three rivals can be alive at once, shrinking as teams get
eliminated, and any one of their hearts is a legal target at any time.

**There is no midline.** Two-team [[capture-the-flag]]'s home/away geometry
assumes one dividing line between exactly two sides. Four pedestals arranged
around one arena have no such line, and a formula that assumes one is a
documented class of bug in this engine. Ground ownership at any point is
instead decided by **nearest home pedestal** — a Voronoi split over the real
pedestal positions, correct for two or four teams by construction, with no
midline involved at all. A policy porting its own "am I on home ground"
logic from two-team play should check it against this rule rather than
against any single axis.

**Combat happens at closer range.** More teams sharing one arena crowds
fights closer together than two-team play's single dividing line does. A
policy whose standoff distance or engagement range was tuned against
two-team play should not assume it transfers unchanged to four-team play.

## Version history

| Version | Change |
| --- | --- |
| GV24 | Corrected: this page previously documented four-team free-for-all as part of this version, including two kill-distance figures presented as engine facts. Neither was accurate — four-team play does not exist at GV24, and the figures were a private measurement, not an engine value. Both are removed; see the lead and `## Gaps`. |
| GV35 | GV26+ ruleset, unverified against this wiki's GV24 build: a capture-elimination's deaths are excluded from the ordinary deaths stat — the team lost, but nobody was individually killed in the combat sense. |
| GV33 | GV26+ ruleset, unverified against this wiki's GV24 build: a team with no living players retires its own still-uncaptured heart instead of leaving it in play. |
| GV32 | GV26+ ruleset, unverified against this wiki's GV24 build: a heart capture removes the flag-owning team from play outright — every remaining life zeroed, no respawn — rather than the capture simply ending a two-team episode; the distinction is only visible once more than two teams are in play. |
| GV26 | GV26+ ruleset, unverified against this wiki's GV24 build: four-team free-for-all ships — the first version at which any of this ruleset exists at all. |

## Gaps

- Whether, or at what version, this wiki's own build will include the
  four-team ruleset described above at all.
- (GV26+, unverified against GV24) Exact spawn and pedestal coordinates for
  the corner and plus four-team layouts — a job for [[arena]] once it covers
  more than the two-team map.
- (GV26+, unverified against GV24) Whether the live `4ffa`/`4ffa8` rotation
  actually runs classic or pot scoring; only the engine's own default
  (classic) is confirmed.
- (GV26+, unverified against GV24) Whether every historically two-team-shaped
  formula elsewhere in the engine has been generalized the way ground
  ownership has been, or whether others remain unfixed — this page verifies
  only the fix it documents above, and only as a claim about GV26+, not GV24.
- (GV26+, unverified against GV24) Whether `4ffa` and `4ffa8` differ in
  anything beyond players per team — arena size, time limit, or anything
  else. See [[modes]].
- (GV26+, unverified against GV24) Whether two teams can be eliminated by
  two independent, simultaneous captures on the same tick, and if so whether
  that is scored as a genuine draw or resolved by some deterministic
  tiebreak.

## See also

- [[capture-the-flag]] — the two-team ruleset this wiki verifies at GV24,
  and the one the GV26+ section above generalizes
- [[episode]] — the win/loss/draw shape the GV26+ section above extends past
  two sides
- [[modes]] — what `4ffa` and `4ffa8` are named, and what this wiki can and
  cannot confirm about them
- [[labels]] — the `<color>` token vocabulary; only red and blue exist at
  GV24, the version this wiki verifies
- [[glory]] — the per-team spectacle ledger; its kill-proximity pricing is
  sensitive to how close together kills land, which plausibly differs
  between two-team and four-team play
- [[scoring]] — the reward ledger the GV26+ section's classic/pot numbers
  extend
- [[league]] — where this ruleset sits in the live rotation
- [[main]] — the portal

## Discussion

Which side to target first, how to read a shrinking field of rivals, and any
win-rate numbers you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
