## Baseline capture-the-flag bot for Coworld CTF (8v8, dense-cover arena).
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
## - **Memory**: visible players are tracked across frames (position, velocity,
##   last-seen tick), the flag's last position is remembered, and an enemy
##   carrier sighting is trusted for a few seconds after it leaves view.
## - **Roles** (deterministic from the per-team seat, 8 seats): a mid trio
##   (rusher plus two trailing attackers) races and contests the flag, two
##   flankers route wide via the extreme top/bottom lanes to get behind the
##   enemy contest, two overwatch bots hold shielded cover posts with peek
##   cells flanking the flag ring, and one home defender guards the choke
##   before our capture column. A stale enemy-carrier sighting sends everyone
##   who knows to the enemy capture gate to cut the run off.
## - **Peek-and-shoot**: the default combat mode. With the gun up and a
##   remembered enemy blocked by a wall, step sideways to the nearest cell
##   that opens the firing line; during the 12-tick cooldown, duck behind the
##   nearest cover that breaks the threat's line and hold until ready.
## - **Fire discipline**: the 260px gun vastly outranges the 128px view, so
##   fresh tracks are engaged out to ~250px. Steer into the target's octant so
##   the 25-degree cone covers it, lead it slightly, and hold fire when a
##   remembered teammate sits anywhere in the corridor (friendly fire is on,
##   one hit kills, and 8v8 puts many teammates downrange).
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

  FireRange = 250.0           # engage distance (gun range is 260)
  CarrierFireRange = 110.0    # while carrying, only shoot enemies this close
  ThreatRange = 200.0         # react to an enemy this close facing us
  MateSpacing = 40.0          # soft repulsion radius between teammates
  CorridorHalfWidth = 15.0    # friendly-fire corridor half width along the ray
  ConeBlockCos = 0.866        # cos 30 deg: a closer mate in this cone blocks
  LeadTicks = 2.0             # aim this many ticks ahead of a moving enemy
  TrackMatchDist = 40.0       # a sighting matches a track within this distance
  TrackTtl = 120              # forget a player not seen for ~5s
  TrackCap = 8                # eight real opponents / teammates per side
  FreshShotTicks = 8          # only fire at tracks seen this recently
  CarryTtl = 240              # trust an enemy-carrier sighting for ~10s (a
                              # carrier's run home takes about that long)
  FlagMemoryTtl = 168         # trust a remembered flag spot for ~7s

  CoverShieldDist = 42.0      # an obstacle this close blocks a threat direction
  PeekLineDist = 150.0        # open px an overwatch peek firing line needs
  DuckSearchCells = 3         # duck-cell search radius in nav cells
  PeekSearchCells = 3         # peek-cell search radius in nav cells
  ExposureRange = 260.0       # enemy gun range used for exposure costing
  ExposureThreats = 3         # cost only the freshest few remembered threats
  ExposureTrackTtl = 60       # only cost threats remembered this recently
  StepCost = 5'i32            # orthogonal move cost in the nav field
  DiagCost = 7'i32            # ~sqrt(2) * StepCost
  ExposedCost = 6'i32         # extra cost to enter a threat-exposed cell
  BehindFlagDist = 120.0      # flankers stage this far past the flag first
  InterceptGateX = 390.0      # camp distance past mid: the enemy capture gate
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
    chokeHold: Vec            # defender hold point snapped to cover
    behindLines: bool         # flanker has crossed deep into the enemy half
    enemies: seq[Track]
    mates: seq[Track]
    flagPos: Vec              # last place we saw the flag
    flagSeen: int
    carrierPos, carrierVel: Vec   # last enemy-carrier sighting
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

proc homeSign(team: Team): float =
  ## -1 toward Red's home edge (left), +1 toward Blue's (right).
  if team == Red: -1.0 else: 1.0

proc homeDeepX(team: Team): float =
  ## A point well inside our capture zone (Red x <= ~206, Blue x >= ~1029).
  if team == Red: 150.0 else: 1085.0

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

proc pickPost(bot: Bot, client: ProtocolClient) =
  ## Chooses the overwatch post: a cover cell on our side of mid whose
  ## obstacle shields it from the enemy half, with a sideways peek cell that
  ## owns a long firing line across the mid lane. Fire from the peek, duck
  ## back to the hold during cooldown.
  bot.postReady = false
  if bot.role notin {OverwatchTop, OverwatchBottom}:
    return
  let
    eSign = -homeSign(bot.team)
    wantY = float(CenterY) + (if bot.role == OverwatchTop: -60.0 else: 60.0)
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
        continue                         # our side of the ring, hugging it
      if rayClearCoarse(client, p, p + vec(eSign * CoverShieldDist, 0.0), 4.0):
        continue                         # nothing shields us from the front
      var
        peek: Vec
        havePeek = false
      for dyc in [-2, 2, -1, 1]:
        let ny = cy + dyc
        if ny < 0 or ny >= GridH or not bot.cellWalkable[ny * GridW + cx]:
          continue
        let q = cellCenter(ny * GridW + cx)
        if rayClearCoarse(client, q, q + vec(eSign * PeekLineDist, 0.0), 6.0):
          peek = q
          havePeek = true
          break
      if not havePeek:
        continue
      let score = abs(p.y - wantY) + abs(fwd + 90.0) * 0.7
      if score < bestScore:
        bestScore = score
        bot.postHold = p
        bot.postPeek = peek
        bot.postReady = true

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
  bot.chokeHold = bot.snapToCover(chokeSpot(bot.team))
  bot.navBuilt = true

const NavNeighbors = [
  (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)
]

proc rebuildExposure(bot: Bot, client: ProtocolClient) =
  ## Marks nav cells the freshest remembered enemies could shoot into
  ## (inside gun range with a coarsely-clear line). Used as a soft path cost.
  for i in 0 ..< bot.exposure.len:
    bot.exposure[i] = false
  var threats = 0
  for t in bot.enemies:                  # already sorted freshest-first
    if threats >= ExposureThreats or bot.tick - t.lastSeen > ExposureTrackTtl:
      break
    inc threats
    let
      x0 = max(0, int(t.pos.x - ExposureRange) div NavCell)
      x1 = min(GridW - 1, int(t.pos.x + ExposureRange) div NavCell)
      y0 = max(0, int(t.pos.y - ExposureRange) div NavCell)
      y1 = min(GridH - 1, int(t.pos.y + ExposureRange) div NavCell)
    for cy in y0 .. y1:
      for cx in x0 .. x1:
        let c = cy * GridW + cx
        if bot.exposure[c] or not bot.cellWalkable[c]:
          continue
        let p = cellCenter(c)
        if dist(p, t.pos) <= ExposureRange and
            rayClearCoarse(client, t.pos, p, 8.0):
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
  bot.flagSeen = -100_000
  bot.carrierSeen = -100_000
  bot.firedLast = false
  bot.stuckTicks = 0
  bot.jinkUntil = 0
  bot.behindLines = false
  bot.navGoal = -1

proc safestLaneY(bot: Bot, me: Vec): float =
  ## The lane with the fewest remembered enemies between us and home.
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
    if score < bestScore:
      bestScore = score
      bestLane = lane
  bestLane

proc friendlyBlocked(bot: Bot, me, aim: Vec, enemyDist: float): bool =
  ## True when a remembered teammate could eat the shot: the server kills the
  ## nearest player inside the 25-degree cone, friend or foe, along the full
  ## 260px ray — and 8v8 puts many teammates downrange.
  let dir = norm(aim - me)
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
    if along < enemyDist + 14.0 and
        abs(cross(rel, dir)) < CorridorHalfWidth + age * 0.35:
      return true
    if d < enemyDist + 6.0 and dot(rel, dir) / d >= ConeBlockCos:
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

  # Flag bookkeeping: a carried flag rides its carrier's exact position.
  var
    iCarry = false
    mateCarry = false
    mateCarryPos: Vec
  let flags = client.spriteObjectsWithLabel("flag")
  if flags.len > 0:
    let fp = client.mapPos(flags[0])
    bot.flagPos = fp
    bot.flagSeen = bot.tick
    if alive and dist(fp, me) <= 4:
      iCarry = true
    else:
      for a in seenMates:
        if dist(fp, a.pos) <= 8:
          mateCarry = true
          mateCarryPos = a.pos
          break
      var enemyCarry = false
      if not mateCarry:
        for a in seenEnemies:
          if dist(fp, a.pos) <= 8:
            bot.carrierPos = a.pos
            bot.carrierVel = vec(0, 0)
            for t in bot.enemies:
              if dist(t.pos, a.pos) <= 4:
                bot.carrierVel = t.vel
                break
            bot.carrierSeen = bot.tick
            enemyCarry = true
            break
      if iCarry or mateCarry or not enemyCarry:
        bot.carrierSeen = -100_000       # we saw the flag; no enemy holds it

  if not alive:
    bot.firedLast = false
    return 0                             # dead: inputs are ignored anyway

  let
    enemyCarryKnown = bot.tick - bot.carrierSeen <= CarryTtl
    flagKnown = bot.tick - bot.flagSeen <= FlagMemoryTtl
    arrows = client.spriteObjectsWithLabel("flag arrow")
  var flagTarget = vec(float(CenterX), float(CenterY))
  if flagKnown:
    flagTarget = bot.flagPos
  elif arrows.len > 0:
    flagTarget = me + norm(client.mapPos(arrows[0]) - me) * 180.0

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
    # Run home along the emptiest lane; the exposure cost in the path field
    # keeps the route hugging cover past remembered enemies.
    target = vec(homeDeepX(bot.team), bot.safestLaneY(me))
  elif enemyCarryKnown:
    if bot.tick - bot.carrierSeen > 40:
      # The carrier is long out of view and running home: cut it off at its
      # capture gate (a fixed choke) instead of chasing a fading prediction.
      target = vec(float(CenterX) - homeSign(bot.team) * InterceptGateX, LaneMid)
    else:
      # Converge on the carrier's predicted path toward their capture edge.
      var predicted = bot.carrierPos +
        bot.carrierVel * float(18 + bot.tick - bot.carrierSeen)
      predicted.x += -homeSign(bot.team) * 40.0
      target = vec(clamp(predicted.x, 20.0, float(MapW - 20)),
                   clamp(predicted.y, 20.0, float(MapH - 20)))
  elif mateCarry:
    case bot.role
    of MidTop, FlankTop:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, -30.0)
    of MidBottom, FlankBottom:
      target = mateCarryPos + vec(homeSign(bot.team) * 46.0, 30.0)
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
    # Hold the choke; break off for a loose flag or an intruder on our half.
    let flagOnOurHalf =
      if bot.team == Red: flagTarget.x < float(CenterX) + 40
      else: flagTarget.x > float(CenterX) - 40
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
    if flagKnown and flagOnOurHalf:
      target = flagTarget
    elif intruder >= 0:
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
    # Attackers: the lead rusher races the flag dead straight (its seat
    # spawns at flag height), the second mid trails behind and offset so one
    # enemy cone cannot kill the pair; flankers run the extreme lanes deep
    # past mid, then hit the flag contest from behind.
    target = flagTarget
    case bot.role
    of MidBottom:
      if dist(me, flagTarget) > 90:
        target = flagTarget + vec(homeSign(bot.team) * 34.0, 26.0)
    of MidGuard:
      if dist(me, flagTarget) > 90:
        target = flagTarget + vec(homeSign(bot.team) * 60.0, -26.0)
    of FlankTop, FlankBottom:
      let laneY = (if bot.role == FlankTop: LaneTop else: LaneBottom)
      if not bot.behindLines and dist(me, flagTarget) > 170.0:
        target = vec(float(CenterX) - homeSign(bot.team) * FlankDepth, laneY)
      else:
        # Behind lines: stage on the enemy side of the flag so the attack
        # comes from the octant the contesters are facing away from.
        let stage = flagTarget + vec(-homeSign(bot.team) * BehindFlagDist, 0.0)
        if dist(me, flagTarget) > 150.0 and dist(me, stage) > 60.0:
          target = stage
    else:
      discard

  # Combat: the nearest recently-seen enemy with a clear pixel ray is the
  # engage target; the nearest fresh-but-wall-blocked track is the peek
  # candidate. The gun outranges the view, so fresh off-screen tracks count.
  var
    engage = -1
    engageD = (if iCarry: CarrierFireRange else: FireRange)
    aim: Vec
    blockedAim: Vec
    haveBlocked = false
    blockedD = FireRange
  for i in 0 ..< bot.enemies.len:
    let t = bot.enemies[i]
    if bot.tick - t.lastSeen > FreshShotTicks:
      continue
    let predicted = t.pos + t.vel * (float(bot.tick - t.lastSeen) + LeadTicks)
    let d = dist(predicted, me)
    if d >= engageD:
      continue
    if client.pixelRayClear(me, predicted):
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
    nearThreatD = ThreatRange + 60.0
  for i in 0 ..< bot.enemies.len:
    if bot.tick - bot.enemies[i].lastSeen > 30:
      continue
    let d = dist(bot.enemies[i].pos, me)
    if d < nearThreatD:
      nearThreatD = d
      nearThreat = i

  # The mid pair plays for the flag, not for position: pickup races and
  # carrier chases are lost to peek/duck detours, so mids keep moving and
  # shoot on the move whenever a mate is not already carrying.
  let rushing = not iCarry and not mateCarry and
    bot.role in {MidTop, MidBottom, MidGuard}

  var
    mask: uint8
    acted = false
    holdStill = false
  if engage >= 0 and shotReady:
    # Shoot first from max range: steer into the target's octant (facing
    # follows movement) and fire when no teammate is in the corridor.
    mask = octantBits(aim - me)
    if not bot.firedLast and not bot.friendlyBlocked(me, aim, engageD):
      mask = mask or ButtonA
    acted = true
  elif not iCarry and not rushing and not shotReady and nearThreat >= 0:
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
    if threat >= 0 and not iCarry:
      let away = norm(me - seenEnemies[threat].pos)
      var side = vec(-away.y, away.x)
      if (bot.tick div 12 + bot.slot) mod 2 == 0:
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
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
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
      echo "disconnected: ", e.msg
      sleep(250)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
