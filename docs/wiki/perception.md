*Verified against `paintbot-v0.7.397` (GV63 / GLORYVERSION 18), 2026-09-11 — see `docs/wiki/_era.md`.*

**This page documents a `control: "input"` seat's observation — see the
scope note below.** Perception on such a seat is a fogged view
of the arena delivered once per tick as **sprite objects matched by label
string**: that seat's control surface gives a policy no other API into the
simulation — it finds things by their labels and steers off their positions.
The terrain is always fully visible, but every moving thing is fogged: you see
**only yourself** for free, and **teammates are fogged exactly like enemies —
there is no team radio**. Your vision is a ±60° cone around your **aim** plus
a 90 px bubble, so where you look is a deliberate choice, not a side effect of
where you walk.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Vision cone half-angle | ±60° | — | Centred on aim angle, **unlimited range** |
| Vision bubble | 90 px | — | Omnidirectional, regardless of aim |
| Aim turn rate | 5 brads/tick | — | 256 brads = full turn; ≈7°/tick, ≈2.1 s per turn |

## Rules

### Scope: this is a `control: "input"` seat's perception

Everything below describes what a `control: "input"` seat's `/player`
connection observes — the wire [[wire]] documents (Sprite/Object messages,
resolved to labels via [[labels]]). A seat configured `control: "play"`
instead perceives through a structured `PlayView` message — named JSON-ish
fields such as `hp`, `hp_frac`, `aim_brads`, `seat`, `team` and `fresh_tick`
(`src/shell/view.nim`), not sprite objects matched by label string at all.
**Every seat in the platform's own published `battle-royale-s2` variant —
today's only live ladder, see [[modes]] — is configured `control: "play"`**
(`coworld_manifest_paintbot.json`'s `battle-royale-s2` entry, all 16
`game_config.slots`), so the fog-and-label perception this page documents is
not what a policy submitted to that ladder actually receives. It remains
accurate for a human seat that has taken over a cog's controls, and for any
seat explicitly configured `control: "input"` — today, a deprecated
classic-mode game (see [[modes]]).

### Vision

The vision cone, vision bubble and aim turn rate are in `## Stats` above.

**The full terrain is always visible.** The map is static knowledge and is always
drawn. Fog applies to moving entities and to event markers, not to walls.

**Your aim carries your vision.** You look where you aim, not where you walk. The
d-pad is locomotion only and never rotates the aim; rotation is a deliberate B or
Select input. Moving into a room does not reveal it. This is the mechanic that
makes sweeping, watching a lane, and turning your back into distinct acts rather
than by-products of movement — see [[combat]].

**Walls block vision, with one exception.** The same stone that stops bullets
stops sight. Glass windows in the [[arena]] block movement, bullets and spray
cones but **not** vision — cover you can be seen behind is not cover. On the
default arena, glass is the second wall stub from the top and from the
bottom of each half's outer column, plus the center bar of the mid-lane
bracket that frames the flag ring — see [[arena]] for the exact footprint.

**Everything outside your vision is simply absent** from your observation, not
dimmed-but-present: fogged enemies, a fogged enemy carrying the objective, and
markers from events you did not see are not in the frame at all.

**Always visible regardless of fog:**

- The static map.
- Both objective pedestals, including **your own objective's state** — an empty
  own pedestal means it has been stolen. The thief is fogged like any other
  enemy.
- Yourself, via a distinct self marker.

**Teammates are not on that list, and this is the one rule on this page worth
being suspicious of.** Almost every other team game trains you to expect a
minimap blip, a health bar, or a silhouette for your own side even through
walls — some baseline level of shared awareness that costs nothing to ask for.
Paintbot has none of it. A teammate is fogged by your vision cone and bubble
exactly as an enemy is, with no exception for color. Keeping track of your own
side takes the same eyes as keeping track of the enemy: there is no team
radio, no shared vision, and no global objective tracking, so once a carrier —
yours or theirs — runs into the fog, finding it again means putting eyes on
it. This has caused real, repeated confusion precisely because it violates the
genre's default; read it twice if this is your first pass through this page.

**Being tagged out does not lift the fog.** A tagged-out player sees the terrain,
the pedestal objectives, and their own corpse — nothing else — until they
respawn. Their inputs are ignored for the whole respawn delay.

### Sound

Sound is the only information that crosses fog and walls, and it is always
**deliberately imprecise**.

| Event | Label | Who hears it | Jitter |
| --- | --- | --- | --- |
| A shot landing | `shot impact` | Every living player | ≈±20 px |
| A paint bomb landing you did not see | `grenade sound` | Every living player | ≈±20 px |
| A shout | `<color> shout <player>: <text>` | Within 247 px | ≈±20 px |

**Firing is silent; landing is loud.** The muzzle emits no signal at all, so
pulling the trigger never reveals the shooter's neighbourhood. Every shot leaves
every living player one brief `shot impact` ring near where it landed, for about
half a second, regardless of line of sight. The ring is offset by up to about
20 px — deterministically per shot, so it is not noise that averages away within
one event. It tells you something was hit *roughly there*, never the exact spot,
never the shot's line, and never which team fired.

**Bullets themselves are invisible to players.** Tracers and muzzle flashes are
broadcast rendering only; no player observation ever contains them.

Shout radius, rate limit and truncation are on [[shouts]].

### Aim is not readable

**Since GV24, every soldier sprite in a player's view renders its gun at a fuzzed
angle** — true aim plus a deterministic pseudo-random offset of up to **±20°**,
held for 12 ticks (0.5 s) before being re-rolled. This applies to enemies,
teammates, corpses and **your own self marker** alike. Watching a cog never
reveals its exact aim.

**Nothing on the wire carries an aim angle.** A policy knows its own aim only by
tracking the turn commands it has issued. The old floating `aim dot <color>`
indicator has been retired — the function that drew it is a literal no-op — so a
policy scanning for it gets an empty answer every tick, forever.

The broadcast board is unaffected by the fuzz and shows true aim. That is a
viewing convenience, not something a policy can reach.

## Labels

A label is not a debug tag: **it is the observation schema**. The vocabulary is
enforced by the engine's own contract test, so a rename is a breaking change to
every policy in the league — but a *stale wiki page* is silent, which is why
every label below is version-stamped and why unknowns are marked as gaps rather
than guessed.

Match rules: flat labels are compared with `==`; prefixes are matched with
`startsWith`, because the tail interpolates a colour, a side, a name, a count or
free text. **Scan prefixes by prefix** — an identity badge's tail changes every
time its wearer picks something up.

### The objective: two correct names, one trap

The objective is a **heart** in the fiction, on the banners and in the broadcast
(`RED HEART STOLEN!`). Its **wire label is `flag`**. Both names are correct at
their own layer, and a policy must be written against `flag`.

| Label | Meaning | Stream |
| --- | --- | --- |
| `<color> flag` | The objective — **including while it is being carried** | **Player view only** |
| `<color> flag planted` | The objective on its home pedestal | Player view and broadcast |
| `<color> flag carried` | The carried objective, cradled by the carrier | **Broadcast board only** |
| `<color> flag carrier glow` | Aura marking who is carrying | Player view and broadcast |

**This is the trap, and it runs in both directions at once.** The bare
`<color> flag` and `<color> flag carried` are near-mirror images. The bare
label is **player-view only** — the broadcast never emits it, and shows
`<color> flag carried` in its place whenever a carrier holds the objective —
while `<color> flag carried` is **broadcast-board only**, since the literal
word `carried` never reaches a player view. Someone developing a policy
against a recorded broadcast stream sees `flag carried` and never sees the
bare `<color> flag`; a policy reading the real player wire sees the reverse.
Distinguishing "carried" from "planted" in a player view is the presence or
absence of `<color> flag planted` instead, which both streams carry.

The carrier's glow halo sits next to that split without joining it: it is a
distinct object present on **both** streams, but the two streams gate it
differently. A player view's copy is gated by the carrier's real
vision-cone-and-bubble fog, so it appears only once the carrier is actually
visible to you; the board's copy carries no fog at all and appears whenever
a carrier exists, visible or not. Only the literal word `carried` is
broadcast-exclusive — the glow object exists on both streams, under
different rules.

A policy written from the broadcast board's vocabulary waits forever for a label
the wire does not send it. Your own pedestal is never fogged, so an absent
`<color> flag planted` on your own side means your objective has been stolen.

### Players and bodies

| Label | Meaning | Stream |
| --- | --- | --- |
| `player <color> <side>` | A **living** player | Player view and broadcast; fog-gated |
| `self <color> <side>` | Your own avatar, drawn **only while alive** | Player view |
| `corpse <color> <side>` | A body — deliberately *not* the player prefix | Player view (own body while tagged out) and broadcast |
| `selected player <color> <side>` | Spectator-highlighted player | **Broadcast board only** |
| `player <color>` | The cog rig's head segment, **no side token** | **Broadcast board only** |
| `identity <color> <name>[ shield][ nade] <weapon>` | Per-player badge, `alpha`…`theta` | Player view and broadcast; fog-gated |
| `hp <n>/3` | Overhead health bar, a separate object | Player view and broadcast; fog-gated |
| `veteran mark <n>` | Rank plume; label sent from rank 1, star artwork only from rank 3 | Player view and broadcast; fog-gated |

`<side>` is a **coarse `right`/`left`** — which half the aim falls into. It is
not an aim angle and cannot be refined into one.

**The absence of `self <color> <side>` is how a policy learns it is dead.**

**`corpse` is a separate prefix from `player` on purpose**, so a scanner never
counts a body as a live threat. While you are tagged out, your own body is the
only player-ish sprite in your frame and it carries the `corpse` prefix.

**The `3` in `hp <n>/3` is a bar segment count, not a hit-point count.** The bar
always draws three segments whatever the hit-point setting is, and the numerator
is the number of *lit* segments. Today the hit-point default is also 3, which
makes the two numbers coincide — do not build a scan denominator from the
hit-point value.

`hp` and `identity` are **distinct objects centred on their player's body**:
attach them by proximity, not by an id relationship.

**`veteran mark <n>` is emitted from rank 1 — its star artwork is chrome that
only starts at rank 3.** Ranks 1 and 2 send the same label with a plain-pip
icon instead of a star; a policy inferring "this enemy is Ace" from the
mark's mere presence is wrong until it also checks `<n>` ≥ 3. What a rank
buys is on [[ranks]].

### Your own state

| Label | Meaning | Stream |
| --- | --- | --- |
| `lives <n>hp x<n>` | Own HUD readout | Player view |
| `weapon gun` / `weapon spray` | Own weapon readout | Player view |
| `fire icon` | Trigger is ready | Player view |
| `fire icon cooldown` | Gun is recovering | Player view |

**`lives <n>hp x<n>` reads past the base hit-point cap.** A [[shield]] carrier
shows `6hp`, which is how a policy detects its own shield without needing to see
a carry marker.

**`weapon <token>` is authoritative for your own hands.** Inferring your own
weapon from floating markers gets it wrong under fog.

**Gate firing on the presence of `fire icon`**, not on a timer. On cooldown the
HUD object switches to `fire icon cooldown`, so the ready test is "at least one
object labelled `fire icon` exists". Frame data for the shot itself is on
[[combat]].

### Items and events

| Label | Meaning | Stream |
| --- | --- | --- |
| `med kit` | Centre-line health pickup | Player view and broadcast; fog-gated |
| `shield` | Endzone armour pickup on the floor | Player view and broadcast; fog-gated |
| `shield carried` | Marker over a shield carrier you can see | Player view and broadcast; fog-gated |
| `spray can` | Side-column weapon pickup | Player view and broadcast; fog-gated |
| `spray can carried` | Marker over a spray-can carrier | Player view and broadcast; fog-gated |
| `spray paint puff` | One mist puff of a firing spray cone | Player view and broadcast |
| `grenade`, `grenade air`, `grenade carried` | Paint bomb pickup, flight, carrier | Player view and broadcast; fog-gated |
| `grenade sound` | A landing you could not see | Player view only |
| `throw target` | Charging throw's landing ring | **Player view only** |
| `blast stage <n>` | Paint bomb landing splat | Player view and broadcast |
| `shot impact` | Jittered ring near where a shot landed | Player view |
| `supply halo` | Ring under veteran-dropped kit | **Broadcast board only** |
| `cog gun <color>` / `cog spray can <color>` | The held weapon in the rig art | **Broadcast board only** |
| `walkability map` | Invisible navigation mask, see below | Player view and broadcast |

Item behaviour behind these labels is on [[paint-bomb]], [[spray-can]],
[[shield]] and [[med-kit]].

**A carried-item marker is gated on seeing the carrier, not on the pickup's
own fog check.** `shield carried`, `spray can carried` and `grenade carried`
appear once the *player* holding the item is visible to you — the same
visibility test that gates `player <color> <side>` — which is a different
check from the one that fogs the floor-pickup label, gated on visibility of
the *spot* the item sits at. The two usually agree, but a policy tracking
only the floor-pickup label will not learn a carrier has come into view from
some other angle than the pickup's old spawn point. Full rule on [[labels]].

**Supply-dropped kit is indistinguishable from ordinary kit in a player view.**
`supply halo` is broadcast garnish; the kit itself carries each type's normal
label. Nothing should ever scan for `supply halo`.

**`walkability map` is a sprite you decode, not one you locate.** It is an RGBA
sprite whose alpha channel is the walkable bit per map pixel. It is **always
unscaled 1×** whatever the render scale, and a policy reads its pixels, never its
position.

### Broadcast chrome

The renderer emits many more labels than the ones above — map bands, the replay
scrubber, roster and score pips, hit flashes, muzzle blooms, tracer stages,
splatters, damage pops, endzone glow, the cog rig's individual limbs. **None of
them are contract labels.** They exist for the broadcast view and for sprite
deduplication, they carry no stability promise, and the broadcast is free to
re-cut them at any time. Do not scan for them.

### Wire coordinates

**A policy does no coordinate conversion.** On the `/player` stream — the one
a submitted policy actually connects to — an object's `x`, `y` and `z` on the
wire already *are* the world coordinate, unscaled: the numbers a policy reads
off the wire are the numbers it should compare against a radius or range
documented elsewhere on this wiki, with no scale, no offset and no
fixed-point arithmetic to undo first. The engine's own sub-pixel fixed-point
accounting is a velocity accumulator, fully resolved into whole map pixels
before a position is ever placed on the wire — a policy never sees a
fraction.

**The spectator and replay streams are not the observation a policy gets, and
the gap between them has the same shape as the flag-label trap on
[[labels]]: POV and board can each show something the other does not, and
building intuition for one from the other gets you wrong answers.** The
`/global` and `/replay` board streams double every object's coordinate and
sprite pixel size for their own zoomable rendering — applied only inside that
board's own layer, after a policy's own stream has already been built from
the unscaled numbers above. `z` is never doubled on either stream. See
[[wire]] for the split by stream.

**Worked example.** The same moment, the same entity, at world position
(300, 150): a policy's own `/player` connection reports it as `x: 300, y:
150` — read the numbers as given, no arithmetic. Watching the identical
moment on `/global` or `/replay` instead reports `x: 600, y: 300` — that
stream's own ×2, which never reaches the policy actually playing the match.

Every distance elsewhere on this wiki is in **map pixels** — a policy's own
numbers, nothing to undo. Labels, sprite and object ids, layers and the input
protocol are unaffected by either stream's scale; the `walkability map`
sprite stays 1× on every stream.

## Version history

| Version | Change |
| --- | --- |
| 2026-09-11 (wiki, re-trace, GV63 / GLORYVERSION 18) | Added a scope note: this page documents a `control: "input"` seat's fog-and-label perception. A `control: "play"` seat instead perceives through a structured `PlayView` message (`src/shell/view.nim`), and every seat in the platform's own published `battle-royale-s2` variant is configured that way today. This page previously stated, unscoped, that label-and-position perception is "everything a policy can observe in Paintbot today." |
| Wiki | This page previously stated a ×3 wire-coordinate scale applying to every stream, including the player stream. Both halves were wrong: the real scale is ×2, and it applies only to the board streams — a policy's own stream has always been unscaled. See [[wire]]. |
| GV24 | Gun rotation in **player views** is fuzzed ±≈20°, both teams, self included. Broadcast board unaffected. |
| GV3 | `aim dot <color>` retired; nothing on the wire carries an aim angle any more |
| GV14 | Board-stream (`/global`/`/replay`) coordinates and sprite sizes doubled relative to the player stream's plain map pixels; no GameVersion bump accompanied the change at the time. |

## Gaps

- The exact `PlayView` schema a `control: "play"` seat receives — confirmed
  to exist, to be JSON-shaped with named fields (`hp`, `aim_brads`, `seat`,
  `team`, `fresh_tick`, …), and to be what the live `battle-royale-s2`
  ladder uses for every seat, but not documented field-by-field here or on
  [[wire]].
- Whether a `PlayView` seat's fog rules (vision cone, bubble, wall-blocking)
  match this page's `control: "input"` numbers exactly, or differ — not
  checked in this pass.

## See also

- [[main]] — the portal, the action mask and the item list
- [[labels]] — the full label vocabulary as one reference table, with the
  POV-versus-board split called out label by label
- [[wire]] — the byte-level protocol, including the coordinate split between
  the player stream and the board streams, and the `control: "play"` scope
  note this page's own note points back to
- [[paint-bomb]] — the labels an item page documents
- [[combat]] — the rotation mechanic that steers vision
- [[baseline-policy]] — which of these labels the canonical policy reads on
  a classic `control: "input"` seat
- [[modes]] — which named variants boot `control: "input"` seats today
- [[conventions]] — the mechanic-and-chrome layering rule

## Discussion

Advice built on these rules — sweep patterns, when to break line of sight, how to
read an impact ring — and any perception measurements of your own belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.
