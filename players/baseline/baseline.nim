## Baseline capture-the-flag bot for Coworld CTF (8v8, classic two-flag,
## dense-cover arena, FOG-OF-WAR full-map vision).
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The observation is
## the FULL map in map coordinates, but entities are fogged: an enemy (and an
## enemy carrying our flag) is only streamed while it sits inside OUR vision —
## a forward cone (half-angle ~60 degrees around our AIM ANGLE, unlimited
## range, walls block) plus a small omnidirectional bubble (~90px). Always
## visible: the static map, BOTH flag pedestals (teammates are fogged too),
## our own flag's state (an empty own pedestal means it is stolen), and
## ourselves via the distinct "self <color> right|left" marker. AIM IS
## DECOUPLED FROM MOVEMENT: a continuous per-player aim angle (0..255 brads,
## 0 = east, counter-clockwise on screen) turns while B (CCW) or Select (CW)
## is held at ~5 brads/tick; the d-pad never touches it. The aim drives the
## gun, the vision cone, and the sprite flip, so pointing it is THE core
## tactical decision. The bot keeps a persistent world model on top of that:
##
## - **Nav grid**: the full walkability mask arrives once at init; we erode it
##   by the player footprint into an 8px cell grid and run a cost field
##   (Dijkstra) to any goal, then follow the path with waypoint lookahead.
## - **Cover model**: walkable cells adjacent to an obstacle are "cover
##   cells". Cells a remembered enemy could shoot into (range + coarse LOS)
##   get a soft path cost, so movement naturally advances cover-to-cover and
##   keeps obstacles between us and known threats.
## - **Flag model** (two flags): pedestals are STATIC known positions and
##   pedestal flags are never fogged. Only OUR team can carry the enemy flag,
##   so the "<enemy color> heart" sprite is always visible and fully describes
##   our attack (pedestal / on me / on a mate). Only the enemy can carry OUR
##   heart: the "<my color> heart" sprite on its pedestal means safe, visible
##   off-pedestal is a live thief fix, and ABSENT means stolen by a fogged
##   carrier somewhere between our pedestal and its home edge.
## - **Memory**: visible players are matched to tracks (position, velocity,
##   last-seen tick) that persist through fog, and the last thief fix guides
##   the hunt after the carrier fogs out.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid QUAD
##   races lanes to the ENEMY pedestal, two flankers route wide and hit the
##   pocket from behind, one overwatch sniper holds a shielded cover post
##   whose peek cell owns the longest firing line over mid — under fog a lane
##   watcher SEES map-wide down its open lane, so overwatch is also the radar
##   — and one home defender guards the choke before our pedestal. The attack
##   wave is deliberately six strong: with no global flag tracking, a carrier
##   that slips the contest is hard to reacquire, so committed offense turns
##   steals into captures. While our flag is stolen the back line hunts the
##   thief along its predicted route toward ITS home edge; attackers press on
##   — captures are instant wins both ways, so the race stays on.
## - **Turret controller**: the bot dead-reckons its own aim (spawn aim is
##   toward the enemy side; each held rotate button turns it 5 brads/tick)
##   and resyncs it every frame from its own rendered aim-indicator dots.
##   Each tick it outputs the rotate button that traverses toward the desired
##   aim by the shortest arc, and fires only when the bullet corridor
##   (~14px half-width) covers the target at its range.
## - **Scanning**: units holding a position (overwatch posts, the defender's
##   choke, cooldown ducks) sweep the aim back and forth across the watch arc
##   with genuine rotate-button sweeps, raking the vision cone over it while
##   standing perfectly still. On the move, the aim leads the movement
##   direction when no target demands it, so attackers watch down-lane.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, PRE-LAY the aim on the firing line
##   while stepping sideways to the nearest cell that opens it — the shot is
##   ready the moment the ray clears; during the 12-tick cooldown, duck
##   behind the nearest cover that breaks the threat's line and hold there.
## - **Fire discipline**: the bullet is a corridor hitscan along the aim, so
##   the fire gate is geometric: shoot when the aim error's perpendicular
##   miss at the target's range is inside the corridor. Skip targets with a
##   remembered teammate near the fire axis (friendly fire is on; the server
##   kills the NEAREST player in the corridor).
##
## Coordinate model: the map object sits at (0, 0), so object positions ARE
## map coordinates; we find ourselves via the self marker. Only a fresh A
## press fires, and the aim angle locks at the pull (the bullet leaves after
## a short windup), so we stop rotating on the tick we pull.

import
  std/[algorithm, heapqueue, math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols

when defined(taunt):
  import baseline/taunts

const
  WebSocketPath = "/player"
                              # Object coordinates and sprite sizes arrive
                              # multiplied by this; sprites stay centered on
                              # the same map points, so dividing the object
                              # center recovers exact legacy map coordinates.
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  PlayerHalf = 6              # solid footprint half-extent, matches the sim
  NavCell = 8                 # nav grid cell size in px
  GridW = (MapW + NavCell - 1) div NavCell
  GridH = (MapH + NavCell - 1) div NavCell
  RepathTicks = 10            # refresh the cost field at least this often
  LookaheadCells = 6          # how far ahead on the path we aim the waypoint

  FireRange = 1250.0          # engage distance (the 1300px gun is map-wide)
  CarrierFireRange = 110.0    # while carrying, only shoot enemies this close
  RushEngageRange = 230.0     # racing for the steal: only fight what blocks it
  EscortEngageRange = 320.0   # escorting a run: only fight near threats
  PocketRushRange = 210.0     # this close to the enemy pedestal, just GRAB
  ThreatRange = 200.0         # react to a visible enemy this close facing us
  DuckRange = 340.0           # duck from remembered threats this close on cooldown
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  LeadTicks = 6.0             # aim this many ticks ahead of a moving enemy:
                              # the 5-tick windup releases the bullet late
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 24         # only fire at tracks seen this recently; the
                              # turret needs traverse time, so chases keep
                              # shooting a bit after the target fogs out
  ThiefFixTtl = 40            # a thief position fix guides the chase this long

  AimBrads = 256              # aim angle units per full turn
  AimRate = 5                 # brads/tick a held rotate button turns the aim
                              # (matches the server's aimTurnRate default)
  AimDotRadius = 16.0         # own aim-indicator dots sit within this radius
  AimResyncBrads = 4          # trust dead reckoning inside this error
  MaxHp = 3                   # hitPoints per life (config default); pip labels
                              # read "hp <n>/<MaxHp>"
  HpPipRadius = 22.0          # a player's overhead hp bar sits within this
  HpFocusBonus = 60.0         # px of effective-distance credit per missing
                              # enemy hit point — a tiebreak between
                              # comparably-engageable targets, never a reason
                              # to swing the turret across the map
  ThiefFocusBonus = 400.0     # px of credit for the enemy RUNNING OUR FLAG:
                              # dominates every positional tiebreak — killing
                              # the thief returns the flag instantly
  FocusFireBonus = 45.0       # px of credit when a visible mate's aim line
                              # already covers the target (finish together)
  TraversePxPerBrad = 1.6     # px of effective distance per brad of turret
                              # swing needed to lay on the target: err/AimRate
                              # ticks of traverse at ~8px of enemy closing
                              # motion per tick = 8/5 px per brad
  MateAimRayLen = 700.0       # trust a mate's aim line out to this range
  MateAimHitSlack = 22.0      # enemy within this perpendicular distance of a
                              # mate's aim ray counts as mate-targeted
  ButtonC = 1'u8 shl 7        # grenade charge/throw (input mask bit 128)
  NadeMaxRange = 240.0        # full-charge throw distance (~fifth of the field)
  NadeMinRange = 60.0         # never lob inside this — the ~40px blast + drift
                              # would clip us
  NadeBlast = 40.0            # blast radius; a pair this close dies together
  NadeFullChargeTicks = 24    # ~1s of holding C reaches max range
  NadePickupDetour = 90.0     # grab a corner pickup within this detour range
  MedKitDetour = 80.0         # heal-detour budget when merely wounded
  MedKitCriticalReach = 180.0 # at 1 hp a heal outranks the current errand
  MedKitRespawn = 30 * 24     # a taken kit refills after 30s (sim constant)
  MedKitSeenClear = 55.0      # inside this range an empty spot is truly
                              # empty (bubble vision), not just fogged
  SwordReach = 26.0           # melee swipe range (sim SwordReach)
  SwordArcBrads = 32          # +/-45 degree swipe arc in brads
  SwordDetour = 70.0          # attacker detour budget for a sword pickup
  ShieldStealDetour = 480.0   # MidGuard's shield trip: the enemy endzone
                              # shield sits low in their back column
                              # (~215px from the pedestal since the game-v7
                              # split), so the round trip costs ~430 path px
  PickupRespawn = 30 * 24     # sword/shield respawn timer (sim constant)
  MedKitCarrierBudget = 90.0  # extra path px a hurt CARRIER spends to heal:
                              # a full-heal carrier survives pocket exits
                              # that kill a 1 hp one
  CarrySelfRadius = 26.0      # the carried flag banner is centered on its
                              # carrier: anything inside this slack that no
                              # visible mate sits closer to is OUR carry
  CarrierEstSpeed = 1.0       # px/tick a fogged mate-carrier is assumed to
                              # advance homeward (carrier moves at ~70% speed)
  CombatDeadband = 2          # stop the traverse within this error (brads);
                              # AimRate 5 cannot settle tighter than +-2
  CruiseDeadband = 8          # sloppier deadband for non-combat aim
  FireSlackPx = 11.0          # fire when the aim error's perpendicular miss
                              # at the target's range is inside this (the
                              # corridor half-width is ~14px; keep margin)
  ScanArc = 44                # scan sweeps this many brads each side of the
                              # watch heading (cone half-angle is 32 brads)
  PushOutTicks = 360          # endgame push: no enemy seen for ~15s...
  PushOutMinGame = 2400       # ...this deep into the game breaks the posts
  LatePushTick = 6800         # all-in on the clock: past this tick a draw is
                              # the default outcome, so commit to the capture

  CoverShieldDist = 42.0      # an obstacle this close blocks a threat direction
  PeekLineDist = 150.0        # floor for an overwatch peek firing line; post
                              # scoring strongly prefers the longest line
  DuckSearchCells = 3         # duck-cell search radius in nav cells
  PeekSearchCells = 3         # peek-cell search radius in nav cells
  ExposureRange = 380.0       # enemy threat radius used for exposure costing
  ExposureThreats = 3         # cost only the freshest few remembered threats
  ExposureTrackTtl = 60       # only cost threats remembered this recently
  UnderFireTrackTtl = 16      # tracks this fresh can pin us on open ground
  SerpentineNear = 100.0      # serpentine band: closer threats are jink/duck
  SerpentineFar = 400.0       # ... and farther tracks cannot really aim at us
  StepCost = 5'i32            # orthogonal move cost in the nav field
  DiagCost = 7'i32            # ~sqrt(2) * StepCost
  ExposedCost = 14'i32        # extra cost to enter a threat-exposed cell:
                              # under fog the exposure model (enemy sniper
                              # posts + fresh tracks) is the only warning of
                              # watched lanes, so routes respect it hard
  FlankDepth = 260.0          # wide flankers cross this far past mid
  WeaveBand = 280.0           # rushers serpentine within this x-band of mid

  LaneTop = 40.0              # open corridor above the mirrored obstacles
  LaneMid = float(CenterY)
  LaneBottom = 619.0          # open corridor below the mirrored obstacles

type
  Team = enum
    Red, Blue

  Role = enum
    MidTop, MidBottom, MidGuard, FlankTop, FlankBottom,
    Overwatch, HomeDefender

  Vec = object                # a map-space point or direction
    x, y: float

  Actor = object              # a player visible this frame
    pos: Vec
    facingRight: bool
    hp: int                   # from the overhead pip bar; 0 = not read

  Track = object              # a remembered player
    pos, vel: Vec
    lastSeen: int
    facingRight: bool
    hp: int                   # last observed hit points; 0 = never read

  Bot = ref object
    slot: int
    team: Team
    role: Role
    tick: int                 # sim ticks, advanced by frames received
    navBuilt: bool
    cellWalkable: seq[bool]   # eroded walkability, GridW x GridH
    coverCell: seq[bool]      # walkable cells hugging an obstacle
    exposure: seq[bool]       # cells a remembered enemy could shoot into
    navDist: seq[int32]       # cost field toward navGoal
    navGoal: int              # goal cell of the current field, -1 = stale
    navStamp: int             # tick the field was computed
    postHold, postPeek: Vec   # overwatch cover post and its peek cell
    postReady: bool
    enemyPosts: seq[Vec]      # the mirrored ENEMY sniper peek cells
    chokeHold: Vec            # defender hold point snapped to cover
    behindLines: bool         # flanker has crossed deep into the enemy half
    enemies: seq[Track]
    mates: seq[Track]
    carrierPos, carrierVel: Vec   # last fix on the thief carrying OUR flag
    carrierSeen: int
    lastEnemySeen: int        # last tick ANY enemy was inside our vision
    gameStart: int            # tick of the last lobby-to-playing transition
    firedLast: bool           # A was set on the previous sent mask
    estAim: int               # dead-reckoned own aim angle in brads
    rotSign: int              # rotation of the last sent mask: +1 B, -1 Select
    wasDead: bool             # respawn resets the aim to the spawn heading
    scanHigh: bool            # scan sweep currently heading to the high end
    lastPos: Vec
    stuckTicks: int
    jinkUntil: int
    jinkBits: uint8
    nadeCharge: int           # ticks the C button has been held; 0 = idle
    mateFixPos: Vec           # last SEEN position of a mate-carried enemy heart
    mateFixTick: int          # tick of that sighting; 0 = never seen this game
    nadeNeed: int             # charge ticks required for the planned throw
    shoutWant: string         # chat packet to send after this frame's input
    lastShoutTick: int        # rate limit: server allows one shout per second
    tauntBank: seq[string]    # Bedrock-prefetched taunts, popped front-first
    comebackWant: string      # pending reply to a heard enemy shout
    corpseCount: int          # visible enemy corpses last frame (kill signal)
    killMoodUntil: int        # taunt window opened by a fresh kill
    lastEnemyShout: string    # last enemy shout label already responded to
    lastComebackReq: int      # rate limit on comeback generation requests
    wasMateCarry: bool        # edge detector: a fresh steal opens a taunt window
    hp: int                   # own hit points, read from the HUD lives label
    kitPos: seq[Vec]          # discovered med kit spots (two, center line)
    kitAbsentAt: seq[int]     # tick a spot was last seen empty; -1 = present
    swordPos: seq[Vec]        # discovered sword spots (side midpoints)
    swordAbsentAt: seq[int]
    shieldPos: seq[Vec]       # discovered shield spots (endzone back columns)
    shieldAbsentAt: seq[int]

proc roleForSeat(seat: int, team: Team): Role =
  ## Deterministic role spread over the 8 per-team seats. Seats 2 and 3 both
  ## spawn at flag height, but the sim's un-mirrored +-6px spawn offset makes
  ## seat 3 the closest spawn to the flag for Red and seat 2 for Blue — the
  ## rusher takes whichever is closest so we win the opening pickup race.
  ## Under fog the attack wave is six strong (a mid quad plus two flankers):
  ## with no global flag tracking a carrier that slips the contest is hard to
  ## reacquire, so committed offense converts steals into captures, and the
  ## back line is one lane sniper plus the home defender.
  when defined(rushAll):
    # Shuffled-seat leagues deal this policy 1-2 agents onto random mixed
    # teams: coordinated-wave roles waste the seat, and a single capture wins
    # the episode outright, so every seat plays the flag-racing rusher.
    MidTop
  else:
    case seat
    of 0: FlankBottom      # wide bottom lane, get behind the contest
    of 1: MidGuard         # third mid, trails offset high and cleans up
    of 2: (if team == Blue: MidTop else: MidBottom)
    of 3: (if team == Red: MidTop else: MidBottom)
    of 4: MidBottom        # fourth mid: the second trailing attacker
    of 5: Overwatch        # cover post flanking the ring: the lane sniper
    of 6: FlankTop         # wide top lane, get behind the contest
    else: HomeDefender     # choke guard before our capture column

proc vec(x, y: float): Vec =
  Vec(x: x, y: y)

proc `+`(a, b: Vec): Vec = vec(a.x + b.x, a.y + b.y)
proc `-`(a, b: Vec): Vec = vec(a.x - b.x, a.y - b.y)
proc `*`(a: Vec, s: float): Vec = vec(a.x * s, a.y * s)

proc len(a: Vec): float =
  hypot(a.x, a.y)

proc dist(a, b: Vec): float =
  len(a - b)

proc norm(a: Vec): Vec =
  let l = a.len()
  if l < 1e-6: vec(0, 0) else: a * (1.0 / l)

proc dot(a, b: Vec): float =
  a.x * b.x + a.y * b.y

proc cross(a, b: Vec): float =
  a.x * b.y - a.y * b.x

proc octantBits(d: Vec): uint8 =
  ## D-pad bits for the 8-way direction nearest to `d`. The worst-case aim
  ## error is 22.5 degrees, safely inside the 25-degree firing cone.
  if d.len() < 1e-6:
    return 0
  let octant = (int(round(arctan2(d.y, d.x) / (PI / 4))) + 8) mod 8
  case octant
  of 0: ButtonRight
  of 1: ButtonRight or ButtonDown
  of 2: ButtonDown
  of 3: ButtonDown or ButtonLeft
  of 4: ButtonLeft
  of 5: ButtonLeft or ButtonUp
  of 6: ButtonUp
  else: ButtonUp or ButtonRight

proc bradsOf(d: Vec): int =
  ## The aim angle in brads pointing along `d`: 0 = east (+x), increasing
  ## counter-clockwise on screen (64 = north; map y grows downward).
  if d.len() < 1e-6:
    return 0
  (int(round(arctan2(-d.y, d.x) * float(AimBrads div 2) / PI)) +
    AimBrads) mod AimBrads

proc bradsDir(brads: int): Vec =
  ## The unit vector of one aim angle in brads (the true fire axis).
  let angle = float(brads) * PI / float(AimBrads div 2)
  vec(cos(angle), -sin(angle))

proc bradsErr(desired, current: int): int =
  ## The signed shortest arc from `current` to `desired` in -128..127:
  ## positive means rotate counter-clockwise (hold B).
  (desired - current + AimBrads + AimBrads div 2) mod AimBrads -
    AimBrads div 2

proc spawnAim(team: Team): int =
  ## The spawn/respawn aim angle: toward the enemy side.
  if team == Red: 0 else: AimBrads div 2

proc slotFromUrl(url: string): int =
  ## Reads the `slot` query parameter from the websocket URL.
  let key = "slot="
  let at = url.find(key)
  if at < 0:
    return 0
  var i = at + key.len
  var digits = ""
  while i < url.len and url[i] in {'0' .. '9'}:
    digits.add(url[i])
    inc i
  if digits.len == 0: 0 else: digits.parseInt()

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## Map-space center of a sprite object (the map object sits at the origin,
  ## so the camera offset is zero; keep it for exactness). Since the 0.7.8
  ## renderer restore the wire is back to 1x map pixels (the 0.6-0.7.7 HD
  ## era carried 3x-scaled coordinates), with sprites centered on their map
  ## points.
  vec(
    float(o.x + o.width div 2 + client.mapCameraX),
    float(o.y + o.height div 2 + client.mapCameraY)
  )

proc findSelf(
    client: ProtocolClient, color: string): tuple[alive: bool, pos: Vec] =
  ## Our avatar via the distinct self marker, only drawn while we are alive.
  for facingRight in [true, false]:
    let label = "self " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      return (alive: true, pos: client.mapPos(o))

proc observedAim(client: ProtocolClient, me: Vec, color: string): int =
  ## Our actual aim read back from our own rendered aim-indicator dots: the
  ## farthest "aim dot <color>" object within the indicator radius points
  ## along the aim. Returns -1 when no dot is close enough (teammate dots
  ## share our color but hug their own player). Resolution is ~2 brads —
  ## an absolute fix that caps dead-reckoning drift.
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, me)
    if d <= AimDotRadius and d > bestD:
      bestD = d
      result = bradsOf(p - me)

proc actorsFor(client: ProtocolClient, color: string): seq[Actor] =
  ## Visible players of one color in map coordinates plus horizontal facing
  ## and hit points. The overhead "hp <n>/<max>" pip bar is fog-culled with
  ## its player, so whenever the player is visible its hp is too: attach the
  ## nearest pip bar within HpPipRadius.
  for facingRight in [true, false]:
    let label = "player " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      result.add(Actor(pos: client.mapPos(o), facingRight: facingRight))
  for hp in 1 .. MaxHp:
    for o in client.spriteObjectsWithLabel("hp " & $hp & "/" & $MaxHp):
      let p = client.mapPos(o)
      var best = -1
      var bestD = HpPipRadius
      for i in 0 ..< result.len:
        let d = dist(result[i].pos, p)
        if d < bestD:
          bestD = d
          best = i
      if best >= 0:
        result[best].hp = hp

proc mateAimBrads(client: ProtocolClient, mate, me: Vec, color: string): int =
  ## A visible mate's aim angle read from ITS rendered aim-indicator dots
  ## (the same absolute readback observedAim does for our own turret).
  ## Returns -1 when the mate is too close to us to attribute dots safely.
  if dist(mate, me) <= 2.0 * AimDotRadius:
    return -1
  result = -1
  var bestD = 0.0
  for o in client.spriteObjectsWithLabel("aim dot " & color):
    let
      p = client.mapPos(o)
      d = dist(p, mate)
    if d <= AimDotRadius and d > bestD and dist(p, me) > AimDotRadius:
      bestD = d
      result = bradsOf(p - mate)

proc walkableAt(client: ProtocolClient, x, y: int): bool =
  if x < 0 or y < 0 or x >= client.walkabilityWidth or
      y >= client.walkabilityHeight:
    return false
  client.walkabilityMask[y * client.walkabilityWidth + x]

proc footprintFits(client: ProtocolClient, x, y: int): bool =
  ## True when the player's solid box centered at (x, y) is all walkable,
  ## mirroring canOccupy in the sim.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not client.walkableAt(x + dx, y + dy):
        return false
  true

proc cellOf(p: Vec): int =
  let
    cx = clamp(int(p.x) div NavCell, 0, GridW - 1)
    cy = clamp(int(p.y) div NavCell, 0, GridH - 1)
  cy * GridW + cx

proc cellCenter(cell: int): Vec =
  vec(
    float((cell mod GridW) * NavCell + NavCell div 2),
    float((cell div GridW) * NavCell + NavCell div 2)
  )

proc pixelRayClear(client: ProtocolClient, a, b: Vec): bool =
  ## True when no wall pixel blocks the segment; mirrors lineOfSightClear in
  ## the sim (walls are exactly the non-walkable pixels).
  let
    ax = int(a.x)
    ay = int(a.y)
    bx = int(b.x)
    by = int(b.y)
    steps = max(abs(bx - ax), abs(by - ay))
  if steps == 0:
    return true
  for s in 1 .. steps:
    if not client.walkableAt(ax + (bx - ax) * s div steps,
                             ay + (by - ay) * s div steps):
      return false
  true

proc rayClearCoarse(client: ProtocolClient, a, b: Vec, step: float): bool =
  ## Coarsely-sampled walkability raycast for cover scoring and exposure
  ## costing, where an occasional missed thin corner is an acceptable trade.
  let
    d = b - a
    l = d.len()
  if l < 1e-6:
    return true
  let n = max(1, int(l / step))
  for s in 1 .. n:
    let p = a + d * (float(s) / float(n))
    if not client.walkableAt(int(p.x), int(p.y)):
      return false
  true

proc openLineLen(client: ProtocolClient, a, dir: Vec, maxLen, step: float): float =
  ## Length of the wall-free ray from `a` along unit `dir`, capped at maxLen.
  ## Sizes sniper firing lines and arrow-snipe rays under the map-wide gun.
  var l = step
  while l <= maxLen:
    let p = a + dir * l
    if not client.walkableAt(int(p.x), int(p.y)):
      return l - step
    l += step
  maxLen

proc homeSign(team: Team): float =
  ## -1 toward Red's home edge (left), +1 toward Blue's (right).
  if team == Red: -1.0 else: 1.0

proc homeDeepX(team: Team): float =
  ## A point well inside our capture zone (Red x <= ~206, Blue x >= ~1029).
  ## Blue mirrors Red exactly across the x = 617 center line.
  if team == Red: 150.0 else: float(MapW - 1) - 150.0

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim).
  if team == Red: vec(186, 329) else: vec(1049, 329)

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between the flag and our home edge, mirrored
  ## exactly across the x = 617 center line.
  if team == Red: vec(390, 340) else: vec(float(MapW - 1) - 390.0, 340)

proc nearestOpenCell(bot: Bot, cell: int): int =
  ## The nearest walkable nav cell, searched in expanding rings.
  if bot.cellWalkable[cell]:
    return cell
  let
    cx = cell mod GridW
    cy = cell div GridW
  for r in 1 .. 16:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
          continue
        if bot.cellWalkable[ny * GridW + nx]:
          return ny * GridW + nx
  cell

proc snapToCover(bot: Bot, p: Vec): Vec =
  ## The nearest cover cell within a few cells of a point, else the point.
  let
    c0 = bot.nearestOpenCell(cellOf(p))
    cx = c0 mod GridW
    cy = c0 div GridW
  var bestD = 1e18
  result = p
  for dy in -6 .. 6:
    for dx in -6 .. 6:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.coverCell[nc]:
        continue
      let d = dist(cellCenter(nc), p)
      if d < bestD:
        bestD = d
        result = cellCenter(nc)

proc scanPost(
    bot: Bot, client: ProtocolClient, eSign, wantY: float
): tuple[hold, peek: Vec, ready: bool] =
  ## Finds one overwatch sniper post for the side whose guns point along
  ## `eSign`: a cover cell hugging the center ring, shielded from the front,
  ## with a sideways peek cell that owns the LONGEST clear firing line — the
  ## map-wide gun makes the lane length the post's value.
  var bestScore = 1e18
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.coverCell[c]:
        continue
      let
        p = cellCenter(c)
        fwd = eSign * (p.x - float(CenterX))
      if fwd > -40.0 or fwd < -160.0:
        continue                         # this side of the ring, hugging it
      if rayClearCoarse(client, p, p + vec(eSign * CoverShieldDist, 0.0), 4.0):
        continue                         # nothing shields us from the front
      var
        peek: Vec
        peekLine = 0.0
      for dyc in [-2, 2, -1, 1]:
        let ny = cy + dyc
        if ny < 0 or ny >= GridH or not bot.cellWalkable[ny * GridW + cx]:
          continue
        let q = cellCenter(ny * GridW + cx)
        let line = openLineLen(client, q, vec(eSign, 0.0), FireRange, 6.0)
        if line > peekLine:
          peekLine = line
          peek = q
      if peekLine < PeekLineDist:
        continue
      # The firing-line length dominates; the position terms break near-ties
      # toward the wanted flank height and hugging the flag ring.
      let score = abs(p.y - wantY) + abs(fwd + 90.0) * 0.7 - peekLine * 0.7
      if score < bestScore:
        bestScore = score
        result.hold = p
        result.peek = peek
        result.ready = true

proc pickPost(bot: Bot, client: ProtocolClient) =
  ## Chooses our own overwatch post (the overwatch seat only): fire from the
  ## peek, duck back to the hold during cooldown.
  bot.postReady = false
  if bot.role != Overwatch:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + 60.0
  let post = bot.scanPost(client, eSign, wantY)
  if post.ready:
    bot.postHold = post.hold
    bot.postPeek = post.peek
    bot.postReady = true

proc findEnemyPosts(bot: Bot, client: ProtocolClient) =
  ## Precomputes the standing virtual threats every carrier run has to
  ## respect, fed into exposure costing and lane choice: the mirrored ENEMY
  ## overwatch post (a stationary, hidden killer) and the ENEMY spawn
  ## pocket — every kill respawns an armed, spawn-protected enemy at the
  ## pedestal aiming our way, so the pocket mouth (and its mid lane) is
  ## permanently watched ground even when no track remembers anyone there.
  bot.enemyPosts.setLen(0)
  let post = bot.scanPost(client, homeSign(bot.team), float(CenterY) + 60.0)
  if post.ready:
    bot.enemyPosts.add(post.peek)
  bot.enemyPosts.add(flagHome(enemy(bot.team)))

proc buildNavGrid(bot: Bot, client: ProtocolClient) =
  ## Erodes the pixel walkability mask into a footprint-safe nav grid, then
  ## derives the cover model (cover cells, overwatch post, defender choke).
  bot.cellWalkable = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      bot.cellWalkable[cy * GridW + cx] = client.footprintFits(
        cx * NavCell + NavCell div 2, cy * NavCell + NavCell div 2)
  bot.coverCell = newSeq[bool](GridW * GridH)
  for cy in 0 ..< GridH:
    for cx in 0 ..< GridW:
      let c = cy * GridW + cx
      if not bot.cellWalkable[c]:
        continue
      block adjacency:
        for dy in -1 .. 1:
          for dx in -1 .. 1:
            if dx == 0 and dy == 0:
              continue
            let
              nx = cx + dx
              ny = cy + dy
            if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
              continue
            if not bot.cellWalkable[ny * GridW + nx]:
              bot.coverCell[c] = true
              break adjacency
  bot.exposure = newSeq[bool](GridW * GridH)
  bot.navDist = newSeq[int32](GridW * GridH)
  bot.navGoal = -1
  bot.pickPost(client)
  bot.findEnemyPosts(client)
  bot.chokeHold = bot.snapToCover(chokeSpot(bot.team))
  bot.navBuilt = true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc rebuildExposure(bot: Bot, client: ProtocolClient) =
  ## Marks nav cells the freshest remembered enemies — plus the mirrored
  ## enemy sniper posts, which are stationary hidden threats all game —
  ## could shoot into (inside gun range with a coarsely-clear line). Used as
  ## a soft path cost.
  for i in 0 ..< bot.exposure.len:
    bot.exposure[i] = false
  var
    threatSpots: seq[Vec] = bot.enemyPosts
    threats = 0
  for t in bot.enemies:                  # already sorted freshest-first
    if threats >= ExposureThreats or bot.tick - t.lastSeen > ExposureTrackTtl:
      break
    inc threats
    threatSpots.add(t.pos)
  for spot in threatSpots:
    let
      x0 = max(0, int(spot.x - ExposureRange) div NavCell)
      x1 = min(GridW - 1, int(spot.x + ExposureRange) div NavCell)
      y0 = max(0, int(spot.y - ExposureRange) div NavCell)
      y1 = min(GridH - 1, int(spot.y + ExposureRange) div NavCell)
    for cy in y0 .. y1:
      for cx in x0 .. x1:
        let c = cy * GridW + cx
        if bot.exposure[c] or not bot.cellWalkable[c]:
          continue
        let p = cellCenter(c)
        if dist(p, spot) <= ExposureRange and
            rayClearCoarse(client, spot, p, 8.0):
          bot.exposure[c] = true

proc computeField(bot: Bot, client: ProtocolClient, goal: int) =
  ## Cost field (Dijkstra) over the nav grid toward one goal cell. Steps cost
  ## StepCost/DiagCost and entering a threat-exposed cell adds ExposedCost, so
  ## paths prefer segments that keep obstacles between us and known enemies.
  ## Diagonal steps require both orthogonal neighbors open (no corner cuts).
  bot.rebuildExposure(client)
  for i in 0 ..< bot.navDist.len:
    bot.navDist[i] = -1
  var heap = initHeapQueue[(int32, int32)]()
  bot.navDist[goal] = 0
  heap.push((0'i32, int32(goal)))
  while heap.len > 0:
    let
      (dcur, cur32) = heap.pop()
      cur = int(cur32)
    if dcur > bot.navDist[cur]:
      continue
    let
      cx = cur mod GridW
      cy = cur div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      var step = (if dx != 0 and dy != 0: DiagCost else: StepCost)
      if bot.exposure[nc]:
        step += ExposedCost
      let nd = bot.navDist[cur] + step
      if bot.navDist[nc] < 0 or nd < bot.navDist[nc]:
        bot.navDist[nc] = nd
        heap.push((nd, int32(nc)))

proc gridRayClear(bot: Bot, a, b: Vec): bool =
  ## True when the eroded nav grid is open along the whole segment.
  let
    d = b - a
    steps = int(d.len() / 4.0) + 1
  for s in 0 .. steps:
    let p = a + d * (float(s) / float(steps))
    if not bot.cellWalkable[cellOf(p)]:
      return false
  true

proc navSteer(bot: Bot, client: ProtocolClient, me, target: Vec): Vec =
  ## Direction along the cost-field path toward `target`, with waypoint
  ## lookahead. Falls back to a beeline before the grid exists or when
  ## unreachable.
  if not bot.navBuilt:
    return target - me
  let goal = bot.nearestOpenCell(cellOf(target))
  if goal != bot.navGoal or bot.tick - bot.navStamp >= RepathTicks:
    bot.computeField(client, goal)
    bot.navGoal = goal
    bot.navStamp = bot.tick
  let start = bot.nearestOpenCell(cellOf(me))
  if bot.navDist[start] < 0:
    return target - me
  if bot.navDist[start] == 0:
    return target - me
  var
    node = start
    waypoint = cellCenter(start)
    haveClear = false
  for _ in 0 ..< LookaheadCells:
    var next = -1
    var bestD = bot.navDist[node]
    let
      cx = node mod GridW
      cy = node div GridW
    for (dx, dy) in NavNeighbors:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if bot.navDist[nc] < 0 or bot.navDist[nc] >= bestD:
        continue
      if dx != 0 and dy != 0 and
          not (bot.cellWalkable[cy * GridW + nx] and
               bot.cellWalkable[ny * GridW + cx]):
        continue
      bestD = bot.navDist[nc]
      next = nc
    if next < 0:
      break
    node = next
    if bot.gridRayClear(me, cellCenter(node)):
      waypoint = cellCenter(node)
      haveClear = true
    else:
      break
  if not haveClear:
    waypoint = cellCenter(node)
  waypoint - me

proc findDuckCell(bot: Bot, client: ProtocolClient, me, threat: Vec): int =
  ## The nearest directly-reachable cell around us whose center the threat
  ## cannot see; -1 when no nearby cover breaks the line.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -DuckSearchCells .. DuckSearchCells:
    for dx in -DuckSearchCells .. DuckSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if not bot.gridRayClear(me, p):
        continue
      if client.pixelRayClear(p, threat):
        continue                          # the threat can still see this cell
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc findPeekCell(bot: Bot, client: ProtocolClient, me, aim: Vec): int =
  ## The nearest directly-reachable cell that opens a firing line to `aim`
  ## within gun range; -1 when no sidestep grants the shot.
  result = -1
  let
    c0 = cellOf(me)
    cx0 = c0 mod GridW
    cy0 = c0 div GridW
  var bestD = 1e18
  for dy in -PeekSearchCells .. PeekSearchCells:
    for dx in -PeekSearchCells .. PeekSearchCells:
      let
        nx = cx0 + dx
        ny = cy0 + dy
      if nx < 0 or ny < 0 or nx >= GridW or ny >= GridH:
        continue
      let nc = ny * GridW + nx
      if not bot.cellWalkable[nc]:
        continue
      let p = cellCenter(nc)
      if dist(p, aim) > FireRange or not bot.gridRayClear(me, p):
        continue
      if not client.pixelRayClear(p, aim):
        continue
      let d = dist(p, me)
      if d < bestD:
        bestD = d
        result = nc

proc updateTracks(bot: Bot, tracks: var seq[Track], seen: seq[Actor]) =
  ## Matches this frame's sightings to remembered tracks and prunes stale
  ## ones. Velocity is a blended px/tick estimate used to lead shots.
  var claimed = newSeq[bool](tracks.len)
  for a in seen:
    var
      best = -1
      bestD = TrackMatchDist
    for i in 0 ..< tracks.len:
      if claimed[i]:
        continue
      let d = dist(tracks[i].pos, a.pos)
      if d < bestD:
        bestD = d
        best = i
    if best >= 0:
      let
        dt = float(max(1, bot.tick - tracks[best].lastSeen))
        v = (a.pos - tracks[best].pos) * (1.0 / dt)
      tracks[best].vel = vec(
        clamp((tracks[best].vel.x + v.x) * 0.5, -3.0, 3.0),
        clamp((tracks[best].vel.y + v.y) * 0.5, -3.0, 3.0)
      )
      tracks[best].pos = a.pos
      tracks[best].facingRight = a.facingRight
      tracks[best].lastSeen = bot.tick
      if a.hp > 0:
        tracks[best].hp = a.hp
      claimed[best] = true
    else:
      tracks.add(Track(
        pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight, hp: a.hp))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    if bot.tick - t.lastSeen <= TrackTtl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > TrackCap:                # there are only eight real players
    kept.setLen(TrackCap)
  tracks = kept

proc trackPickups(
  positions: var seq[Vec],
  absentAt: var seq[int],
  seen: seq[Vec],
  me: Vec,
  tick: int,
) =
  ## Shared fog-honest pickup memory: learn spots on sight, mark a spot
  ## taken only when we pass close enough that the bubble would show it,
  ## and believe it restocked once its respawn timer has elapsed.
  for p in seen:
    var known = false
    for i in 0 ..< positions.len:
      if dist(positions[i], p) < 24.0:
        known = true
        absentAt[i] = -1
    if not known:
      positions.add(p)
      absentAt.add(-1)
  for i in 0 ..< positions.len:
    if dist(positions[i], me) <= MedKitSeenClear and absentAt[i] < 0:
      var present = false
      for p in seen:
        if dist(positions[i], p) < 24.0:
          present = true
      if not present:
        absentAt[i] = tick

proc pickupAvailable(absentAt: seq[int], i, tick: int): bool =
  absentAt[i] < 0 or tick - absentAt[i] > PickupRespawn + 48

proc kitAvailable(bot: Bot, i: int): bool =
  ## Whether a discovered med kit spot is believed stocked right now: never
  ## seen empty, or its 30s respawn has elapsed since we saw it taken.
  bot.kitAbsentAt[i] < 0 or bot.tick - bot.kitAbsentAt[i] > MedKitRespawn + 48

proc bestKitDetour(bot: Bot, me, dest: Vec, budget: float): int =
  ## The stocked kit spot whose me->kit->dest detour costs the fewest extra
  ## path px over going straight to dest; -1 when none fits the budget.
  result = -1
  var best = budget
  for i in 0 ..< bot.kitPos.len:
    if not bot.kitAvailable(i):
      continue
    let cost = dist(me, bot.kitPos[i]) + dist(bot.kitPos[i], dest) - dist(me, dest)
    if cost < best:
      best = cost
      result = i

proc resetTransient(bot: Bot) =
  ## Drops per-game memory between rounds (lobby / game-over interstitials).
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.nadeCharge = 0
  bot.mateFixTick = 0
  bot.hp = MaxHp
  for i in 0 ..< bot.kitAbsentAt.len:
    bot.kitAbsentAt[i] = -1              # both kits restock at game start
  for i in 0 ..< bot.swordAbsentAt.len:
    bot.swordAbsentAt[i] = -1
  for i in 0 ..< bot.shieldAbsentAt.len:
    bot.shieldAbsentAt[i] = -1
  bot.shoutWant = ""
  bot.lastShoutTick = 0
  bot.comebackWant = ""
  bot.corpseCount = 0
  bot.killMoodUntil = 0
  bot.lastEnemyShout = ""
  bot.lastComebackReq = 0
  bot.wasMateCarry = false
  bot.carrierSeen = -100_000
  bot.lastEnemySeen = bot.tick
  bot.gameStart = bot.tick
  bot.firedLast = false
  bot.estAim = spawnAim(bot.team)
  bot.rotSign = 0
  bot.wasDead = false
  bot.scanHigh = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1

proc scanAim(bot: Bot, watch: Vec): int =
  ## The scan-sweep aim while holding a position: rake the vision cone back
  ## and forth across the arc around the `watch` heading with real rotation.
  ## Flip the sweep direction whenever the current end is nearly reached.
  let center = bradsOf(watch)
  var goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
    AimBrads) mod AimBrads
  if abs(bradsErr(goal, bot.estAim)) <= CombatDeadband:
    bot.scanHigh = not bot.scanHigh
    goal = (center + (if bot.scanHigh: ScanArc else: -ScanArc) +
      AimBrads) mod AimBrads
  goal

proc safestLaneY(bot: Bot, me: Vec): float =
  ## The carrier's lane home: fewest remembered enemies AND the best cover
  ## continuity — under map-wide guns a lane whose run has no cover nearby is
  ## a shooting gallery even when it looks empty.
  var
    bestLane = LaneMid
    bestScore = 1e18
  for lane in [LaneTop, LaneMid, LaneBottom]:
    var score = abs(me.y - lane) / 500.0     # mild bias toward the nearest lane
    for t in bot.enemies:
      let towardHome =
        if bot.team == Red: t.pos.x < me.x + 200
        else: t.pos.x > me.x - 200
      if towardHome and abs(t.pos.y - lane) < 120:
        score += 1.0
    for post in bot.enemyPosts:
      # The mirrored enemy sniper posts are standing threats on the run home
      # even when nobody has been seen there.
      if abs(post.y - lane) < 120:
        score += 1.0
    if bot.navBuilt:
      # Cover continuity: sample the run home along the lane and charge each
      # sample with no cover cell in its 3x3 nav neighborhood.
      let
        goalX = homeDeepX(bot.team)
        stepX = (if goalX > me.x: 32.0 else: -32.0)
      var
        x = me.x
        samples = 0
        bare = 0
      while (stepX > 0.0 and x < goalX) or (stepX < 0.0 and x > goalX):
        inc samples
        let
          c = cellOf(vec(x, lane))
          cx = c mod GridW
          cy = c div GridW
        block covered:
          for dy in -1 .. 1:
            for dx in -1 .. 1:
              let
                nx = cx + dx
                ny = cy + dy
              if nx >= 0 and ny >= 0 and nx < GridW and ny < GridH and
                  bot.coverCell[ny * GridW + nx]:
                break covered
          inc bare
        x += stepX
      if samples > 0:
        score += float(bare) / float(samples) * 2.0
    if score < bestScore:
      bestScore = score
      bestLane = lane
  bestLane

proc friendlyBlocked(bot: Bot, me, aim: Vec, enemyDist: float): bool =
  ## True when a remembered teammate could eat the shot: the bullet is a
  ## corridor hitscan (~14px half width) along the aim ray and the server
  ## kills the NEAREST player inside it, friend or foe — 8v8 puts many
  ## teammates downrange. The fire axis is the exact angle the turret would
  ## fire at right now.
  let dir = bradsDir(bradsOf(aim - me))
  for t in bot.mates:
    let age = float(bot.tick - t.lastSeen)
    if age > 36:
      continue
    let
      rel = t.pos - me
      d = rel.len()
      along = dot(rel, dir)
    if along <= 0 or d < 1e-6:
      continue
    if along >= enemyDist + 14.0:
      continue                          # beyond the target: the target dies first
    if abs(cross(rel, dir)) < CorridorHalfWidth + age * 0.35:
      return true
  false

proc decide(bot: Bot, client: ProtocolClient): uint8 =
  ## Core CTF policy for one frame.
  when defined(statue):
    return 0'u8                          # test dummy: stand still all game
  let
    myColor = (if bot.team == Red: "red" else: "blue")
    enemyColor = (if bot.team == Red: "blue" else: "red")
    (alive, me) = client.findSelf(myColor)
  if not alive:
    # Dead: the view is fully fogged (only our corpse renders) and inputs
    # are ignored, so skip perception entirely.
    bot.firedLast = false
    bot.rotSign = 0
    bot.wasDead = true
    return 0
  if bot.wasDead:
    # Respawned: the server points the aim back at the enemy side.
    bot.wasDead = false
    bot.estAim = spawnAim(bot.team)
  # Absolute turret fix: our own rendered aim-indicator dots show the actual
  # aim every frame, capping any dead-reckoning drift (mask-apply races).
  block resync:
    let seen = client.observedAim(me, myColor)
    if seen >= 0 and abs(bradsErr(seen, bot.estAim)) > AimResyncBrads:
      bot.estAim = seen
  # Swords and shields (game v7) share the endzone back columns (inset 50)
  # but are vertically SEPARATED: swords in the top half (quarter height),
  # shields in the bottom half (three-quarter height). Seed the spots up
  # front (they are deterministic; the fog would otherwise hide them until
  # we are already on top of them), then let sightings refine the nudged
  # positions.
  if bot.swordPos.len == 0:
    for spot in [vec(50.0, float(MapH div 4)),
                 vec(float(MapW) - 50.0, float(MapH div 4))]:
      bot.swordPos.add(spot)
      bot.swordAbsentAt.add(-1)
    for spot in [vec(50.0, float(3 * MapH div 4)),
                 vec(float(MapW) - 50.0, float(3 * MapH div 4))]:
      bot.shieldPos.add(spot)
      bot.shieldAbsentAt.add(-1)
  var swordSeen, shieldSeen: seq[Vec]
  for o in client.spriteObjectsWithLabel("sword"):
    swordSeen.add(client.mapPos(o))
  for o in client.spriteObjectsWithLabel("shield"):
    shieldSeen.add(client.mapPos(o))
  trackPickups(bot.swordPos, bot.swordAbsentAt, swordSeen, me, bot.tick)
  trackPickups(bot.shieldPos, bot.shieldAbsentAt, shieldSeen, me, bot.tick)
  # Own carry state: the carried markers float over their carrier, and a
  # shield carrier's HUD reads 6 hp (the marker is the fallback).
  var hasSword = false
  for o in client.spriteObjectsWithLabel("sword carried"):
    if dist(client.mapPos(o), me) <= 30.0:
      hasSword = true
      break
  var hasShield = bot.hp > MaxHp
  if not hasShield:
    for o in client.spriteObjectsWithLabel("shield carried"):
      if dist(client.mapPos(o), me) <= 30.0:
        hasShield = true
        break

  let
    shotReady = client.spriteObjectsWithLabel("fire icon").len > 0 and
      not hasSword                       # sword replaces the gun; a shield
                                         # only slows it (3x cooldown)
    seenEnemies = client.actorsFor(enemyColor)
    seenMates = client.actorsFor(myColor)
  bot.updateTracks(bot.enemies, seenEnemies)
  bot.updateTracks(bot.mates, seenMates)
  if seenEnemies.len > 0:
    bot.lastEnemySeen = bot.tick

  # Flag bookkeeping (two flags; a carried flag rides its carrier's exact
  # position). The enemy flag can only be carried by OUR team, so its sprite
  # is never fogged and fully describes our attack (pedestal / on me / on a
  # mate). Our own flag can only be carried by the enemy: on its pedestal it
  # is safe, visible off-pedestal is a live thief fix, and ABSENT means a
  # fogged thief is running it toward its home edge.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
  let
    stealTarget = flagHome(enemy(bot.team))  # the enemy pedestal is static
    ownHome = flagHome(bot.team)
    # Since the 0.7.8 renderer restore the objective is labeled a FLAG again,
    # split into distinct pedestal/carried sprites: "<color> flag planted" is
    # the always-visible pedestal banner, "<color> flag" the carried banner
    # centered exactly on its carrier (fogged with the carrier).
    enemyPlanted = client.spriteObjectsWithLabel(enemyColor & " flag planted")
    enemyFlags = client.spriteObjectsWithLabel(enemyColor & " flag")
    ownPlanted = client.spriteObjectsWithLabel(myColor & " flag planted")
    ownFlags = client.spriteObjectsWithLabel(myColor & " flag")
  # Own hit points from the HUD "lives <hp>hp x<lives>" text sprite.
  for o in client.spriteObjects():
    if o.label.startsWith("lives "):
      let text = o.label[6 .. ^1]
      let cut = text.find("hp")
      if cut > 0:
        try:
          # Unclamped past MaxHp: a shield carrier reads 6 hp on the HUD.
          bot.hp = clamp(parseInt(text[0 ..< cut]), 1, 9)
        except ValueError:
          discard
      break

  # Med kits: learn the two center-line spots on sight; presence is
  # fog-gated, so an empty spot only counts as TAKEN when we pass close
  # enough that the bubble would show it.
  var kitSeen: seq[Vec]
  for o in client.spriteObjectsWithLabel("med kit"):
    kitSeen.add(client.mapPos(o))
  for p in kitSeen:
    var known = false
    for i in 0 ..< bot.kitPos.len:
      if dist(bot.kitPos[i], p) < 24.0:
        known = true
        bot.kitAbsentAt[i] = -1
    if not known:
      bot.kitPos.add(p)
      bot.kitAbsentAt.add(-1)
  for i in 0 ..< bot.kitPos.len:
    if dist(bot.kitPos[i], me) <= MedKitSeenClear and bot.kitAbsentAt[i] < 0:
      var present = false
      for p in kitSeen:
        if dist(bot.kitPos[i], p) < 24.0:
          present = true
      if not present:
        bot.kitAbsentAt[i] = bot.tick

  when defined(taunt):
    # Taunt pipeline, all non-blocking: drain whatever the Bedrock worker
    # produced, notice new ENEMY shouts (queue a comeback), and open a short
    # taunt window when a corpse appears right after we fired. The worker
    # thread owns every HTTP call — this block only moves strings around.
    pollTaunts(bot.tauntBank, bot.comebackWant)
    for o in client.spriteObjects():
      if o.label.startsWith(enemyColor & " shout "):
        if o.label != bot.lastEnemyShout:
          bot.lastEnemyShout = o.label
          if bot.tick - bot.lastComebackReq >= 240:
            bot.lastComebackReq = bot.tick
            let sep = o.label.rfind(": ")
            if sep > 0:
              requestComeback(o.label[sep + 2 .. ^1])
        break
    var corpses = 0
    for facing in [" right", " left"]:
      corpses += client.spriteObjectsWithLabel(
        "corpse " & enemyColor & facing).len
    if corpses > bot.corpseCount and bot.firedLast:
      bot.killMoodUntil = bot.tick + 72
    bot.corpseCount = corpses

  when defined(shoutCoord):
    # Shout intel (0.7.5): teammates broadcast quantized fixes as 10-char
    # shouts — "C<cx> <cy>" is our carrier's own position, "T<cx> <cy>" a
    # fresh fix on the enemy thief running OUR heart. The payload carries the
    # exact quantized position; the bubble's jittered coordinates are ignored.
    for o in client.spriteObjects():
      if not o.label.startsWith(myColor & " shout "):
        continue
      let sep = o.label.rfind(": ")
      if sep < 0:
        continue
      let text = o.label[sep + 2 .. ^1]
      if text.len < 4 or text[0] notin {'C', 'T'}:
        continue
      let parts = text[1 .. ^1].split(' ')
      if parts.len != 2:
        continue
      var cx, cy: int
      try:
        cx = parseInt(parts[0])
        cy = parseInt(parts[1])
      except ValueError:
        continue
      let p = vec(float(cx * 8 + 4), float(cy * 8 + 4))
      if text[0] == 'C':
        # Fresher than any dead-reckoned estimate: pin the escort fix here.
        bot.mateFixPos = p
        bot.mateFixTick = bot.tick
      else:
        when defined(shoutThief):
          # Thief fix: adopt unless we have our own fresher eyes on it.
          # (Isolated behind its own define: broadcast convergence pulls
          # defenders across watched ground — measured attrition risk.)
          if bot.tick - bot.carrierSeen > 8:
            bot.carrierPos = p
            bot.carrierVel = vec(0, 0)
            bot.carrierSeen = bot.tick
  if enemyPlanted.len > 0:
    discard                              # enemy flag sits home: nobody carries
  elif enemyFlags.len > 0:
    # Carried banner in sight, centered exactly on its carrier. "Am I the
    # carrier" is "is the flag on ME and on nobody else" — a visible mate
    # closer to it than us means the mate is the carrier.
    let fp = client.mapPos(enemyFlags[0])
    var mateCloser = false
    let dSelf = dist(fp, me)
    for t in bot.mates:
      if bot.tick - t.lastSeen <= 2 and dist(t.pos, fp) < dSelf:
        mateCloser = true
        break
    if dSelf <= CarrySelfRadius and not mateCloser:
      iCarry = true
    else:
      mateCarry = true                   # only a teammate can be carrying it
      mateCarryPos = fp
      bot.mateFixPos = fp
      bot.mateFixTick = bot.tick
  else:
    # No planted banner and no carried banner in the frame: the flag is off
    # its pedestal on a FOGGED carrier — and only OUR team can carry it, so a
    # teammate is running it home right now even though we cannot see it.
    # Without this inference the whole wave keeps pressing an empty pedestal
    # instead of covering the run. Escort a dead-reckoned fix: the last
    # sighting (or the pedestal it was lifted from) advanced homeward at
    # carrier speed.
    mateCarry = true
    var est =
      if bot.mateFixTick > 0: bot.mateFixPos
      else: stealTarget
    let elapsed = float(bot.tick - max(bot.mateFixTick, bot.gameStart))
    est.x += homeSign(bot.team) * min(
      abs(ownHome.x - est.x),
      elapsed * CarrierEstSpeed
    )
    mateCarryPos = est
  when defined(carryDebug):
    if bot.tick mod 50 == 0 and (iCarry or mateCarry):
      var fpS = "none"
      if enemyFlags.len > 0:
        let fp = client.mapPos(enemyFlags[0])
        fpS = $int(fp.x) & "," & $int(fp.y) & " d=" & $int(dist(fp, me))
      echo "CARRY t=", bot.tick, " slot=", bot.slot, " role=", bot.role,
        " iCarry=", iCarry, " mateCarry=", mateCarry,
        " me=", int(me.x), ",", int(me.y), " fp=", fpS,
        " mateCarryPos=", int(mateCarryPos.x), ",", int(mateCarryPos.y)
      flushFile(stdout)
  var ownStolen = ownPlanted.len == 0
  var sawThief = false
  if ownPlanted.len > 0:
    bot.carrierSeen = -100_000           # our flag is safely home
  elif ownFlags.len > 0:
    # The thief holding our flag is inside our vision: take a fresh fix.
    let fp = client.mapPos(ownFlags[0])
    sawThief = true
    bot.carrierPos = fp
    bot.carrierVel = vec(0, 0)
    for t in bot.enemies:
      if dist(t.pos, fp) <= 8:
        bot.carrierVel = t.vel
        break
    bot.carrierSeen = bot.tick

  when defined(shoutCoord):
    # Broadcast intel worth its position leak (shouts are heard by enemies
    # within ~247px too, but a carrier is already hunted and a defender's
    # post is no secret). Carrier heartbeat beats thief fix; own eyes only —
    # re-broadcasting a heard fix would echo it around the map forever.
    if bot.tick - bot.lastShoutTick >= 26:
      if iCarry:
        bot.shoutWant = "C" & $(int(me.x) div 8) & " " & $(int(me.y) div 8)
        bot.lastShoutTick = bot.tick
      elif sawThief and defined(shoutThief):
        bot.shoutWant = "T" & $(int(bot.carrierPos.x) div 8) & " " &
          $(int(bot.carrierPos.y) div 8)
        bot.lastShoutTick = bot.tick

  when defined(taunt):
    # Taunts spend only LEFTOVER shout budget: never while carrying and never
    # over a gameplay shout (the carrier heartbeat always wins the 1/s slot).
    # Position leak is a non-issue at the trigger moments — a kill means we
    # just FIRED, and gunfire is already heard map-wide as a sound ring, so
    # the ~247px shout bubble tells enemies nothing new. One taunt per
    # kill/steal window; comebacks answer a heard enemy shout.
    if mateCarry and not bot.wasMateCarry:
      bot.killMoodUntil = bot.tick + 72    # a mate just lifted their heart
    bot.wasMateCarry = mateCarry
    if bot.shoutWant.len == 0 and not iCarry and
        bot.tick - bot.lastShoutTick >= 26 and
        (bot.comebackWant.len > 0 or bot.tick < bot.killMoodUntil):
      if bot.comebackWant.len > 0:
        bot.shoutWant = bot.comebackWant
        bot.comebackWant = ""
      else:
        if bot.tauntBank.len > 0:
          bot.shoutWant = bot.tauntBank[0]
          bot.tauntBank.delete(0)
        else:
          bot.shoutWant = sample(CannedTaunts)
        bot.killMoodUntil = 0              # one taunt per window
      bot.lastShoutTick = bot.tick

  # Flank progress: sticky so lane-runners do not oscillate at the boundary.
  if bot.role in {FlankTop, FlankBottom}:
    let fwd = -homeSign(bot.team) * (me.x - float(CenterX))
    if fwd >= FlankDepth - 50.0:
      bot.behindLines = true
    elif fwd < 20.0:
      bot.behindLines = false

  # Endgame push: our flag is safe and nobody on OUR side has seen an enemy
  # for a long while deep into the game. The survivors by then are usually
  # the defensive seats, and holding their posts forever is a guaranteed
  # tiebreak stalemate — break the posts and go win by capture (the enemy
  # team pushes symmetrically, so somebody makes something happen).
  let pushOut = not ownStolen and (
    (bot.tick - bot.gameStart > PushOutMinGame and
     bot.tick - bot.lastEnemySeen > PushOutTicks) or
    # Late all-in: a timeout is a scoreless draw, so deep into a game with no
    # capture the posts are worth nothing — break them and go win. Standoffs
    # keep enemies in sight, so the quiet-field trigger above never fires
    # against a peek-duck opponent; this one is on the clock.
    bot.tick - bot.gameStart > LatePushTick
  )

  # Movement target from role and flag situation.
  var target: Vec
  if iCarry:
    # Run the stolen enemy flag home along the emptiest lane; the exposure
    # cost in the path field keeps the route hugging cover past remembered
    # enemies.
    let
      pocket = flagHome(enemy(bot.team))
      laneY = bot.safestLaneY(me)
    if abs(me.x - pocket.x) < 60.0 and abs(me.y - laneY) > 70.0:
      # Bug out of the pocket VERTICALLY first: every kill respawns an
      # armed, spawn-protected enemy at this pedestal whose spawn aim points
      # along the east-west axis — pure-vertical movement exits that cone
      # fastest, then the border lane runs home outside it.
      target = vec(pocket.x, laneY)
    else:
      target = vec(homeDeepX(bot.team), laneY)
    # A hurt carrier detours through a stocked med kit on the way home: the
    # run crosses the center line anyway, kits are hurt-only pickups (a
    # healthy escort cannot waste one), and a full-heal carrier survives
    # pocket exits and mid crossings that kill a 1 hp one.
    if bot.hp < MaxHp:
      let kit = bot.bestKitDetour(me, target, MedKitCarrierBudget)
      if kit >= 0:
        target = bot.kitPos[kit]
  elif ownStolen and (bot.role == HomeDefender or
      bot.tick - bot.carrierSeen <= ThiefFixTtl):
    # An enemy is RUNNING OUR FLAG: with a fresh fix (own eyes or a mate's
    # "T" shout), EVERY role drops what it is doing and converges on the
    # thief's predicted route — an enemy capture ends the episode against
    # us, so nothing we were otherwise doing outranks the intercept. Without
    # a fix, only the back line guards the crossing lanes: the thief is
    # fogged but MUST cross mid toward its home edge, so the defender holds
    # the lane nearest the last fix and sweeps its vision — reacquisition
    # takes eyes, not magic.
    if bot.tick - bot.carrierSeen <= ThiefFixTtl:
      # Converge on the thief's predicted path toward the enemy capture edge.
      var predicted = bot.carrierPos +
        bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
    else:
      var laneY = LaneMid
      if bot.carrierSeen > -100_000:
        var bestD = 1e18
        for lane in [LaneTop, LaneMid, LaneBottom]:
          if abs(bot.carrierPos.y - lane) < bestD:
            bestD = abs(bot.carrierPos.y - lane)
            laneY = lane
      target = vec(float(CenterX) - homeSign(bot.team) * 60.0, laneY)
  elif mateCarry:
    case bot.role
    of MidTop, FlankTop:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, -30.0)
    of MidBottom, FlankBottom:
      # Rear guard: sit between the carrier and the enemy pocket it just
      # robbed — respawners chase from there, and the gun kills the NEAREST
      # player in the cone, so a body on the ray shields the carrier.
      target = mateCarryPos + vec(
        -homeSign(bot.team) * 42.0,
        (if bot.role == MidBottom: 22.0 else: -22.0)
      )
    of MidGuard:
      # Screen the carrier from the nearest remembered threat.
      var threat = -1
      var threatD = 1e18
      for i in 0 ..< bot.enemies.len:
        let d = dist(bot.enemies[i].pos, mateCarryPos)
        if d < threatD:
          threatD = d
          threat = i
      if threat >= 0:
        target = mateCarryPos + norm(bot.enemies[threat].pos - mateCarryPos) * 30.0
      else:
        target = mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of Overwatch:
      when defined(swarm):
        # Only 2-3 of our agents exist: a completed capture ends the episode,
        # so even the back line escorts the run home.
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, 24.0)
      else:
        # The posts already overwatch the carrier's retreat across mid.
        target =
          if bot.postReady: bot.postHold
          else: mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of HomeDefender:
      when defined(swarm):
        target = mateCarryPos + vec(homeSign(bot.team) * 40.0, -24.0)
      else:
        target = bot.chokeHold
  elif bot.role == HomeDefender and not pushOut:
    # Hold the choke on our pedestal approach; break off to chase the nearest
    # intruder on our half (every steal has to come through here).
    var intruder = -1
    var intruderD = 1e18
    for i in 0 ..< bot.enemies.len:
      let onOurHalf =
        if bot.team == Red: bot.enemies[i].pos.x < float(CenterX) + 60
        else: bot.enemies[i].pos.x > float(CenterX) - 60
      if not onOurHalf:
        continue
      let d = dist(bot.enemies[i].pos, me)
      if d < intruderD:
        intruderD = d
        intruder = i
    if intruder >= 0:
      target = bot.enemies[intruder].pos + bot.enemies[intruder].vel * 6.0
    else:
      target = bot.chokeHold
  elif bot.role == Overwatch and not pushOut:
    if bot.postReady:
      # Peek-and-shoot cycle: hold behind the post; with the gun up and a
      # remembered enemy in reach, sidestep to the peek cell to open the
      # line (the combat block below takes the shot and ducks us back).
      target = bot.postHold
      if shotReady:
        for t in bot.enemies:
          if bot.tick - t.lastSeen <= 24 and
              dist(t.pos, bot.postHold) < FireRange + 30.0:
            target = bot.postPeek
            break
    else:
      target = vec(float(CenterX) + homeSign(bot.team) * 70.0, float(CenterY))
  else:
    # Attackers: route to the ENEMY pedestal — a fixed, known position by
    # team side. The lead rusher races it dead straight (its seat spawns at
    # pedestal height), the second mid trails behind and offset so one enemy
    # cone cannot kill the pair; flankers run the extreme lanes deep past
    # mid, then hit the pedestal pocket from behind.
    target = stealTarget
    case bot.role
    of MidBottom:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 34.0, 26.0)
    of MidGuard:
      if dist(me, stealTarget) > 90:
        target = stealTarget + vec(homeSign(bot.team) * 60.0, -26.0)
    of FlankTop, FlankBottom:
      # Run the wide lane deep, then turn straight in for the grab so the
      # flankers hit the pocket together with the mid trio instead of
      # trickling in.
      let laneY = (if bot.role == FlankTop: LaneTop else: LaneBottom)
      if not bot.behindLines and dist(me, stealTarget) > 170.0:
        target = vec(float(CenterX) - homeSign(bot.team) * FlankDepth, laneY)
    else:
      discard

  # The mid trio plays for the flag, not for position: pickup races and
  # carrier chases are lost to peek/duck detours, so mids keep moving and
  # shoot on the move whenever a mate is not already carrying.
  let rushing = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard}
  # The pocket endgame: duelling at the pocket edge is an infinite respawn
  # grinder (respawners appear spawn-protected AT the pedestal), so the
  # attacker CLOSEST to the pedestal commits to the touch, unarmed and
  # undistracted, while the rest of the wave keeps its guns up to cover the
  # grab — even a suicide grab forces the enemy back onto defense, and a
  # lucky one starts the capture run.
  var nearestMateToSteal = 1e18
  for t in bot.mates:
    if bot.tick - t.lastSeen > 48:
      continue
    nearestMateToSteal = min(nearestMateToSteal, dist(t.pos, stealTarget))
  let pocketRush = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
    dist(me, stealTarget) < PocketRushRange and
    dist(me, stealTarget) < nearestMateToSteal + 8.0

  # Combat: the nearest fresh track with a clear pixel ray AND a mate-free
  # fire cone is the engage target; the nearest fresh-but-wall-blocked track
  # is the peek candidate. The map-wide gun engages fresh tracks far beyond
  # the view, so chases keep killing after the target leaves the window —
  # but objective play caps the range: the carrier only fights point-blank,
  # rushers racing for the steal and escorts guarding a run only fight what
  # is actually in the way, instead of frag-chasing across the map.
  let maxEngage =
    if hasShield and not hasSword:       # slow gun (3x cooldown): only fight
      CarrierFireRange                   # what is point-blank in the way
    elif hasSword: SwordReach + 6.0      # melee: only point-blank matters
    elif pocketRush: 0.0
    elif iCarry: CarrierFireRange
    elif ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl: FireRange
      # A live fix on the enemy running our flag lifts every role's range
      # cap: the map-wide gun is the fastest flag return there is.
    elif rushing: RushEngageRange
    elif mateCarry: EscortEngageRange
    else: FireRange
  # Focus-fire intel: which remembered enemies sit on a visible mate's aim
  # line right now. A mate's rendered aim dots are an absolute readback of
  # where it is about to shoot; piling our shot onto the same target converts
  # two 1-damage hits into a kill instead of two wounded runners.
  var mateTargeted = newSeq[bool](bot.enemies.len)
  for m in bot.mates:
    if bot.tick - m.lastSeen > 2:
      continue                          # dots exist only while the mate is visible
    let mAim = client.mateAimBrads(m.pos, me, myColor)
    if mAim < 0:
      continue
    let dir = bradsDir(mAim)
    for i in 0 ..< bot.enemies.len:
      if bot.tick - bot.enemies[i].lastSeen > FreshShotTicks:
        continue
      let rel = bot.enemies[i].pos - m.pos
      let along = dot(rel, dir)
      if along <= 0.0 or along > MateAimRayLen:
        continue
      if abs(cross(rel, dir)) <= MateAimHitSlack:
        mateTargeted[i] = true

  var
    engage = -1
    engageD = maxEngage
    engagePrio = maxEngage
    aim: Vec
    blockedAim: Vec
    haveBlocked = false
    blockedD = maxEngage
  for i in 0 ..< bot.enemies.len:
    let t = bot.enemies[i]
    if bot.tick - t.lastSeen > FreshShotTicks:
      continue
    let predicted = t.pos + t.vel * (float(bot.tick - t.lastSeen) + LeadTicks)
    let d = dist(predicted, me)
    if d >= maxEngage:
      continue
    # Target priority: distance plus the turret swing needed to lay on the
    # target (the traverse is slow, so a target near the current aim line
    # dies sooner than a nearer one behind us), discounted for wounded
    # targets (a 1-hp enemy dies to one shot — finish it before it resets on
    # respawn) and for targets a visible mate is already lined up on (focus
    # fire). The discounts are tiebreaks between comparably-engageable
    # targets, deliberately smaller than a real positional difference.
    var prio = d +
      float(abs(bradsErr(bradsOf(predicted - me), bot.estAim))) * TraversePxPerBrad
    if t.hp in 1 ..< MaxHp:
      prio -= float(MaxHp - t.hp) * HpFocusBonus
    if mateTargeted[i]:
      prio -= FocusFireBonus
    if ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl and
        dist(t.pos, bot.carrierPos) <= 48.0:
      # This track IS (or shadows) the enemy running our flag: shoot it
      # before anything else — a dead carrier returns the flag instantly.
      prio -= ThiefFocusBonus
    if client.pixelRayClear(me, predicted):
      if bot.friendlyBlocked(me, predicted, d):
        continue                        # prefer a target with an empty corridor
      if engage < 0 or prio < engagePrio:
        engagePrio = prio
        engageD = d
        engage = i
        aim = predicted
    elif d < blockedD:
      blockedD = d
      blockedAim = predicted
      haveBlocked = true

  # The nearest remembered enemy that could be threatening us right now,
  # used to pick which line to break when ducking through cooldown.
  var
    nearThreat = -1
    nearThreatD = DuckRange
  for i in 0 ..< bot.enemies.len:
    if bot.tick - bot.enemies[i].lastSeen > 30:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if d < nearThreatD:
      nearThreatD = d
      nearThreat = i

  # Grenades (0.7.0): a lobbed 2-hp blast that flies over every wall — the
  # counter to cover-campers the hitscan gun can never reach. Carry one when a
  # corner pickup is a short detour away; spend it on a wall-blocked fresh
  # track (value the gun cannot collect) or on a tight enemy pair in range.
  var carryingNade = false
  for o in client.spriteObjectsWithLabel("grenade carried"):
    # The marker floats above-right of its carrier (+8 x, ~-20 y from center).
    if dist(client.mapPos(o), me) <= 30.0:
      carryingNade = true
      break
  var
    nadeAim = -1
    nadeThrowD = 0.0
  if carryingNade and not iCarry:
    var bestD = 1e18
    for i in 0 ..< bot.enemies.len:
      let t = bot.enemies[i]
      if bot.tick - t.lastSeen > FreshShotTicks:
        continue
      let p = t.pos + t.vel * float(bot.tick - t.lastSeen)
      let d = dist(p, me)
      if d < NadeMinRange or d > NadeMaxRange or d >= bestD:
        continue
      let blocked = not client.pixelRayClear(me, p)
      var paired = false
      if not blocked:
        for j in 0 ..< bot.enemies.len:
          if j != i and bot.tick - bot.enemies[j].lastSeen <= FreshShotTicks and
              dist(bot.enemies[j].pos, p) <= NadeBlast:
            paired = true
            break
      if blocked or paired:
        bestD = d
        nadeAim = bradsOf(p - me)
        nadeThrowD = d

  # Weapon pickups. SHIELD-THEN-STEAL: the enemy endzone shield sits just
  # behind their pedestal — a rusher near the pocket grabs 6 hp first and
  # steals second (the run home is what kills 3 hp carriers). Defensive
  # roles never take a shield (it slows the gun 3x). SWORDS arm the pocket
  # brawlers: attackers detour a little for one on the way in — the pocket
  # duel is point-blank, where an instant lethal swipe beats any gun.
  if not iCarry and not hasShield and bot.role == MidGuard and
      not (ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl):
    # ONE designated shield-runner (MidGuard, the trailing mid): the shield
    # sits ~136px BEYOND the enemy pedestal, so the trip costs ~270 path px —
    # never spend the LEAD rusher's tempo on it (first steal wins races).
    # The second wave arrives as a 6 hp bruiser: it steals if the flag is
    # still planted, escorts (and re-steals after a failed run) if not.
    var best = -1
    var bestCost = ShieldStealDetour
    for i in 0 ..< bot.shieldPos.len:
      if not pickupAvailable(bot.shieldAbsentAt, i, bot.tick):
        continue
      if homeSign(bot.team) * (bot.shieldPos[i].x - float(CenterX)) > 0.0:
        continue                         # OUR endzone shield: leave the gun
      let cost = dist(me, bot.shieldPos[i]) + dist(bot.shieldPos[i], stealTarget) -
        dist(me, stealTarget)
      if cost < bestCost:
        bestCost = cost
        best = i
    if best >= 0:
      target = bot.shieldPos[best]
      when defined(pickupDebug):
        if bot.tick mod 50 == 0:
          echo "SHIELDTRIP slot=", bot.slot, " t=", bot.tick, " me=",
            int(me.x), ",", int(me.y), " -> ", int(target.x), ",",
            int(target.y), " cost=", int(bestCost)
          flushFile(stdout)
    else:
      when defined(pickupDebug):
        if bot.tick mod 100 == 0:
          echo "SHIELDTRIP-NONE slot=", bot.slot, " t=", bot.tick,
            " spots=", bot.shieldPos.len
          flushFile(stdout)
  elif not iCarry and not hasSword and
      bot.role in {MidTop, MidBottom, MidGuard, FlankTop, FlankBottom} and
      not mateCarry and not pocketRush:
    # Sword top-up: swipe-armed pocket brawls win point-blank. Cheap when we
    # are already visiting the endzone column (shield chain) or passing by.
    for i in 0 ..< bot.swordPos.len:
      if not pickupAvailable(bot.swordAbsentAt, i, bot.tick):
        continue
      if dist(me, bot.swordPos[i]) <= SwordDetour:
        target = bot.swordPos[i]
        break

  # Med kit heal detour (hurt bots only; the carrier handles its own detour
  # in the carry branch). Wounded: a short opportunistic detour. Critical
  # (1 hp): a heal outranks the current errand at much longer reach — a
  # healed body is a respawn we did not spend. Never while committing to the
  # pocket touch or chasing the enemy running our flag, and the CARRIER gets
  # right of way: if our flag runner is closer to the kit than we are, we
  # leave it — kits are hurt-only pickups, so deferring costs nothing when
  # the carrier turns out healthy.
  if bot.hp < MaxHp and not iCarry and not pocketRush and
      not (ownStolen and bot.tick - bot.carrierSeen <= ThiefFixTtl):
    let reach = if bot.hp <= 1: MedKitCriticalReach else: MedKitDetour
    let kit = bot.bestKitDetour(me, target, reach)
    if kit >= 0 and not (mateCarry and
        dist(mateCarryPos, bot.kitPos[kit]) < dist(me, bot.kitPos[kit]) + 100.0):
      target = bot.kitPos[kit]

  if not carryingNade and not iCarry and not mateCarry and not pocketRush:
    # Collect a pickup: anyone grabs one within a short detour, and the two
    # flankers own their lane's friendly-side corner spawn — it sits right on
    # their border route, so they arm up on the way out every respawn cycle.
    for o in client.spriteObjectsWithLabel("grenade"):
      let p = client.mapPos(o)
      if p.x < 40.0 or p.y < 40.0 or p.x > float(MapW - 40) or
          p.y > float(MapH - 40):
        continue                     # HUD indicator shares the label
      let laneMatch =
        (bot.role == FlankTop and p.y < float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0) or
        (bot.role == FlankBottom and p.y > float(CenterY) and
         homeSign(bot.team) * (p.x - float(CenterX)) > 0)
      let reach = if laneMatch: 1e9 else: NadePickupDetour
      if dist(p, me) <= reach:
        when defined(nadeDebug):
          echo "DETOUR to pickup at ", p.x, ",", p.y, " role ", bot.role
        target = p
        break

  # Grenade danger: a visible throw-target ring marks where an enemy's lob
  # will land, and an airborne grenade is seconds from bursting — anything
  # inside the blast radius eats 2 of 3 hit points. Fleeing the marked spot
  # outranks every movement goal except nothing: dead carriers drop the run.
  var
    nadeDanger = false
    nadeDangerFrom: Vec
  block nadeDangerScan:
    for label in ["throw target", "grenade air"]:
      for o in client.spriteObjectsWithLabel(label):
        let p = client.mapPos(o)
        if dist(p, me) <= NadeBlast + 18.0:
          nadeDanger = true
          nadeDangerFrom = p
          break nadeDangerScan

  # Turret + locomotion, decided together but on separate buttons: moveMask
  # is the d-pad, desiredAim feeds the rotate buttons, wantFire pulls A.
  var
    moveMask: uint8
    desiredAim = -1
    deadband = CombatDeadband
    wantFire = false
    acted = false
    holdStill = false
    nadeC = false
  if bot.nadeCharge > 0 or nadeAim >= 0:
    # Charge-throw: lay the turret on the lob line, then hold C for the ticks
    # the planned distance needs and release — the grenade leaves along the
    # CURRENT aim on release, so the turret keeps correcting while charging.
    if bot.nadeCharge == 0:
      bot.nadeNeed = max(3, int(float(NadeFullChargeTicks) *
        (nadeThrowD - 30.0) / (NadeMaxRange - 30.0)))
    if nadeAim >= 0:
      desiredAim = nadeAim
    if bot.nadeCharge > 0 or (desiredAim >= 0 and
        abs(bradsErr(desiredAim, bot.estAim)) <= CombatDeadband + 2):
      if bot.nadeCharge < bot.nadeNeed:
        nadeC = true
        inc bot.nadeCharge
      else:
        bot.nadeCharge = 0           # release this tick = the throw
    holdStill = true
    acted = true
  elif hasSword and engage >= 0:
    # Sword melee: the swipe is INSTANT (no windup, no aim lock) and lethal
    # in a +/-45 degree arc at 26 px — close the last step and press A the
    # moment the victim is inside reach and roughly in front.
    desiredAim = bradsOf(aim - me)
    let err = abs(bradsErr(desiredAim, bot.estAim))
    if engageD <= SwordReach and err <= SwordArcBrads - 4:
      wantFire = true
      holdStill = true
    else:
      moveMask = octantBits(aim - me)    # charge in
    acted = true
  elif engage >= 0 and shotReady:
    # Traverse onto the target and fire once the corridor covers it: the
    # perpendicular miss of the current aim error at the target's range must
    # sit inside the ~14px bullet corridor. Advancing scales that miss down
    # linearly, so keep closing while the turret settles.
    desiredAim = bradsOf(aim - me)
    let
      err = abs(bradsErr(desiredAim, bot.estAim))
      perpMiss = engageD * sin(float(err) * PI / float(AimBrads div 2))
    wantFire = perpMiss <= FireSlackPx
    moveMask = octantBits(aim - me)
    acted = true
  elif not iCarry and not rushing and not pocketRush and not shotReady and
      nearThreat >= 0:
    # Cooldown: duck behind the nearest cover that breaks the threat's line
    # and hold there until the gun is back up, keeping the aim (and the
    # vision cone) on the arc the threat would push through.
    let duck = bot.findDuckCell(client, me, bot.enemies[nearThreat].pos)
    if duck >= 0:
      desiredAim = bradsOf(bot.enemies[nearThreat].pos - me)
      if dist(cellCenter(duck), me) < 5.0:
        holdStill = true
      else:
        moveMask = octantBits(cellCenter(duck) - me)
      acted = true
  elif not iCarry and not rushing and shotReady and haveBlocked:
    # Peek: PRE-LAY the aim on the blocked target while stepping sideways to
    # the nearest cell that opens the firing line — the engage branch fires
    # the moment the ray clears, with the traverse already done.
    desiredAim = bradsOf(blockedAim - me)
    let peek = bot.findPeekCell(client, me, blockedAim)
    if peek >= 0 and dist(cellCenter(peek), me) > 4.0:
      moveMask = octantBits(cellCenter(peek) - me)
      acted = true

  if not acted:
    # Threat jink: sidestep a visible enemy that is aiming our way while our
    # own shot is not lined up, instead of walking into its muzzle.
    var threat = -1
    var threatD = ThreatRange
    for i in 0 ..< seenEnemies.len:
      let a = seenEnemies[i]
      let facingMe =
        (a.facingRight and a.pos.x < me.x) or
        (not a.facingRight and a.pos.x > me.x)
      let d = dist(a.pos, me)
      if facingMe and d < threatD:
        threatD = d
        threat = i
    if threat >= 0 and not iCarry and not pocketRush:
      let away = norm(me - seenEnemies[threat].pos)
      var side = vec(-away.y, away.x)
      if (bot.tick div 12 + bot.slot div 2) mod 2 == 0:
        side = side * -1.0
      if not bot.gridRayClear(me, me + side * 24.0):
        side = side * -1.0
      moveMask = octantBits(side + away * 0.4)
      if desiredAim < 0:
        desiredAim = bradsOf(seenEnemies[threat].pos - me)
    elif bot.role in {Overwatch, HomeDefender} and
        dist(me, target) < 6.0:
      # Holding a watch position: the aim carries the vision cone, so sweep
      # it back and forth across the arc threats cross while standing still.
      # While our flag is stolen the thief comes from our own half;
      # otherwise intruders come from the enemy half.
      let watch =
        if ownStolen: vec(homeSign(bot.team), 0.0)
        else: vec(-homeSign(bot.team), 0.0)
      if desiredAim < 0:
        desiredAim = bot.scanAim(watch)
      holdStill = true
    else:
      # Navigate: cover-aware path steering plus soft repulsion from nearby
      # teammates so one burst (or our own shot) cannot hit two of us.
      var steer = norm(bot.navSteer(client, me, target))
      for t in bot.mates:
        if bot.tick - t.lastSeen > 12:
          continue
        let d = dist(t.pos, me)
        if d < MateSpacing and d > 0.5:
          steer = steer + norm(me - t.pos) * ((MateSpacing - d) / MateSpacing) * 0.9
      # Serpentine when a straight run would cross watched ground. Fog cuts
      # both ways: a fresh remembered enemy with a clear pixel line pins
      # anyone, and rushers crossing the contested MIDDLE weave even without
      # intel — the snipers watching their lane are exactly the enemies they
      # cannot see. Close threats are the jink/duck branches' job; carriers
      # and the pocket grab skip it — for them speed beats evasion.
      if not iCarry and not pocketRush:
        var weave = false
        if rushing:
          weave = abs(me.x - float(CenterX)) < WeaveBand
        else:
          for t in bot.enemies:
            if bot.tick - t.lastSeen > UnderFireTrackTtl:
              continue
            let d = dist(t.pos, me)
            if d >= SerpentineNear and d <= SerpentineFar and
                client.pixelRayClear(me, t.pos):
              weave = true
              break
        if weave:
          var side = vec(-steer.y, steer.x)
          if (bot.tick div 8 + bot.slot div 2) mod 2 == 0:
            side = side * -1.0
          steer = norm(steer) + side * 0.6
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      moveMask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        moveMask = bot.jinkBits            # unsticking burst
      if desiredAim < 0:
        # No target demands the turret: the aim leads the movement direction
        # so the vision cone watches down-lane where we are heading. Movement
        # no longer leaks our vision, so this is a choice, not a side effect.
        desiredAim = bradsOf(steer)
        deadband = CruiseDeadband

  # Stuck detection: if we have not moved for a second (and are not holding
  # behind cover on purpose), burst in a random direction and force a repath.
  if dist(me, bot.lastPos) < 0.8:
    inc bot.stuckTicks
  else:
    bot.stuckTicks = 0
  bot.lastPos = me
  if holdStill:
    bot.stuckTicks = 0
  if bot.stuckTicks > 20 and engage < 0:
    bot.stuckTicks = 0
    bot.jinkUntil = bot.tick + 10
    bot.jinkBits = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))
    bot.navGoal = -1
    if bot.jinkBits == 0:
      bot.jinkBits = ButtonUp
    moveMask = bot.jinkBits

  if nadeDanger:
    # Sprint straight out of the marked blast zone; drop any hold/duck.
    let away = me - nadeDangerFrom
    moveMask = octantBits(
      if len(away) < 1.0: vec(homeSign(bot.team), 0.3) else: away
    )
    holdStill = false

  if moveMask == 0 and not holdStill:
    moveMask = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))

  # Rotate toward the desired aim by the shortest arc; inside the deadband
  # (AimRate cannot settle tighter than +-AimRate/2) hold the turret still.
  var rotBits: uint8 = 0
  if desiredAim >= 0:
    let err = bradsErr(desiredAim, bot.estAim)
    if err > deadband:
      rotBits = ButtonB
    elif err < -deadband:
      rotBits = ButtonSelect

  # Only a FRESH A press fires, and the pull locks the aim angle on the same
  # tick — never rotate on the pull tick so the lock takes the settled aim.
  var mask = moveMask or rotBits
  if wantFire and not bot.firedLast:
    mask = moveMask or ButtonA
  if nadeC:
    mask = mask or ButtonC
  bot.firedLast = (mask and ButtonA) != 0
  bot.rotSign =
    if (mask and ButtonB) != 0: 1
    elif (mask and ButtonSelect) != 0: -1
    else: 0
  mask

const ShoutVocab = [
  "go go go", "on me", "help!", "push left", "flank right",
  "got it!", "cover me", "nice!", "regroup", "incoming"
]
  ## A short kid-friendly chatter set. Only emitted when CTF_BOT_SHOUT is set
  ## (fixture recording), so tournament play is unchanged.

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Team.Red else: Team.Blue)
    role = roleForSeat(clamp(slot div 2, 0, 7), team)
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  let
    bot = Bot(slot: slot, team: team, role: role)
    shoutEnabled = getEnv("CTF_BOT_SHOUT").len > 0
  bot.resetTransient()
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
  when defined(taunt):
    startTaunts()                        # worker thread + bank prefetch
  var everConnected = false
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
      everConnected = true
      client.reset()
      bot.navBuilt = false
      bot.resetTransient()
      var lastMask = 0xff'u8
      while true:
        if not client.receiveLatestFrame(ws, false):
          continue
        let advance = max(1, client.frameAdvance)
        bot.tick += advance
        # Dead-reckon the aim: the last sent mask keeps rotating on the
        # server for every elapsed sim tick until we change it.
        bot.estAim = floorMod(
          bot.estAim + bot.rotSign * AimRate * advance, AimBrads)
        if not client.mapCameraReady:
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not bot.navBuilt and client.walkabilityReady:
          bot.buildNavGrid(client)
        let mask = bot.decide(client)
        if mask != lastMask:
          ws.send(inputBlob(mask), BinaryMessage)
          lastMask = mask
        # Fixture-only chatter: shout on a slot-staggered ~2s cadence so a
        # recorded episode carries live shouts to exercise the bubble render.
        if shoutEnabled and
            (bot.tick + bot.slot * 5) mod (2 * 24) < advance:
          let phrase = ShoutVocab[(bot.tick div 48 + bot.slot) mod
            ShoutVocab.len]
          ws.send(chatBlob(phrase), BinaryMessage)
        # Competitive coordination / taunt shouts (compile-gated).
        when defined(shoutCoord) or defined(taunt):
          if bot.shoutWant.len > 0:
            ws.send(chatBlob(bot.shoutWant), BinaryMessage)
            bot.shoutWant = ""
    except Exception as e:
      if everConnected:
        # The game ended and the server went away: exit so the episode
        # runner sees a clean player shutdown.
        echo "game over, exiting: ", e.msg
        quit(0)
      echo "connect retry: ", e.msg
      sleep(250)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
