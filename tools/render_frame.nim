## Renders one broadcast frame of a replay to a PNG: steps the replay sim to a
## tick where both a fresh HIT and a fresh MISS tracer are in flight, builds the
## global sprite packet, and composites the map-layer objects. Demo tooling for
## the hit-bright/miss-faded tracer rendering; not part of the server.
import
  std/[algorithm, os, strutils],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/replays, ../src/ctf/sim

proc main() =
  let
    replayPath = paramStr(1)
    fromTick = parseInt(paramStr(2))
    toTick = parseInt(paramStr(3))
    outPath = paramStr(4)
  let data = loadReplay(replayPath)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var replay = initReplayPlayer(data)
  replay.looping = false
  replay.mismatchQuit = true

  while sim.tickCount < fromTick:
    replay.stepReplay(sim)
  var pickTick = -1
  while sim.tickCount < toTick:
    replay.stepReplay(sim)
    var hits, misses = 0
    for shot in sim.recentShots:
      let age = sim.tickCount - shot.firedTick
      if age <= 4:
        if shot.hit: inc hits else: inc misses
    if hits >= 1 and misses >= 1:
      pickTick = sim.tickCount
      break
  if pickTick < 0:
    echo "no tick with fresh hit+miss tracers in ", fromTick, "..", toTick
    quit(1)
  echo "rendering tick ", pickTick

  var
    state = initGlobalViewerState()
    next: GlobalViewerState
  let messages = sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket()

  # Sprite id -> decoded RGBA image.
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

  # Find the map background: the object whose sprite is the full-map image.
  # Everything on its layer composites in z order.
  var mapLayer = -1
  var mapSprites: seq[int]
  for m in messages:
    if m.kind == spkSprite and m.sprite.width == MapWidth:
      mapSprites.add(m.sprite.id)
  for m in messages:
    if m.kind == spkObject and m.objectDef.spriteId in mapSprites:
      mapLayer = m.objectDef.layer
  var objects: seq[SpritePacketObject]
  for m in messages:
    if m.kind == spkObject and m.objectDef.layer == mapLayer:
      objects.add(m.objectDef)
  objects.sort(proc (a, b: SpritePacketObject): int = cmp(a.z, b.z))

  var canvas = newImage(MapWidth, MapHeight)
  canvas.fill(rgba(20, 18, 16, 255))
  for obj in objects:
    let image = spriteImage(obj.spriteId)
    if image.isNil:
      continue
    canvas.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))
  canvas.writeFile(outPath)
  echo "wrote ", outPath

  # Zoomed crops of the youngest hit and youngest miss tracer for comparison.
  proc crop(cx, cy: int, tag: string) =
    let
      w = 260
      h = 180
      x0 = clamp(cx - w div 2, 0, MapWidth - w)
      y0 = clamp(cy - h div 2, 0, MapHeight - h)
    var sub = canvas.subImage(x0, y0, w, h)
    var big = sub.resize(w * 3, h * 3)
    let cropPath = outPath.changeFileExt("") & "-" & tag & ".png"
    big.writeFile(cropPath)
    echo "wrote ", cropPath
  var bestHitAge = 1000
  var bestMissAge = 1000
  var hitShot, missShot: ShotFx
  for shot in sim.recentShots:
    let age = sim.tickCount - shot.firedTick
    if shot.hit and age < bestHitAge:
      bestHitAge = age
      hitShot = shot
    if not shot.hit and age < bestMissAge:
      bestMissAge = age
      missShot = shot
  echo "hit shot (", hitShot.x0, ",", hitShot.y0, ")->(", hitShot.x1, ",",
    hitShot.y1, ") age ", bestHitAge
  echo "miss shot (", missShot.x0, ",", missShot.y0, ")->(", missShot.x1, ",",
    missShot.y1, ") age ", bestMissAge
  crop((hitShot.x0 + hitShot.x1) div 2, (hitShot.y0 + hitShot.y1) div 2, "hit")
  crop((missShot.x0 + missShot.x1) div 2, (missShot.y0 + missShot.y1) div 2,
    "miss")

main()
