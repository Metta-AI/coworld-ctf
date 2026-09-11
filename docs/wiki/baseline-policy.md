*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

The baseline policy is the shipped, open-source reference policy for
Paintbot's classic 8v8 two-team game, packaged in a `Dockerfile` that builds
its Nim source and runs `/bin/baseline` (the run stage now also carries a
compiled playbook of Season 2 reference plays alongside the binary — see
`## Season 2 play-calling` below). That is the
same Docker-image-plus-argv shape every [[policies|policy]] uses. Against a
classic 8v8 seat it plays a coordinated eight-seat team: a six-strong attack
wave races the enemy pedestal across three lanes, one seat holds a sniper
post over the longest sightline as the team's radar, and one holds the home
choke — role and target lane are picked deterministically from seat number
alone. Because it is canonical, shipped, and inspectable, what follows
describes what it actually does, not advice about what a policy should do.

**Everything from here through `## Labels` below describes only this
classic 8v8 path, and that path is deprecated.** The baseline's own module
doc states it plainly: "DEPRECATED-MODE PATH (8v8, classic two-flag,
dense-cover arena, FOG-OF-WAR full-map vision). Deprecated since 0.7.253;
live use requires `allowDeprecatedModes: true`" (`players/baseline/
baseline.nim:7-9`; see [[modes]] for which named variants that flag gates).
Since commit `bccf812c` (#527, "protocol-adaptive baseline speaks Season 2
play-calling"), the same image also drives a Season 2 `control: "play"`
seat — the configuration every seat in the platform's own published
`battle-royale-s2` variant actually uses — through a completely different,
much smaller code path with "no button masks, aim brads, or nav grid of its
own" (`players/baseline/baseline.nim:11-13`). None of the roles, lanes, fire
discipline, or carrier logic below applies to that path; see `## Season 2
play-calling` for what the baseline actually does there.

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

## Season 2 play-calling

This is what the baseline image actually does when the platform seats it
into a `control: "play"` seat — the configuration every seat of the
published `battle-royale-s2` variant uses today. It shares no code, and
almost no concept, with the classic path above: it is a direct, deliberately
small port of `policies/starters/common/starter_harness.py`'s gate-based
"ladder maintenance" logic (`baseline/s2play.nim`), driving a fixed ladder
of four uploaded reference plays rather than its own button masks, aim
brads, or nav grid:

- `edge_ride` is the always-on base — the battle-royale shrinking zone has no
  analogue in the classic path's two-flag navigation stack, so this is a
  genuinely new default, not a translation of anything.
- `target_law` (`prefer: ["weakened", "isolated"]`) is always on, standing in
  for the classic path's hurt/isolated target preference.
- `supply_run` (heal when hurt and a medkit is in reach) and `loot` (grab
  nearby gear when no enemy is close) are gated on the live view, standing
  in for the classic path's medkit- and pickup-detour behaviour.
- `pact`, `bodyguard`, `crossfire` and `jackal` — the reference playbook's
  duo/alliance plays — are **not** uploaded: the classic baseline has no
  negotiated-alliance concept to port, and `battle-royale-s2`'s own
  certification fixture solo-seats every slot, so `context.self.duo_partner`
  is always absent and those plays' gates would never open regardless.

`ReferencePlays` in `baseline/s2play.nim` names the exact four-play subset
uploaded. `policies/starters/` — not this image — is the platform's own
starting point for writing a new play-calling policy from scratch.

## Labels

**The table below is also classic-8v8-only** — a `control: "play"` seat
receives `PlayContext`/`PlayView` messages instead of labelled sprite
objects (see [[policies]]), so none of these labels reach the baseline's
Season 2 code path at all.

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
`control: "input"` seat.

## Version history

| Version | Change |
| --- | --- |
| 2026-09-11 (wiki, re-trace, GV63 / GLORYVERSION 18) | This page previously presented the classic 8v8 roles/lanes/combat description as simply what the baseline "actually does," with no note that this ruleset is deprecated (since build 0.7.253, `allowDeprecatedModes: true` required) or that the same image now also drives a completely different Season 2 `control: "play"` seat via `baseline/s2play.nim` (added by commit `bccf812c` / #527) — the configuration every seat of the live `battle-royale-s2` ladder actually uses. Added a `## Season 2 play-calling` section and scoped the rest of this page explicitly to the classic path. Also noted the baseline's `Dockerfile` now compiles and ships a reference-play playbook alongside the binary, not just the binary. |

## Gaps

- The exact tuning constants behind lane widths, cover-cell cost, and the
  endgame push timers beyond the ones named above.
- Whether the `shoutCoord` build is used anywhere the baseline is actually
  deployed, or exists only as an optional flag in the baseline policy's own
  published source.
- Whether `baseline/s2play.nim`'s gated ladder ever beats, or even matches,
  the classic path's tactics on any measured metric — not evaluated here;
  this page only confirms what it uploads and calls, not how well it plays.

## See also

- [[policies]] — what a policy is, of which this is one example; also
  documents the `control` field that decides which of this page's two paths
  a given seat actually runs
- [[submitting-a-policy]] — the packaging pattern this policy's own `Dockerfile` follows
- [[perception]] — the fog and label rules this policy reads on a classic
  `control: "input"` seat
- [[modes]] — which named variants require `allowDeprecatedModes: true` to
  boot the classic path this page mostly documents
- [[shouts]] — the channel `shoutCoord` rides on
- [[conventions]] — why documenting this policy's behaviour is a fact, not advice

## Discussion

Advice about improving on the baseline, tier-list comparisons against it, or
your own measurements of how it performs belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
