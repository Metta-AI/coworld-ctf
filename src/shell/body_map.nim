## Immutable episode-scoped terrain and exact standing-goal validation.
##
## This is the production port of stencil's map-static world model. Mutable
## route/duck caches belong to body_cache.nim in phase 2; this module exposes
## no mutation after construction and never installs the process-global arena.

import std/[algorithm, heapqueue, math, options, tables]
import ../ctf/arena as ctfArena
import ../ctf/sim_types as ctfTypes
import types as shellTypes

const
  NavCell* = 8
  PlayerHalf* = 6
  AtlasSectorCount* = 16
  CoverRays = 16
  CoverRayPx = 24
  TopologyMergeDepthPx = 4
  TopologyMergeRatio = 0.8
  GateSeparationPx = 64
  PostReachCapPx = 1300
  AtlasBucketCells = 8
  EdtInfinity = uint32.high div 4
  Orth = [(-1, 0), (1, 0), (0, -1), (0, 1)]
  Neighbors = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1)]
  Sqrt2 = sqrt(2.0)

type
  BodyMapError* = object of CatchableError

  BodyPoint* = tuple[x, y: int]

  BodyHome* = object
    ## Integer group ownership keeps BR's 16 groups out of stencil's former
    ## four-team type. Flagless maps pass no homes at all.
    group*: int
    point*: BodyPoint

  BodyRoom* = object
    peak*: BodyPoint
    peakClearance*: int
    area*: int
    component*: int
    chokes*: seq[int]

  BodyChoke* = object
    pos*: BodyPoint
    clearance*: int
    roomA*, roomB*: int

  BodyAtlasPost* = object
    pos*: BodyPoint
    reach*: array[AtlasSectorCount, uint16]

  RaySample = object
    dx, dy: int32
    distance: uint16

  DistanceTable = object
    component: uint16
    winners: seq[uint32]

  HomeField = object
    group: int
    distances: seq[float]
    hops: seq[uint8]

  BodyMap* = ref object
    mapWidth, mapHeight, navWidth, navHeight, groups: int
    wall: seq[bool]
    clearance: seq[uint8]
    component: seq[uint16]
    components: int
    walkable: seq[bool]
    roomLabel: seq[uint16]
    rooms: seq[BodyRoom]
    chokes: seq[BodyChoke]
    coverDirs: seq[uint16]
    atlas: seq[BodyAtlasPost]
    atlasBuckets: seq[seq[int]]
    atlasBucketW, atlasBucketH, maxAtlasDensity: int
    validatorTables: seq[DistanceTable]
    homeFields: seq[HomeField]

  ValidatedGoal* {.requiresInit.} = object
    ## Opaque proof: external modules cannot name the private fields, and
    ## requiresInit forbids constructing an empty/default proof.
    owner: BodyMap
    point: BodyPoint
    component: uint16

  QueueNode = tuple[distance: float, x, y: int]

template pixelIndex(map: BodyMap, x, y: int): int = y * map.mapWidth + x
template gridIndex(map: BodyMap, x, y: int): int = y * map.navWidth + x
template standableAt(map: BodyMap, index: int): bool =
  map.clearance[index].int > PlayerHalf

proc pyRound(value: float): int =
  ## Python/NumPy nearest rounding, with exact half ties to even.
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5:
    lower
  elif fraction > 0.5:
    lower + 1
  elif (lower and 1) == 0:
    lower
  else:
    lower + 1

proc width*(map: BodyMap): int = map.mapWidth
proc height*(map: BodyMap): int = map.mapHeight
proc gridWidth*(map: BodyMap): int = map.navWidth
proc gridHeight*(map: BodyMap): int = map.navHeight
proc groupCount*(map: BodyMap): int = map.groups
proc componentCount*(map: BodyMap): int = map.components
proc roomCount*(map: BodyMap): int = map.rooms.len
proc chokeCount*(map: BodyMap): int = map.chokes.len
proc atlasPostCount*(map: BodyMap): int = map.atlas.len
proc maxAtlasPostsInRadius*(map: BodyMap): int = map.maxAtlasDensity
proc validatorTableCount*(map: BodyMap): int = map.validatorTables.len
proc validatorBytesFor*(width, height, distinctComponents: int): int64 =
  if width < 0 or height < 0 or distinctComponents < 0:
    raise newException(ValueError, "validator byte dimensions must be non-negative")
  int64(width) * int64(height) * int64(distinctComponents) *
    int64(sizeof(uint32))
proc validatorLogicalBytes*(map: BodyMap): int64 =
  validatorBytesFor(map.mapWidth, map.mapHeight, map.validatorTables.len)
proc homeFieldCount*(map: BodyMap): int = map.homeFields.len

proc inBounds*(map: BodyMap, point: BodyPoint): bool =
  point.x >= 0 and point.x < map.mapWidth and
    point.y >= 0 and point.y < map.mapHeight

proc isWall*(map: BodyMap, point: BodyPoint): bool =
  not map.inBounds(point) or map.wall[map.pixelIndex(point.x, point.y)]

proc rayClear*(map: BodyMap, a, b: BodyPoint): bool =
  ## Pixel ray check for body-side weapon gating. Endpoints outside the map
  ## are blocked; otherwise any wall pixel sampled along the segment blocks.
  if not map.inBounds(a) or not map.inBounds(b):
    return false
  let
    dx = b.x - a.x
    dy = b.y - a.y
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return not map.isWall(a)
  for step in 0 .. steps:
    let point = (
      x: pyRound(a.x.float + dx.float * step.float / steps.float),
      y: pyRound(a.y.float + dy.float * step.float / steps.float))
    if map.isWall(point):
      return false
  true

proc clearanceAt*(map: BodyMap, point: BodyPoint): int =
  if map.inBounds(point): map.clearance[map.pixelIndex(point.x, point.y)].int
  else: 0

proc canStand*(map: BodyMap, point: BodyPoint): bool =
  map.inBounds(point) and map.clearanceAt(point) > PlayerHalf

proc componentOf*(map: BodyMap, point: BodyPoint): int =
  if map.canStand(point): map.component[map.pixelIndex(point.x, point.y)].int
  else: 0

proc cellCenter*(cell: BodyPoint): BodyPoint =
  (cell.x * NavCell + NavCell div 2, cell.y * NavCell + NavCell div 2)

proc cellOf*(map: BodyMap, point: BodyPoint): BodyPoint =
  (clamp(point.x div NavCell, 0, map.navWidth - 1),
   clamp(point.y div NavCell, 0, map.navHeight - 1))

proc cellWalkable*(map: BodyMap, cell: BodyPoint): bool =
  cell.x >= 0 and cell.x < map.navWidth and
    cell.y >= 0 and cell.y < map.navHeight and
    map.walkable[map.gridIndex(cell.x, cell.y)]

proc coverDirections*(map: BodyMap, cell: BodyPoint): uint16 =
  if cell.x >= 0 and cell.x < map.navWidth and
      cell.y >= 0 and cell.y < map.navHeight:
    map.coverDirs[map.gridIndex(cell.x, cell.y)]
  else:
    0'u16

proc roomLabelAt*(map: BodyMap, point: BodyPoint): int =
  if map.inBounds(point): map.roomLabel[map.pixelIndex(point.x, point.y)].int
  else: 0

proc roomAt*(map: BodyMap, index: int): BodyRoom =
  if index < 0 or index >= map.rooms.len:
    raise newException(IndexDefect, "body room index out of bounds")
  result = map.rooms[index]
  result.chokes = newSeq[int](map.rooms[index].chokes.len)
  for chokeIndex, choke in map.rooms[index].chokes:
    result.chokes[chokeIndex] = choke

proc chokeAt*(map: BodyMap, index: int): BodyChoke =
  if index < 0 or index >= map.chokes.len:
    raise newException(IndexDefect, "body choke index out of bounds")
  map.chokes[index]

proc atlasPostAt*(map: BodyMap, index: int): BodyAtlasPost =
  if index < 0 or index >= map.atlas.len:
    raise newException(IndexDefect, "body atlas index out of bounds")
  map.atlas[index]

proc buildClearance(map: BodyMap, pixelWalkable: openArray[bool]): seq[uint8] =
  result = newSeq[uint8](map.mapWidth * map.mapHeight)
  template neighbor(nx, ny: int): int =
    if nx < 0 or nx >= map.mapWidth or ny < 0 or ny >= map.mapHeight: 0
    else: result[ny * map.mapWidth + nx].int
  for y in 0 ..< map.mapHeight:
    for x in 0 ..< map.mapWidth:
      if not pixelWalkable[y * map.mapWidth + x]:
        continue
      let best = min(255, min(
        min(neighbor(x - 1, y), neighbor(x, y - 1)),
        min(neighbor(x - 1, y - 1), neighbor(x + 1, y - 1))) + 1)
      result[y * map.mapWidth + x] = uint8(best)
  for y in countdown(map.mapHeight - 1, 0):
    for x in countdown(map.mapWidth - 1, 0):
      if not pixelWalkable[y * map.mapWidth + x]:
        continue
      let index = y * map.mapWidth + x
      let best = min(result[index].int, min(
        min(neighbor(x + 1, y), neighbor(x, y + 1)),
        min(neighbor(x + 1, y + 1), neighbor(x - 1, y + 1))) + 1)
      result[index] = uint8(best)

proc deriveWalkableGrid(map: BodyMap): seq[bool] =
  result = newSeq[bool](map.navWidth * map.navHeight)
  for gy in 0 ..< map.navHeight:
    let cy = gy * NavCell + NavCell div 2
    for gx in 0 ..< map.navWidth:
      let cx = gx * NavCell + NavCell div 2
      result[map.gridIndex(gx, gy)] =
        map.clearance[map.pixelIndex(cx, cy)].int > PlayerHalf

proc buildComponents(map: BodyMap) =
  map.component = newSeq[uint16](map.mapWidth * map.mapHeight)
  var queue: seq[int]
  for start in 0 ..< map.component.len:
    if map.component[start] != 0 or not map.standableAt(start):
      continue
    if map.components == high(uint16).int:
      raise newException(BodyMapError, "body map has too many standable components")
    inc map.components
    let label = uint16(map.components)
    map.component[start] = label
    queue.setLen(0)
    queue.add(start)
    var head = 0
    while head < queue.len:
      let index = queue[head]
      inc head
      let x = index mod map.mapWidth
      let y = index div map.mapWidth
      for delta in Orth:
        let nx = x + delta[0]
        let ny = y + delta[1]
        if nx < 0 or nx >= map.mapWidth or ny < 0 or ny >= map.mapHeight:
          continue
        let neighbor = ny * map.mapWidth + nx
        if map.component[neighbor] == 0 and map.standableAt(neighbor):
          map.component[neighbor] = label
          queue.add(neighbor)

proc transform1d(source: openArray[uint32], output: var openArray[uint32],
                 winners: var openArray[int]) =
  if source.len == 0:
    return
  var sites = newSeq[int](source.len)
  var boundaries = newSeq[float64](source.len + 1)
  var k = 0
  sites[0] = 0
  boundaries[0] = -Inf
  boundaries[1] = Inf
  for q in 1 ..< source.len:
    var split: float64
    while true:
      let p = sites[k]
      split = (source[q].float64 + float64(q * q) -
        source[p].float64 - float64(p * p)) / float64(2 * (q - p))
      if split > boundaries[k] or k == 0:
        break
      dec k
    inc k
    sites[k] = q
    boundaries[k] = split
    boundaries[k + 1] = Inf
  k = 0
  for q in 0 ..< source.len:
    while boundaries[k + 1] < q.float64:
      inc k
    let delta = q - sites[k]
    let value = uint64(delta * delta) + uint64(source[sites[k]])
    output[q] = uint32(min(value, uint64(EdtInfinity)))
    winners[q] = sites[k]

proc buildDistanceTable(map: BodyMap, component: uint16): DistanceTable =
  result.component = component
  result.winners = newSeq[uint32](map.component.len)
  # The validator contract is row-major, not arbitrary-nearest. The row pass
  # chooses the smallest x for same-row distance ties; the column pass chooses
  # the smallest y for total-distance ties and then reuses that row's smallest
  # x. Together that is the old scanner's `(distance, y, x)` ordering.
  var rowInput = newSeq[uint32](map.mapWidth)
  var rowOutput = newSeq[uint32](map.mapWidth)
  var rowWinners = newSeq[int](map.mapWidth)
  var intermediate = newSeq[uint32](map.component.len)
  var intermediateWinners = newSeq[uint32](map.component.len)
  for y in 0 ..< map.mapHeight:
    for x in 0 ..< map.mapWidth:
      rowInput[x] = if map.component[y * map.mapWidth + x] == component:
        0'u32 else: EdtInfinity
    transform1d(rowInput, rowOutput, rowWinners)
    for x in 0 ..< map.mapWidth:
      intermediate[y * map.mapWidth + x] = rowOutput[x]
      intermediateWinners[y * map.mapWidth + x] = uint32(rowWinners[x])
  var columnInput = newSeq[uint32](map.mapHeight)
  var columnOutput = newSeq[uint32](map.mapHeight)
  var columnWinners = newSeq[int](map.mapHeight)
  for x in 0 ..< map.mapWidth:
    for y in 0 ..< map.mapHeight:
      columnInput[y] = intermediate[y * map.mapWidth + x]
    transform1d(columnInput, columnOutput, columnWinners)
    for y in 0 ..< map.mapHeight:
      let winnerY = columnWinners[y]
      let winnerX = intermediateWinners[winnerY * map.mapWidth + x].int
      result.winners[y * map.mapWidth + x] =
        uint32(winnerY * map.mapWidth + winnerX)

proc tableFor(map: BodyMap, component: uint16): int =
  for index, table in map.validatorTables:
    if table.component == component:
      return index
  -1

proc resolveNearest(map: BodyMap, table: DistanceTable,
                    point: BodyPoint, maxRadiusPx: int): Option[BodyPoint] =
  if maxRadiusPx < 0 or not map.inBounds(point):
    return none(BodyPoint)
  let winner = table.winners[map.pixelIndex(point.x, point.y)].int
  let x = winner mod map.mapWidth
  let y = winner div map.mapWidth
  let dx = int64(x - point.x)
  let dy = int64(y - point.y)
  let distance = dx * dx + dy * dy
  let radiusSquared = int64(maxRadiusPx) * int64(maxRadiusPx)
  if distance > radiusSquared:
    return none(BodyPoint)
  some((x, y))

proc resolveNearestByRowMajorScan*(map: BodyMap, component: int,
                                   point: BodyPoint,
                                   maxRadiusPx: int): Option[BodyPoint] =
  ## Test/measurement oracle for the pre-table validator behavior: scan the
  ## bounded row-major box and keep the first component pixel at the smallest
  ## squared distance.
  if component <= 0 or maxRadiusPx < 0 or not map.inBounds(point):
    return none(BodyPoint)
  let label = uint16(component)
  let radiusSquared = int64(maxRadiusPx) * int64(maxRadiusPx)
  var bestDistance = radiusSquared + 1
  for y in max(0, point.y - maxRadiusPx) ..
      min(map.mapHeight - 1, point.y + maxRadiusPx):
    for x in max(0, point.x - maxRadiusPx) ..
        min(map.mapWidth - 1, point.x + maxRadiusPx):
      let dx = int64(x - point.x)
      let dy = int64(y - point.y)
      let distance = dx * dx + dy * dy
      if distance < bestDistance and distance <= radiusSquared and
          map.component[map.pixelIndex(x, y)] == label:
        bestDistance = distance
        result = some((x, y))

proc validatorDistanceSquaredForComponent*(map: BodyMap, component: int,
                                           point: BodyPoint): Option[uint32] =
  if component <= 0 or not map.inBounds(point):
    return none(uint32)
  let tableIndex = map.tableFor(uint16(component))
  if tableIndex < 0:
    return none(uint32)
  let winner = map.validatorTables[tableIndex].
    winners[map.pixelIndex(point.x, point.y)].int
  let x = winner mod map.mapWidth
  let y = winner div map.mapWidth
  let dx = int64(x - point.x)
  let dy = int64(y - point.y)
  some(uint32(dx * dx + dy * dy))

proc validateGoal*(map: BodyMap, requested,
                   fromPoint: BodyPoint): Option[ValidatedGoal] =
  ## Sole constructor for ValidatedGoal. The default radius is the ABI's exact
  ## stencil radius; the explicit argument exists for fixed-radius goldens.
  let component = map.componentOf(fromPoint)
  if component == 0:
    return none(ValidatedGoal)
  let tableIndex = map.tableFor(uint16(component))
  if tableIndex < 0:
    return none(ValidatedGoal)
  let resolved = map.resolveNearest(
    map.validatorTables[tableIndex], requested, shellTypes.ValidatorRadiusPx)
  if resolved.isNone:
    return none(ValidatedGoal)
  some(ValidatedGoal(owner: map, point: resolved.get,
    component: uint16(component)))

proc goalPoint*(goal: ValidatedGoal): BodyPoint = goal.point
proc goalComponent*(goal: ValidatedGoal): int = goal.component.int
proc belongsTo*(goal: ValidatedGoal, map: BodyMap): bool = goal.owner == map

proc nearestWalkable*(map: BodyMap, cell: BodyPoint): BodyPoint =
  if map.cellWalkable(cell):
    return cell
  for ring in 1 ..< max(map.navWidth, map.navHeight):
    for dy in -ring .. ring:
      for dx in -ring .. ring:
        let candidate = (cell.x + dx, cell.y + dy)
        if map.cellWalkable(candidate):
          return candidate
  cell

proc reverseNeighborIndex(dx, dy: int): int =
  for index, delta in Neighbors:
    if delta[0] == -dx and delta[1] == -dy:
      return index

proc buildHomeField(map: BodyMap, home: BodyHome): HomeField =
  result.group = home.group
  result.distances = newSeq[float](map.walkable.len)
  result.hops = newSeq[uint8](map.walkable.len)
  for value in result.distances.mitems:
    value = Inf
  let rawCell = map.cellOf(home.point)
  let goal = map.nearestWalkable(rawCell)
  if not map.cellWalkable(goal):
    raise newException(BodyMapError,
      "home " & $home.group & " has no walkable navigation cell")
  result.distances[map.gridIndex(goal.x, goal.y)] = 0.0
  var queue = initHeapQueue[QueueNode]()
  queue.push((0.0, goal.x, goal.y))
  while queue.len > 0:
    let current = queue.pop()
    if current.distance > result.distances[map.gridIndex(current.x, current.y)]:
      continue
    for _, delta in Neighbors:
      let nx = current.x + delta[0]
      let ny = current.y + delta[1]
      if nx < 0 or nx >= map.navWidth or ny < 0 or ny >= map.navHeight:
        continue
      let nextIndex = map.gridIndex(nx, ny)
      if not map.walkable[nextIndex]:
        continue
      if delta[0] != 0 and delta[1] != 0 and
          (not map.walkable[map.gridIndex(nx, current.y)] or
           not map.walkable[map.gridIndex(current.x, ny)]):
        continue
      let nextDistance = current.distance +
        (if delta[0] != 0 and delta[1] != 0: Sqrt2 else: 1.0)
      if nextDistance < result.distances[nextIndex]:
        result.distances[nextIndex] = nextDistance
        result.hops[nextIndex] = uint8(1 +
          reverseNeighborIndex(delta[0], delta[1]))
        queue.push((nextDistance, nx, ny))
proc homeDistance*(map: BodyMap, group: int,
                   point: BodyPoint): Option[float] =
  for field in map.homeFields:
    if field.group == group:
      let cell = map.nearestWalkable(map.cellOf(point))
      let distance = field.distances[map.gridIndex(cell.x, cell.y)]
      if distance.classify == fcInf:
        return none(float)
      return some(distance * NavCell.float)
  none(float)

proc buildTopology(map: BodyMap) =
  let
    width = map.mapWidth
    pixels = width * map.mapHeight
  var
    raw = newSeq[int32](pixels)
    seeds: seq[BodyPoint]
    peaks: seq[int]
    areas: seq[int]
    visited = newSeq[bool](pixels)
    plateau: seq[int]
  for start in 0 ..< pixels:
    if visited[start] or not map.standableAt(start):
      continue
    let level = map.clearance[start].int
    plateau.setLen(0)
    plateau.add(start)
    visited[start] = true
    var head = 0
    var isMax = true
    while head < plateau.len:
      let index = plateau[head]
      inc head
      let x = index mod width
      let y = index div width
      for delta in Orth:
        let nx = x + delta[0]
        let ny = y + delta[1]
        if nx < 0 or nx >= width or ny < 0 or ny >= map.mapHeight:
          continue
        let neighbor = ny * width + nx
        if not map.standableAt(neighbor):
          continue
        let candidateClearance = map.clearance[neighbor].int
        if candidateClearance > level:
          isMax = false
        elif candidateClearance == level and not visited[neighbor]:
          visited[neighbor] = true
          plateau.add(neighbor)
    if isMax:
      seeds.add((plateau[0] mod width, plateau[0] div width))
      peaks.add(level)
      areas.add(plateau.len)
      let label = int32(seeds.len)
      for index in plateau:
        raw[index] = label

  var
    buckets: array[256, seq[int32]]
    queued = newSeq[bool](pixels)
    contacts: seq[tuple[pos: BodyPoint, clearance: int, a, b: int]]
    pairContacts = initTable[(int, int), seq[BodyPoint]]()
  template pushNeighbors(index: int) =
    let x = index mod width
    let y = index div width
    for delta in Orth:
      let nx = x + delta[0]
      let ny = y + delta[1]
      if nx >= 0 and nx < width and ny >= 0 and ny < map.mapHeight:
        let neighbor = ny * width + nx
        if raw[neighbor] == 0 and not queued[neighbor] and
            map.standableAt(neighbor):
          queued[neighbor] = true
          buckets[map.clearance[neighbor].int].add(int32(neighbor))
  for index in 0 ..< pixels:
    if raw[index] != 0:
      pushNeighbors(index)
  for level in countdown(255, PlayerHalf + 1):
    var head = 0
    while head < buckets[level].len:
      let index = buckets[level][head].int
      inc head
      if raw[index] != 0:
        continue
      let x = index mod width
      let y = index div width
      var labels: array[4, int32]
      var labelCount = 0
      for delta in Orth:
        let nx = x + delta[0]
        let ny = y + delta[1]
        if nx < 0 or nx >= width or ny < 0 or ny >= map.mapHeight:
          continue
        let value = raw[ny * width + nx]
        if value == 0:
          continue
        var known = false
        for existing in 0 ..< labelCount:
          if labels[existing] == value:
            known = true
            break
        if not known:
          labels[labelCount] = value
          inc labelCount
      if labelCount == 0:
        continue
      var assigned = labels[0]
      for existing in 1 ..< labelCount:
        assigned = min(assigned, labels[existing])
      raw[index] = assigned
      inc areas[assigned - 1]
      if labelCount >= 2:
        for first in 0 ..< labelCount:
          for second in first + 1 ..< labelCount:
            let pair = (min(labels[first], labels[second]).int,
              max(labels[first], labels[second]).int)
            var nearExisting = false
            if pairContacts.hasKey(pair):
              for previous in pairContacts[pair]:
                if max(abs(previous.x - x), abs(previous.y - y)) <
                    GateSeparationPx:
                  nearExisting = true
                  break
            if not nearExisting:
              pairContacts.mgetOrPut(pair, @[]).add((x, y))
              contacts.add(((x, y), level, pair[0], pair[1]))
      pushNeighbors(index)
    buckets[level].setLen(0)

  var parent = newSeq[int](seeds.len)
  for index in 0 ..< parent.len:
    parent[index] = index
  proc findRoot(parent: var seq[int], node: int): int =
    result = node
    while parent[result] != result:
      parent[result] = parent[parent[result]]
      result = parent[result]
  for contact in contacts:
    let ra = findRoot(parent, contact.a - 1)
    let rb = findRoot(parent, contact.b - 1)
    if ra == rb:
      continue
    let minPeak = min(peaks[ra], peaks[rb])
    let depth = minPeak - contact.clearance
    let ratio = contact.clearance.float / max(minPeak, 1).float
    if depth < TopologyMergeDepthPx or ratio >= TopologyMergeRatio:
      var winner = ra
      var loser = rb
      if peaks[rb] > peaks[ra] or (peaks[rb] == peaks[ra] and rb < ra):
        winner = rb
        loser = ra
      parent[loser] = winner
      areas[winner] += areas[loser]

  var final = newSeq[int](seeds.len)
  for index in 0 ..< final.len:
    final[index] = -1
  for label in 0 ..< seeds.len:
    let root = findRoot(parent, label)
    if final[root] < 0:
      final[root] = map.rooms.len
      map.rooms.add(BodyRoom(
        peak: seeds[root], peakClearance: peaks[root], area: areas[root],
        component: map.component[seeds[root].y * width + seeds[root].x].int))
    final[label] = final[root]
  for contact in contacts:
    let ra = final[findRoot(parent, contact.a - 1)]
    let rb = final[findRoot(parent, contact.b - 1)]
    if ra == rb:
      continue
    let pair = (min(ra, rb), max(ra, rb))
    var nearExisting = false
    for choke in map.chokes:
      if (min(choke.roomA, choke.roomB), max(choke.roomA, choke.roomB)) ==
          pair and max(abs(choke.pos.x - contact.pos.x),
          abs(choke.pos.y - contact.pos.y)) < GateSeparationPx:
        nearExisting = true
        break
    if not nearExisting:
      for room in [pair[0], pair[1]]:
        map.rooms[room].chokes.add(map.chokes.len)
      map.chokes.add(BodyChoke(pos: contact.pos,
        clearance: contact.clearance, roomA: pair[0], roomB: pair[1]))
  map.roomLabel = newSeq[uint16](pixels)
  for index in 0 ..< pixels:
    if raw[index] != 0:
      map.roomLabel[index] = uint16(final[raw[index] - 1] + 1)

proc buildCoverDirs(map: BodyMap) =
  map.coverDirs = newSeq[uint16](map.walkable.len)
  for gy in 0 ..< map.navHeight:
    for gx in 0 ..< map.navWidth:
      let index = map.gridIndex(gx, gy)
      if not map.walkable[index]:
        continue
      let center = cellCenter((gx, gy))
      var mask: uint16
      for ray in 0 ..< CoverRays:
        let angle = ray.float * 2.0 * PI / CoverRays.float
        let dirX = cos(angle)
        let dirY = sin(angle)
        var distance = 2.0
        while distance <= CoverRayPx.float:
          let sx = pyRound(center.x.float + dirX * distance)
          let sy = pyRound(center.y.float + dirY * distance)
          if sx < 0 or sx >= map.mapWidth or sy < 0 or sy >= map.mapHeight:
            break
          if map.wall[map.pixelIndex(sx, sy)]:
            mask = mask or uint16(1 shl ray)
            break
          distance += 2.0
      map.coverDirs[index] = mask

proc atlasRaySamples(): array[AtlasSectorCount, seq[RaySample]] =
  for sector in 0 ..< AtlasSectorCount:
    let angle = sector.float * 2.0 * PI / AtlasSectorCount.float
    let dirX = cos(angle)
    let dirY = sin(angle)
    for distance in 1 .. PostReachCapPx:
      let dx = int32(pyRound(dirX * distance.float))
      let dy = int32(pyRound(dirY * distance.float))
      if result[sector].len > 0 and result[sector][^1].dx == dx and
          result[sector][^1].dy == dy:
        result[sector][^1].distance = uint16(distance)
      else:
        result[sector].add(RaySample(
          dx: dx, dy: dy, distance: uint16(distance)))

proc rayReach(map: BodyMap, point: BodyPoint,
              samples: openArray[RaySample]): uint16 =
  var reached = 0
  for sample in samples:
    let sx = point.x + sample.dx.int
    let sy = point.y + sample.dy.int
    if sx.uint >= map.mapWidth.uint or sy.uint >= map.mapHeight.uint or
        map.wall[map.pixelIndex(sx, sy)]:
      break
    reached = sample.distance.int
  uint16(reached)

proc cardinalReach(map: BodyMap): array[4, seq[uint16]] =
  for direction in 0 .. 3:
    result[direction] = newSeq[uint16](map.navWidth * map.navHeight)
  for gy in 0 ..< map.navHeight:
    let y = gy * NavCell + NavCell div 2
    var obstacle = map.mapWidth
    for x in countdown(map.mapWidth - 1, 0):
      if map.wall[map.pixelIndex(x, y)]: obstacle = x
      if x >= NavCell div 2 and (x - NavCell div 2) mod NavCell == 0:
        let gx = (x - NavCell div 2) div NavCell
        if gx < map.navWidth:
          result[0][map.gridIndex(gx, gy)] =
            uint16(min(PostReachCapPx, max(0, obstacle - x - 1)))
    obstacle = -1
    for x in 0 ..< map.mapWidth:
      if map.wall[map.pixelIndex(x, y)]: obstacle = x
      if x >= NavCell div 2 and (x - NavCell div 2) mod NavCell == 0:
        let gx = (x - NavCell div 2) div NavCell
        if gx < map.navWidth:
          result[2][map.gridIndex(gx, gy)] =
            uint16(min(PostReachCapPx, max(0, x - obstacle - 1)))
  for gx in 0 ..< map.navWidth:
    let x = gx * NavCell + NavCell div 2
    var obstacle = map.mapHeight
    for y in countdown(map.mapHeight - 1, 0):
      if map.wall[map.pixelIndex(x, y)]: obstacle = y
      if y >= NavCell div 2 and (y - NavCell div 2) mod NavCell == 0:
        let gy = (y - NavCell div 2) div NavCell
        if gy < map.navHeight:
          result[1][map.gridIndex(gx, gy)] =
            uint16(min(PostReachCapPx, max(0, obstacle - y - 1)))
    obstacle = -1
    for y in 0 ..< map.mapHeight:
      if map.wall[map.pixelIndex(x, y)]: obstacle = y
      if y >= NavCell div 2 and (y - NavCell div 2) mod NavCell == 0:
        let gy = (y - NavCell div 2) div NavCell
        if gy < map.navHeight:
          result[3][map.gridIndex(gx, gy)] =
            uint16(min(PostReachCapPx, max(0, y - obstacle - 1)))

proc buildPostAtlas(map: BodyMap) =
  map.atlasBucketW = (map.navWidth + AtlasBucketCells - 1) div AtlasBucketCells
  map.atlasBucketH = (map.navHeight + AtlasBucketCells - 1) div AtlasBucketCells
  map.atlasBuckets = newSeq[seq[int]](map.atlasBucketW * map.atlasBucketH)
  let raySamples = atlasRaySamples()
  let cardinal = map.cardinalReach()
  for gy in 0 ..< map.navHeight:
    for gx in 0 ..< map.navWidth:
      if (gx and 1) != 0 or (gy and 1) != 0:
        continue
      let cellIndex = map.gridIndex(gx, gy)
      if map.coverDirs[cellIndex] == 0:
        continue
      var post = BodyAtlasPost(pos: cellCenter((gx, gy)))
      for sector in 0 ..< AtlasSectorCount:
        if sector mod 4 == 0:
          post.reach[sector] = cardinal[sector div 4][cellIndex]
        else:
          post.reach[sector] = map.rayReach(post.pos, raySamples[sector])
      let atlasIndex = map.atlas.len
      map.atlas.add(post)
      let bucket = (gy div AtlasBucketCells) * map.atlasBucketW +
        gx div AtlasBucketCells
      map.atlasBuckets[bucket].add(atlasIndex)

iterator atlasNear*(map: BodyMap, point: BodyPoint, radiusPx: int): int =
  if radiusPx >= 0 and map.atlasBucketW > 0 and map.atlasBucketH > 0:
    let bucketPx = AtlasBucketCells * NavCell
    let minBx = clamp((int64(point.x) - int64(radiusPx)) div bucketPx,
      0, int64(map.atlasBucketW - 1)).int
    let maxBx = clamp((int64(point.x) + int64(radiusPx)) div bucketPx,
      0, int64(map.atlasBucketW - 1)).int
    let minBy = clamp((int64(point.y) - int64(radiusPx)) div bucketPx,
      0, int64(map.atlasBucketH - 1)).int
    let maxBy = clamp((int64(point.y) + int64(radiusPx)) div bucketPx,
      0, int64(map.atlasBucketH - 1)).int
    let radiusSquared = int64(radiusPx) * int64(radiusPx)
    for by in minBy .. maxBy:
      for bx in minBx .. maxBx:
        for atlasIndex in map.atlasBuckets[by * map.atlasBucketW + bx]:
          let post = map.atlas[atlasIndex]
          let dx = int64(post.pos.x) - int64(point.x)
          let dy = int64(post.pos.y) - int64(point.y)
          if dx * dx + dy * dy <= radiusSquared:
            yield atlasIndex

proc validateAtlasDensity(map: BodyMap) =
  ## Exact maximum over every integer query point, not merely post-centered
  ## discs. For one query y, each post contributes one inclusive x interval;
  ## a difference-array sweep finds the densest center in linear width.
  let radius = shellTypes.MaxCoverRadiusPx
  let radiusSquared = int64(radius) * int64(radius)
  var differences = newSeq[int32](map.mapWidth + 1)
  var maximumPoint: BodyPoint
  for queryY in 0 ..< map.mapHeight:
    for index in 0 ..< differences.len:
      differences[index] = 0
    for post in map.atlas:
      let dy = abs(post.pos.y - queryY)
      if dy > radius:
        continue
      let xReach = floor(sqrt((radiusSquared - int64(dy) * int64(dy)).float)).int
      let x0 = max(0, post.pos.x - xReach)
      let x1 = min(map.mapWidth - 1, post.pos.x + xReach)
      inc differences[x0]
      dec differences[x1 + 1]
    var count = 0
    for queryX in 0 ..< map.mapWidth:
      count += differences[queryX]
      if count > map.maxAtlasDensity:
        map.maxAtlasDensity = count
        maximumPoint = (queryX, queryY)
  if map.maxAtlasDensity > shellTypes.MaxCoverPostsExamined:
    raise newException(BodyMapError,
      "body atlas has " & $map.maxAtlasDensity &
      " posts within radius " & $shellTypes.MaxCoverRadiusPx & " at (" &
      $maximumPoint.x & "," & $maximumPoint.y & "), over " &
      "MaxCoverPostsExamined=" & $shellTypes.MaxCoverPostsExamined)

proc buildValidatorTables(map: BodyMap, spawnPoints: openArray[BodyPoint]) =
  var components: seq[uint16]
  for index, point in spawnPoints:
    let component = map.componentOf(point)
    if component == 0:
      raise newException(BodyMapError,
        "spawn point " & $index & " is not standable")
    let label = uint16(component)
    if label notin components:
      components.add(label)
  components.sort()
  let logicalBytes = validatorBytesFor(
    map.mapWidth, map.mapHeight, components.len)
  if logicalBytes > int64(shellTypes.MaxValidatorTableBytes):
    raise newException(BodyMapError,
      "validator tables need " & $logicalBytes & " bytes, over " &
      $shellTypes.MaxValidatorTableBytes)
  for component in components:
    map.validatorTables.add(map.buildDistanceTable(component))

proc newBodyMap*(pixelWalkable: openArray[bool], width, height,
                 groupCount: int, spawnPoints: openArray[BodyPoint],
                 homes: openArray[BodyHome] = []): BodyMap =
  ## Build the complete immutable episode layer. Inputs are copied/derived;
  ## retaining and mutating the caller's sequences cannot change the map.
  if width < NavCell or height < NavCell or pixelWalkable.len != width * height:
    raise newException(BodyMapError,
      "body map dimensions do not match the walkability raster")
  if groupCount <= 0:
    raise newException(BodyMapError, "body map group count must be positive")
  if spawnPoints.len == 0:
    raise newException(BodyMapError, "body map needs at least one spawn point")
  result = BodyMap(mapWidth: width, mapHeight: height,
    navWidth: max(1, width div NavCell), navHeight: max(1, height div NavCell),
    groups: groupCount, wall: newSeq[bool](pixelWalkable.len))
  for index, walkable in pixelWalkable:
    result.wall[index] = not walkable
  result.clearance = result.buildClearance(pixelWalkable)
  result.walkable = result.deriveWalkableGrid()
  result.buildComponents()
  result.buildTopology()
  result.buildCoverDirs()
  result.buildPostAtlas()
  result.validateAtlasDensity()
  result.buildValidatorTables(spawnPoints)
  var seenHomes: seq[int]
  for home in homes:
    if home.group < 0 or home.group >= groupCount:
      raise newException(BodyMapError, "home group is outside the map roster")
    if home.group in seenHomes:
      raise newException(BodyMapError, "duplicate home group " & $home.group)
    if not result.canStand(home.point):
      raise newException(BodyMapError, "home " & $home.group & " is not standable")
    seenHomes.add(home.group)
    result.homeFields.add(result.buildHomeField(home))

proc newBodyMap*(gameMap: ctfTypes.CtfMap): BodyMap =
  ## Engine adapter. Uses only pure map APIs and never installs the arena.
  let groups = gameMap.teamCount()
  let masks = ctfArena.rasterizeWallMasks(gameMap,
    ctfArena.buildArenaObstacles(gameMap))
  var pixelWalkable = newSeq[bool](gameMap.width * gameMap.height)
  for index, blocked in masks.maxWall:
    pixelWalkable[index] = not blocked
  var spawnPoints: seq[BodyPoint]
  if gameMap.spawnPoints.len > 0:
    for point in gameMap.spawnPoints:
      spawnPoints.add((point.x, point.y))
  else:
    if groups > 4:
      raise newException(BodyMapError,
        "a map with more than four groups must author spawnPoints")
    for index in 0 ..< groups:
      let point = gameMap.teamAnchor(ctfTypes.Team(index))
      spawnPoints.add((point.x, point.y))
  var homes: seq[BodyHome]
  if not gameMap.flagless:
    if groups > 4:
      raise newException(BodyMapError,
        "a non-flagless body map cannot have more than four homes")
    for index in 0 ..< groups:
      let zone = gameMap.captureZone(ctfTypes.Team(index))
      homes.add(BodyHome(group: index,
        point: ((zone.xLo + zone.xHi) div 2, (zone.yLo + zone.yHi) div 2)))
  newBodyMap(pixelWalkable, gameMap.width, gameMap.height, groups,
    spawnPoints, homes)
