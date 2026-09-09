## Dump the TEAM-BASE GEOMETRY of hosted .replay files as JSON lines.
##
## Measurement-only probe: for each replay it initializes the recorded sim and
## prints the map's team layout (sides/corners/plus), dimensions, per-team home
## anchors, per-team planted-flag (pedestal) positions at tick 0, and the
## per-team capture zone box. Nothing here touches policy code.
import std/[json, os], ../src/ctf/[replay_runtime, replays, sim]

proc zoneJson(z: CaptureZone): JsonNode =
  %*{"xLo": z.xLo, "xHi": z.xHi, "yLo": z.yLo, "yHi": z.yHi,
     "diag": z.diag, "disc": z.disc, "radius": z.radius,
     "anchorX": z.anchorX, "anchorY": z.anchorY}

for i in 1 .. paramCount():
  let path = paramStr(i)
  var row = newJObject()
  row["file"] = %path.extractFilename()
  try:
    let data = parseReplayBytes(readFile(path))
    let cfg = parseJson(data.configJson)
    var rt = initReplayRuntime(
      data, mismatchQuit = false, gameEventLoggingEnabled = false)
    let m = rt.sim.gameMap
    row["ok"] = %true
    row["map"] = %m.name
    row["w"] = %m.width
    row["h"] = %m.height
    row["cx"] = %m.center.x
    row["cy"] = %m.center.y
    row["layout"] = %($m.layout)
    row["symmetry"] = %($m.symmetry)
    row["homeDepth"] = %m.homeDepth
    row["genSeed"] = %m.genSeed
    row["endzone"] = %($m.endzone)
    row["endzoneRadius"] = %m.endzoneRadius
    row["teams"] = %cfg{"teams"}.getInt(2)
    row["seed"] = %cfg{"seed"}.getInt(-1)
    row["mapSeed"] = %cfg{"mapSeed"}.getInt(-1)
    row["mapName"] = %cfg{"map"}.getStr("")
    var anchors = newJArray()
    var flags = newJArray()
    var zones = newJArray()
    let n = cfg{"teams"}.getInt(2)
    for t in Red .. Yellow:
      if ord(t) >= n: break
      let a = m.teamAnchor(t)
      anchors.add %*{"team": $t, "x": a.x, "y": a.y}
      flags.add %*{"team": $t, "x": rt.sim.flags[t].x, "y": rt.sim.flags[t].y}
      zones.add %*{"team": $t, "zone": zoneJson(m.captureZone(t))}
    row["anchors"] = anchors
    row["flags"] = flags
    row["zones"] = zones
  except CatchableError as e:
    row["ok"] = %false
    row["err"] = %($e.name & ": " & e.msg)
  echo $row
