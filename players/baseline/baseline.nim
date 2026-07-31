## a004 — from-scratch CTF bot, stance: ATTRITION.
##
## Combat economy before objective: six pickets hold a line just our side of
## the midline (cover-snapped, strafe-dodging, med-kit health cycling), two
## raiders convert only when the enemy provably cannot contest (witnessed
## corpses / quiet field / sound late-clock state). Drop-in replacement for
## players/baseline/baseline.nim: same entry point, protocol client and
## Dockerfile.

import
  std/[math, os, random, strutils, tables],
  whisky,
  ctf/labels,
  baseline/protocols

const
  # Input mask bits (Sprite v1 + CTF C button; see docs/PROTOCOL.md).
  BtnUp = 1'u8
  BtnDown = 2'u8
  BtnLeft = 4'u8
  BtnRight = 8'u8
  BtnSelect = 16'u8   # aim clockwise (decreasing brads)
  BtnA = 32'u8        # fire (edge-triggered)
  BtnB = 64'u8        # aim counter-clockwise (increasing brads)

  AimTurnRate = 5           # brads per tick while a rotate button is held
  BradsTurn = 256
  Cell = 13                 # nav grid cell size in px
  MaxEngageDist = 650.0     # do not fire beyond this
  WindupTicks = 5.0         # aim locks at pull; bullet leaves 5 ticks later
  PushTick = 3300           # clock-hedge conversion trigger
  QuietTicks = 500          # "quiet field" window
  KitTakenTicks = 30 * 24   # med-kit respawn interval
  StrafeHalfSpan = 30.0     # picket dodge amplitude around the post

type
  PointF = object
    x, y: float

  Mode = enum
    modeBoot, modePicket, modeHeal, modeHunt, modeRaid, modeCarry

  Kit = object
    x, y: float
    takenUntil: int

  TrackedEnemy = object
    x, y: float
    vx, vy: float
    lastSeen: int

  Bot = object
    client: ProtocolClient
    ws: WebSocket
    tick: int               # our own monotonically increasing tick estimate
    lastMask: uint8
    # identity / world
    myColor: string         # "red" / "blue" (latched at first self sighting)
    enemyColor: string
    roleIdx: int            # 0..5 picket, 6..7 raider (-1 until latched)
    haveSelf: bool
    selfWasAbsent: bool
    sx, sy: float           # self center
    prevSx, prevSy: float
    selfSide: string        # "left"/"right" token from self label
    aim: int                # dead-reckoned brads
    aimDir: int             # -1 CW, 0, +1 CCW: what we told the server last
    hp: int
    lives: int
    weaponSpray: bool
    mapW, mapH: int
    ourPed: PointF
    enemyPed: PointF
    havePeds: bool
    ourPlantedPresent: bool
    enemyPlantedPresent: bool
    carrying: bool
    ourFlagSeenAt: PointF   # enemy carrier of OUR flag (valid when set this frame)
    ourFlagSeen: bool
    mateCarrying: bool
    kits: seq[Kit]
    enemies: seq[TrackedEnemy]     # freshly matched this frame
    prevEnemies: seq[TrackedEnemy]
    mates: seq[PointF]
    fireReady: bool
    # nav
    gw, gh: int
    walk: seq[bool]         # static walkable cells
    tempBlock: Table[int, int]  # cell -> expiry tick (stuck / diamonds)
    dist: seq[int32]        # BFS distance field toward current goal
    goalCell: int
    lastFlood: int
    # behaviour state
    mode: Mode
    post: PointF
    postReady: bool
    lineAdvance: float      # 0 = base line, positive pushes toward enemy
    strafeSign: float
    strafeFlip: int
    stuckRefX, stuckRefY: float
    stuckSince: int
    moveIntent: bool
    jiggleUntil: int
    jiggleMask: uint8
    lastEnemySeen: int      # tick of most recent enemy sighting
    raidLatch: bool         # a triggered raid persists for the life
    corpseKills: int        # witnessed enemy corpses (dominance proxy)
    corpseMarks: seq[tuple[x, y: float, at: int]]
    lastHp: int
    hurtAt: int
    rng: Rand

proc pt(x, y: float): PointF = PointF(x: x, y: y)

proc dist2(ax, ay, bx, by: float): float =
  (ax - bx) * (ax - bx) + (ay - by) * (ay - by)

# ---------------------------------------------------------------- navigation

proc cellIdx(b: Bot, cx, cy: int): int = cy * b.gw + cx

proc cellOf(b: Bot, x, y: float): tuple[cx, cy: int] =
  result.cx = clamp(int(x) div Cell, 0, b.gw - 1)
  result.cy = clamp(int(y) div Cell, 0, b.gh - 1)

proc buildGrid(b: var Bot) =
  ## Static walkable grid from the walkability mask: a cell is walkable when
  ## its center pixel is walkable and most of its pixels are.
  b.mapW = b.client.walkabilityWidth
  b.mapH = b.client.walkabilityHeight
  b.gw = (b.mapW + Cell - 1) div Cell
  b.gh = (b.mapH + Cell - 1) div Cell
  b.walk = newSeq[bool](b.gw * b.gh)
  for cy in 0 ..< b.gh:
    for cx in 0 ..< b.gw:
      var total = 0
      var ok = 0
      for py in countup(cy * Cell, min((cy + 1) * Cell - 1, b.mapH - 1), 3):
        for px in countup(cx * Cell, min((cx + 1) * Cell - 1, b.mapW - 1), 3):
          inc total
          if b.client.walkabilityMask[py * b.mapW + px]:
            inc ok
      let mx = min(cx * Cell + Cell div 2, b.mapW - 1)
      let my = min(cy * Cell + Cell div 2, b.mapH - 1)
      b.walk[b.cellIdx(cx, cy)] =
        total > 0 and ok * 10 >= total * 7 and
        b.client.walkabilityMask[my * b.mapW + mx]
  b.dist = newSeq[int32](b.gw * b.gh)
  b.goalCell = -1

proc blocked(b: Bot, idx: int): bool =
  if not b.walk[idx]:
    return true
  b.tempBlock.getOrDefault(idx, -1) > b.tick

proc flood(b: var Bot, gx, gy: int) =
  ## BFS distance field from the goal cell over walkable, unblocked cells.
  for i in 0 ..< b.dist.len:
    b.dist[i] = int32.high
  var q = newSeq[int]()
  let g = b.cellIdx(gx, gy)
  b.dist[g] = 0
  q.add(g)
  var head = 0
  while head < q.len:
    let cur = q[head]
    inc head
    let cx = cur mod b.gw
    let cy = cur div b.gw
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        if dx == 0 and dy == 0:
          continue
        let nx = cx + dx
        let ny = cy + dy
        if nx < 0 or nx >= b.gw or ny < 0 or ny >= b.gh:
          continue
        # forbid diagonal corner-cutting
        if dx != 0 and dy != 0:
          if b.blocked(b.cellIdx(cx + dx, cy)) or
             b.blocked(b.cellIdx(cx, cy + dy)):
            continue
        let ni = b.cellIdx(nx, ny)
        if b.blocked(ni) or b.dist[ni] != int32.high:
          continue
        b.dist[ni] = b.dist[cur] + 1
        q.add(ni)
  b.goalCell = g
  b.lastFlood = b.tick

proc nearestWalkable(b: Bot, x, y: float): tuple[cx, cy: int] =
  var (cx, cy) = b.cellOf(x, y)
  if not b.blocked(b.cellIdx(cx, cy)):
    return (cx, cy)
  for r in 1 .. 8:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let nx = cx + dx
        let ny = cy + dy
        if nx < 0 or nx >= b.gw or ny < 0 or ny >= b.gh:
          continue
        if not b.blocked(b.cellIdx(nx, ny)):
          return (nx, ny)
  (cx, cy)

proc markDiamonds(b: var Bot) =
  ## The spinning centre diamonds are real geometry not present in the static
  ## walkability bake: block the cells under each visible "diamond" object
  ## for a short window (they are re-marked every frame while visible).
  for obj in b.client.spriteObjectsWithLabel("diamond"):
    let x0 = obj.x
    let y0 = obj.y
    let x1 = obj.x + obj.width
    let y1 = obj.y + obj.height
    var cy = y0 div Cell
    while cy * Cell <= y1:
      var cx = x0 div Cell
      while cx * Cell <= x1:
        if cx >= 0 and cx < b.gw and cy >= 0 and cy < b.gh:
          b.tempBlock[b.cellIdx(cx, cy)] = b.tick + 12
        inc cx
      inc cy

proc navMask(b: var Bot, target: PointF): uint8 =
  ## Button mask stepping toward a target point via the BFS field.
  let d2 = dist2(b.sx, b.sy, target.x, target.y)
  if d2 <= 26.0 * 26.0:
    # close: press straight at it (handles pedestal touch, kit touch)
    var m: uint8 = 0
    if target.x < b.sx - 3: m = m or BtnLeft
    elif target.x > b.sx + 3: m = m or BtnRight
    if target.y < b.sy - 3: m = m or BtnUp
    elif target.y > b.sy + 3: m = m or BtnDown
    return m
  let (gx, gy) = b.nearestWalkable(target.x, target.y)
  let g = b.cellIdx(gx, gy)
  if g != b.goalCell or b.tick - b.lastFlood > 8:
    b.flood(gx, gy)
  let (cx, cy) = b.cellOf(b.sx, b.sy)
  var best = int32.high
  var bx = cx
  var by = cy
  let ci = b.cellIdx(cx, cy)
  if b.dist[ci] != int32.high:
    best = b.dist[ci]
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if dx == 0 and dy == 0:
        continue
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or nx >= b.gw or ny < 0 or ny >= b.gh:
        continue
      if dx != 0 and dy != 0:
        if b.blocked(b.cellIdx(cx + dx, cy)) or
           b.blocked(b.cellIdx(cx, cy + dy)):
          continue
      let ni = b.cellIdx(nx, ny)
      if b.dist[ni] < best:
        best = b.dist[ni]
        bx = nx
        by = ny
  if best == int32.high:
    # unreachable: walk straight-line and let stuck recovery cope
    var m: uint8 = 0
    if target.x < b.sx - 3: m = m or BtnLeft
    elif target.x > b.sx + 3: m = m or BtnRight
    if target.y < b.sy - 3: m = m or BtnUp
    elif target.y > b.sy + 3: m = m or BtnDown
    return m
  if bx == cx and by == cy:
    return 0
  let tx = float(bx * Cell + Cell div 2)
  let ty = float(by * Cell + Cell div 2)
  var m: uint8 = 0
  if tx < b.sx - 2: m = m or BtnLeft
  elif tx > b.sx + 2: m = m or BtnRight
  if ty < b.sy - 2: m = m or BtnUp
  elif ty > b.sy + 2: m = m or BtnDown
  m

# ------------------------------------------------------------------- parsing

proc centerOf(o: SpriteObjectInfo): PointF =
  pt(float(o.x) + float(o.width) / 2.0, float(o.y) + float(o.height) / 2.0)

proc identityName(label, color: string): string =
  ## "identity <color> <name>[ shield][ nade] <weapon>" -> <name>
  let parts = label.split(' ')
  if parts.len >= 3 and parts[0] == "identity" and parts[1] == color:
    return parts[2]
  ""

const IdentityOrder = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]

proc scanFrame(b: var Bot) =
  ## One pass over the sprite objects: self, enemies, mates, flags, kits, HUD.
  b.haveSelf = false
  b.enemies.setLen(0)
  b.mates.setLen(0)
  b.fireReady = false
  b.ourFlagSeen = false
  var selfIdentityCand = ""
  var selfIdentityD2 = 1e18
  var enemyPlantedSeen = false
  var ourPlantedSeen = false
  var enemyCarriedFlag: PointF
  var enemyCarriedSeen = false
  var corpsesNow: seq[PointF] = @[]

  for obj in b.client.spriteObjects:
    let label = obj.label
    if label.startsWith(LabelPrefixSelf):
      # "self <color> <side>"
      let parts = label.split(' ')
      if parts.len >= 3:
        if b.myColor.len == 0:
          b.myColor = parts[1]
          b.enemyColor = (if b.myColor == "red": "blue" else: "red")
        b.selfSide = parts[2]
      b.haveSelf = true
      b.prevSx = b.sx
      b.prevSy = b.sy
      let c = centerOf(SpriteObjectInfo(
        objectId: obj.objectId, x: obj.x, y: obj.y,
        width: obj.width, height: obj.height))
      b.sx = c.x
      b.sy = c.y
    elif label == LabelFireIcon:
      b.fireReady = true
    elif label.startsWith(LabelPrefixLives):
      # "lives <hp>hp x<lives>"
      let parts = label.split(' ')
      if parts.len >= 3:
        let hpTok = parts[1]
        if hpTok.endsWith("hp"):
          try: b.hp = parseInt(hpTok[0 ..< hpTok.len - 2]) except ValueError: discard
        let lvTok = parts[2]
        if lvTok.len >= 2 and lvTok[0] == 'x':
          try: b.lives = parseInt(lvTok[1 .. ^1]) except ValueError: discard
    elif label.startsWith(LabelPrefixWeapon):
      b.weaponSpray = label == labelWeapon(LabelWeaponSpray)
    elif label == LabelMedKit:
      let c = pt(float(obj.x) + float(obj.width) / 2.0,
                 float(obj.y) + float(obj.height) / 2.0)
      var known = false
      for k in b.kits.mitems:
        if dist2(k.x, k.y, c.x, c.y) < 30.0 * 30.0:
          known = true
          k.takenUntil = 0        # visible => available
      if not known:
        b.kits.add(Kit(x: c.x, y: c.y, takenUntil: 0))

  # second pass for things that need myColor resolved
  if b.myColor.len == 0:
    return
  for obj in b.client.spriteObjects:
    let label = obj.label
    let c = pt(float(obj.x) + float(obj.width) / 2.0,
               float(obj.y) + float(obj.height) / 2.0)
    if label.startsWith(LabelPrefixPlayer):
      let parts = label.split(' ')
      if parts.len >= 2:
        if parts[1] == b.enemyColor:
          var e = TrackedEnemy(x: c.x, y: c.y, lastSeen: b.tick)
          # match against previous frame for a velocity estimate
          var bestD = 40.0 * 40.0
          for p in b.prevEnemies:
            let d = dist2(p.x, p.y, c.x, c.y)
            if d < bestD:
              bestD = d
              let dt = float(max(1, b.tick - p.lastSeen))
              e.vx = (c.x - p.x) / dt
              e.vy = (c.y - p.y) / dt
          b.enemies.add(e)
          b.lastEnemySeen = b.tick
        elif parts[1] == b.myColor:
          # includes our own sprite; exclude by distance to self
          if not b.haveSelf or dist2(c.x, c.y, b.sx, b.sy) > 12.0 * 12.0:
            b.mates.add(c)
    elif label.startsWith(LabelPrefixCorpse):
      let parts = label.split(' ')
      if parts.len >= 2 and parts[1] == b.enemyColor:
        corpsesNow.add(c)
    elif label == labelFlagPlanted(b.enemyColor):
      enemyPlantedSeen = true
      if not b.havePeds:
        # the planted banner is bottom-anchored on the pedestal: the true
        # flag point is its bottom-center (2px up), NOT the sprite center
        b.enemyPed = pt(float(obj.x) + float(obj.width) / 2.0,
                        float(obj.y) + float(obj.height) - 2.0)
    elif label == labelFlagPlanted(b.myColor):
      ourPlantedSeen = true
      if not b.havePeds:
        b.ourPed = pt(float(obj.x) + float(obj.width) / 2.0,
                      float(obj.y) + float(obj.height) - 2.0)
    elif label == labelFlag(b.enemyColor):
      enemyCarriedSeen = true
      enemyCarriedFlag = c
    elif label == labelFlag(b.myColor):
      b.ourFlagSeen = true
      b.ourFlagSeenAt = c
    elif label.startsWith(LabelPrefixIdentity) and b.haveSelf:
      let nm = identityName(label, b.myColor)
      if nm.len > 0:
        let d = dist2(c.x, c.y, b.sx, b.sy)
        if d < 20.0 * 20.0 and d < selfIdentityD2:
          selfIdentityD2 = d
          selfIdentityCand = nm

  if not b.havePeds and enemyPlantedSeen and ourPlantedSeen:
    b.havePeds = true
  b.ourPlantedPresent = ourPlantedSeen
  b.enemyPlantedPresent = enemyPlantedSeen

  # carrying: the enemy flag banner rides its carrier
  b.carrying = enemyCarriedSeen and b.haveSelf and
    dist2(enemyCarriedFlag.x, enemyCarriedFlag.y, b.sx, b.sy) < 16.0 * 16.0
  b.mateCarrying = enemyCarriedSeen and not b.carrying

  # role latch
  if b.roleIdx < 0 and selfIdentityCand.len > 0:
    let i = IdentityOrder.find(selfIdentityCand)
    if i >= 0:
      b.roleIdx = i

  # witnessed-kill proxy: a corpse we have not counted near here recently
  for c in corpsesNow:
    var novel = true
    for m in b.corpseMarks:
      if b.tick - m.at < 240 and dist2(m.x, m.y, c.x, c.y) < 40.0 * 40.0:
        novel = false
        break
    if novel:
      b.corpseMarks.add((x: c.x, y: c.y, at: b.tick))
      inc b.corpseKills
  if b.corpseMarks.len > 64:
    b.corpseMarks.delete(0)

  # damage tell
  if b.hp < b.lastHp:
    b.hurtAt = b.tick
  b.lastHp = b.hp

# ---------------------------------------------------------------------- aim

proc angleTo(fromX, fromY, toX, toY: float): int =
  ## Map-space brads: 0 = east, increasing counter-clockwise ON SCREEN, i.e.
  ## with y growing downward, CCW-on-screen means angle = atan2(-(dy), dx).
  var a = arctan2(-(toY - fromY), toX - fromX) * (float(BradsTurn) / (2 * PI))
  var r = int(round(a))
  ((r mod BradsTurn) + BradsTurn) mod BradsTurn

proc aimErr(cur, want: int): int =
  ## Signed shortest rotation from cur to want, in brads (-128..127).
  var d = (want - cur) mod BradsTurn
  if d > BradsTurn div 2: d -= BradsTurn
  if d < -(BradsTurn div 2): d += BradsTurn
  d

proc losClear(b: Bot, ax, ay, bx2, by2: float): bool =
  ## Walkability ray-march: unwalkable pixels approximate bullet blockers
  ## (glass is unwalkable => correctly refused; pits are walkable => pass).
  if b.mapW == 0:
    return false
  let d = sqrt(dist2(ax, ay, bx2, by2))
  if d < 1.0:
    return true
  let steps = int(d / 4.0) + 1
  for i in 1 ..< steps:
    let t = float(i) / float(steps)
    let x = int(ax + (bx2 - ax) * t)
    let y = int(ay + (by2 - ay) * t)
    if x < 0 or x >= b.mapW or y < 0 or y >= b.mapH:
      return false
    if not b.client.walkabilityMask[y * b.mapW + x]:
      return false
  true

proc mateInLane(b: Bot, tx, ty: float): bool =
  ## Refuse the shot when a teammate sits near the segment self->target.
  let dx = tx - b.sx
  let dy = ty - b.sy
  let len2 = dx * dx + dy * dy
  if len2 < 1.0:
    return false
  for m in b.mates:
    let t = ((m.x - b.sx) * dx + (m.y - b.sy) * dy) / len2
    if t < 0.02 or t > 0.98:
      continue
    let px = b.sx + t * dx
    let py = b.sy + t * dy
    if dist2(m.x, m.y, px, py) < 18.0 * 18.0:
      return true
  false

# ----------------------------------------------------------------- behaviour

proc basePost(b: Bot, idx: int): PointF =
  ## Picket posts: spread over map height at a line slightly our side of mid,
  ## advanced by lineAdvance toward the enemy. Raiders (6,7) take the flanks.
  let w = float(b.mapW)
  let h = float(b.mapH)
  let dir = (if b.enemyPed.x > b.ourPed.x: 1.0 else: -1.0)
  var lineX = w / 2.0 - dir * w * 0.10 + dir * b.lineAdvance * w
  lineX = clamp(lineX, w * 0.06, w * 0.94)
  case idx
  of 0 .. 5:
    pt(lineX, h * float(idx + 1) / 7.0)
  of 6:
    pt(lineX, h * 0.12)
  else:
    pt(lineX, h * 0.88)

proc coverSnap(b: var Bot, p: PointF): PointF =
  ## Snap a post to a walkable cell, preferring one with stone toward the
  ## enemy side (a wall neighbour 1-2 cells enemy-ward = cover to duck).
  let dirX = (if b.enemyPed.x > b.ourPed.x: 1 else: -1)
  let (cx, cy) = b.nearestWalkable(p.x, p.y)
  var bestScore = -1
  var bestC = (cx, cy)
  for dy in -4 .. 4:
    for dx in -4 .. 4:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 1 or nx >= b.gw - 1 or ny < 1 or ny >= b.gh - 1:
        continue
      if b.blocked(b.cellIdx(nx, ny)):
        continue
      var score = 10 - abs(dx) - abs(dy)
      for step in 1 .. 2:
        let wx = nx + dirX * step
        if wx >= 0 and wx < b.gw and not b.walk[b.cellIdx(wx, ny)]:
          score += 6
          break
      if score > bestScore:
        bestScore = score
        bestC = (nx, ny)
  pt(float(bestC[0] * Cell + Cell div 2), float(bestC[1] * Cell + Cell div 2))

proc nearestKit(b: Bot): int =
  result = -1
  var best = 1e18
  for i, k in b.kits:
    if k.takenUntil > b.tick:
      continue
    let d = dist2(b.sx, b.sy, k.x, k.y)
    if d < best:
      best = d
      result = i

proc chooseMode(b: var Bot) =
  if not b.havePeds:
    b.mode = modeBoot
    return
  if b.carrying:
    b.mode = modeCarry
    return
  if b.hp <= 1 and b.nearestKit() >= 0:
    b.mode = modeHeal
    return
  let isRaider = b.roleIdx >= 6
  if not b.ourPlantedPresent and not (isRaider and b.raidLatch):
    b.mode = modeHunt
    return
  # conversion triggers (attrition: only from strength). A triggered raid
  # LATCHES for the rest of the life: the trigger decides to launch the
  # push, it is not a condition the push must keep satisfying (an enemy
  # sighted en route must not bounce the raider back to his post).
  let quiet = b.tick - b.lastEnemySeen > QuietTicks and b.tick > 1200
  let dominance = b.corpseKills >= 6 and b.tick > 2000
  let clockHedge = b.tick >= PushTick and b.lives >= 2 and
    (b.tick - b.hurtAt > 240)
  if isRaider and (quiet or dominance or clockHedge):
    b.raidLatch = true
  if isRaider and b.raidLatch:
    b.mode = modeRaid
    return
  # pickets creep with the same evidence, raiders otherwise hold flanks
  if quiet or dominance:
    b.lineAdvance = 0.22
  elif b.mateCarrying:
    b.lineAdvance = -0.06
  else:
    b.lineAdvance = 0.0
  b.mode = modePicket

proc tickBot(b: var Bot): uint8 =
  ## One frame -> one input mask. Never raises.
  let fa = max(1, b.client.frameAdvance)
  b.tick += fa

  # settle the aim estimate for the rotation we held since last frame
  b.aim = ((b.aim + b.aimDir * AimTurnRate * fa) mod BradsTurn +
           BradsTurn) mod BradsTurn

  if b.walk.len == 0:
    if b.client.walkabilityReady:
      b.buildGrid(  )
    else:
      return 0

  b.markDiamonds()
  let hadSelf = b.haveSelf
  b.scanFrame()
  b.prevEnemies = b.enemies

  if not b.haveSelf:
    # dead or lobby: keep the seat alive, remember to re-seed the aim
    b.selfWasAbsent = true
    b.aimDir = 0
    return 0

  if b.selfWasAbsent or not hadSelf:
    # first sighting after spawn/respawn: aim reset toward the enemy side
    b.aim = (if b.myColor == "red": 0 else: BradsTurn div 2)
    b.aimDir = 0
    b.selfWasAbsent = false
    b.raidLatch = false
    b.stuckRefX = b.sx
    b.stuckRefY = b.sy
    b.stuckSince = b.tick

  # coarse mirror-correction from our own sprite's side token
  if b.selfSide == LabelSideLeft or b.selfSide == LabelSideRight:
    let facingLeft = b.aim > BradsTurn div 4 and b.aim < BradsTurn * 3 div 4
    let margin = min(
      abs(b.aim - BradsTurn div 4), abs(b.aim - BradsTurn * 3 div 4))
    if margin > 12:
      if facingLeft and b.selfSide == LabelSideRight:
        b.aim = ((BradsTurn div 2 - b.aim) mod BradsTurn + BradsTurn) mod
          BradsTurn
      elif (not facingLeft) and b.selfSide == LabelSideLeft:
        b.aim = ((BradsTurn div 2 - b.aim) mod BradsTurn + BradsTurn) mod
          BradsTurn

  b.chooseMode()

  # ------------------------------------------------------------- movement
  var target: PointF
  var holdAtTarget = false
  case b.mode
  of modeBoot:
    target = pt(b.sx, b.sy)
    holdAtTarget = true
  of modeCarry:
    target = b.ourPed
  of modeHeal:
    let ki = b.nearestKit()
    target = (if ki >= 0: pt(b.kits[ki].x, b.kits[ki].y) else: b.ourPed)
  of modeHunt:
    if b.ourFlagSeen:
      target = b.ourFlagSeenAt
    else:
      # intercept station between our pedestal and the midline, spread by role
      let f = 0.30
      let baseY = float(b.mapH) *
        float((if b.roleIdx >= 0: b.roleIdx else: 3) + 1) / 9.0
      target = pt(
        b.ourPed.x + (float(b.mapW) / 2.0 - b.ourPed.x) * f, baseY)
      target = b.coverSnap(target)
  of modeRaid:
    if b.enemyPlantedPresent:
      target = b.enemyPed
    else:
      target = b.basePost(b.roleIdx)   # someone has it; fall back to post
  of modePicket:
    if not b.postReady or b.tick mod 96 == 0:
      b.post = b.coverSnap(b.basePost(max(0, b.roleIdx)))
      b.postReady = true
    target = b.post
    holdAtTarget = true

  var mask: uint8 = 0
  let atTarget = dist2(b.sx, b.sy, target.x, target.y) < 10.0 * 10.0
  let engaged = b.enemies.len > 0

  if holdAtTarget and atTarget and engaged:
    # strafe-dodge around the post, perpendicular to the nearest enemy
    var ei = 0
    var best = 1e18
    for i, e in b.enemies:
      let d = dist2(b.sx, b.sy, e.x, e.y)
      if d < best:
        best = d
        ei = i
    let e = b.enemies[ei]
    let dx = e.x - b.sx
    let dy = e.y - b.sy
    let len = max(1.0, sqrt(dx * dx + dy * dy))
    if b.tick > b.strafeFlip:
      b.strafeFlip = b.tick + 16
      if b.rng.rand(1.0) < 0.5 or b.tick - b.hurtAt < 8:
        b.strafeSign = -b.strafeSign
    if b.strafeSign == 0:
      b.strafeSign = 1
    let px = -dy / len * b.strafeSign
    let py = dx / len * b.strafeSign
    # stay near the post
    if dist2(b.sx + px * 20, b.sy + py * 20, b.post.x, b.post.y) >
        StrafeHalfSpan * StrafeHalfSpan:
      b.strafeSign = -b.strafeSign
    if px < -0.3: mask = mask or BtnLeft
    elif px > 0.3: mask = mask or BtnRight
    if py < -0.3: mask = mask or BtnUp
    elif py > 0.3: mask = mask or BtnDown
    b.moveIntent = false
  elif holdAtTarget and atTarget:
    b.moveIntent = false
  else:
    mask = b.navMask(target)
    b.moveIntent = mask != 0

  # stuck recovery (only while trying to move)
  if b.moveIntent:
    if dist2(b.sx, b.sy, b.stuckRefX, b.stuckRefY) > 6.0 * 6.0:
      b.stuckRefX = b.sx
      b.stuckRefY = b.sy
      b.stuckSince = b.tick
    elif b.tick - b.stuckSince > 24 and b.tick > b.jiggleUntil:
      # mark the cell ahead blocked briefly and jiggle
      let (cx, cy) = b.cellOf(b.sx, b.sy)
      var fx = cx
      var fy = cy
      if (mask and BtnLeft) != 0: dec fx
      if (mask and BtnRight) != 0: inc fx
      if (mask and BtnUp) != 0: dec fy
      if (mask and BtnDown) != 0: inc fy
      if fx >= 0 and fx < b.gw and fy >= 0 and fy < b.gh:
        b.tempBlock[b.cellIdx(fx, fy)] = b.tick + 72
      b.goalCell = -1                      # force reflood
      b.jiggleUntil = b.tick + 12
      b.jiggleMask = uint8(1 shl b.rng.rand(3))
      b.stuckSince = b.tick
  else:
    b.stuckRefX = b.sx
    b.stuckRefY = b.sy
    b.stuckSince = b.tick
  if b.tick < b.jiggleUntil:
    mask = b.jiggleMask

  # --------------------------------------------------------------- combat
  var wantAim = -1
  var mayFire = false
  if b.enemies.len > 0:
    # target: enemy carrying OUR flag first, else nearest
    var ti = -1
    if b.ourFlagSeen:
      var best = 1e18
      for i, e in b.enemies:
        let d = dist2(e.x, e.y, b.ourFlagSeenAt.x, b.ourFlagSeenAt.y)
        if d < 20.0 * 20.0 and d < best:
          best = d
          ti = i
    if ti < 0:
      var best = 1e18
      for i, e in b.enemies:
        let d = dist2(b.sx, b.sy, e.x, e.y)
        if d < best:
          best = d
          ti = i
    let e = b.enemies[ti]
    let edist = sqrt(dist2(b.sx, b.sy, e.x, e.y))
    let maxRange = (if b.weaponSpray: 120.0 else: MaxEngageDist)
    if edist <= maxRange:
      # lead the target and compensate our own release drift (5-tick windup)
      let svx = (b.sx - b.prevSx) / float(fa)
      let svy = (b.sy - b.prevSy) / float(fa)
      let rx = b.sx + svx * WindupTicks
      let ry = b.sy + svy * WindupTicks
      let tx = e.x + e.vx * WindupTicks
      let ty = e.y + e.vy * WindupTicks
      wantAim = angleTo(rx, ry, tx, ty)
      let err = aimErr(b.aim, wantAim)
      # rotation control
      let step = AimTurnRate * fa
      if abs(err) > step div 2 + 1:
        b.aimDir = (if err > 0: 1 else: -1)
      else:
        b.aimDir = 0
      # fire gate
      var tol = int(570.0 / max(40.0, edist))
      tol = clamp(tol, 3, 14)
      if b.fireReady and abs(err) <= max(tol, step div 2 + 1) and
          b.losClear(b.sx, b.sy, e.x, e.y) and
          not b.mateInLane(e.x, e.y) and
          (b.lastMask and BtnA) == 0:
        mayFire = true
    else:
      wantAim = angleTo(b.sx, b.sy, e.x, e.y)
      let err = aimErr(b.aim, wantAim)
      b.aimDir = (if abs(err) > 6: (if err > 0: 1 else: -1) else: 0)
  else:
    # no target: sweep the cone across the threat half (triangle wave)
    var baseAim: int
    case b.mode
    of modeHunt:
      baseAim = angleTo(b.sx, b.sy, float(b.mapW) / 2.0, float(b.mapH) / 2.0)
    of modeCarry:
      baseAim = angleTo(b.sx, b.sy, b.enemyPed.x, b.enemyPed.y)  # watch back
    else:
      baseAim = angleTo(b.sx, b.sy, b.enemyPed.x, b.enemyPed.y)
    let phase = b.tick mod 192
    let wob = (if phase < 96: phase - 48 else: 144 - phase)  # -48..48
    wantAim = ((baseAim + wob) mod BradsTurn + BradsTurn) mod BradsTurn
    let err = aimErr(b.aim, wantAim)
    b.aimDir = (if abs(err) > 8: (if err > 0: 1 else: -1) else: 0)

  if b.aimDir > 0:
    mask = mask or BtnB
  elif b.aimDir < 0:
    mask = mask or BtnSelect
  if mayFire:
    mask = mask or BtnA

  mask

# ---------------------------------------------------------------- main loop

proc runBot(url: string) =
  var b = Bot(
    client: initProtocolClient(),
    roleIdx: -1,
    rng: initRand(20260731),
    tempBlock: initTable[int, int]())
  b.lastHp = 3
  b.hp = 3
  b.lives = 3
  b.strafeSign = 1.0
  let endpoint = ensureWsPath(url, "/player")
  b.ws = newWebSocket(endpoint)
  while true:
    var ok = false
    try:
      ok = b.client.receiveLatestFrame(b.ws, false)
    except CatchableError:
      break                       # socket closed: episode over
    if not ok:
      break
    var mask: uint8 = 0
    try:
      mask = b.tickBot()
    except CatchableError:
      mask = 0                    # never miss a tick, whatever broke
    try:
      b.ws.send(inputBlob(mask), BinaryMessage)
      b.lastMask = mask
    except CatchableError:
      break

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
