## Hot-path typed emit validator over canonical_fast.CanonicalReader.
##
## No JsonNode tree is built here. The accepted controller path normalizes
## navigation goals with lane A's real BodyMap.validateGoal proof.

import std/[math, options, strutils]

import ../ctf/sim_types
import abi, body_map, canonical_fast, finisher, policy_encoding, types

type
  EmitClass* = enum
    ecController
    ecOverlay

  DuoSeats* = object
    configured*: bool
    seats*: array[2, SeatRef]

  EmitValidationContext* = object
    map*: BodyMap
    selfPos*: BodyPoint
    emitClass*: EmitClass
    mode*: GameMode
    duoSeats*: array[Team, DuoSeats]

  EmitValidationResult* = object
    code*: int32
    accepted*: bool
    normalized*: bool
    intent*: Intent
    goal*: Option[ValidatedGoal]
    policy*: CombatPolicy
    canonicalBytes*: string
    reason*: string

  EmitValidationError = object of CatchableError
    code: int32

proc raiseCode(code: int32; msg: string) {.noreturn.} =
  var error = newException(EmitValidationError, msg)
  error.code = code
  raise error

proc schema(msg: string) {.noreturn.} = raiseCode(AbiSchemaViolation, msg)
proc rangeViolation(msg: string) {.noreturn.} = raiseCode(AbiRangeViolation, msg)
proc unknown(msg: string) {.noreturn.} = raiseCode(AbiUnknownReference, msg)
proc mismatch(msg: string) {.noreturn.} = raiseCode(AbiClassMismatch, msg)
proc unreachable(msg: string) {.noreturn.} = raiseCode(AbiUnreachableGoal, msg)

proc toBodyPoint(point: MapPoint): BodyPoint {.inline.} =
  (point.x, point.y)

proc toMapPoint(point: BodyPoint): MapPoint {.inline.} =
  MapPoint(x: point.x, y: point.y)

proc readRequiredString(r: var CanonicalReader): string =
  if r.peekKind() != cvString:
    schema("expected string")
  r.readString()

proc readRequiredInt(r: var CanonicalReader): int64 =
  if r.peekKind() != cvInt:
    schema("expected integer")
  r.readInt()

proc readRequiredNumber(r: var CanonicalReader): float =
  case r.peekKind()
  of cvInt, cvFloat: r.readNumber()
  else: schema("expected number")

proc readRequiredBool(r: var CanonicalReader): bool =
  if r.peekKind() != cvBool:
    schema("expected bool")
  r.readBool()

proc parseTeam(value: string): Team =
  for team in Team:
    if ($team).toLowerAscii == value:
      return team
  unknown("unknown team reference")

proc parseDirectSeat(value: string): SeatRef =
  if not value.startsWith("seat:"):
    unknown("unknown seat reference")
  let digits = value[5 .. ^1]
  if digits.len == 0:
    unknown("unknown seat reference")
  var parsed = 0
  for ch in digits:
    if ch notin {'0' .. '9'}:
      unknown("unknown seat reference")
    parsed = parsed * 10 + ord(ch) - ord('0')
    if parsed >= MaxPlayers:
      unknown("unknown seat reference")
  SeatRef(uint8(parsed))

proc addSeatRef(result: var ProtectedSet, value: string,
                ctx: EmitValidationContext) =
  if value.startsWith("seat:"):
    result.seats.add(parseDirectSeat(value))
  elif value.startsWith("duo:"):
    if ctx.mode != gmBr:
      unknown("noDuosInMode")
    let suffix = value[4 .. ^1]
    if suffix.len == 0:
      unknown("unknown team reference")
    let team = parseTeam(suffix)
    if not ctx.duoSeats[team].configured:
      unknown("unknown team reference")
    result.seats.add(ctx.duoSeats[team].seats[0])
    result.seats.add(ctx.duoSeats[team].seats[1])
  else:
    unknown("unknown seat reference")

proc parsePoint(r: var CanonicalReader, map: BodyMap): MapPoint =
  r.enterArray()
  if not r.nextElement(): schema("point needs x")
  let x = r.readRequiredInt()
  if not r.nextElement(): schema("point needs y")
  let y = r.readRequiredInt()
  if r.nextElement(): schema("point has too many coordinates")
  if x < 0 or y < 0 or x > int64(high(int32)) or y > int64(high(int32)):
    rangeViolation("point outside int32 range")
  result = MapPoint(x: int(x), y: int(y))
  if map != nil and (result.x >= map.width or result.y >= map.height):
    rangeViolation("point outside map")

proc parseProtectedSet(r: var CanonicalReader,
                       ctx: EmitValidationContext): ProtectedSet =
  r.enterObject()
  var key: string
  while r.nextKey(key):
    case key
    of "seats":
      r.enterArray()
      while r.nextElement():
        result.addSeatRef(r.readRequiredString(), ctx)
    of "teams":
      r.enterArray()
      while r.nextElement():
        result.teams.incl(parseTeam(r.readRequiredString()))
    else:
      schema("unknown protected-set field")

proc parsePreferTag(value: string): PreferTag =
  case value
  of "weakened": ptWeakened
  of "isolated": ptIsolated
  of "revenge": ptRevenge
  of "bounty": ptBounty
  else: schema("unknown prefer tag")

proc parseMicroFlag(value: string): MicroFlag =
  case value
  of "formation_bias": mfFormationBias
  of "peek_duck": mfPeekDuck
  of "separation": mfSeparation
  of "steal_rush_exempt": mfStealRushExempt
  else: schema("unknown micro flag")

proc parseCombatPolicy(r: var CanonicalReader,
                       ctx: EmitValidationContext): CombatPolicy =
  var schemaName = ""
  var version = -1'i64
  r.enterObject()
  var key: string
  while r.nextKey(key):
    case key
    of "hold_fire":
      result.holdFire = r.readRequiredBool()
    of "no_shoot":
      result.noShoot = r.parseProtectedSet(ctx)
    of "prefer":
      var seen: set[PreferTag]
      r.enterArray()
      while r.nextElement():
        if result.prefer.len >= ord(high(PreferTag)) + 1:
          rangeViolation("too many preference tags")
        let tag = parsePreferTag(r.readRequiredString())
        if tag in seen:
          schema("duplicate preference tag")
        seen.incl(tag)
        result.prefer.add(tag)
    of "protect":
      result.protect = r.parseProtectedSet(ctx)
    of "schema":
      schemaName = r.readRequiredString()
    of "v":
      version = r.readRequiredInt()
    else:
      schema("unknown combat policy field")
  if schemaName != "combat_policy":
    schema("wrong combat policy schema")
  if version != 1:
    schema("wrong combat policy version")

proc parseKind(value: string): IntentKind =
  case value
  of "navigate_to": ikNavigateTo
  of "hold": ikHold
  else: schema("unknown intent kind")

proc parseProfile(value: string): CostProfile =
  case value
  of "default": cpDefault
  of "carrier": cpCarrier
  of "hunter": cpHunter
  else: schema("unknown cost profile")

proc parseIntent(r: var CanonicalReader, ctx: EmitValidationContext): Intent =
  var
    schemaName = ""
    version = -1'i64
    hasKind = false
    hasArrive = false
  r.enterObject()
  var key: string
  while r.nextKey(key):
    case key
    of "arrive_radius":
      result.arriveRadius = r.readRequiredNumber()
      hasArrive = true
    of "clamp_to_endzone":
      result.clampToEndzone = r.readRequiredBool()
    of "combat":
      result.combat = r.parseCombatPolicy(ctx)
    of "idle_aim_center_brads":
      let value = r.readRequiredInt()
      if value < 0 or value > 255:
        rangeViolation("idle aim outside 0..255")
      result.idleAimCenterBrads = some(int(value))
    of "kind":
      result.kind = parseKind(r.readRequiredString())
      hasKind = true
    of "micro":
      r.enterArray()
      while r.nextElement():
        result.micro.incl(parseMicroFlag(r.readRequiredString()))
    of "moving_goal":
      result.movingGoal = r.readRequiredBool()
    of "point":
      result.point = some(r.parsePoint(ctx.map))
    of "profile":
      result.profile = parseProfile(r.readRequiredString())
    of "reason":
      result.reason = r.readRequiredString()
      if result.reason.len > IntentReasonMaxBytes:
        rangeViolation("reason too large")
    of "schema":
      schemaName = r.readRequiredString()
    of "suppress_fire_freeze":
      result.suppressFireFreeze = r.readRequiredBool()
    of "v":
      version = r.readRequiredInt()
    else:
      schema("unknown intent field")
  if schemaName != "intent":
    schema("wrong intent schema")
  if version != 1 or not hasKind or not hasArrive:
    schema("missing required intent field")
  if result.arriveRadius.classify in {fcNan, fcInf, fcNegInf} or
      result.arriveRadius < 0:
    rangeViolation("arrival radius out of range")
  if ctx.map != nil:
    let diagonal = hypot(ctx.map.width.float, ctx.map.height.float)
    if result.arriveRadius > diagonal:
      rangeViolation("arrival radius exceeds map diagonal")
  if (result.kind == ikNavigateTo) != result.point.isSome:
    schema("point presence does not match intent kind")

proc writeCombatPolicy(w: var CanonicalWriter, value: CombatPolicy) =
  w.beginObject()
  if value.holdFire:
    w.field("hold_fire", true)
  if not value.noShoot.protectedSetEmpty:
    w.key("no_shoot")
    w.writeProtectedSet(value.noShoot)
  if value.prefer.len > 0:
    w.key("prefer")
    w.beginArray()
    for tag in value.prefer:
      case tag
      of ptWeakened: w.addString("weakened")
      of ptIsolated: w.addString("isolated")
      of ptRevenge: w.addString("revenge")
      of ptBounty: w.addString("bounty")
    w.endArray()
  if not value.protect.protectedSetEmpty:
    w.key("protect")
    w.writeProtectedSet(value.protect)
  w.field("schema", "combat_policy")
  w.field("v", 1'i64)
  w.endObject()

proc canonicalCombatPolicy*(policy: CombatPolicy): string =
  var writer = initCanonicalWriter(256)
  writer.writeCombatPolicy(policy)
  writer.take()

proc validateEmit*(bytes: sink string,
                   ctx: EmitValidationContext): EmitValidationResult =
  if bytes.len > MaxEmitBytes:
    return EmitValidationResult(code: AbiTooLarge)
  try:
    var schemaProbe = initCanonicalReader(bytes)
    var key, schemaName: string
    schemaProbe.enterObject()
    while schemaProbe.nextKey(key):
      if key == "schema":
        schemaName = schemaProbe.readRequiredString()
      else:
        schemaProbe.skipValue()
    schemaProbe.finish()
    if ctx.emitClass == ecController and schemaName == "combat_policy":
      mismatch("controller emitted combat policy")
    if ctx.emitClass == ecOverlay and schemaName == "intent":
      mismatch("overlay emitted intent")

    var reader = initCanonicalReader(bytes)
    case ctx.emitClass
    of ecController:
      result.intent = reader.parseIntent(ctx)
      reader.finish()
      var accepted = result.intent
      if accepted.kind == ikNavigateTo:
        let requested = accepted.point.get.toBodyPoint
        if ctx.map == nil:
          unreachable("navigation goal has no map")
        let validated = ctx.map.validateGoal(requested, ctx.selfPos)
        if validated.isNone:
          unreachable("navigation goal unreachable")
        let resolved = validated.get.goalPoint.toMapPoint
        result.normalized = resolved != accepted.point.get
        accepted.point = some(resolved)
        result.goal = some(validated.get)
      result.intent = accepted
      result.canonicalBytes = canonicalIntent(accepted)
      result.accepted = true
      result.code = if result.normalized: AbiNormalized else: AbiOk
    of ecOverlay:
      result.policy = reader.parseCombatPolicy(ctx)
      reader.finish()
      result.canonicalBytes = canonicalCombatPolicy(result.policy)
      result.accepted = true
      result.code = AbiOk
  except EmitValidationError as error:
    result.code = error.code
    result.reason = error.msg
  except CanonicalError:
    result.code = AbiSchemaViolation
