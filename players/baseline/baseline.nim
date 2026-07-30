## Scratch attempt a001 — role-squad CTF bot, written from a blank file.
##
## Stance: deterministic role specialisation from the seat index. Each of the
## eight seats has a standing job (runner / escort / second-runner / defender /
## keeper / two interceptors / grenadier-rover) keyed off the identity badge
## letter (alpha..theta). Coordination is implicit in the role assignment:
## nobody negotiates at runtime, everyone trusts the others to do their jobs.
##
## Shared core under every role: parse frame -> navigate (BFS over the eroded
## walkability mask) -> shoot what is visible and reachable -> never miss a
## tick. Roles only change WHERE a bot stands and how eagerly it engages.
##
## Drop-in replacement for players/baseline/baseline.nim: same protocol client,
## same Dockerfile, same entry point.

import
  std/[math, os, strutils, tables],
  bitworld/spriteprotocol,
  whisky,
  ctf/labels,
  baseline/protocols

const
  AimTurn = 256                 ## brads per full turn.
  AimRate = 5                   ## brads/tick while a rotate button is held.
  NavCell = 6                   ## px per navigation grid cell.
  PlayerHalfPx = 6              ## solid footprint half-extent (13px box).
  FireWindupTicks = 5
  GrenadeMinRange = 30.0
  GrenadeMaxRange = 247.0       ## map width 1235 / 5 on the default arena.
  GrenadeChargeTicks = 24
  SeatNames = ["alpha", "beta", "gamma", "delta",
               "epsilon", "zeta", "eta", "theta"]

type
  Role = enum
    roleRunner        ## seat 0: steal the enemy heart, capture it.
    roleEscort        ## seat 1: push the enemy pedestal, kill defenders.
    roleRunner2       ## seat 2: second runner, bottom route.
    roleDefender      ## seat 3: guard own pedestal.
    roleKeeper        ## seat 4: shield + hold the capture-zone mouth.
    roleIntTop        ## seat 5: top midfield interceptor.
    roleIntBot        ## seat 6: bottom midfield interceptor.
    roleRover         ## seat 7: grenadier, roams the middle.

  Pt = tuple[x, y: float]

  SeenPlayer = object
    x, y: float
    color: string

  Frame = object
    hasSelf: bool
    selfX, selfY: float
    selfSideRight: bool
    myColor: string
    enemies: seq[SeenPlayer]
    mates: seq[SeenPlayer]          ## visible teammates, self excluded.
    planted: Table[string, Pt]      ## color -> pedestal flag point.
    carriedFlags: Table[string, Pt] ## color -> carried banner center.
    medKits: seq[Pt]
    shields: seq[Pt]
    sprayCans: seq[Pt]
    grenades: seq[Pt]
    fireReady: bool
    weaponSpray: bool
    hp: int
    lives: int
    seatName: string
    haveShield: bool
    haveNade: bool

  Bot = object
    client: ProtocolClient
    # dead-reckoned aim
    aimEst: int
    lastRotDir: int               ## -1 CW, 0, +1 CCW (sent last frame).
    wasAlive: bool
    faceMismatch: int
    faceFixCooldown: int
    # navigation
    navReady: bool
    navW, navH: int               ## grid dims.
    mapW, mapH: int               ## map pixel dims.
    navWalk: seq[bool]            ## eroded, per grid cell.
    dist: seq[int32]              ## BFS distance field toward goal.
    distGoal: tuple[cx, cy: int]
    distAge: int
    # persistent knowledge
    pedestals: Table[string, Pt]  ## color -> pedestal point (static).
    knownKits: seq[Pt]
    knownShieldSpots: seq[Pt]
    knownNadeSpots: seq[Pt]
    myColor: string
    seat: int
    role: Role
    ourFlagLastSeen: Pt
    ourFlagSeenAge: int
    # per-life state
    tick: int
    lastX, lastY: float
    stuckTicks: int
    jigglingTicks: int
    jiggleDir: int
    windupLeft: int               ## ticks left where our shot is in flight-lock.
    windupTarget: Pt
    chargeTicks: int              ## grenade charge progress; 0 = not charging.
    chargeGoal: int
    nadeCooldown: int
    healCooldown: int
    strafePhase: int
    prevMaskA: bool

# ---------------------------------------------------------------------------
# small math helpers
# ---------------------------------------------------------------------------

proc angDiff(a, b: int): int =
  ## Shortest signed distance from b to a in brads, in [-128, 128).
  result = (a - b) mod AimTurn
  if result < -AimTurn div 2: result += AimTurn
  if result >= AimTurn div 2: result -= AimTurn

proc bearingBrads(fromX, fromY, toX, toY: float): int =
  ## Map-coordinate bearing in brads: 0 = east, 64 = north (-y), CCW.
  let rad = arctan2(-(toY - fromY), toX - fromX)
  result = int(round(rad * float(AimTurn) / (2.0 * PI))) mod AimTurn
  if result < 0: result += AimTurn

proc dist2(ax, ay, bx, by: float): float =
  (ax - bx) * (ax - bx) + (ay - by) * (ay - by)

proc distPx(ax, ay, bx, by: float): float =
  sqrt(dist2(ax, ay, bx, by))

# ---------------------------------------------------------------------------
# frame parsing
# ---------------------------------------------------------------------------

proc centerPt(x, y, w, h: int): Pt =
  (float(x) + float(w) / 2.0, float(y) + float(h) / 2.0)

proc parseFrame(bot: var Bot): Frame =
  result.hp = 3
  result.lives = 3
  result.planted = initTable[string, Pt]()
  result.carriedFlags = initTable[string, Pt]()
  var badges: seq[tuple[p: Pt, color: string, toks: seq[string]]]
  for obj in bot.client.spriteObjects():
    let label = obj.label
    if label.len == 0: continue
    let c = centerPt(obj.x, obj.y, obj.width, obj.height)
    if label.startsWith(LabelPrefixSelf):
      # "self <color> <side>"
      let toks = label.split(' ')
      result.hasSelf = true
      result.selfX = c.x
      result.selfY = c.y
      if toks.len >= 2: result.myColor = toks[1]
      result.selfSideRight = toks.len >= 3 and toks[2] == LabelSideRight
    elif label.startsWith(LabelPrefixPlayer):
      let toks = label.split(' ')
      if toks.len >= 2:
        # note: mates vs enemies resolved after the loop (needs myColor).
        badges.add(((c.x, c.y), "PLAYER:" & toks[1], @[]))
    elif label.startsWith(LabelPrefixIdentity):
      let toks = label.split(' ')
      if toks.len >= 3:
        badges.add(((c.x, c.y), "BADGE", toks))
    elif label.endsWith(" flag planted"):
      let color = label.split(' ')[0]
      # planted banner: bottom-anchored on the pedestal point.
      result.planted[color] = (float(obj.x) + float(obj.width) / 2.0,
                               float(obj.y) + float(obj.height) - 2.0)
    elif label.endsWith(" flag") or label.endsWith(" flag carried"):
      let color = label.split(' ')[0]
      result.carriedFlags[color] = c
    elif label == LabelMedKit:
      result.medKits.add(c)
    elif label == LabelShield:
      result.shields.add(c)
    elif label == LabelSprayCan:
      result.sprayCans.add(c)
    elif label == LabelGrenade:
      result.grenades.add(c)
    elif label == LabelFireIcon:
      result.fireReady = true
    elif label == labelWeapon(LabelWeaponSpray):
      result.weaponSpray = true
    elif label.startsWith(LabelPrefixLives):
      # "lives <n>hp x<n>"
      let toks = label.split(' ')
      if toks.len >= 3:
        let hpTok = toks[1]
        if hpTok.endsWith("hp"):
          try: result.hp = parseInt(hpTok[0 ..< hpTok.len - 2])
          except ValueError: discard
        if toks[2].len >= 2 and toks[2][0] == 'x':
          try: result.lives = parseInt(toks[2][1 .. ^1])
          except ValueError: discard

  # split the seen players into mates and enemies, and resolve our own badge.
  if result.myColor.len > 0:
    for b in badges:
      if b.color.startsWith("PLAYER:"):
        let color = b.color[7 .. ^1]
        # skip anything drawn on top of ourselves.
        if dist2(b.p.x, b.p.y, result.selfX, result.selfY) < 9.0 and
            color == result.myColor:
          continue
        if color == result.myColor:
          result.mates.add(SeenPlayer(x: b.p.x, y: b.p.y, color: color))
        else:
          result.enemies.add(SeenPlayer(x: b.p.x, y: b.p.y, color: color))
    # our own badge is the NEAREST own-color badge: at spawn several players
    # stand close together, so a fixed radius alone attaches the wrong seat.
    var bestBadge = 30.0 * 30.0
    for b in badges:
      if b.color == "BADGE" and b.toks.len >= 3 and
          b.toks[1] == result.myColor:
        let d = dist2(b.p.x, b.p.y, result.selfX, result.selfY)
        if d < bestBadge:
          bestBadge = d
          result.seatName = b.toks[2]
          result.haveShield = false
          result.haveNade = false
          for t in b.toks[3 .. ^1]:
            if t == LabelTokenShield: result.haveShield = true
            elif t == LabelTokenNade: result.haveNade = true

# ---------------------------------------------------------------------------
# navigation: eroded walkability -> coarse grid -> BFS distance field
# ---------------------------------------------------------------------------

proc buildNav(bot: var Bot) =
  let
    w = bot.client.walkabilityWidth
    h = bot.client.walkabilityHeight
  if w <= 0 or h <= 0: return
  bot.mapW = w
  bot.mapH = h
  # erode by the player half-extent so a walkable cell fits the footprint.
  const r = PlayerHalfPx
  var horiz = newSeq[bool](w * h)
  for y in 0 ..< h:
    var run = 0
    let base = y * w
    for x in 0 ..< w:
      if bot.client.walkabilityMask[base + x]: inc run else: run = 0
      if x >= r and run >= 2 * r + 1:
        horiz[base + x - r] = true
  var eroded = newSeq[bool](w * h)
  for x in 0 ..< w:
    var run = 0
    for y in 0 ..< h:
      if horiz[y * w + x]: inc run else: run = 0
      if y >= r and run >= 2 * r + 1:
        eroded[(y - r) * w + x] = true
  bot.navW = (w + NavCell - 1) div NavCell
  bot.navH = (h + NavCell - 1) div NavCell
  bot.navWalk = newSeq[bool](bot.navW * bot.navH)
  for cy in 0 ..< bot.navH:
    for cx in 0 ..< bot.navW:
      let
        px = min(cx * NavCell + NavCell div 2, w - 1)
        py = min(cy * NavCell + NavCell div 2, h - 1)
      bot.navWalk[cy * bot.navW + cx] = eroded[py * w + px]
  bot.dist = newSeq[int32](bot.navW * bot.navH)
  bot.distGoal = (-1, -1)
  bot.navReady = true

proc cellOf(bot: Bot, x, y: float): tuple[cx, cy: int] =
  (clamp(int(x) div NavCell, 0, bot.navW - 1),
   clamp(int(y) div NavCell, 0, bot.navH - 1))

proc nearestWalkCell(bot: Bot, cx, cy: int): tuple[cx, cy: int] =
  if bot.navWalk[cy * bot.navW + cx]: return (cx, cy)
  for r in 1 .. 24:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r: continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= bot.navW or ny >= bot.navH: continue
        if bot.navWalk[ny * bot.navW + nx]: return (nx, ny)
  (cx, cy)

proc computeDist(bot: var Bot, goalX, goalY: float) =
  ## Single-source BFS from the goal; bot steers down the gradient.
  var (gx, gy) = bot.cellOf(goalX, goalY)
  (gx, gy) = bot.nearestWalkCell(gx, gy)
  if bot.distGoal == (gx, gy) and bot.distAge < 12:
    inc bot.distAge
    return
  bot.distGoal = (gx, gy)
  bot.distAge = 0
  const Unreached = int32(1 shl 28)
  for i in 0 ..< bot.dist.len: bot.dist[i] = Unreached
  var queue = newSeq[int](0)
  queue.add(gy * bot.navW + gx)
  bot.dist[gy * bot.navW + gx] = 0
  var head = 0
  while head < queue.len:
    let
      cur = queue[head]
      cx = cur mod bot.navW
      cy = cur div bot.navW
      d = bot.dist[cur]
    inc head
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        if dx == 0 and dy == 0: continue
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= bot.navW or ny >= bot.navH: continue
        let ni = ny * bot.navW + nx
        if not bot.navWalk[ni] or bot.dist[ni] != Unreached: continue
        if dx != 0 and dy != 0:
          # no corner cutting through blocked orthogonals.
          if not bot.navWalk[cy * bot.navW + nx] or
             not bot.navWalk[ny * bot.navW + cx]: continue
        bot.dist[ni] = d + 1
        queue.add(ni)

proc stepToward(bot: var Bot, fromX, fromY: float): tuple[dx, dy: int] =
  ## Follows the BFS gradient a few cells and returns a d-pad direction.
  var (cx, cy) = bot.cellOf(fromX, fromY)
  (cx, cy) = bot.nearestWalkCell(cx, cy)
  const Unreached = int32(1 shl 28)
  if bot.dist[cy * bot.navW + cx] >= Unreached:
    return (0, 0)
  var
    px = cx
    py = cy
  for step in 0 ..< 3:
    var
      best = bot.dist[py * bot.navW + px]
      bx = px
      by = py
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        if dx == 0 and dy == 0: continue
        let
          nx = px + dx
          ny = py + dy
        if nx < 0 or ny < 0 or nx >= bot.navW or ny >= bot.navH: continue
        if not bot.navWalk[ny * bot.navW + nx]: continue
        if dx != 0 and dy != 0:
          if not bot.navWalk[py * bot.navW + nx] or
             not bot.navWalk[ny * bot.navW + px]: continue
        if bot.dist[ny * bot.navW + nx] < best:
          best = bot.dist[ny * bot.navW + nx]
          bx = nx
          by = ny
    if bx == px and by == py: break
    px = bx
    py = by
  let
    wx = float(px * NavCell + NavCell div 2)
    wy = float(py * NavCell + NavCell div 2)
    ddx = wx - fromX
    ddy = wy - fromY
  result.dx = (if ddx > 2.0: 1 elif ddx < -2.0: -1 else: 0)
  result.dy = (if ddy > 2.0: 1 elif ddy < -2.0: -1 else: 0)

proc losClear(bot: Bot, ax, ay, bx, by: float): bool =
  ## Raw-mask raycast: any non-walkable pixel blocks (walls and glass both
  ## live outside the walk mask, so this is conservative and safe).
  if not bot.client.walkabilityReady: return false
  let
    w = bot.client.walkabilityWidth
    h = bot.client.walkabilityHeight
    d = distPx(ax, ay, bx, by)
  if d < 1.0: return true
  let steps = int(d / 3.0) + 1
  for i in 1 ..< steps:
    let
      t = float(i) / float(steps)
      x = int(ax + (bx - ax) * t)
      y = int(ay + (by - ay) * t)
    if x < 0 or y < 0 or x >= w or y >= h: return false
    if not bot.client.walkabilityMask[y * w + x]: return false
  true

proc mateInCorridor(frame: Frame, tx, ty: float): bool =
  ## True when a visible teammate stands near the segment self->target.
  let
    ax = frame.selfX
    ay = frame.selfY
    vx = tx - ax
    vy = ty - ay
    len2 = vx * vx + vy * vy
  if len2 < 1.0: return false
  for m in frame.mates:
    let t = ((m.x - ax) * vx + (m.y - ay) * vy) / len2
    if t < 0.02 or t > 0.98: continue
    let
      px = ax + vx * t
      py = ay + vy * t
    if dist2(px, py, m.x, m.y) < 18.0 * 18.0:
      return true
  false

# ---------------------------------------------------------------------------
# knowledge upkeep
# ---------------------------------------------------------------------------

proc rememberSpots(spots: var seq[Pt], seen: seq[Pt]) =
  for s in seen:
    var known = false
    for k in spots:
      if dist2(k.x, k.y, s.x, s.y) < 24.0 * 24.0:
        known = true
        break
    if not known: spots.add(s)

proc updateKnowledge(bot: var Bot, frame: Frame) =
  for color, p in frame.planted:
    bot.pedestals[color] = p
  rememberSpots(bot.knownKits, frame.medKits)
  rememberSpots(bot.knownShieldSpots, frame.shields)
  rememberSpots(bot.knownNadeSpots, frame.grenades)
  if frame.myColor.len > 0 and bot.myColor.len == 0:
    bot.myColor = frame.myColor
  if frame.seatName.len > 0:
    for i, n in SeatNames:
      if n == frame.seatName:
        bot.seat = i
        break
  # our flag carried by an enemy: remember where we last saw it.
  if bot.myColor.len > 0 and bot.myColor in frame.carriedFlags:
    let p = frame.carriedFlags[bot.myColor]
    # if it is centered on us we are not the carrier of our own flag; an
    # own-color carried banner is always an enemy thief.
    bot.ourFlagLastSeen = p
    bot.ourFlagSeenAge = 0
  else:
    inc bot.ourFlagSeenAge

proc enemyPedestal(bot: Bot): tuple[ok: bool, p: Pt] =
  var
    best = 1.0e18
    found = false
    bp: Pt
  let mine = bot.pedestals.getOrDefault(bot.myColor, (-1.0, -1.0))
  for color, p in bot.pedestals:
    if color == bot.myColor: continue
    let d = dist2(p.x, p.y, mine.x, mine.y)
    if not found or d < best:
      best = d
      bp = p
      found = true
  (found, bp)

proc enemyFlagHome(bot: Bot, frame: Frame): tuple[known: bool, home: bool, p: Pt] =
  ## The enemy planted flag is never fogged while home, so its absence from
  ## the frame means it is being carried (necessarily by our team).
  for color, p in frame.planted:
    if color != frame.myColor:
      return (true, true, p)
  # not planted this frame: taken (or we have not identified the enemy yet).
  let (ok, p) = bot.enemyPedestal()
  (ok, false, p)

proc iCarryEnemyFlag(bot: Bot, frame: Frame): bool =
  for color, p in frame.carriedFlags:
    if color != frame.myColor and
        dist2(p.x, p.y, frame.selfX, frame.selfY) < 16.0 * 16.0:
      return true
  false

proc ourFlagStolen(bot: Bot, frame: Frame): bool =
  bot.myColor.len > 0 and bot.myColor notin frame.planted

# ---------------------------------------------------------------------------
# role goals
# ---------------------------------------------------------------------------

proc mirrored(bot: Bot, x: float): float =
  ## Red-frame helper: positions are authored for a left-side team and
  ## mirrored when our pedestal sits on the right half.
  let mine = bot.pedestals.getOrDefault(bot.myColor, (0.0, 0.0))
  if mine.x <= float(bot.mapW) / 2.0: x
  else: float(bot.mapW) - 1.0 - x

proc roleGoal(bot: var Bot, frame: Frame): Pt =
  let
    w = float(bot.mapW)
    h = float(bot.mapH)
    cx = w / 2.0
    myPed = bot.pedestals.getOrDefault(bot.myColor, (bot.mirrored(186.0), h / 2.0))
    (efKnown, efHome, efP) = bot.enemyFlagHome(frame)
    stolen = bot.ourFlagStolen(frame)
  case bot.role
  of roleRunner:
    if efKnown and efHome: efP
    else: myPed                       # our side has it: cover the way home.
  of roleEscort:
    if efKnown and efHome:
      # fight down the runner's approach all the way to the pedestal: the
      # escort clears the pocket and doubles as the backup stealer.
      efP
    else:
      (cx + (if myPed.x < cx: -w / 6.0 else: w / 6.0), h / 2.0)
  of roleRunner2:
    if efKnown and efHome:
      # bottom route: swing through the lower lane until past midfield.
      if abs(frame.selfX - myPed.x) < w / 4.0 and
          abs(frame.selfY - h * 0.8) > 60.0:
        (cx + (if myPed.x < cx: -w / 8.0 else: w / 8.0), h * 0.8)
      else:
        efP
    else: myPed
  of roleDefender:
    if stolen and bot.ourFlagSeenAge < 72:
      bot.ourFlagLastSeen                # chase the thief we saw.
    elif stolen:
      (cx + (if myPed.x < cx: -w / 8.0 else: w / 8.0), h / 2.0)
    else:
      (myPed.x + (if myPed.x < cx: 110.0 else: -110.0), myPed.y)
  of roleKeeper:
    if not frame.haveShield:
      # go pick the endzone shield if we know where one sits.
      var
        best = 1.0e18
        found = false
        bp: Pt
      for s in bot.knownShieldSpots:
        # our own side only.
        if (s.x < cx) == (myPed.x < cx):
          let d = dist2(s.x, s.y, frame.selfX, frame.selfY)
          if not found or d < best:
            best = d
            bp = s
            found = true
      if found: return bp
    (myPed.x + (if myPed.x < cx: 60.0 else: -60.0), myPed.y - 70.0)
  of roleIntTop:
    # forward pressure: sit on the ENEMY-side lane mouth so runners are not
    # crossing alone into a settled camp.
    if stolen and bot.ourFlagSeenAge < 72: bot.ourFlagLastSeen
    else: (cx + (if myPed.x < cx: w / 6.0 else: -w / 6.0), h / 5.0)
  of roleIntBot:
    if stolen and bot.ourFlagSeenAge < 72: bot.ourFlagLastSeen
    else: (cx + (if myPed.x < cx: w / 6.0 else: -w / 6.0), h * 4.0 / 5.0)
  of roleRover:
    if not frame.haveNade and bot.knownNadeSpots.len > 0:
      var
        best = 1.0e18
        bp: Pt = bot.knownNadeSpots[0]
      for s in bot.knownNadeSpots:
        if (s.x < cx) == (myPed.x < cx):
          let d = dist2(s.x, s.y, frame.selfX, frame.selfY)
          if d < best:
            best = d
            bp = s
      bp
    else:
      # patrol between the two center-line kit heights.
      let phase = (bot.tick div 240) mod 2
      (cx + (if myPed.x < cx: -w / 10.0 else: w / 10.0),
       (if phase == 0: h / 3.0 else: h * 2.0 / 3.0))

# ---------------------------------------------------------------------------
# the per-frame decision
# ---------------------------------------------------------------------------

proc decide(bot: var Bot, frame: Frame): uint8 =
  var mask: uint8 = 0
  let carrying = bot.iCarryEnemyFlag(frame)

  # ----- pick a movement goal -------------------------------------------
  var goal: Pt
  if carrying:
    goal = bot.pedestals.getOrDefault(bot.myColor,
      (float(bot.mapW) / 4.0, float(bot.mapH) / 2.0))
  else:
    goal = bot.roleGoal(frame)
    # opportunistic heart steal when it is close and unclaimed.
    let (efKnown, efHome, efP) = bot.enemyFlagHome(frame)
    var nearEnemyFlag = false
    if efKnown and efHome:
      let d = distPx(frame.selfX, frame.selfY, efP.x, efP.y)
      nearEnemyFlag = d < 250.0
      if d < 90.0:
        goal = efP
    # heal when hurt and a kit is known and close-ish (but never abandon a
    # steal that is almost complete).
    if frame.hp <= 1 and bot.healCooldown == 0 and not nearEnemyFlag and
        bot.role notin {roleDefender, roleKeeper} and not carrying:
      var
        best = 320.0 * 320.0
        found = false
        bp: Pt
      for k in bot.knownKits:
        let d = dist2(k.x, k.y, frame.selfX, frame.selfY)
        if d < best:
          best = d
          bp = k
          found = true
      if found:
        goal = bp
        if distPx(frame.selfX, frame.selfY, bp.x, bp.y) < 18.0 and
            frame.medKits.len == 0:
          bot.healCooldown = 240      # arrived, no kit: try again later.
    # cheap shield grabs for the pedestal-side roles.
    if not frame.haveShield and bot.role in {roleDefender, roleKeeper}:
      for s in frame.shields:
        if distPx(frame.selfX, frame.selfY, s.x, s.y) < 160.0:
          goal = s

  # ----- steering --------------------------------------------------------
  bot.computeDist(goal.x, goal.y)
  var (mdx, mdy) = bot.stepToward(frame.selfX, frame.selfY)

  # spray-can repulsion: never trade the gun away by stepping on a can.
  for s in frame.sprayCans:
    if dist2(s.x, s.y, frame.selfX, frame.selfY) < 30.0 * 30.0:
      mdx = (if frame.selfX >= s.x: 1 else: -1)
      mdy = (if frame.selfY >= s.y: 1 else: -1)

  # stuck detection: jiggle when we have not moved but want to.
  if bot.jigglingTicks > 0:
    dec bot.jigglingTicks
    case bot.jiggleDir mod 4
    of 0: mdx = 1; mdy = 0
    of 1: mdx = 0; mdy = 1
    of 2: mdx = -1; mdy = 0
    else: mdx = 0; mdy = -1
  elif (mdx != 0 or mdy != 0) and
      dist2(frame.selfX, frame.selfY, bot.lastX, bot.lastY) < 2.0:
    inc bot.stuckTicks
    if bot.stuckTicks > 20:
      bot.stuckTicks = 0
      bot.jigglingTicks = 10
      inc bot.jiggleDir
  else:
    bot.stuckTicks = 0

  # ----- combat -----------------------------------------------------------
  var
    haveTarget = false
    tx, ty: float
    tdist = 1.0e18
  # priority one: any enemy near our stolen flag banner.
  if bot.myColor in frame.carriedFlags:
    let fp = frame.carriedFlags[bot.myColor]
    for e in frame.enemies:
      let d = dist2(e.x, e.y, fp.x, fp.y)
      if d < 40.0 * 40.0 and d < tdist:
        haveTarget = true
        tx = e.x
        ty = e.y
        tdist = d
  if not haveTarget:
    for e in frame.enemies:
      let d = dist2(e.x, e.y, frame.selfX, frame.selfY)
      if d < tdist:
        haveTarget = true
        tx = e.x
        ty = e.y
        tdist = d
  tdist = sqrt(tdist)

  let engageRange =
    if carrying: 0.0                        # carriers run, never brawl.
    elif bot.role == roleRunner: 170.0
    elif bot.role == roleRunner2: 200.0
    else: 520.0
  let fighting = haveTarget and tdist <= engageRange
  # runners are on a mission: they shoot in passing but never stop running.
  let mission = bot.role in {roleRunner, roleRunner2} and not carrying

  # desired aim: at the target when fighting, along movement otherwise.
  var wantAim = bot.aimEst
  if fighting:
    # small linear lead over the windup.
    wantAim = bearingBrads(frame.selfX, frame.selfY, tx, ty)
  elif bot.role in {roleDefender, roleKeeper} and not carrying:
    # sweep the approaches: oscillate around the field-facing bearing.
    let mine = bot.pedestals.getOrDefault(bot.myColor, (0.0, 0.0))
    let base = (if mine.x <= float(bot.mapW) / 2.0: 0 else: 128)
    let swing = [(-40), -20, 0, 20, 40, 20, 0, -20][(bot.tick div 36) mod 8]
    wantAim = (base + swing + AimTurn) mod AimTurn
  elif mdx != 0 or mdy != 0:
    wantAim = bearingBrads(0.0, 0.0, float(mdx), float(mdy))

  # rotate toward wantAim.
  let err = angDiff(wantAim, bot.aimEst)
  var rot = 0
  if err > 2: rot = 1
  elif err < -2: rot = -1
  if rot > 0: mask = mask or ButtonB
  elif rot < 0: mask = mask or ButtonSelect
  bot.lastRotDir = rot

  # fire decision.
  var firedThisFrame = false
  if fighting and not carrying:
    # keep the shot line honest: while a windup is pending, close straight in.
    if bot.windupLeft > 0:
      dec bot.windupLeft
      if not mission:
        let b = bearingBrads(frame.selfX, frame.selfY,
                             bot.windupTarget.x, bot.windupTarget.y)
        let v = (cos(float(b) * 2.0 * PI / 256.0),
                 -sin(float(b) * 2.0 * PI / 256.0))
        mdx = (if v[0] > 0.4: 1 elif v[0] < -0.4: -1 else: 0)
        mdy = (if v[1] > 0.4: 1 elif v[1] < -0.4: -1 else: 0)
    elif not mission:
      # movement while fighting: close beyond 260, strafe inside 150.
      if tdist > 260.0:
        discard # keep BFS steering toward goal/target.
      elif tdist < 150.0:
        inc bot.strafePhase
        let b = bearingBrads(frame.selfX, frame.selfY, tx, ty)
        let perp = float((b + 64) mod 256) * 2.0 * PI / 256.0
        let sign = (if (bot.strafePhase div 16) mod 2 == 0: 1.0 else: -1.0)
        let sx = cos(perp) * sign
        let sy = -sin(perp) * sign
        mdx = (if sx > 0.4: 1 elif sx < -0.4: -1 else: 0)
        mdy = (if sy > 0.4: 1 elif sy < -0.4: -1 else: 0)

    if frame.weaponSpray:
      # the can replaces the gun: short cone, generous angle.
      if frame.fireReady and tdist < 120.0 and abs(err) <= 8 and
          bot.losClear(frame.selfX, frame.selfY, tx, ty) and
          not mateInCorridor(frame, tx, ty) and not bot.prevMaskA:
        mask = mask or ButtonA
        firedThisFrame = true
    else:
      # lateral miss at the target if we fire right now.
      let lateral = abs(sin(float(err) * 2.0 * PI / 256.0)) * tdist
      if frame.fireReady and bot.windupLeft == 0 and lateral <= 13.0 and
          tdist < 560.0 and
          bot.losClear(frame.selfX, frame.selfY, tx, ty) and
          not mateInCorridor(frame, tx, ty) and not bot.prevMaskA:
        mask = mask or ButtonA
        firedThisFrame = true
        bot.windupLeft = FireWindupTicks
        bot.windupTarget = (tx, ty)

  # grenade: lob at mid-range targets, especially when the gun is cold.
  if bot.chargeTicks > 0:
    # currently charging: keep holding C until the charge goal, then release.
    if bot.chargeTicks >= bot.chargeGoal or not frame.hasSelf:
      bot.chargeTicks = 0
      bot.nadeCooldown = 96
      # C released by simply not setting the bit this frame.
    else:
      mask = mask or ButtonC
      inc bot.chargeTicks
  elif frame.haveNade and haveTarget and bot.nadeCooldown == 0 and
      not carrying and not firedThisFrame and bot.windupLeft == 0 and
      tdist >= 100.0 and tdist <= GrenadeMaxRange - 10.0 and abs(err) <= 4:
    var closeAllies = 0
    for m in frame.mates:
      if dist2(m.x, m.y, tx, ty) < 60.0 * 60.0: inc closeAllies
    if closeAllies == 0 and
        distPx(frame.selfX, frame.selfY, tx, ty) > 60.0:
      let need = clamp(int((tdist - GrenadeMinRange) *
        float(GrenadeChargeTicks) / (GrenadeMaxRange - GrenadeMinRange)),
        2, GrenadeChargeTicks)
      bot.chargeGoal = need
      bot.chargeTicks = 1
      mask = mask or ButtonC

  # ----- movement bits ----------------------------------------------------
  if mdx > 0: mask = mask or ButtonRight
  elif mdx < 0: mask = mask or ButtonLeft
  if mdy > 0: mask = mask or ButtonDown
  elif mdy < 0: mask = mask or ButtonUp

  bot.prevMaskA = (mask and ButtonA) != 0
  mask

# ---------------------------------------------------------------------------
# aim dead-reckoning upkeep
# ---------------------------------------------------------------------------

proc spawnAim(bot: Bot, frame: Frame): int =
  ## On spawn the aim points at the fight: bearing to map center, snapped to
  ## the nearest 32 brads (exactly east/west on the classic sides maps).
  if bot.mapW <= 0:
    return 0
  let b = bearingBrads(frame.selfX, frame.selfY,
                       float(bot.mapW) / 2.0, float(bot.mapH) / 2.0)
  ((b + 16) div 32 * 32) mod AimTurn

proc updateAim(bot: var Bot, frame: Frame, framesAdvanced: int) =
  if not frame.hasSelf:
    bot.wasAlive = false
    return
  if not bot.wasAlive:
    bot.aimEst = bot.spawnAim(frame)
    bot.lastRotDir = 0
    bot.windupLeft = 0
    bot.chargeTicks = 0
    bot.faceMismatch = 0
    bot.wasAlive = true
    return
  # the mask we sent last frame was held for every server tick since.
  let turned = bot.aimEst + bot.lastRotDir * AimRate * max(framesAdvanced, 1)
  bot.aimEst = (turned mod AimTurn + AimTurn) mod AimTurn
  # one honest bit of feedback: the self label's left/right side.
  let estRight = not (bot.aimEst > 64 and bot.aimEst < 192)
  if bot.faceFixCooldown > 0: dec bot.faceFixCooldown
  if estRight != frame.selfSideRight and
      min(abs(angDiff(bot.aimEst, 64)), abs(angDiff(bot.aimEst, 192))) > 10:
    inc bot.faceMismatch
    if bot.faceMismatch >= 6 and bot.faceFixCooldown == 0:
      bot.aimEst = ((128 - bot.aimEst) mod AimTurn + AimTurn) mod AimTurn
      bot.faceMismatch = 0
      bot.faceFixCooldown = 48
  else:
    bot.faceMismatch = 0

# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------

proc runOnce(bot: var Bot, url: string) =
  let ws = newWebSocket(url)
  defer: ws.close()
  bot.client.reset()
  echo "connected: ", url
  while true:
    if not bot.client.receiveLatestFrame(ws, false):
      continue
    inc bot.tick
    if bot.nadeCooldown > 0: dec bot.nadeCooldown
    if bot.healCooldown > 0: dec bot.healCooldown
    if not bot.navReady and bot.client.walkabilityReady:
      bot.buildNav()
    var mask: uint8 = 0
    try:
      let frame = bot.parseFrame()
      bot.updateAim(frame, bot.client.frameAdvance)
      if frame.hasSelf and bot.navReady:
        bot.updateKnowledge(frame)
        if bot.seat >= 0:
          bot.role = Role(bot.seat mod 8)
        mask = bot.decide(frame)
        bot.lastX = frame.selfX
        bot.lastY = frame.selfY
      else:
        bot.lastRotDir = 0
    except CatchableError as e:
      # never miss a tick: a decision bug costs one no-op, not the episode.
      echo "decide error: ", e.msg
      mask = 0
      bot.lastRotDir = 0
    ws.send(inputBlob(mask), BinaryMessage)
    ws.send(readyBlob(), BinaryMessage)

proc main() =
  var url = getEnv("COGAMES_ENGINE_WS_URL")
  if url.len == 0:
    url = getEnv("ENGINE_WS_URL")
  if url.len == 0:
    url = "ws://localhost:8080"
  url = url.ensureWsPath("/player")
  var bot = Bot(client: initProtocolClient(), seat: -1)
  bot.role = roleIntTop            # neutral default until the badge resolves.
  var attempt = 0
  while true:
    try:
      bot.runOnce(url)
    except CatchableError as e:
      echo "socket error: ", e.msg
    inc attempt
    sleep(min(attempt * 500, 5000))

main()
