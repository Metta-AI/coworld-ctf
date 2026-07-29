## Audits every map in the pack against the properties a real match needs,
## using the FULL-RESOLUTION mask and the real player footprint (canOccupy),
## not the stride-2 lattice the unit test uses.
import
  std/[deques, os, strformat],
  ../src/ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initForMap(mapName: string): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.mapPath = mapName
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc floodFootprint(sim: SimServer, sx, sy: int): seq[bool] =
  ## Flood fill over cells a PLAYER can actually occupy (full 13x13 box fits),
  ## at 1px resolution. This is the true movement graph.
  result = newSeq[bool](MapWidth * MapHeight)
  var queue = initDeque[(int32, int32)]()
  if not sim.canOccupy(sx, sy):
    return
  result[mapIndex(sx, sy)] = true
  queue.addLast((sx.int32, sy.int32))
  while queue.len > 0:
    let (cx, cy) = queue.popFirst()
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx.int + dx
        ny = cy.int + dy
      if nx < 0 or ny < 0 or nx >= MapWidth or ny >= MapHeight:
        continue
      if result[mapIndex(nx, ny)]:
        continue
      if not sim.canOccupy(nx, ny):
        continue
      result[mapIndex(nx, ny)] = true
      queue.addLast((nx.int32, ny.int32))

when isMainModule:
  for name in Mw2Rotation:
    let sim = initForMap(name)
    let
      redHome = sim.gameMap.flagHome(Red)
      blueHome = sim.gameMap.flagHome(Blue)
      reach = sim.floodFootprint(redHome.x, redHome.y)
    # 1. Total occupiable area, and how much of it the red spawn reaches.
    var occupiable, reached: int
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        if sim.canOccupy(x, y):
          inc occupiable
          if reach[mapIndex(x, y)]:
            inc reached
    let pct = if occupiable > 0: reached * 100 div occupiable else: 0
    echo &"\n=== {name} ==="
    echo &"  occupiable cells {occupiable}, reachable from red flag {reached} ({pct}%)"
    # 2. Both pedestals reachable.
    echo &"  blue pedestal reachable: {reach[mapIndex(blueHome.x, blueHome.y)]}"
    # 3. Every pickup spawn reachable (they get nudged to nearestWalkable, but
    #    a nudge can land them in a SEALED pocket, which strands the item).
    for i, sp in sim.grenadeSpawns:
      if not reach[mapIndex(sp.x, sp.y)]:
        echo &"  STRANDED grenade {i} at {sp.x},{sp.y}"
    for i, sp in sim.medKitSpawns:
      if not reach[mapIndex(sp.x, sp.y)]:
        echo &"  STRANDED medkit {i} at {sp.x},{sp.y}"
    for i, sp in sim.shieldSpawns:
      if not reach[mapIndex(sp.x, sp.y)]:
        echo &"  STRANDED shield {i} at {sp.x},{sp.y}"
    for i, sp in sim.plasmaArcSpawns:
      if not reach[mapIndex(sp.x, sp.y)]:
        echo &"  STRANDED spray {i} at {sp.x},{sp.y}"
    # 4. Every one of the 16 spawn seats reachable + distinct-ish.
    for team in Team:
      for order in 0 ..< 8:
        let s = sim.spawnPosition(team, order)
        if not reach[mapIndex(s.x, s.y)]:
          echo &"  STRANDED spawn {team} #{order} at {s.x},{s.y}"
    # 5. No full-width horizontal sightline (the arena's own invariant).
    var openRows: int
    var y = 10
    while y < MapHeight - 10:
      if sim.isWalkable(215, y) or sim.isWalkable(1020, y):
        var blocked = false
        let steps = 1020 - 215
        for s in 1 .. steps:
          if sim.isWall(215 + s, y):
            blocked = true
            break
        if not blocked:
          inc openRows
          if openRows <= 3:
            echo &"  OPEN cross-field row y={y}"
      y += 4
    echo &"  open cross-field rows: {openRows}"
