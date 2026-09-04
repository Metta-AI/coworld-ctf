## Server-owned FIRST LIGHT belief-lite handoff checks.

import std/[math, unittest]

include ../src/ctf/server

proc startedObservationSim(playerCount = 3): SimServer =
  result = initSimServer(defaultGameConfig())
  for index in 0 ..< playerCount:
    discard result.addPlayer("observation-" & $index)
  result.startGame()

proc admitted(sim: SimServer, playerIndices: openArray[int]):
    seq[ObservationAudienceSeat] =
  for playerIndex in playerIndices:
    let slot = sim.players[playerIndex].joinOrder
    result.add ObservationAudienceSeat(
      slot: uint8(slot), lifeGeneration: sim.seatLifeGenerations[slot])

suite "shell FIRST LIGHT server seam":
  test "self hp count and fraction are populated from sim truth":
    var sim = initSimServer(defaultGameConfig())
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].hp = 3
    sim.players[playerIndex].shieldHp = 2

    let live = sim.firstLightSelfState(playerIndex)
    check live.hp == 5
    check (live.hp > 0) == (live.hpFrac > 0.0)

    sim.players[playerIndex].hp = 0
    sim.players[playerIndex].shieldHp = 0
    let depleted = sim.firstLightSelfState(playerIndex)
    check depleted.hp == 0
    check (depleted.hp > 0) == (depleted.hpFrac > 0.0)

  test "self combat facts are populated from sim truth":
    var config = defaultGameConfig()
    config.brMode = false
    var sim = initSimServer(config)
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].lives = 2
    sim.players[playerIndex].aimBrads = 37
    sim.players[playerIndex].fireCooldown = 11
    sim.players[playerIndex].fireWindup = 3
    sim.players[playerIndex].windupBrads = 0
    sim.players[playerIndex].hasGrenade = true
    sim.players[playerIndex].hasShield = true
    sim.players[playerIndex].shieldHp = 2
    sim.players[playerIndex].hasSprayPaint = true
    sim.players[playerIndex].arcTicksLeft = 5

    let live = sim.firstLightSelfState(playerIndex)
    check live.lives == some(2)
    check live.aimBrads == 37
    check live.fireCooldown == 11
    check live.fireWindup == 3
    check live.windup == some(0)
    check live.hasGrenade
    check live.hasShield
    check live.shieldHp == 2
    check live.hasSprayPaint
    check live.arcTicksLeft == 5

    sim.players[playerIndex].windupBrads = -1
    sim.players[playerIndex].hasShield = false
    sim.players[playerIndex].shieldHp = 0
    let idle = sim.firstLightSelfState(playerIndex)
    check idle.windup.isNone
    check not idle.hasShield
    check idle.shieldHp == 0

  test "self lives are omitted in battle royale mode":
    var config = defaultGameConfig()
    config.brMode = true
    var sim = initSimServer(config)
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].lives = 1

    let live = sim.firstLightSelfState(playerIndex)
    check live.lives.isNone

  test "visible track combat facts are populated from sim truth":
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    let targetIndex = sim.addPlayer("blue0")
    sim.players[targetIndex].x = sim.players[viewerIndex].x
    sim.players[targetIndex].y = sim.players[viewerIndex].y
    sim.players[targetIndex].aimBrads = 91
    sim.players[targetIndex].hp = 2
    sim.players[targetIndex].hasShield = true
    sim.players[targetIndex].shieldHp = 1
    sim.players[targetIndex].hasSprayPaint = true
    sim.players[targetIndex].arcTicksLeft = 4
    sim.players[targetIndex].level = AceLevel

    let inputs = sim.firstLightBodyInputs(viewerIndex)
    check inputs.visibleTracks.len == 1
    let track = inputs.visibleTracks[0]
    check track.seat == sim.players[targetIndex].joinOrder
    check track.aimBrads == some(91)
    check track.hpKnown == some(3)
    check track.shielded == sim.players[targetIndex].hasShield
    check track.weapon == some(bwSpray)
    check track.veteranMarker

    sim.players[targetIndex].hasSprayPaint = false
    sim.players[targetIndex].arcTicksLeft = 0
    sim.players[targetIndex].hasGrenade = true
    sim.fovCaches.setLen(0)
    let grenadeInputs = sim.firstLightBodyInputs(viewerIndex)
    check grenadeInputs.visibleTracks[0].weapon == some(bwGrenade)

  test "item sightings are populated from the fixed pickup spawns":
    # Before this pass nothing fed BodyTickInputs.sightedItems outside the
    # tests, so body.items -- and the play view's items array -- stayed empty
    # for the whole match and no play could ever see a pickup.
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    let viewer = sim.players[viewerIndex]
    sim.grenadeSpawns = @[PickupSpawn(x: viewer.x, y: viewer.y, present: true)]
    sim.medKitSpawns = @[PickupSpawn(x: viewer.x + 1, y: viewer.y,
      present: false, respawnAt: 999)]
    sim.shieldSpawns = @[PickupSpawn(x: viewer.x, y: viewer.y + 1,
      present: true)]
    sim.sprayPaintSpawns.setLen(0)
    sim.barrierSpawns.setLen(0)

    let inputs = sim.firstLightBodyInputs(viewerIndex)
    check inputs.sightedItems.len == 3
    var kinds: seq[BodyItemKind]
    for sighting in inputs.sightedItems:
      kinds.add sighting.kind
      check sighting.tick == uint32(sim.tickCount + 1)
    check bikGrenade in kinds
    check bikMedkit in kinds
    check bikShield in kinds
    for sighting in inputs.sightedItems:
      if sighting.kind == bikMedkit:
        check not sighting.present  # a taken kit is still a sighting
        check sighting.pos == (viewer.x + 1, viewer.y)
      else:
        check sighting.present

  test "event ids are deterministic and unique within one tick":
    var sim = startedObservationSim(2)
    sim.tickCount = 41
    let
      first = sim.nextObservationEventId(GunKillObservationKind, 0, 1)
      second = sim.nextObservationEventId(GunKillObservationKind, 0, 1)
      differentTarget = sim.nextObservationEventId(
        GunKillObservationKind, 0, 0)
    check first == packedObservationEventId(
      41, GunKillObservationKind, 0, 1, 0)
    check second == packedObservationEventId(
      41, GunKillObservationKind, 0, 1, 1)
    check differentTarget == packedObservationEventId(
      41, GunKillObservationKind, 0, 0, 0)
    check first != second
    check first != differentTarget

  test "public and private retained observations obey their audience":
    var sim = startedObservationSim()
    let
      seat0 = sim.players[0].joinOrder
      seat1 = sim.players[1].joinOrder
      generation0 = sim.seatLifeGenerations[seat0]
    sim.publicKillObservations.add KillObservation(
      eventId: 101, tick: sim.tickCount, killerTeam: Red,
      victimSlot: seat1)
    sim.aggressorObservations.add AggressorObservation(
      eventId: 102, tick: sim.tickCount, victimSlot: seat0,
      victimLifeGeneration: generation0, dirBrads: 17, attackerSlot: seat1)
    sim.blastObservations.add BlastObservation(
      eventId: 103, tick: sim.tickCount, x: 400, y: 300,
      audience: sim.admitted([0, 1]),
      coveredSlots: 1'u32 shl seat0)
    sim.sprayImpactObservations.add SprayImpactObservation(
      eventId: 104, tick: sim.tickCount, x: 410, y: 300,
      incomingDirBrads: 128, audience: sim.admitted([0]))

    let
      first = sim.firstLightBodyInputs(0)
      second = sim.firstLightBodyInputs(1)
      excluded = sim.firstLightBodyInputs(2)
    check first.killFeed.len == 1
    check second.killFeed.len == 1
    check excluded.killFeed.len == 1
    check first.aggressorEvents.len == 1
    check first.aggressorEvents[0].seat == some(seat1)
    check second.aggressorEvents.len == 0
    check excluded.aggressorEvents.len == 0
    check first.hazards.blastCues.len == 1
    check first.hazards.blastCues[0].coversSelf
    check second.hazards.blastCues.len == 1
    check not second.hazards.blastCues[0].coversSelf
    check excluded.hazards.blastCues.len == 0
    check first.hazards.sprays.len == 1
    check first.hazards.sprays[0].kind == bshAnonymousImpact
    check second.hazards.sprays.len == 0
    check excluded.hazards.sprays.len == 0

    inc sim.seatLifeGenerations[seat0]
    let nextLife = sim.firstLightBodyInputs(0)
    check nextLife.killFeed.len == 1
    check nextLife.aggressorEvents.len == 0
    check nextLife.hazards.blastCues.len == 0
    check nextLife.hazards.sprays.len == 0

  test "shouts use the existing audible and anonymous display semantics":
    var sim = startedObservationSim()
    sim.players[0].x = 200
    sim.players[0].y = 200
    sim.players[1].x = 200
    sim.players[1].y = 200
    sim.players[2].x = 200 + ShoutRange + 20
    sim.players[2].y = 200
    check sim.applyShout(0, "push left")

    let
      heard = sim.firstLightBodyInputs(1)
      unheard = sim.firstLightBodyInputs(2)
    check heard.shouts.len == 1
    check heard.shouts[0].eventId == sim.shoutObservations[0].eventId
    check heard.shouts[0].slotLetter ==
      sim.shoutIdentityName(sim.recentShouts[0])
    check heard.shouts[0].text == "push left"
    check unheard.shouts.len == 0
    check sim.shoutObservations[0].sourceSlot == sim.players[0].joinOrder

    inc sim.seatLifeGenerations[sim.players[0].joinOrder]
    check sim.firstLightBodyInputs(1).shouts[0].slotLetter ==
      heard.shouts[0].slotLetter

    let listenerSlot = sim.players[1].joinOrder
    sim.removePlayerAt(0)
    let listenerIndex = sim.playerIndexForSlot(listenerSlot)
    let departed = sim.firstLightBodyInputs(listenerIndex)
    check departed.shouts.len == 1
    check departed.shouts[0].eventId == heard.shouts[0].eventId
    check departed.shouts[0].slotLetter == IdentityNameUnknown
    discard sim.addPlayer("observation-0", requestedSlot = 0, trusted = true)
    let reusedListenerIndex = sim.playerIndexForSlot(listenerSlot)
    sim.players[reusedListenerIndex].x = sim.recentShouts[0].x
    sim.players[reusedListenerIndex].y = sim.recentShouts[0].y
    let reused = sim.firstLightBodyInputs(reusedListenerIndex)
    check reused.shouts.len == 1
    check reused.shouts[0].slotLetter == IdentityNameUnknown

  test "current grenade and cone hazards are fogged while own throw is exact":
    var sim = startedObservationSim(2)
    let
      viewer = 0
      attacker = 1
      viewerSlot = sim.players[viewer].joinOrder
      center = sim.players[viewer].bodyPoint
    sim.airborneGrenades.add AirborneGrenade(
      sx: center.x, sy: center.y, tx: center.x + 20, ty: center.y,
      launchTick: sim.tickCount, flightTicks: 12,
      thrower: viewer, throwerSlot: viewerSlot, throwerAccount: 0,
      observationId: 201)
    sim.players[attacker].x = sim.players[viewer].x + 40
    sim.players[attacker].y = sim.players[viewer].y
    sim.players[attacker].arcTicksLeft = SprayPaintActiveTicks
    sim.players[attacker].arcAimBrads = bradsOfVector(-40, 0)
    sim.fovCaches.setLen(0)

    let visible = sim.firstLightBodyInputs(viewer)
    check visible.hazards.grenades.len == 1
    check visible.hazards.grenades[0].eventId == 201
    check visible.hazards.ownThrow.isSome
    check visible.hazards.ownThrow.get.target == (center.x + 20, center.y)
    var foundCone = false
    for spray in visible.hazards.sprays:
      if spray.kind == bshVisibleCone:
        foundCone = true
        check spray.attackerSeat == sim.players[attacker].joinOrder
        check spray.coversSelf
    check foundCone

    sim.players[viewer].alive = false
    sim.fovCaches.setLen(0)
    let dead = sim.firstLightBodyInputs(viewer)
    check dead.hazards.grenades.len == 0
    for spray in dead.hazards.sprays:
      check spray.kind != bshVisibleCone

  test "a produced blast reaches every admitted body on the next boundary":
    for playbackSpeed in [1, 4]:
      var sim = startedObservationSim(2)
      sim.airborneGrenades.add AirborneGrenade(
        sx: 500, sy: 500, tx: 500, ty: 500,
        launchTick: sim.tickCount, flightTicks: 1,
        thrower: -1, throwerSlot: -1, throwerAccount: -1,
        observationId: 301)
      check sim.firstLightBodyInputs(0).hazards.blastCues.len == 0
      check sim.firstLightBodyInputs(1).hazards.blastCues.len == 0
      let idle = newSeq[InputState](sim.players.len)
      for substep in 0 ..< playbackSpeed:
        if substep > 0:
          check sim.firstLightBodyInputs(0).hazards.blastCues.len == 1
          check sim.firstLightBodyInputs(1).hazards.blastCues.len == 1
        sim.step(idle, idle)
      check sim.firstLightBodyInputs(0).hazards.blastCues.len == 1
      check sim.firstLightBodyInputs(1).hazards.blastCues.len == 1
      check sim.blastObservations.len == 1

  test "gun damage and credited kills populate the authoritative records":
    var sim = startedObservationSim(2)
    let
      shooter = 0
      victim = 1
      sx = sim.players[shooter].x
      sy = sim.players[shooter].y
    sim.players[victim].x = sx + 12
    sim.players[victim].y = sy
    sim.players[victim].hp = 1
    sim.players[shooter].aimBrads = bradsOfVector(12, 0)
    sim.players[shooter].fireCooldown = 0
    sim.resolveSimultaneousFire([shooter])
    check not sim.players[victim].alive
    check sim.aggressorObservations.len == 1
    check sim.aggressorObservations[0].victimSlot ==
      sim.players[victim].joinOrder
    check sim.publicKillObservations.len == 1
    check sim.publicKillObservations[0].killerTeam ==
      sim.players[shooter].team

  test "a hidden spray hit yields anonymous impact and aggressor records":
    var sim = startedObservationSim(2)
    let
      attacker = 0
      victim = 1
      origin = sim.players[attacker].bodyPoint
      heading = sim.players[attacker].aimBrads
      (ux, uy) = aimVector(heading)
      victimCenter = (
        x: origin.x + int(round(ux * 120.0)),
        y: origin.y + int(round(uy * 120.0)))
    sim.players[victim].x = victimCenter.x - CollisionW div 2
    sim.players[victim].y = victimCenter.y - CollisionH div 2
    sim.players[victim].aimBrads = heading
    sim.players[attacker].hasSprayPaint = true
    sim.players[attacker].fireCooldown = 0
    sim.startArcFire(attacker)
    check victim in sim.selectArcVictims(attacker)
    sim.resolveActiveArcCones()

    check sim.aggressorObservations.len == 1
    check sim.aggressorObservations[0].attackerSlot == -1
    check sim.sprayImpactObservations.len == 1
    let inputs = sim.firstLightBodyInputs(victim)
    check inputs.aggressorEvents.len == 1
    check inputs.aggressorEvents[0].seat.isNone
    check inputs.hazards.sprays.len >= 1
    check inputs.hazards.sprays[0].kind == bshAnonymousImpact

  test "observation state is hash-excluded and survives keyframes":
    var sim = startedObservationSim(2)
    sim.airborneGrenades.add AirborneGrenade(
      sx: 10, sy: 20, tx: 30, ty: 40,
      launchTick: sim.tickCount, flightTicks: 12,
      thrower: 0, throwerSlot: 0, throwerAccount: 0)
    let originalHash = sim.gameHash()
    sim.airborneGrenades[0].observationId = 401
    sim.aggressorObservations.add AggressorObservation(
      eventId: 402, tick: sim.tickCount, victimSlot: 0,
      victimLifeGeneration: sim.seatLifeGenerations[0],
      dirBrads: 8, attackerSlot: 1)
    sim.publicKillObservations.add KillObservation(
      eventId: 403, tick: sim.tickCount, killerTeam: Blue, victimSlot: 0)
    sim.blastObservations.add BlastObservation(
      eventId: 404, tick: sim.tickCount, x: 30, y: 40,
      audience: sim.admitted([0, 1]))
    sim.sprayImpactObservations.add SprayImpactObservation(
      eventId: 405, tick: sim.tickCount, x: 50, y: 60,
      incomingDirBrads: 9, audience: sim.admitted([0]))
    sim.shoutObservations.add ShoutObservation(
      eventId: 406, tick: sim.tickCount, sourceSlot: 0,
      address: sim.players[0].address)
    check sim.gameHash() == originalHash

    let bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.airborneGrenades[0].observationId == 401
    check restored.aggressorObservations == sim.aggressorObservations
    check restored.publicKillObservations == sim.publicKillObservations
    check restored.blastObservations == sim.blastObservations
    check restored.sprayImpactObservations == sim.sprayImpactObservations
    check restored.shoutObservations == sim.shoutObservations

  test "body state caps observations after priority sorting":
    var sim = startedObservationSim(1)
    let body = activateSeatBody(newBodyMap(sim.gameMap), 0, sim.config.gunRange)
    var inputs = sim.firstLightBodyInputs(0)
    for index in 0 ..< 40:
      let tick = uint32(index)
      inputs.killFeed.add KillEvent(
        eventId: uint64(500 + index), tick: tick,
        killerTeam: Red, victimSeat: 0)
      inputs.aggressorEvents.add AggressorEvent(
        eventId: uint64(600 + index), tick: tick,
        dirBrads: index mod AimBradsTurn, seat: none(int))
      inputs.shouts.add ShoutEvent(
        eventId: uint64(700 + index), team: Team(index mod 16),
        slotLetter: "slot-" & $index, text: "go",
        pos: (index, index), tick: tick)
      inputs.hazards.grenades.add BodyGrenadeHazard(
        eventId: uint64(800 + index), pos: (index, index),
        predictedBlastPos: (index, index), ticksToBlast: index)
      inputs.hazards.blastCues.add BodyBlastCue(
        eventId: uint64(900 + index), pos: (index, index), tick: tick)
      inputs.hazards.sprays.add BodySprayHazard(
        eventId: uint64(1000 + index), tick: tick,
        kind: bshAnonymousImpact, impactPos: (index, index),
        incomingDirBrads: index mod AimBradsTurn)
    body.updateBelief(inputs, 40)
    check body.killFeed.len == 32
    check body.aggressorEvents.len == 16
    check body.shouts.len == 32
    check body.hazards.grenades.len == 8
    check body.hazards.blastCues.len == 4
    check body.hazards.sprays.len == 8
    check body.killFeed[0].tick == 39
    check body.aggressorEvents[0].tick == 39
    check body.shouts[0].tick == 39
    check body.hazards.grenades[0].ticksToBlast == 0
    check body.hazards.blastCues[0].tick == 39
    check body.hazards.sprays[0].tick == 39
