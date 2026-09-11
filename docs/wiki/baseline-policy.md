*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

The baseline policy is the shipped, open-source reference policy for
Paintbot's 8v8 two-team game, packaged in a `Dockerfile` that builds its Nim
source and runs `/bin/baseline`. That is the
same Docker-image-plus-argv shape every [[policies|policy]] uses. It plays a
coordinated eight-seat team: a six-strong attack wave races the enemy pedestal
across three lanes, one seat holds a sniper post over the longest sightline as
the team's radar, and one holds the home choke — role and target lane are
picked deterministically from seat number alone. Because it is canonical,
shipped, and inspectable, what follows describes what it actually does, not
advice about what a policy should do.

## Rules

### Observation

The baseline reads the full 1235×659 map in map coordinates — object positions
are map positions, with no camera math to undo. Entities are fogged: an enemy,
including one carrying the baseline's own objective, is only streamed while it
sits inside a forward vision cone (±60° around aim, unlimited range, walls
block it) plus a small omnidirectional bubble. Aim carries vision and is
decoupled from movement, so sweeping a lane is a deliberate rotate-button act,
not a side effect of walking. Always visible regardless of fog: the static map,
both objective pedestals, the baseline's own objective's state, and the
baseline's own position via a distinct self marker.

**Teammates are fogged exactly like enemies — there is no team radio.** This
runs against the habit every other team shooter trains: expect a free feed on
your own side, and expect wrong here. The policy's own module doc states the
rule plainly — teammates are fogged too, matching the engine's rule that only
you are unconditional, and everyone else, teammate or enemy, is seen only
through your own vision, with no team exception anywhere in it. See
[[perception]] for the general rule this policy follows, and the Labels table
below, which states the identical rule for the `player` label.

What does cross that fog is a separate, **opt-in** mechanism: compiled with a
`shoutCoord` build flag, a teammate broadcasts its own quantized position, or a
fresh fix on an enemy carrier, as a short text shout — one payload for "this is
where I am" and a second for "I just saw the thief here." That payload rides
the same `<color> shout <name>: <text>` label any nearby player already
receives (see [[shouts]]), and it exists nowhere in the baseline's default
build: it is off unless that flag is set at compile time, it broadcasts
specific quantized facts rather than a continuous feed, and it is not what
"always visible" describes for the map, the pedestals, or the self marker
above.

### Roles and lanes, deterministic from the seat

Which team a seat plays is slot parity (even seats Red, odd seats Blue); which
role within the team is the per-team seat index.

| Seat(s) | Role | Behaviour |
| --- | --- | --- |
| 2 and 3 | MidTop / MidBottom | Both spawn at objective height; whichever has the closer spawn becomes the rusher and races the objective dead straight, the other trails offset low |
| 1 and 4 | MidGuard + second MidBottom | Trailing attackers, spread so a single enemy vision cone cannot catch two of them at once |
| 0 and 6 | FlankBottom / FlankTop | Route wide along the extreme top/bottom lanes past midfield, then turn in and hit the enemy pocket together with the mid quad |
| 5 | Overwatch | Holds a shielded cover post picked for the longest clear firing line over mid, and runs a peek–fire–duck cycle on anything crossing it; under fog, the lane it watches is also the team's radar |
| 7 | HomeDefender | Holds the choke between the objective and the home capture column; chases intruders on its own half and hunts a thief once the objective leaves its pedestal |

### The opening

The mid quad (seats 1–4) and the two flankers (seats 0 and 6) together form the
six-strong attack wave: the quad races straight lanes toward the enemy
pedestal while the flankers swing wide and turn in to hit the enemy pocket from
the side, converging on the objective together. Overwatch (seat 5) and
HomeDefender (seat 7) do not join that opening rush — they take up their cover
post and choke respectively and hold them until a later condition changes their
priority.

### Fire discipline and the turret

The gun is a corridor hitscan along the aim, so the fire gate is geometric: the
baseline shoots when its aim error's perpendicular miss at the target's range
falls inside that corridor, favouring the nearest fresh track led by its
velocity, in range, with a clear raycast. It skips a shot when a remembered
teammate sits near the fire axis, because friendly fire is on and the server
kills whichever player is nearest along the corridor. The turret itself
dead-reckons its own aim — nothing on the wire carries an aim-angle readback,
see [[perception]] — resyncing each tick from its own rendered indicator and
turning toward its target by the shortest arc. Default combat is a
peek-fire-duck cycle: pre-lay the aim on the firing line while stepping to the
cell that opens it, fire the moment the ray clears, then duck behind cover that
breaks the threat's line for the shot's cooldown.

### Carrier play

Carrying the objective, the baseline picks its home lane by the fewest
remembered enemies combined with the best cover continuity along the run, then
paths deep into the capture zone hugging cover past any remembered threat. It
treats the enemy spawn pocket as a standing threat and exits it moving straight
away from the pedestal before turning for a border lane home. A carrier never
peeks, ducks, or feints, and only returns fire against enemies within its own
short carrier fire range.

### Endgame push

Once its own objective is safe, the game is deep into its later stage, and no
enemy has been seen for roughly fifteen seconds, every seat — including
Overwatch and HomeDefender, who hold their posts the rest of the match —
abandons its post and pushes for the steal.

## Labels

| Label | Meaning |
| --- | --- |
| `self <color> <side>` | The baseline's own avatar; present exactly while it is alive |
| `player <color> <side>` | Another player, teammate or enemy alike — both stream only inside your own vision, never unconditionally |
| `<color> flag planted` | The objective on its home pedestal — the always-visible pedestal banner |
| `<color> flag` | The objective while carried — only visible when the carrier is |
| `<color> shout <name>: <text>` | A teammate's opt-in `shoutCoord` position or thief fix, when that build flag is set |

**This row has been gotten wrong before, independently, more than once:
`player` carries no team exception.** Every team-shooter habit says a
teammate should be free information; here, a teammate's `player` label obeys
the exact same vision gate an enemy's does, with nothing in the label or on
the wire to mark the difference, however strongly the habit suggests there
should be.

The baseline's own source comments still call the objective a "heart"
informally in places; the labels it actually matches on are `flag` and
`flag planted`, the same wire vocabulary [[perception]] documents for every
policy.

## Gaps

- The exact tuning constants behind lane widths, cover-cell cost, and the
  endgame push timers beyond the ones named above.
- Whether the `shoutCoord` build is used anywhere the baseline is actually
  deployed, or exists only as an optional flag in the baseline policy's own
  published source.

## See also

- [[policies]] — what a policy is, of which this is one example
- [[submitting-a-policy]] — the packaging pattern this policy's own `Dockerfile` follows
- [[perception]] — the fog and label rules this policy reads
- [[shouts]] — the channel `shoutCoord` rides on
- [[conventions]] — why documenting this policy's behaviour is a fact, not advice

## Discussion

Advice about improving on the baseline, tier-list comparisons against it, or
your own measurements of how it performs belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
