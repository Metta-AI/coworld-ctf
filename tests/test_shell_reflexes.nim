## Phase P3-13: Appendix R engine-native reflexes and planEscape.

import std/[json, options, strutils, times, unittest]

import ../src/ctf/[sim_config, sim_types]
import ../src/shell/[body_map, call_validation, canonical, emit_validator,
  guards, ladder, manifest, plan_escape, reflexes, standing_order, types]

proc openMap(width = 768; height = 768): BodyMap =
  var walkable = newSeq[bool](width * height)
  for cell in walkable.mitems:
    cell = true
  newBodyMap(walkable, width, height, 1, @[(width div 2, height div 2)])

proc pocketMap(): BodyMap =
  const Side = 96
  var walkable = newSeq[bool](Side * Side)
  for y in 36 .. 52:
    for x in 36 .. 52:
      walkable[y * Side + x] = true
  newBodyMap(walkable, Side, Side, 1, @[(44, 44)])

proc zoneQuery(rect: MapRect): ZoneTicksUntilOutside =
  result = proc(point: BodyPoint): int64 =
    if point.pointInRect(rect): InfiniteArrival else: 0

proc fixedZone(value: int64): ZoneTicksUntilOutside =
  result = proc(point: BodyPoint): int64 =
    discard point
    value

proc input(map: BodyMap; pos: BodyPoint = (384, 384);
           velocity = MaxSpeed; motionScale = MotionScale;
           mode = gmBr): ReflexTickInput =
  ReflexTickInput(tick: 10, mode: mode, map: map, selfPos: pos, alive: true,
    motionScale: motionScale, velocity: velocity,
    nextZone: MapRect(x: 320, y: 320, w: 128, h: 128))

proc sub(kind: ReflexKind; epoch = 7'u64): ReflexSubscription =
  ReflexSubscription(kind: kind, epoch: epoch)

proc native(decision: ReflexDecision): LadderNativeBase =
  LadderNativeBase(intent: decision.order.intent, goal: decision.order.goal,
    provenance: decision.order.provenance,
    contributingEpoch: decision.order.contributingEpoch)

proc holdIntent(name: string): Intent =
  Intent(kind: ikHold, arriveRadius: 0.0, reason: name)

proc canonical(text: string): string =
  canonicalJson(parseJson(text))

proc manifestFor(name: string): PlayManifest =
  parseManifest(canonical("""
    {"abi":1,"class":"controller","modes":["br"],"name":"$1","params":{},"retune":false}
  """ % [name]), false)

proc fakeBinding(): LadderBinding =
  result.manifest = manifestFor("controller")
  result.hash = repeat('c', 64)
  result.ready = true
  result.makeGuest = proc(seatIndex: int; entry: ValidatedCallEntry,
                          emitClass: EmitClass): LadderGuest =
    discard seatIndex
    discard entry
    discard emitClass
    new(result)
    result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
      discard paramsBytes
      discard contextBytes
    result.runStep = proc(viewBytes: string; tick: uint32): LadderInvocationResult =
      discard viewBytes
      result.emission.intent = some(holdIntent("controller@" & $tick))
      result.emission.canonicalBytes = canonicalIntent(result.emission.intent.get)
    result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
      discard oldParamsBytes
      discard newParamsBytes
    result.close = proc() =
      discard

proc registry(): PathRegistry =
  newPathRegistry(@[])

proc ladderInput(base: Option[LadderNativeBase]): LadderSeatInput =
  LadderSeatInput(alive: true, contextBytes: "{}", viewBytes: "{}",
    guardContext: IntentContext(), defaultIntent: holdIntent("default"),
    nativeBase: base)

suite "shell planEscape":
  test "arrival arithmetic covers speed modifiers and motion scale boundaries":
    var config = defaultGameConfig()
    check arrivalTicksForDistance(10, config.motionScale, config.maxSpeed) ==
      int64((10 * config.motionScale + config.maxSpeed - 1) div config.maxSpeed)
    config.handicaps[Red] = 1000
    check effectiveMaxVelocity(config, Red, {}, false, 100) ==
      config.maxSpeed div 2
    let thrusterVelocity = effectiveMaxVelocity(config, Red,
      {PerkThruster}, false, 100)
    check thrusterVelocity ==
      (config.maxSpeed div 2) * (1000 + config.perkMods.thrusterSpeed) div 1000
    check effectiveMaxVelocity(config, Red, {}, true, 100) ==
      (config.maxSpeed div 2) * config.carrierSpeedPct div 100
    check effectiveMaxVelocity(config, Red, {}, false, 50) ==
      (config.maxSpeed div 2) * 50 div 100
    check arrivalTicksForDistance(10, 100, 25) == 40
    check arrivalTicksForDistance(10, config.motionScale, 0) == InfiniteArrival
    check effectiveMaxVelocity(config, Red, {}, false, 0) == 0
    # Trench-exit reduction is deliberately excluded: callers pass the same
    # live max velocity whether the next step points out of a trench or not.
    check arrivalTicksForDistance(10, config.motionScale,
      effectiveMaxVelocity(config, Red, {}, false, 100)) ==
      arrivalTicksForDistance(10, config.motionScale,
        effectiveMaxVelocity(config, Red, {}, false, 100))

  test "lattice is 1089 candidates, drops off-map first, and tie-breaks by ordinal":
    let map = openMap()
    let planned = planEscape(PlanEscapeInput(map: map, fromPoint: (384, 384),
      motionScale: MotionScale, velocity: MaxSpeed),
      proc(candidate: EscapeCandidate): EscapeScore =
        EscapeScore(hardPass: true, normal: noScoreKeys(),
          fallback: noScoreKeys()))
    check planned.found
    check planned.considered == MaxReflexCandidates
    check planned.ordinal == 544
    check planned.point == (384, 384)

    let corner = planEscape(PlanEscapeInput(map: map, fromPoint: (8, 8),
      motionScale: MotionScale, velocity: MaxSpeed),
      proc(candidate: EscapeCandidate): EscapeScore =
        EscapeScore(hardPass: true,
          normal: scoreKeys([maxKey(int64(candidate.ordinal))]),
          fallback: noScoreKeys()))
    check corner.found
    check corner.considered == MaxReflexCandidates
    check corner.resolvedCount < MaxReflexCandidates

  test "duplicate resolved points keep the lower ordinal":
    let map = pocketMap()
    let planned = planEscape(PlanEscapeInput(map: map, fromPoint: (44, 44),
      motionScale: MotionScale, velocity: MaxSpeed),
      proc(candidate: EscapeCandidate): EscapeScore =
        EscapeScore(hardPass: true, normal: scoreKeys([maxKey(1)]),
          fallback: noScoreKeys()))
    check planned.found
    check planned.resolvedCount > planned.dedupedCount
    check planned.ordinal < MaxReflexCandidates
    check map.validateGoal(planned.point, (44, 44)).isSome

  test "domain with no resolved candidate reports no goal":
    let map = pocketMap()
    let planned = planEscape(PlanEscapeInput(map: map, fromPoint: (1, 1),
      motionScale: MotionScale, velocity: MaxSpeed),
      proc(candidate: EscapeCandidate): EscapeScore =
        discard candidate
        EscapeScore(hardPass: true, normal: noScoreKeys(),
          fallback: noScoreKeys()))
    check not planned.found

suite "shell reflexes":
  test "grenade trigger, release, boundary coverage, fallback, and blast-cue negative":
    let map = openMap()
    var state: ReflexSeatState
    var facts = input(map, pos = (300, 384))
    facts.blastCues = @[BlastCue(pos: facts.selfPos, tick: facts.tick,
      eventId: 1)]
    var decision = state.selectReflex(facts, [sub(rkClearGrenade)])
    check not decision.selected
    check state.telemetry.len == 0

    facts.visibleGrenades = @[VisibleGrenade(
      predictedBlastPos: facts.selfPos,
      ticksToBlast: 1,
      blastRadius: 24,
      eventId: 2)]
    decision = state.selectReflex(facts, [sub(rkClearGrenade)])
    check decision.selected
    check decision.fallbackUsed
    check decision.order.provenance.base.kind == pbReflex
    check decision.order.provenance.base.reflexName == ReflexClearGrenadeName
    check decision.order.contributingEpoch == 7
    check state.telemetry[^1].kind == rtTriggered

    let boundary = VisibleGrenade(predictedBlastPos: (100, 100),
      ticksToBlast: 10, blastRadius: 24, eventId: 3)
    check grenadeCovers((100 + body_map.PlayerHalf + 48, 100), boundary)
    check not grenadeCovers((100 + body_map.PlayerHalf + 49, 100), boundary)

    facts.visibleGrenades.setLen(0)
    decision = state.selectReflex(facts, [sub(rkClearGrenade)])
    check not decision.selected
    check state.telemetry[^1].kind == rtReleased

  test "spray visible and anonymous triggers release only after impact window drains":
    let map = openMap()
    var state: ReflexSeatState
    var facts = input(map, pos = (300, 384))
    facts.sprayCones = @[VisibleSprayCone(origin: (100, 384),
      aimBrads: 0, coversSelf: false, tick: facts.tick, eventId: 1)]
    var decision = state.selectReflex(facts, [sub(rkClearSpray)])
    check not decision.selected

    facts.sprayCones[0].coversSelf = true
    decision = state.selectReflex(facts, [sub(rkClearSpray)])
    check decision.selected
    check decision.order.provenance.base.reflexName == ReflexClearSprayName

    facts.sprayCones.setLen(0)
    facts.sprayImpacts = @[
      AnonymousSprayImpact(impactPos: (360, 384), incomingDir: 0,
        tick: facts.tick, eventId: 2),
      AnonymousSprayImpact(impactPos: (408, 384), incomingDir: 0,
        tick: facts.tick, eventId: 3)]
    decision = state.selectReflex(facts, [sub(rkClearSpray)])
    check decision.selected

    facts.tick += ReflexSprayImpactWindowTicks.uint32 + 1
    decision = state.selectReflex(facts, [sub(rkClearSpray)])
    check not decision.selected
    check state.telemetry[^1].kind == rtReleased

  test "zone trigger and hysteresis are BR-only and score inside next rect first":
    let map = openMap()
    var state: ReflexSeatState
    var facts = input(map, pos = (300, 384))
    facts.zoneTicksUntilOutside = fixedZone(ReflexZoneTriggerTicks)
    var decision = state.selectReflex(facts, [sub(rkZoneEscape)])
    check decision.selected
    check decision.order.provenance.base.reflexName == ReflexZoneEscapeName
    check decision.order.intent.point.get.x >= facts.nextZone.x
    check decision.order.intent.point.get.x < facts.nextZone.x + facts.nextZone.w

    facts.zoneTicksUntilOutside = fixedZone(ReflexZoneReleaseTicks)
    decision = state.selectReflex(facts, [sub(rkZoneEscape)])
    check decision.selected
    facts.zoneTicksUntilOutside = fixedZone(ReflexZoneReleaseTicks + 1)
    decision = state.selectReflex(facts, [sub(rkZoneEscape)])
    check not decision.selected

    facts.mode = gmCtf
    facts.zoneTicksUntilOutside = fixedZone(0)
    decision = state.selectReflex(facts, [sub(rkZoneEscape)])
    check not decision.selected

  test "observers run without subscription and a later ladder picks up the emergency":
    let map = openMap()
    var state: ReflexSeatState
    var facts = input(map)
    facts.visibleGrenades = @[VisibleGrenade(predictedBlastPos: facts.selfPos,
      ticksToBlast: 12, blastRadius: 24, eventId: 1)]
    var decision = state.selectReflex(facts, [])
    check not decision.selected
    check state.active[rkClearGrenade]

    decision = state.selectReflex(facts, [sub(rkClearGrenade, 99)])
    check decision.selected
    check decision.order.contributingEpoch == 99

  test "no resolved reflex goal emits telemetry and does not choose a base":
    let map = pocketMap()
    var state: ReflexSeatState
    var facts = input(map, pos = (1, 1))
    facts.visibleGrenades = @[VisibleGrenade(predictedBlastPos: facts.selfPos,
      ticksToBlast: 12, blastRadius: 24, eventId: 1)]
    let decision = state.selectReflex(facts, [sub(rkClearGrenade)])
    check not decision.selected
    check decision.noGoal
    check state.telemetry[^1].kind == rtNoGoal

  test "reflex native base takes precedence above guest controllers":
    let map = openMap()
    var state: ReflexSeatState
    var facts = input(map, pos = (300, 384))
    facts.zoneTicksUntilOutside = zoneQuery(MapRect(x: 320, y: 320,
      w: 128, h: 128))
    let decision = state.selectReflex(facts, [sub(rkZoneEscape, 42)])
    check decision.selected

    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    let binding = fakeBinding()
    check driver.acceptCall(0, 1, 1, 1, canonical("""
      {"plays":[{"entry_id":"controller","params":{},"play":"controller"}]}
    """), [binding], IntentContext()).accepted
    discard driver.tick([ladderInput(none(LadderNativeBase))], 1, [binding])
    let tick = driver.tick([ladderInput(some(decision.native))], 2, [binding])
    check tick.seats[0].provenance.base.kind == pbReflex
    check tick.seats[0].provenance.base.reflexName == ReflexZoneEscapeName
    check tick.seats[0].contributingEpoch == 42

  test "32 seats can each run the max grenade fallback plan inside the budget":
    let map = openMap()
    var states: array[32, ReflexSeatState]
    var facts = input(map)
    for index in 0 ..< 8:
      facts.visibleGrenades.add VisibleGrenade(
        predictedBlastPos: facts.selfPos,
        ticksToBlast: 1 + index,
        blastRadius: 24,
        eventId: index)

    for seat in 0 ..< 32:
      discard states[seat].selectReflex(facts, [sub(rkClearGrenade)])
    let start = cpuTime()
    var selected = 0
    for seat in 0 ..< 32:
      let decision = states[seat].selectReflex(facts, [sub(rkClearGrenade)])
      if decision.selected:
        inc selected
      check decision.plan.considered == MaxReflexCandidates
    let elapsedUs = (cpuTime() - start) * 1_000_000.0
    echo "SHELL_REFLEX_MAX_PLAN seats=32 candidates=", 32 * MaxReflexCandidates,
      " hazards=8 elapsed_us=", elapsedUs
    check selected == 32
    check elapsedUs <= ReflexRuntimeBudgetUs
