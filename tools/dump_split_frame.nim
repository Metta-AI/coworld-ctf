## Eyes-on probe for the tank split fixes: base = wheels only (NO head/face),
## turret = head + smile + SIDE-mounted gun (off the aim ray), heart cradled
## forward. Renders REAL broadcast frames (buildSpriteProtocolUpdates, z-sorted
## like the client). Throwaway; not part of the server. Writes /tmp/split_*.png.
import
  std/[algorithm],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/sim

proc renderFrame(sim: var SimServer): Image =
  var
    state = initGlobalViewerState()
    next: GlobalViewerState
  let messages = sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket()
  var sprites: seq[tuple[id: int, image: Image]]
  proc spriteImage(id: int): Image =
    for s in sprites:
      if s.id == id:
        return s.image
    nil
  for m in messages:
    if m.kind == spkSprite:
      let raw = supersnappy.uncompress(m.sprite.compressedPixels)
      var image = newImage(m.sprite.width, m.sprite.height)
      for y in 0 ..< m.sprite.height:
        for x in 0 ..< m.sprite.width:
          let i = y * m.sprite.width + x
          image[x, y] = rgba(
            raw[i * 4 + 0], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3])
      sprites.add((m.sprite.id, image))
  var mapSprites: seq[int]
  for m in messages:
    if m.kind == spkSprite and m.sprite.width == MapWidth * RenderScale:
      mapSprites.add(m.sprite.id)
  var mapLayer = -1
  for m in messages:
    if m.kind == spkObject and m.objectDef.spriteId in mapSprites:
      mapLayer = m.objectDef.layer
  var objects: seq[SpritePacketObject]
  for m in messages:
    if m.kind == spkObject and m.objectDef.layer == mapLayer:
      objects.add(m.objectDef)
  objects.sort(proc (a, b: SpritePacketObject): int =
    result = cmp(a.z, b.z)
    if result == 0: result = cmp(a.y, b.y)
    if result == 0: result = cmp(a.id, b.id))
  result = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
  result.fill(rgba(20, 18, 16, 255))
  for obj in objects:
    let image = spriteImage(obj.spriteId)
    if image.isNil:
      continue
    result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))

proc cropAround(frame: Image, px, py, size: int): Image =
  let
    cx = px * RenderScale
    cy = py * RenderScale
    x0 = max(0, cx - size div 2)
    y0 = max(0, cy - size div 2)
  result = frame.subImage(
    x0, y0, min(size, frame.width - x0), min(size, frame.height - y0))

when isMainModule:
  var game = initSimServer(defaultGameConfig())
  let
    a = game.addPlayer("p0")
    b = game.addPlayer("p1")
    c = game.addPlayer("p2")
  game.startGame()
  # a: strafing — moving EAST while aiming NORTH (base E wheels, turret N head).
  game.players[a].x = 300; game.players[a].y = 300
  game.players[a].velX = MaxSpeed; game.players[a].velY = 0
  game.players[a].aimBrads = 64
  # b: backpedal — moving SOUTH while aiming NORTH.
  game.players[b].x = 500; game.players[b].y = 300
  game.players[b].velX = 0; game.players[b].velY = MaxSpeed
  game.players[b].aimBrads = 64
  # c: heart carrier — BLUE cog + RED heart, aim NE so the forward heart shows.
  game.players[c].team = Blue
  game.players[c].x = 700; game.players[c].y = 300
  game.players[c].velX = MaxSpeed; game.players[c].velY = 0
  game.players[c].aimBrads = 32
  game.players[c].carryingFlag = true
  game.flags[Red].carrier = c
  game.flags[Red].x = game.players[c].x + CollisionW div 2
  game.flags[Red].y = game.players[c].y + CollisionH div 2

  let frame = game.renderFrame()
  frame.cropAround(300, 300, 200).writeFile("/tmp/split_strafe.png")
  frame.cropAround(500, 300, 200).writeFile("/tmp/split_backpedal.png")
  frame.cropAround(700, 300, 240).writeFile("/tmp/split_carrier.png")
  echo "wrote /tmp/split_{strafe,backpedal,carrier}.png"
