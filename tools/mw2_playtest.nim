## Re-simulates a recorded episode and dumps WHERE THE GAME ACTUALLY HAPPENED,
## so a map can be judged on how it plays rather than on how it looks.
##
## The MW2 pack's first two passes both got the footprints roughly right and
## still played nothing like the real maps: geometry in the correct place says
## nothing about whether players use it. This emits the raw evidence —
## per-tick occupancy, where players died, and where shots were fired — and
## tools/mw2_playtest.py renders it into heatmaps and a gap report.
##
## Usage: nim r tools/mw2_playtest.nim <replay.bitreplay> [--out <path.json>]
## Demo/audit tooling; not part of the server.
import
  std/[json, os, strutils],
  ../src/ctf/replays,
  ../src/ctf/sim

const
  Cell = 10   ## heatmap cell size (px). Fine enough to see a lane, coarse
              ## enough that one episode is not pure noise.

when isMainModule:
  let params = commandLineParams()
  if params.len == 0:
    quit("usage: mw2_playtest <replay.bitreplay> [--out <path.json>]", 1)
  let path = params[0]
  var outPath = ""
  for i in 1 ..< params.len:
    if params[i] == "--out" and i + 1 < params.len:
      outPath = params[i + 1]

  let gameDir = currentSourcePath().parentDir().parentDir()
  setCurrentDir(gameDir)
  let data = loadReplay(path)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var
    game = initSimServer(config)
    replay = initReplayPlayer(data)
  game.gameEventLoggingEnabled = false
  replay.looping = false
  replay.mismatchQuit = true

  let
    gw = (MapWidth + Cell - 1) div Cell
    gh = (MapHeight + Cell - 1) div Cell
  var
    occupancy = newSeq[int](gw * gh)      ## player-ticks spent per cell
    occRed = newSeq[int](gw * gh)
    occBlue = newSeq[int](gw * gh)
    deaths: seq[JsonNode]
    wasAlive: array[16, bool]
    lastPos: array[16, (int, int)]
    ticks = 0

  for i in 0 ..< 16:
    wasAlive[i] = true

  while replay.playing:
    replay.stepReplay(game)
    inc ticks
    for i in 0 ..< min(game.players.len, 16):
      let p = game.players[i]
      if p.alive:
        let
          cx = clamp(p.x div Cell, 0, gw - 1)
          cy = clamp(p.y div Cell, 0, gh - 1)
          idx = cy * gw + cx
        inc occupancy[idx]
        if p.team == Red: inc occRed[idx] else: inc occBlue[idx]
        lastPos[i] = (p.x, p.y)
      elif wasAlive[i]:
        # Died this tick: record where, which is where the fights are.
        let (dx, dy) = lastPos[i]
        deaths.add(%*{"x": dx, "y": dy, "tick": game.tickCount,
                      "team": (if p.team == Red: "red" else: "blue")})
      wasAlive[i] = p.alive

  # The static geometry the heatmap is read against.
  var wallCells = newSeq[bool](gw * gh)
  for cy in 0 ..< gh:
    for cx in 0 ..< gw:
      # A cell is "wall" when a player cannot stand at its center.
      wallCells[cy * gw + cx] =
        not game.canOccupy(cx * Cell + Cell div 2, cy * Cell + Cell div 2)

  let result = %*{
    "map": game.gameMap.name,
    "ticks": ticks,
    "cell": Cell,
    "gw": gw, "gh": gh,
    "occupancy": occupancy,
    "occRed": occRed,
    "occBlue": occBlue,
    "wall": wallCells,
    "deaths": deaths,
  }
  if outPath.len > 0:
    writeFile(outPath, $result)
    echo "wrote ", outPath, " (", game.gameMap.name, ", ", ticks, " ticks, ",
      deaths.len, " deaths)"
  else:
    echo $result
