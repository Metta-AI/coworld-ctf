## ctf-scratch-a003 — replicated central-planner CTF bot, written from a blank
## file in one pass at exposure level 0.50 (doctrine), stance central-planner.
##
## One process = one seat. Every seat runs the IDENTICAL deterministic planner
## over common-knowledge inputs (shared tick clock, own team color, own-heart
## state, identity badge) and reads its own row out of the team plan; private
## sightings feed only the local executor (aim/fire/chase). See DESIGN.md.

import std/[os, strutils, math]
import whisky
import baseline/protocols
import bitworld/spriteprotocol
import ctf/labels

# ---------------------------------------------------------------------------
# Game constants mirrored from the readable game source (src/ctf/sim.nim).
# ---------------------------------------------------------------------------
const
  AimBradsTurn = 256
  AimTurnRate = 5              ## brads per tick while a rotate button is held.
  BulletHalfWidth = 8.0
  PlayerHalf = 6               ## solid footprint half-extent, px.
  GrenadeMinRange = 30
  GrenadeChargeTicks = 24
  GrenadeBlastRadius = 52
  NavCell = 8                  ## nav grid cell size, px.
  MaxTicks = 5000

  # Plan timetable (ticks on the shared clock).
  PressTick = 240              ## wave leaves staging.
  AllInTick = 3700             ## everyone presses; a draw costs a loss anyway.

  IdentityNames = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]

type
  Role = enum
    roleWave, roleMid, roleAnchor, roleCarrier, roleEscort, roleHunter

  Pt = tuple[x, y: int]

  Sighting = object
    pos: Pt
    isThief: bool              ## carries OUR heart.

  Bot = object
    client: ProtocolClient
    # Frame-derived state
    tick: int                  ## shared clock: sum of frameAdvance.
    alive: bool
    selfPos: Pt
    myColor: string            ## "red" or "blue"
    enemyColor: string
    haveColor: bool
    myIdent: int               ## 0..7 (alpha..theta), -1 unknown.
    myHp: int
    weaponSpray: bool
    carryNade: bool
    fireReady: bool
    ownFlagHome: bool          ## own planted flag observed this frame.
    ownFlagKnown: bool         ## own pedestal in frame at all (always, once seen).
    enemyFlagPlantedSeen: bool
    iCarry: bool
    mateCarrierPos: Pt
    mateCarrierSeen: bool
    thiefSeen: bool
    thiefPos: Pt
    enemies: seq[Sighting]
    mates: seq[Pt]
    medKits: seq[Pt]
    # Geometry (fixed once learned)
    mapW, mapH: int
    geomReady: bool
    ownPedestal: Pt
    enemyPedestal: Pt
    # Nav
    gridW, gridH: int
    navOk: seq[bool]           ## cell passable for the player footprint.
    navReady: bool
    flowGoal: int              ## goal cell index of the cached flow field, -1 none.
    flowDist: seq[uint16]
    # Aim dead-reckoning
    estAim: int
    lastMask: uint8
    lastSide: string           ## last self side token for boundary resync.
    firedLastFrame: bool
    # Grenade charge state
    nadeCharging: bool
    nadeChargeLeft: int
    # Stuck detection
    stuckRefPos: Pt
    stuckRefTick: int
    unstickUntil: int
    unstickDir: int
    # Lifecycle
    wasAlive: bool

proc center(o: SpriteObjectInfo, b: Bot): Pt =
  (o.x + o.width div 2 + b.client.mapCameraX,
   o.y + o.height div 2 + b.client.mapCameraY)

proc dist(a, b: Pt): float =
  sqrt(float((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)))

proc bradsOf(dx, dy: int): int =
  ## Map-space vector -> brads (0 east, 64 north; screen y points down).
  var b = int(round(arctan2(-float(dy), float(dx)) * float(AimBradsTurn) /
    (2.0 * PI)))
  ((b mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn

proc bradDiff(a, b: int): int =
  ## Shortest signed rotation from b to a, in -128..127.
  var d = (a - b) mod AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  d

# ---------------------------------------------------------------------------
# Navigation: 8px occupancy grid + BFS flow field to the current goal.
# ---------------------------------------------------------------------------
proc buildNav(b: var Bot) =
  b.mapW = b.client.walkabilityWidth
  b.mapH = b.client.walkabilityHeight
  b.gridW = b.mapW div NavCell
  b.gridH = b.mapH div NavCell
  b.navOk = newSeq[bool](b.gridW * b.gridH)
  # A cell is passable when the player's 13x13 footprint fits at its center.
  for cy in 0 ..< b.gridH:
    for cx in 0 ..< b.gridW:
      let px = cx * NavCell + NavCell div 2
      let py = cy * NavCell + NavCell div 2
      var ok = true
      block scan:
        for dy in -PlayerHalf .. PlayerHalf:
          let yy = py + dy
          if yy < 0 or yy >= b.mapH: ok = false; break scan
          let rowBase = yy * b.mapW
          for dx in -PlayerHalf .. PlayerHalf:
            let xx = px + dx
            if xx < 0 or xx >= b.mapW or not b.client.walkabilityMask[rowBase + xx]:
              ok = false
              break scan
      b.navOk[cy * b.gridW + cx] = ok
  b.navReady = true
  b.flowGoal = -1

proc cellOf(b: Bot, p: Pt): int =
  let cx = clamp(p.x div NavCell, 0, b.gridW - 1)
  let cy = clamp(p.y div NavCell, 0, b.gridH - 1)
  cy * b.gridW + cx

proc nearestOkCell(b: Bot, start: int): int =
  ## Expanding ring search for a passable cell (goal may sit on furniture).
  if b.navOk[start]: return start
  let sx = start mod b.gridW
  let sy = start div b.gridW
  for r in 1 .. 24:
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) != r: continue
        let nx = sx + dx
        let ny = sy + dy
        if nx < 0 or ny < 0 or nx >= b.gridW or ny >= b.gridH: continue
        let idx = ny * b.gridW + nx
        if b.navOk[idx]: return idx
  start

proc ensureFlow(b: var Bot, goal: Pt) =
  let g = b.nearestOkCell(b.cellOf(goal))
  if g == b.flowGoal and b.flowDist.len > 0: return
  b.flowGoal = g
  if b.flowDist.len != b.navOk.len:
    b.flowDist = newSeq[uint16](b.navOk.len)
  for i in 0 ..< b.flowDist.len: b.flowDist[i] = 65535'u16
  var queue = newSeq[int32](0)
  queue.add(int32(g))
  b.flowDist[g] = 0
  var head = 0
  while head < queue.len:
    let cur = int(queue[head])
    inc head
    let cx = cur mod b.gridW
    let cy = cur div b.gridW
    let d = b.flowDist[cur] + 1
    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)]:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= b.gridW or ny >= b.gridH: continue
      let idx = ny * b.gridW + nx
      if not b.navOk[idx] or b.flowDist[idx] != 65535'u16: continue
      b.flowDist[idx] = d
      queue.add(int32(idx))

proc moveMaskToward(b: var Bot, goal: Pt): uint8 =
  ## Flow-field descent with greedy fallback; returns d-pad bits.
  if dist(b.selfPos, goal) < 5.0: return 0
  var tx = goal.x
  var ty = goal.y
  if b.navReady:
    b.ensureFlow(goal)
    var cur = b.cellOf(b.selfPos)
    if not b.navOk[cur]: cur = b.nearestOkCell(cur)
    if b.flowDist[cur] != 65535'u16 and b.flowDist[cur] > 0:
      # Walk 3 cells downhill and steer at that point.
      var look = cur
      for _ in 0 ..< 3:
        let cx = look mod b.gridW
        let cy = look div b.gridW
        var best = look
        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)]:
          let nx = cx + dx
          let ny = cy + dy
          if nx < 0 or ny < 0 or nx >= b.gridW or ny >= b.gridH: continue
          let idx = ny * b.gridW + nx
          if b.navOk[idx] and b.flowDist[idx] < b.flowDist[best]: best = idx
        if best == look: break
        look = best
      tx = (look mod b.gridW) * NavCell + NavCell div 2
      ty = (look div b.gridW) * NavCell + NavCell div 2
  let dx = tx - b.selfPos.x
  let dy = ty - b.selfPos.y
  # Nearest of 8 directions.
  if dx == 0 and dy == 0: return 0
  let ang = arctan2(float(-dy), float(dx))            # radians, CCW, 0 = east
  let oct = int(floor((ang + PI / 8.0) / (PI / 4.0) + 4.0)) mod 8
  case oct                                            # 0=W ... going CCW
  of 0: ButtonLeft
  of 1: ButtonLeft or ButtonDown
  of 2: ButtonDown
  of 3: ButtonRight or ButtonDown
  of 4: ButtonRight
  of 5: ButtonRight or ButtonUp
  of 6: ButtonUp
  of 7: ButtonLeft or ButtonUp
  else: 0

proc rayClear(b: Bot, a, c: Pt): bool =
  ## Stone/glass proxy: every walkability pixel on the segment is floor.
  ## Glass is unwalkable and blocks bullets, so this is conservative-correct.
  if not b.client.walkabilityReady: return true
  let steps = max(1, int(dist(a, c) / 4.0))
  for i in 1 ..< steps:
    let t = float(i) / float(steps)
    let x = int(float(a.x) + t * float(c.x - a.x))
    let y = int(float(a.y) + t * float(c.y - a.y))
    if x < 0 or y < 0 or x >= b.mapW or y >= b.mapH: return false
    if not b.client.walkabilityMask[y * b.mapW + x]: return false
  true

proc mateInCorridor(b: Bot, target: Pt): bool =
  ## Friendly fire is ON: refuse the shot when a teammate sits inside the
  ## bullet corridor between us and the target.
  let d = dist(b.selfPos, target)
  if d < 1.0: return false
  let ux = float(target.x - b.selfPos.x) / d
  let uy = float(target.y - b.selfPos.y) / d
  for m in b.mates:
    let px = float(m.x - b.selfPos.x)
    let py = float(m.y - b.selfPos.y)
    let along = px * ux + py * uy
    if along <= 0 or along >= d: continue
    let perp = abs(px * uy - py * ux)
    if perp < BulletHalfWidth + float(PlayerHalf) + 2.0: return true
  false

# ---------------------------------------------------------------------------
# Frame parsing.
# ---------------------------------------------------------------------------
proc parseFrame(b: var Bot) =
  b.alive = false
  b.fireReady = false
  b.ownFlagHome = false
  b.enemyFlagPlantedSeen = false
  b.iCarry = false
  b.mateCarrierSeen = false
  b.thiefSeen = false
  b.enemies.setLen(0)
  b.mates.setLen(0)
  b.medKits.setLen(0)
  var selfObj: SpriteObjectInfo
  var haveSelf = false
  var idents: seq[(Pt, string)]
  var enemyFlagCarried: Pt
  var enemyFlagCarriedSeen = false

  for obj in spriteObjects(b.client):
    let label = obj.label
    if label.len == 0: continue
    if label.startsWith(LabelPrefixSelf):
      selfObj = SpriteObjectInfo(objectId: obj.objectId, x: obj.x, y: obj.y,
        width: obj.width, height: obj.height)
      haveSelf = true
      if not b.haveColor:
        let parts = label.split(' ')
        if parts.len >= 3:
          b.myColor = parts[1]
          b.enemyColor = if b.myColor == "red": "blue" else: "red"
          b.haveColor = true
      # Passive absolute aim resync off the coarse side token.
      let parts = label.split(' ')
      if parts.len >= 3:
        let side = parts[2]
        if b.lastSide.len > 0 and side != b.lastSide:
          # Crossed 64 (north) or 192 (south) since last frame; pick by the
          # rotation direction we were commanding.
          let ccw = (b.lastMask and ButtonB) != 0
          let cw = (b.lastMask and ButtonSelect) != 0
          if ccw and not cw:
            b.estAim = if side == LabelSideLeft: 64 else: 192
          elif cw and not ccw:
            b.estAim = if side == LabelSideLeft: 192 else: 64
        b.lastSide = side
    elif label == LabelFireIcon:
      b.fireReady = true
    elif label == LabelMedKit:
      discard # position resolved below (needs map camera; obj is a tuple here)
    elif label.startsWith(LabelPrefixIdentity):
      discard
    else:
      discard

  # Second pass with positions (needs self for proximity attachments).
  for obj in spriteObjects(b.client):
    let label = obj.label
    if label.len == 0: continue
    let o = SpriteObjectInfo(objectId: obj.objectId, x: obj.x, y: obj.y,
      width: obj.width, height: obj.height)
    let p = o.center(b)
    if b.haveColor:
      if label.startsWith(LabelPrefixPlayer):
        if label.contains(b.enemyColor):
          b.enemies.add(Sighting(pos: p))
        elif label.contains(b.myColor):
          b.mates.add(p)
      elif label == labelFlagPlanted(b.myColor):
        b.ownFlagHome = true
        b.ownFlagKnown = true
        b.ownPedestal = p
      elif label == labelFlagPlanted(b.enemyColor):
        b.enemyFlagPlantedSeen = true
        b.enemyPedestal = p
        b.geomReady = true
      elif label == labelFlag(b.myColor):
        # Our heart on an enemy's back: the banner centers on the thief.
        b.thiefSeen = true
        b.thiefPos = p
      elif label == labelFlag(b.enemyColor):
        enemyFlagCarried = p
        enemyFlagCarriedSeen = true
      elif label == LabelMedKit:
        b.medKits.add(p)
      elif label.startsWith(LabelPrefixIdentity):
        idents.add((p, label))
      elif label.startsWith(LabelPrefixLives):
        # `lives <hp>hp x<lives>` — own HUD.
        let parts = label.split(' ')
        if parts.len >= 2 and parts[1].endsWith("hp"):
          try: b.myHp = parseInt(parts[1][0 ..< parts[1].len - 2])
          except ValueError: discard
      elif label == labelWeapon(LabelWeaponSpray):
        b.weaponSpray = true
      elif label == labelWeapon(LabelWeaponGun):
        b.weaponSpray = false

  if haveSelf:
    b.alive = true
    b.selfPos = selfObj.center(b)
    # Identity badge: nearest own-color badge riding our sprite.
    if b.myIdent < 0 and b.haveColor:
      var bestD = 26.0
      for (p, label) in idents:
        if not label.startsWith(LabelPrefixIdentity & b.myColor): continue
        let d = dist(p, b.selfPos)
        if d < bestD:
          bestD = d
          let parts = label.split(' ')
          if parts.len >= 3:
            for i, n in IdentityNames:
              if parts[2] == n: b.myIdent = i
    # Own badge also carries loadout tokens (shield/nade).
    b.carryNade = false
    for (p, label) in idents:
      if dist(p, b.selfPos) < 26.0 and
          label.startsWith(LabelPrefixIdentity & b.myColor):
        b.carryNade = (" " & LabelTokenNade & " ") in (label & " ")
    if enemyFlagCarriedSeen:
      if dist(enemyFlagCarried, b.selfPos) < 20.0:
        b.iCarry = true
      else:
        b.mateCarrierSeen = true
        b.mateCarrierPos = enemyFlagCarried
    # Tag which enemies carry our heart.
    if b.thiefSeen:
      for e in b.enemies.mitems:
        if dist(e.pos, b.thiefPos) < 20.0: e.isThief = true

  # Learn geometry from own pedestal (never fogged) + mirror symmetry.
  if b.ownFlagKnown and not b.geomReady and b.mapW > 0:
    b.enemyPedestal = (b.mapW - b.ownPedestal.x, b.ownPedestal.y)
    b.geomReady = true

# ---------------------------------------------------------------------------
# The planner: identical in every seat; allocation reads only common knowledge
# (clock, identity, own-heart state) — private sight feeds execution only.
# ---------------------------------------------------------------------------
proc myRole(b: Bot): Role =
  if b.iCarry: return roleCarrier
  if b.tick >= AllInTick: return roleWave
  let idx = max(b.myIdent, 0)
  # Own heart stolen: identity-keyed hunter subset peels; the rest race.
  if b.ownFlagKnown and not b.ownFlagHome and not b.mateCarrierSeen:
    if idx in [4, 5, 6, 7]: return roleHunter
  if b.mateCarrierSeen and idx in [0, 1, 2, 3, 4, 5]: return roleEscort
  case idx
  of 6: roleMid
  of 7: roleAnchor
  else: roleWave

proc fx(b: Bot, frac: float): int =
  ## Own-side-relative x: frac 0 = own home edge, 1 = enemy home edge.
  if b.myColor == "red": int(frac * float(b.mapW))
  else: int((1.0 - frac) * float(b.mapW))

proc planGoal(b: var Bot, role: Role): Pt =
  let h = b.mapH
  let laneY = int(0.28 * float(h))
  let idx = max(b.myIdent, 0)
  let spread = (idx - 3) * 14                    # de-stack the wave laterally
  case role
  of roleCarrier:
    # Home along the top lane, then the pedestal (capture zone reaches it).
    if abs(b.selfPos.x - b.fx(0.0)) > int(0.45 * float(b.mapW)):
      result = (b.fx(0.30), laneY + spread)
    else:
      result = b.ownPedestal
  of roleEscort:
    # Between the carrier and the enemy side, spread out.
    let toward = if b.myColor == "red": 70 else: -70
    result = (b.mateCarrierPos.x + toward, b.mateCarrierPos.y + spread * 2)
  of roleHunter:
    if b.thiefSeen:
      result = b.thiefPos
    else:
      # Converge on the two mid chokes on our half; kill returns the heart.
      if idx mod 2 == 0: result = (b.fx(0.38), int(0.25 * float(h)))
      else: result = (b.fx(0.38), int(0.75 * float(h)))
  of roleMid:
    # Rove the lower mid; the wave owns the top lane.
    if (b.tick div 400) mod 2 == 0:
      result = (b.fx(0.48), int(0.62 * float(h)))
    else:
      result = (b.fx(0.42), int(0.40 * float(h)))
  of roleAnchor:
    let toward = if b.myColor == "red": 80 else: -80
    result = (b.ownPedestal.x + toward, b.ownPedestal.y + 34)
  of roleWave:
    if b.tick < PressTick:
      result = (b.fx(0.30), laneY + spread)
    else:
      # Timetabled press down the top lane to the enemy pedestal.
      let myX = if b.myColor == "red": b.selfPos.x
                else: b.mapW - b.selfPos.x
      if myX < int(0.62 * float(b.mapW)):
        result = (b.fx(0.68), laneY + spread)
      elif not b.enemyFlagPlantedSeen and
          (b.mateCarrierSeen or dist(b.selfPos, b.enemyPedestal) < 140.0):
        # Steal already made (or pedestal reached and found empty): fall back
        # and guard the exfil lane instead of camping an empty pedestal.
        result = (b.fx(0.45), laneY + spread)
      else:
        result = b.enemyPedestal
  # Wounded detour: a VISIBLE med kit is guaranteed present; touch it.
  if role != roleCarrier and b.myHp > 0 and b.myHp < 3:
    for kit in b.medKits:
      if dist(b.selfPos, kit) < 220.0: return kit
  if role == roleCarrier and b.myHp == 1:
    for kit in b.medKits:
      if dist(b.selfPos, kit) < 150.0: return kit

# ---------------------------------------------------------------------------
# Combat executor.
# ---------------------------------------------------------------------------
proc pickTarget(b: Bot): int =
  result = -1
  var best = 1.0e18
  for i, e in b.enemies:
    var score = dist(b.selfPos, e.pos)
    if e.isThief: score -= 100000.0            # killing the thief returns it
    if score < best:
      best = score
      result = i

proc aimTolerance(d: float): int =
  ## Corridor half-width (8px) + target half-extent, as brads at distance d.
  clamp(int((14.0 / max(d, 20.0)) * float(AimBradsTurn) / (2.0 * PI)), 2, 12)

proc think(b: var Bot): uint8 =
  ## One frame -> one button mask. Never raises.
  if not b.alive:
    b.nadeCharging = false
    return 0
  if not b.haveColor or not b.navReady or not b.geomReady:
    return 0                       # first frames: geometry not learned yet
  let role = b.myRole()
  let goal = b.planGoal(role)
  var mask: uint8 = 0

  # --- locomotion ---
  var wantMove = dist(b.selfPos, goal) >= 5.0
  if wantMove:
    if b.tick < b.unstickUntil:
      mask = mask or (if b.unstickDir == 0: ButtonUp
                      elif b.unstickDir == 1: ButtonRight
                      elif b.unstickDir == 2: ButtonDown
                      else: ButtonLeft)
    else:
      mask = mask or b.moveMaskToward(goal)
    # Stuck detection: no progress while trying to move -> jiggle.
    if b.tick - b.stuckRefTick > 30:
      if dist(b.selfPos, b.stuckRefPos) < 7.0:
        b.unstickUntil = b.tick + 14
        b.unstickDir = (b.unstickDir + 1 + (b.tick div 31) mod 2) mod 4
      b.stuckRefPos = b.selfPos
      b.stuckRefTick = b.tick
  else:
    b.stuckRefPos = b.selfPos
    b.stuckRefTick = b.tick

  # --- aim + fire ---
  let ti = b.pickTarget()
  var desired: int
  if ti >= 0:
    let tp = b.enemies[ti].pos
    desired = bradsOf(tp.x - b.selfPos.x, tp.y - b.selfPos.y)
  else:
    # No contact: look where we are going (aim carries the vision cone);
    # anchors sweep their arc instead of staring.
    if role == roleAnchor and b.geomReady:
      let base = bradsOf(b.mapW div 2 - b.selfPos.x, 0)
      desired = (base + (if (b.tick div 60) mod 2 == 0: 40 else: -40) +
        AimBradsTurn) mod AimBradsTurn
    elif role == roleHunter and not b.thiefSeen and
        dist(b.selfPos, goal) < 40.0:
      desired = (b.estAim + 30) mod AimBradsTurn   # spin to scan
    else:
      desired = bradsOf(goal.x - b.selfPos.x, goal.y - b.selfPos.y)

  let diff = bradDiff(desired, b.estAim)
  if diff > 3: mask = mask or ButtonB              # CCW increases brads
  elif diff < -3: mask = mask or ButtonSelect      # CW decreases

  if ti >= 0 and b.fireReady and not b.firedLastFrame:
    let tp = b.enemies[ti].pos
    let d = dist(b.selfPos, tp)
    let aligned = abs(diff) <= aimTolerance(d)
    let sprayRange = if b.weaponSpray: d < 120.0 else: true
    # Carriers shoot at 1/3 rate: only spend it on close threats.
    let carrierOk = role != roleCarrier or d < 300.0
    if aligned and sprayRange and carrierOk and
        b.rayClear(b.selfPos, tp) and not b.mateInCorridor(tp):
      mask = mask or ButtonA
      b.firedLastFrame = true
  else:
    b.firedLastFrame = false

  # --- grenade (never detour for pickups; lob into a cluster on the press) ---
  if b.nadeCharging:
    if b.nadeChargeLeft <= 0:
      b.nadeCharging = false                      # release this frame = throw
    else:
      mask = mask or ButtonC
      dec b.nadeChargeLeft, max(b.client.frameAdvance, 1)
  elif b.carryNade and not b.weaponSpray and ti >= 0:
    # Cluster: two enemies within 60px of each other, centroid in range.
    var cl: Pt
    var found = false
    for i in 0 ..< b.enemies.len:
      for j in i + 1 ..< b.enemies.len:
        if dist(b.enemies[i].pos, b.enemies[j].pos) < 60.0:
          cl = ((b.enemies[i].pos.x + b.enemies[j].pos.x) div 2,
                (b.enemies[i].pos.y + b.enemies[j].pos.y) div 2)
          found = true
    if found:
      let d = dist(b.selfPos, cl)
      var mateClose = false
      for m in b.mates:
        if dist(m, cl) < float(GrenadeBlastRadius) + 12.0: mateClose = true
      let aimAt = bradsOf(cl.x - b.selfPos.x, cl.y - b.selfPos.y)
      if d > 70.0 and d < 240.0 and not mateClose and
          abs(bradDiff(aimAt, b.estAim)) <= 6:
        b.nadeCharging = true
        b.nadeChargeLeft = clamp(int(float(GrenadeChargeTicks) *
          (d - float(GrenadeMinRange)) / 217.0), 3, GrenadeChargeTicks)
        mask = mask or ButtonC

  result = mask

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
proc runBot(url: string) =
  let endpoint = ensureWsPath(url, "/player")
  var b = Bot(myIdent: -1, myHp: 3, flowGoal: -1)
  b.client = initProtocolClient()
  while true:
    var ws: WebSocket
    try:
      ws = newWebSocket(endpoint)
    except CatchableError:
      sleep(500)
      continue
    try:
      while true:
        if not b.client.receiveLatestFrame(ws, false):
          sleep(2)
          continue
        # Shared clock + open-loop aim advance for the ticks just consumed.
        let adv = max(b.client.frameAdvance, 1)
        b.tick += adv
        if (b.lastMask and ButtonB) != 0 and (b.lastMask and ButtonSelect) == 0:
          b.estAim = (b.estAim + AimTurnRate * adv) mod AimBradsTurn
        elif (b.lastMask and ButtonSelect) != 0 and (b.lastMask and ButtonB) == 0:
          b.estAim = ((b.estAim - AimTurnRate * adv) mod AimBradsTurn +
            AimBradsTurn) mod AimBradsTurn
        if b.client.walkabilityReady and not b.navReady:
          b.buildNav()
        parseFrame(b)
        # Respawn: aim snaps toward the enemy side; re-anchor the estimate.
        if b.alive and not b.wasAlive and b.haveColor:
          b.estAim = if b.myColor == "red": 0 else: AimBradsTurn div 2
          b.lastSide = ""
          b.unstickUntil = 0
          b.stuckRefPos = b.selfPos
          b.stuckRefTick = b.tick
        b.wasAlive = b.alive
        var mask: uint8 = 0
        try:
          mask = b.think()
        except CatchableError:
          mask = 0                    # never miss a tick on a think bug
        ws.send(inputBlob(mask), BinaryMessage)
        b.lastMask = mask
    except CatchableError:
      discard
    try: ws.close()
    except CatchableError: discard
    sleep(300)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    raise newException(ValueError, "COWORLD_PLAYER_WS_URL is required.")
  runBot(url)
