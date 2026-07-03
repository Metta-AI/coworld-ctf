## Baseline capture-the-flag bot for Coworld CTF (8v8, classic two-flag,
## dense-cover arena).
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The bot keeps a
## persistent world model on top of the partially-observable 128x128 view:
##
## - **Nav grid**: the full walkability mask arrives once at init; we erode it
##   by the player footprint into an 8px cell grid and run a cost field
##   (Dijkstra) to any goal, then follow the path with waypoint lookahead.
## - **Cover model**: walkable cells adjacent to an obstacle are "cover
##   cells". Cells a remembered enemy could shoot into (range + coarse LOS)
##   get a soft path cost, so movement naturally advances cover-to-cover and
##   keeps obstacles between us and known threats.
## - **Flag model** (two flags): each team's flag sits on a pedestal at a
##   STATIC, known position inside its spawn pocket — no arrow is needed to
##   find the enemy pedestal. Only the enemy flag can be stolen, so the
##   "<enemy color> flag" sprite tells us about our own attack (on the
##   pedestal, on me, or on a mate) while the "<my color> flag" sprite plus
##   the "own flag arrow" (present exactly while our flag is stolen and
##   off-screen) tell us about the thief.
## - **Memory**: visible players are tracked across frames (position, velocity,
##   last-seen tick), the enemy flag's last position is remembered, and a
##   thief fix (position + velocity) is kept while our flag is stolen.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid trio
##   (rusher plus two trailing attackers) races lanes to the ENEMY pedestal,
##   two flankers route wide via the extreme top/bottom lanes and hit the
##   pocket from behind, two overwatch snipers hold shielded cover posts whose
##   peek cells own the longest firing lines over mid (both the thief's escape
##   route and the approach to our own pedestal), and one home defender guards
##   the choke before our pedestal. While our flag is stolen the back line
##   (defender + overwatch) hunts the thief along its predicted route to ITS
##   home zone; attackers press on — captures are instant wins both ways, so
##   the race stays on.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, step sideways to the nearest cell
##   that opens the firing line; during the 12-tick cooldown, duck behind the
##   nearest cover that breaks the threat's line and hold until ready.
## - **Fire discipline**: the 1300px gun is effectively map-wide, so any fresh
##   track with a clear pixel ray is engaged out to ~1250px. Steer into the
##   target's octant so the 25-degree cone covers it, lead it slightly, and
##   skip targets with a remembered teammate near the fire axis (friendly fire
##   is on, the server kills the NEAREST player in the cone, and at long range
##   the cone is hundreds of px wide laterally). While a thief runs OUR flag
##   home, the own-flag arrow tracks it globally: fire down a long-open arrow
##   ray to snipe the thief from anywhere on the map.
##
## Coordinate model: objects arrive in screen space and the map object's offset
## is the camera, so mapPos = objectCenter + camera; our own avatar sits at
## exactly (66, 66) on screen (see playerView in src/ctf/sim.nim). Facing ==
## last movement direction and only a fresh A press fires, so to shoot we steer
## toward the target for a frame and pulse A.

import
  std/[algorithm, heapqueue, math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols

const
  WebSocketPath = "/player"
  SelfScreen = 66             # our sprite's exact screen-space center (x and y)
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
  SnipeMinOpen = 300.0        # min open ray for an arrow-guided carrier snipe
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  FireConeCos = 0.88          # cos ~28 deg: the server's 25-deg hit cone plus slack
  LeadTicks = 2.0             # aim this many ticks ahead of a moving enemy
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 12         # only fire at tracks seen this recently; the
                              # wide long-range cone forgives the drift, so
                              # chases keep shooting after the target is gone
  ThiefFixTtl = 40            # a thief position fix guides the chase this long
  FlagMemoryTtl = 168         # trust a remembered enemy-flag spot for ~7s

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
  ExposedCost = 8'i32         # extra cost to enter a threat-exposed cell
  FlankDepth = 260.0          # wide flankers cross this far past mid

  LaneTop = 40.0              # open corridor above the mirrored obstacles
  LaneMid = float(CenterY)
  LaneBottom = 619.0          # open corridor below the mirrored obstacles

type
  Team = enum
    Red, Blue

  Role = enum
    MidTop, MidBottom, MidGuard, FlankTop, FlankBottom,
    OverwatchTop, OverwatchBottom, HomeDefender

  Vec = object                # a map-space point or direction
    x, y: float

  Actor = object              # a player visible this frame
    pos: Vec
    facingRight: bool

  Track = object              # a remembered player
    pos, vel: Vec
    lastSeen: int
    facingRight: bool

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
    enemyFlagPos: Vec         # last place we saw the enemy flag (our prize)
    enemyFlagSeen: int
    carrierPos, carrierVel: Vec   # last fix on the thief carrying OUR flag
    carrierSeen: int
    firedLast: bool           # A was set on the previous sent mask
    lastPos: Vec
    stuckTicks: int
    jinkUntil: int
    jinkBits: uint8

proc roleForSeat(seat: int, team: Team): Role =
  ## Deterministic role spread over the 8 per-team seats. Seats 2 and 3 both
  ## spawn at flag height, but the sim's un-mirrored +-6px spawn offset makes
  ## seat 3 the closest spawn to the flag for Red and seat 2 for Blue — the
  ## rusher takes whichever is closest so we win the opening pickup race.
  case seat
  of 0: FlankBottom      # wide bottom lane, get behind the contest
  of 1: MidGuard         # third mid, trails offset high and cleans up
  of 2: (if team == Blue: MidTop else: MidBottom)
  of 3: (if team == Red: MidTop else: MidBottom)
  of 4: OverwatchTop     # cover post flanking the ring, upper side
  of 5: OverwatchBottom  # cover post flanking the ring, lower side
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

proc octantDir(d: Vec): Vec =
  ## The unit vector of the 8-way direction octantBits picks for `d`: the
  ## facing the sim gives us when we steer that way, hence the true fire axis.
  if d.len() < 1e-6:
    return vec(0, 0)
  let angle = float(int(round(arctan2(d.y, d.x) / (PI / 4)))) * (PI / 4)
  vec(cos(angle), sin(angle))

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

proc selfPos(client: ProtocolClient): Vec =
  ## Our avatar's map position: the camera plus the fixed screen center.
  vec(float(client.mapCameraX + SelfScreen), float(client.mapCameraY + SelfScreen))

proc mapPos(client: ProtocolClient, o: SpriteObjectInfo): Vec =
  ## Map-space center of a screen-space sprite object.
  vec(
    float(o.x + o.width div 2 + client.mapCameraX),
    float(o.y + o.height div 2 + client.mapCameraY)
  )

proc actorsFor(
    client: ProtocolClient, me: Vec, color: string, dropSelf: bool): seq[Actor] =
  ## Visible players of one color in map coordinates plus horizontal facing.
  ## Our own sprite shares our color label, so `dropSelf` filters it out.
  for facingRight in [true, false]:
    let label = "player " & color & (if facingRight: " right" else: " left")
    for o in client.spriteObjectsWithLabel(label):
      let pos = client.mapPos(o)
      if dropSelf and dist(pos, me) <= 3:
        continue
      result.add(Actor(pos: pos, facingRight: facingRight))

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
  if team == Red: 150.0 else: 1085.0

proc enemy(team: Team): Team =
  ## The opposing team.
  if team == Red: Blue else: Red

proc flagHome(team: Team): Vec =
  ## The STATIC pedestal position of one team's flag: the center of the
  ## team's protected spawn pocket (matches flagHome in src/ctf/sim.nim).
  if team == Red: vec(186, 329) else: vec(1049, 329)

proc chokeSpot(team: Team): Vec =
  ## Defender hold point between the flag and our home edge.
  if team == Red: vec(390, 340) else: vec(float(MapW - 390), 340)

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
  ## Chooses our own overwatch post (overwatch seats only): fire from the
  ## peek, duck back to the hold during cooldown.
  bot.postReady = false
  if bot.role notin {OverwatchTop, OverwatchBottom}:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + (if bot.role == OverwatchTop: -60.0 else: 60.0)
  let post = bot.scanPost(client, eSign, wantY)
  if post.ready:
    bot.postHold = post.hold
    bot.postPeek = post.peek
    bot.postReady = true

proc findEnemyPosts(bot: Bot, client: ProtocolClient) =
  ## Precomputes where the ENEMY overwatch snipers sit (the mirrored post
  ## scan): stationary, hidden killers every carrier run has to cross. They
  ## are fed into exposure costing and lane choice as permanent virtual
  ## threats so routes give their firing lanes a wide berth.
  bot.enemyPosts.setLen(0)
  for wantOffset in [-60.0, 60.0]:
    let post = bot.scanPost(client, homeSign(bot.team), float(CenterY) + wantOffset)
    if post.ready:
      bot.enemyPosts.add(post.peek)

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
      claimed[best] = true
    else:
      tracks.add(Track(pos: a.pos, lastSeen: bot.tick, facingRight: a.facingRight))
      claimed.add(true)
  var kept: seq[Track]
  for t in tracks:
    if bot.tick - t.lastSeen <= TrackTtl:
      kept.add(t)
  kept.sort(proc(a, b: Track): int = cmp(b.lastSeen, a.lastSeen))
  if kept.len > TrackCap:                # there are only eight real players
    kept.setLen(TrackCap)
  tracks = kept

proc resetTransient(bot: Bot) =
  ## Drops per-game memory between rounds (lobby / game-over interstitials).
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.enemyFlagPos = flagHome(enemy(bot.team))
  bot.enemyFlagSeen = -100_000
  bot.carrierSeen = -100_000
  bot.firedLast = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1

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
  ## True when a remembered teammate could eat the shot: the server kills the
  ## NEAREST player inside the 25-degree cone around our real 8-way facing,
  ## friend or foe, along the full ray. At long range the cone is huge
  ## laterally (~550px half width at 1250px), so any mate closer than the
  ## target and near the fire axis blocks — 8v8 puts many teammates downrange.
  let dir = octantDir(aim - me)
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
    if along / d >= FireConeCos:
      return true
  false

proc decide(bot: Bot, client: ProtocolClient): uint8 =
  ## Core CTF policy for one frame.
  let
    me = client.selfPos()
    alive = client.spriteObjectsWithLabel("shadow").len > 0
    shotReady = client.spriteObjectsWithLabel("fire icon").len > 0
    myColor = (if bot.team == Red: "red" else: "blue")
    enemyColor = (if bot.team == Red: "blue" else: "red")
    seenEnemies = client.actorsFor(me, enemyColor, dropSelf = false)
    seenMates = client.actorsFor(me, myColor, dropSelf = true)

  # Ghost views show corpses under the same labels; only trust sightings
  # while alive so memory is not poisoned by bodies.
  if alive:
    bot.updateTracks(bot.enemies, seenEnemies)
    bot.updateTracks(bot.mates, seenMates)

  # Flag bookkeeping (two flags; a carried flag rides its carrier's exact
  # position). Only OUR team can hold the enemy flag and only the enemy can
  # hold ours, so the two flag sprites answer different questions: the enemy
  # flag is our attack state (pedestal / on me / on a mate), the own flag is
  # the thief's position.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
    ownFlagStolenSeen = false
  let
    stealTarget = flagHome(enemy(bot.team))  # the enemy pedestal is static
    ownHome = flagHome(bot.team)
    enemyFlags = client.spriteObjectsWithLabel(enemyColor & " flag")
    ownFlags = client.spriteObjectsWithLabel(myColor & " flag")
  if alive and enemyFlags.len > 0:
    let fp = client.mapPos(enemyFlags[0])
    bot.enemyFlagPos = fp
    bot.enemyFlagSeen = bot.tick
    if dist(fp, me) <= 4:
      iCarry = true
    else:
      for a in seenMates:
        if dist(fp, a.pos) <= 8:
          mateCarry = true
          mateCarryPos = a.pos
          break
  if alive and ownFlags.len > 0:
    let fp = client.mapPos(ownFlags[0])
    if dist(fp, ownHome) <= 6:
      bot.carrierSeen = -100_000         # our flag is safely home
    else:
      # The thief holding our flag is right here: take a fresh fix.
      ownFlagStolenSeen = true
      bot.carrierPos = fp
      bot.carrierVel = vec(0, 0)
      for t in bot.enemies:
        if dist(t.pos, fp) <= 8:
          bot.carrierVel = t.vel
          break
      bot.carrierSeen = bot.tick

  if not alive:
    bot.firedLast = false
    return 0                             # dead: inputs are ignored anyway

  # The own-flag arrow exists exactly while our flag is stolen and off-screen,
  # so stolen-ness is fully observable every frame: arrow present, or the own
  # flag visibly off its pedestal.
  let
    ownArrows = client.spriteObjectsWithLabel("own flag arrow")
    enemyArrows = client.spriteObjectsWithLabel("enemy flag arrow")
    ownStolen = ownArrows.len > 0 or ownFlagStolenSeen
  if not ownStolen:
    bot.carrierSeen = -100_000
  # A remembered away-from-pedestal enemy flag means a mate is running it
  # home (only our team can carry it): keep escorting the remembered spot,
  # refreshed by the enemy-flag arrow bearing when it is off-screen.
  if not iCarry and not mateCarry and
      bot.tick - bot.enemyFlagSeen <= FlagMemoryTtl and
      dist(bot.enemyFlagPos, stealTarget) > 16.0:
    mateCarry = true
    mateCarryPos = bot.enemyFlagPos
    if enemyFlags.len == 0 and enemyArrows.len > 0:
      mateCarryPos = me + norm(client.mapPos(enemyArrows[0]) - me) * 180.0

  # Flank progress: sticky so lane-runners do not oscillate at the boundary.
  if bot.role in {FlankTop, FlankBottom}:
    let fwd = -homeSign(bot.team) * (me.x - float(CenterX))
    if fwd >= FlankDepth - 50.0:
      bot.behindLines = true
    elif fwd < 20.0:
      bot.behindLines = false

  # Movement target from role and flag situation.
  var target: Vec
  if iCarry:
    # Run the stolen enemy flag home along the emptiest lane; the exposure
    # cost in the path field keeps the route hugging cover past remembered
    # enemies.
    target = vec(homeDeepX(bot.team), bot.safestLaneY(me))
  elif ownStolen and (bot.role == HomeDefender or
      (bot.role in {OverwatchTop, OverwatchBottom} and
       bot.tick - bot.carrierSeen <= ThiefFixTtl)):
    # The back line intercepts the thief running OUR flag toward ITS home
    # zone; attackers keep pressing the enemy pedestal so the capture race
    # stays on. Pursuit is bounded: with a fresh fix, converge on the
    # predicted route; without one the defender guards the mid crossing the
    # thief has to make and overwatch keeps its long mid lanes plus the
    # arrow snipe — chasing the beacon across the map just feeds the
    # thief's escort wall.
    if bot.tick - bot.carrierSeen <= ThiefFixTtl:
      # Converge on the thief's predicted path toward the enemy capture edge.
      var predicted = bot.carrierPos +
        bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
    else:
      target = vec(float(CenterX) - homeSign(bot.team) * 60.0, LaneMid)
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
    of OverwatchTop, OverwatchBottom:
      # The posts already overwatch the carrier's retreat across mid.
      target =
        if bot.postReady: bot.postHold
        else: mateCarryPos + vec(-homeSign(bot.team) * 32.0, 0.0)
    of HomeDefender:
      target = bot.chokeHold
  elif bot.role == HomeDefender:
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
  elif bot.role in {OverwatchTop, OverwatchBottom}:
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
    if pocketRush: 0.0
    elif iCarry: CarrierFireRange
    elif rushing: RushEngageRange
    elif mateCarry: EscortEngageRange
    else: FireRange
  var
    engage = -1
    engageD = maxEngage
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
    if d >= engageD:
      continue
    if client.pixelRayClear(me, predicted):
      if bot.friendlyBlocked(me, predicted, d):
        continue                        # prefer a target with an empty corridor
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

  var
    mask: uint8
    acted = false
    holdStill = false
  if engage >= 0 and shotReady:
    # Shoot first from max range: steer into the target's octant (facing
    # follows movement) and fire; the mate corridor was checked at selection.
    mask = octantBits(aim - me)
    if not bot.firedLast:
      mask = mask or ButtonA
    acted = true
  elif not iCarry and not rushing and not pocketRush and not shotReady and
      nearThreat >= 0:
    # Cooldown: duck behind the nearest cover that breaks the threat's line
    # and hold there until the gun is back up.
    let duck = bot.findDuckCell(client, me, bot.enemies[nearThreat].pos)
    if duck >= 0:
      if dist(cellCenter(duck), me) < 5.0:
        holdStill = true
      else:
        mask = octantBits(cellCenter(duck) - me)
      acted = true
  elif not iCarry and not rushing and shotReady and haveBlocked:
    # Peek: step sideways to the nearest cell that opens the firing line;
    # the engage branch fires the moment the ray clears.
    let peek = bot.findPeekCell(client, me, blockedAim)
    if peek >= 0 and dist(cellCenter(peek), me) > 4.0:
      mask = octantBits(cellCenter(peek) - me)
      acted = true

  if not acted and shotReady and not bot.firedLast and not iCarry and
      ownArrows.len > 0 and
      bot.role in {HomeDefender, OverwatchTop, OverwatchBottom}:
    # Arrow-guided thief snipe (back line only — attackers keep pressing the
    # pedestal so the capture race stays on): while an enemy runs OUR flag
    # home out of view, the own-flag arrow tracks the carried flag globally
    # and the map-wide gun can reach it. Fire down the arrow ray when it is
    # long-open and no remembered mate is on it — the nearest player on that
    # ray is the thief, and the wide long-range cone forgives the arrow
    # quantization.
    let dir = norm(client.mapPos(ownArrows[0]) - me)
    if dir.len() > 0.5:
      let open = openLineLen(client, me, dir, FireRange, 4.0)
      if open >= SnipeMinOpen and
          not bot.friendlyBlocked(me, me + dir * open, open):
        mask = octantBits(dir) or ButtonA
        acted = true

  if not acted:
    # Threat jink: sidestep a visible enemy that is facing us while our own
    # shot is not lined up, instead of walking into its muzzle.
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
      mask = octantBits(side + away * 0.4)
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
      # Serpentine when a fresh remembered enemy at mid distance has a clear
      # line to us: with map-wide guns a straight run across its lane is
      # lethal. Closer threats are the jink/duck branches' job; rushers and
      # the carrier skip it — for them speed beats evasion.
      if not iCarry and not rushing and not pocketRush:
        for t in bot.enemies:
          if bot.tick - t.lastSeen > UnderFireTrackTtl:
            continue
          let d = dist(t.pos, me)
          if d >= SerpentineNear and d <= SerpentineFar and
              client.pixelRayClear(me, t.pos):
            var side = vec(-steer.y, steer.x)
            if (bot.tick div 8 + bot.slot div 2) mod 2 == 0:
              side = side * -1.0
            steer = norm(steer) + side * 0.6
            break
      steer = steer + vec(rand(-0.12 .. 0.12), rand(-0.12 .. 0.12))
      mask = octantBits(steer)
      if bot.tick < bot.jinkUntil:
        mask = bot.jinkBits                # unsticking burst

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
    mask = bot.jinkBits

  if mask == 0 and not holdStill:
    mask = octantBits(vec(rand(-1.0 .. 1.0), rand(-1.0 .. 1.0)))

  # Only a FRESH A press fires: release for at least one frame between shots.
  if (mask and ButtonA) != 0 and bot.firedLast:
    mask = mask and not ButtonA
  bot.firedLast = (mask and ButtonA) != 0
  mask

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Team.Red else: Team.Blue)
    role = roleForSeat(clamp(slot div 2, 0, 7), team)
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  let bot = Bot(slot: slot, team: team, role: role)
  bot.resetTransient()
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
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
        bot.tick += max(1, client.frameAdvance)
        if not client.mapCameraReady:
          bot.resetTransient()             # lobby / game-over interstitial
          continue
        if not bot.navBuilt and client.walkabilityReady:
          bot.buildNavGrid(client)
        let mask = bot.decide(client)
        if mask != lastMask:
          ws.send(inputBlob(mask), BinaryMessage)
          lastMask = mask
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
