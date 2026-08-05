## Endzone-vs-hardcoded-literal probe: prints, per map, where the engine SAYS
## a team's capture zone is against the two scarred literals the reference
## policy falls back to when no `endzone` marker is read. It is the cheap
## static half of the carry-conversion diagnosis — the simulation says whether
## a steal converts, this says WHY it could not.
import
  std/[strformat, strutils],
  ../src/ctf/[arena, map_metrics, sim_config, sim_types],
  toolutil

proc report(label: string, gm: CtfMap) =
  let masks = buildMapMasks(gm)
  proc wall(x, y: int): bool =
    x < 0 or y < 0 or x >= gm.width or y >= gm.height or
      masks.wallPix[y * gm.width + x]

  echo &"--- {label}  {gm.width}x{gm.height}  endzoneRadius={gm.endzoneRadius}" &
    &"  layout={gm.layout}  shape={gm.endzone}"
  let
    cx = gm.width div 2
    cy = gm.height div 2
  for team in gm.teams():
    let
      anchor = gm.teamAnchor(team)
      zone = gm.captureZone(team)
      ## players/baseline/baseline.nim's `flagHome` 2-team literal.
      litHomeX =
        if team == Red: cx - cx * 7 div 10
        else: cx + (gm.width - cx) * 7 div 10
      ## players/baseline/baseline.nim's `homeDeepX` 2-team literal, and the
      ## lane the carrier would sit at while standing on it.
      deep = gm.width * 150 div 1235
      deepX = if team == Red: deep else: gm.width - 1 - deep
      mx = (zone.xLo + zone.xHi) div 2
      my = (zone.yLo + zone.yHi) div 2
    echo &"  {team}: anchor=({anchor.x},{anchor.y}) " &
      &"zone x[{zone.xLo}..{zone.xHi}] y[{zone.yLo}..{zone.yHi}] r={zone.radius}"
    echo &"      flagHome literal ({litHomeX},{cy}) " &
      &"off by ({litHomeX - anchor.x},{cy - anchor.y})"
    echo &"      homeDeepX literal x={deepX}: " &
      &"(x,CenterY) inZone={zone.inCaptureZone(deepX, cy)}  " &
      &"(x,zoneY) inZone={zone.inCaptureZone(deepX, anchor.y)}  " &
      &"off by {deepX - anchor.x}px in x"
    echo &"      marker centre ({mx},{my}) " &
      &"inZone={zone.inCaptureZone(mx, my)}"
    ## The three fixed border lanes the carrier picks its run home along. Two
    ## of them are y = 40 and y = height - 40, which are the open top and
    ## bottom corridors of a RECTANGULAR board; on a hexagon they are inside
    ## the hull's slanted wall for most of the board's width.
    for (name, laneY) in [("LaneTop", 40), ("LaneMid", cy),
        ("LaneBottom", gm.height - 40)]:
      echo &"      lane {name} y={laneY}: wall at zone x? " &
        &"{wall(mx, laneY)}   scores at (zoneX,laneY)? " &
        &"{zone.inCaptureZone(mx, laneY)}"

when isMainModule:
  chdirGameDir()
  var config = defaultGameConfig()
  config.teams = 2
  config.mapPath = "arena"
  report("arena", resolveCtfMapMetadata(config))
  config.mapPath = "arena-large"
  report("arena-large", resolveCtfMapMetadata(config))
  config.mapPath = GenMapName
  for seed in [4242, 1337, 2026]:
    config.mapSeed = seed
    report(&"gen:{seed}", resolveCtfMapMetadata(config))
