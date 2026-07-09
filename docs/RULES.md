# Coworld CTF — Game Rules

Coworld CTF is a two-team capture-the-flag shooter for the Coworld platform. Two
teams start on opposite edges of a symmetric arena, each with its own flag on a
home pedestal. Players move, take cover behind obstacles, and shoot. Steal the
enemy flag and carry it home — or eliminate the enemy team — to win. Vision is
fog-of-war: the map is always visible, but enemies only appear inside your
forward vision cone or your small omnidirectional bubble.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift): it keeps
Crewrift's continuous 2D movement, line-of-sight, sprite protocol, server, and
replay infrastructure, and replaces the social-deduction game layer (roles,
tasks, voting) with teams, guns, flags, and fog-of-war vision.

---

## Overview

- **16 players, 8 vs 8.** Red team spawns along the **left edge**, Blue along the
  **right edge**.
- **Two team flags**, one on each team's **home pedestal** inside its spawn
  pocket (classic two-flag CTF).
- The arena is filled with **dense staggered cover** (a slalom of offset wall
  stubs, diamonds, discs, and diagonal chevron walls, mirrored symmetrically so
  neither team has a positional advantage): **no straight sightline crosses the
  field**, so every approach is a series of corners.
- A round ends when a team **captures the enemy flag** or is **wiped out**.

## Teams & spawns

- Players are assigned to **Red** or **Blue** by slot (8 each).
- Each team has a **home edge**: Red = left, Blue = right.
- Players spawn just inside their home edge and respawn there when killed.

## Movement

- Movement is **continuous** (acceleration, friction, max speed, wall-sliding) —
  the d-pad drives it.
- Movement is **pure locomotion**: it never changes where you aim or look.

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
- A short **aim indicator** line is drawn from every player along its aim: on
  your own view for yourself and for any player you can see — a visible
  enemy's aim is readable intel — and for everyone in the spectator view.

## Vision (fog of war)

Every player observes the **full map** — the terrain is static knowledge and is
always drawn — but moving entities are fogged:

- Your **vision** is a **forward cone** of half-angle `visionConeDeg` (default
  ±45°) around your **aim angle**, with **unlimited range**, plus a small
  **omnidirectional bubble** of `visionBubble` (default ~90px) around you.
- **Walls block vision** — the same walls that block bullets. A long open lane is
  visible (and lethal) end to end; anything behind cover is not.
- **Your aim carries your vision.** You look where you aim, not where you walk,
  so watching a lane, sweeping an arc, and turning your back are deliberate
  rotation choices - and moving somewhere no longer reveals it.
- Everything outside your vision is **masked**: enemies, an enemy carrying a
  flag, and shot tracers / death splatters from unseen events are simply not in
  your observation. The unseen area is dimmed by a fog overlay.
- **Always visible regardless of fog:** the static map, your **teammates** (team
  radio), **both flag pedestals**, your **own flag's state** (its pedestal flag
  is never hidden — an empty own pedestal means your flag is stolen), and
  **yourself** via a distinct self marker.
- There is **no global flag tracking**: once a thief carries your flag into the
  fog, finding it again takes eyes on it.
- Dead players spectate as ghosts and see the whole map (their inputs are
  ignored).

## Combat

- **Guns are one-shot-kill.** There is no health bar: if you are hit, you die.
- Press **A** to fire. Firing has a short **cooldown** between shots (it is not a
  continuous beam).
- Pressing fire starts a short **windup** (~0.2s): your aim locks the moment
  you pull the trigger, and the bullet leaves at the end of the windup. A
  target that peeks out and ducks back behind cover before the release
  survives the shot.
- The bullet is **hitscan along your aim ray**: it travels down the locked
  aim direction and hits the **first player whose footprint crosses its
  narrow corridor** — it never passes through a body to hit someone behind,
  and **walls stop it** (clear line of sight required). Range is effectively
  map-wide, so cover and angles matter more than distance.
- **Friendly fire is ON.** A shot hits the first valid target regardless of team,
  so firing into a cluster of teammates can kill your own escort.
- **Same-tick shots resolve simultaneously.** Every trigger pulled on the same
  tick picks its target against the same snapshot before any kill applies: a
  mutual face-off duel kills both shooters, and neither team gains an
  input-processing-order advantage.
- On respawn you have brief **spawn protection** (temporary invulnerability) to
  prevent spawn-camping.

## Lives & respawn

- Each player has a fixed number of **lives**.
- When you die, you **respawn at your home edge** after a short delay — as long as
  you have lives remaining.
- When you run out of lives, you are **out for the rest of the round**.

## The flags

- Each team's flag sits on its **home pedestal** inside the team's spawn pocket.
- **Touch the ENEMY flag to steal it** off its pedestal. Your own flag cannot be
  interacted with by your own team. While carrying you move **slower** but can
  **still shoot**.
- If the carrier is killed (or disconnects), the flag **returns instantly to its
  own pedestal**. A flag is never left loose on the ground: it is either carried
  or sitting on its pedestal.
- Your own flag's **state** is always observable: its pedestal is never fogged,
  so an empty own pedestal means it is stolen — but the **thief itself is fogged**
  like any other enemy.

## Winning

A round ends immediately when either condition is met:

1. **Capture** — carry the **enemy flag** into **your own home capture zone**.
2. **Wipe** — the entire **enemy team is out of lives**.

If neither happens before the **time limit**, the round is decided by tiebreak:
most **total lives remaining**, then **closest flag progress toward home**,
otherwise a **draw**.

## Scoring

Scoring is **sparse and win-only**:

- **Winning team: +100** to every player on it.
- **Losing team / draw: 0.**

Kills, deaths, flag pickups, carry time, and captures are still **recorded** in
the episode results for leaderboards and analysis — they just do not award
points. This keeps the training objective tied purely to winning.

## Controls

| Button | Action |
| --- | --- |
| D-pad | Move (locomotion only — never changes your aim) |
| A | Fire |
| B | Rotate aim counter-clockwise (browser client: X or K) |
| Select | Rotate aim clockwise (browser client: Space or L) |

---

## Tuning defaults (configurable)

These are starting values, exposed in the game config and tuned in self-play.

| Parameter | Proposed default | Notes |
| --- | --- | --- |
| Players | 16 (8v8) | All standard Coworld slots |
| Lives per player | 3 | Out of lives = out for the round |
| Respawn delay | ~3s | Time dead before respawning at home |
| Spawn protection | ~1s | Invulnerability after respawn |
| Gun range | 1300px | Effectively map-wide; aim precision and line of sight are the real limits |
| Fire windup | ~0.2s | Trigger pull to bullet release; aim locks at the pull |
| Fire cooldown | ~0.5s | Minimum time between shots |
| Carrier speed | ~70% | Movement penalty while holding the flag |
| Aim turn rate (`aimTurnRate`) | 5 brads/tick | Rotation speed while B/Select is held (~7°/tick; full turn ~2.1s) |
| Vision cone (`visionConeDeg`) | ±45° | Fog-of-war forward vision half-angle; unlimited range, walls block |
| Vision bubble (`visionBubble`) | 90px | Omnidirectional close-range vision regardless of aim |
| Flag auto-return | instant | A flag snaps back to its own pedestal the moment its carrier dies |
| Time limit | (TBD) ticks | Round length cap before tiebreak |
| Map size | 1235×659 | Inherited from Crewrift; may change |

Engine tick rate is **24 ticks/sec** (inherited from Crewrift); all
second-based values above convert at that rate.

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
  **lives/respawn**, **flag pickup/carry/return**, **team win-check**, and a
  **Lobby → Playing → GameOver** phase machine (drop RoleReveal/Voting/VoteResult).
- Player struct: keep `x,y,velX,velY,carryX,carryY,alive,color,reward`; drop
  task/vent/vote fields; add `team`, `lives`, `respawnTimer`, `fireCooldown`,
  `aimBrads`, `carryingFlag`, `spawnProtect`.
- `global.nim` observation building: team-colored player sprites, the flag
  sprites, a **carrier indicator**, the per-viewer **fog overlay** and
  fog-culled entity stream (there are deliberately **no flag arrows** — fog of
  war replaced all global tracking intel), a distinct **self marker**, and
  per-player **lives / fire-cooldown UI** on HUD layers.
- New **symmetric arena**: a new `.resources` map (CSS-like rects) plus an Aseprite
  image with walk/wall layers. Red/Blue spawn strips on the left/right edges,
  flag pedestal at center, obstacles mirrored across the vertical axis, home-edge
  capture zones at the leftmost/rightmost columns.
- New team-based `config.json` and `coworld_manifest.json` (slots carry `team`
  instead of `role`; results schema reports team/kills/deaths/captures).
- A **baseline bot** (Crewrift's `notsus` equivalent) speaking Sprite v1.
- A **CTF grader** scoring episodes from wins.

**Open follow-up:**

- Crewrift reuses the **among_them social-deduction commissioner** for seating and
  ranking. CTF is team-based, so it needs a **team commissioner** (fixed Red/Blue
  seating, win/loss ranking) — to be written or adapted.
