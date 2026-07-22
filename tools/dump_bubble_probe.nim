## Renders one broadcast frame with a shield-carrying cog to verify the
## forcefield bubble wraps the cog on the 2x spectator board (placement +
## sprite scale), and that the overhead shield marker only appears once the
## bubble pops. Throwaway eyes-on probe; not part of the server.
import
  std/[algorithm],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/sim

const
  # Broadcast object-id pools, mirrored from global.nim's private consts.
  ShieldBubbleObjectBase = 19680
  ShieldCarryObjectBase = 19620

proc renderFrame(sim: var SimServer): Image =
  ## Composites the map-layer objects of one full broadcast packet, exactly
  ## like tools/render_replay_movie.nim.
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
            raw[i * 4 + 0], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]
          )
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
  objects.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))
  result = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
  result.fill(rgba(20, 18, 16, 255))
  for obj in objects:
    let image = spriteImage(obj.spriteId)
    if image.isNil:
      continue
    result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))

proc cropAround(frame: Image, px, py, size: int): Image =
  ## size x size crop of the RenderScale'd frame centered on map-px (px, py).
  let
    cx = px * RenderScale
    cy = py * RenderScale
    x0 = max(0, cx - size div 2)
    y0 = max(0, cy - size div 2)
  result = frame.subImage(
    x0, y0,
    min(size, frame.width - x0), min(size, frame.height - y0))

when isMainModule:
  var game = initSimServer(defaultGameConfig())
  let
    red = game.addPlayer("red0")
    blue = game.addPlayer("blue0")
  game.startGame()
  game.players[red].x = 300
  game.players[red].y = 300
  game.players[red].aimBrads = 0
  game.players[red].hasShield = true
  game.players[red].hp = 6
  game.players[blue].x = 500
  game.players[blue].y = 300

  # Frame 1: bubble up (hp 6) — expect the ring wrapping the cog, no marker.
  let f1 = game.renderFrame()
  f1.cropAround(300 + CollisionW div 2, 300 + CollisionH div 2, 220)
    .writeFile("/tmp/bubble_up.png")

  # Frame 2: an impact from the east — expect the blink/dent variant, aligned.
  for i in 0 ..< game.players.len:
    game.players[i].spawnProtect = 0
  game.players[blue].x = 300 + 30
  game.players[blue].aimBrads = 128
  game.players[blue].fireCooldown = 0
  game.tryFire(blue)
  let f2 = game.renderFrame()
  f2.cropAround(300 + CollisionW div 2, 300 + CollisionH div 2, 220)
    .writeFile("/tmp/bubble_hit.png")

  # Frame 3: bubble popped (hp 3) — expect NO ring, small marker overhead.
  game.players[red].hp = 3
  let f3 = game.renderFrame()
  f3.cropAround(300 + CollisionW div 2, 300 + CollisionH div 2, 220)
    .writeFile("/tmp/bubble_popped.png")

  echo "wrote /tmp/bubble_up.png /tmp/bubble_hit.png /tmp/bubble_popped.png"

  # Numeric check: dump the bubble + player objects from one packet, with the
  # bubble back up so its object is present. The bubble center must land on
  # the player center minus ShieldBubbleLagPx along the aim (in render px).
  game.players[red].hp = 6
  var
    state2 = initGlobalViewerState()
    next2: GlobalViewerState
  let messages = game.buildSpriteProtocolUpdates(state2, next2).parseSpritePacket()
  var spriteDims: seq[tuple[id, w, h: int]]
  for m in messages:
    if m.kind == spkSprite:
      spriteDims.add((m.sprite.id, m.sprite.width, m.sprite.height))
  for m in messages:
    if m.kind == spkObject:
      let o = m.objectDef
      if o.id >= ShieldBubbleObjectBase and o.id < ShieldBubbleObjectBase + 16 or
         o.id >= ShieldCarryObjectBase and o.id < ShieldCarryObjectBase + 16 or
         o.id >= PlayerObjectBase and o.id < PlayerObjectBase + 16:
        var w, h = -1
        for s in spriteDims:
          if s.id == o.spriteId:
            w = s.w; h = s.h
        echo "obj ", o.id, " sprite ", o.spriteId, " (", w, "x", h,
          ") at (", o.x, ",", o.y, ") center (",
          o.x + w div 2, ",", o.y + h div 2, ")"
