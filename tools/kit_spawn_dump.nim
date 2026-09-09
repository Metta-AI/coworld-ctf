## Dumps ONE replay's med-kit geometry as a single JSON object.
##
## WHY: the policy routes wounded bots to two HARD-CODED "formula" addresses
##   MedKitA = (MapW div 2, MapH div 3)   MedKitB = (MapW div 2, 2*MapH div 3)
## which came from the two HAND-AUTHORED arenas (arena.nim L576 / L602). Every
## GENERATED board draws its kits instead:
##   * 2-team: four candidates on x = W/2 at (y1, H-1-y1, y2, H-1-y2) and a COIN
##     FLIP activates exactly ONE of the two pairs.
##   * 4-team: FOUR kits, the rot90 / quadMirror orbit of one drawn ring point.
## So the formula address is a claim about the map, and this tool is what checks
## it against ground truth.
##
## The sim is built and NOT stepped: initSimServer already calls resetMedKits
## (sim.nim L3206), so `sim.medKitSpawns` — the ACTUAL pickup points, nudged to
## the nearest walkable floor — is populated at construction. No replay walk is
## needed, which makes this ~30x cheaper than extract_events. Nothing here reads
## a recorded hash, so it also works on replays whose engine we could not
## re-simulate (the GameVersion gate lives in stepReplay, not in the config).
##
## Emits, on one line:
##   replay, episode (echoed from --episode), teams, slots, mapW/mapH (the
##   map's own size), arenaW/arenaH (the process-wide MapWidth/MapHeight const),
##   map name/layout/symmetry/genSeed, formula (the two policy addresses),
##   spawns (ACTIVE, from sim.medKitSpawns — the pickup truth),
##   mapSpawns (gameMap.medKitSpawns, pre-nudge), candidates (the DRAWN set;
##   on a 2-team board the two that the coin flip did NOT activate are the
##   perfectly-matched empty control), and nearest[] — distance from each
##   formula address to the nearest ACTIVE spawn.
##
## Usage: bin/kit_spawn_dump <replay-path> [--episode <id>]

import
  std/[json, math, os, strutils],
  ../src/ctf/sim,
  toolutil

type KitDumpError = object of CatchableError

const UsageText = "Usage: kit_spawn_dump <replay-path> [--episode <id>]"

proc fail(message: string) =
  raise newException(KitDumpError, message)

proc parseArgs(): tuple[replayPath, episode: string] =
  var
    paths: seq[string]
    params = commandLineParams()
    i = 0
  while i < params.len:
    let arg = params[i]
    if arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg == "--episode":
      if i + 1 >= params.len:
        fail("--episode requires a value.\n" & UsageText)
      inc i
      result.episode = params[i]
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
    inc i
  if paths.len != 1:
    fail("Expected exactly one replay path.\n" & UsageText)
  result.replayPath = paths[0].absolutePath()

proc dist(ax, ay, bx, by: int): float =
  sqrt(float((ax - bx) * (ax - bx) + (ay - by) * (ay - by)))

proc dumpKits(replayPath, episode: string): JsonNode =
  let previousDir = getCurrentDir()
  chdirGameDir()
  try:
    # Only the CONFIG is read: the map is deterministic in the recorded seed,
    # so no tick has to be simulated to know where its kits are.
    var config = defaultGameConfig()
    config.update(loadReplay(replayPath).configJson)
    var sim = initSimServer(config)

    let
      mapW = sim.gameMap.width
      mapH = sim.gameMap.height
      # The policy's two hard-coded addresses, computed exactly as
      # players/baseline/baseline.nim does from the walkability grid size.
      formula = [(mapW div 2, mapH div 3), (mapW div 2, 2 * mapH div 3)]

    var
      spawns = newJArray()      # ACTIVE pickups (post walkable-nudge)
      mapSpawns = newJArray()   # the map's own active points (pre-nudge)
      cands = newJArray()       # the DRAWN candidate set
    for s in sim.medKitSpawns:
      spawns.add(%*{"x": s.x, "y": s.y, "present": s.present})
    for p in sim.gameMap.medKitSpawns:
      mapSpawns.add(%*{"x": p.x, "y": p.y})
    for p in sim.gameMap.medKitCandidates:
      cands.add(%*{"x": p.x, "y": p.y})

    var nearest = newJArray()
    for (fx, fy) in formula:
      var best = -1.0
      var bx, by = -1
      for s in sim.medKitSpawns:
        let d = dist(fx, fy, s.x, s.y)
        if best < 0.0 or d < best:
          best = d
          bx = s.x
          by = s.y
      nearest.add(%*{"fx": fx, "fy": fy, "d": best, "sx": bx, "sy": by})

    result = %*{
      "replay": replayPath.extractFilename(),
      "episode": episode,
      "teams": sim.config.teams,
      "slots": sim.config.slots.len,
      "mapW": mapW, "mapH": mapH,
      "arenaW": MapWidth, "arenaH": MapHeight,
      "map": sim.gameMap.name,
      "layout": $sim.gameMap.layout,
      "symmetry": $sim.gameMap.symmetry,
      "genSeed": sim.gameMap.genSeed,
      "formula": %*[
        {"x": formula[0][0], "y": formula[0][1]},
        {"x": formula[1][0], "y": formula[1][1]}],
      "spawns": spawns,
      "mapSpawns": mapSpawns,
      "candidates": cands,
      "nearest": nearest,
    }
  finally:
    setCurrentDir(previousDir)

when isMainModule:
  try:
    let (replayPath, episode) = parseArgs()
    if not fileExists(replayPath):
      fail("Replay file does not exist: " & replayPath)
    echo $dumpKits(replayPath, episode)
  except KitDumpError as e:
    stderr.writeLine("kit_spawn_dump failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("kit_spawn_dump replay error: " & e.msg)
    quit(1)
  except CtfError as e:
    stderr.writeLine("kit_spawn_dump sim error: " & e.msg)
    quit(1)
