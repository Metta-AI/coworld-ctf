## Phase P3-1: the engine-native Battle Royale fallback and finisher.

import std/[algorithm, json, options, os, random, strutils, unittest]
import ../src/ctf/sim_types
import ../src/shell/[body_map, canonical, canonical_fast, default_play,
  finisher, types]

proc testBodyMap(): BodyMap =
  const Side = 512
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(10, 10)])

proc goal(map: BodyMap, x, y: int): ValidatedGoal =
  map.validateGoal((x, y), (10, 10)).get

proc baseFacts(): BrDefaultFacts =
  let map = testBodyMap()
  BrDefaultFacts(
    tick: 10,
    map: map,
    selfPos: (10, 10),
    currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
    nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zoneDps: 1,
    idleAimCenterBrads: 64,
    partner: some((seat: 1'u8, team: Red, pos: (20, 20), aimBrads: 32,
      alive: true, downed: false)),
    rotateTarget: (150, 150))

proc wireName(kind: IntentKind): string =
  if kind == ikNavigateTo: "navigate_to" else: "hold"

proc wireName(profile: CostProfile): string =
  case profile
  of cpDefault: "default"
  of cpCarrier: "carrier"
  of cpHunter: "hunter"

proc wireName(flag: MicroFlag): string =
  case flag
  of mfPeekDuck: "peek_duck"
  of mfSeparation: "separation"
  of mfFormationBias: "formation_bias"
  of mfStealRushExempt: "steal_rush_exempt"

proc wireName(tag: PreferTag): string =
  case tag
  of ptWeakened: "weakened"
  of ptIsolated: "isolated"
  of ptRevenge: "revenge"
  of ptBounty: "bounty"

proc protectedNode(value: ProtectedSet): JsonNode =
  result = newJObject()
  if value.seats.len > 0:
    var seats: seq[string]
    for seat in value.seats:
      seats.add($seat)
    seats.sort()
    var unique = newJArray()
    for index, seat in seats:
      if index == 0 or seat != seats[index - 1]:
        unique.add(%seat)
    result["seats"] = unique
  if value.teams.card > 0:
    var teams: seq[string]
    for team in value.teams:
      teams.add(($team).toLowerAscii)
    teams.sort()
    result["teams"] = %teams

proc combatNode(value: CombatPolicy): JsonNode =
  result = newJObject()
  if value.holdFire:
    result["hold_fire"] = %true
  if value.noShoot.teams.card > 0 or value.noShoot.seats.len > 0:
    result["no_shoot"] = protectedNode(value.noShoot)
  if value.prefer.len > 0:
    var prefer = newJArray()
    for tag in value.prefer:
      prefer.add(%tag.wireName)
    result["prefer"] = prefer
  if value.protect.teams.card > 0 or value.protect.seats.len > 0:
    result["protect"] = protectedNode(value.protect)
  result["schema"] = %"combat_policy"
  result["v"] = %1

proc combatEmpty(value: CombatPolicy): bool =
  value.noShoot.teams.card == 0 and value.noShoot.seats.len == 0 and
    value.protect.teams.card == 0 and value.protect.seats.len == 0 and
    value.prefer.len == 0 and not value.holdFire

proc intentNode(intent: Intent): JsonNode =
  result = newJObject()
  result["arrive_radius"] = %intent.arriveRadius
  if intent.clampToEndzone:
    result["clamp_to_endzone"] = %true
  if not intent.combat.combatEmpty:
    result["combat"] = combatNode(intent.combat)
  if intent.idleAimCenterBrads.isSome:
    result["idle_aim_center_brads"] = %intent.idleAimCenterBrads.get
  result["kind"] = %intent.kind.wireName
  if intent.micro.card > 0:
    var micro = newJArray()
    for flag in [mfFormationBias, mfPeekDuck, mfSeparation,
                 mfStealRushExempt]:
      if flag in intent.micro:
        micro.add(%flag.wireName)
    result["micro"] = micro
  if intent.movingGoal:
    result["moving_goal"] = %true
  if intent.point.isSome:
    result["point"] = %*[intent.point.get.x, intent.point.get.y]
  if intent.profile != cpDefault:
    result["profile"] = %intent.profile.wireName
  if intent.reason.len > 0:
    result["reason"] = %intent.reason
  result["schema"] = %"intent"
  if intent.suppressFireFreeze:
    result["suppress_fire_freeze"] = %true
  result["v"] = %1

proc randomReason(rng: var Rand, length: int): string =
  const Alphabet = "azAZ09:\"\\\n_-"
  result = newStringOfCap(length)
  for _ in 0 ..< length:
    result.add(Alphabet[rng.rand(Alphabet.high)])

proc randomizedIntent(rng: var Rand, index: int): Intent =
  let navigate = (index and 1) == 1
  result.kind = if navigate: ikNavigateTo else: ikHold
  if navigate:
    result.point = some(MapPoint(
      x: rng.rand(-2048 .. 4096), y: rng.rand(-2048 .. 4096)))
  result.arriveRadius = [0.0, 1.0, 24.0, 4096.5][index mod 4]
  result.movingGoal = rng.rand(1) == 1
  result.profile = CostProfile(rng.rand(ord(high(CostProfile))))
  for flag in MicroFlag:
    if (index and (1 shl (ord(flag) + 1))) != 0:
      result.micro.incl(flag)
  if index mod 3 != 0:
    result.idleAimCenterBrads = some(if index mod 7 == 0: 255 else: rng.rand(255))
  result.clampToEndzone = rng.rand(1) == 1
  result.suppressFireFreeze = rng.rand(1) == 1
  let reasonLength = [0, 1, IntentReasonMaxBytes][index mod 3]
  result.reason = rng.randomReason(reasonLength)

  # Every fourth row is the exact neutral policy; the others cover all
  # policy options, enum values, set shapes, order preservation, and duplicate
  # seat references (which canonical set encoding removes).
  if index mod 4 != 0:
    result.combat.holdFire = rng.rand(1) == 1
    for team in Team:
      if rng.rand(3) == 0:
        result.combat.noShoot.teams.incl(team)
      if rng.rand(4) == 0:
        result.combat.protect.teams.incl(team)
    for _ in 0 ..< rng.rand(0 .. 8):
      result.combat.noShoot.seats.add(SeatRef(uint8(rng.rand(MaxPlayers - 1))))
    for _ in 0 ..< rng.rand(0 .. 8):
      result.combat.protect.seats.add(SeatRef(uint8(rng.rand(MaxPlayers - 1))))
    let preferCount = rng.rand(ord(high(PreferTag)) + 1)
    let firstTag = rng.rand(ord(high(PreferTag)))
    for offset in 0 ..< preferCount:
      result.combat.prefer.add(PreferTag(
        (firstTag + offset) mod (ord(high(PreferTag)) + 1)))

suite "shell default play":
  test "proposed BR rule priority is rotate, partner, cover, hold":
    var facts = baseFacts()
    facts.rotateTarget = (200, 200)
    facts.coverGoal = some(facts.map.goal(40, 40))
    facts.threatPositions = @[(300, 300)]
    facts.partner = some((seat: 1'u8, team: Red, pos: (399, 399),
      aimBrads: 32, alive: true, downed: false))
    facts.ticksToNextShrink = BrRotateLeadTicks

    let rotate = computeBrDefault(facts)
    check rotate.rule == brRotate
    check rotate.intent.point == some(MapPoint(x: 200, y: 200))
    check rotate.goal.isSome

    facts.ticksToNextShrink = BrRotateLeadTicks + 1
    let partner = computeBrDefault(facts)
    check partner.rule == brPartnerLeash
    check partner.intent.point == some(MapPoint(x: 399, y: 399))

    facts.partner = some((seat: 1'u8, team: Red, pos: (20, 20),
      aimBrads: 32, alive: true, downed: false))
    let cover = computeBrDefault(facts)
    check cover.rule == brCoverHold
    check cover.intent.point == some(MapPoint(x: 40, y: 40))

    facts.threatPositions.setLen(0)
    let hold = computeBrDefault(facts)
    check hold.rule == brHold
    check hold.intent.kind == ikHold
    check hold.intent.point.isNone
    check hold.goal.isNone

  test "finisher stamps idle aim and stable pbDefault provenance":
    let finished = finishDefault(computeBrDefault(baseFacts()).intent, 64)
    check finished.intent.idleAimCenterBrads == some(64)
    check finished.provenance.base.kind == pbDefault
    check finished.provenance.overlays.len == 0

    var alreadyStamped = finished.intent
    alreadyStamped.idleAimCenterBrads = some(7)
    check finishDefault(alreadyStamped, 64).intent.idleAimCenterBrads == some(7)

  test "CanonicalWriter default bytes are exact and match canonical.nim":
    let finished = finishDefault(computeBrDefault(baseFacts()).intent, 64)
    let fast = canonicalIntent(finished.intent)
    const Golden =
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":64," &
      "\"kind\":\"hold\",\"reason\":\"default:hold\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check fast == Golden
    check fast == canonicalJson(parseJson(Golden))

  test "CanonicalWriter matches the complete contract golden and canonical.nim":
    let intent = Intent(
      kind: ikNavigateTo,
      point: some(MapPoint(x: 512, y: 288)),
      arriveRadius: 24.0,
      movingGoal: true,
      profile: cpHunter,
      micro: {mfPeekDuck, mfSeparation},
      idleAimCenterBrads: some(128),
      reason: "edge_ride:margin",
      combat: CombatPolicy(
        noShoot: ProtectedSet(
          teams: {Navy},
          seats: @[SeatRef(5), SeatRef(4), SeatRef(5)]),
        protect: ProtectedSet(seats: @[SeatRef(4)]),
        prefer: @[ptWeakened, ptRevenge],
        holdFire: true))
    let golden = readFile(currentSourcePath.parentDir /
      "fixtures/shell/intent.golden.json").strip
    let fast = canonicalIntent(intent)
    check fast == golden
    check fast == canonicalJson(parseJson(golden))

  test "seeded randomized CanonicalWriter bytes match canonical.nim":
    var rng = initRand(0x51E2C0DE)
    var
      seenKinds: set[IntentKind]
      seenProfiles: set[CostProfile]
      seenMicro: array[16, bool]
      seenReasonLengths: array[IntentReasonMaxBytes + 1, bool]
      seenTeams: set[Team]
      seenPrefer: set[PreferTag]
      sawIdleAbsent, sawIdlePresent: bool
      sawCombatEmpty, sawCombatNonEmpty: bool
    for index in 0 ..< 1024:
      let intent = rng.randomizedIntent(index)
      seenKinds.incl(intent.kind)
      seenProfiles.incl(intent.profile)
      var microMask = 0
      for flag in intent.micro:
        microMask = microMask or (1 shl ord(flag))
      seenMicro[microMask] = true
      seenReasonLengths[intent.reason.len] = true
      sawIdleAbsent = sawIdleAbsent or intent.idleAimCenterBrads.isNone
      sawIdlePresent = sawIdlePresent or intent.idleAimCenterBrads.isSome
      sawCombatEmpty = sawCombatEmpty or intent.combat.combatEmpty
      sawCombatNonEmpty = sawCombatNonEmpty or not intent.combat.combatEmpty
      seenTeams = seenTeams + intent.combat.noShoot.teams +
        intent.combat.protect.teams
      for tag in intent.combat.prefer:
        seenPrefer.incl(tag)
      var writer = initCanonicalWriter(256)
      writer.writeIntent(intent)
      let fast = writer.take()
      check fast == canonicalJson(intent.intentNode)
      check fast == canonicalIntent(intent)
    check seenKinds == {ikNavigateTo, ikHold}
    check seenProfiles == {cpDefault, cpCarrier, cpHunter}
    for covered in seenMicro:
      check covered
    check seenReasonLengths[0]
    check seenReasonLengths[1]
    check seenReasonLengths[IntentReasonMaxBytes]
    check sawIdleAbsent and sawIdlePresent
    check sawCombatEmpty and sawCombatNonEmpty
    check seenTeams == {low(Team) .. high(Team)}
    check seenPrefer == {ptWeakened, ptIsolated, ptRevenge, ptBounty}
