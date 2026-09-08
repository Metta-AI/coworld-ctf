## Phase-4 laws for the immutable zone-hazard overlay and bounded safe cache.

import std/[math, unittest]
import ../src/ctf/[sim, zone_field]
import ../src/shell/[body_hazard, body_map, body_route_index]

proc openMap(): BodyMap =
  const Side = 96
  var walkable = newSeq[bool](Side * Side)
  for y in 1 ..< Side - 1:
    for x in 1 ..< Side - 1:
      walkable[y * Side + x] = true
  newBodyMap(walkable, Side, Side, 2, @[(16, 16), (80, 80)],
    mapName = "hazard-open")

proc uniformSnapshot(map: BodyMap, arrival: uint16,
                     fingerprint = 17'u64): ZoneDamageSnapshot =
  result.gridW = (map.width + 3) div 4
  result.gridH = (map.height + 3) div 4
  result.cellPx = 4
  result.fingerprint = fingerprint
  result.damage = newSeq[uint16](result.gridW * result.gridH)
  for value in result.damage.mitems:
    value = arrival

proc manualSegmentHazard(overlay: BodyHazardOverlay, index: BodyRouteIndex,
    segment: int, reversed: bool, elapsed: int,
    entryPhysicalQ4: int64): int64 =
  let metadata = index.routeSegmentAt(segment)
  var physical = entryPhysicalQ4
  for offset in 1 ..< metadata.cellLen.int:
    let
      previous = index.segmentCellAt(segment, offset - 1, reversed)
      current = index.segmentCellAt(segment, offset, reversed)
      a = index.routePoint(previous)
      b = index.routePoint(current)
      dx = a.x - b.x
      dy = a.y - b.y
      step = uint32(round(sqrt(float(dx * dx + dy * dy)) * 16.0))
      eta = elapsed + int((physical + step.int64 + HazardEtaSpeedQ4 - 1) div
        HazardEtaSpeedQ4)
    result += overlay.hazardStepCostQ4(index.routeNavCell(current).int,
      eta, step)
    physical += step.int64

suite "body hazard overlay":
  test "zone snapshot copies damage and never reads render arrival":
    var config = defaultGameConfig()
    config.update(
      """{"zonePhases":[{"z":0.5,"waitTicks":10,"shrinkTicks":40,"dps":2}]}""")
    var sim = initSimServer(config)
    discard sim.ensureZoneArrivalField()
    check ZoneArrivalFieldValue.damage.len > 0
    let
      oldDamage = ZoneArrivalFieldValue.damage[0]
      oldArrival = ZoneArrivalFieldValue.arrival[0]
    ZoneArrivalFieldValue.damage[0] = 123
    ZoneArrivalFieldValue.arrival[0] = 456
    let snapshot = sim.zoneDamageSnapshot()
    ZoneArrivalFieldValue.damage[0] = 789
    check snapshot.damage[0] == 123
    check snapshot.damage[0] != ZoneArrivalFieldValue.arrival[0]
    ZoneArrivalFieldValue.damage[0] = oldDamage
    ZoneArrivalFieldValue.arrival[0] = oldArrival

  test "dark overlay is typed and contributes no hazard":
    let overlay = newDarkBodyHazardOverlay()
    check overlay.state == bhsDark
    check overlay.arrivalAt(0) == HazardNeverArrives
    check overlay.hazardStepCostQ4(0, 10_000, 181) == 0

  test "projection takes the minimum damage arrival over each nav cell":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
    var source = map.uniformSnapshot(500)
    let
      navX = 3
      navY = 4
      sourceX = navX * 2
      sourceY = navY * 2
    source.damage[sourceY * source.gridW + sourceX] = 91
    source.damage[sourceY * source.gridW + sourceX + 1] = 73
    source.damage[(sourceY + 1) * source.gridW + sourceX] = 82
    source.damage[(sourceY + 1) * source.gridW + sourceX + 1] = 88
    let overlay = newBodyHazardOverlay(index, source)
    check overlay.state == bhsReady
    check overlay.fingerprint != 0
    check overlay.arrivalAt(navY * map.gridWidth + navX) == 73

  test "never-arrives is infinity for projection and room maxima":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
    var source = map.uniformSnapshot(HazardNeverArrives)
    let
      navX = 2
      navY = 2
      sourceX = navX * 2
      sourceY = navY * 2
    source.damage[sourceY * source.gridW + sourceX] = 120
    let overlay = newBodyHazardOverlay(index, source)
    check overlay.arrivalAt(navY * map.gridWidth + navX) == 120
    check overlay.arrivalAt((navY + 1) * map.gridWidth + navX + 1) ==
      HazardNeverArrives
    check overlay.roomMaxArrival.len == index.routeIndexStats.rooms
    check overlay.roomMaxArrival[0] == HazardNeverArrives

  test "segment extrema equal a cell-by-cell projection":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      source = map.uniformSnapshot(240)
      overlay = newBodyHazardOverlay(index, source)
    check overlay.segmentArrivalMin.len == index.routeIndexStats.segments
    check overlay.segmentArrivalMax.len == index.routeIndexStats.segments
    for segment in 0 ..< index.routeIndexStats.segments:
      let metadata = index.routeSegmentAt(segment)
      var
        minimum = HazardNeverArrives
        maximum = 0'u16
      for offset in 0 ..< metadata.cellLen.int:
        let arrival = overlay.arrivalAt(
          index.routeNavCell(index.segmentCellAt(segment, offset)).int)
        minimum = min(minimum, arrival)
        maximum = max(maximum, arrival)
      check overlay.segmentArrivalMin[segment] == minimum
      check overlay.segmentArrivalMax[segment] == maximum

  test "segment extrema skips equal cell-by-cell directional scoring":
    let
      map = newBodyMap(loadCtfMapMetadata("arena"))
      index = newBodyRouteIndex(map)
      segment = 0
      entryPhysical = 77'i64
      elapsed = 40
      ramp = newBodyHazardOverlay(index, map.uniformSnapshot(140))
      zero = newBodyHazardOverlay(index, map.uniformSnapshot(10_000))
      saturated = newBodyHazardOverlay(index, map.uniformSnapshot(0))
    for reversed in [false, true]:
      check ramp.hazardSegmentCostQ4(index, segment, reversed, elapsed,
        entryPhysical) == ramp.manualSegmentHazard(index, segment, reversed,
          elapsed, entryPhysical)
      check zero.hazardSegmentCostQ4(index, segment, reversed, elapsed,
        entryPhysical) == 0
      check zero.hazardSegmentCostQ4(index, segment, reversed, elapsed,
        entryPhysical) == zero.manualSegmentHazard(index, segment, reversed,
          elapsed, entryPhysical)
      check saturated.hazardSegmentCostQ4(index, segment, reversed, elapsed,
        entryPhysical) == saturated.manualSegmentHazard(index, segment,
          reversed, elapsed, entryPhysical)

  test "hazard ramp boundaries are exact and painted cells remain finite":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      overlay = newBodyHazardOverlay(index, map.uniformSnapshot(200))
      cell = 2 * map.gridWidth + 2
    check overlay.hazardStepCostQ4(cell, 104, 128) == 0
    check overlay.hazardStepCostQ4(cell, 152, 128) == 768
    check overlay.hazardStepCostQ4(cell, 200, 128) == 1536
    check overlay.hazardStepCostQ4(cell, 500, 128) == 1536

  test "safe cache rekeys on bucket generation and backward elapsed time":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      overlay = newBodyHazardOverlay(index, map.uniformSnapshot(500))
      cache = newBodySafeCache()
    cache.refreshSafeCache(index, overlay, 96, 7)
    let firstRevision = cache.revision
    check cache.overlayFingerprint == overlay.fingerprint
    check cache.gameGeneration == 7
    check cache.bucket == 2
    cache.refreshSafeCache(index, overlay, 97, 7)
    check cache.revision == firstRevision
    cache.refreshSafeCache(index, overlay, 48, 7)
    check cache.bucket == 1
    check cache.revision == firstRevision + 1
    cache.refreshSafeCache(index, overlay, 48, 8)
    check cache.gameGeneration == 8
    check cache.revision == firstRevision + 2

  test "never-arrives remains dry beyond the uint16 tick range":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      overlay = newBodyHazardOverlay(index,
        map.uniformSnapshot(HazardNeverArrives))
      cache = newBodySafeCache()
    cache.refreshSafeCache(index, overlay, 100_000, 1)
    check cache.roomHasDryAt(overlay, 0)

  test "safe cache refuses reads against another overlay fingerprint":
    let
      map = openMap()
      index = newBodyRouteIndex(map)
      first = newBodyHazardOverlay(index, map.uniformSnapshot(500, 1))
      second = newBodyHazardOverlay(index, map.uniformSnapshot(500, 2))
      cache = newBodySafeCache()
    cache.refreshSafeCache(index, first, 0, 1)
    expect AssertionDefect:
      discard cache.roomHasDryAt(second, 0)
