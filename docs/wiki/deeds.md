# Deeds

*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

A deed is the unit Paintbot's Glory system prices: one category per flavor
of in-game moment that earns the team a price, from a clean tag to a heart
capture. There are 24 deeds in total; one of them is the null case — no deed
occurred — and it carries no price, pop word, or log name, so the table
below covers the other 23.

**The Glory/Drama numbers below price the classic (CTF) ladder.** Which
trigger mints which deed, and the priority order in `## Rules` below, is the
same engine mechanism [[battle-royale-s2|battle royale]] uses too — but
Paintbot (Season 2)'s live `battle-royale-s2` ladder does not price a deed
with a flat Glory/Drama pair at all. It reprices every deed as a
whole-number multiplier, composed into a per-duo product rather than summed
into a per-team total. See [[glory-season-2]] for that ladder's pricing map;
nothing in the table below applies there.

Every substantive deed carries two numbers, a
Glory price and a Drama price — but the Drama price is read only for its
sign: any positive value makes a deed eligible for the heat ladder and the
carry multiplier, a value of zero makes it ineligible for both, and the
exact number past that point changes nothing else — see [[glory]]. Every
deed also carries two display strings from two different chrome channels: a
one-word HUD **pop word** shown in the moment, and a longer prose **log
name** used only on the stdout herald and the replay log. The two strings
are not interchangeable, and — as the table below shows — one deed's pop
word is deliberately blank.

## Stats

| Log name | Glory | Drama | Pop word | Trigger |
| --- | --- | --- | --- | --- |
| "first tag" | 12 | 20 | `FIRST!` | The episode's first kill, by any weapon, excluding friendly fire |
| "clean tag" | 10 | 10 | `TAG` | The floor: any kill matching none of the other kill deeds here |
| "spray tag" | 12 | 30 | `SPRAYED` | A kill by the [[spray-can]] cone |
| "bomb tag" | 12 | 30 | `BOMBED` | A kill by a [[paint-bomb]] blast |
| "point blank tag" | 12 | 35 | `POINT-BLANK` | A kill at 110 px range or less |
| "longshot tag" | 30 | 40 | `LONGSHOT` | A kill at 700 px range or more |
| "double splash" | 35 | 40 | `MULTI!` | One blast or cone activation killing 2 or more |
| "payback" | 18 | 30 | `PAYBACK` | Killing the cog that killed you, within 240 ticks (10 s) |
| "chase down" | 16 | 20 | `CHASE` | Killing a target fleeing (opening the distance) from you |
| "ace tag" | 40 | 30 | `BOUNTY` | Killing a cog at rank 3 or higher |
| "own paint" | −60 | 0 | `OWN PAINT` | A friendly-fire kill — see [[glory]] for why it's never discounted |
| "heart steal" | 40 | 25 | `STEAL` | Picking the enemy heart off its pedestal |
| "capture" | 250 | 70 | `CAPTURE` | Scoring the enemy heart |
| "the peel" | 90 | 35 | `PEEL` | Killing the enemy carrier, outside denial range of their pedestal |
| "doorstep stop" | 120 | 45 | `DENIED!` | Killing the enemy carrier within 600 px of their own pedestal |
| "escort tag" | 14 | 15 | `ESCORT` | A kill landed while a teammate, not the killer, carries the enemy heart |
| "assist" | 14 | 15 | `ASSIST` | The victim's most recent hit came from a different teammate, within the assist window, and that teammate is not the killer — credited to the assister, not the killer. CTF only. |
| "rescue" | 18 | 30 | `RESCUE` | Killing the attacker whose recent hit left a living teammate at clutch HP — credited to the killer. CTF only. |
| "clutch patch" | 0 | 0 | *(blank)* | Healing yourself at 1 hp — retired as currency in Glory 9 |
| "shield soak" | 4 / hp | 0 | *(blank)* | A [[shield]] absorbing a hit point |
| "wipeout" | 400 | 400 | `WIPEOUT` | The entire enemy team eliminated |
| "rank up" | 0 | 0 | `RANK UP` | A cog's XP crosses a rank threshold — retired as currency in Glory 10 |
| "achievement" | 0 | 0 | *(blank)* | An achievement tier claimed — priced per tier, see [[achievements]] |

## Rules

### Drama is a gate, not a gradient

The Drama column above is checked once, for sign, and never again: a deed
with a positive Drama price is eligible for the heat ladder and the carry
multiplier, and a deed at 0 is eligible for neither. Once a deed clears that
line, its specific Drama number does nothing further — a deed priced
"Drama 10" and one priced "Drama 70" are equally eligible and behave
identically from there on out. Nothing in the engine ranks a replay's
moments by Drama magnitude, or by any other measure; no highlight-ranking
feature exists. See [[glory]] for where the gate is actually checked, in the
mint pipeline.

### One kill, one deed

A kill mints exactly one of the kill deeds above, chosen by a fixed priority
order — whichever condition is highest wins, so a kill is never
double-priced. Highest to lowest: `OWN PAINT` > `DENIED!` > `PEEL` >
`BOUNTY` > `MULTI!` > `LONGSHOT` > `POINT-BLANK` > `PAYBACK` > `CHASE` >
`ESCORT` > `SPRAYED` > `BOMBED` > `TAG` (the floor, for anything matching
nothing above). `FIRST!` is one exception: because it is a
one-shot-per-episode event, it stacks on top of whichever other deed also
fires for that same kill, rather than competing with it. `ASSIST` and
`RESCUE` stack the same way and are also CTF-only: a kill can mint the
priority-chain deed above AND `RESCUE` (to the killer, if the kill answers a
recent menace to a living teammate) AND `ASSIST` (to a different teammate
whose earlier hit qualifies) — all in the same kill, none of them competing
with the priority chain or each other.

### Pop word and log name are two different chrome channels

Every deed's display text splits into a one-word HUD **pop word**, read in
the moment, and a longer prose **log name**, used only by the stdout herald
and the replay log. They are not two spellings of the same string — a deed
can have one without the other.

**The shield-soak deed's pop word is not "SHIELD SOAK."** It has no pop word
at all: the slot is blank, and the deed is explicitly excluded from the
HUD's pop scoring, so it never draws a toast, ever, under any circumstance.
"Shield soak" exists only as the log name above — the string the stdout
herald and replay log use, never the HUD. A list that shows "SHIELD SOAK" as
something you'd see pop on screen is wrong.

**`RANK UP` does draw, but not through the generic path, and it pays
nothing.** The rank-up deed's pop word is real text, shown as `RANK UP`
with one asterisk appended per rank reached — but it's drawn through a
dedicated call in the XP system rather than the shared pop-scoring mechanism
every other deed above uses, and as the table shows, it carries 0 glory and
0 drama (previously 6 and 5, before Glory 10). A rank-up buys power —
windup, hit points, cooldowns, grenade charges — never currency; see
[[ranks]].

**The achievement deed's pop word is also blank, for a third, different
reason.** It isn't silent like the shield-soak deed — an achievement claim
draws its own banner naming the achievement, through a path entirely
separate from the generic deed-pop mechanism this table otherwise
describes. See [[achievements]].

### A pop word is rendered, not transmitted as text

A deed's pop word reaches the broadcast as a pre-rendered sprite, not as a
text field a viewer or policy can read. The server rasterizes the pop
word's letters into pixels and places that sprite directly in the outgoing
wire packet; nothing downstream is told "this pop says TAG" — it is only
ever shown a small picture that happens to spell it.

### There is no flag-return deed

There is no deed for returning a dropped heart, and this is a deletion, not
an oversight or a zeroed-out tombstone like the clutch-heal deed above:
every code path that clears an enemy's heart carrier is already priced by
something else — the carrier's death mints `PEEL` or `DENIED!`, and a
disconnect or stale-index clear has no player action to credit at all.
There was no honest act left over to mint a separate deed for.

## Version history

| Version | Change |
| --- | --- |
| Unrecorded | Mode-scoped this page's pricing table to the classic (CTF) ladder; Paintbot (Season 2)'s `battle-royale-s2` ladder reprices every deed as a whole-number multiplier instead of a flat Glory/Drama pair — see [[glory-season-2]]. |
| Wiki | Corrected this page: a deed's Drama number is read only for its sign — positive vs. zero — to gate heat-ladder and carry-multiplier eligibility; the magnitude itself has no further effect anywhere, and no replay-highlight feature reads it. |
| Glory 10 | Rank-up (`RANK UP`) zeroed to 0 glory / 0 drama — previously 6 glory / 5 drama |
| Glory 12 | Two new CTF-only deeds promoted from existing engine counters: `ASSIST` (14g/15 drama, `dEscortKill` parity) and `RESCUE` (18g/30 drama, `dRevengeKill` parity). Both stack alongside a kill's priority-chain deed, same as `FIRST!` — see "One kill, one deed" above. Deed count 22 → 24. |
| Glory 9 | Clutch-heal ("clutch patch") zeroed to 0 glory / 0 drama, retired as currency — previously 25 glory / 30 drama, popping `SAVE` |

## See also

- [[glory]] — the mint pipeline: base, site gradient, heat, and the carry multiplier
- [[glory-season-2]] — the whole-number multiplier economy this page's prices do not apply to
- [[achievements]] — the 8 trees and their own, separately-priced tiers
- [[ranks]] — what a rank actually buys, and why it resets on death
- [[perception]] — the label contract these pop words sit alongside
- [[conventions]] — the mechanic-and-chrome rule applied to this table

## Discussion

Which deeds are worth chasing, whether heat-stacking or holding the enemy
heart for the carry multiplier is worth the risk, and any of your own
measurements of deed frequency — belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
