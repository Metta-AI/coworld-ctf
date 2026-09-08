## FL-A/FL-B laws for the contracted per-seat body data and movement seam.

import std/[options, sequtils, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[sim_types, zone_field]
import ../src/shell/body
import ../src/shell/body_cache
import ../src/shell/body_hazard
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
import ../src/shell/body_route_index
import ../src/shell/types as shellTypes

proc openMap(): BodyMap =
  const Width = 192
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2,
    @[(16, 48), (Width - 17, 48)])

proc smallOpenMap(): BodyMap =
  const Width = 64
  const Height = 48
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2,
    @[(16, 24), (Width - 17, 24)])

proc selfState(pos: BodyPoint = (16, 48), alive = true,
               aimBrads = 32): BodySelfState =
  BodySelfState(pos: pos, hp: (if alive: 2 else: 0),
    hpFrac: (if alive: 2.0 / 3.0 else: 0.0), aimBrads: aimBrads,
    alive: alive, carrying: false)

proc holdIntent(idleAim = 0): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikHold, point: none(MapPoint),
    idleAimCenterBrads: idleAim, profile: shellTypes.cpDefault,
    combat: shellTypes.CombatPolicy())

proc navigateIntent(point: BodyPoint, arriveRadius = 0.0,
                    movingGoal = false, idleAim = 0,
                    targetClass = ""): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikNavigateTo,
    point: some(MapPoint(x: point.x, y: point.y)),
    arriveRadius: arriveRadius, movingGoal: movingGoal,
    idleAimCenterBrads: idleAim, profile: shellTypes.cpDefault,
    combat: shellTypes.CombatPolicy(), targetClass: targetClass)

proc snapshotFromNav(map: BodyMap; arrivals: openArray[uint16]):
    ZoneDamageSnapshot =
  require arrivals.len == map.gridWidth * map.gridHeight
  result.gridW = (map.width + 3) div 4
  result.gridH = (map.height + 3) div 4
  result.cellPx = 4
  result.fingerprint = 71
  result.damage = newSeq[uint16](result.gridW * result.gridH)
  for cellIndex, arrival in arrivals:
    let
      navX = cellIndex mod map.gridWidth
      navY = cellIndex div map.gridWidth
    for sourceY in navY * 2 .. navY * 2 + 1:
      for sourceX in navX * 2 .. navX * 2 + 1:
        result.damage[sourceY * result.gridW + sourceX] = arrival

proc hasMovement(input: InputState): bool =
  input.up or input.down or input.left or input.right

proc mask(input: InputState): uint8 =
  encodeInputMask(input)

proc withoutActuatorWeapons(input: InputState): bool =
  not input.attack and not input.c

proc stepPosition(pos: BodyPoint, input: InputState): BodyPoint =
  result = pos
  if input.left:
    dec result.x, 8
  if input.right:
    inc result.x, 8
  if input.up:
    dec result.y, 8
  if input.down:
    inc result.y, 8

proc stepAim(aimBrads: int, input: InputState): int =
  result = aimBrads
  if input.b and not input.select:
    result = (result + AimTurnRate) mod AimBradsTurn
  elif input.select and not input.b:
    result = (result - AimTurnRate + AimBradsTurn) mod AimBradsTurn

proc near(a, b: BodyPoint, radius: float): bool =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  float(dx * dx + dy * dy) <= radius * radius

proc settlePlans(nav: BodyNavSystem, tick: var int, limit = 400) =
  var guard = 0
  while guard < limit:
    var pending = false
    for seat in nav.seats:
      pending = pending or seat.job.planPending
    if not pending:
      return
    discard nav.runPlanningTick(tick)
    inc tick
    inc guard
  raise newException(ValueError, "planning did not settle")

suite "shell body seat belief-lite seam":
  test "activation installs the safe standing order":
    let body = activateSeatBody(openMap(), 7, 331)
    check body.seatIndex == 7
    check body.nav.seatCount == 8
    check body.standingIntent.kind == shellTypes.ikHold
    check body.standingIntent.point.isNone
    check body.standingIntent.combat == shellTypes.CombatPolicy()
    check body.effectiveEpoch == 0
    check body.standingGoal.isNone

  test "activation references the shared episode navigation system":
    let map = smallOpenMap()
    let nav = newBodyNavSystem(map, 2, 331, DangerCadenceK, 16)
    let first = activateSeatBody(nav, 0)
    let second = activateSeatBody(nav, 1)
    check first.map == map
    check second.map == map
    check first.nav == nav
    check second.nav == nav
    check first.seatIndex == 0
    check second.seatIndex == 1

    first.updateBelief(BodyTickInputs(self: selfState((16, 24)),
      visibleTracks: @[
        BodyTrackUpdate(seat: 1, pos: (32, 24), team: Blue,
          aimBrads: some(0), hpKnown: none(int), tick: 0)]), 0)
    second.updateBelief(BodyTickInputs(self: selfState((48, 24)),
      visibleTracks: @[
        BodyTrackUpdate(seat: 0, pos: (32, 24), team: Red,
          aimBrads: some(0), hpKnown: none(int), tick: 0)]), 0)
    nav.rebuildScheduledDanger(0, @[
      first.dangerInputFromTracks(0, proc(track: BodyTrack): bool = true),
      second.dangerInputFromTracks(0, proc(track: BodyTrack): bool = true)])
    var dangerTrace = nav.dangerTraceSnapshot
    check dangerTrace.len == 1
    check dangerTrace[0].tick == 0
    check dangerTrace[0].seat == 0

    second.updateBelief(BodyTickInputs(self: selfState((48, 24)),
      visibleTracks: @[
        BodyTrackUpdate(seat: 0, pos: (32, 24), team: Red,
          aimBrads: some(0), hpKnown: none(int), tick: 1)]), 1)
    nav.rebuildScheduledDanger(1, @[
      first.dangerInputFromTracks(1, proc(track: BodyTrack): bool = true),
      second.dangerInputFromTracks(1, proc(track: BodyTrack): bool = true)])
    dangerTrace = nav.dangerTraceSnapshot
    check dangerTrace.len == 2
    check dangerTrace[1].tick == 1
    check dangerTrace[1].seat == 1

    let goal0 = map.validateGoal((48, 24), (16, 24)).get
    let goal1 = map.validateGoal((16, 24), (48, 24)).get
    nav.replacePlan(first.seatIndex, 10, (16, 24), goal0)
    nav.replacePlan(second.seatIndex, 11, (48, 24), goal1)
    let spent = nav.runPlanningTick(2)
    check spent <= ColdPlanBudgetPerTick
    var tickSpend = 0
    var sawFirst = false
    var sawSecond = false
    for visit in nav.planningTraceSnapshot:
      if visit.tick == 2:
        tickSpend += visit.units
        sawFirst = sawFirst or visit.seat == first.seatIndex
        sawSecond = sawSecond or visit.seat == second.seatIndex
    for visit in nav.mintTraceSnapshot:
      if visit.tick == 2:
        tickSpend += visit.units
    check tickSpend == spent
    check sawFirst
    check sawSecond

  test "inactive navigation seats are skipped and cannot be queried":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 2, 331, traceCapacity = 8,
        prepareRouteQueries = true)
      start: BodyPoint = (16, 48)
      goal = map.validateGoal((160, 48), start).get
    nav.setSeatActive(1, false)
    nav.rebuildScheduledDanger(1, [DangerInput(), DangerInput()])
    check nav.dangerTraceSnapshot.len == 0
    expect AssertionDefect:
      discard nav.navigationWaypoint(1, start, goal, 1)
    expect AssertionDefect:
      discard nav.steeringMask(1, start, goal.goalPoint,
        shellTypes.cpDefault, 0)

  test "standing intent validates goals without mutating navigation work":
    let map = openMap()
    let body = activateSeatBody(map, 3, 331)
    let point: BodyPoint = (160, 48)
    let goal = map.validateGoal(point, (16, 48)).get
    expect ValueError:
      body.setStandingIntent(navigateIntent(point), none(ValidatedGoal), 4)
    expect ValueError:
      body.setStandingIntent(holdIntent(), some(goal), 4)

    body.nav.replacePlan(0, 1, (16, 48), goal)
    body.nav.replacePlan(body.seatIndex, 1, (16, 48), goal)
    body.nav.seats[body.seatIndex].cache.pinStandingGoal((80, 48))
    let existingPin = body.nav.seats[body.seatIndex].cache.pinnedRouteKey
    check body.nav.seats[0].job.planPending
    check body.nav.seats[body.seatIndex].job.planPending
    body.setStandingIntent(navigateIntent(point), some(goal), 5)
    check body.nav.seats[0].job.planPending
    check body.nav.seats[body.seatIndex].job.planPending
    check body.standingIntent.kind == shellTypes.ikNavigateTo
    check body.effectiveEpoch == 5
    check body.standingGoal.get.goalPoint == goal.goalPoint
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey == existingPin

    body.setStandingIntent(holdIntent(), none(ValidatedGoal), 6)
    check body.effectiveEpoch == 6
    check body.standingGoal.isNone
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey == existingPin

  test "safe epoch zero intent leaves navigation work untouched":
    let map = openMap()
    let body = activateSeatBody(map, 3, 331)
    let start: BodyPoint = (16, 48)
    let point: BodyPoint = (160, 48)
    let goal = map.validateGoal(point, start).get

    body.setStandingIntent(navigateIntent(point), some(goal), 9)
    body.nav.replacePlan(body.seatIndex, 9, start, goal)
    check body.nav.seats[body.seatIndex].job.planPending
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey.isNone

    body.setStandingIntent(holdIntent(), none(ValidatedGoal), 0)
    check body.effectiveEpoch == 0
    check body.standingIntent.kind == shellTypes.ikHold
    check body.standingGoal.isNone
    check body.nav.seats[body.seatIndex].job.planPending
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey.isNone

    let input = body.seatTick(BodyTickInputs(self: selfState(start)), 10)
    check input.mask == ButtonSelect

  test "request anchors coalesce drift, cadence, profile, and semantic identity":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      seat = nav.seats[0]
      literal = NavRequestAnchor(goalCell: (10, 6),
        identity: NavTargetIdentity(kind: ntiLiteral, sourceCell: 154),
        profile: shellTypes.cpDefault)
    seat.setActivePathForTest([(16, 48), (160, 48)], 1)
    check seat.shouldQueryRoute(literal, 0)
    seat.acceptRequestAnchor(literal, 0)
    check not seat.shouldQueryRoute(NavRequestAnchor(goalCell: (11, 6),
      identity: NavTargetIdentity(kind: ntiLiteral, sourceCell: 155),
      profile: shellTypes.cpDefault), 1)
    check not seat.shouldQueryRoute(NavRequestAnchor(goalCell: (12, 6),
      identity: NavTargetIdentity(kind: ntiLiteral, sourceCell: 156),
      profile: shellTypes.cpDefault), 2)
    check seat.shouldQueryRoute(NavRequestAnchor(goalCell: (13, 6),
      identity: NavTargetIdentity(kind: ntiLiteral, sourceCell: 157),
      profile: shellTypes.cpDefault), 3)
    check seat.acceptedAnchor.get == literal

    var moving = literal
    moving.moving = true
    check not seat.shouldQueryRoute(moving, 11)
    check seat.shouldQueryRoute(moving, 12)

    var carrier = literal
    carrier.profile = shellTypes.cpCarrier
    check seat.shouldQueryRoute(carrier, 1)

    let semantic = NavRequestAnchor(goalCell: (10, 6),
      identity: NavTargetIdentity(kind: ntiZoneSafeGround, sourceCell: 154),
      profile: shellTypes.cpDefault)
    seat.acceptRequestAnchor(semantic, 20)
    var changedSource = semantic
    changedSource.identity.sourceCell = 155
    check seat.shouldQueryRoute(changedSource, 21)

    seat.stuckTicks = 7
    check not seat.shouldQueryRoute(semantic, 21)
    seat.stuckTicks = 8
    check seat.shouldQueryRoute(semantic, 21)

    let emptySeat = newBodyNavSystem(map, 1, 331).seats[0]
    emptySeat.acceptRequestAnchor(literal, 0)
    check emptySeat.shouldQueryRoute(literal, 1)

  test "a requested anchor survives failure while an old route advances":
    let
      map = openMap()
      nav = newBodyNavSystem(map, 1, 331)
      seat = nav.seats[0]
      start: BodyPoint = (16, 48)
      oldPath = [start, (80, 48)]
      goal = map.validateGoal((160, 48), start).get
      goalCell = map.cellOf(goal.goalPoint)
      anchor = NavRequestAnchor(goalCell: goalCell,
        identity: NavTargetIdentity(kind: ntiLiteral,
          sourceCell: int32(goalCell.y * map.gridWidth + goalCell.x)),
        profile: shellTypes.cpDefault)
    seat.setActivePathForTest(oldPath, 1)
    discard nav.navigationWaypoint(0, start, goal, 7)
    check seat.job.planPending
    check seat.acceptedAnchor == some(anchor)
    check seat.activePath == @oldPath

    seat.cache.cancelPlan(seat.job)
    check not seat.job.planPending
    check not seat.shouldQueryRoute(anchor, 8)
    seat.cursor = seat.pathLen
    check seat.shouldQueryRoute(anchor, 8)

  test "semantic goal resolves before arrival and dark context uses fallback":
    let
      map = openMap()
      start: BodyPoint = (16, 48)
      fallback = map.validateGoal(start, start).get
      intent = navigateIntent(start, arriveRadius = 4.0,
        targetClass = NavTargetClassZoneSafeGround)

    block dark:
      let body = activateSeatBody(map, 0, 331)
      body.setStandingIntent(intent, some(fallback), 1)
      body.updateBelief(BodyTickInputs(self: selfState(start)), 1)
      let resolved = body.resolveEffectiveGoal(0, 1)
      check resolved.goal.goalPoint == start
      check resolved.identity.kind == ntiLiteral

    block ready:
      let
        index = newBodyRouteIndex(map)
        nav = newBodyNavSystem(map, 1, 331, prepareRouteQueries = true,
          preparedRouteIndex = index)
        safeCell: BodyPoint = (map.gridWidth - 3, map.gridHeight div 2)
        safeIndex = safeCell.y * map.gridWidth + safeCell.x
      var arrivals = newSeq[uint16](map.gridWidth * map.gridHeight)
      for value in arrivals.mitems:
        value = 0
      arrivals[safeIndex] = HazardNeverArrives
      nav.installSafetyContext(newBodyHazardOverlay(index,
        map.snapshotFromNav(arrivals)), newBodySafeCache())

      let body = activateSeatBody(nav, 0)
      body.setStandingIntent(intent, some(fallback), 4)
      body.updateBelief(BodyTickInputs(self: selfState(start)), 1)
      let resolved = body.resolveEffectiveGoal(0, 77)
      check resolved.goal.goalPoint != start
      check resolved.identity == NavTargetIdentity(kind: ntiZoneSafeGround,
        sourceCell: int32(safeIndex))

      discard body.actFromBelief(1, elapsedTick = 0, gameGeneration = 77)
      check nav.seats[0].desiredGoal == some(resolved.goal.goalPoint)
      check nav.seats[0].acceptedAnchor.get.identity == resolved.identity

      let revision = nav.seats[0].revision
      body.setStandingIntent(intent, some(fallback), 99)
      discard body.actFromBelief(2, elapsedTick = SafeBucketTicks,
        gameGeneration = 78)
      check nav.seats[0].revision == revision

  test "seatTick matches explicit belief fold then action":
    let
      map = openMap()
      wrapped = activateSeatBody(map, 0, 331)
      split = activateSeatBody(map, 0, 331)
      inputs = BodyTickInputs(self: selfState(aimBrads = 0),
        visibleTracks: @[
          BodyTrackUpdate(seat: 1, pos: (80, 48), team: Blue,
            aimBrads: some(128), hpKnown: some(2), tick: 10)])
    wrapped.setStandingIntent(holdIntent(64), none(ValidatedGoal), 1)
    split.setStandingIntent(holdIntent(64), none(ValidatedGoal), 1)

    let wrappedInput = wrapped.seatTick(inputs, 10)
    split.updateBelief(inputs, 10)
    let splitInput = split.actFromBelief(10)

    check wrapped.beliefFingerprint == split.beliefFingerprint
    check wrappedInput.mask == splitInput.mask
    check wrapped.navState == split.navState
    check wrapped.combatOutcome == split.combatOutcome

  test "fog absence preserves stale tracks and never invents knowledge":
    let body = activateSeatBody(openMap(), 0, 331)
    for track in body.tracks:
      check track.isNone
    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 4, pos: (80, 40), team: Blue,
        aimBrads: some(64), hpKnown: none(int), tick: 10)]), 10)
    check body.tracks[4].isSome
    check body.tracks[4].get.hpKnown.isNone
    check body.tracks[5].isNone

    body.updateBelief(BodyTickInputs(self: selfState()), 11)
    check body.tracks[4].get.pos == (80, 40)
    check body.tracks[4].get.freshTick == 10
    check body.tracks[4].get.hpKnown.isNone

    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 4, pos: (82, 40), team: Blue,
        aimBrads: some(65), hpKnown: some(2), tick: 12)]), 12)
    check body.tracks[4].get.hpKnown == some(2)

  test "duo telemetry is live sim truth and ends exactly at death":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, team: Red, pos: (70, 30), aimBrads: 12,
        alive: true))), 3)
    check body.tracks[1].isNone
    check body.partnerTelemetry == some((seat: 1'u8, team: Red, pos: (70, 30),
      aimBrads: 12, alive: true, downed: false, hasGun: false,
      hasHopper: false))

    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 1, pos: (60, 30), team: Red,
        aimBrads: some(8), hpKnown: none(int), tick: 3)], partner:
      some(PartnerSample(seat: 1, team: Red, pos: (74, 31), aimBrads: 14,
        alive: true))), 4)
    check body.tracks[1].get.pos == (60, 30)
    check body.partnerTelemetry.get.pos == (74, 31)

    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, team: Red, pos: (74, 31), aimBrads: 14,
        alive: false))), 5)
    check body.partnerTelemetry.isNone
    check body.tracks[1].get.pos == (60, 30)

  test "duo telemetry carries the down flag":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, team: Red, pos: (70, 30), aimBrads: 12,
        alive: true, downed: true))), 3)
    check body.partnerTelemetry.get.downed
    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, team: Red, pos: (70, 30), aimBrads: 12,
        alive: true, downed: false))), 4)
    check not body.partnerTelemetry.get.downed

    let solo = activateSeatBody(openMap(), 2, 331)
    solo.updateBelief(BodyTickInputs(self: selfState()), 1)
    check solo.partnerTelemetry.isNone

  test "belief updates are deterministic within a tick":
    let map = openMap()
    let first = activateSeatBody(map, 0, 331)
    let second = activateSeatBody(map, 0, 331)
    let a = BodyTrackUpdate(seat: 7, pos: (100, 40), team: Blue,
      aimBrads: some(80), hpKnown: some(1), tick: 20)
    let b = BodyTrackUpdate(seat: 3, pos: (60, 50), team: Red,
      aimBrads: some(16), hpKnown: none(int), tick: 20)
    let partner = some(PartnerSample(seat: 1, pos: (48, 48),
      aimBrads: 30, alive: true))
    first.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[a, b], partner: partner), 20)
    second.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[b, a], partner: partner), 20)
    check first.beliefFingerprint == second.beliefFingerprint

  test "danger input uses only fresh predicate-approved tracks":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 1, pos: (50, 40), team: Red,
        aimBrads: some(0), hpKnown: none(int), tick: 8),
      BodyTrackUpdate(seat: 2, pos: (70, 40), team: Blue,
        aimBrads: some(0), hpKnown: none(int), tick: 9),
      BodyTrackUpdate(seat: 3, pos: (90, 40), team: Blue,
        aimBrads: some(0), hpKnown: none(int), tick: 8)]), 9)
    let input = body.dangerInputFromTracks(9,
      proc(track: BodyTrack): bool = track.team != Red)
    check input.selfXy == body.selfState.pos
    check input.candidates.len == 1
    check input.candidates[0].seatIndex == 2
    check input.candidates[0].pos == (70, 40)

  test "belief event windows expire exactly on their first outside tick":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(),
      aggressorEvents: @[
        AggressorEvent(eventId: 1, tick: 10, dirBrads: 64,
          seat: some(3))]), 10)
    body.updateBelief(BodyTickInputs(self: selfState(),
      killFeed: @[KillEvent(eventId: 2, tick: 20, killerTeam: Blue,
        victimSeat: 4)]), 20)

    body.updateBelief(BodyTickInputs(self: selfState()), 129)
    check body.aggressorEvents.len == 1
    body.updateBelief(BodyTickInputs(self: selfState()), 130)
    check body.aggressorEvents.len == 0

    body.updateBelief(BodyTickInputs(self: selfState()), 259)
    check body.killFeed.len == 1
    body.updateBelief(BodyTickInputs(self: selfState()), 260)
    check body.killFeed.len == 0

  test "item memory updates by kind and cell and evicts oldest then farthest":
    let body = activateSeatBody(openMap(), 0, 331)
    var sightings: seq[ItemSighting]
    for index in 0 ..< 32:
      sightings.add(ItemSighting(kind: bikMedkit,
        pos: (16 + (index mod 16) * 8, 24 + (index div 16) * 8),
        present: true, tick: 10))
    sightings.add(ItemSighting(kind: bikGrenade,
      pos: (180, 80), present: true, tick: 10))
    body.updateBelief(BodyTickInputs(self: selfState(),
      sightedItems: sightings), 10)
    check body.items.len == 32
    check body.items.allIt(not (it.kind == bikGrenade and it.pos == (180, 80)))

    body.updateBelief(BodyTickInputs(self: selfState(),
      sightedItems: @[ItemSighting(kind: bikMedkit, pos: (18, 26),
        present: false, tick: 11)]), 11)
    check body.items.len == 32
    let id = body.map.itemEventIdForPoint(bikMedkit, (18, 26))
    check body.items.countIt(it.eventId == id) == 1
    let updated = body.items.filterIt(it.eventId == id)[0]
    check updated.pos == (18, 26)
    check updated.present == false
    check updated.freshTick == 11

    body.updateBelief(BodyTickInputs(self: selfState(),
      sightedItems: @[
        ItemSighting(kind: bikShield, pos: (24, 40), present: true, tick: 20),
        ItemSighting(kind: bikSpray, pos: (180, 80), present: true,
          tick: 20)]), 20)
    check body.items.len == 32
    check body.items.anyIt(it.kind == bikShield and it.pos == (24, 40))
    check body.items.anyIt(it.kind == bikSpray and it.pos == (180, 80))

  test "fog discipline keeps unseen facts absent and stale bounty false":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[
        BodyTrackUpdate(seat: 6, pos: (90, 40), team: Blue,
          aimBrads: none(int), hpKnown: none(int), veteranMarker: true,
          tick: 40)],
      killFeed: @[KillEvent(eventId: 44, tick: 40, killerTeam: Red,
        victimSeat: 7)],
      aggressorEvents: @[AggressorEvent(eventId: 45, tick: 40,
        dirBrads: 12, seat: none(int))]), 40)
    check body.items.len == 0
    check body.killFeed[0].killerTeam == Red
    static:
      doAssert not compiles(KillEvent(eventId: 1, tick: 1,
        killerTeam: Red, killerSeat: 2, victimSeat: 3))
      doAssert not compiles(KillEvent(eventId: 1, tick: 1,
        killerTeam: Red, victimSeat: 3, pos: (1, 1)))
    check body.aggressorEvents[0].seat.isNone
    check body.tracks[6].get.veteranMarker
    check body.preferenceScores(6, 41, 331, 3).bounty == 0.0

  test "shouts are current live-shouter facts, not retained memory":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(),
      shouts: @[ShoutEvent(eventId: 50, team: Red, slotLetter: "A",
        text: "go", pos: (30, 30), tick: 40)]), 40)
    check body.shouts.len == 1
    body.updateBelief(BodyTickInputs(self: selfState()), 41)
    check body.shouts.len == 0

  test "prefer scoring uses unknown hp zero and aggressor-only revenge":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[
        BodyTrackUpdate(seat: 1, pos: (80, 40), team: Blue,
          aimBrads: some(0), hpKnown: none(int), tick: 50),
        BodyTrackUpdate(seat: 2, pos: (96, 40), team: Blue,
          aimBrads: some(0), hpKnown: some(1), veteranMarker: true,
          tick: 50),
        BodyTrackUpdate(seat: 3, pos: (184, 40), team: Green,
          aimBrads: some(0), hpKnown: some(3), tick: 50)],
      killFeed: @[KillEvent(eventId: 60, tick: 50, killerTeam: Blue,
        victimSeat: 4)]), 50)
    check body.preferenceScores(1, 50, 331, 3).weakened == 0.0
    check body.preferenceScores(2, 50, 331, 3).weakened > 0.66
    check body.preferenceScores(2, 50, 331, 3).bounty == 1.0
    check body.preferenceScores(2, 50, 331, 3).revenge == 0.0

    body.updateBelief(BodyTickInputs(self: selfState(),
      aggressorEvents: @[AggressorEvent(eventId: 61, tick: 51,
        dirBrads: 8, seat: some(3))]), 51)
    check body.preferenceScores(3, 51, 331, 3).revenge == 1.0
    check body.compareByPreference(3, 2, @[ptRevenge, ptWeakened],
      51, 331, 3) < 0
    check body.compareByPreference(2, 3, @[ptWeakened, ptRevenge],
      51, 331, 3) < 0

  test "full belief is deterministic across input permutations":
    proc filled(order: seq[int]): SeatBody =
      result = activateSeatBody(openMap(), 0, 331)
      let tracks = [
        BodyTrackUpdate(seat: 4, pos: (80, 40), team: Blue,
          aimBrads: none(int), hpKnown: none(int), tick: 70),
        BodyTrackUpdate(seat: 2, pos: (60, 40), team: Red,
          aimBrads: some(12), hpKnown: some(2), veteranMarker: true,
          tick: 70)]
      let items = [
        ItemSighting(kind: bikMedkit, pos: (16, 16), present: true,
          tick: 70),
        ItemSighting(kind: bikGrenade, pos: (48, 16), present: false,
          tick: 70)]
      let aggressors = [
        AggressorEvent(eventId: 91, tick: 70, dirBrads: 64,
          seat: some(2)),
        AggressorEvent(eventId: 90, tick: 70, dirBrads: 32,
          seat: none(int))]
      let kills = [
        KillEvent(eventId: 101, tick: 69, killerTeam: Blue, victimSeat: 5),
        KillEvent(eventId: 100, tick: 70, killerTeam: Red, victimSeat: 6)]
      let shouts = [
        ShoutEvent(eventId: 111, team: Blue, slotLetter: "B",
          text: "hold", pos: (40, 40), tick: 70),
        ShoutEvent(eventId: 110, team: Red, slotLetter: "A",
          text: "go", pos: (30, 40), tick: 70)]
      var inputs = BodyTickInputs(self: selfState())
      for index in order:
        inputs.visibleTracks.add(tracks[index])
        inputs.sightedItems.add(items[index])
        inputs.aggressorEvents.add(aggressors[index])
        inputs.killFeed.add(kills[index])
        inputs.shouts.add(shouts[index])
      inputs.hazards.grenades = @[
        BodyGrenadeHazard(eventId: 201, coversSelf: false,
          pos: (70, 70), predictedBlastPos: (90, 90), ticksToBlast: 4),
        BodyGrenadeHazard(eventId: 200, coversSelf: true,
          pos: (70, 70), predictedBlastPos: (90, 90), ticksToBlast: 4)]
      inputs.hazards.sprays = @[
        BodySprayHazard(kind: bshAnonymousImpact, eventId: 301,
          coversSelf: true, tick: 70, impactPos: (20, 20),
          incomingDirBrads: 9),
        BodySprayHazard(kind: bshAnonymousImpact, eventId: 300,
          coversSelf: true, tick: 70, impactPos: (20, 20),
          incomingDirBrads: 9)]
      result.updateBelief(inputs, 70)

    let first = filled(@[0, 1])
    let second = filled(@[1, 0])
    check first.beliefFingerprint == second.beliefFingerprint
    check first.hazards.grenades.len == 2
    check first.hazards.grenades[0].eventId == 200
    check first.hazards.sprays.len == 2

  test "seatTick follows externally-budgeted navigation to a standing goal":
    let map = openMap()
    let nav = newBodyNavSystem(map, 1, 331)
    let body = activateSeatBody(nav, 0)
    let start: BodyPoint = (16, 48)
    let target: BodyPoint = (160, 48)
    let goal = map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target, arriveRadius = 10.0),
      some(goal), 1)

    var
      pos = start
      aim = 32
      tick = 0
      masks: seq[uint8]
    while tick < 512 and not near(pos, goal.goalPoint, 10.0):
      let traceLen = nav.planningTraceSnapshot.len
      let input = body.seatTick(BodyTickInputs(
        self: selfState(pos, aimBrads = aim)), tick.uint32)
      check nav.planningTraceSnapshot.len == traceLen
      masks.add(input.mask)
      check input.withoutActuatorWeapons
      check nav.dangerTraceSnapshot.len == 0
      discard nav.runPlanningTick(tick)
      check nav.planningTraceSnapshot.len >= traceLen
      pos = stepPosition(pos, input)
      aim = stepAim(aim, input)
      inc tick

    check near(pos, goal.goalPoint, 10.0)
    check masks.anyIt((it and (ButtonUp or ButtonDown or ButtonLeft or
      ButtonRight)) != 0)

    let stopped = body.seatTick(BodyTickInputs(
      self: selfState(pos, aimBrads = aim)), tick.uint32)
    check not stopped.hasMovement
    check stopped.withoutActuatorWeapons

    let replayNav = newBodyNavSystem(map, 1, 331)
    let replayBody = activateSeatBody(replayNav, 0)
    replayBody.setStandingIntent(navigateIntent(target, arriveRadius = 10.0),
      some(goal), 1)
    var replayPos = start
    var replayAim = 32
    for replayTick, expected in masks:
      let input = replayBody.seatTick(BodyTickInputs(
        self: selfState(replayPos, aimBrads = replayAim)), replayTick.uint32)
      check input.mask == expected
      discard replayNav.runPlanningTick(replayTick)
      replayPos = stepPosition(replayPos, input)
      replayAim = stepAim(replayAim, input)

  test "idleSweepAim persists and reverses at both arc ends":
    let body = activateSeatBody(openMap(), 0, 331)
    var observed: seq[int]
    for _ in 0 ..< 28:
      observed.add(body.idleSweepAim(64))
    check observed == @[69, 74, 79, 84, 89, 94, 96, 91, 86, 81, 76, 71,
      66, 61, 56, 51, 46, 41, 36, 32, 37, 42, 47, 52, 57, 62, 67, 72]

  test "seatTick hold emits no movement and honors idle aim":
    let body = activateSeatBody(openMap(), 0, 331)
    body.setStandingIntent(holdIntent(64), none(ValidatedGoal), 1)

    let rotating = body.seatTick(BodyTickInputs(
      self: selfState(aimBrads = 0)), 0)
    check not rotating.hasMovement
    check rotating.b
    check not rotating.select
    check rotating.withoutActuatorWeapons

    # Aim bits are allowed to move in phase 5: the old FL-B placeholder
    # converged and held; the real Stencil idle aim sweeps continuously.
    let sweeping = body.seatTick(BodyTickInputs(
      self: selfState(aimBrads = 63)), 1)
    check not sweeping.hasMovement
    check sweeping.b
    check not sweeping.select
    check sweeping.withoutActuatorWeapons

  test "seatTick arrival stops movement before scheduling route work":
    let map = openMap()
    let body = activateSeatBody(map, 0, 331)
    let start: BodyPoint = (16, 48)
    let target: BodyPoint = (24, 48)
    let goal = map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target, arriveRadius = 12.0),
      some(goal), 1)

    let input = body.seatTick(BodyTickInputs(
      self: selfState(start, aimBrads = 32)), 0)
    check input.mask == ButtonSelect
    check not body.nav.seats[body.seatIndex].job.planPending
    check body.nav.planningTraceSnapshot.len == 0

  test "seatTick dead seats return zero while still applying belief":
    let body = activateSeatBody(openMap(), 0, 331)
    let start: BodyPoint = (16, 48)
    let target: BodyPoint = (160, 48)
    let goal = body.map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target), some(goal), 1)

    let input = body.seatTick(BodyTickInputs(self: selfState(start,
      alive = false), visibleTracks: @[
        BodyTrackUpdate(seat: 5, pos: (80, 48), team: Blue,
          aimBrads: some(64), hpKnown: some(2), tick: 7)]), 7)
    check input.mask == 0
    check body.tracks[5].isSome
    check body.tracks[5].get.pos == (80, 48)
    check not body.nav.seats[body.seatIndex].job.planPending
    check body.nav.planningTraceSnapshot.len == 0

  test "seatTick never emits weapon bits during mixed movement and idle aim":
    let map = openMap()
    let nav = newBodyNavSystem(map, 1, 331)
    let body = activateSeatBody(nav, 0)
    let start: BodyPoint = (16, 48)
    let target: BodyPoint = (160, 48)
    let goal = map.validateGoal(target, start).get
    body.setStandingIntent(navigateIntent(target, arriveRadius = 10.0,
      movingGoal = true, idleAim = 64), some(goal), 1)

    var
      pos = start
      aim = 0
    for tick in 0 ..< 512:
      let input = body.seatTick(BodyTickInputs(
        self: selfState(pos, aimBrads = aim)), tick.uint32)
      check (input.mask and ButtonA) == 0
      check (input.mask and ButtonC) == 0
      discard nav.runPlanningTick(tick)
      pos = stepPosition(pos, input)
      aim = stepAim(aim, input)

  test "seatTick order is deterministic across shared episode navigation":
    proc runOrder(order: seq[int]): tuple[masks: array[2, seq[uint8]],
                                         paths: array[2, seq[BodyPoint]]] =
      let map = smallOpenMap()
      let nav = newBodyNavSystem(map, 2, 331)
      let bodies = [activateSeatBody(nav, 0), activateSeatBody(nav, 1)]
      var positions: array[2, BodyPoint] = [(16, 24), (48, 24)]
      let goals = [
        map.validateGoal((48, 24), positions[0]).get,
        map.validateGoal((16, 24), positions[1]).get]
      bodies[0].setStandingIntent(navigateIntent((48, 24),
        arriveRadius = 8.0), some(goals[0]), 1)
      bodies[1].setStandingIntent(navigateIntent((16, 24),
        arriveRadius = 8.0), some(goals[1]), 1)

      var tick = 0
      while tick < 80:
        for seat in order:
          let input = bodies[seat].seatTick(BodyTickInputs(
            self: selfState(positions[seat], aimBrads = 32)), tick.uint32)
          result.masks[seat].add(input.mask)
        discard nav.runPlanningTick(tick)
        for seat in 0 .. 1:
          positions[seat] = stepPosition(positions[seat],
            decodeInputMask(result.masks[seat][^1]))
        inc tick
      nav.settlePlans(tick)
      for seat in 0 .. 1:
        result.paths[seat] = nav.seats[seat].activePath

    let forward = runOrder(@[0, 1])
    let reversed = runOrder(@[1, 0])
    check forward.masks == reversed.masks
    check forward.paths == reversed.paths
