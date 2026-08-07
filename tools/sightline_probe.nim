## sightline_probe — the geometry half of "is a long sightline a kill lane?".
##
## Emits ONE JSON object per map, so a play-evidence join can be done in python
## without parsing a report. Takes the same map arguments as `map_eval`
## ("arena", "arena-large", "gen:<seed>", "pool:<i>", or a mapSpec .json path),
## which matters here because the 210 stored episodes were played from mapSpec
## FILES: scoring the file removes the generator-drift confound entirely, where
## re-generating `(seed, attempt)` on a moved tree would silently score a
## different map than the one that was played.
##
##   sightline_probe --teams 2 /tmp/spread_wide/s1001a8.json arena arena-large
##
## `--teams` applies to `gen:`/`pool:` only. A .json spec and a hand-authored
## map carry their own team count, and the probe PRINTS the one it measured so
## a batch cannot silently mix denominators.

import
  std/[json, os, strutils],
  ../src/ctf/[arena, map_metrics, map_pool, sim_types]

proc load(path: string, teams: int): CtfMap =
  if path.endsWith(".json"):
    mapFromSpecJson(readFile(path))
  elif path.startsWith("gen:"):
    generateCtfMap(path[4 .. ^1].parseInt,
      MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)
  elif path.startsWith("pool:"):
    generateCtfMap(MapPoolSeeds[path[5 .. ^1].parseInt],
      MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)
  else:
    loadCtfMapMetadata(path)

when isMainModule:
  var
    teams = 2
    maps: seq[string]
    argv = commandLineParams()
    i = 0
  while i < argv.len:
    if argv[i] == "--teams": inc i; teams = argv[i].parseInt
    else: maps.add argv[i]
    inc i

  for path in maps:
    var m: MapMetrics
    try:
      m = evaluateMap(load(path, teams), path)
    except CatchableError as e:
      echo $(%*{"map": path, "error": e.msg.split('(')[0].strip()})
      continue
    echo $(%*{
      "map": path,
      "width": m.width, "height": m.height, "teams": m.teams,
      "valid": m.valid, "reason": m.reason,
      "staticScore": m.staticScore(),
      "sightlineMaxPx": m.sightlineMaxPx,
      "sightlineAxis": m.sightlineAxis,
      "sightlineX": m.sightlineX, "sightlineY": m.sightlineY,
      "openRunP95Px": m.openRunP95Px, "openRunMaxPx": m.openRunMaxPx,
      "longRunFrac": m.longRunFrac, "longRunPxFrac": m.longRunPxFrac,
      "diagRunP95Px": m.diagRunP95Px, "diagRunMaxPx": m.diagRunMaxPx,
      "diagLongRunFrac": m.diagLongRunFrac,
      "diagLongRunPxFrac": m.diagLongRunPxFrac,
      "interiorFrac": m.interiorFrac, "exposedFrac": m.exposedFrac,
      "coverPermille": m.coverPermille, "openFloorPx": m.openFloorPx,
    })
