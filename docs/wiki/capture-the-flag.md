*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

Capture the flag is Paintbot's classic mode, in which two teams each defend a
heart on home ground while racing to steal and carry home the other's. It is
one of several rulesets the game runs — see [[modes]] for the full list,
including [[ffa]]'s four-team variant, not part of this build. The objective
has two correct names at two layers: the wire label is `flag`, the string a
policy matches on, while the fiction and the broadcast call it a *heart*
(`RED HEART STOLEN!`). Touch the enemy team's flag on its home pedestal,
within 12 px, to steal it, then carry it into your own home capture zone to
win the episode outright. A carrier moves at 70% speed but can still shoot, and
— unlike most capture-the-flag games — does not need their own team's flag to
be home before they can score.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Steal touch range | 12 px | — | Distance from your collision-centre to a flag still on its pedestal; fixed regardless of map — see Rules |
| Carrier speed | 70% | — | Waived to 100% at rank 5 — see [[ranks]] |
| Capture zone depth, Red | 207 px | — | `x` 0–206 on the default arena, full map height, no y-bound; see Rules for how this is derived |
| Capture zone depth, Blue | 206 px | — | `x` 1029–1234 on the default arena, full map height, no y-bound; fixed regardless of map — see Rules |
| Denial range | 600 px | — | How close to their own pedestal a carrier must die for the kill to price as a doorstep stop (`DENIED!`) instead of a peel (`PEEL`) — see [[deeds]] |

## Rules

### Stealing and carrying

A flag is always in exactly one of two states: sitting on its home pedestal,
or riding a living enemy — it is never loose on the ground and there is no
fumble-and-drop. Walking within 12 px of an enemy flag still on its pedestal
steals it; a player can never touch their own team's flag, and a player
already carrying cannot steal a second one. Every steal and capture is priced
as a Glory deed and pays XP — see [[deeds]] and [[glory]].

**A steal counts as "contested" at 300 px.** If a living enemy is within
300 px of the stealer at the instant the steal lands, the claim is priced and
gated differently from an uncontested one — see [[achievements]] for the tiers
this feeds.

**Carrying costs speed, not firepower.** A carrier moves at 70% of normal
speed (waived back to 100% at rank 5, the max rank — see [[ranks]]) but faces,
aims, and fires exactly like an uncarried player.

**Losing the carrier returns the flag immediately, by any cause.** Tagging
out the carrier, or the carrier disconnecting, snaps the flag straight back
to its own home pedestal on the same tick — never to the ground where it was
lost. The engine prices a carrier kill differently depending on where it
happens: a peel (`PEEL`) anywhere outside denial range, or a doorstep stop
(`DENIED!`) when the kill lands within 600 px of the carrier's own pedestal
(defending your doorstep prices higher) — see [[deeds]].

### Capture

**There is no own-flag-must-be-home precondition.** The engine's own comment
on the win check is explicit that this is deliberate: you can carry the enemy
flag into your capture zone and win even while your own flag is currently
stolen. Nothing about the objective fight requires defending your own
pedestal to be eligible to score.

The check itself runs every tick, for a living carrier only: the carrier's
collision-centre x-coordinate must land inside their own team's capture
zone x-range. **The check has no y-bound at all** — the zone is a full-height
half-plane running the entire vertical extent of the map, not a bounded box
with a goal-line top and bottom, so a carrier scores by crossing the
x-threshold at any height. **A capture is checked, and can end the
episode, before the wipe condition is checked in the same tick** — so a carrier
who completes the capture on the exact tick their own team is wiped out still
wins by capture; the episode never falls through to a mutual-wipe draw in that
case.

Winning, losing, and draw scoring are the same for every path to the episode's
end — see [[episode]] and [[scoring]] for the +1/−1/−1/0 numbers and the
wipe and timeout conditions this page doesn't repeat. Those numbers, and the
two-sides-only shape of this whole page, are scoped to this build's two-team
ruleset; [[ffa]] documents the different elimination-not-instant-win shape and
scoring once more than two teams share an arena — a later ruleset, not part
of this GV24 build.

### The capture zone, and a misleading constant

`CaptureZoneWidth = 40` is the one number in this system worth reading twice:
its name suggests a symmetric 40 px band, but the win check only ever adds or
subtracts *half* of it — 20 px — from a team's home-anchor x, and uses that
as the capture zone's **inner** edge only. The **outer** edge is the map's
own border. So `CaptureZoneWidth` names a half-band offset from home, not a
span, and the real scored region is the entire column from your team's edge
of the map in to `homeAnchor ± 20` — essentially the whole capture/spawn
column, unbounded in height and spanning the full vertical extent of the
map, not a thin goal line at its inner lip.

On the default 1235 px-wide arena, home anchors sit at x=186 for Red and
x=1049 for Blue, so that column works out to Red `x` 0–206 (207 px deep) and
Blue `x` 1029–1234 (206 px deep). Full obstacle geometry and the spawn pocket
this column shares space with are on [[arena]].

**The drawn endzone matches the scored region exactly.** The floor tint that
marks each team's capture column is baked from the identical
`homeAnchor ± CaptureZoneWidth div 2` formula the win check itself uses, not
a separately-drawn approximation — so what a viewer sees painted on the floor
is what a policy's capture is actually tested against.

**Two similarly-named constants are not this zone, and describe something
else entirely.** `ArenaFlagRing = 70` is the radius of a small clearing kept
permanently obstacle-free at the exact center of the map — nothing to do with
either team's flag despite the name, just a naming coincidence with this
page's subject. `ArenaCaptureClear = 210` is the depth, from each border
inward, of the column the map generator is forbidden from ever placing an
obstacle in — a *protected-floor* guarantee, not the scored threshold, and
close enough to the real 206/207 px capture depth above to be mistaken for
it. [[arena]] covers the full protected-floor-versus-capture-zone
distinction and its geometry table; this page only needs to flag that the two
are different things.

**Neither number on this page scales on the large arena.** [[arena]]'s 1.3×
`arena-large` variant grows the flag-ring clearance, the protected-floor
depth, the spawn pocket and the gun range all by the same 1.3× the map itself
grows by — but the steal touch range and the capture zone depth are not part
of that per-map scaling block at all. Both are fixed values, identical on
every map. A carrier on the large arena steals and scores against the exact
same 12 px and ~206 px the default arena uses, even though every clearance
around them has grown 30%.

## Labels

| Label | Meaning | Stream |
| --- | --- | --- |
| `<color> flag` | The objective itself, including while carried | POV only |
| `<color> flag planted` | The objective on its home pedestal | Both |
| `<color> flag carried` | The carried-objective banner art | Board only |
| `<color> flag carrier glow` | Halo marking a visible carrier | Both, gated differently |

**The bare `<color> flag` and `<color> flag carried` are near-mirror images,
and the mismatch runs in both directions.** A policy reading its own view
never sees `flag carried` — the broadcast sends that label in the bare
label's place whenever a carrier holds the objective — while a board
recording never carries the bare `<color> flag` at all. A policy tells
carried from planted by the presence or absence of `<color> flag planted`
instead, since both streams carry that one. The carrier's glow sits next to
this split without joining it: it exists on both streams, but a POV's copy is
gated by the carrier's real vision-cone-and-bubble fog while the board's copy
ignores fog entirely. Full label table, the fog rules behind it, and every
other contract label in the game are on [[labels]] and [[perception]].

## Version history

| Version | Change |
| --- | --- |
| GV24 | Corrected: this page previously framed capture the flag as Paintbot's core win condition. It is the game's classic two-team mode, one of several rulesets — see [[modes]] for the list and [[ffa]] for the four-team ruleset that is out of scope at this version. |

## Gaps

- No GameVersion is recorded for when the current `CaptureZoneWidth` value,
  the steal mechanic, or the carrier speed tax were introduced — they predate
  the earliest version this wiki can date, and pinning one down would need an
  older published release to compare against.

## See also

- [[main]] — the portal and the objective's two-layer name in overview
- [[modes]] — the other rulesets Paintbot runs besides this classic mode
- [[ffa]] — the four-team ruleset this page's two-team shape does not cover,
  not part of this GV24 build
- [[episode]] — lives, respawn, the wipe and timeout conditions, and the
  score-ending tick order this page builds on
- [[arena]] — capture-zone and protected-floor geometry, pedestals, and
  the map's obstacle layout
- [[labels]] — the full label vocabulary, POV versus board, in one table
- [[perception]] — fog of war and why your own pedestal is never fogged
- [[scoring]] — the +1/−1/−1/0 reward numbers
- [[deeds]] — the heart-steal, capture, peel, doorstep-stop, and wipeout
  deeds, and their Glory pricing
- [[achievements]] — the contested-steal tiers fed by the 300 px radius above
- [[glory]], [[ranks]] — the Glory ledger and the per-life rank ladder that
  waives the carrier speed tax at rank 5
- [[conventions]] — the mechanic-and-chrome layering rule this page applies

## Discussion

Whether to push for a fast steal-and-capture or grind toward a wipe, how to
defend a doorstep denial, and any win-rate numbers you measured yourself
belong on [the forum](https://softmax.com/paintbot/forum) rather than here.
