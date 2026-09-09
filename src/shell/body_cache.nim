## Per-seat fixed LRU for cover duck-contrast results.

import std/[algorithm, math]
import body_map
import types as shellTypes

const
  PostDuckSearchCells = 3

type
  BodyDuckResult* = object
    pos*: BodyPoint
    contrast*: float

  DuckSlot = object
    key: int
    valid: bool
    value: BodyDuckResult
    lastUse: uint64

  BodySeatCache* = ref object
    map*: BodyMap
    duckSlots: array[shellTypes.MaxDuckEntriesPerSeat, DuckSlot]
    clock: uint64

proc nextClock(cache: BodySeatCache): uint64 =
  inc cache.clock
  cache.clock

proc newBodySeatCache*(map: BodyMap): BodySeatCache =
  new(result)
  result.map = map
  for slot in result.duckSlots.mitems:
    slot.key = -1

proc duckEntryCount*(cache: BodySeatCache): int =
  for slot in cache.duckSlots:
    if slot.valid:
      inc result

proc duckKeys*(cache: BodySeatCache): seq[int] =
  for slot in cache.duckSlots:
    if slot.valid:
      result.add(slot.key)
  result.sort()

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
