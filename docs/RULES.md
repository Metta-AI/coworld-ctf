# Coworld CTF — Game Rules

Coworld CTF is a two-team capture-the-heart shooter for the Coworld platform. Two
teams start on opposite edges of a symmetric arena, each with its own heart on a
home pedestal. Players move, take cover behind obstacles, and shoot. Steal the
enemy heart and carry it home — or eliminate the enemy team — to win. Vision is
fog-of-war: the map is always visible, but enemies only appear inside your
forward vision cone or your small omnidirectional bubble.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift): it keeps
Crewrift's continuous 2D movement, line-of-sight, sprite protocol, server, and
replay infrastructure, and replaces the social-deduction game layer (roles,
tasks, voting) with teams, guns, hearts, and fog-of-war vision.

---

## Overview

- **16 players, 8 vs 8.** Red team spawns along the **left edge**, Blue along the
  **right edge**.
- **Two team hearts**, one on each team's **home pedestal** inside its spawn
  pocket (classic two-object CTF, with hearts for flags).
- The arena is filled with **staggered cover** (a slalom of offset wall
  stubs, diamonds, discs, and diagonal chevron walls, mirrored symmetrically so
  neither team has a positional advantage): **no straight shot crosses the
  field**, so every approach is a series of corners. GameVersion 16 thinned
  the disc column to every other disc, opening real gaps in the mid-field
  slalom.
- In the outermost stub column of each half, the **second wall stub from the
  top and from the bottom are glass windows** (GameVersion 15): they block
  movement, bullets, and plasma arcs exactly like stone, but **vision passes
  straight through them**. Glass draws as a pale pane with diagonal sheen —
  cover you can be seen behind is not cover.
- The old midline chevron zigzag is now a **square-bracket wall pair framing
  the flag ring** (`[ … ]`, GameVersion 16), and the middle of each bracket's
  bar — dead on the center row — is a **glass window**: the mid lane stays
  closed to movement and fire, but both teams can watch the center corridor
  through the glass.
- A round ends when a team **captures the enemy heart** or is **wiped out**.

## Teams & spawns

- Players are assigned to **Red** or **Blue** by slot (8 each).
- A slot may configure a cosmetic **skin** (`slots[i].skin` in the game
  config; currently `default` or `crown`) that restyles that player's body
  art. Skins are cosmetic only: no gameplay effect, and the player, corpse,
  and selected-player observation labels are unchanged, so policies cannot
  (and need not) distinguish them.
- Each team's players get a fixed **identity**, `alpha` through `theta`, by
  slot order within the team — deterministic across matches and replays. A
  small Greek-letter badge (Α Β Γ Δ Ε Ζ Η Θ) rides each living player's
  sprite, and the badge object is labeled `identity <color> <name>` (e.g.
  `identity red alpha`). Badges are fog-gated with their player: seeing a
  player means seeing who it is. Existing `player <color> <side>` labels are
  unchanged.
- Each team has a **home edge**: Red = left, Blue = right.
- Players spawn just inside their home edge and respawn there when killed.

## Movement

- Movement is **continuous** (acceleration, friction, max speed, wall-sliding) —
  the d-pad drives it.
- Movement is **pure locomotion**: it never changes where you aim or look.
- Player bodies are **solid**: you cannot drive over or through another live
  player (friend or foe). Contact is a **slightly elastic collision** — equal
  masses, `playerBouncePct` restitution (default 40%): ramming a standing
  player shoves them forward and keeps a little of your speed; a head-on
  meeting bounces both back at 40% of the closing speed. Glancing contact
  slides around the body the same way wall-sliding works. Corpses never block.

## Aim

- Every player has a **continuous aim angle**, measured in **brads** (256 units
  per full turn, integer — deterministic): **0 = east (+x)**, increasing
  **counter-clockwise on screen** in map coordinates (64 = north, 128 = west,
  192 = south).
- The aim is **decoupled from movement**. Hold **B** to rotate the aim
  **counter-clockwise**, hold **Select** to rotate **clockwise**, at
  `aimTurnRate` brads per tick (default 5 ≈ 7°/tick; a full turn takes ~2.1s).
  Holding both rotate buttons cancels out. The d-pad **never** touches the aim.
- The aim drives everything directional: the **gun** fires along it, the
  **vision cone** centers on it, and the sprite flip follows it (you face left
  while aiming left-ish).
- On spawn and respawn your aim points **toward the enemy side** (Red → east,
  Blue → west).
- A player's **facing** is shown by the soldier sprite itself: the held gun
  sweeps to the aim angle (the sprite reports a coarse `right`/`left` side in
  its label), and — for anyone you can see — the direction they can shoot is
  exactly the lane their body faces. There is no longer a separate floating
  aim-dot indicator; the vision cone and the swept gun convey aim.

## Vision (fog of war)

Every player observes the **full map** — the terrain is static knowledge and is
always drawn — but moving entities are fogged:

- Your **vision** is a **forward cone** of half-angle `visionConeDeg` (default
  ±60°) around your **aim angle**, with **unlimited range**, plus a small
  **omnidirectional bubble** of `visionBubble` (default ~90px) around you.
- **Stone walls block vision** — the same walls that block bullets — with one
  exception: **glass windows** (the second stub from the top and bottom of
  each half's outer stub column) block bullets but NOT vision. A long open
  lane is visible (and lethal) end to end; anything behind stone is not;
  anything behind glass is **seen but safe from direct fire**.
- **Your aim carries your vision.** You look where you aim, not where you walk,
  so watching a lane, sweeping an arc, and turning your back are deliberate
  rotation choices - and moving somewhere no longer reveals it.
- Everything outside your vision is **masked**: enemies, an enemy carrying a
  heart, and death splatters from unseen events are simply not in your
  observation. The unseen area is dimmed by a fog overlay.
- **Bullets are invisible to players.** Shot tracers and muzzle flashes are
  spectator/replay rendering only — no player observation ever contains
  them, whether the shot crossed your vision or not. Players learn of
  gunfire only by sound (below).
- **Always visible regardless of fog:** the static map, **both heart pedestals**,
  your **own heart's state** (its pedestal heart is never hidden — an empty own
  pedestal means your heart is stolen), and **yourself** via a distinct self
  marker. **Teammates are fogged like everyone else** — there is no team
  radio; keeping track of your own side takes eyes too.
- **Only a shot's landing is audible — and sound is all a player gets.**
  Every shot leaves every living player one brief hollow **impact ring**
  (label `shot impact`) near where it landed, for ~0.5s, regardless of line
  of sight. **Firing itself is silent**: the muzzle emits no signal, so
  pulling the trigger never reveals the shooter's neighborhood — only where
  the paint lands. The ring is randomly (but deterministically, per shot)
  offset by up to ~20px, so it tells you something was hit *roughly there*
  — never the exact spot, the shot's line, or which team.
- There is **no global heart tracking**: once a thief carries your heart into the
  fog, finding it again takes eyes on it.
- Death does not lift the fog: a dead player sees the whole map fogged —
  only the terrain, the pedestal hearts, and their own corpse — until they
  respawn (their inputs are ignored).

## Combat

- **Every player has `hitPoints` (default 3) per life.** Each bullet that hits
  removes one hit point; at zero you die. Hit points reset to full on every
  respawn. Your own remaining HP shows on your HUD next to your lives.
- Press **A** to fire. Firing has a short **cooldown** between shots (it is not a
  continuous beam).
- Pressing fire starts a short **windup** (~0.2s): your aim locks the moment
  you pull the trigger, and the bullet leaves at the end of the windup. A
  target that peeks out and ducks back behind cover before the release
  survives the shot.
- The bullet is **hitscan along your aim ray**: it travels down the locked
  aim direction and hits the **first player whose footprint crosses its
  narrow corridor** — it never passes through a body to hit someone behind,
  and **walls stop it**. Range is effectively map-wide, so cover and angles
  matter more than distance.
- **Cover is partial, not binary.** A target's body is sampled across its
  silhouette: only the part of the body that is both inside the bullet
  corridor AND visible from the shooter can be hit. A corner-hugger showing
  a sliver is exactly as hittable as that sliver — no more (fully hidden
  body parts cannot be tagged through the wall), and no less (the poking
  shoulder is fair game even when the body's center is safely covered).
  More exposure means more aim angles connect.
- **Friendly fire is ON.** A shot hits the first valid target regardless of team,
  so firing into a cluster of teammates can kill your own escort.
- **Same-tick shots resolve simultaneously.** Every trigger pulled on the same
  tick picks its target against the same snapshot before any kill applies: a
  mutual face-off duel kills both shooters, and neither team gains an
  input-processing-order advantage.

### Shot micro (frame data)

The full life of one shot, at 24 ticks/second:

1. **Trigger pull (tick 0).** Fire is edge-triggered: a shot arms on the
   tick the button goes down — holding it does nothing, and a second pull
   during a pending windup is ignored. The pull is refused entirely while
   the cooldown is still running.
2. **Windup (5 ticks, ~0.2s).** Your **aim angle locks at the pull**;
   turning during the windup does not bend the pending shot (it only
   re-aims the next one). Your **position stays live**: movement is
   full-speed and unrestricted during the windup.
3. **Release (tick 5).** The bullet resolves instantly (hitscan) **from
   your position at release, along the angle locked at the pull**. All
   movement for the tick happens first; every shot releasing that tick then
   resolves at once against the post-movement snapshot.
4. **Cooldown (12 ticks, ~0.5s; 3x that for a shield carrier).** The
   cooldown starts at release, so the sustained rate is one shot per
   cooldown — the windup does not slow your cadence.

What that means in practice:

- **Strafe-firing works.** The shot line translates with your movement
  (new position, old angle), so lead your own strafe when you pull.
- **Fire-and-duck can waste your own shot.** Line of sight is checked from
  your release position: step behind a wall during your windup and the
  wall eats your bullet.
- **Targets can dodge the windup.** Anyone who breaks line of sight during
  your ~0.2s windup survives; the aim lock is the price of the shot.
- **The corridor is forgiving.** The bullet is a ray with an 8px half-width
  corridor sampled against the target's ~12px-wide silhouette — near-misses
  connect; precision beyond the corridor width buys nothing.
- **Respawners are live immediately.** There is no spawn protection: a
  freshly respawned player can shoot and be shot (and blocks bullets) from
  their first tick.

## Grenades

- **Four grenade pickups spawn in the arena corners** — two on each team's
  side — a fixed inset inside the border walls. Anyone may take either
  side's pickups by **touch**; a taken corner **refills 5 seconds later**.
- **Each player carries at most one grenade.** Dying loses the carried
  grenade (nothing drops).
- **Throwing:** hold the **C button** (input mask bit 128) to charge, release
  to throw along your **current aim**. The charge picks the distance, from a
  short tap (~30 px — inside the blast radius, so a panicked drop can hurt
  you) up to a full-charge **maximum of one fifth of the field width**
  (~247 px) after ~1s of holding. While you charge, a **throw target ring**
  marks the landing spot on your own view (and is readable intel for anyone
  who can see you, like your aim line).
- **Grenades fly over every obstacle** in a straight lob from thrower to
  target and **explode on landing**. The burst comes a **fixed two shot
  windups (~0.4s) after release, near or far** — long throws just travel
  faster. A grenade is a snap weapon: the reaction window is the same as
  eating two aimed shots, not a mortar shell you can stroll away from.
- **The blast hurts everyone inside its radius (~52 px): enemies, teammates,
  and the thrower alike**, removing 2 hit points each. The landing splat and
  the charge-time throw-target ring are drawn at the TRUE blast diameter —
  what looks painted is exactly what got hit, and everything inside the ring
  will be. Kills credit the thrower (except suicides).
- **Throwing is silent; landing is loud.** A landing you could not see
  leaves a large jittered sound ring (label `grenade sound`) — landing-only
  audio, exactly like gunshot impact rings. The throw itself leaves nothing.
- Observation labels: pickups `grenade`, airborne `grenade air`, the marker
  above a carrier `grenade carried`, the charge marker `throw target`, the
  landing flash `blast stage N`.

## Plasma arc

- **Two plasma arc pickups spawn high in the side back columns** — one on
  each side, in the TOP half (a quarter of the map height down, between the
  top corner grenade and the side midpoint), nudged to the nearest walkable
  floor. The shields hold the matching bottom-half spots. Both plasma arcs
  are present when the game starts, and a taken one respawns after
  **30 seconds**.
- **Each player carries at most one plasma arc**, independently of their
  grenade. Dying loses the carried arc; nothing drops.
- While carrying a plasma arc, **A ignites a forward plasma cone instead of
  firing the gun**. The cone reaches **4 squares** in front of the player
  (136 px — one square is one 34 px cog body) and widens linearly to
  **2 squares (68 px) at max reach**, a constant half-angle of
  atan(1/4) ≈ 14°. The gun is disabled while the arc is held; C still
  throws a carried grenade normally.
- **The cone stays on for 5 ticks**, tracking the attacker's position and
  aim across the window, then the weapon takes **20 ticks to reset**
  (one firing every 25 ticks). The cone shuts off if its owner dies.
- **A touch removes 3 hit points, once per victim per firing** — instantly
  lethal to a bare 3 hp cog, while a 6 hp shield carrier survives the first
  touch with 3 hp left. The cone affects teammates too and requires line
  of sight. Kills credit the attacker.
- Observation labels: pickup `plasma arc`, carrier marker
  `plasma arc carried`, and the fading cone `plasma arc pulse` (a run of
  team-colored pulse discs along the attacker's aim each active tick).

## Shouts

- **Any living player can shout: a short text message, at most 10
  characters** (longer messages are truncated; non-printable characters are
  dropped). Send it as a chat packet (`0x81`, the standard sprite-protocol
  chat message); in the browser client press **Enter**, type, and press
  Enter again.
- **Anyone within one fifth of the field width (~247 px) hears it** —
  through walls and fog, like gunfire. Outside that radius the shout does
  not appear in your frame at all.
- A heard shout appears as a speech bubble labeled
  `<team> shout <player>: <text>` pinned at **deterministically jittered
  coordinates** (~±20 px, like gunshot impact rings): you learn roughly where
  the shouter is, never exactly.
- **Rate limit: one shout per second per player**, and each player has at
  most one live bubble (a new shout replaces the old). Bubbles fade after
  **3 seconds**. Dead players cannot shout and hear nothing.
- The global/replay view draws every bubble at the shouter's actual
  position, following them while they live.

## Med kits

- **Two med kits sit on the center line** — at one third and two thirds of
  the field height, nudged to the nearest walkable floor.
- **Touching one while hurt restores your hit points back to full.** A
  healthy player walks over it untouched — a kit is never wasted.
- **A taken kit respawns 30 seconds later** in the same spot.
- Observation label: `med kit`. Kits are fog-gated like the grenade
  pickups: you see one only where you have vision.
- **Med kits never block anything** — not movement, not bullets, not
  line of sight. They are floor pickups, not cover.

## Shields

- **One shield sits deep in each team's endzone**, in the same back column
  as the corner grenade pickups but in the BOTTOM half (three quarters of
  the map height down, between the side midpoint and the bottom corner
  grenade), nudged to the nearest walkable floor. The plasma arcs hold the
  matching top-half spots.
- **Touch a shield to pick it up** — either team may take either endzone's
  shield. A shield is a **3 hp armor layer on top of your base hit points**:
  damage depletes the shield layer first, and only then your base hp. A
  pickup refills the layer to 3 but **never heals base damage** (med kits
  do that) — so a worn carrier can take another shield to restore the
  layer, while a carrier whose layer is intact leaves the spawn untouched.
- **While carrying a shield you fire 3x slower.** A fresh player with a
  fresh shield has 6 effective hp (3 base + 3 shield). Each shot you fire
  starts a cooldown three times the normal length until you lose the
  shield. You can still move, carry the heart, and throw grenades.
- **A shield is lost when you die** and is not dropped on the ground; the
  taken endzone shield **respawns 30 seconds later** in the same spot.
- Observation label: `shield`. Shields are fog-gated like the med kits and
  grenade pickups: you see one only where you have vision, and a small
  marker floats over a shield carrier you can see.

## Lives & respawn

- Each player has a fixed number of **lives**.
- When you die, you **respawn at your home edge** after a short delay — as long as
  you have lives remaining.
- When you run out of lives, you are **out for the rest of the round**.

## The hearts

- Each team's heart sits on its **home pedestal** inside the team's spawn pocket.
- **Touch the ENEMY heart to steal it** off its pedestal. Your own heart cannot be
  interacted with by your own team. While carrying you move **slower** but can
  **still shoot**.
- If the carrier is killed (or disconnects), the heart **returns instantly to its
  own pedestal**. A heart is never left loose on the ground: it is either carried
  or sitting on its pedestal.
- Your own heart's **state** is always observable: its pedestal is never fogged,
  so an empty own pedestal means it is stolen — but the **thief itself is fogged**
  like any other enemy.

## Winning

A round ends immediately when either condition is met:

1. **Capture** — carry the **enemy heart** into **your own home capture zone**.
2. **Wipe** — the entire **enemy team is out of lives**.

If neither happens before the **time limit**, the round is a **lose-lose
draw** — there is no tiebreak, and both sides are penalized.

## Scoring

Scoring is **sparse and win-only**:

- **Decisive round** (capture or wipe): every winner scores **+1**, every
  loser scores **-1**.
- **Time-limit draw: -1 for both sides** (GameVersion 21). Running out the
  clock is never better than losing, so stalling has no upside for anyone.
- **Mutual-wipe draw** (both teams eliminated on the same tick): 0 for both
  sides — both at least fought to a decision.

Kills, deaths, heart pickups, carry time, and captures are still **recorded** in
the episode results for leaderboards and analysis — they just do not award
points. This keeps the training objective tied purely to winning.

## Controls

| Button | Action |
| --- | --- |
| D-pad | Move (locomotion only — never changes your aim) |
| A | Fire; while carrying a plasma arc, ignite the plasma cone |
| B | Rotate aim counter-clockwise (browser client: X or K) |
| Select | Rotate aim clockwise (browser client: Space or L) |
| C | Hold to charge a grenade throw, release to throw (browser client: C) |
| Chat packet | Shout, max 10 chars (browser client: Enter to type) |

---

## Tuning defaults (configurable)

These are starting values, exposed in the game config and tuned in self-play.

| Parameter | Proposed default | Notes |
| --- | --- | --- |
| Players | 16 (8v8) | All standard Coworld slots |
| Lives per player | 3 | Out of lives = out for the round |
| Hit points per life (`hitPoints`) | 3 | Shots to kill; reset to full on respawn |
| Respawn delay | ~3s | Time dead before respawning at home |
| Gun range | 1300px | Effectively map-wide; aim precision and line of sight are the real limits |
| Fire windup | ~0.2s | Trigger pull to bullet release; aim locks at the pull |
| Fire cooldown | ~0.5s | Minimum time between shots |
| Carrier speed | ~70% | Movement penalty while holding the heart |
| Body bounce (`playerBouncePct`) | 40% | Restitution of player-player collisions; bodies are always solid |
| Aim turn rate (`aimTurnRate`) | 5 brads/tick | Rotation speed while B/Select is held (~7°/tick; full turn ~2.1s) |
| Vision cone (`visionConeDeg`) | ±60° | Fog-of-war forward vision half-angle; unlimited range, walls block |
| Vision bubble (`visionBubble`) | 90px | Omnidirectional close-range vision regardless of aim |
| Plasma arc reach (`PlasmaArcReach`) | 136px (4 squares) | Forward cone reach; one square = one 34px cog body |
| Plasma arc max width (`PlasmaArcMaxWidth`) | 68px (2 squares) | Cone width at max reach; widens linearly (half-angle atan(1/4) ≈ 14°) |
| Plasma arc damage (`PlasmaArcDamage`) | 3 hp | One touch per victim per firing; lethal to a bare cog, survivable by a shield carrier |
| Plasma arc active window (`PlasmaArcActiveTicks`) | 5 ticks | The fired cone stays on, tracking its owner's position and aim |
| Plasma arc reset (`PlasmaArcResetTicks`) | 20 ticks | Recharge after the cone shuts off (one firing per 25 ticks) |
| Plasma arc respawn | 30s | Taken pickups refill after this interval |
| Plasma pulse lifetime (`PlasmaArcFxTicks`) | 4 ticks | Cosmetic fade of each per-tick cone snapshot |
| Heart auto-return | instant | A heart snaps back to its own pedestal the moment its carrier dies |
| Time limit (`MaxTicks`) | 5000 ticks (~3.5 min) | Round length cap before the lose-lose draw |
| Map size | 1235×659 | Inherited from Crewrift; may change |

Engine tick rate is **24 ticks/sec** (inherited from Crewrift); all
second-based values above convert at that rate.

**Observation render scale (since 0.6.0):** the sprite-protocol wire carries
the zoomable map/fog layers at **3x map resolution** -- object coordinates and
sprite pixel sizes are all multiplied by 3, and every entity sprite is
centered on its scaled map point. To recover exact legacy map coordinates,
compute the object center and divide by 3:
`map_x = (object.x + sprite.width / 2) / 3` (same for y). Everything above
(map size 1235x659, ranges, speeds) stays in map pixels; only the wire
representation scaled. The invisible `walkability map` sprite is unscaled and
still 1235x659. Labels, sprite/object ids, layers, and the input protocol are
unchanged, with one exception: while you are dead your own body is the only
player sprite in frame, labeled `corpse <color> <side>` instead of
`player <color> <side>`, so a policy scanning for `player` labels never
mistakes a body for a live enemy.

**Label changes since 0.7.0:** the capture objects are hearts — their sprites
are labeled `red heart` / `blue heart` (formerly `red flag` / `blue flag`).
Grenades add the labels documented in the Grenades section, and the throw
button is input mask bit 128.

Plasma arcs add the labels documented in the Plasma arc section; their
pickup and carrier markers are fog-gated like other floor and overhead item
markers.

**Since 0.7.5:** shouts (see the Shouts section) add the label
`<team> shout <player>: <text>`; chat packets, previously ignored, are now
applied as shouts and recorded in replays (GameVersion 3 — older replays are
rejected at load).

**Player-sprite labels are stable across the HD art change:** the rotating
high-definition soldier is a pure visual upgrade — living players are still
`player <color> <side>` (yourself `self <color> <side>`, selected
`selected player <color> <side>`, a body `corpse <color> <side>`), where
`<side>` is the coarse `right`/`left` the aim falls into. The floating
`aim dot <color>` indicator has been **retired**; facing is read from the
sprite's swept gun and the vision cone, so a label-scanning policy sees the
same vocabulary it always has.

**Identity badges:** every living player carries a separate badge object
labeled `identity <color> <name>` (`alpha`..`theta` — see Teams & spawns).
Like the `hp <n>/3` bar, the badge is a distinct object centered on its
player's body: attach it by proximity. It is fog-gated with its player and disappears on
death.

---

## Implementation notes

This section is a build plan, not player-facing rules.

**Reused from Crewrift (the engine, ~60–70% of the code):**

- Continuous movement, fixed-point sub-pixel carry, wall-sliding collision
  against a per-pixel `walkMask`.
- Line-of-sight against a per-pixel `wallMask`. The old per-player 128×128
  camera is gone: each player now gets the **full map** with a per-viewer
  **fog-of-war** (recursive shadowcasting on an 8px visibility cell grid,
  intersected with the vision cone and bubble) that culls fogged entities from
  the observation and dims the unseen area with a fog overlay layer.
- The **Sprite v1** protocol (button-mask input + sprite/object observations),
  websocket server (`/player`, `/global`, `/replay`, `/reward`), replay
  recording/playback, JSON config loading, and reward streaming.

**Rewritten (the game layer, replacing social deduction):**

- `sim.nim`: replace `Crewmate`/`Imposter` roles with `Red`/`Blue` teams; replace
  `tryKill` (proximity grab) with **directional hitscan + LOS along the aim**; add
  **lives/respawn**, **heart pickup/carry/return**, **team win-check**, and a
  **Lobby → Playing → GameOver** phase machine (drop RoleReveal/Voting/VoteResult).
- Player struct: keep `x,y,velX,velY,carryX,carryY,alive,color,reward`; drop
  task/vent/vote fields; add `team`, `lives`, `respawnTimer`, `fireCooldown`,
  `aimBrads`, `carryingFlag`.
- `global.nim` observation building: team-colored player sprites, the heart
  sprites, a **carrier indicator**, the per-viewer **fog overlay** and
  fog-culled entity stream (there are deliberately **no heart arrows** — fog of
  war replaced all global tracking intel), a distinct **self marker**, and
  per-player **lives / fire-cooldown UI** on HUD layers.
- New **symmetric arena**: a new `.resources` map (CSS-like rects) plus an Aseprite
  image with walk/wall layers. Red/Blue spawn strips on the left/right edges,
  heart pedestal at center, obstacles mirrored across the vertical axis, home-edge
  capture zones at the leftmost/rightmost columns.
- New team-based `config.json` and `coworld_manifest.json` (slots carry `team`
  instead of `role`; results schema reports team/kills/deaths/captures).
- A **baseline bot** (Crewrift's `notsus` equivalent) speaking Sprite v1.
- A **CTF grader** scoring episodes from wins.

**Open follow-up:**

- Crewrift reuses the **among_them social-deduction commissioner** for seating and
  ranking. CTF is team-based, so it needs a **team commissioner** (fixed Red/Blue
  seating, win/loss ranking) — to be written or adapted.
