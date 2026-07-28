## Renders consecutive board frames around a REAL bot spray burst from a recorded
## replay, as a filmstrip: proof the animation and the held-can art work through
## the true pipeline (replay -> sim -> delta sprite packets), not just a posed probe.
## Usage (repo root): nim r tools/spray_replay_frames.nim <replay> <fromTick> [n] [outDir]
import
  std/[algorithm, os, strutils, tables],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/replays, ../src/ctf/sim

proc main() =
  let
    replayPath = paramStr(1).absolutePath()
    fromTick = parseInt(paramStr(2))
    frameCount = if paramCount() >= 3: parseInt(paramStr(3)) else: 6
    outDir = if paramCount() >= 4: paramStr(4) else: "/tmp"
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  let data = loadReplay(replayPath)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var replay = initReplayPlayer(data)
  replay.looping = false
  replay.mismatchQuit = true

  var
    state = initGlobalViewerState()
    next: GlobalViewerState
    sprites: Table[int, Image]
    world: Table[int, SpritePacketObject]
    mapLayer = -1
    mapSpriteIds: seq[int]

  proc applyPacket() =
    for m in sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket():
      case m.kind
      of spkSprite:
        let raw = supersnappy.uncompress(m.sprite.compressedPixels)
        var image = newImage(m.sprite.width, m.sprite.height)
        for y in 0 ..< m.sprite.height:
          for x in 0 ..< m.sprite.width:
            let i = y * m.sprite.width + x
            image[x, y] = rgba(raw[i*4], raw[i*4+1], raw[i*4+2], raw[i*4+3])
        sprites[m.sprite.id] = image
        if m.sprite.width == MapWidth * RenderScale:
          mapSpriteIds.add(m.sprite.id)
      of spkObject:
        world[m.objectDef.id] = m.objectDef
        if m.objectDef.spriteId in mapSpriteIds:
          mapLayer = m.objectDef.layer
      of spkDeleteObject: world.del(m.objectId)
      of spkClearObjects: world.clear()
      else: discard
    state = next

  proc board(): Image =
    var objects: seq[SpritePacketObject]
    for _, o in world:
      if o.layer == mapLayer: objects.add o
    objects.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))
    result = newImage(MapWidth * RenderScale, MapHeight * RenderScale)
    result.fill(rgba(20, 18, 16, 255))
    for o in objects:
      if o.spriteId in sprites:
        result.draw(sprites[o.spriteId], translate(vec2(float32(o.x), float32(o.y))))

  # Wind to just before the burst, keeping the sprite world in sync.
  while sim.tickCount < fromTick - 1 and replay.playing:
    replay.stepReplay(sim)
    applyPacket()

  const W = 300
  const H = 190
  var frames: seq[Image]
  for f in 0 ..< frameCount:
    if not replay.playing: break
    replay.stepReplay(sim)
    applyPacket()
    # Center on whichever cog is mid-burst (else the last known sprayer).
    var cx, cy = -1
    for p in sim.players:
      if p.arcTicksLeft > 0 or p.hasPlasmaArc:
        cx = p.x + CollisionW div 2
        cy = p.y + CollisionH div 2
        if p.arcTicksLeft > 0: break
    if cx < 0: continue
    let full = board()
    let
      x0 = clamp(cx * RenderScale - W div 2, 0, MapWidth * RenderScale - W)
      y0 = clamp(cy * RenderScale - H div 2, 0, MapHeight * RenderScale - H)
    frames.add full.subImage(x0, y0, W, H)
  if frames.len == 0:
    echo "no frames captured"; quit(1)
  var strip = newImage(W, H * frames.len)
  for i, fr in frames:
    strip.draw(fr, translate(vec2(0, float32(i * H))))
  let path = outDir / "spray-replay-strip.png"
  strip.resize(W * 2, H * frames.len * 2).writeFile(path)
  echo "wrote ", path, "  ", frames.len, " frames from tick ", fromTick

main()
