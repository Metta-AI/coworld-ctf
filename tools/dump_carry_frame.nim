## Steps a replay until a heart is being CARRIED (flag.carrier >= 0), then renders
## that broadcast frame and a tight crop around the carrier — a browser-free way
## to eyeball the carry pose (heart cradled front + perpendicular + arms).
import
  std/[algorithm, os, strformat],
  pixie, supersnappy,
  bitworld/spriteprotocol,
  ../src/ctf/global, ../src/ctf/replays, ../src/ctf/sim

proc renderFrame(sim: var SimServer): Image =
  var state = initGlobalViewerState()
  var next: GlobalViewerState
  let messages = sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket()
  var sprites: seq[tuple[id: int, image: Image]]
  proc spriteImage(id: int): Image =
    for s in sprites:
      if s.id == id: return s.image
    nil
  for m in messages:
    if m.kind == spkSprite:
      let raw = uncompress(m.sprite.compressedPixels)
      var image = newImage(m.sprite.width, m.sprite.height)
      for y in 0 ..< m.sprite.height:
        for x in 0 ..< m.sprite.width:
          let i = y * m.sprite.width + x
          image[x, y] = rgba(raw[i*4], raw[i*4+1], raw[i*4+2], raw[i*4+3])
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
    if image.isNil: continue
    result.draw(image, translate(vec2(float32(obj.x), float32(obj.y))))

proc main() =
  let
    replayPath = paramStr(1)
    outDir = if paramCount() >= 2: paramStr(2) else: "/tmp/carryframes"
  createDir(outDir)
  let data = loadReplay(replayPath)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var replay = initReplayPlayer(data)
  replay.looping = false
  replay.mismatchQuit = true
  let maxTick = replay.replayMaxTick()
  echo "maxTick=", maxTick, " playing=", replay.playing
  var shots = 0
  var everCarried = 0
  while sim.tickCount < maxTick and replay.playing:
    replay.stepReplay(sim)
    for team in Team:
      if sim.flags[team].carrier >= 0: inc everCarried
    # find an active carrier
    var carrierIdx = -1
    for team in Team:
      if sim.flags[team].carrier >= 0:
        carrierIdx = sim.flags[team].carrier
    if carrierIdx < 0: continue
    # sample a few carry frames spaced out
    if sim.tickCount mod 8 != 0: continue
    let canvas = sim.renderFrame()
    let p = sim.players[carrierIdx]
    let
      cx = p.x * RenderScale
      cy = p.y * RenderScale
      half = 70 * RenderScale
      x0 = max(0, cx - half)
      y0 = max(0, cy - half)
      x1 = min(canvas.width, cx + half)
      y1 = min(canvas.height, cy + half)
    let crop = canvas.subImage(x0, y0, x1 - x0, y1 - y0)
    let big = crop.resize(crop.width * 3, crop.height * 3)
    big.writeFile(outDir / &"carry-t{sim.tickCount:05}-p{carrierIdx}.png")
    inc shots
    echo "carry at tick ", sim.tickCount, " player ", carrierIdx,
      " aim ", p.aimBrads, " vel(", p.velX, ",", p.velY, ")"
    if shots >= 8: break
  echo "wrote ", shots, " carry crops to ", outDir,
    " (carry-tick samples seen: ", everCarried, ", last tick ", sim.tickCount, ")"

main()
