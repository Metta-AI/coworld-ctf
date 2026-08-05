## Dumps the metallic-paint shimmer as the board actually emits it: a row of
## cogs, one team per pair, with the LEFT cog of each pair flagged as the
## shimmer policy and the RIGHT one a stock control on the same team — the
## comparison the effect has to win. Several ticks are sampled down the rows so
## the sweep phase (and the per-seat phase offset) is visible in one strip.
##
## Board pixels straight out of `buildSpriteProtocolUpdates`, composited by the
## shared tool compositor, so what this shows is what the viewer draws. Tuning
## the sheen against a browser screenshot costs a rebuild + record + serve per
## try; this is the inner loop for the art itself.
##
##   nim c -d:release -r tools/shimmer_preview.nim /tmp/shimmer/strip.png
import
  std/[os, strutils],
  pixie,
  ../src/ctf/[global, shimmer, sim],
  toolutil

const
  Crop = 132          ## px of board kept around each cog in the strip.
  Cogs = 8
  Ticks = [0, 5, 10, 15, 20, 25, 30, 35]

proc main() =
  let outPath = if paramCount() >= 1: paramStr(1) else: "/tmp/shimmer-strip.png"
  var config = defaultGameConfig()
  config.teams = 4
  config.mapPath = "gen"
  config.mapGen.layout = "corners"
  config.mapSeed = 42
  config.slots.setLen(Cogs)
  var sim = initSimServer(config)
  # A seat's address IS its policy here: even seats are "metalpolicy", odd seats
  # the control, each with a hosted-style seat suffix so the strip also proves
  # the suffix stripping reaches the renderer.
  for i in 0 ..< Cogs:
    discard sim.addPlayer(
      (if i mod 2 == 0: "metalpolicy" else: "stockpolicy") & "_(" & $i & ")")
  sim.startGame()
  # One policy league-wide, seated on every team here so the strip shows the
  # sheen against a stock control on each team's own color.
  setShimmerPolicy("metalpolicy")

  let
    scale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
    cx = sim.gameMap.center.x
    cy = sim.gameMap.center.y
  proc pose(sim: var SimServer) =
    ## Park the cogs in a line across open floor, all aiming east, all alive.
    for i in 0 ..< Cogs:
      sim.players[i].team = Team(i div 2)
      sim.players[i].x = cx - (Cogs div 2) * Crop + i * Crop + Crop div 2
      sim.players[i].y = cy
      sim.players[i].aimBrads = 0
      sim.players[i].alive = true
    sim.phase = Playing

  var strip = newImage(Cogs * Crop, Ticks.len * Crop)
  for row, want in Ticks:
    while sim.tickCount < want:
      sim.step(newSeq[InputState](sim.players.len),
               newSeq[InputState](sim.players.len))
      sim.pose()
    sim.pose()
    let board = sim.renderBoardFrame(scale = scale)
    for i in 0 ..< Cogs:
      let
        px = sim.players[i].x * scale
        py = sim.players[i].y * scale
      var crop = newImage(Crop, Crop)
      for y in 0 ..< Crop:
        for x in 0 ..< Crop:
          let
            sx = px - Crop div 2 + x
            sy = py - Crop div 2 + y
          if sx >= 0 and sy >= 0 and sx < board.width and sy < board.height:
            crop.data[y * Crop + x] = board.data[sy * board.width + sx]
      strip.draw(crop, translate(vec2(float32(i * Crop), float32(row * Crop))))
  strip.writeFile(outPath)
  echo "wrote ", outPath, " (rows = ticks ", Ticks.join(","),
    "; each pair: LEFT = shimmer policy, RIGHT = stock control)"

main()
