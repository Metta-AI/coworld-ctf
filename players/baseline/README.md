# baseline — Coworld CTF bot (8v8, fog-of-war)

A capture-the-flag reference bot that speaks the Bitworld Sprite v1 protocol.
It keeps a persistent world model on top of the fog-of-war full-map view and
plays a coordinated 8v8 team game on the dense-cover arena: cover-aware
pathfinding, a six-strong attack wave (mid quad plus wide flankers), an
overwatch sniper whose vision cone owns the longest lane (under fog the lane
watcher is also the radar), vision-scanning at every hold point, thief
hunting without any global tracking, and disciplined one-shot-kill gunplay
under the effectively map-wide 1300px gun.

All decision logic lives in `decide` in `baseline.nim`.

## View model (fog-of-war, full-map, map coordinates)

The observation is the **full 1235×659 map in map coordinates**: the map
object sits at `(0, 0)`, so object positions ARE map positions (no camera
math). Entities are **fogged**: an enemy — including an enemy carrying our
flag — is only streamed while inside OUR vision, which is a **forward cone**
(half-angle `visionConeDeg` ≈ 45° around our 8-dir facing, **unlimited
range**, walls block it) plus an **omnidirectional bubble** (`visionBubble` ≈
90px). **Facing aims vision**: we look where we last moved, so pointing the
cone is a tactical decision. Always visible regardless of fog: the map, our
**teammates** (team radio), **both flag pedestals**, our **own flag's state**,
and **ourselves** via the distinct self marker.
**Facing equals movement direction** (you shoot — and look — where you walk)
and only a **fresh A press** fires, so to shoot we steer into the target's
octant and pulse A. Labels we read:

- `"self <color> right|left"` — OUR OWN avatar (an outlined marker sprite);
  present exactly while we are alive, and how we locate ourselves in map
  coordinates. The suffix is horizontal facing.
- `"player <color> right|left"` — another player; the suffix is horizontal
  facing. Teammates are always streamed; enemies only while inside our
  vision cone/bubble with line of sight.
- `"<team> flag"` (`"red flag"` / `"blue flag"`) — a flag, on its pedestal or
  riding its carrier's exact position. Pedestal flags are never fogged; a
  carried flag is exactly as visible as its carrier. Consequences: the ENEMY
  flag (only our team can carry it) is always visible — on its pedestal, on
  me, or on a mate; our OWN flag on its pedestal means it is safe, visibly
  off-pedestal is a live thief fix, and ABSENT from the frame means a fogged
  thief is running it home.
- `"walkability map"` — the full static walkability mask, sent once at init.
- `"fire icon"` / `"fire icon cooldown"` — whether our shot is ready (HUD).
- `"fog"` — the viewer-side fog overlay runs (cosmetic; we ignore them — the
  entity culling above IS the observation).
- Death splatters and shot tracers render under their own labels, culled by
  the same fog, and are ignored (cosmetic only).

There are **no flag arrows** — fog of war deleted all global tracking intel.
When we are dead the self marker disappears and the ghost view shows the whole
map (inputs are ignored); the bot returns to lobby behavior and ignores ghost
frames so corpses never poison memory.

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

## Memory (fog makes the entity stream partially observable)

- **Player tracks**: visible players are matched to remembered tracks
  (position, blended px/tick velocity, last-seen tick, facing). Tracks expire
  after `TrackTtl` (~5s) and are capped at the **8** real opponents/teammates
  (`TrackCap`). Tracks are what persists through fog: an enemy that walks
  behind cover or out of the cone stays remembered until the TTL runs out.
- **Flag state needs no memory**: the enemy flag is always visible somewhere
  (pedestal / me / a mate), and our own flag's stolen-ness is observable
  every frame from its pedestal.
- **Thief fix**: seeing our own flag off-pedestal is a live fix on the thief
  (position, plus velocity from the matching track). The fix guides pursuit
  for `ThiefFixTtl` (~1.7s); after that the hunt falls back to guarding the
  mid crossing on the lane nearest the last fix.

## Roles & lanes (deterministic from the seat)

Slot parity picks the team (even = Red/left, odd = Blue/right); the per-team
seat index (`slot div 2`) picks the role via `roleForSeat`:

- **Seats 2/3 — MidTop (rusher) + MidBottom**: both seats spawn at flag
  height, but the sim's un-mirrored ±6px spawn offset makes seat 3 the
  closest spawn for Red and seat 2 for Blue — the **rusher** takes whichever
  is closer for its team (still fully deterministic) and races the flag dead
  straight, winning the opening pickup race. The other trails offset low.
- **Seats 1/4 — MidGuard + second MidBottom**: the trailing attackers; the
  quad is spread so one 25° enemy cone cannot kill two of them. The attack
  wave is deliberately six strong — under fog a carrier that slips the
  contest is hard to reacquire, so committed offense converts steals into
  captures.
- **Seats 0/6 — FlankBottom/FlankTop**: route wide via the extreme bottom/top
  lanes (`LaneBottom`/`LaneTop`) to `FlankDepth` past mid (sticky
  `behindLines` progress so they never oscillate), then turn straight in and
  hit the pocket together with the mid quad.
- **Seat 5 — Overwatch**: holds a shielded cover post flanking the flag ring
  (see cover model) and runs the peek-fire-duck cycle on anything crossing
  mid. Post selection is sniper-first: candidate peek cells are scored by
  the **length of their clear firing line** toward the enemy half
  (`openLineLen`, floor `PeekLineDist`), because under a map-wide gun AND
  map-wide vision cone a post is worth what its lane can reach — the watcher
  facing down an open lane sees (and kills) intruders at any distance.
  Overwatch is the team's radar.
- **Seat 7 — HomeDefender**: holds the choke between the flag and our capture
  column, snapped to the nearest cover cell (`chokeHold`); chases intruders
  spotted on our half and hunts the thief when our flag leaves its pedestal.

Priorities override the defaults for everyone: carry → run home; enemy
carrier known → intercept (see below); teammate carries → escort (mids and
flankers take spread positions ahead toward home, the guard screens the
nearest threat, overwatch keeps its post covering the retreat, the defender
holds the choke).

## Carrier play & interception

Our carrier picks the home lane (top/mid/bottom) that combines the fewest
remembered enemies with the best **cover continuity** (`safestLaneY` samples
the run home and charges stretches with no cover cell nearby — under map-wide
guns an open lane is a shooting gallery even when it looks empty) and paths
deep into the capture zone; the exposure cost keeps the run hugging cover
past remembered enemies. Carriers never peek, duck, or jink and only engage
enemies within `CarrierFireRange`.

Against a thief carrying OUR flag (defense without arrows): stolen-ness is
always observable — the own pedestal is empty — but the thief itself is
fogged like any enemy. With a **fresh fix** (own flag seen off-pedestal ≤
`ThiefFixTtl` ago) the back line (defender, and overwatch while the fix is
fresh) converges on the thief's predicted path toward ITS home edge. With a
**stale** fix the defender guards the **mid crossing** on the lane nearest
the last fix (the thief must cross toward its capture zone) and **sweeps its
vision** there; overwatch keeps its long lanes — reacquisition takes eyes on
the thief, and the moment any unit's cone touches the carrier, the flag
sprite itself is the new fix. Attackers keep pressing the enemy pedestal so
the capture race stays on.

## Fire discipline & combat micro

- **Target**: nearest track seen within `FreshShotTicks`, led by its velocity
  (`LeadTicks`), within `FireRange` = 1250 (the 1300px gun is effectively
  map-wide, so chases keep shooting briefly after the target fogs out — the
  wide long-range cone forgives track drift), with a clear pixel raycast
  against the walkability mask (exactly the sim's LOS rule). Shoot first —
  first shot wins. Tracks form anywhere the vision cone reaches, so a lane
  watcher genuinely engages at map range down its open lane.
- **Scanning**: any unit holding a position (overwatch posts, the defender's
  choke or thief gate, cooldown ducks) sweeps its facing with one-tick
  direction pulses every `ScanPeriod` ticks (~1px drift each), raking the
  90°-wide cone across a ~180° watch arc instead of staring down one ray.
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
TTLs, scan period, cover/exposure costs, lane y-coordinates, spacing,
corridor width). Role assignment is `roleForSeat`; lane via-points,
`chokeSpot`, and `homeDeepX` encode the map geometry (1235×659, center
617,329, mirror line x=617, capture zones x≤~206 / x≥~1029, spawn-pocket
pedestals at 186,329 / 1049,329).

## Build & run

```bash
# From the repo root:
nim c -d:release --opt:speed --out:players/baseline/baseline.out players/baseline/baseline.nim
COWORLD_PLAYER_WS_URL="ws://localhost:8080/player?slot=0&token=0xBADA55_0" \
  ./players/baseline/baseline.out
```

Container build uses `players/baseline/Dockerfile` (produces `/bin/baseline`).
