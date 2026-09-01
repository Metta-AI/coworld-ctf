# Paintbot — AI Paintball (the Coworld CTF engine)

Paintbot — historically "Coworld CTF", this repo's engine — is a paintball-flavored
shooter for the Coworld platform, played by submitted AI policies. Its classic game
is two-team capture-the-flag: two teams (Red and Blue) start on opposite edges
of a symmetric arena, each with its
own flag on a home pedestal. Players move, take cover behind obstacles, and
shoot. Steal the enemy flag and carry it home — or wipe the enemy team — to win.
Vision is fog-of-war: you observe the full map, but enemies only appear inside
your forward vision cone (walls block it) or your small omnidirectional bubble.

**Season 2:** the league flagship is `battle-royale-s2` — sixteen duos (32 seats,
seats k and k+16 partnered), no respawns, a zone that closes the field completely,
an open pre-round lobby chat, WebAssembly play-calling against a public seven-play
menu (`docs/designs/BR_PLAYS.md`), and Glory as the league score. The classic CTF
ruleset below is unchanged and remains the reference for core combat.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift). It keeps
Crewrift's continuous 2D movement, line-of-sight, Sprite v1 protocol, websocket
server, and replay infrastructure, and replaces the social-deduction game layer
(roles, tasks, voting) with teams, guns, flags, and fog-of-war vision.

The **full, authoritative ruleset lives in [`docs/RULES.md`](docs/RULES.md)**. The
summary below is just an orientation.

This repo publishes one `paintbot` Coworld manifest for both products. Paintbot
keeps its established variant ids (`2v2`, `4ffa`, `4ffa8`, `default`, `1v1`),
while the CTF leagues select `ctf-default` or `ctf-1v1`. The leagues remain
independent; they share only the versioned game artifact and schema.

If docs, commands, runtime behavior, logs, or replays disagree while you are
building or submitting a CTF policy, preserve the evidence and file a GitHub issue
instead of silently working around it. Include the command, league/Coworld ids,
logs or replay links, and the smallest repro.

## Rules at a glance

- **8 vs 8.** Red spawns on the **left** edge, Blue on the **right**. Each team's
  flag sits on a pedestal inside its spawn pocket.
- **Move** with the d-pad — locomotion only; it never changes where you aim.
- **Aim** with a continuous per-player **aim angle** (256 brads per turn, 0 =
  east, counter-clockwise): hold **B** to rotate counter-clockwise, **Select**
  to rotate clockwise (~7°/tick). Spawns aim toward the enemy side. A short aim
  indicator line shows every visible player's aim.
- **Vision is fog-of-war:** the map itself is always visible, but enemies (and an
  enemy carrying a flag) only appear inside your **forward vision cone** (±60°
  around your **aim**, reaching 1.5× the gun range — 1575px — with stone walls
  blocking it) or your **~90px omnidirectional bubble**. Six wall stubs are **glass windows** (the
  second-from-top, middle, and second-from-bottom stubs of each half's outer
  stub column): they block
  movement and bullets like any wall but are **transparent to vision**. Your aim carries your vision — you see where you
  point, not where you walk. Both pedestals, your own flag's state, and your
  own position (a distinct self marker) are always visible — teammates are
  NOT (no team radio). Shots are invisible to players and firing is
  silent: each shot's only trace is a brief impact ring randomly offset
  from where it landed — heard, not pinpointed.
- **Shoot** with **A**: an instant, line-of-sight hitscan along your aim angle
  (locked at the trigger pull, released after a short windup), with a fixed
  **1050px range** on every map and lightly **fuzzed aim** — a fully visible
  target at max range is hit 80% of the time, near-certainly when closer.
  Each hit removes one of **3 hit points** — at zero you die, and HP
  resets on respawn. **Friendly fire is on.**
- **Spray cans** spawn high in the side back columns and respawn 30 seconds
  after pickup. Carrying one disables the gun (and a carrier visibly holds the
  can); press **A** to spray a forward paint cone — 4 squares of reach, 2
  squares wide at the tip — that stays on for 5 ticks and takes 20 ticks to
  repressurize. A touch deals 3 damage (lethal to a bare cog; a shield carrier
  survives one), hits teammates too, credits kills to the attacker, and the can
  is lost on death.
- **Lives & respawn:** each player has a few lives and respawns at their home edge
  after a delay until their lives run out.
- **The flags:** touch the **enemy** pedestal flag to steal it; you carry it
  slower but can still shoot. If the carrier dies, the flag returns instantly to
  its own pedestal.
- **Win** by carrying the enemy flag into **your own home capture zone**, or by
  **wiping** the enemy team. Scoring: winners **+1**, losers **-1**; a
  time-limit draw is **-1 for both sides**, a mutual-wipe draw is 0.

See [`docs/RULES.md`](docs/RULES.md) for exact mechanics and tuning defaults.

## Run the game locally (without Docker)

Install Nim and sync the lock file. We recommend
[Nimby](https://github.com/treeform/nimby).

```sh
nimby use 2.2.10
nimby sync -g nimby.lock
```

Build and run the game with the repo config:

```sh
COGAME_HOST=0.0.0.0 \
COGAME_PORT=2000 \
COGAME_CONFIG_URI=file://$PWD/config.json \
nim r src/ctf.nim
```

Build the baseline bot:

```sh
nim c players/baseline/baseline.nim
```

Run 16 bots in parallel (slots 0–15, eight per team, with the matching tokens
from `config.json`):

```sh
for i in $(seq 0 15); do
  token="0xBADA55_$i"
  url="ws://localhost:2000/player?slot=$i&token=$token"
  COWORLD_PLAYER_WS_URL="$url" ./players/baseline/baseline.out &
done
wait
```

Watch the match with the global viewer at <http://localhost:2000/client/global>.

To play one slot yourself, open a configured player URL in the browser, e.g.
`http://localhost:2000/client/player?slot=0&token=0xBADA55_0`.

## Run the game with Docker

> **Note:** the public CTF images are not published yet. Build the image locally
> first (`docker build -t coworld-ctf:local .`) and substitute it below, or wait
> for the published image. The flow mirrors Crewrift's.

```sh
docker network create ctf-local || true

docker run --rm -d \
  --name ctf-server \
  --network ctf-local \
  -p 2000:2000 \
  -v "$PWD/config.json:/workspace/ctf/config.json:ro" \
  -e COGAME_HOST=0.0.0.0 \
  -e COGAME_PORT=2000 \
  -e COGAME_CONFIG_URI=file:///workspace/ctf/config.json \
  coworld-ctf:local
```

## Policy starting points

CTF policies speak the shared Bitworld Sprite v1 protocol:
<https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md>

The runner starts every policy with a `COWORLD_PLAYER_WS_URL` environment
variable. The policy connects to that websocket, plays until the game ends, and
exits when the runner stops it.

- **Stock baseline:** run the bundled baseline bot to compare against your own.
- **Improve baseline:** edit `players/baseline/` and use its README as a guide.
- **From scratch:** implement Sprite v1 in any language and package it in a Docker
  image.

## Season 2: the play-calling shell (design, not yet implemented)

Season 2 changes what a policy is: instead of driving a cog with button masks,
a policy uploads a playbook of WebAssembly "plays", talks with the other
policies in a lobby chat phase, and then calls plays by name with parameters
while the game runs them itself. The authoritative plan is
[`docs/designs/strategy-play-calling-shell-2026-08-29.md`](docs/designs/strategy-play-calling-shell-2026-08-29.md)
(implemented and merged behind the `season2Shell` config gate, off by
default: the ported body, the wasmtime runtime, the episode ladder, the
reference plays, and the wire codec are all on main, dark; a shipped
config never runs any of it). The runtime
choice behind it is documented in
[`docs/reports/wasm-runtime-embedding-2026-08-30.md`](docs/reports/wasm-runtime-embedding-2026-08-30.md).
A proof-of-concept policy image that drives a play seat over the real wire protocol — and a list of what the server still has to register before one can — is in [`policies/poc_llm_policy/`](policies/poc_llm_policy/README.md).

## Debug overlays (visualize what your bot is thinking)

A policy can send Sprite v1 **debug sprite** packets (client message `0x86` —
see the spec above) to draw private annotations: planned paths, target marks,
heatmaps, labels. The payload is ordinary server-to-client sprite messages
(define sprite / define object / delete object / clear objects). The server
records them into the replay, and the global viewer renders the **selected
player's** overlay on the map — live and during replay playback, exact across
seeks.

- Payload sprite/object ids must stay in `0..1023` per player; the viewer
  namespaces them so players can't collide with each other or the game.
- Overlays are diagnostic only: they never affect simulation state, inputs,
  scoring, or the replay tick hash. Malformed or oversized packets
  (> 32 KiB per player per tick) are dropped.
- Define sprites once and move objects per tick — every accepted packet is
  stored in the replay, so diff-style authoring keeps files small.

## Inspect and edit maps

Maps come from a seeded procedural generator (see [`docs/RULES.md`](docs/RULES.md)
for what the terrain features do in play). To look at one interactively — or
author your own — run the map editor:

```sh
nim c --threads:on --mm:orc -r tools/map_editor.nim 8099
```

Then open <http://localhost:8099>. It loads any curated pool entry, generator
seed with the full override set, or pasted map spec, renders it through the real
game geometry, and reports the play-quality validators live — cover budget, open
sightlines, corridor connectivity, and endzone access. Failures are **locatable**:
click an open sightline and it draws a rule across the board where the validator
found it, so "why was this candidate rejected" has a visible answer rather than a
sentence.

You can also edit: add and reshape obstacles, place trenches and med kits, change
the map parameters, and export the result as a `mapSpec` you can drop straight
into a config. Maps are authored for one half (or one quadrant on 4-team boards)
and the server derives the rest, so team fairness is structural — you cannot
accidentally give one side more cover than the other.

For a static, zoomable view of the whole curated pool without running anything,
open [`docs/pool-review.html`](docs/pool-review.html).

## Inspect replay timelines

Use `tools/expand_replay.nim` to get a text view of a replay — tick numbers, phase
changes, movement, shots, kills, flag pickups/returns/captures, and score changes.

```sh
nim r tools/expand_replay.nim tests/replays/<replay>.bitreplay
```

Use `tools/extract_events.nim` for the analysis JSONL stream. It includes
correlated gun trigger/fire/impact stages, grenade throws and impacts, spray
uses, pickups, shouts, and the existing damage/kill/objective events:

```sh
nim r tools/extract_events.nim tests/replays/<replay>.bitreplay
```

Start with replays where your bot scored poorly, died early, stood still, missed
shots, or failed to escort/defend the flag carrier. Expand the timeline, name the
failed capability, then find the function in `players/baseline/` that controls it.
