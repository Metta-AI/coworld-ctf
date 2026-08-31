## FL-A laws for the contracted per-seat body data seam.

import std/[options, unittest]
import ../src/ctf/sim_types
import ../src/shell/body
import ../src/shell/body_cache
import ../src/shell/body_map
import ../src/shell/body_nav
import ../src/shell/body_planner
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

proc selfState(pos: BodyPoint = (16, 48), alive = true): BodySelfState =
  BodySelfState(pos: pos, hpFrac: 2.0 / 3.0, aimBrads: 32,
    alive: alive, carrying: false)

proc holdIntent(): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikHold, point: none(MapPoint),
    profile: shellTypes.cpDefault, combat: shellTypes.CombatPolicy())

proc navigateIntent(point: BodyPoint): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikNavigateTo,
    point: some(MapPoint(x: point.x, y: point.y)),
    profile: shellTypes.cpDefault, combat: shellTypes.CombatPolicy())

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
          aimBrads: 0, hpKnown: none(int), tick: 0)]), 0)
    second.updateBelief(BodyTickInputs(self: selfState((48, 24)),
      visibleTracks: @[
        BodyTrackUpdate(seat: 0, pos: (32, 24), team: Red,
          aimBrads: 0, hpKnown: none(int), tick: 0)]), 0)
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
          aimBrads: 0, hpKnown: none(int), tick: 1)]), 1)
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
    check tickSpend == spent
    check sawFirst
    check sawSecond

  test "standing intent enforces validated goals and supersedes old work":
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
    check body.nav.seats[0].job.planPending
    check body.nav.seats[body.seatIndex].job.planPending
    body.setStandingIntent(navigateIntent(point), some(goal), 5)
    check body.nav.seats[0].job.planPending
    check not body.nav.seats[body.seatIndex].job.planPending
    check body.standingIntent.kind == shellTypes.ikNavigateTo
    check body.effectiveEpoch == 5
    check body.standingGoal.get.goalPoint == goal.goalPoint
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey ==
      some(body.nav.seats[body.seatIndex].cache.routeKey(goal.goalPoint))

    body.setStandingIntent(holdIntent(), none(ValidatedGoal), 6)
    check body.effectiveEpoch == 6
    check body.standingGoal.isNone
    check body.nav.seats[body.seatIndex].cache.pinnedRouteKey.isNone

  test "fog absence preserves stale tracks and never invents knowledge":
    let body = activateSeatBody(openMap(), 0, 331)
    for track in body.tracks:
      check track.isNone
    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 4, pos: (80, 40), team: Blue,
        aimBrads: 64, hpKnown: none(int), tick: 10)]), 10)
    check body.tracks[4].isSome
    check body.tracks[4].get.hpKnown.isNone
    check body.tracks[5].isNone

    body.updateBelief(BodyTickInputs(self: selfState()), 11)
    check body.tracks[4].get.pos == (80, 40)
    check body.tracks[4].get.freshTick == 10
    check body.tracks[4].get.hpKnown.isNone

    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 4, pos: (82, 40), team: Blue,
        aimBrads: 65, hpKnown: some(2), tick: 12)]), 12)
    check body.tracks[4].get.hpKnown == some(2)

  test "duo telemetry is live sim truth and ends exactly at death":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, pos: (70, 30), aimBrads: 12,
        alive: true))), 3)
    check body.tracks[1].isNone
    check body.partnerTelemetry == some((seat: 1'u8, pos: (70, 30),
      aimBrads: 12, alive: true))

    body.updateBelief(BodyTickInputs(self: selfState(), visibleTracks: @[
      BodyTrackUpdate(seat: 1, pos: (60, 30), team: Red,
        aimBrads: 8, hpKnown: none(int), tick: 3)], partner:
      some(PartnerSample(seat: 1, pos: (74, 31), aimBrads: 14,
        alive: true))), 4)
    check body.tracks[1].get.pos == (60, 30)
    check body.partnerTelemetry.get.pos == (74, 31)

    body.updateBelief(BodyTickInputs(self: selfState(), partner:
      some(PartnerSample(seat: 1, pos: (74, 31), aimBrads: 14,
        alive: false))), 5)
    check body.partnerTelemetry.isNone
    check body.tracks[1].get.pos == (60, 30)

    let solo = activateSeatBody(openMap(), 2, 331)
    solo.updateBelief(BodyTickInputs(self: selfState()), 1)
    check solo.partnerTelemetry.isNone

  test "belief updates are deterministic within a tick":
    let map = openMap()
    let first = activateSeatBody(map, 0, 331)
    let second = activateSeatBody(map, 0, 331)
    let a = BodyTrackUpdate(seat: 7, pos: (100, 40), team: Blue,
      aimBrads: 80, hpKnown: some(1), tick: 20)
    let b = BodyTrackUpdate(seat: 3, pos: (60, 50), team: Red,
      aimBrads: 16, hpKnown: none(int), tick: 20)
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
        aimBrads: 0, hpKnown: none(int), tick: 8),
      BodyTrackUpdate(seat: 2, pos: (70, 40), team: Blue,
        aimBrads: 0, hpKnown: none(int), tick: 9),
      BodyTrackUpdate(seat: 3, pos: (90, 40), team: Blue,
        aimBrads: 0, hpKnown: none(int), tick: 8)]), 9)
    let input = body.dangerInputFromTracks(9,
      proc(track: BodyTrack): bool = track.team != Red)
    check input.selfXy == body.selfState.pos
    check input.candidates.len == 1
    check input.candidates[0].seatIndex == 2
    check input.candidates[0].pos == (70, 40)
