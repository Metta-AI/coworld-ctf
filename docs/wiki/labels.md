*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

**This page documents a `control: "input"` seat's label vocabulary — see the
scope note below.** A label is the string every sprite object carries on that
seat's wire, and it is the entire observation schema such a seat has: its
control surface gives a policy no other API into the simulation, so a policy
finds objects by label and steers off their positions. The engine delivers a fresh set of
labelled objects **once per tick**, over two genuinely different streams — a
policy's own point-of-view (**POV**) observation, and the **broadcast board**
a spectator or replay watches — and the same tick of game state renders a
different vocabulary onto each. Most labels are exact strings; some are
prefixes whose tail interpolates a colour, a side, a name, a count, or free
text. The objective is the clearest case of a layer mismatch: its fiction
name is *heart*, but nothing in the table below is spelled that way — every
row is the wire name, `flag` included.

## Rules

### Scope: this vocabulary belongs to `control: "input"` seats

Every label below is emitted on a `/player`, `/global` or `/replay` binary
stream (see [[wire]]), which is what a seat speaks when its game config
marks it `control: "input"`. A seat marked `control: "play"` instead
exchanges a structured `PlayView` message with named JSON-ish fields
(`hp`, `seat`, `team`, `fresh_tick`, …, `src/shell/view.nim`) — it carries
none of the strings this page documents, because it carries no sprite
objects at all. **Every seat in the platform's own published
`battle-royale-s2` variant — today's only live ladder, see [[modes]] — is
configured `control: "play"`** (`coworld_manifest_paintbot.json`'s
`battle-royale-s2` entry, all 16 `game_config.slots`), so a policy built
against this page's label vocabulary is not reading what that ladder's own
seats actually send. This page's vocabulary remains accurate for a human
seat that has taken over a cog's controls, and for any seat explicitly
configured `control: "input"` — today, a deprecated classic-mode game (see
[[modes]]).

### Matching: exact string vs prefix

A label is matched one of two ways, and a consumer has to know which before
it scans:

- **Flat labels are compared with `==`.** `med kit`, `grenade`, `fire icon`
  and the rest of the fixed-vocabulary labels are whole strings; nothing
  about them varies from tick to tick.
- **Prefix families are matched with `startsWith`**, because the tail
  interpolates a colour, a side token, a Greek slot name, a count, or free
  text that changes constantly. `player red right`, `identity blue gamma
  shield gun`, and `hp 2/3` are all instances of a prefix family, not full
  strings to copy verbatim into a scan.

Scan a prefix family by its stable head, never by one observed full value —
an identity badge's tail changes the moment its wearer picks something up,
and a side token flips the moment a player turns.

### Contract labels vs chrome

Not every label the renderer emits is part of this contract. The vocabulary
documented here is enforced by the engine's own tests, and a rename of any of
it is a breaking change to every policy in the league. The renderer also
emits a much larger vocabulary with no such promise: map bands, the replay
scrubber and its transport controls, roster and score pips, hit flashes,
muzzle blooms, tracer stages, splatters, damage pops, endzone glow, and the
cog rig's individual limbs (its arms, legs and wheels, as opposed to the head
segment in the table below). None of those are contract labels — they exist
for the broadcast view and for the renderer's own sprite bookkeeping, the
broadcast is free to re-cut them at any time, and no policy should scan for
them.

### POV and board are not the same observation

Every labelled object belongs to one of two streams, built from the **same**
tick of game state but carrying **different** vocabularies:

- **POV** — a policy's own point-of-view observation, fogged by its vision
  cone and bubble. See [[perception]] for the fog rules themselves.
- **Board** — the broadcast/spectator/replay stream, unfogged.

A label that exists on one stream can be entirely absent from the other, in
both directions: some labels exist only because a spectator is watching from
outside the fog of war, and others exist only because a POV has a cockpit HUD
a wide broadcast shot does not need.

**The board-only labels never reach a policy at all — a POV never carries
them, at any fog state:**

- `<color> flag carried`
- `cog gun <color>` / `cog spray can <color>`
- `supply halo`
- `selected player <color> <side>`
- `player <color>` (the cog rig's head-segment art — do not confuse with
  `player <color> <side>`, which is Both)

**`<color> flag` and `<color> flag carried` are near-mirror images.** The
bare `<color> flag` is **POV-only** — the broadcast never emits it, and
sends `<color> flag carried` in its place whenever a carrier holds the
objective. `<color> flag carried` is **board-only** — the literal word
`carried` never reaches a POV. Someone developing a policy against a
recorded broadcast stream sees `flag carried` and never sees the bare
`<color> flag`; a policy reading the real player wire sees the reverse.
Distinguish carried from planted in a POV by the presence or absence of
`<color> flag planted` instead, which both streams carry.

**`<color> flag carrier glow` sits next to that split without joining it.**
It is a **different** object present on both streams, but the two streams
gate it differently: a POV's copy is gated by the carrier's real
vision-cone-and-bubble fog, so it appears only once the carrier is actually
visible to you; the board's copy carries no fog at all and appears whenever
a carrier exists, visible or not.

**The mirror case exists too.** `throw target` — the charging-throw landing
ring — is POV-only: the broadcast deliberately suppresses it (drawn as a
sweeping arc on a wide shot, it read as the grenade spinning around) and
shows the lob with the airborne orb and the landing splat instead. Anyone
developing a policy against a recorded broadcast stream, rather than the real
player wire, will never see this label and may not notice its absence.

## Labels

| Label | Stream | Meaning |
| --- | --- | --- |
| `<color> flag` | POV | The objective itself, including while it is being carried — the same label whether it is moving or not. Never sent to the board; see the callout above. |
| `<color> flag planted` | Both | The objective on its home pedestal. Your own pedestal is never fogged, so its absence on your own side is how you learn it has been stolen. |
| `<color> flag carried` | Board | The carried-objective banner art. A distinct sprite from the bare `<color> flag` above; never sent to a POV. |
| `<color> flag carrier glow` | Both | Halo under a visible carrier. Gated by real fog on POV, by carrier presence alone (no fog) on the board — see the callout above. |
| `player <color> <side>` | Both | A living player. |
| `self <color> <side>` | POV | Your own avatar, drawn only while alive — its absence is how a policy learns it is dead. |
| `corpse <color> <side>` | Both | A body. A separate prefix from `player` on purpose, so a scanner never counts a body as a live threat. |
| `selected player <color> <side>` | Board | The spectator-highlighted variant of a living player. |
| `player <color>` | Board | The cog rig's head-segment art — a different object from the row above. |
| `identity <color> <name>[ shield][ nade] <weapon>` | Both | Per-player badge: name, loadout flags, weapon. |
| `hp <n>/3` | Both | Overhead health bar. The `3` is a fixed bar-segment count, not the hit-point setting — `<n>` is the lit-segment count, not a hit-point count. |
| `veteran mark <n>` | Both | Rank plume. The label itself is sent from rank 1; its star artwork renders only from rank 3 — see the callout below. See [[ranks]]. |
| `lives <n>hp x<n>` | POV | Own HUD readout of remaining hit points and lives. Reads past the base hit-point cap, so a shield carrier's hp reads higher than normal. |
| `weapon gun` / `weapon spray` | POV | Own weapon readout; authoritative for your own hands. |
| `fire icon` | POV | Trigger is ready. |
| `fire icon cooldown` | POV | Gun is recovering. The ready test is "does a `fire icon` object exist," not a timer. |
| `med kit` | Both | Centre-line health pickup. See [[med-kit]]. |
| `shield` | Both | Endzone armour pickup on the floor. See [[shield]]. |
| `shield carried` | Both | Marker over a visible shield carrier. |
| `spray can` | Both | Side-column weapon pickup. See [[spray-can]]. |
| `spray can carried` | Both | Marker over a visible spray-can carrier. |
| `spray paint puff` | Both | One mist puff of a firing spray cone; a burst emits a run of them. |
| `grenade`, `grenade air`, `grenade carried` | Both | Paint bomb pickup, in-flight orb, and carrier marker. See [[paint-bomb]]. |
| `grenade sound` | POV | A landing you could not see; audio-only intel with no board equivalent. |
| `throw target` | POV | Charging throw's projected landing ring — see the callout above. |
| `blast stage <n>` | Both | Paint bomb landing splat, by animation stage. |
| `shot impact` | POV | Jittered ring near a shot's landing; the only trace a shot leaves in a POV, since firing itself is silent. |
| `<color> shout <player>: <text>` | Both | A speech bubble. A POV hears a shout only within range; the board shows every shout regardless of distance. See [[shouts]]. |
| `kill_feed` | POV | One entry per elimination: the tick, the eliminating team's identity, and the eliminated player's seat identity. Never the eliminating player's own seat, the eliminated player's team, or a location. |
| `supply halo` | Board | Ring under veteran-dropped supply kit. The kit itself still carries its ordinary pickup label on both streams. |
| `cog gun <color>` | Board | The held-gun rig art. |
| `cog spray can <color>` | Board | The held-spray-can rig art, which replaces the row above while one is carried. |
| `walkability map` | Both | Invisible navigation mask: an RGBA sprite whose alpha channel is the walkable bit per map pixel, always unscaled 1× regardless of render scale. |

**`player <color>` is not a shorter form of `player <color> <side>`.** It is a
separate object: the broadcast rig's head-segment sprite in the board's
articulated cog art, carrying no side token at all. Match the full prefix —
a scan for the bare word `player` pulls this board-only row into a count that
should only ever hold living players.

**An identity badge's tail has a fixed field order.** `<name>` is a Greek slot
letter, `alpha` through `theta`. Any loadout flags the player is carrying
come next, always in the same order. The weapon token is always last and
always present, so it is the one piece a consumer can rely on finding at a
fixed distance from the end of the string regardless of which flags are set.

**A carried-item marker is gated on seeing the carrier, not on the pickup's
own fog check.** `shield carried`, `spray can carried` and `grenade carried`
all appear once you can see the *player* holding the item — the same
visibility test that gates `player <color> <side>` itself, including the
exception that you always see your own marker. That is a different check
from the one that fogs the floor-pickup label, which tests visibility of the
*spot* the item sits at rather than of a person. The two usually agree, but a
policy that only tracks the floor-pickup label will not learn a carrier has
come into view from some other angle than the pickup's old spawn point.

**`kill_feed` rides a policy's own POV observation stream — it is not part
of what the broadcast/spectator/replay board sees.** Each entry carries
exactly three fields: the tick the elimination happened, the eliminating
team's identity, and the eliminated player's seat identity. It explicitly
does not carry the eliminating player's own seat, the eliminated player's
team, or a location. This is a different, older, and unrelated mechanism
from the on-screen kill feed a spectator or replay viewer sees on the
broadcast — the two do not share an implementation and one existing tells
you nothing about the other.

**`veteran mark <n>` is a mechanic/chrome split, not a single rank-3 gate.**
The mechanic — the label itself, which is what a policy actually receives —
is emitted from rank 1 onward. The chrome — the star artwork drawn for it —
only starts rendering at rank 3; at ranks 1 and 2 the same label renders as a
plain pip instead. A policy inferring "this enemy is Ace" from the mark's mere
presence is wrong at ranks 1 and 2; it has to read `<n>` itself, not just test
whether the label exists. See [[ranks]].

## Version history

| Version | Change |
| --- | --- |
| 2026-09-11 (wiki, re-trace, GV63 / GLORYVERSION 18) | Added a scope note: this page's label vocabulary belongs to a `control: "input"` seat. A `control: "play"` seat instead exchanges a structured `PlayView` message (`src/shell/view.nim`) with no sprite labels at all, and every seat in the platform's own published `battle-royale-s2` variant is configured that way today. This page previously called label-based perception "the entire observation schema a policy has today" with no such scoping. |
| Unrecorded | Documented `kill_feed`, a POV-only elimination entry (tick, eliminating team, eliminated seat) that predates this documentation pass and is unrelated to the broadcast's own on-screen kill feed. |
| Unrecorded | A later renderer restore reverted the objective's wire labels to `flag`, undoing 0.7.0's rename to `heart`. The fiction has called it a heart throughout; only the wire label moved. |
| 0.7.5 | Chat packets, previously ignored, began rendering as the shout label `<color> shout <player>: <text>`. |
| 0.7.x | The plasma-arc weapon's five label surfaces (pickup, carrier marker, cone FX, own-HUD/badge weapon token, held-weapon rig art) were renamed to "spray can." No GameVersion bump accompanied it. |
| 0.7.0 | The objective's wire labels were renamed from `flag` to `heart`, matching an object rename (reverted — see the first row). |
| GV3 | The floating `aim dot <color>` indicator was retired; the function that drew it became a no-op and nothing replaced it on the wire. |

## Gaps

- Which engine version performed the renderer restore that reverted the
  objective's labels from `heart` back to `flag`.
- The exact list of cosmetic-only labels the broadcast emits (cog limb
  segments, hit flashes, tracer stages, and the rest) is deliberately not
  enumerated above, since none of it carries a stability promise — but no
  page currently names them either, for anyone trying to filter a board
  recording down to contract objects only.
- Which GameVersion introduced `kill_feed` — confirmed to already exist in
  the shipped engine, not dated here.
- Whether `kill_feed` is delivered as an ordinary sprite/label object or by
  some other mechanism on the `/player` stream — see [[wire]] for the
  byte-level protocol this page's labels ride on.
- The exact `PlayView` schema a `control: "play"` seat receives in place of
  these labels — confirmed to exist and to be what the live
  `battle-royale-s2` ladder uses for every seat, not documented field-by-field
  here.

## See also

- [[perception]] — the fog-of-war mechanics behind POV gating, and the rules
  this page's table distils into a single reference
- [[main]] — the portal, and the objective's two-layer name in overview
- [[baseline-policy]] — which of these labels the canonical policy scans on
  a classic `control: "input"` seat, and by which match rule
- [[conventions]] — the mechanic-and-chrome layering rule this page applies
- [[combat]] — the shot and windup mechanics behind `shot impact` and
  `fire icon`
- [[wire]] — the byte-level protocol these labels ride on, and its own
  `control: "play"` scope note
- [[modes]] — which named variants boot `control: "input"` seats today

## Discussion

Which labels a policy *should* bother scanning for, and any vocabulary
pattern you worked out yourself from watching matches, belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
