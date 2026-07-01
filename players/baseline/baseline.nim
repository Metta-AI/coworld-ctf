## Baseline capture-the-flag bot for Coworld CTF.
##
## Speaks the Bitworld Sprite v1 protocol over a websocket. The decision logic
## lives in `decideMask`: grab the flag, run it home, and shoot enemies that
## line up with where we are heading. Everything else is connection plumbing.

import
  std/[math, os, random, strutils],
  bitworld/spriteprotocol,
  whisky,
  baseline/protocols

const
  WebSocketPath = "/player"
  SelfX = ScreenWidth div 2     # our avatar sits at the screen center
  SelfY = ScreenHeight div 2
  SpriteHalf = 6                # half of the 12px sprite, to find object centers
  CarryRadius = 10              # flag this close to center == we are carrying it
  FireRange = 40                # only shoot enemies within this screen distance
  FireDotMin = 0.5             # cos of the half-cone we are willing to fire into

type
  Team = enum
    Red, Blue

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

proc decideMask(client: ProtocolClient, team: Team): uint8 =
  ## Core CTF policy for one frame.
  let
    enemyRight = (if team == Red: "player blue right" else: "player red right")
    enemyLeft = (if team == Red: "player blue left" else: "player red left")
  var enemies = client.spriteObjectsWithLabel(enemyRight)
  enemies.add(client.spriteObjectsWithLabel(enemyLeft))

  let flags = client.spriteObjectsWithLabel("flag")
  var
    carrying = false
    flagDx = 0
    flagDy = 0
    haveFlagTarget = false
  if flags.len > 0:
    let (fx, fy) = objCenter(flags[0])
    flagDx = fx - SelfX
    flagDy = fy - SelfY
    haveFlagTarget = true
    if abs(flagDx) <= CarryRadius and abs(flagDy) <= CarryRadius:
      carrying = true

  # Choose a movement target.
  var tx, ty: int
  if carrying:
    # Head for our home edge: Red = left (small x), Blue = right (large x).
    tx = (if team == Red: -1000 else: 1000)
    ty = rand(-6 .. 6)                 # slight wander so escorts don't stack
  elif haveFlagTarget:
    tx = flagDx
    ty = flagDy
  else:
    # Flag not visible: follow the off-screen arrow toward it.
    let arrows = client.spriteObjectsWithLabel("flag arrow")
    if arrows.len > 0:
      let (ax, ay) = objCenter(arrows[0])
      tx = ax - SelfX
      ty = ay - SelfY
    else:
      # Nothing to chase yet: drift toward center with jitter to avoid deadlock.
      tx = rand(-20 .. 20)
      ty = rand(-20 .. 20)

  var mask = bitsToward(tx, ty)
  if mask == 0:
    mask = [ButtonUp, ButtonDown, ButtonLeft, ButtonRight].sample()

  # Fire when an enemy lines up with our heading and is in range.
  let (mvx, mvy) = moveVec(mask)
  let mvLen = hypot(mvx, mvy)
  if mvLen > 0:
    for e in enemies:
      let (ex, ey) = objCenter(e)
      let
        edx = float(ex - SelfX)
        edy = float(ey - SelfY)
        dist = hypot(edx, edy)
      if dist > FireRange or dist < 1:
        continue
      let dot = (edx * mvx + edy * mvy) / (dist * mvLen)
      if dot >= FireDotMin:
        mask = mask or ButtonA
        break
  mask

proc runBot(url: string) =
  ## Connects, then loops frames forever, reconnecting on disconnect.
  let
    slot = slotFromUrl(url)
    team = (if slot mod 2 == 0: Red else: Blue)
    endpoint = ensureWsPath(url, WebSocketPath)
  randomize(slot * 7919 + 1)
  echo "baseline slot=", slot, " team=", team, " -> ", endpoint
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
        let mask = decideMask(client, team)
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
