## Renders a replay to a numbered PNG frame sequence for movie assembly
## (ffmpeg). Steps the replay sim and composites the full broadcast frame
## every N ticks, rebuilding the sprite packet from scratch each sampled tick
## so no incremental-protocol state needs tracking. Demo tooling; not part of
## the server.
import
  std/[algorithm, os, strformat, strutils],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/replays, ../src/ctf/sim

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
            raw[i * 4 + 0], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]
          )
      sprites.add((m.sprite.id, image))
  # The spectator wire ships the board at RenderScale x the sim's map pixels
  # (map bands are full-width crops), so the map sprites and the canvas use
  # the scaled dimensions.
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

proc main() =
  let
    replayPath = paramStr(1)
    outDir = paramStr(2)
    everyN = if paramCount() >= 3: parseInt(paramStr(3)) else: 3
    fromTick = if paramCount() >= 4: parseInt(paramStr(4)) else: 0
    toTick = if paramCount() >= 5: parseInt(paramStr(5)) else: high(int)
  createDir(outDir)
  let data = loadReplay(replayPath)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var replay = initReplayPlayer(data)
  replay.looping = false
  replay.mismatchQuit = true
  let maxTick = min(toTick, replay.replayMaxTick())
  var frame = 0
  while sim.tickCount < maxTick and replay.playing:
    replay.stepReplay(sim)
    if sim.tickCount < fromTick or sim.tickCount mod everyN != 0:
      continue
    let canvas = sim.renderFrame()
    canvas.writeFile(outDir / &"frame-{frame:05}.png")
    inc frame
    if frame mod 100 == 0:
      echo "tick ", sim.tickCount, " -> ", frame, " frames"
  echo "wrote ", frame, " frames to ", outDir, " (last tick ",
    sim.tickCount, ")"

main()
