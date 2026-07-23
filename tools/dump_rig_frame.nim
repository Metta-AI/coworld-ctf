## Eyes-on probe for the ARTICULATED rig emission: chassis + 3 legs + 3 caster
## wheels + head, arms when carrying. Renders REAL broadcast frames through
## buildSpriteProtocolUpdates (z-sorted like the client), stepping the sim over
## many ticks with ONE persistent viewer state so the CogDriveState controller
## builds up heading/turnAmt/casters. Throwaway. Writes /tmp/rigview/nim_rig_*.png.
import
  std/[algorithm],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/sim

var vstate = initGlobalViewerState()
# Sprite defs ship ONCE (at init); accumulate them across frames so a later
# delta frame's objects can still resolve their (init-defined) sprites.
var sprites: seq[tuple[id: int, image: Image]]

proc renderFrame(sim: var SimServer): Image =
  var next: GlobalViewerState
  let messages = sim.buildSpriteProtocolUpdates(vstate, next).parseSpritePacket()
  vstate = next
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
      # replace-or-add so a redefined id updates in place
      var found = false
      for k in 0 ..< sprites.len:
        if sprites[k].id == m.sprite.id:
          sprites[k].image = image; found = true; break
      if not found:
        sprites.add((m.sprite.id, image))
  # The map bands are defined once at init, so on a delta frame no full-size map
  # sprite is present — detect nothing and use MapLayerId (0) directly.
  var objects: seq[SpritePacketObject]
  for m in messages:
    if m.kind == spkObject and m.objectDef.layer == MapLayerId:
      objects.add(m.objectDef)
  objects.sort(proc (a, b: SpritePacketObject): int =
    result = cmp(a.z, b.z)
    if result == 0: result = cmp(a.y, b.y)
    if result == 0: result = cmp(a.id, b.id))
  result = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
  result.fill(rgba(60, 64, 52, 255))
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
  # a: continuous LEFT curve — velocity sweeps so heading keeps turning CCW
  #    (sustained +turnAmt -> left leg splays out).
  game.players[a].x = 300; game.players[a].y = 300
  game.players[a].aimBrads = 64
  # b: hard strafe — moving EAST while aiming NORTH (wheels caster east, head N).
  game.players[b].x = 620; game.players[b].y = 300
  game.players[b].velX = MaxSpeed; game.players[b].velY = 0
  game.players[b].aimBrads = 64
  # c: heart carrier — BLUE cog + RED heart, aim NE.
  game.players[c].team = Blue
  game.players[c].x = 940; game.players[c].y = 300
  game.players[c].velX = MaxSpeed; game.players[c].velY = 0
  game.players[c].aimBrads = 32
  game.players[c].carryingFlag = true
  game.flags[Red].carrier = c
  game.flags[Red].x = game.players[c].x + CollisionW div 2
  game.flags[Red].y = game.players[c].y + CollisionH div 2

  # Step ~40 sim ticks so the controller builds up turnAmt/casters. player a's
  # velocity sweeps CCW each tick to make a real left curve; others hold. PIN
  # each cog's position every tick (velocity drives the controller only; we
  # don't want the bodies translating out of the crop windows).
  import std/math
  let ax = 300; let bx = 620; let cxp = 940; let py = 300
  var frame: Image
  for t in 0 ..< 40:
    let ang = float(t) * 0.12
    game.players[a].x = ax; game.players[a].y = py
    game.players[a].velX = int(float(MaxSpeed) * cos(ang))
    game.players[a].velY = int(-float(MaxSpeed) * sin(ang))
    game.players[b].x = bx; game.players[b].y = py
    game.players[b].velX = MaxSpeed; game.players[b].velY = 0
    game.players[c].x = cxp; game.players[c].y = py
    game.players[c].velX = MaxSpeed; game.players[c].velY = 0
    game.flags[Red].x = cxp + CollisionW div 2
    game.flags[Red].y = py + CollisionH div 2
    game.tickCount = t   # sequential ticks so cogDrive integrates
    frame = game.renderFrame()

  frame.cropAround(ax, py, 220).writeFile("/tmp/rigview/nim_rig_leftcurve.png")
  frame.cropAround(bx, py, 220).writeFile("/tmp/rigview/nim_rig_strafe.png")
  frame.cropAround(cxp, py, 260).writeFile("/tmp/rigview/nim_rig_carry.png")
  echo "wrote /tmp/rigview/nim_rig_{leftcurve,strafe,carry}.png"
