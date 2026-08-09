## archetype_probe — the FINGERPRINT of each route topology.
##
## The archetype brief's acceptance criterion is a statement about the graph,
## not about the picture: "two maps of different archetypes should differ in
## room count, route count and metric fingerprint". Every quality metric this
## repo owns is computed on ONE map, so none of them can see whether fifty
## seeds are fifty designs or one design fifty times. This tool groups seeds BY
## ARCHETYPE and reports the DISTRIBUTION of each measure within the group.
##
## ROOM COUNT is measured here rather than in `map_metrics` because it is a
## descriptive coordinate, not a quality term — the whole point is that
## `warren` and `field` sit at opposite ends of it and NEITHER is wrong.
## Definition: connected components of the floor whose clearance to the
## nearest wall is at least `RoomClearPx`, keeping components of at least
## `RoomMinAreaPx`. That is the standard "a room is a basin of the distance
## transform" reading — a corridor never qualifies, because its clearance is
## bounded by half its width.
##
##   nim c -d:release -r tools/archetype_probe.nim [count] [teams] [--raw]
## Demo/curation tooling; not part of the server.
import std/[os, strformat, strutils, algorithm, tables, sequtils]
import ../src/ctf/[sim, arena, map_metrics, map_lanes]

const
  RoomClearPx = 40
    ## Wider than half a `RecommendedCorridorWidthPx` corridor (34), so a
    ## corridor NEVER qualifies as a room however long it runs, and narrow
    ## enough that a modest room still has a core.
  RoomMinAreaPx = 40 * 40
    ## Thresholded on the ERODED core, not on the room. A 130 px room erodes
    ## to a 50 px core; asking the core to be room-sized was what made a
    ## 30-room warren report 2 rooms on the first run of this probe.

proc roomCount(gameMap: CtfMap): tuple[rooms: int, largestFrac: float] =
  ## Rooms, and how much of the open floor the BIGGEST one holds. The second
  ## number is what separates `hub` (one dominant space) from `blocks` (many
  ## equivalent ones) at the same room count.
  let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
  let
    w = gameMap.width
    h = gameMap.height
    clear = clearancePx(diag.maxWall, w, h)
  var
    seen = newSeq[bool](w * h)
    stack: seq[int]
    total = 0
    biggest = 0
  for i in 0 ..< w * h:
    if not diag.maxWall[i]: inc total
  for start in 0 ..< w * h:
    if seen[start] or clear[start] < RoomClearPx: continue
    var area = 0
    stack.setLen(0)
    stack.add start
    seen[start] = true
    while stack.len > 0:
      let i = stack.pop()
      inc area
      let
        x = i mod w
        y = i div w
      for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        let (nx, ny) = (x + dx, y + dy)
        if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
        let j = ny * w + nx
        if seen[j] or clear[j] < RoomClearPx: continue
        seen[j] = true
        stack.add j
    if area >= RoomMinAreaPx:
      inc result.rooms
      biggest = max(biggest, area)
  result.largestFrac =
    if total > 0: float(biggest) / float(total) else: 0.0

type Row = object
  seed: int
  arch: string
  valid: bool
  reason: string
  cover: int
  interior: float
  score: float
  routeMin: int
  routeMean: float
  capacity: float
  rooms: int
  largest: float
  dead: float

proc quartiles(values: seq[int]): string =
  if values.len == 0: return "-"
  var v = values
  v.sort()
  &"min {v[0]} p25 {v[v.len div 4]} med {v[v.len div 2]} " &
    &"p75 {v[min(v.high, 3 * v.len div 4)]} max {v[^1]}"

proc histogram(values: seq[int]): string =
  var counts = initOrderedTable[int, int]()
  var v = values
  v.sort()
  for x in v: counts.mgetOrPut(x, 0) += 1
  var parts: seq[string]
  for k, n in counts: parts.add &"{k}x{n}"
  parts.join(" ")

proc meanOf(values: seq[float]): float =
  if values.len == 0: return 0.0
  for x in values: result += x
  result /= float(values.len)

proc main() =
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 40
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
    raw = "--raw" in commandLineParams()
  let control = evaluateMap(loadCtfMapMetadata("arena"), "arena")
  let (ctlRooms, ctlLargest) = roomCount(loadCtfMapMetadata("arena"))
  echo &"CONTROL arena: score={control.staticScore():.3f} " &
    &"int={control.interiorFrac:.3f} cover={control.coverPermille}pm " &
    &"routes={control.routeCountMin}/{control.routeCountMean:.1f} " &
    &"cap={control.routeCapacityFrac:.3f} rooms={ctlRooms} " &
    &"largest={ctlLargest:.2f}"
  var rows: seq[Row]
  for i in 0 ..< count:
    let
      seed = 1001 + i
      arch = $mapArchetypeFor(seed, teams)
    var row = Row(seed: seed, arch: arch)
    var gameMap: CtfMap
    try:
      gameMap = generateCtfMap(seed, teams = teams)
      row.valid = true
    except CtfError:
      ## Report the archetype anyway — a topology that CANNOT validate is the
      ## single most useful thing this probe can say, and dropping the seed
      ## would hide it inside an aggregate validity number.
      gameMap = generateMapAttempt(seed, MapGenOverrides(
        windows: -1, pits: -1, pitDensity: -1), teams, 0)
      row.reason = validateGeneratedMap(gameMap)
    let m = evaluateMap(gameMap, "gen")
    row.cover = m.coverPermille
    row.interior = m.interiorFrac
    row.score = m.staticScore()
    row.routeMin = m.routeCountMin
    row.routeMean = m.routeCountMean
    row.capacity = m.routeCapacityFrac
    (row.rooms, row.largest) = roomCount(gameMap)
    rows.add row
    if raw:
      echo &"  {seed} {arch:<10} valid={row.valid} cover={row.cover}pm " &
        &"int={row.interior:.3f} rooms={row.rooms} " &
        &"routes={row.routeMin}/{row.routeMean:.1f} {row.reason}"

  echo ""
  echo &"{teams}-team, {count} seeds — PER-ARCHETYPE FINGERPRINT"
  echo "archetype    n  valid        rooms (distribution)         " &
    "routeMin (distribution)      largest  int    cover  score"
  var byArch = initOrderedTable[string, seq[Row]]()
  for a in legalArchetypes(teams):
    byArch[$a] = @[]
  for row in rows:
    byArch.mgetOrPut(row.arch, @[]).add row
  var totalValid = 0
  for arch, group in byArch:
    if group.len == 0:
      echo &"{arch:<12} 0  —"
      continue
    var
      valid = 0
      rooms, routes: seq[int]
      interiors, largests, scores: seq[float]
      covers: seq[int]
    for row in group:
      if row.valid: inc valid
      rooms.add row.rooms
      routes.add row.routeMin
      interiors.add row.interior
      largests.add row.largest
      scores.add row.score
      covers.add row.cover
    totalValid += valid
    echo &"{arch:<12} {group.len:<2} {valid}/{group.len} " &
      &"({100 * valid div group.len}%)  " &
      &"{histogram(rooms):<28} {histogram(routes):<28} " &
      &"{meanOf(largests):.2f}     {meanOf(interiors):.3f}  " &
      &"{meanOf(covers.mapIt(float(it))):.0f}pm  {meanOf(scores):.3f}"
  echo ""
  echo &"ALL: valid {totalValid}/{rows.len} " &
    &"({100 * totalValid div rows.len}%)"
  var allRooms, allRoutes: seq[int]
  for row in rows:
    allRooms.add row.rooms
    allRoutes.add row.routeMin
  echo &"  room count  across all seeds: {quartiles(allRooms)}   " &
    &"(arena {ctlRooms})"
  echo &"  route count across all seeds: {quartiles(allRoutes)}   " &
    &"(arena {control.routeCountMin})"
  for row in rows:
    if not row.valid:
      echo &"  INVALID {row.seed} {row.arch}: {row.reason} " &
        &"[cover={row.cover}pm int={row.interior:.2f}]"

when isMainModule:
  main()
