# Coworld CTF — AI Capture-the-Flag Shooter

Coworld CTF is a two-team capture-the-flag shooter for the Coworld platform. Two
teams (Red and Blue) start on opposite edges of a symmetric arena, each with its
own flag on a home pedestal. Players move, take cover behind obstacles, and
shoot. Steal the enemy flag and carry it home — or wipe the enemy team — to win.
Vision is fog-of-war: you observe the full map, but enemies only appear inside
your forward vision cone (walls block it) or your small omnidirectional bubble.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift). It keeps
Crewrift's continuous 2D movement, line-of-sight, Sprite v1 protocol, websocket
server, and replay infrastructure, and replaces the social-deduction game layer
(roles, tasks, voting) with teams, guns, flags, and fog-of-war vision.

The **full, authoritative ruleset lives in [`docs/RULES.md`](docs/RULES.md)**. The
summary below is just an orientation.

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
  enemy carrying a flag) only appear inside your **forward vision cone** (±45°
  around your **aim**, unlimited range, walls block it) or your **~90px
  omnidirectional bubble**. Your aim carries your vision — you see where you
  point, not where you walk. Teammates, both pedestals, your own flag's state,
  and your own position (a distinct self marker) are always visible.
- **Shoot** with **A**: an instant, line-of-sight, effectively map-wide hitscan
  along your aim angle (locked at the trigger pull, released after a short
  windup). One hit kills. **Friendly fire is on.**
- **Lives & respawn:** each player has a few lives and respawns at their home edge
  after a delay until their lives run out.
- **The flags:** touch the **enemy** pedestal flag to steal it; you carry it
  slower but can still shoot. If the carrier dies, the flag returns instantly to
  its own pedestal.
- **Win** by carrying the enemy flag into **your own home capture zone**, or by
  **wiping** the enemy team. Scoring is **win-only** (+100 to the winning team).

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

## Inspect replay timelines

Use `tools/expand_replay.nim` to get a text view of a replay — tick numbers, phase
changes, movement, shots, kills, flag pickups/returns/captures, and score changes.

```sh
nim r tools/expand_replay.nim tests/replays/<replay>.bitreplay
```

Start with replays where your bot scored poorly, died early, stood still, missed
shots, or failed to escort/defend the flag carrier. Expand the timeline, name the
failed capability, then find the function in `players/baseline/` that controls it.
