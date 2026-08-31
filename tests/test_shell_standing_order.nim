## Phase P3-1: the zero-guest standing order and its annotation predicate.

import std/[json, options, unittest]
import bitworld/spriteprotocol
import ../src/ctf/sim_types
import ../src/shell/[body_map, canonical, default_play, standing_order, types]

proc testBodyMap(): BodyMap =
  const Side = 512
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(10, 10)])

proc goal(map: BodyMap, x, y: int): ValidatedGoal =
  map.validateGoal((x, y), (10, 10)).get

proc bodyFixture(): SeatBody =
  result = activateSeatBody(testBodyMap(), 3)
  result.brSnapshot = LaneABrSnapshot(
    selfPos: MapPoint(x: 10, y: 10),
    currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
    nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zoneDps: 1,
    idleAimCenterBrads: 64)
  result.partner = PartnerTelemetry(
    identity: SeatRef(4), pos: MapPoint(x: 20, y: 20),
    aimBrads: 32, alive: true)

suite "shell standing order":
  test "default changes on current facts while effective epoch stays zero":
    var body = bodyFixture()
    var standing: StandingOrderState

    standing.stepFirstLightDefault(body, 1)
    check standing.annotations.len == 1
    check body.installCount == 1

    # An identical consecutive default is still recomputed but writes no
    # annotation and performs no body install.
    standing.stepFirstLightDefault(body, 2)
    check standing.annotations.len == 1
    check body.installCount == 1

    # Zone change: rotate on the same tick.
    body.brSnapshot.ticksToNextShrink = BrRotateLeadTicks
    body.brSnapshot.rotateTarget = some(MapPoint(x: 200, y: 200))
    standing.stepFirstLightDefault(body, 3)

    # Threat change: hold cover on the same tick.
    body.brSnapshot.ticksToNextShrink = BrRotateLeadTicks + 1
    body.brSnapshot.threatPositions = @[MapPoint(x: 300, y: 300)]
    body.brSnapshot.coverGoal = some(body.map.goal(40, 40))
    standing.stepFirstLightDefault(body, 4)

    # Partner change: leash on the same tick.
    body.brSnapshot.threatPositions.setLen(0)
    body.partner.pos = MapPoint(x: 399, y: 399)
    body.brSnapshot.partnerTarget = some(MapPoint(x: 100, y: 100))
    standing.stepFirstLightDefault(body, 5)

    check standing.annotations.len == 4
    check body.installCount == 4
    check standing.effectiveEpoch == 0
    check body.installedEffectiveEpoch == 0
    for annotation in standing.annotations:
      check annotation.kind == akAcceptedIntentChange
      check annotation.effectiveEpoch == 0
      check annotation.provenance.base.kind == pbDefault
      check annotation.provenance.overlays.len == 0
      check annotation.intentBytes == canonicalJson(parseJson(
        annotation.intentBytes))

    check standing.annotations[0].intentBytes ==
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":64," &
      "\"kind\":\"hold\",\"reason\":\"default:hold\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check standing.annotations[1].intentBytes ==
      "{\"arrive_radius\":48.0,\"idle_aim_center_brads\":64," &
      "\"kind\":\"navigate_to\",\"point\":[200,200]," &
      "\"reason\":\"default:rotate\",\"schema\":\"intent\",\"v\":1}"
    check standing.annotations[2].intentBytes ==
      "{\"arrive_radius\":24.0,\"idle_aim_center_brads\":64," &
      "\"kind\":\"navigate_to\",\"point\":[40,40]," &
      "\"reason\":\"default:cover\",\"schema\":\"intent\",\"v\":1}"
    check standing.annotations[3].intentBytes ==
      "{\"arrive_radius\":64.0,\"idle_aim_center_brads\":64," &
      "\"kind\":\"navigate_to\",\"moving_goal\":true," &
      "\"point\":[100,100],\"reason\":\"default:partner\"," &
      "\"schema\":\"intent\",\"v\":1}"

  test "frozen setter carries validated goal and effective epoch":
    var body = activateSeatBody(testBodyMap(), 7)
    let validated = body.map.goal(12, 34)
    let intent = Intent(
      kind: ikNavigateTo,
      point: some(validated.goalPoint.toMapPoint),
      arriveRadius: 8.0)
    setStandingIntent(body, intent, some(validated), 0)
    check body.installedGoal == some(validated)
    check body.installedEffectiveEpoch == 0

    expect AssertionDefect:
      setStandingIntent(body, intent, none(ValidatedGoal), 0)

  test "other frozen placeholder operations preserve their signatures":
    var body = activateSeatBody(testBodyMap(), 9)
    check partnerTelemetry(body).alive == false
    check seatTick(body, BodyTickInputs(input: InputState(right: true)), 11).right
