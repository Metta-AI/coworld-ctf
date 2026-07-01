## Baseline capture-the-flag bot for Coworld CTF.
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The decision logic
## lives in `decideMask`: pick a role from the slot, then attack/defend/escort
## and shoot enemies that line up with where we are heading. Everything else is
## connection plumbing.
##
## Coordinate model: the per-player view is 128x128 screen-space. Our own avatar
## sits at the center (64, 64), so "direction to X" is just `objectCenter - center`.
## Facing == last movement direction (we shoot where we walk), so to fire at a
## target we briefly steer toward it.

import
  std/[math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols

const
  WebSocketPath = "/player"
  SelfX = ScreenWidth div 2     # our avatar sits at the screen center
  SelfY = ScreenHeight div 2
  CarryRadius = 10              # flag this close to center == we are carrying it
  OverlapRadius = 8            # a flag this close to a player == that player carries it
  FireRange = 46               # only shoot enemies within this screen distance
  CloseRange = 22             # "in my face" distance: worth turning to shoot / dodging
  FireDotMin = 0.55           # cos of the half-cone we are willing to fire into
  AimDotMin = 0.30            # looser cone: worth a brief steer to line up a close shot
  FriendlyDotMin = 0.85       # a teammate this aligned in front blocks the shot

type
  Team = enum
    Red, Blue

  Role = enum
    Attacker, Defender

  Target = object            # a screen-space point we want to move toward
    x, y: int

  Actor = object             # a visible player: offset from us + facing
    dx, dy: int
    facingRight: bool

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

proc objCenter(o: SpriteObjectInfo): (int, int) =
  ## Screen-space center of a sprite object.
  (o.x + o.width div 2, o.y + o.height div 2)

proc offset(o: SpriteObjectInfo): (int, int) =
  ## Screen-space offset of an object's center from our avatar.
  let (cx, cy) = objCenter(o)
  (cx - SelfX, cy - SelfY)

proc dist(dx, dy: int): float =
  hypot(float(dx), float(dy))

proc bitsToward(dx, dy: int): uint8 =
  ## Picks d-pad bits aiming at a screen-space offset. Diagonals allowed: any
  ## axis whose magnitude is a meaningful share of the move sets its bit.
  let
    ax = abs(dx)
    ay = abs(dy)
    thresh = max(ax, ay) div 2
  if ax >= thresh and ax > 0:
    result = result or (if dx > 0: ButtonRight else: ButtonLeft)
  if ay >= thresh and ay > 0:
    result = result or (if dy > 0: ButtonDown else: ButtonUp)

proc moveVec(mask: uint8): (float, float) =
  ## Unit-ish direction implied by the current d-pad bits.
  var dx, dy = 0.0
  if (mask and ButtonLeft) != 0: dx -= 1
  if (mask and ButtonRight) != 0: dx += 1
  if (mask and ButtonUp) != 0: dy -= 1
  if (mask and ButtonDown) != 0: dy += 1
  (dx, dy)

proc dotToward(dx, dy: int, mvx, mvy: float): float =
  ## Cosine between a target offset and our movement/facing direction.
  let d = dist(dx, dy)
  let mv = hypot(mvx, mvy)
  if d < 1 or mv < 1e-6: -1.0 else: (float(dx) * mvx + float(dy) * mvy) / (d * mv)

proc actorsFor(
    client: ProtocolClient, rightLabel, leftLabel: string): seq[Actor] =
  ## Visible players of one color as offsets-from-us plus facing (right/left).
  for o in client.spriteObjectsWithLabel(rightLabel):
    let (dx, dy) = o.offset()
    result.add(Actor(dx: dx, dy: dy, facingRight: true))
  for o in client.spriteObjectsWithLabel(leftLabel):
    let (dx, dy) = o.offset()
    result.add(Actor(dx: dx, dy: dy, facingRight: false))

proc nearest(actors: seq[Actor]): int =
  ## Index of the actor closest to us, or -1 when empty.
  result = -1
  var best = float.high
  for i, a in actors:
    let d = dist(a.dx, a.dy)
    if d < best:
      best = d
      result = i

proc homeTarget(team: Team): Target =
  ## Far off-screen point on our home edge: Red = left, Blue = right.
  Target(x: (if team == Red: -1000 else: 1000), y: rand(-6 .. 6))

proc decideMask(client: ProtocolClient, team: Team, role: Role): uint8 =
  ## Core CTF policy for one frame.
  let
    myColor = (if team == Red: "red" else: "blue")
    enemyColor = (if team == Red: "blue" else: "red")
    enemies = client.actorsFor("player " & enemyColor & " right",
                               "player " & enemyColor & " left")
    mates = client.actorsFor("player " & myColor & " right",
                             "player " & myColor & " left")

  # Locate the flag and classify who (if anyone) holds it. A carried flag rides
  # on its carrier's sprite, so a flag overlapping a player means that player is
  # the carrier; a flag near our center means we are.
  let flags = client.spriteObjectsWithLabel("flag")
  var
    iCarry = false
    flagOff = (0, 0)          # offset to a loose flag or an enemy carrier
    haveFlag = false
    mateCarry = false
    mateCarryOff = (0, 0)
    enemyCarry = false
  if flags.len > 0:
    let f = flags[0]
    let (fdx, fdy) = f.offset()
    haveFlag = true
    flagOff = (fdx, fdy)
    if abs(fdx) <= CarryRadius and abs(fdy) <= CarryRadius:
      iCarry = true
    else:
      # Overlaps a teammate? escort. Overlaps an enemy? intercept.
      for m in mates:
        if dist(fdx - m.dx, fdy - m.dy) <= OverlapRadius:
          mateCarry = true
          mateCarryOff = (fdx, fdy)
          break
      if not mateCarry:
        for e in enemies:
          if dist(fdx - e.dx, fdy - e.dy) <= OverlapRadius:
            enemyCarry = true
            break

  # Pick a movement target from role + flag situation.
  var target: Target
  if iCarry:
    target = homeTarget(team)                    # beeline home with the flag
  elif mateCarry:
    # Escort our carrier: sit a little behind them toward home, covering.
    let (mx, my) = mateCarryOff
    let homeSign = (if team == Red: -1 else: 1)
    target = Target(x: mx + homeSign * 14, y: my + rand(-4 .. 4))
  elif enemyCarry:
    target = Target(x: flagOff[0], y: flagOff[1]) # chase the enemy carrier down
  elif role == Defender and not haveFlag:
    # No flag in view: hold near home and face the incoming lane.
    if enemies.len > 0:
      let e = enemies[nearest(enemies)]
      target = Target(x: e.dx, y: e.dy)
    else:
      target = homeTarget(team)
  elif haveFlag:
    target = Target(x: flagOff[0], y: flagOff[1]) # go grab the loose flag
  else:
    # Flag not visible: follow the off-screen arrow toward it.
    let arrows = client.spriteObjectsWithLabel("flag arrow")
    if arrows.len > 0:
      let (ax, ay) = arrows[0].offset()
      target = Target(x: ax, y: ay)
    else:
      target = Target(x: rand(-20 .. 20), y: rand(-20 .. 20))

  # If a close enemy is roughly ahead, bias our heading toward it so we can shoot;
  # a one-shot kill is worth a brief detour.
  let nEnemy = nearest(enemies)
  var aiming = false
  if nEnemy >= 0:
    let e = enemies[nEnemy]
    if dist(e.dx, e.dy) <= CloseRange:
      aiming = true
      target = Target(x: e.dx, y: e.dy)

  var mask = bitsToward(target.x, target.y)
  if mask == 0:
    mask = [ButtonUp, ButtonDown, ButtonLeft, ButtonRight].sample()

  # Retreat/jink: if a close enemy is aimed at us and we are NOT closing to shoot,
  # sidestep instead of walking into their muzzle. A right-facer to our left (or a
  # left-facer to our right) has us in front of its gun.
  if not aiming and nEnemy >= 0:
    let e = enemies[nEnemy]
    if dist(e.dx, e.dy) <= CloseRange and
        ((e.facingRight and e.dx < 0) or (not e.facingRight and e.dx > 0)):
      mask = bitsToward(-e.dy, e.dx)             # strafe perpendicular to the threat
      if mask == 0:
        mask = [ButtonUp, ButtonDown, ButtonLeft, ButtonRight].sample()

  # Firing: shoot the nearest enemy that is in range, inside our cone, and not
  # screened by a teammate directly in the line.
  let (mvx, mvy) = moveVec(mask)
  if hypot(mvx, mvy) > 0 and nEnemy >= 0:
    let e = enemies[nEnemy]
    let ed = dist(e.dx, e.dy)
    if ed <= FireRange:
      let cone = if ed <= CloseRange: AimDotMin else: FireDotMin
      if dotToward(e.dx, e.dy, mvx, mvy) >= cone:
        # Friendly-fire guard: a closer teammate tightly in front blocks the shot.
        var blocked = false
        for m in mates:
          if dist(m.dx, m.dy) < ed and
              dotToward(m.dx, m.dy, mvx, mvy) >= FriendlyDotMin:
            blocked = true
            break
        if not blocked:
          mask = mask or ButtonA
  mask

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Red else: Blue)
    # Two seats per team: the lower two (slots 0/1 & 2/3 within a team) attack,
    # the rest defend. slot div 2 is the per-team seat index (0..3).
    role = (if (slot div 2) < 2: Attacker else: Defender)
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  echo "baseline slot=", slot, " team=", team, " role=", role, " -> ", endpoint
  let client = initProtocolClient()
  while true:
    try:
      let ws = newWebSocket(endpoint)
      echo "connected ", endpoint
      client.reset()
      var lastMask = 0xff'u8
      while true:
        if not client.receiveLatestFrame(ws, false):
          continue
        let mask = decideMask(client, team, role)
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
