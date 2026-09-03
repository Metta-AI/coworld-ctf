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

proc withDuo(ctx: var EmitValidationContext, team: Team, a, b: int) =
  ctx.duoSeats[team] = DuoSeats(configured: true,
    seats: [SeatRef(uint8(a)), SeatRef(uint8(b))])

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
      "\"isolated\",\"weakened\"]," &
      "\"schema\":\"combat_policy\",\"v\":1}", map.overlayContext).code ==
      AbiSchemaViolation
    let fourDistinct = validateEmit("{\"hold_fire\":true,\"prefer\":[" &
      "\"weakened\",\"isolated\",\"revenge\",\"bounty\"]," &
      "\"schema\":\"combat_policy\",\"v\":1}", map.overlayContext)
    check fourDistinct.code == AbiOk
    check fourDistinct.accepted
    check fourDistinct.policy.prefer == @[ptWeakened, ptIsolated, ptRevenge,
      ptBounty]
    check validateEmit("{\"no_shoot\":{\"teams\":[\"bogus\"]}," &
      "\"schema\":\"combat_policy\",\"v\":1}", map.overlayContext).code ==
      AbiUnknownReference

  test "duo seat refs resolve only in battle royale and fold to plain seats":
    let map = openRoomsMap()
    var br = map.overlayContext
    br.mode = gmBr
    br.withDuo(Navy, 10, 2)
    let accepted = validateEmit("{\"no_shoot\":{\"seats\":[" &
      "\"duo:navy\",\"seat:2\"]},\"schema\":\"combat_policy\",\"v\":1}", br)
    check accepted.code == AbiOk
    check accepted.accepted
    check accepted.canonicalBytes == "{\"no_shoot\":{\"seats\":[" &
      "\"seat:10\",\"seat:2\"]},\"schema\":\"combat_policy\",\"v\":1}"

    for mode in [gmCtf, gmKoth]:
      var ctx = map.overlayContext
      ctx.mode = mode
      ctx.withDuo(Navy, 10, 2)
      let rejected = validateEmit("{\"no_shoot\":{\"seats\":[" &
        "\"duo:navy\"]},\"schema\":\"combat_policy\",\"v\":1}", ctx)
      check rejected.code == AbiUnknownReference
      check rejected.reason == "noDuosInMode"

    var unknownDuo = map.overlayContext
    unknownDuo.mode = gmBr
    check validateEmit("{\"no_shoot\":{\"seats\":[\"duo:navy\"]}," &
      "\"schema\":\"combat_policy\",\"v\":1}", unknownDuo).code ==
      AbiUnknownReference
    check validateEmit("{\"no_shoot\":{\"seats\":[\"duo:bogus\"]}," &
      "\"schema\":\"combat_policy\",\"v\":1}", unknownDuo).code ==
      AbiUnknownReference

  test "handoff declares only in battle royale and only the seam's items":
    # §4.1 amendment: the standing give-item declaration. Same mode rule as
    # duo refs (a duo fact), same closed vocabulary as sim.declareHandoff.
    let map = openRoomsMap()
    var br = map.controllerContext
    br.mode = gmBr
    let declared = "{\"arrive_radius\":0.0,\"handoff\":\"gun\"," &
      "\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}"
    let accepted = validateEmit(declared, br)
    check accepted.code == AbiOk
    check accepted.accepted
    check accepted.intent.handoff == "gun"
    # The canonical re-encoding keeps the field in sorted position, and a
    # typed round trip reproduces the emission byte-for-byte.
    check accepted.canonicalBytes == declared
    check accepted.canonicalBytes == canonicalIntent(accepted.intent)

    # Every item of the seam's vocabulary is accepted; anything else is an
    # unknown reference, never a silent drop.
    for item in ["bandage", "hopper"]:
      check validateEmit("{\"arrive_radius\":0.0,\"handoff\":\"" & item &
        "\",\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}", br).accepted
    check validateEmit("{\"arrive_radius\":0.0,\"handoff\":\"shield\"," &
      "\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}", br).code ==
      AbiUnknownReference
    check validateEmit("{\"arrive_radius\":0.0,\"handoff\":true," &
      "\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}", br).code ==
      AbiSchemaViolation

    # A duo fact has no meaning outside battle royale: rejected by the same
    # rule (and reason) that rejects "duo:" references there.
    for mode in [gmCtf, gmKoth]:
      var ctx = map.controllerContext
      ctx.mode = mode
      let rejected = validateEmit(declared, ctx)
      check rejected.code == AbiUnknownReference
      check rejected.reason == "noDuosInMode"

    # Neutral is omitted: an intent that declares nothing encodes without
    # the key, so every pre-amendment emission is byte-identical.
    check "handoff" notin canonicalIntent(Intent(kind: ikHold,
      arriveRadius: 0.0))

  test "protected set writer is shared across finisher and emit validation":
    let map = openRoomsMap()
    let protectedSet = ProtectedSet(seats: @[
      SeatRef(2), SeatRef(10), SeatRef(30), SeatRef(2)])
    let policy = CombatPolicy(noShoot: protectedSet)
    let protectedBytes = "{\"seats\":[\"seat:10\",\"seat:2\",\"seat:30\"]}"
    let emitBytes = canonicalCombatPolicy(policy)
    let finishBytes = canonicalIntent(Intent(kind: ikHold, arriveRadius: 0.0,
      combat: policy))
    check emitBytes == "{\"no_shoot\":" & protectedBytes &
      ",\"schema\":\"combat_policy\",\"v\":1}"
    check finishBytes == "{\"arrive_radius\":0.0,\"combat\":{\"no_shoot\":" &
      protectedBytes & ",\"schema\":\"combat_policy\",\"v\":1}," &
      "\"kind\":\"hold\",\"schema\":\"intent\",\"v\":1}"
    check validateEmit(emitBytes, map.overlayContext).canonicalBytes ==
      emitBytes

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
    var overCeiling = 0
    for _ in 0 ..< 1000:
      let started = getMonoTime()
      let outcome = validateEmit(bytes, ctx)
      let elapsed = (getMonoTime() - started).inNanoseconds
      if elapsed > maxNs:
        maxNs = elapsed
      if elapsed > 100_000:
        inc overCeiling
      check outcome.code == AbiNormalized
    when declared(GC_enable):
      GC_enable()
    elif declared(GC_enableOrc):
      GC_enableOrc()
    echo "SHELL_EMIT_VALIDATION_MAX_US ", (maxNs.float / 1000.0)
    echo "SHELL_EMIT_VALIDATION_OVER_CEILING ", overCeiling
    when defined(release):
      when defined(shellShardRegressionGate):
        # Shard 2 runs concurrently with the other CI shards, so this path keeps
        # a regression-class ceiling while the serial focused phase gate above
        # remains the strict 15 us acceptance check. Gate on the count of
        # iterations over the ceiling rather than the single worst sample:
        # max-of-1000 on a preempted shared runner is a tail-latency lottery
        # (bit twice on main 2026-09-03), while a genuine regression pushes
        # every iteration over and still fails this check.
        check overCeiling <= 10
      else:
        check maxNs <= 15_000
    else:
      check maxNs > 0
