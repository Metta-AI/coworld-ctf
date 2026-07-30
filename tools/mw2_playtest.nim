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
  std/[json, os],
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
    ## The objective's own track. Where players walk says how the map is
    ## traversed; where the FLAG travels says how it is won, and the two are
    ## not the same picture — a map can be busy everywhere and still have one
    ## viable carry route.
    carries: seq[JsonNode]
    captureAt: seq[JsonNode]
    steals = 0
    captures = 0
    wasCarrier: array[Team, int]

  for i in 0 ..< 16:
    wasAlive[i] = true
  for t in Team:
    wasCarrier[t] = -1

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

    # Flag tracks. A flag is provably either home (carrier -1) or on an
    # enemy's back, so a -1 -> k edge is a steal.
    #
    # A capture cannot be read the same way, off a k -> -1 edge: scoring calls
    # finishGame, so the episode ENDS on the capture tick and the following
    # observation never happens -- which is why an earlier pass of this tool
    # reported 0 captures on every map INCLUDING the default arena, a
    # known-good control. Evaluate the engine's own predicate instead, on the
    # same state and with the same player-centre offset it uses.
    for t in Team:
      let f = game.flags[t]
      if f.carrier >= 0:
        # Sampled, not per-tick: a carry lasts hundreds of ticks and the
        # route is what matters, not the pixel-by-pixel walk.
        if ticks mod 4 == 0:
          carries.add(%*{"x": f.x, "y": f.y,
                         "flag": (if t == Red: "red" else: "blue")})
        if wasCarrier[t] < 0:
          inc steals
        let carrier = game.players[f.carrier]
        if carrier.alive:
          let
            cx = carrier.x + CollisionW div 2
            cy = carrier.y + CollisionH div 2
          if game.inCaptureZone(carrier.team, cx, cy):
            inc captures
            captureAt.add(%*{"x": cx, "y": cy, "tick": game.tickCount,
                             "team": (if carrier.team == Red: "red"
                                      else: "blue")})
      wasCarrier[t] = f.carrier

  # The static geometry the heatmap is read against.
  var wallCells = newSeq[bool](gw * gh)
  for cy in 0 ..< gh:
    for cx in 0 ..< gw:
      # A cell is "wall" when a player cannot stand at its center.
      wallCells[cy * gw + cx] =
        not game.canOccupy(cx * Cell + Cell div 2, cy * Cell + Cell div 2)

  proc pt(p: MapPoint): JsonNode = %*{"x": p.x, "y": p.y}
  proc rc(r: MapRect): JsonNode =
    %*{"x": r.x, "y": r.y, "w": r.w, "h": r.h}

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
    # The objective model, so the analysis measures the game as it is now
    # rather than the home-edge column it used to be. captureRadius 0 means
    # the map kept the legacy column.
    "carries": carries,
    "captureAt": captureAt,
    "steals": steals,
    "captures": captures,
    "redHome": pt(game.gameMap.teamHome(Red)),
    "blueHome": pt(game.gameMap.teamHome(Blue)),
    "captureRadius": game.gameMap.captureRadius,
    "redSpawn": rc(game.gameMap.redSpawn),
    "blueSpawn": rc(game.gameMap.blueSpawn),
    "trenches": block:
      var t: seq[JsonNode]
      for r in game.gameMap.trenches: t.add rc(r)
      t,
  }
  if outPath.len > 0:
    writeFile(outPath, $result)
    echo "wrote ", outPath, " (", game.gameMap.name, ", ", ticks, " ticks, ",
      deaths.len, " deaths)"
  else:
    echo $result
