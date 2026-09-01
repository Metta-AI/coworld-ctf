## Phase-4 CombatPolicy execution contract.

import std/[options, unittest]

import bitworld/spriteprotocol
import ../src/ctf/sim_types
import ../src/shell/body
import ../src/shell/body_map
import ../src/shell/types as shellTypes

proc p(x, y: int): BodyPoint = (x, y)

proc openMap(): BodyMap =
  const Width = 256
  const Height = 160
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[p(16, 80), p(Width - 17, 80)])

proc sightBlockedMap(): BodyMap =
  const Width = 256
  const Height = 160
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = not (x == 80 and y in 64 .. 96)
  newBodyMap(walkable, Width, Height, 2, @[p(16, 80), p(Width - 17, 80)])

proc selfState(pos = p(16, 80), aimBrads = 0, hp = 3, hpFrac = 1.0,
               hasGrenade = false, hasSprayPaint = false,
               fireCooldown = 0, fireWindup = 0): BodySelfState =
  BodySelfState(pos: pos, hp: hp, hpFrac: hpFrac, lives: some(1),
    aimBrads: aimBrads, fireCooldown: fireCooldown, fireWindup: fireWindup,
    hasGrenade: hasGrenade, hasSprayPaint: hasSprayPaint,
    alive: true)

proc updateTracks(body: SeatBody, tick: uint32,
                  tracks: openArray[BodyTrackUpdate],
                  self = selfState()) =
  body.updateBelief(BodyTickInputs(self: self,
    visibleTracks: @tracks), tick)

proc track(seat: int, pos: BodyPoint, team: Team, tick: uint32,
           hp = 3, aim = some(128), shielded = false,
           weapon = none(BodyWeapon)): BodyTrackUpdate =
  BodyTrackUpdate(seat: seat, pos: pos, team: team, aimBrads: aim,
    hpKnown: some(hp), shielded: shielded, weapon: weapon, tick: tick)

proc unknownHpTrack(seat: int, pos: BodyPoint, team: Team,
                    tick: uint32): BodyTrackUpdate =
  BodyTrackUpdate(seat: seat, pos: pos, team: team, aimBrads: some(128),
    hpKnown: none(int), tick: tick)

proc candidate(seat: int, score: float, shootable = true,
               identity = some(seat)): CombatCandidateInput =
  CombatCandidateInput(seat: seat, shootable: shootable, baseScore: score,
    identity: identity)

proc combatHold(policy: CombatPolicy): shellTypes.Intent =
  shellTypes.Intent(kind: shellTypes.ikHold, point: none(MapPoint),
    idleAimCenterBrads: none(int), profile: shellTypes.cpDefault,
    combat: policy)

proc selectedSeat(decision: Option[CombatDecision]): int =
  doAssert decision.isSome
  decision.get.combatTarget.combatSeat

proc closeTo(actual, expected: float): bool =
  abs(actual - expected) < 0.000001

suite "shell combat policy":
  test "noShoot target is not constructible outside the selector":
    static:
      doAssert not compiles(CombatTarget(seat: 1, team: Blue,
        pos: (10, 10), identity: some(1)))

  test "gate claim sweep never selects a noShoot target":
    # Defence in depth over the private-target construction guarantee: even an
    # adversarial candidate list cannot make the single selector return a
    # noShoot seat or team.
    let teams = [Red, Blue, Green, Yellow, Orange, Navy]
    for bannedSeat in 1 .. 5:
      for bannedTeam in teams:
        let body = activateSeatBody(openMap(), 0, 331)
        var updates: seq[BodyTrackUpdate]
        var inputs: seq[CombatCandidateInput]
        for seat in 1 .. 5:
          let team = teams[(seat + ord(bannedTeam)) mod teams.len]
          updates.add(track(seat, p(32 + seat * 16, 40 + seat * 8),
            team, 20))
          inputs.add(candidate(seat, 10.0 - seat.float))
        body.updateTracks(20, updates)
        let policy = CombatPolicy(noShoot: ProtectedSet(
          teams: {bannedTeam}, seats: @[SeatRef(uint8(bannedSeat))]))
        let decision = body.selectCombatTarget(policy, inputs, 20, 331, 3)
        if decision.isSome:
          let target = decision.get.combatTarget
          check not policy.noShootTarget(target.combatSeat,
            target.combatTeam)

  test "noShoot precedes prefer and holdFire":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[
        track(1, p(64, 40), Blue, 40, hp = 1),
        track(2, p(96, 40), Green, 40, hp = 3)],
      aggressorEvents: @[
        AggressorEvent(eventId: 1, tick: 40, dirBrads: 0, seat: some(1)),
        AggressorEvent(eventId: 2, tick: 40, dirBrads: 0, seat: some(2))]),
      40)
    let policy = CombatPolicy(
      noShoot: ProtectedSet(seats: @[SeatRef(1'u8)]),
      prefer: @[ptWeakened],
      holdFire: true)
    let decision = body.selectCombatTarget(policy,
      [candidate(1, 0.0), candidate(2, 0.0)], 40, 331, 3)
    check decision.selectedSeat == 2

    let held = activateSeatBody(openMap(), 0, 331)
    held.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[track(1, p(64, 40), Blue, 50, hp = 1)],
      aggressorEvents: @[
        AggressorEvent(eventId: 3, tick: 50, dirBrads: 0, seat: some(1))]),
      50)
    check held.selectCombatTarget(policy, [candidate(1, 100.0)],
      50, 331, 3).isNone

  test "holdFire permits only retained identified aggressors until expiry":
    let body = activateSeatBody(openMap(), 0, 331)
    let policy = CombatPolicy(holdFire: true)
    body.updateTracks(10, [track(1, p(64, 40), Blue, 10)])
    check body.selectCombatTarget(policy, [candidate(1, 1.0)],
      10, 331, 3).isNone

    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[track(1, p(64, 40), Blue, 11)],
      aggressorEvents: @[
        AggressorEvent(eventId: 10, tick: 11, dirBrads: 0,
          seat: some(1))]), 11)
    check body.selectCombatTarget(policy, [candidate(1, 1.0)],
      11, 331, 3).selectedSeat == 1

    # The retained aggressor list is the self-or-visible-ward return-fire
    # permission set. Anonymous events never name a target, so they cannot
    # initiate a held-fire engagement.
    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[track(2, p(96, 40), Green, 12)],
      aggressorEvents: @[
        AggressorEvent(eventId: 11, tick: 12, dirBrads: 0,
          seat: none(int))]), 12)
    check body.selectCombatTarget(policy, [candidate(2, 2.0)],
      12, 331, 3).isNone

    body.updateBelief(BodyTickInputs(self: selfState(),
      visibleTracks: @[track(1, p(64, 40), Blue, 131)]), 131)
    check body.selectCombatTarget(policy, [candidate(1, 1.0)],
      131, 331, 3).isNone

  test "stickiness keeps, margin-switches, and immediately leaves unshootable current":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateTracks(0, [
      track(1, p(64, 40), Blue, 0),
      track(2, p(96, 40), Green, 0)])
    check body.selectCombatTarget(CombatPolicy(),
      [candidate(1, 1.0), candidate(2, 0.9)], 0, 331, 3).selectedSeat == 1

    body.updateTracks(1, [
      track(1, p(64, 40), Blue, 1),
      track(2, p(96, 40), Green, 1)])
    check body.selectCombatTarget(CombatPolicy(),
      [candidate(1, 1.0), candidate(2, 1.5)], 1, 331, 3).selectedSeat == 1

    body.updateTracks(uint32(FirefightTargetMinDwellTicks), [
      track(1, p(64, 40), Blue, uint32(FirefightTargetMinDwellTicks)),
      track(2, p(96, 40), Green, uint32(FirefightTargetMinDwellTicks))])
    check body.selectCombatTarget(CombatPolicy(),
      [candidate(1, 1.0), candidate(2, 1.11)],
      uint32(FirefightTargetMinDwellTicks), 331, 3).selectedSeat == 2

    body.updateTracks(uint32(FirefightTargetMinDwellTicks + 1), [
      track(1, p(64, 40), Blue, uint32(FirefightTargetMinDwellTicks + 1)),
      track(2, p(96, 40), Green, uint32(FirefightTargetMinDwellTicks + 1))])
    check body.selectCombatTarget(CombatPolicy(),
      [candidate(1, 0.5), candidate(2, 0.6, shootable = false)],
      uint32(FirefightTargetMinDwellTicks + 1), 331, 3).selectedSeat == 1

  test "ordering follows prefer then score, identity, cell y, and cell x":
    block scoreDescending:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(1, [
        track(1, p(64, 40), Blue, 1),
        track(2, p(96, 40), Green, 1)])
      check body.selectCombatTarget(CombatPolicy(),
        [candidate(1, 1.0), candidate(2, 2.0)], 1, 331, 3).selectedSeat == 2

    block preferBeforeScore:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(1, [
        track(1, p(64, 40), Blue, 1, hp = 1),
        track(2, p(96, 40), Green, 1, hp = 3)])
      check body.selectCombatTarget(CombatPolicy(prefer: @[ptWeakened]),
        [candidate(1, 0.0), candidate(2, 100.0)], 1, 331, 3).selectedSeat == 1

    block knownBeforeUnknown:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(1, [
        track(1, p(64, 40), Blue, 1),
        track(2, p(96, 40), Green, 1)])
      check body.selectCombatTarget(CombatPolicy(),
        [candidate(1, 1.0, identity = none(int)),
         candidate(2, 1.0, identity = some(9))], 1, 331, 3).selectedSeat == 2

    block identityAscending:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(1, [
        track(1, p(64, 40), Blue, 1),
        track(2, p(96, 40), Green, 1)])
      check body.selectCombatTarget(CombatPolicy(),
        [candidate(1, 1.0, identity = some(3)),
         candidate(2, 1.0, identity = some(2))], 1, 331, 3).selectedSeat == 2

    block cellYThenX:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(1, [
        track(1, p(80, 48), Blue, 1),
        track(2, p(96, 40), Green, 1),
        track(3, p(64, 48), Yellow, 1)])
      check body.selectCombatTarget(CombatPolicy(),
        [candidate(1, 1.0, identity = none(int)),
         candidate(2, 1.0, identity = none(int)),
         candidate(3, 1.0, identity = none(int))], 1, 331, 3).selectedSeat == 2
      let body2 = activateSeatBody(openMap(), 0, 331)
      body2.updateTracks(1, [
        track(1, p(80, 48), Blue, 1),
        track(3, p(64, 48), Yellow, 1)])
      check body2.selectCombatTarget(CombatPolicy(),
        [candidate(1, 1.0, identity = none(int)),
         candidate(3, 1.0, identity = none(int))], 1, 331, 3).selectedSeat == 3

    block unknownSameCellFallsBackToSeat:
      proc choose(inputs: openArray[CombatCandidateInput]): int =
        let body = activateSeatBody(openMap(), 0, 331)
        body.updateTracks(1, [
          track(4, p(64, 40), Blue, 1),
          track(2, p(66, 42), Green, 1)])
        body.selectCombatTarget(CombatPolicy(), inputs, 1, 331, 3).selectedSeat

      let left = [
        candidate(4, 1.0, identity = none(int)),
        candidate(2, 1.0, identity = none(int))]
      let right = [
        candidate(2, 1.0, identity = none(int)),
        candidate(4, 1.0, identity = none(int))]
      check choose(left) == 2
      check choose(right) == 2

  test "ward threat uses live range, aim bearing, fallback proximity, and exclusions":
    let policy = CombatPolicy(protect: ProtectedSet(seats: @[SeatRef(5'u8)]))
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateTracks(20, [
      track(2, p(150, 80), Blue, 20, aim = some(128)),
      track(3, p(64, 120), Green, 20),
      track(5, p(100, 80), Red, 20)])
    check not body.threatensProtectedWard(policy, 2, 20, 49)
    check body.threatensProtectedWard(policy, 2, 20, 50)
    check not body.threatensProtectedWard(policy, 5, 20, 331)
    check body.selectCombatTarget(policy,
      [candidate(2, 0.0), candidate(3, 0.5)], 20, 50, 3).selectedSeat == 2

    let fallback = activateSeatBody(openMap(), 0, 331)
    fallback.updateTracks(20, [
      track(2, p(150, 80), Blue, 20, aim = none(int)),
      track(5, p(100, 80), Red, 20)])
    check fallback.threatensProtectedWard(policy, 2, 20, 50)

  test "grenade commit revalidates endpoint and splash against current policy":
    let body = activateSeatBody(openMap(), 0, 331)
    body.updateTracks(30, [
      track(1, p(64, 40), Blue, 30),
      track(2, p(96, 40), Green, 30)])
    let decision = body.selectCombatTarget(CombatPolicy(),
      [candidate(1, 1.0)], 30, 331, 3)
    let target = decision.get.combatTarget
    check body.revalidateGrenadeCommit(CombatPolicy(), target, [], 30).isSome
    check body.revalidateGrenadeCommit(
      CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(1'u8)])),
      target, [], 30).isNone
    check body.revalidateGrenadeCommit(
      CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(2'u8)])),
      target, [2], 30).isNone

    let absent = activateSeatBody(openMap(), 0, 331)
    absent.updateTracks(31, [track(1, p(64, 40), Blue, 31)])
    let absentTarget = absent.selectCombatTarget(CombatPolicy(),
      [candidate(1, 1.0)], 31, 331, 3).get.combatTarget
    check absent.revalidateGrenadeCommit(
      CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(2'u8)])),
      absentTarget, [2], 31).isNone
    # Team bans need a fog-readable team. With no track for splash seat 2, the
    # seat id is known but its team is not, so a team-only ban cannot cancel.
    check absent.revalidateGrenadeCommit(
      CombatPolicy(noShoot: ProtectedSet(teams: {Green})),
      absentTarget, [2], 31).isSome

  test "baseScore isolates every stencil term owned by body weapons":
    block unknownWound:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [unknownHpTrack(1, p(96, 80), Blue, 70)])
      check body.combatBaseScore(1, 3).closeTo(
        FirefightWoundWeight * FirefightWoundUnknown)

    block rangePlateau:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [track(1, p(236, 80), Blue, 70, hp = 3)])
      check body.combatBaseScore(1, 3).closeTo(FirefightRangeWeight)

    block aimCostOnly:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [track(1, p(16, 160), Blue, 70, hp = 3)])
      check body.combatBaseScore(1, 3).closeTo(
        -FirefightAimCostWeight * 0.5)

    block shieldOnly:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [
        track(1, p(96, 80), Blue, 70, hp = 3, shielded = true)])
      check body.combatBaseScore(1, 3).closeTo(-FirefightShieldWeight)

    block sprayOnly:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [
        track(1, p(96, 80), Blue, 70, hp = 3,
          weapon = some(bwSpray))])
      check body.combatBaseScore(1, 3).closeTo(FirefightSprayWeight)

    block assembled:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(70, [
        track(1, p(236, 80), Blue, 70, hp = 1, shielded = true,
          weapon = some(bwSpray))])
      check body.combatBaseScore(1, 3).closeTo(
        FirefightWoundWeight * (2.0 / 3.0) + FirefightRangeWeight -
          FirefightShieldWeight + FirefightSprayWeight)

  test "shootability uses live range, map ray, and protected blockers":
    block liveRange:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(78, [track(1, p(136, 80), Blue, 78, hp = 1)])
      check not body.trackShootable(CombatPolicy(), 1, 78, 100)

    block mapRay:
      let body = activateSeatBody(sightBlockedMap(), 0, 331)
      body.updateTracks(78, [track(1, p(136, 80), Blue, 78, hp = 1)])
      check not body.trackShootable(CombatPolicy(), 1, 78, 331)

    block protectedBlocker:
      let body = activateSeatBody(openMap(), 0, 331)
      let policy = CombatPolicy(protect: ProtectedSet(seats: @[SeatRef(2'u8)]))
      body.updateTracks(78, [
        track(1, p(136, 80), Blue, 78, hp = 1),
        track(2, p(80, 80), Red, 78, hp = 3)])
      check not body.trackShootable(policy, 1, 78, 331)

  test "fire timing and final policy veto gate actuation":
    let policy = CombatPolicy(prefer: @[ptWeakened])

    block gunFiresWhenReady:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(80, [track(1, p(136, 80), Blue, 80, hp = 1)])
      let decision = body.selectCombatTarget(policy,
        body.combatCandidates(policy, 80, 331, 3), 80, 331, 3)
      let fired = body.weaponActuationMask(policy, decision, 80)
      check (fired and ButtonA) != 0
      check (fired and ButtonC) == 0

    block seatTickRoutesStandingCombatToActuation:
      let body = activateSeatBody(openMap(), 0, 331)
      body.setStandingIntent(combatHold(policy), none(ValidatedGoal), 1)
      let input = body.seatTick(BodyTickInputs(self: selfState(),
        visibleTracks: @[track(1, p(136, 80), Blue, 80, hp = 1)]), 80)
      check input.attack
      check not input.c

    block policyChangeCancelsBetweenDecisionAndActuation:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(80, [track(1, p(136, 80), Blue, 80, hp = 1)])
      let decision = body.selectCombatTarget(policy,
        body.combatCandidates(policy, 80, 331, 3), 80, 331, 3)
      let veto = CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(1'u8)]),
        prefer: @[ptWeakened])
      check body.weaponActuationMask(veto, decision, 80) == 0

      let holdFireVeto = CombatPolicy(holdFire: true, prefer: @[ptWeakened])
      check body.weaponActuationMask(holdFireVeto, decision, 80) == 0

    block cooldownAndWindupBlockTrigger:
      for blockedSelf in [
          selfState(fireCooldown = 1),
          selfState(fireWindup = 1)]:
        let body = activateSeatBody(openMap(), 0, 331)
        body.updateTracks(80, [track(1, p(136, 80), Blue, 80, hp = 1)],
          blockedSelf)
        let decision = body.selectCombatTarget(policy,
          body.combatCandidates(policy, 80, 331, 3), 80, 331, 3)
        check (body.weaponActuationMask(policy, decision, 80) and ButtonA) == 0

    block sprayUsesAttackBitOnlyWhenConeContainsTarget:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(80, [track(1, p(96, 80), Blue, 80, hp = 1)],
        selfState(hasSprayPaint = true))
      let decision = body.selectCombatTarget(policy,
        body.combatCandidates(policy, 80, 331, 3), 80, 331, 3)
      let fired = body.weaponActuationMask(policy, decision, 80)
      check (fired and ButtonA) != 0
      check (fired and ButtonC) == 0

    block grenadeChargesThenPolicyVetoCancelsReleasePath:
      let body = activateSeatBody(openMap(), 0, 331)
      body.updateTracks(80, [track(1, p(136, 80), Blue, 80, hp = 1)],
        selfState(hasGrenade = true))
      let decision = body.selectCombatTarget(policy,
        body.combatCandidates(policy, 80, 331, 3), 80, 331, 3)
      check body.weaponActuationMask(policy, decision, 80) == ButtonC
      let veto = CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(1'u8)]),
        prefer: @[ptWeakened])
      check body.weaponActuationMask(veto, decision, 81) == 0

  test "selection is deterministic across repeats and candidate permutations":
    proc filled(): SeatBody =
      result = activateSeatBody(openMap(), 0, 331)
      result.updateTracks(60, [
        track(1, p(96, 40), Blue, 60, hp = 2),
        track(2, p(64, 40), Green, 60, hp = 2),
        track(3, p(128, 40), Yellow, 60, hp = 1)])
    let policy = CombatPolicy(prefer: @[ptWeakened, ptIsolated])
    let left = filled()
    let right = filled()
    let a = left.selectCombatTarget(policy,
      [candidate(1, 1.0), candidate(2, 1.0), candidate(3, 0.0)],
      60, 331, 3)
    let b = right.selectCombatTarget(policy,
      [candidate(3, 0.0), candidate(2, 1.0), candidate(1, 1.0)],
      60, 331, 3)
    check a.selectedSeat == b.selectedSeat
    check a.get.combatScore == b.get.combatScore
    check left.selectCombatTarget(policy,
      [candidate(2, 1.0), candidate(1, 1.0), candidate(3, 0.0)],
      60, 331, 3).selectedSeat == a.selectedSeat
