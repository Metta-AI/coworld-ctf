## Phase P3-1/P3-FL: standing-order default install bound to lane A FL-B body.

import std/[json, options, unittest]
import bitworld/spriteprotocol
import ../src/ctf/sim_types
import ../src/shell/[body, body_map, canonical, default_play,
  standing_order, types]

proc testBodyMap(): BodyMap =
  const Side = 512
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(10, 10)])

proc goal(map: BodyMap, x, y: int): ValidatedGoal =
  map.validateGoal((x, y), (10, 10)).get

proc inputs(self = (10, 10), partner = (20, 20), tick = 1'u32,
            threats: seq[BodyPoint] = @[]): BodyTickInputs =
  result.self = BodySelfState(pos: self, hpFrac: 1.0, aimBrads: 32,
    alive: true, carrying: false)
  result.partner = some(PartnerSample(seat: 4, pos: partner,
    aimBrads: 32, alive: true))
  for index, threat in threats:
    result.visibleTracks.add(BodyTrackUpdate(seat: index + 10,
      pos: threat, team: Blue, aimBrads: 0, hpKnown: some(3), tick: tick))

proc fallback(map: BodyMap): BrDefaultFallbacks =
  BrDefaultFallbacks(
    currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
    nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zoneDps: 1,
    idleAimCenterBrads: 64,
    coverGoal: none(ValidatedGoal))

proc bodyFixture(): SeatBody =
  result = activateSeatBody(testBodyMap(), 3, 331)
  result.updateBelief(inputs(), 1)

suite "shell standing order":
  test "default changes on current facts while effective epoch stays zero":
    let body = bodyFixture()
    var standing: StandingOrderState
    var facts = fallback(body.map)

    standing.stepFirstLightDefault(body, 1, facts)
    check standing.annotations.len == 1

    # An identical consecutive default is still recomputed but writes no
    # annotation and performs no body install.
    standing.stepFirstLightDefault(body, 2, facts)
    check standing.annotations.len == 1

    # Zone change: rotate on the same tick.
    facts.ticksToNextShrink = BrRotateLeadTicks
    facts.rotateTarget = some((200, 200))
    standing.stepFirstLightDefault(body, 3, facts)

    # Threat change: hold cover on the same tick.
    facts.ticksToNextShrink = BrRotateLeadTicks + 1
    facts.rotateTarget = none(BodyPoint)
    facts.coverGoal = some(body.map.goal(40, 40))
    body.updateBelief(inputs(tick = 4'u32, threats = @[(300, 300)]), 4)
    standing.stepFirstLightDefault(body, 4, facts)

    # Partner change: leash on the same tick.
    facts.coverGoal = none(ValidatedGoal)
    body.updateBelief(inputs(partner = (399, 399)), 5)
    standing.stepFirstLightDefault(body, 5, facts)

    check standing.annotations.len == 4
    check standing.effectiveEpoch == 0
    check body.effectiveEpoch == 0
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
      "\"point\":[399,399],\"reason\":\"default:partner\"," &
      "\"schema\":\"intent\",\"v\":1}"

  test "frozen setter carries validated goal and effective epoch":
    let body = activateSeatBody(testBodyMap(), 7, 331)
    let validated = body.map.goal(12, 34)
    let intent = Intent(
      kind: ikNavigateTo,
      point: some(validated.goalPoint.toMapPoint),
      arriveRadius: 8.0)
    setStandingIntent(body, intent, some(validated), 0)
    check body.standingGoal == some(validated)
    check body.effectiveEpoch == 0

    expect ValueError:
      setStandingIntent(body, intent, none(ValidatedGoal), 0)

  test "lane A body operations preserve their final signatures":
    let body = activateSeatBody(testBodyMap(), 9, 331)
    check partnerTelemetry(body).isNone
    let input = body.seatTick(BodyTickInputs(
      self: BodySelfState(pos: (10, 10), hpFrac: 1.0, aimBrads: 0,
        alive: true, carrying: false)), 11)
    check input.encodeInputMask() == 0
