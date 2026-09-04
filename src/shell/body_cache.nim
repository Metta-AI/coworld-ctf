## Per-seat bounded spatial caches over the immutable BodyMap.
##
## Route rasters are allocated at the activation barrier. A cold lookup never
## mints a field: body_planner owns the resumable build and publishes a slot
## only after every Dijkstra pop has completed. Duck results use a fixed LRU.

import std/[algorithm, hashes, math, options]
import body_map
import types as shellTypes

const
  PostDuckSearchCells = 3

type
  BodyDuckResult* = object
    pos*: BodyPoint
    contrast*: float

  RouteFieldSlot* = object
    key*: int
    goalCell*: BodyPoint
    valid*: bool
    building*: bool
    clearCursor*: int
    distances*: seq[float]
    hops*: seq[uint8]
    lastUse*: uint64

  DuckSlot = object
    key: int
    valid: bool
    value: BodyDuckResult
    lastUse: uint64

  BodySeatCache* = ref object
    map*: BodyMap
    routeSlots*: array[shellTypes.MaxRouteFieldsPerSeat, RouteFieldSlot]
    duckSlots: array[shellTypes.MaxDuckEntriesPerSeat, DuckSlot]
    pinnedKey: int
    hasPinnedKey: bool
    clock: uint64

proc nextClock(cache: BodySeatCache): uint64 =
  inc cache.clock
  cache.clock

proc routeKey*(map: BodyMap, goal: BodyPoint): int =
  let cell = map.cellOf(goal)
  cell.y * map.gridWidth + cell.x

proc routeKey*(cache: BodySeatCache, goal: BodyPoint): int =
  cache.map.routeKey(goal)

proc newBodySeatCache*(map: BodyMap): BodySeatCache =
  ## Activation-barrier constructor. All route-field payloads are allocated
  ## here, never on a playing tick.
  new(result)
  result.map = map
  let cells = map.gridWidth * map.gridHeight
  for slot in result.routeSlots.mitems:
    slot.key = -1
    slot.distances = newSeq[float](cells)
    slot.hops = newSeq[uint8](cells)
  for slot in result.duckSlots.mitems:
    slot.key = -1

proc routeFieldCount*(cache: BodySeatCache): int =
  for slot in cache.routeSlots:
    if slot.valid or slot.building:
      inc result

proc readyRouteFieldCount*(cache: BodySeatCache): int =
  for slot in cache.routeSlots:
    if slot.valid:
      inc result

proc duckEntryCount*(cache: BodySeatCache): int =
  for slot in cache.duckSlots:
    if slot.valid:
      inc result

proc routeKeys*(cache: BodySeatCache): seq[int] =
  for slot in cache.routeSlots:
    if slot.valid or slot.building:
      result.add(slot.key)
  result.sort()

proc duckKeys*(cache: BodySeatCache): seq[int] =
  for slot in cache.duckSlots:
    if slot.valid:
      result.add(slot.key)
  result.sort()

proc routeStateFingerprint*(cache: BodySeatCache): Hash =
  ## Diagnostic snapshot of complete route-cache state, including a suspended
  ## field build. It allocates nothing and is not used on the playing path.
  var value: Hash = hash(cache.clock) !& hash(cache.hasPinnedKey) !&
    hash(cache.pinnedKey)
  for slot in cache.routeSlots:
    value = value !& hash(slot.key) !& hash(slot.valid) !&
      hash(slot.building) !& hash(slot.clearCursor) !& hash(slot.lastUse)
    if slot.valid or slot.building:
      for index, distance in slot.distances:
        value = value !& hash(index) !& hash(distance) !& hash(slot.hops[index])
  !$value

proc pinnedRouteKey*(cache: BodySeatCache): Option[int] =
  if cache.hasPinnedKey: some(cache.pinnedKey) else: none(int)

proc pinStandingGoal*(cache: BodySeatCache, goal: BodyPoint) =
  cache.pinnedKey = cache.routeKey(goal)
  cache.hasPinnedKey = true

proc clearStandingGoalPin*(cache: BodySeatCache) =
  cache.hasPinnedKey = false

proc findRouteSlot*(cache: BodySeatCache, key: int): int =
  for index, slot in cache.routeSlots:
    if (slot.valid or slot.building) and slot.key == key:
      return index
  -1

proc selectRouteSlot(cache: BodySeatCache, key: int): int =
  result = cache.findRouteSlot(key)
  if result >= 0:
    return
  for index, slot in cache.routeSlots:
    if not slot.valid and not slot.building:
      return index
  var oldest = high(uint64)
  result = -1
  for index, slot in cache.routeSlots:
    if cache.hasPinnedKey and slot.key == cache.pinnedKey:
      continue
    if slot.lastUse < oldest:
      oldest = slot.lastUse
      result = index
  if result < 0:
    raise newException(BodyMapError,
      "all route-field slots are pinned; exactly one pin is permitted")

proc beginRouteFieldKeyed*(cache: BodySeatCache, key: int,
                           anchorCell: BodyPoint): int =
  ## Reserve the LRU slot for an ARBITRARY field key.
  ##
  ## The per-seat route tier keys a field by its goal cell's raster index, and
  ## `beginRouteField` below is exactly that spelling. A multi-source world
  ## field has no single goal cell to key on (the zone-safe field's sources are
  ## every dry cell on the board), so it names its own key — see
  ## body_nav.worldFieldKey, which namespaces the class into the high bits so a
  ## world key and a cell index can never collide inside one store.
  result = cache.selectRouteSlot(key)
  var slot = addr cache.routeSlots[result]
  slot.lastUse = cache.nextClock()
  if slot.key == key and (slot.valid or slot.building):
    return
  slot.key = key
  slot.goalCell = anchorCell
  slot.valid = false
  slot.building = true
  slot.clearCursor = 0

proc beginRouteField*(cache: BodySeatCache, goal: BodyPoint): int =
  ## Reserve the goal's LRU slot. Existing ready/building membership is kept.
  cache.beginRouteFieldKeyed(cache.routeKey(goal), cache.map.cellOf(goal))

proc clearRouteCell*(cache: BodySeatCache, slotIndex: int): bool =
  ## Clear exactly one raster cell. Returns true once the field is clean.
  var slot = addr cache.routeSlots[slotIndex]
  if slot.clearCursor >= slot.distances.len:
    return true
  slot.distances[slot.clearCursor] = Inf
  slot.hops[slot.clearCursor] = 0
  inc slot.clearCursor
  slot.clearCursor >= slot.distances.len

proc cancelRouteFieldBuild*(cache: BodySeatCache, slotIndex: int) =
  if slotIndex >= 0 and slotIndex < cache.routeSlots.len:
    cache.routeSlots[slotIndex].building = false
    cache.routeSlots[slotIndex].valid = false

proc publishRouteField*(cache: BodySeatCache, slotIndex: int) =
  var slot = addr cache.routeSlots[slotIndex]
  slot.building = false
  slot.valid = true
  slot.lastUse = cache.nextClock()

proc routeSlotReady*(cache: BodySeatCache, key: int): bool =
  let index = cache.findRouteSlot(key)
  index >= 0 and cache.routeSlots[index].valid

proc routeSlotReady*(cache: BodySeatCache, goal: BodyPoint): bool =
  cache.routeSlotReady(cache.routeKey(goal))

proc routeDistanceAt*(cache: BodySeatCache, slotIndex, cellIndex: int): float =
  cache.routeSlots[slotIndex].distances[cellIndex]

proc routeHopAt*(cache: BodySeatCache, slotIndex, cellIndex: int): uint8 =
  ## The parent-direction byte the minter stores beside every distance:
  ## `1 + reverseNeighborIndex(dx, dy)` of the step that reached this cell, so
  ## the route raster is ALREADY a flow field. 0 means "a source cell, or never
  ## reached". Readers resolve the parent as `cell + Neighbors[hop - 1]`.
  cache.routeSlots[slotIndex].hops[cellIndex]

proc setRouteDistance*(cache: BodySeatCache, slotIndex, cellIndex: int,
                       distance: float, hop: uint8) =
  var slot = addr cache.routeSlots[slotIndex]
  slot.distances[cellIndex] = distance
  slot.hops[cellIndex] = hop

proc peekRouteDistance*(cache: BodySeatCache, point, goal: BodyPoint): Option[float] =
  ## Non-minting oracle lookup. A miss remains a miss.
  let key = cache.routeKey(goal)
  let slotIndex = cache.findRouteSlot(key)
  if slotIndex < 0 or not cache.routeSlots[slotIndex].valid:
    return none(float)
  let cell = cache.map.nearestWalkable(cache.map.cellOf(point))
  if not cache.map.cellWalkable(cell):
    return none(float)
  let index = cell.y * cache.map.gridWidth + cell.x
  let distance = cache.routeDistanceAt(slotIndex, index)
  if distance.classify == fcInf:
    return none(float)
  cache.routeSlots[slotIndex].lastUse = cache.nextClock()
  some(distance * NavCell.float)

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc rayClear(map: BodyMap, a, b: BodyPoint, step = 2.0): bool =
  let dx = b.x - a.x
  let dy = b.y - a.y
  let length = hypot(dx.float, dy.float)
  let samples = max(int(length / step), 1)
  for index in 0 .. samples:
    let ratio = index.float / samples.float
    let point = (
      clamp(pyRound(a.x.float + dx.float * ratio), 0, map.width - 1),
      clamp(pyRound(a.y.float + dy.float * ratio), 0, map.height - 1))
    if map.isWall(point):
      return false
  true

proc nudgeClear(map: BodyMap, start, goal: BodyPoint): bool =
  let dx = goal.x - start.x
  let dy = goal.y - start.y
  let samples = max(1, ceil(hypot(dx.float, dy.float) / 2.0).int)
  for index in 0 .. samples:
    let ratio = index.float / samples.float
    let point = (
      pyRound(start.x.float + dx.float * ratio),
      pyRound(start.y.float + dy.float * ratio))
    if not map.canStand(point):
      return false
  true

proc computeDuck(cache: BodySeatCache, atlasIndex: int): BodyDuckResult =
  let candidate = cache.map.atlasPostAt(atlasIndex)
  let cell = cache.map.cellOf(candidate.pos)
  var sectors: array[AtlasSectorCount, int]
  for sector in 0 ..< AtlasSectorCount:
    sectors[sector] = sector
  sectors.sort(proc(a, b: int): int =
    result = cmp(candidate.reach[b], candidate.reach[a])
    if result == 0:
      result = cmp(a, b))
  var threatEnds: array[3, BodyPoint]
  var threatCount = 0
  for rank in 0 .. 2:
    let sector = sectors[rank]
    let distance = candidate.reach[sector].int
    if distance == 0:
      continue
    let angle = sector.float * 2.0 * PI / AtlasSectorCount.float
    threatEnds[threatCount] = (
      pyRound(candidate.pos.x.float + cos(angle) * distance.float),
      pyRound(candidate.pos.y.float + sin(angle) * distance.float))
    inc threatCount
  result.pos = candidate.pos
  var bestUtility = 0.0
  for dy in -PostDuckSearchCells .. PostDuckSearchCells:
    for dx in -PostDuckSearchCells .. PostDuckSearchCells:
      if dx == 0 and dy == 0:
        continue
      if dx != 0 and dy != 0 and abs(dx) != abs(dy):
        continue
      let hideCell = (cell.x + dx, cell.y + dy)
      if not cache.map.cellWalkable(hideCell):
        continue
      let hide = cellCenter(hideCell)
      if not cache.map.nudgeClear(candidate.pos, hide):
        continue
      var blocked = 0
      for index in 0 ..< threatCount:
        let endpoint = threatEnds[index]
        if endpoint != candidate.pos and
            not cache.map.rayClear(hide, endpoint, NavCell.float):
          inc blocked
      let contrast = blocked.float / max(threatCount, 1).float
      let travel = hypot(dx.float, dy.float) /
        max(PostDuckSearchCells.float * sqrt(2.0), 1.0)
      let utility = contrast - 0.15 * travel
      if utility > bestUtility:
        bestUtility = utility
        result = BodyDuckResult(pos: hide, contrast: contrast)

proc duckFor*(cache: BodySeatCache, atlasIndex: int): BodyDuckResult =
  let post = cache.map.atlasPostAt(atlasIndex)
  let cell = cache.map.cellOf(post.pos)
  let key = cell.y * cache.map.gridWidth + cell.x
  for slot in cache.duckSlots.mitems:
    if slot.valid and slot.key == key:
      slot.lastUse = cache.nextClock()
      return slot.value
  let value = cache.computeDuck(atlasIndex)
  var selected = -1
  var oldest = high(uint64)
  for index, slot in cache.duckSlots:
    if not slot.valid:
      selected = index
      break
    if slot.lastUse < oldest:
      oldest = slot.lastUse
      selected = index
  cache.duckSlots[selected] = DuckSlot(
    key: key, valid: true, value: value, lastUse: cache.nextClock())
  value
