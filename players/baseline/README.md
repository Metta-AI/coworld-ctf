# baseline — Coworld CTF bot (8v8)

A capture-the-flag reference bot that speaks the Bitworld Sprite v1 protocol.
It keeps a persistent world model on top of the partially-observable 128×128
view and plays a coordinated 8v8 team game on the dense-cover arena:
cover-aware pathfinding, a flag-rushing mid trio, wide flankers, overwatch
snipers on the longest firing lines, carrier interception at the enemy capture
gate, arrow-guided carrier sniping, and disciplined one-shot-kill gunplay
under the effectively map-wide 1300px gun.

All decision logic lives in `decide` in `baseline.nim`.

## View model

The per-player view is 128×128 **screen-space** with LOS occlusion (you see
~64px around you — the gun far outranges your eyes). The map object's offset
is the camera, so `mapPos = objectCenter + camera`, and our own avatar sits at
exactly **(66, 66)** on screen (see `playerView` in `src/ctf/sim.nim`).
**Facing equals movement direction** (you shoot where you walk) and only a
**fresh A press** fires, so to shoot we steer into the target's octant and
pulse A. Labels we read:

- `"player <color> right|left"` — a player; the suffix is horizontal facing.
  Our own sprite shares our color label and is filtered by distance.
- `"flag"` — a carried flag rides its carrier's exact position, so flag-on-me
  means we carry, flag-on-a-sprite means they carry, otherwise it is loose.
- `"flag arrow"` — off-screen direction hint to the flag.
- `"walkability map"` — the full static map mask, sent once at init.
- `"shadow"` — present only while we are alive (ghost views drop it).
- `"fire icon"` / `"fire icon cooldown"` — whether our shot is ready.
- Death splatters and shot tracers render under their own labels and are
  ignored (cosmetic only).

## Nav grid, cost field & cover-aware movement

At init the full-map walkability mask is eroded by the player's solid
footprint (`PlayerHalf` = 6px, matching the sim's `canOccupy`) into an
8px-cell grid (`NavCell`). Movement goals run a **cost field (Dijkstra)** over
that grid: orthogonal steps cost `StepCost`, diagonals `DiagCost` (no corner
cuts), and entering a cell **exposed to a remembered enemy** adds
`ExposedCost`. Exposure is recomputed per repath from the freshest few enemy
tracks (`ExposureThreats`, age ≤ `ExposureTrackTtl`): a cell is exposed when
it is inside gun range (`ExposureRange`) of the track with a coarsely-clear
line. The soft cost makes every unit — attackers and carriers alike — advance
cover-to-cover and keep obstacles between themselves and known threats
without hard-blocking any route. Steering follows the cost gradient with a
waypoint lookahead (`LookaheadCells`) plus a grid raycast; the field refreshes
when the goal cell changes or every `RepathTicks`. A stuck detector (no
movement for ~1s, and not deliberately holding behind cover) bursts in a
random direction and forces a repath.

## Cover model

From the eroded grid we precompute **cover cells** — walkable cells adjacent
to an obstacle (`coverCell`). They feed three behaviors:

- **Duck**: during the 12-tick fire cooldown with a remembered threat nearby,
  move to the nearest directly-reachable cell whose center the threat cannot
  see (exact pixel raycast, the sim's LOS rule) and hold there until the gun
  is back up (`findDuckCell`).
- **Peek**: with the gun up and the nearest fresh track wall-blocked, step
  sideways to the nearest cell that opens a firing line within gun range
  (`findPeekCell`); the engage logic fires the moment the ray clears, and the
  next cooldown ducks us back. This peek → fire → duck cycle is the default
  combat mode for every non-carrier, non-rushing unit.
- **Overwatch posts**: at nav-build each overwatch seat scans for a cover
  cell just on our side of the flag ring (`pickPost`) whose obstacle blocks
  the line toward the enemy half (`CoverShieldDist`) and which has a sideways
  peek cell with an open firing line toward the enemy half (≥`PeekLineDist`,
  scored by the longest line — sniper posts). The bot holds the post,
  sidesteps to the peek cell when a remembered enemy is in reach with the gun
  up, fires, and ducks back on cooldown.

## Memory (the world is partially observable)

- **Player tracks**: visible players are matched to remembered tracks
  (position, blended px/tick velocity, last-seen tick, facing). Tracks expire
  after `TrackTtl` (~5s) and are capped at the **8** real opponents/teammates
  (`TrackCap`). Ghost frames are ignored so corpses never poison memory.
- **Flag memory**: the last flag position is trusted for `FlagMemoryTtl`
  (~7s — a dropped flag auto-returns after 8s); after that we follow the flag
  arrow, else assume center.
- **Enemy carrier memory**: a carrier sighting is trusted for `CarryTtl`
  (~10s — roughly a full run home) and cleared the moment we see the flag
  loose or on a teammate.

## Roles & lanes (deterministic from the seat)

Slot parity picks the team (even = Red/left, odd = Blue/right); the per-team
seat index (`slot div 2`) picks the role via `roleForSeat`:

- **Seats 2/3 — MidTop (rusher) + MidBottom**: both seats spawn at flag
  height, but the sim's un-mirrored ±6px spawn offset makes seat 3 the
  closest spawn for Red and seat 2 for Blue — the **rusher** takes whichever
  is closer for its team (still fully deterministic) and races the flag dead
  straight, winning the opening pickup race. The other trails offset low.
- **Seat 1 — MidGuard**: third mid, trails the rusher offset high; the trio
  is spread so one 25° enemy cone cannot kill two of them.
- **Seats 0/6 — FlankBottom/FlankTop**: route wide via the extreme bottom/top
  lanes (`LaneBottom`/`LaneTop`) to `FlankDepth` past mid (sticky
  `behindLines` progress so they never oscillate), then stage
  `BehindFlagDist` past the flag and hit the contest from the octant the
  enemy is facing away from.
- **Seats 4/5 — OverwatchTop/OverwatchBottom**: hold the shielded cover posts
  flanking the flag ring (see cover model) and run the peek-fire-duck cycle
  on anything crossing mid. Post selection is sniper-first: candidate peek
  cells are scored by the **length of their clear firing line** toward the
  enemy half (`openLineLen`, floor `PeekLineDist`), because under a map-wide
  gun a post is worth what its lane can reach.
- **Seat 7 — HomeDefender**: holds the choke between the flag and our capture
  column, snapped to the nearest cover cell (`chokeHold`); grabs a loose flag
  on our half and chases intruders.

Priorities override the defaults for everyone: carry → run home; enemy
carrier known → intercept (see below); teammate carries → escort (mids and
flankers take spread positions ahead toward home, the guard screens the
nearest threat, overwatch keeps its posts covering the retreat, the defender
holds the choke).

## Carrier play & interception

Our carrier picks the home lane (top/mid/bottom) that combines the fewest
remembered enemies with the best **cover continuity** (`safestLaneY` samples
the run home and charges stretches with no cover cell nearby — under map-wide
guns an open lane is a shooting gallery even when it looks empty) and paths
deep into the capture zone; the exposure cost keeps the run hugging cover
past remembered enemies. Carriers never peek, duck, or jink and only engage
enemies within `CarrierFireRange`.

Against an enemy carrier: a fresh sighting (≤ ~40 ticks) makes everyone
converge on its predicted path. A **stale** sighting means it is running home
out of view — instead of chasing a fading prediction, units cut it off at the
**enemy capture gate** (`InterceptGateX` past mid on the mid lane), the fixed
choke every carrier must cross. Mids chase the flag itself (the arrow tracks
a carried flag globally).

**Arrow-guided carrier snipe**: while an enemy carrier is remembered
(`CarryTtl`) and the flag is off-screen, the flag arrow tracks the carried
flag globally — a live global bearing to the carrier. Any unit with its shot
ready fires down the arrow ray whenever the ray is long-open
(`openLineLen` ≥ `SnipeMinOpen`) and no remembered mate is on it: the
hitscan kills the nearest player along the ray, and the only player known to
be on it is the carrier. This is the bot's real long-range weapon — it kills
carriers from far beyond the 64px view, anywhere on the map.

## Fire discipline & combat micro

- **Target**: nearest track seen within `FreshShotTicks`, led by its velocity
  (`LeadTicks`), within `FireRange` = 1250 (the 1300px gun is effectively
  map-wide, so chases keep shooting after the target leaves the view — the
  wide long-range cone forgives track drift), with a clear pixel raycast
  against the walkability mask (exactly the sim's LOS rule). Shoot first —
  first shot wins. Tracks only form inside the ~64px view, so track
  engagements stay short-range in practice; the arrow snipe (above) is what
  actually uses the range.
- **Aim**: steer into the target's octant — the worst-case 22.5° octant error
  sits inside the 25° firing cone — and pulse A only when the fire icon shows
  ready (fresh presses fire; A is released for a frame between shots).
- **Friendly fire guard**: the server kills the **nearest** player inside the
  25° cone around our true 8-way facing, friend or foe — and at long range
  that cone is hundreds of px wide laterally. `friendlyBlocked` therefore
  checks remembered mates closer than the target against both the tight
  corridor (`CorridorHalfWidth`, inflated with sighting age) and the full
  server cone around the real fire axis (`octantDir`, `FireConeCos`).
  Mate-blocked targets are **skipped at selection**, so the bot retargets a
  clear enemy instead of holding fire.
- **Rushing**: the mid trio skips peek/duck while playing for the flag —
  pickup races and carrier chases are lost to positioning detours — and
  shoots on the move instead.
- **Jink**: when a visible enemy inside `ThreatRange` faces us and we have no
  shot lined up (and no duck cell breaks its line), strafe perpendicular.
- **Serpentine**: non-rushing, non-carrying units weave
  (`SerpentineNear`..`SerpentineFar`) while a fresh remembered enemy at mid
  distance has a clear pixel line to us — under map-wide guns a straight run
  across a watched lane is lethal.
- **Duck radius**: cooldown ducking reacts to remembered threats out to
  `DuckRange` (340px), beyond the old close-quarters radius, since threats
  outside the view can kill us the moment their line clears.
- **Spacing**: soft repulsion keeps teammates ~`MateSpacing` (40px) apart so
  one burst (or one of our own shots) cannot hit two of us.

## Tuning

The knobs are the constants at the top of `baseline.nim` (ranges, memory
TTLs, cover/exposure costs, lane y-coordinates, spacing, corridor width).
Role assignment is `roleForSeat`; lane via-points, `chokeSpot`, `homeDeepX`,
and `InterceptGateX` encode the map geometry (1235×659, center 617,329,
capture zones x≤~206 / x≥~1029, flag ring clear radius 70).

## Build & run

```bash
# From the repo root:
nim c -d:release --opt:speed --out:players/baseline/baseline.out players/baseline/baseline.nim
COWORLD_PLAYER_WS_URL="ws://localhost:8080/player?slot=0&token=0xBADA55_0" \
  ./players/baseline/baseline.out
```

Container build uses `players/baseline/Dockerfile` (produces `/bin/baseline`).
