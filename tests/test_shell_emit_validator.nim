## Typed hot-path validation for guest emissions.

import std/[monotimes, options, strutils, times, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, body_map, emit_validator, finisher, types]

proc openRoomsMap(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc controllerContext(map: BodyMap): EmitValidationContext =
  EmitValidationContext(map: map, selfPos: (30, 30), emitClass: ecController)

proc overlayContext(map: BodyMap): EmitValidationContext =
  EmitValidationContext(map: map, selfPos: (30, 30), emitClass: ecOverlay)

proc intentBytes(kind = ikNavigateTo; point = some(MapPoint(x: 30, y: 30));
                 reason = ""; idleAim = none(int)): string =
  canonicalIntent(Intent(kind: kind, point: point, arriveRadius: 24.0,
    idleAimCenterBrads: idleAim, reason: reason))

suite "shell emit validator":
  test "controller intent accepts exact goals and normalizes blocked goals":
    let map = openRoomsMap()
    var outcome = validateEmit(intentBytes(), map.controllerContext)
    check outcome.code == AbiOk
    check outcome.accepted
    check not outcome.normalized
    check outcome.canonicalBytes == intentBytes()

    outcome = validateEmit(intentBytes(point = some(MapPoint(x: 0, y: 0))),
      map.controllerContext)
    check outcome.code == AbiNormalized
    check outcome.accepted
    check outcome.normalized
    check outcome.intent.point == some(MapPoint(x: 7, y: 7))
    check outcome.canonicalBytes == canonicalIntent(outcome.intent)

  test "controller intent rejects every fixed negative return-code class":
    let map = openRoomsMap()
    check validateEmit("{\"arrive_radius\":0,\"kind\":\"hold\",\"point\":[1,1]," &
      "\"schema\":\"intent\",\"v\":1}", map.controllerContext).code ==
      AbiSchemaViolation
    check validateEmit("{\"arrive_radius\":0,\"kind\":\"hold\",\"reason\":\"" &
      repeat("r", IntentReasonMaxBytes + 1) &
      "\",\"schema\":\"intent\",\"v\":1}", map.controllerContext).code ==
      AbiRangeViolation
    check validateEmit(intentBytes(point = some(MapPoint(x: 650, y: 30))),
      map.controllerContext).code == AbiUnreachableGoal
    check validateEmit("{\"arrive_radius\":0,\"combat\":{\"no_shoot\":{" &
      "\"seats\":[\"seat:255\"]},\"schema\":\"combat_policy\",\"v\":1}," &
      "\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}",
      map.controllerContext).code == AbiUnknownReference
    check validateEmit(canonicalCombatPolicy(CombatPolicy(holdFire: true)),
      map.controllerContext).code == AbiClassMismatch
    check validateEmit(repeat("x", MaxEmitBytes + 1),
      map.controllerContext).code == AbiTooLarge

  test "overlay policy accepts policies and rejects controller bytes":
    let map = openRoomsMap()
    let policy = CombatPolicy(holdFire: true)
    let outcome = validateEmit(canonicalCombatPolicy(policy), map.overlayContext)
    check outcome.code == AbiOk
    check outcome.accepted
    check outcome.policy.holdFire
    check outcome.canonicalBytes == canonicalCombatPolicy(policy)

    check validateEmit(intentBytes(kind = ikHold, point = none(MapPoint)),
      map.overlayContext).code == AbiClassMismatch
    check validateEmit("{\"hold_fire\":true,\"prefer\":[\"weakened\"," &
      "\"isolated\",\"revenge\",\"bounty\",\"weakened\"]," &
      "\"schema\":\"combat_policy\",\"v\":1}", map.overlayContext).code ==
      AbiRangeViolation
    check validateEmit("{\"no_shoot\":{\"teams\":[\"bogus\"]}," &
      "\"schema\":\"combat_policy\",\"v\":1}", map.overlayContext).code ==
      AbiUnknownReference

  test "validation stays under the local warm max gate":
    let map = openRoomsMap()
    let bytes = intentBytes(point = some(MapPoint(x: 0, y: 0)),
      reason = repeat("r", IntentReasonMaxBytes))
    let ctx = map.controllerContext
    for _ in 0 ..< 100:
      check validateEmit(bytes, ctx).code == AbiNormalized
    GC_fullCollect()
    when declared(GC_disable):
      GC_disable()
    elif declared(GC_disableOrc):
      GC_disableOrc()
    var maxNs = 0'i64
    for _ in 0 ..< 1000:
      let started = getMonoTime()
      let outcome = validateEmit(bytes, ctx)
      let elapsed = (getMonoTime() - started).inNanoseconds
      if elapsed > maxNs:
        maxNs = elapsed
      check outcome.code == AbiNormalized
    when declared(GC_enable):
      GC_enable()
    elif declared(GC_enableOrc):
      GC_enableOrc()
    echo "SHELL_EMIT_VALIDATION_MAX_US ", (maxNs.float / 1000.0)
    when defined(release):
      check maxNs <= 15_000
    else:
      check maxNs > 0
