## Scratch attempt a002 — uniform-swarm CTF bot.
##
## Every seat runs this identical policy. No role, no seat-index branching,
## no assigned position: all differentiation comes from local state (where I
## am, what I can see, what I carry). Coordination is emergent — the shared
## goal cascade converges the swarm on the enemy flag wherever it is, which
## produces attack, escort and re-steal camping from one rule.
##
## Drop-in replacement for players/baseline/baseline.nim: same entry point,
## same protocol client, same Dockerfile.

import
  std/[math, monotimes, os, strutils, random],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols,
  ctf/labels

const
  AimTurn = 256                 ## brads per full turn (AimBradsTurn).
  AimRate = 5                   ## brads/tick while a rotate button is held.
  NavCell = 8                   ## navigation grid cell size in map px.
  FootHalf = 6                  ## player footprint half-extent (13px body).
  SprayRange = 120.0            ## engage range when holding the spray can.
  FlagMemoryTicks = 200         ## ~8s memory of a lost flag sighting.
  StuckFrames = 12              ## frames of no motion before sidestep.
  SidestepFrames = 8

type
  Vec = object
    x, y: float

  Sighting = object
    valid: bool
    pos: Vec
    age: int                    ## frames since last seen.

  Nav = object
    ready: bool
    mapW, mapH: int             ## map pixels.
    gw, gh: int                 ## grid cells.
    passable: seq[bool]         ## gw*gh
    dist: seq[int32]            ## BFS distance field from goal, gw*gh.
    goalCell: int               ## cell index the field was built for.
    fieldOk: bool

  Bot = object
    client: ProtocolClient
    ws: WebSocket
    rng: Rand
    # identity
    myColor: string
    enemyColor: string
    # per-frame observation
    alive: bool
    myPos: Vec
    myHp: int
    weaponSpray: bool
    fireReady: bool
    enemies: seq[Vec]           ## visible living enemies (centers).
    mates: seq[Vec]             ## visible living teammates (centers).
    ourFlagCarrierVisible: bool
    ourFlagCarrierPos: Vec
    enemyFlagVisible: bool
    enemyFlagPos: Vec
    enemyFlagPlanted: bool
    iCarry: bool
    # memory (static / decaying)
    ownPedestal: Sighting
    enemyPedestal: Sighting
    enemyFlagSeen: Sighting     ## last place the enemy flag was seen.
    medkits: seq[Vec]           ## remembered static kit spots.
    nav: Nav
    # aim dead-reckoning
    aimEst: int                 ## estimated own aim, brads.
    wasAlive: bool
    # combat bookkeeping
    lastTargetPos: Vec
    lastTargetValid: bool
    prevMask: uint8
    # stuck detection
    lastPos: Vec
    stillFrames: int
    sidestep: int
    sidestepMask: uint8

proc vec(x, y: float): Vec = Vec(x: x, y: y)

proc dist(a, b: Vec): float =
  sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))

proc bradDiff(a, b: int): int =
  ## Shortest signed brad difference a-b in [-128, 127].
  var d = ((a - b) mod AimTurn + AimTurn) mod AimTurn
  if d > AimTurn div 2:
    d -= AimTurn
  d

proc bearingBrads(fromP, toP: Vec): int =
  ## Map coords: 0 = east (+x), brads increase counter-clockwise ON SCREEN,
  ## i.e. 64 = north = -y in pixel coords.
  let ang = arctan2(-(toP.y - fromP.y), toP.x - fromP.x)  # radians, CCW
  var b = int(round(ang * float(AimTurn) / (2.0 * PI)))
  ((b mod AimTurn) + AimTurn) mod AimTurn

# ---------------------------------------------------------------------------
# Navigation: eroded walkability -> coarse grid -> BFS distance field.
# ---------------------------------------------------------------------------

proc buildNav(nav: var Nav, mask: seq[bool], w, h: int) =
  ## Erodes the per-pixel walkability by the player footprint (integral
  ## image), then marks each NavCell cell passable iff its center point can
  ## host the footprint.
  nav.mapW = w
  nav.mapH = h
  nav.gw = max(1, w div NavCell)
  nav.gh = max(1, h div NavCell)
  var integral = newSeq[int32]((w + 1) * (h + 1))
  for y in 0 ..< h:
    var rowSum: int32 = 0
    for x in 0 ..< w:
      if mask[y * w + x]:
        rowSum += 1
      integral[(y + 1) * (w + 1) + (x + 1)] =
        integral[y * (w + 1) + (x + 1)] + rowSum
  proc rectAllWalkable(x0, y0, x1, y1: int): bool =
    ## Inclusive rect fully walkable? Clamped at borders (border = wall,
    ## so clamping shrinks the rect; require the UNclamped area).
    if x0 < 0 or y0 < 0 or x1 >= w or y1 >= h:
      return false
    let area = int32((x1 - x0 + 1) * (y1 - y0 + 1))
    let s = integral[(y1 + 1) * (w + 1) + (x1 + 1)] -
            integral[y0 * (w + 1) + (x1 + 1)] -
            integral[(y1 + 1) * (w + 1) + x0] +
            integral[y0 * (w + 1) + x0]
    s == area
  nav.passable = newSeq[bool](nav.gw * nav.gh)
  for gy in 0 ..< nav.gh:
    for gx in 0 ..< nav.gw:
      let cx = gx * NavCell + NavCell div 2
      let cy = gy * NavCell + NavCell div 2
      nav.passable[gy * nav.gw + gx] =
        rectAllWalkable(cx - FootHalf, cy - FootHalf,
                        cx + FootHalf, cy + FootHalf)
  nav.dist = newSeq[int32](nav.gw * nav.gh)
  nav.goalCell = -1
  nav.fieldOk = false
  nav.ready = true

proc cellOf(nav: Nav, p: Vec): int =
  let gx = clamp(int(p.x) div NavCell, 0, nav.gw - 1)
  let gy = clamp(int(p.y) div NavCell, 0, nav.gh - 1)
  gy * nav.gw + gx

proc nearestPassable(nav: Nav, cell: int, radius: int): int =
  ## The cell itself, or the nearest passable cell within `radius` cells;
  ## -1 when none.
  if nav.passable[cell]:
    return cell
  let cx = cell mod nav.gw
  let cy = cell div nav.gw
  var best = -1
  var bestD = radius * radius + 1
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= nav.gw or ny >= nav.gh:
        continue
      let idx = ny * nav.gw + nx
      if nav.passable[idx] and dx * dx + dy * dy < bestD:
        bestD = dx * dx + dy * dy
        best = idx
  best

proc buildField(nav: var Nav, goal: int) =
  ## BFS distance field toward `goal` over passable cells; diagonals allowed
  ## when both orthogonal neighbors are passable (no corner cutting).
  nav.goalCell = goal
  nav.fieldOk = false
  if goal < 0:
    return
  for i in 0 ..< nav.dist.len:
    nav.dist[i] = int32.high
  var queue = newSeq[int32](nav.dist.len)
  var head = 0
  var tail = 0
  nav.dist[goal] = 0
  queue[tail] = int32(goal)
  inc tail
  while head < tail:
    let cur = int(queue[head])
    inc head
    let cx = cur mod nav.gw
    let cy = cur div nav.gw
    let d = nav.dist[cur]
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        if dx == 0 and dy == 0:
          continue
        let nx = cx + dx
        let ny = cy + dy
        if nx < 0 or ny < 0 or nx >= nav.gw or ny >= nav.gh:
          continue
        let idx = ny * nav.gw + nx
        if not nav.passable[idx] or nav.dist[idx] != int32.high:
          continue
        if dx != 0 and dy != 0:
          # corner rule: both orthogonal steps must be open.
          if not nav.passable[cy * nav.gw + nx] or
             not nav.passable[ny * nav.gw + cx]:
            continue
        nav.dist[idx] = d + 1
        queue[tail] = int32(idx)
        inc tail
  nav.fieldOk = true

proc navStep(bot: var Bot, goal: Vec): uint8 =
  ## Returns a d-pad mask moving one step down the distance field toward
  ## `goal`; greedy direct movement when navigation is unavailable.
  var tx = goal.x
  var ty = goal.y
  if bot.nav.ready:
    let goalCell = nearestPassable(bot.nav, cellOf(bot.nav, goal), 6)
    if goalCell >= 0:
      if goalCell != bot.nav.goalCell or not bot.nav.fieldOk:
        buildField(bot.nav, goalCell)
      if bot.nav.fieldOk:
        let myCell = nearestPassable(bot.nav, cellOf(bot.nav, bot.myPos), 4)
        if myCell >= 0 and bot.nav.dist[myCell] != int32.high and
            bot.nav.dist[myCell] > 0:
          let cx = myCell mod bot.nav.gw
          let cy = myCell div bot.nav.gw
          var bestIdx = myCell
          var bestD = bot.nav.dist[myCell]
          for dy in -1 .. 1:
            for dx in -1 .. 1:
              if dx == 0 and dy == 0:
                continue
              let nx = cx + dx
              let ny = cy + dy
              if nx < 0 or ny < 0 or nx >= bot.nav.gw or ny >= bot.nav.gh:
                continue
              let idx = ny * bot.nav.gw + nx
              if not bot.nav.passable[idx]:
                continue
              if dx != 0 and dy != 0:
                if not bot.nav.passable[cy * bot.nav.gw + nx] or
                   not bot.nav.passable[ny * bot.nav.gw + cx]:
                  continue
              if bot.nav.dist[idx] != int32.high and bot.nav.dist[idx] < bestD:
                bestD = bot.nav.dist[idx]
                bestIdx = idx
          if bestIdx != myCell:
            tx = float((bestIdx mod bot.nav.gw) * NavCell + NavCell div 2)
            ty = float((bestIdx div bot.nav.gw) * NavCell + NavCell div 2)
  result = 0
  let dx = tx - bot.myPos.x
  let dy = ty - bot.myPos.y
  if dx > 2.0: result = result or ButtonRight
  elif dx < -2.0: result = result or ButtonLeft
  if dy > 2.0: result = result or ButtonDown
  elif dy < -2.0: result = result or ButtonUp

# ---------------------------------------------------------------------------
# Observation scan.
# ---------------------------------------------------------------------------

proc rememberMedkit(bot: var Bot, p: Vec) =
  for k in bot.medkits:
    if dist(k, p) < 10.0:
      return
  bot.medkits.add(p)

proc scanFrame(bot: var Bot) =
  ## One pass over the sprite objects into the per-frame observation fields.
  bot.alive = false
  bot.myHp = 3
  bot.weaponSpray = false
  bot.fireReady = false
  bot.enemies.setLen(0)
  bot.mates.setLen(0)
  bot.ourFlagCarrierVisible = false
  bot.enemyFlagVisible = false
  bot.enemyFlagPlanted = false
  bot.iCarry = false
  var ownPlantedSeen = false
  var carriedFlags: seq[tuple[color: string, pos: Vec]] = @[]
  for obj in bot.client.spriteObjects():
    let label = obj.label
    let center = vec(float(obj.x) + float(obj.width) / 2.0,
                     float(obj.y) + float(obj.height) / 2.0)
    if label.startsWith(LabelPrefixSelf):
      bot.alive = true
      bot.myPos = center
      # `self <color> <side>` — color fixes identity on first sight.
      let parts = label.split(' ')
      if parts.len >= 2 and bot.myColor.len == 0:
        bot.myColor = parts[1]
    elif label.startsWith(LabelPrefixPlayer):
      # `player <color> <side>` — corpses use their own prefix, never here.
      let parts = label.split(' ')
      if parts.len >= 2:
        if bot.myColor.len > 0 and parts[1] == bot.myColor:
          bot.mates.add(center)
        else:
          bot.enemies.add(center)
          if bot.enemyColor.len == 0 and parts[1] != bot.myColor:
            bot.enemyColor = parts[1]
    elif label == LabelFireIcon:
      bot.fireReady = true
    elif label == LabelMedKit:
      bot.rememberMedkit(center)
    elif label.startsWith(LabelPrefixLives):
      # `lives <hp>hp x<lives>` — leading int is my effective hp.
      let tail = label[LabelPrefixLives.len .. ^1]
      var hp = 0
      var i = 0
      while i < tail.len and tail[i] in {'0' .. '9'}:
        hp = hp * 10 + (ord(tail[i]) - ord('0'))
        inc i
      if i > 0:
        bot.myHp = hp
    elif label.startsWith(LabelPrefixWeapon):
      bot.weaponSpray = label == labelWeapon(LabelWeaponSpray)
    elif label.endsWith(" flag planted"):
      # `<color> flag planted` — pedestals are fog-exempt, so these pin the
      # map's key points from the very first frame.
      let color = label.split(' ')[0]
      if bot.myColor.len > 0 and color == bot.myColor:
        ownPlantedSeen = true
        bot.ownPedestal = Sighting(valid: true, pos: center, age: 0)
      elif bot.myColor.len > 0:
        bot.enemyPedestal = Sighting(valid: true, pos: center, age: 0)
        bot.enemyFlagVisible = true
        bot.enemyFlagPlanted = true
        bot.enemyFlagPos = center
        bot.enemyFlagSeen = Sighting(valid: true, pos: center, age: 0)
    elif label.endsWith(" flag"):
      # `<color> flag` — a CARRIED flag, centered on its carrier.
      carriedFlags.add((color: label.split(' ')[0], pos: center))
  # Carried flags need self identity resolved first.
  for cf in carriedFlags:
    if bot.myColor.len == 0:
      continue
    if cf.color == bot.myColor:
      # Our flag riding an enemy: the thief is exactly there.
      if not ownPlantedSeen:
        bot.ourFlagCarrierVisible = true
        bot.ourFlagCarrierPos = cf.pos
    else:
      bot.enemyFlagVisible = true
      bot.enemyFlagPos = cf.pos
      bot.enemyFlagSeen = Sighting(valid: true, pos: cf.pos, age: 0)
      if bot.alive and dist(cf.pos, bot.myPos) < 14.0:
        bot.iCarry = true

proc rayClear(bot: Bot, a, b: Vec): bool =
  ## Walkability-mask raycast: an approximate bullet LOS (walls and glass are
  ## unwalkable and block shots; pits are walkable and do not).
  if not bot.client.walkabilityReady:
    return true
  let w = bot.client.walkabilityWidth
  let h = bot.client.walkabilityHeight
  let d = dist(a, b)
  if d < 1.0:
    return true
  let steps = int(d / 4.0) + 1
  for i in 1 ..< steps:
    let t = float(i) / float(steps)
    let x = int(a.x + (b.x - a.x) * t)
    let y = int(a.y + (b.y - a.y) * t)
    if x < 0 or y < 0 or x >= w or y >= h:
      return false
    if not bot.client.walkabilityMask[y * w + x]:
      return false
  true

proc mateInCorridor(bot: Bot, target: Vec): bool =
  ## True when a VISIBLE teammate stands inside the bullet corridor between
  ## me and the target (friendly fire is on).
  let d = dist(bot.myPos, target)
  if d < 1.0:
    return false
  let ux = (target.x - bot.myPos.x) / d
  let uy = (target.y - bot.myPos.y) / d
  for m in bot.mates:
    let px = m.x - bot.myPos.x
    let py = m.y - bot.myPos.y
    let along = px * ux + py * uy
    if along <= 0.0 or along >= d:
      continue
    let perp = abs(px * uy - py * ux)
    if perp < 16.0:
      return true
  false

# ---------------------------------------------------------------------------
# Decision: one identical rule set per frame.
# ---------------------------------------------------------------------------

proc pickGoal(bot: var Bot): Vec =
  ## The uniform goal cascade (see DESIGN.md).
  if bot.iCarry and bot.ownPedestal.valid:
    return bot.ownPedestal.pos
  if bot.myHp <= 1 and bot.medkits.len > 0:
    var best = bot.medkits[0]
    var bestD = dist(bot.myPos, best)
    for k in bot.medkits:
      if dist(bot.myPos, k) < bestD:
        bestD = dist(bot.myPos, k)
        best = k
    if bestD < 400.0:
      return best
  if bot.ourFlagCarrierVisible:
    return bot.ourFlagCarrierPos
  if bot.enemyFlagVisible:
    return bot.enemyFlagPos
  if bot.enemyFlagSeen.valid and bot.enemyFlagSeen.age < FlagMemoryTicks:
    return bot.enemyFlagSeen.pos
  if bot.enemyPedestal.valid:
    return bot.enemyPedestal.pos
  if bot.nav.ready:
    return vec(float(bot.nav.mapW) / 2.0, float(bot.nav.mapH) / 2.0)
  vec(bot.myPos.x, bot.myPos.y)

proc decide(bot: var Bot): uint8 =
  ## Produces this frame's input mask.
  if not bot.alive:
    return 0
  let goal = bot.pickGoal()
  var mask = bot.navStep(goal)

  # Stuck detection: wanting to move but not moving -> brief sidestep.
  let moved = dist(bot.myPos, bot.lastPos)
  if bot.sidestep > 0:
    dec bot.sidestep
    mask = (mask and not uint8(ButtonUp or ButtonDown or ButtonLeft or
      ButtonRight)) or bot.sidestepMask
  elif (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0:
    if moved < 2.0:
      inc bot.stillFrames
      if bot.stillFrames >= StuckFrames:
        bot.stillFrames = 0
        bot.sidestep = SidestepFrames
        # Perpendicular-ish random jiggle.
        let horiz = (mask and (ButtonLeft or ButtonRight)) != 0
        if horiz:
          bot.sidestepMask = if bot.rng.rand(1) == 0: ButtonUp else: ButtonDown
        else:
          bot.sidestepMask = if bot.rng.rand(1) == 0: ButtonLeft else: ButtonRight
    else:
      bot.stillFrames = 0
  else:
    bot.stillFrames = 0
  bot.lastPos = bot.myPos

  # --- Combat reflex (aim is decoupled from the d-pad) ---
  var haveTarget = false
  var target: Vec
  if bot.ourFlagCarrierVisible:
    target = bot.ourFlagCarrierPos
    haveTarget = true
  elif bot.enemies.len > 0:
    target = bot.enemies[0]
    var bestD = dist(bot.myPos, target)
    for e in bot.enemies:
      if dist(bot.myPos, e) < bestD:
        bestD = dist(bot.myPos, e)
        target = e
    haveTarget = true

  var desiredAim: int
  if haveTarget:
    # Linear lead: target velocity x (rotate time + windup + latency).
    var aimPoint = target
    if bot.lastTargetValid and dist(target, bot.lastTargetPos) < 60.0:
      let vx = target.x - bot.lastTargetPos.x
      let vy = target.y - bot.lastTargetPos.y
      let rotTicks = abs(bradDiff(bearingBrads(bot.myPos, target),
        bot.aimEst)) div AimRate
      let lead = float(min(rotTicks, 20) + 5 + 2)
      aimPoint = vec(target.x + vx * lead, target.y + vy * lead)
    bot.lastTargetPos = target
    bot.lastTargetValid = true
    desiredAim = bearingBrads(bot.myPos, aimPoint)
    let d = dist(bot.myPos, target)
    # Alignment tolerance: lateral corridor slack (~10px) at the target's
    # range, floored at 3 brads (rotation quantum is 5).
    let tol = max(3, int(float(AimTurn) / (2.0 * PI) * 10.0 / max(d, 30.0)))
    let diff = bradDiff(desiredAim, bot.aimEst)
    let rangeOk = if bot.weaponSpray: d <= SprayRange else: true
    if abs(diff) <= tol and bot.fireReady and rangeOk and
        rayClear(bot, bot.myPos, target) and
        not mateInCorridor(bot, target) and
        (bot.prevMask and ButtonA) == 0:
      # Pull the trigger this frame; no rotation, so the locked aim matches
      # the estimate exactly.
      mask = mask or ButtonA
      return mask
    if abs(diff) > tol:
      if diff > 0:
        mask = mask or ButtonB          # counter-clockwise
      else:
        mask = mask or ButtonSelect     # clockwise
    return mask
  else:
    bot.lastTargetValid = false
    # No target: look where I am going so the vision cone leads the path.
    let moveDx = (if (mask and ButtonRight) != 0: 1.0
                  elif (mask and ButtonLeft) != 0: -1.0 else: 0.0)
    let moveDy = (if (mask and ButtonDown) != 0: 1.0
                  elif (mask and ButtonUp) != 0: -1.0 else: 0.0)
    if moveDx != 0.0 or moveDy != 0.0:
      desiredAim = bearingBrads(vec(0, 0), vec(moveDx, moveDy))
      let diff = bradDiff(desiredAim, bot.aimEst)
      if abs(diff) > 6:
        if diff > 0:
          mask = mask or ButtonB
        else:
          mask = mask or ButtonSelect
    return mask

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------

proc spawnAim(bot: Bot): int =
  ## On (re)spawn the aim points toward the enemy side: Red -> east (0),
  ## Blue -> west (128). Generated 4-team layouts differ, but red/blue sides
  ## hold for the league maps; drift correction handles the rest.
  if bot.myColor == "blue": AimTurn div 2 else: 0

proc updateAimEstimate(bot: var Bot) =
  ## Dead-reckon own aim: the last sent mask was applied for (approximately)
  ## every frame that advanced since the previous receive.
  let frames = bot.client.frameAdvance
  let b = (bot.prevMask and ButtonB) != 0
  let s = (bot.prevMask and ButtonSelect) != 0
  if b and not s:
    bot.aimEst = ((bot.aimEst + AimRate * frames) mod AimTurn + AimTurn) mod AimTurn
  elif s and not b:
    bot.aimEst = ((bot.aimEst - AimRate * frames) mod AimTurn + AimTurn) mod AimTurn

proc correctAimFromSide(bot: var Bot) =
  ## The self label's coarse side is derived from TRUE aim: right <=> not
  ## (64 < brad < 192) (of the 16-step rotation bucket). When the estimate
  ## contradicts it by a margin, snap to the nearest side boundary.
  var side = ""
  for obj in bot.client.spriteObjects():
    if obj.label.startsWith(LabelPrefixSelf):
      let parts = obj.label.split(' ')
      if parts.len >= 3:
        side = parts[2]
      break
  if side.len == 0:
    return
  let estLeft = bot.aimEst > AimTurn div 4 and bot.aimEst < AimTurn * 3 div 4
  let obsLeft = side == LabelSideLeft
  if estLeft != obsLeft:
    # Only correct when clearly inside the wrong half (avoid boundary noise).
    let d64 = abs(bradDiff(bot.aimEst, AimTurn div 4))
    let d192 = abs(bradDiff(bot.aimEst, AimTurn * 3 div 4))
    if min(d64, d192) > 12:
      bot.aimEst = if d64 < d192: AimTurn div 4 else: AimTurn * 3 div 4

proc runBot*(rawUrl: string) =
  var endpoint = ensureWsPath(rawUrl, "/player")
  endpoint = playerConnectUrl(
    endpoint,
    getEnv("COWORLD_PLAYER_NAME", "baseline"),
    getEnv("COWORLD_PLAYER_TOKEN", ""),
    try: parseInt(getEnv("COWORLD_PLAYER_SLOT", "-1")) except ValueError: -1
  )
  var bot = Bot(
    client: initProtocolClient(),
    rng: initRand(int64(getMonoTime().ticks) xor int64(getCurrentProcessId()))
  )
  bot.ws = newWebSocket(endpoint)
  while true:
    var gotFrame = false
    try:
      gotFrame = bot.client.receiveLatestFrame(bot.ws, gui = false)
    except CatchableError:
      break                       # connection closed: episode over.
    if not gotFrame:
      continue
    updateAimEstimate(bot)
    scanFrame(bot)
    # Navigation grid builds once the walkability sprite has arrived.
    if not bot.nav.ready and bot.client.walkabilityReady:
      buildNav(bot.nav, bot.client.walkabilityMask,
               bot.client.walkabilityWidth, bot.client.walkabilityHeight)
    # Memory ages with sim ticks, not loop iterations.
    if bot.enemyFlagSeen.valid:
      bot.enemyFlagSeen.age += bot.client.frameAdvance
    # Respawn (or first spawn): aim is known exactly.
    if bot.alive and not bot.wasAlive:
      bot.aimEst = bot.spawnAim()
      bot.stillFrames = 0
      bot.sidestep = 0
      bot.lastTargetValid = false
      bot.lastPos = bot.myPos
    bot.wasAlive = bot.alive
    if bot.alive:
      correctAimFromSide(bot)
    let mask = bot.decide()
    try:
      bot.ws.send(inputBlob(mask), BinaryMessage)
    except CatchableError:
      break
    bot.prevMask = mask

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
