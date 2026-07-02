# Coworld CTF — Game Rules

Coworld CTF is a two-team capture-the-flag shooter for the Coworld platform. Two
teams start on opposite edges of a symmetric arena. A single flag sits in the
center. Players move, take cover behind obstacles, and shoot. Get the flag to
your home edge — or eliminate the enemy team — to win.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift): it keeps
Crewrift's continuous 2D movement, line-of-sight, per-player camera, sprite
protocol, server, and replay infrastructure, and replaces the social-deduction
game layer (roles, tasks, voting) with teams, guns, and a flag.

---

## Overview

- **8 players, 4 vs 4.** Red team spawns along the **left edge**, Blue along the
  **right edge**.
- **One neutral flag** spawns at the **center** of the map.
- The arena is filled with **dense staggered cover** (a slalom of offset wall
  stubs, mirrored symmetrically so neither team has a positional advantage):
  **no straight sightline crosses the field**, so every approach is a series
  of corners.
- A round ends when a team **captures the flag** or is **wiped out**.

## Teams & spawns

- Players are assigned to **Red** or **Blue** by slot (4 each).
- Each team has a **home edge**: Red = left, Blue = right.
- Players spawn just inside their home edge and respawn there when killed.

## Movement & facing

- Movement is **continuous** (acceleration, friction, max speed, wall-sliding) —
  the d-pad drives it.
- You have an **8-directional facing** (including diagonals). Facing is set by the
  direction you last moved and **persists when you stop**. You shoot where you
  face — there is no separate aim, so you shoot in the direction you walk.

## Combat

- **Guns are one-shot-kill.** There is no health bar: if you are hit, you die.
- Press **A** to fire. Firing has a short **cooldown** between shots (it is not a
  continuous beam).
- A shot is **hitscan** (instant, not a traveling projectile). It hits the
  **nearest player** that is:
  1. within **gun range** (effectively map-wide — long open sightlines are
     lethal, so cover and lanes matter more than distance),
  2. within your **firing cone** (a narrow arc around your facing direction), and
  3. in **clear line of sight** (walls block shots).
- **Friendly fire is ON.** A shot hits the first valid target regardless of team,
  so firing into a cluster of teammates can kill your own escort.
- On respawn you have brief **spawn protection** (temporary invulnerability) to
  prevent spawn-camping.

## Lives & respawn

- Each player has a fixed number of **lives**.
- When you die, you **respawn at your home edge** after a short delay — as long as
  you have lives remaining.
- When you run out of lives, you are **out for the rest of the round**.

## The flag

- The flag is **neutral** and starts at the center.
- **Touch the flag to pick it up.** While carrying it you move **slower** but can
  **still shoot**.
- If the carrier is killed, the flag **drops where they fell**. Anyone — either
  team — can pick it up.
- A dropped flag that is left untouched for a while **auto-returns to the center**.
- It is a **tug-of-war over one flag**: Red wants it at the left edge, Blue wants
  it at the right edge.

## Winning

A round ends immediately when either condition is met:

1. **Capture** — carry the flag to **your own home edge**.
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
| D-pad | Move (also sets your facing direction) |
| A | Fire |
| B | (unused — reserved for future abilities) |
| Select | (unused — reserved) |

---

## Tuning defaults (configurable)

These are starting values, exposed in the game config and tuned in self-play.

| Parameter | Proposed default | Notes |
| --- | --- | --- |
| Players | 8 (4v4) | All standard Coworld slots |
| Lives per player | 3 | Out of lives = out for the round |
| Respawn delay | ~3s | Time dead before respawning at home |
| Spawn protection | ~1s | Invulnerability after respawn |
| Gun range | 1300px | Effectively map-wide; the cone and line of sight are the real limits |
| Firing cone | ~±25° | Main "aim difficulty" knob |
| Fire cooldown | ~0.5s | Minimum time between shots |
| Carrier speed | ~70% | Movement penalty while holding the flag |
| Flag auto-return | ~8s | Idle time before a dropped flag resets |
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
- Line-of-sight / shadow caster against a per-pixel `wallMask`, and the
  per-player **128×128 camera** that crops and occludes each bot's view.
- The **Sprite v1** protocol (button-mask input + sprite/object observations),
  websocket server (`/player`, `/global`, `/replay`, `/reward`), replay
  recording/playback, JSON config loading, and reward streaming.

**Rewritten (the game layer, replacing social deduction):**

- `sim.nim`: replace `Crewmate`/`Imposter` roles with `Red`/`Blue` teams; replace
  `tryKill` (proximity grab) with **directional hitscan + LOS + cone**; add
  **lives/respawn**, **flag pickup/carry/drop/return**, **team win-check**, and a
  **Lobby → Playing → GameOver** phase machine (drop RoleReveal/Voting/VoteResult).
- Player struct: keep `x,y,velX,velY,carryX,carryY,alive,color,reward`; drop
  task/vent/vote fields; add `team`, `lives`, `respawnTimer`, `fireCooldown`,
  `facing`, `carryingFlag`, `spawnProtect`.
- `global.nim` observation building: team-colored player sprites, the flag sprite,
  a **carrier indicator**, a **direction arrow to the flag** (like Crewrift's task
  arrows), and per-player **lives / fire-cooldown UI**.
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
