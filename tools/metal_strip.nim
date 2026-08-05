## Eyeball harness for the metallic cog material (rig_art.applyCogMetal).
##
## The acceptance question is never "does it look good zoomed in" — it is "at
## TRUE viewer zoom, does the flagged cog read as obviously metallic next to the
## stock teammate standing beside it". So every artifact here is rendered at the
## real board scale, box-downsampled to the real embed scale FIRST, and only then
## nearest-upscaled for a human to inspect. Nothing is ever resampled up before
## the downsample, which would flatter the effect exactly where it is weakest.
##
##   nim c -d:release -r tools/metal_strip.nim <outDir> [screenPerMap] [zoom]
##
## Writes:
##   truezoom_pair.png     flagged | stock, at 1:1 embed pixels (the honest look)
##   truezoom_pair_<z>x.png    the same pixels, nearest-upscaled
##   rotation_strip.png    one flagged cog at all 16 aim steps over its stock
##                         twin — proof the highlight moves with ORIENTATION
##   time_strip.png        one flagged cog at a FIXED aim across a full glint
##                         cycle — proof it animates while stationary
import
  std/[math, os, strformat, strutils],
  pixie,
  ../src/ctf/[global, shimmer, sim, sim_types],
  toolutil

const
  Seats = 8          ## 4 teams x (flagged, control).
  Spacing = 130      ## map px between posed cogs.
  CropMap = 40       ## crop side in MAP px around a cog.

proc boxDownsample(src: Image, factor: float): Image =
  ## Area-average downsample — what the browser does when it fits the emitted
  ## board into the embed box. Nearest sampling would preserve sub-pixel spikes
  ## the real viewer averages away, i.e. it would lie in the effect's favour.
  let
    outW = max(1, int(float(src.width) * factor))
    outH = max(1, int(float(src.height) * factor))
    step = 1.0 / factor
  result = newImage(outW, outH)
  for oy in 0 ..< outH:
    let
      y0 = int(float(oy) * step)
      y1 = min(src.height, max(y0 + 1, int(float(oy + 1) * step)))
    for ox in 0 ..< outW:
      let
        x0 = int(float(ox) * step)
        x1 = min(src.width, max(x0 + 1, int(float(ox + 1) * step)))
      var r, g, b, n = 0.0
      for y in y0 ..< y1:
        for x in x0 ..< x1:
          let c = src.data[y * src.width + x]
          r += float(c.r); g += float(c.g); b += float(c.b); n += 1.0
      result.data[oy * outW + ox] = rgbx(
        uint8(clamp(r / n, 0.0, 255.0)), uint8(clamp(g / n, 0.0, 255.0)),
        uint8(clamp(b / n, 0.0, 255.0)), 255)

proc cropAt(img: Image, cxMap, cyMap: int, screenPerMap: float): Image =
  let
    side = max(1, int(float(CropMap) * screenPerMap))
    cx = int(float(cxMap) * screenPerMap) - side div 2
    cy = int(float(cyMap) * screenPerMap) - side div 2
  result = newImage(side, side)
  for y in 0 ..< side:
    for x in 0 ..< side:
      let
        sx = cx + x
        sy = cy + y
      if sx >= 0 and sy >= 0 and sx < img.width and sy < img.height:
        result.data[y * side + x] = img.data[sy * img.width + sx]

proc upscale(src: Image, zoom: int): Image =
  result = newImage(src.width * zoom, src.height * zoom)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      result.data[y * result.width + x] =
        src.data[(y div zoom) * src.width + (x div zoom)]

proc buildSim(): SimServer =
  var config = defaultGameConfig()
  config.teams = 4
  config.mapPath = "gen"
  config.mapGen.layout = "corners"
  config.mapSeed = 42
  config.slots.setLen(Seats)
  result = initSimServer(config)
  for i in 0 ..< Seats:
    discard result.addPlayer(
      (if i mod 2 == 0: "metalpolicy" else: "stockpolicy") & "_(" & $i & ")")
  result.startGame()

proc pose(sim: var SimServer, aim: int) =
  ## Park every cog on open floor in team pairs, all at one aim step, all alive.
  let
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
  for i in 0 ..< Seats:
    sim.players[i].team = Team(i div 2)
    sim.players[i].x = cx - (Seats div 2) * Spacing + i * Spacing + Spacing div 2
    sim.players[i].y = cy
    sim.players[i].aimBrads = aim * (AimBradsTurn div SoldierRotations)
    sim.players[i].alive = true
  sim.phase = Playing

proc main() =
  chdirGameDir()
  let
    outDir = if paramCount() >= 1: paramStr(1) else: ".harness/metal"
    screenPerMap = if paramCount() >= 2: parseFloat(paramStr(2)) else: 0.46
    zoom = if paramCount() >= 3: parseInt(paramStr(3)) else: 6
  createDir(outDir)
  var sim = buildSim()
  let
    scale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
    factor = screenPerMap / float(scale)
  echo &"# board {sim.gameMap.width}x{sim.gameMap.height} map px, emitted at " &
    &"{scale}x, downsampled {factor:.3f} -> " &
    &"{int(float(sim.gameMap.width) * screenPerMap)} screen px"

  proc frameAt(aim, tick: int): Image =
    sim.tickCount = tick
    sim.pose(aim)
    setShimmerPolicy("metalpolicy")
    boxDownsample(sim.renderBoardFrame(scale = scale), factor)

  # --- the honest look: flagged and stock, same team, side by side, 1:1 ---
  block:
    let
      board = frameAt(2, 0)
      side = max(1, int(float(CropMap) * screenPerMap))
    var pair = newImage(side * 2 + 4, side)
    pair.draw(board.cropAt(sim.players[0].x, sim.players[0].y, screenPerMap))
    pair.draw(board.cropAt(sim.players[1].x, sim.players[1].y, screenPerMap),
      translate(vec2(float32(side + 4), 0)))
    pair.writeFile(outDir / "truezoom_pair.png")
    pair.upscale(zoom).writeFile(outDir / &"truezoom_pair_{zoom}x.png")
    # All four palette slugs at once: a mark that only works on red is not a mark.
    var quad = newImage((side * 2 + 4) * 4 + 24, side)
    for t in 0 ..< 4:
      let ox = float32(t * (side * 2 + 4 + 8))
      quad.draw(board.cropAt(sim.players[t * 2].x, sim.players[t * 2].y,
        screenPerMap), translate(vec2(ox, 0)))
      quad.draw(board.cropAt(sim.players[t * 2 + 1].x, sim.players[t * 2 + 1].y,
        screenPerMap), translate(vec2(ox + float32(side + 4), 0)))
    quad.upscale(zoom).writeFile(outDir / &"truezoom_allteams_{zoom}x.png")

  # --- ROTATION: the headline cue. 16 aim steps, glint phase held fixed, so
  # every difference down the strip is caused by ORIENTATION alone. ---
  block:
    let side = max(1, int(float(CropMap) * screenPerMap))
    var strip = newImage(side * SoldierRotations, side * 2)
    for aim in 0 ..< SoldierRotations:
      let board = frameAt(aim, 0)
      strip.draw(board.cropAt(sim.players[0].x, sim.players[0].y, screenPerMap),
        translate(vec2(float32(aim * side), 0)))
      strip.draw(board.cropAt(sim.players[1].x, sim.players[1].y, screenPerMap),
        translate(vec2(float32(aim * side), float32(side))))
    strip.upscale(zoom).writeFile(outDir / "rotation_strip.png")

  # --- TIME: aim held fixed, one full glint cycle. A parked cog must still
  # shimmer, or the effect vanishes the moment a cog holds an angle. ---
  block:
    let side = max(1, int(float(CropMap) * screenPerMap))
    var strip = newImage(side * CogMetalSweepFrames, side * 2)
    for p in 0 ..< CogMetalSweepFrames:
      let board = frameAt(2, p * CogMetalTicksPerFrame)
      strip.draw(board.cropAt(sim.players[0].x, sim.players[0].y, screenPerMap),
        translate(vec2(float32(p * side), 0)))
      strip.draw(board.cropAt(sim.players[1].x, sim.players[1].y, screenPerMap),
        translate(vec2(float32(p * side), float32(side))))
    strip.upscale(zoom).writeFile(outDir / "time_strip.png")

  echo "# wrote ", outDir

main()
