## S2 LOOT REWORK — per-row lever-liveness tests (2026-09-01 lane).
##
## Every row of the loot rework is config-gated and DARK by default, and this
## repo's own history says a flag that "reads as live" can still have a NULL
## input — so each suite below proves BOTH directions on the REAL mechanism
## path (weapon fire, step-loop pickups, the downed-state machine), never by
## restating config prose:
##   * dark: the default config carries none of the new keys, places none of
##     the new pickups, and kills exactly as before;
##   * armed: the flag observably changes behavior.
##
## Rows: (1) hitPoints is live under brMode (4/5-hp BR variants are a config
## edit, CTF's default 3 is untouched); (2) medKitCount caps/empties the kit
## family and bandages are carryable +1 hp self-heals; (3) lootStart spawns
## everyone unarmed and gates the gun on looting BOTH the marker and the
## hopper; (4) downedMode turns lethal hits into the ruled ghost-tag-revive
## shape (no down cap, escalating bleed-out, gun-splat confirm, adjacency
## revive); (5) map scale is a generator knob (tools/brmapkit --scale), not
## an engine mechanism, so it has no suite here.

import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/[sim, events, arena, broadcast]

proc brConfig(): GameConfig =
  result = defaultGameConfig()
  result.brMode = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  ## A started game with `seats` players dealt round-robin (0,2.. Red,
  ## 1,3.. Blue on two teams), tier-2 events on.
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc pointBlank(sim: var SimServer, shooter, target: int) =
  ## Stands the target one body-width east of the shooter, aim locked on.
  sim.players[shooter].x = 300
  sim.players[shooter].y = 300
  sim.players[shooter].aimBrads = 0            # east
  sim.players[shooter].fireCooldown = 0
  sim.players[target].x = 300 + 30
  sim.players[target].y = 300

proc eventsOf(sim: SimServer, kind: SimEventKind): seq[SimEvent] =
  for event in sim.events:
    if event.kind == kind:
      result.add event

proc stepIdle(sim: var SimServer, ticks: int) =
  for _ in 0 ..< ticks:
    sim.step(sim.none(), sim.none())

suite "loot rework config surface (all dark by default)":
  test "defaults are dark and the default echo carries none of the keys":
    let config = defaultGameConfig()
    check config.medKitCount == -1
    check config.bandagePickups == 0
    check config.lootStart == false
    check config.downedMode == false
    check config.downedBleedOutTicks == DownedBleedOutTicksDefault
    check config.downedReviveTicks == DownedReviveTicksDefault
    check config.downedEscalation == true
    let echoed = parseJson(config.configJson())
    for key in ["medKitCount", "bandagePickups", "lootStart", "downedMode",
        "downedBleedOutTicks", "downedReviveTicks", "downedEscalation"]:
      check not echoed.hasKey(key)

  test "armed keys round-trip through config JSON":
    var config = defaultGameConfig()
    config.update("""{"brMode": true, "lootStart": true, "downedMode": true,
      "downedBleedOutTicks": 120, "downedReviveTicks": 24,
      "downedEscalation": false, "medKitCount": 0, "bandagePickups": 6}""")
    check config.lootStart and config.downedMode
    check config.downedBleedOutTicks == 120
    check config.downedReviveTicks == 24
    check config.downedEscalation == false
    check config.medKitCount == 0
    check config.bandagePickups == 6
    let echoed = parseJson(config.configJson())
    check echoed["lootStart"].getBool
    check echoed["downedMode"].getBool
    check echoed["downedBleedOutTicks"].getInt == 120
    check echoed["downedReviveTicks"].getInt == 24
    check echoed["downedEscalation"].getBool == false
    check echoed["medKitCount"].getInt == 0
    check echoed["bandagePickups"].getInt == 6

  test "lootStart and downedMode refuse a non-BR config":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"lootStart": true}""")
    var config2 = defaultGameConfig()
    expect CtfError:
      config2.update("""{"downedMode": true}""")

  test "new event kinds have wire keys and stable tail ordinals":
    check key(Downed) == "downed"
    check key(Revived) == "revived"
    # Appended AFTER every pre-existing kind: archived ordinals unchanged.
    check ord(Downed) == ord(LevelUp) + 1
    check ord(Revived) == ord(Downed) + 1

  test "an existing map's spec pins no crate keys; authored pools round-trip":
    let sim = initCtfForTest(defaultGameConfig())
    let bare = parseJson(mapSpecJson(sim.gameMap))
    check not bare.hasKey("weaponSpawns")
    check not bare.hasKey("hopperSpawns")
    var authored = sim.gameMap
    authored.weaponSpawns = @[MapPoint(x: 301, y: 302)]
    authored.hopperSpawns = @[MapPoint(x: 401, y: 402)]
    let reread = mapFromSpecJson(mapSpecJson(authored))
    check reread.weaponSpawns == @[MapPoint(x: 301, y: 302)]
    check reread.hopperSpawns == @[MapPoint(x: 401, y: 402)]

suite "row 1 — hitPoints is a LIVE lever under brMode":
  test "a 4-hp BR seat takes exactly 4 gun hits through the real fire path":
    var config = brConfig()
    config.hitPoints = 4
    var sim = startedGame(config, 2)
    check sim.players[0].hp == 4
    check sim.players[1].hp == 4
    sim.pointBlank(0, 1)
    for shot in 1 .. 3:
      sim.armToFire(0)
      sim.tryFire(0)
      check sim.players[1].alive
      check sim.players[1].hp == 4 - shot
    sim.armToFire(0)
    sim.tryFire(0)
    check not sim.players[1].alive

  test "a 5-hp BR seat spawns at 5 and survives 4 hits":
    var config = brConfig()
    config.hitPoints = 5
    var sim = startedGame(config, 2)
    check sim.players[1].hp == 5
    sim.pointBlank(0, 1)
    for _ in 1 .. 4:
      sim.armToFire(0)
      sim.tryFire(0)
    check sim.players[1].alive
    check sim.players[1].hp == 1

  test "CTF's default stays 3-shot":
    check defaultGameConfig().hitPoints == 3
    let sim = startedGame(defaultGameConfig(), 2)
    check sim.players[0].hp == 3

suite "row 2 — med-kit cap and carryable bandages":
  test "medKitCount 0 empties the kit family; -1 keeps the map's own set":
    var config = brConfig()
    config.medKitCount = 0
    let sim = startedGame(config, 2)
    check sim.medKitSpawns.len == 0
    let dark = startedGame(brConfig(), 2)
    check dark.medKitSpawns.len > 0

  test "bandage spawns place only when armed and are picked up by touch":
    let dark = startedGame(brConfig(), 2)
    check dark.bandageSpawns.len == 0
    var config = brConfig()
    config.medKitCount = 0       # the ruled test arm: bandages INSTEAD of kits
    config.bandagePickups = 3
    var sim = startedGame(config, 2)
    check sim.bandageSpawns.len == 3
    sim.centerOn(0, sim.bandageSpawns[0].x, sim.bandageSpawns[0].y)
    sim.stepIdle(1)
    check sim.players[0].bandages == 1
    check not sim.bandageSpawns[0].present
    let picks = sim.eventsOf(Pickup)
    check picks.len >= 1
    check picks[^1].item == "bandage"

  test "the pocket caps at BandageCarryCap":
    var config = brConfig()
    config.medKitCount = 0
    config.bandagePickups = 3
    var sim = startedGame(config, 2)
    sim.players[0].bandages = BandageCarryCap
    sim.centerOn(0, sim.bandageSpawns[0].x, sim.bandageSpawns[0].y)
    sim.stepIdle(1)
    check sim.players[0].bandages == BandageCarryCap
    check sim.bandageSpawns[0].present

  test "a bandage self-applies +1 hp after the calm window, one per window":
    var config = brConfig()
    config.medKitCount = 0
    config.bandagePickups = 3
    var sim = startedGame(config, 2)
    sim.players[0].hp = 1
    sim.players[0].bandages = 2
    # Mid-combat (fresh damage stamp): no heal yet.
    sim.players[0].lastDamageTick = sim.tickCount
    sim.stepIdle(1)
    check sim.players[0].hp == 1
    # Calm window elapsed: exactly ONE bandage applies.
    sim.players[0].lastDamageTick = sim.tickCount - BandageApplyTicks
    sim.stepIdle(1)
    check sim.players[0].hp == 2
    check sim.players[0].bandages == 1
    # The clock restarted: the second bandage waits its own window out.
    sim.stepIdle(1)
    check sim.players[0].hp == 2
    let heals = sim.eventsOf(Heal)
    check heals.len == 1
    check heals[0].weapon == "bandage"
    check heals[0].amount == 1

  test "a bandage never lifts hp above the seat's max":
    var config = brConfig()
    config.medKitCount = 0
    config.bandagePickups = 1
    var sim = startedGame(config, 2)
    sim.players[0].bandages = 1
    sim.players[0].lastDamageTick = sim.tickCount - BandageApplyTicks
    sim.stepIdle(1)
    check sim.players[0].hp == 3          # untouched: already at max
    check sim.players[0].bandages == 1    # not consumed

suite "row 3 — loot-start: unarmed spawn, marker+hopper BOTH to shoot":
  test "dark BR seats spawn armed and fire exactly as before":
    var sim = startedGame(brConfig(), 2)
    check sim.weaponSpawns.len == 0
    check sim.hopperSpawns.len == 0
    sim.pointBlank(0, 1)
    check sim.canFire(0)

  test "lootStart spawns everyone unarmed with crates on the board":
    var config = brConfig()
    config.lootStart = true
    var sim = startedGame(config, 2)
    for i in 0 ..< sim.players.len:
      check not sim.players[i].hasGun
      check not sim.players[i].hasHopper
    check sim.weaponSpawns.len > 0    # fallback: the grenade pickup points
    check sim.hopperSpawns.len > 0    # fallback: the med-kit points
    sim.players[0].fireCooldown = 0
    check not sim.canFire(0)

  test "the gun needs BOTH halves — marker alone stays silent":
    var config = brConfig()
    config.lootStart = true
    var sim = startedGame(config, 2)
    sim.centerOn(0, sim.weaponSpawns[0].x, sim.weaponSpawns[0].y)
    sim.stepIdle(1)
    check sim.players[0].hasGun
    check not sim.players[0].hasHopper
    sim.players[0].fireCooldown = 0
    check not sim.canFire(0)
    sim.centerOn(0, sim.hopperSpawns[0].x, sim.hopperSpawns[0].y)
    sim.stepIdle(1)
    check sim.players[0].hasHopper
    sim.players[0].fireCooldown = 0
    check sim.canFire(0)
    let picks = sim.eventsOf(Pickup)
    var looted: seq[string]
    for p in picks:
      if p.source == 0 and p.item in ["gun", "hopper"]:
        looted.add p.item
    check "gun" in looted and "hopper" in looted

  test "a crate serves one cog and never refills":
    var config = brConfig()
    config.lootStart = true
    var sim = startedGame(config, 2)
    sim.centerOn(0, sim.weaponSpawns[0].x, sim.weaponSpawns[0].y)
    sim.stepIdle(1)
    check not sim.weaponSpawns[0].present
    # Force the (inert) respawn timer far past due: still no refill,
    # because no code path refills this family.
    sim.weaponSpawns[0].respawnAt = sim.tickCount - 1
    sim.centerOn(0, 300, 300)
    sim.stepIdle(3)
    check not sim.weaponSpawns[0].present

  test "an armed cog walks over a crate without consuming it":
    var config = brConfig()
    config.lootStart = true
    var sim = startedGame(config, 2)
    sim.players[0].hasGun = true
    sim.centerOn(0, sim.weaponSpawns[0].x, sim.weaponSpawns[0].y)
    sim.stepIdle(1)
    check sim.weaponSpawns[0].present

proc downedConfig(): GameConfig =
  result = brConfig()
  result.downedMode = true
  result.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
  result.downedReviveTicks = 5

suite "row 4 — downed-state: ghost, tag revive, bleed-out, splat":
  test "dark: a lethal hit still kills on the spot":
    var sim = startedGame(brConfig(), 2)
    sim.killPlayer(1, 0)
    check not sim.players[1].alive
    check not sim.players[1].downed

  test "armed: a lethal hit downs into a frozen ghost, Death deferred":
    var sim = startedGame(downedConfig(), 4)
    # Spread the board first: home clusters can put the ghost's teammate
    # inside DownedTagRange, and an accidental tag would revive it mid-test.
    sim.centerOn(1, 400, 300)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.centerOn(3, 700, 500)
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    check sim.players[1].alive          # a ghost is revivable, not dead
    check sim.players[1].hp == 0
    check sim.players[1].downedCount == 1
    check sim.eventsOf(Downed).len == 1
    check sim.eventsOf(Death).len == 0
    check sim.players[1].deaths == 0
    # Frozen: held movement input goes nowhere.
    let ghostX = sim.players[1].x
    var held = sim.none()
    held[1].right = true
    for _ in 0 ..< 10:
      sim.step(held, sim.none())
    check sim.players[1].x == ghostX
    # Frozen trigger: cooldown clear changes nothing.
    sim.players[1].fireCooldown = 0
    check not sim.canFire(1)

  test "dark: the roster wire never carries a downed key":
    # The spectator/replay BOARD (buildStateJson -> the wasm decoder ->
    # broadcast_core.js) has no baked "downed corpse" sprite pool to fall
    # back on the way the POV ghost view does -- it reads this roster flag
    # and fades the rig at draw time (client/broadcast_core.js's
    # setDownedSeats/drawObject), so a dark game must never carry the key.
    var sim = startedGame(brConfig(), 2)
    sim.killPlayer(1, 0)
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 100, false, true, -1, -1
    ))
    for seat in state["roster"]:
      check not seat.hasKey("downed")

  test "armed: the roster wire flags exactly the downed seat":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.centerOn(3, 700, 500)
    sim.killPlayer(1, 0)
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 100, false, true, -1, -1
    ))
    check state["roster"].len == 4
    for seat in state["roster"]:
      check seat.hasKey("downed")
      let isGhostSeat = seat["s"].getInt == sim.players[1].joinOrder
      check seat["downed"].getBool == isGhostSeat

  test "an adjacent teammate tags the ghost back in at 1 hp":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 400 + DownedTagRange - 10, 300)   # teammate in tag range
    sim.centerOn(0, 900, 300)                          # enemies far away
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    sim.stepIdle(5)                                    # downedReviveTicks
    check not sim.players[1].downed
    check sim.players[1].alive
    check sim.players[1].hp == 1
    let revives = sim.eventsOf(Revived)
    check revives.len == 1
    check revives[0].source == 3
    check revives[0].target == 1

  test "a broken tag resets the revive channel":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 400 + 20, 300)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    sim.stepIdle(3)                                    # partial channel
    check sim.players[1].reviveProgress == 3
    sim.centerOn(3, 400 + DownedTagRange * 3, 300)     # tagger walks off
    sim.stepIdle(1)
    check sim.players[1].reviveProgress == 0
    check sim.players[1].downed

  test "an untagged ghost bleeds out into a real, attributed death":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 900, 500)                          # teammate out of range
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    let window = 3 * DownedMinBleedOutTicks
    sim.stepIdle(window - 1)
    check sim.players[1].downed                        # still hanging on
    sim.stepIdle(2)
    check not sim.players[1].downed
    check not sim.players[1].alive
    check sim.players[1].deaths == 1
    check sim.eventsOf(Death).len == 1

  test "escalation halves the second down's window; off keeps it flat":
    for escalation in [true, false]:
      var config = downedConfig()
      config.downedEscalation = escalation
      var sim = startedGame(config, 4)
      sim.centerOn(1, 400, 300)
      sim.centerOn(3, 400 + 20, 300)
      sim.centerOn(0, 900, 300)
      sim.centerOn(2, 900, 340)
      sim.killPlayer(1, 0)
      sim.stepIdle(5)                                  # tag back in
      check not sim.players[1].downed
      sim.centerOn(3, 900, 500)                        # tagger leaves
      sim.killPlayer(1, 0)                             # second down
      check sim.players[1].downedCount == 2
      # Halved window = max(3*min div 2, min): well under the base window.
      let halved = max(3 * DownedMinBleedOutTicks div 2,
        DownedMinBleedOutTicks)
      sim.stepIdle(halved + 1)
      if escalation:
        check not sim.players[1].alive                 # bled out early
      else:
        check sim.players[1].downed                    # flat window holds

  test "an enemy paintball splats the ghost with no second kill credit":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(3, 900, 500)
    sim.centerOn(2, 900, 340)
    sim.pointBlank(0, 1)
    sim.players[1].hp = 1
    sim.armToFire(0)
    sim.tryFire(0)                                     # the down
    check sim.players[1].downed
    check sim.players[0].kills == 1                    # credited at the down
    sim.armToFire(0)
    sim.tryFire(0)                                     # the splat confirm
    check not sim.players[1].downed
    check not sim.players[1].alive
    check sim.players[0].kills == 1                    # never double-counted
    check sim.eventsOf(Kill).len == 1
    check sim.eventsOf(Death).len == 1

  test "a teammate's stray paint never confirms":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    sim.pointBlank(3, 1)                               # TEAMMATE aims at ghost
    sim.armToFire(3)
    sim.tryFire(3)
    check sim.players[1].downed                        # still tag-able
    check sim.players[1].alive

  test "a fully-downed team fades out and the round resolves":
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(0, 300, 300)
    sim.centerOn(2, 300, 340)
    sim.centerOn(1, 500, 300)
    sim.centerOn(3, 500, 340)
    sim.killPlayer(1, 0)
    sim.killPlayer(3, 0)                               # last upright Blue
    sim.stepIdle(1)
    check not sim.players[1].alive
    check not sim.players[3].alive
    check sim.phase == GamePhase.GameOver
    check sim.winner == Red

  test "upright cogs walk straight through a ghost":
    var sim = startedGame(downedConfig(), 4)
    sim.blockAll()
    sim.openField(280, 280, 560, 340)
    sim.centerOn(1, 400, 300)                          # the ghost-to-be
    sim.centerOn(0, 340, 300)                          # enemy west of it
    sim.centerOn(2, 300, 330)
    sim.centerOn(3, 540, 330)
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    var held = sim.none()
    held[0].right = true
    for _ in 0 ..< 60:
      sim.step(held, sim.none())
    # Passed through the ghost's body, never bounced off it.
    check sim.players[0].x + CollisionW div 2 > 430

  test "going down clears the hazard clocks with the rest of the body":
    # (The hazard loops themselves also skip ghosts — updatePuddles/
    # updateZone — but both early-return on this zone-free, puddle-free
    # test arena, so the behavioral assertion here is the downPlayer reset;
    # the loop guards are exercised by any zone-armed BR episode.)
    var sim = startedGame(downedConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.centerOn(3, 700, 500)
    sim.players[1].zoneOutsideTicks = 7
    sim.players[1].puddleTicks = 7
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    check sim.players[1].zoneOutsideTicks == 0
    check sim.players[1].puddleTicks == 0

## row 5 — spawn-loot seeding (owner-approved starter fix, 2026-09-03 lane):
## ADDITIONAL marker/hopper crates seeded within `lootSpawnSeedRadius` of
## every spawn cluster (one per team; a BR duo's two seats already land
## within SpawnShareStagger of each other around one shared spawn point, see
## sim.nim's seedSpawnLoot), on top of resetLootCrates' own base placement
## (the map's authored pool or its grenade/med-kit fallback), which stays
## untouched. Dark by default (both counts 0); lootSpawnSeedGuns/Hoppers
## additionally require lootStart (a config that never places any crate
## family cannot seed extra ones into it).
proc twoTeamSeatedGame(config: GameConfig): SimServer =
  ## A started 4-seat BR game on the classic 2-team arena, round-robin
  ## seated Red,Blue,Red,Blue — so team Red is (p0, p2) and team Blue is
  ## (p1, p3), the SAME duo pairing row 4's downed-state suite already
  ## relies on (its tag-revive tests use p1/p3 as one team on purpose).
  startedGame(config, 4)

suite "row 5 — spawn loot seeding: additive crates near spawn clusters (dark by default)":
  test "defaults are dark and the default echo carries none of the keys":
    let config = defaultGameConfig()
    check config.lootSpawnSeedGuns == 0
    check config.lootSpawnSeedHoppers == 0
    check config.lootSpawnSeedRadius == 0
    let echoed = parseJson(config.configJson())
    for key in ["lootSpawnSeedGuns", "lootSpawnSeedHoppers", "lootSpawnSeedRadius"]:
      check not echoed.hasKey(key)

  test "dark: a lootStart game seeds nothing beyond the existing fallback":
    var config = brConfig()
    config.lootStart = true
    var sim = twoTeamSeatedGame(config)
    # Same fallback pools row 3's own dark-lootStart test asserts on
    # (grenade points for guns, med-kit points for hoppers) — untouched.
    check sim.weaponSpawns.len == sim.grenadeSpawns.len
    check sim.hopperSpawns.len ==
      sim.gameMap.medKitSpawns.len + sim.gameMap.medKitCandidates.len

  test "validation: negative counts/radius, and seeding without lootStart, all refuse":
    for badJson in [
        """{"brMode": true, "lootSpawnSeedGuns": -1}""",
        """{"brMode": true, "lootSpawnSeedHoppers": -1}""",
        """{"brMode": true, "lootSpawnSeedRadius": -1}""",
        """{"brMode": true, "lootSpawnSeedGuns": 2}""",              # no lootStart
        """{"brMode": true, "lootSpawnSeedHoppers": 2}"""]:          # no lootStart
      var config = defaultGameConfig()
      expect CtfError:
        config.update(badJson)
    # Positive counts DO validate once lootStart is armed alongside them.
    var ok = defaultGameConfig()
    ok.update("""{"brMode": true, "lootStart": true,
      "lootSpawnSeedGuns": 1, "lootSpawnSeedHoppers": 1}""")
    check ok.lootSpawnSeedGuns == 1

  test "armed keys round-trip through config JSON only when a count is positive":
    var config = defaultGameConfig()
    config.update("""{"brMode": true, "lootStart": true,
      "lootSpawnSeedGuns": 3, "lootSpawnSeedHoppers": 2,
      "lootSpawnSeedRadius": 48}""")
    check config.lootSpawnSeedGuns == 3
    check config.lootSpawnSeedHoppers == 2
    check config.lootSpawnSeedRadius == 48
    let echoed = parseJson(config.configJson())
    check echoed["lootSpawnSeedGuns"].getInt == 3
    check echoed["lootSpawnSeedHoppers"].getInt == 2
    check echoed["lootSpawnSeedRadius"].getInt == 48

  test "armed: seeded crates are appended ON TOP of the dark fallback, base entries untouched":
    var dark = brConfig()
    dark.lootStart = true
    let darkSim = twoTeamSeatedGame(dark)
    var armed = brConfig()
    armed.lootStart = true
    armed.lootSpawnSeedGuns = 3
    armed.lootSpawnSeedHoppers = 2
    armed.lootSpawnSeedRadius = 40
    var armedSim = twoTeamSeatedGame(armed)
    # The base pool is an untouched PREFIX, byte-identical to the dark run —
    # the existing global scatter is never rewritten, only appended to.
    check armedSim.weaponSpawns[0 ..< darkSim.weaponSpawns.len] ==
      darkSim.weaponSpawns
    check armedSim.hopperSpawns[0 ..< darkSim.hopperSpawns.len] ==
      darkSim.hopperSpawns
    # 2 teams (2 clusters) * 3 seeded guns / 2 seeded hoppers each, appended.
    check armedSim.weaponSpawns.len == darkSim.weaponSpawns.len + 2 * 3
    check armedSim.hopperSpawns.len == darkSim.hopperSpawns.len + 2 * 2

  test "every seeded crate lands on walkable ground (placement is a guarantee, not a filter)":
    var config = brConfig()
    config.lootStart = true
    config.lootSpawnSeedGuns = 5
    config.lootSpawnSeedHoppers = 5
    config.lootSpawnSeedRadius = 60
    var sim = twoTeamSeatedGame(config)
    for spawn in sim.weaponSpawns:
      check sim.canOccupy(spawn.x, spawn.y)
    for spawn in sim.hopperSpawns:
      check sim.canOccupy(spawn.x, spawn.y)

  test "duo-aware: each team's cluster carries >=2 reachable guns and >=2 hoppers for BOTH seats":
    var config = brConfig()
    config.lootStart = true
    config.lootSpawnSeedGuns = 2
    config.lootSpawnSeedHoppers = 2
    config.lootSpawnSeedRadius = 48
    var sim = twoTeamSeatedGame(config)   # Red: p0,p2  Blue: p1,p3
    proc withinReach(spawn: PickupSpawn, px, py, dist: int): bool =
      abs(spawn.x - px) <= dist and abs(spawn.y - py) <= dist
    # SpawnShareStagger covers the partner spread; +40px covers a couple of
    # early-game movement ticks (MaxSpeed 704/s at 24 ticks/s is ~29px/tick).
    let reach = config.lootSpawnSeedRadius + SpawnShareStagger + 40
    for pair in [(0, 2), (1, 3)]:
      let (a, b) = pair
      var guns, hoppers = 0
      for spawn in sim.weaponSpawns:
        if spawn.withinReach(sim.players[a].x, sim.players[a].y, reach) or
            spawn.withinReach(sim.players[b].x, sim.players[b].y, reach):
          inc guns
      for spawn in sim.hopperSpawns:
        if spawn.withinReach(sim.players[a].x, sim.players[a].y, reach) or
            spawn.withinReach(sim.players[b].x, sim.players[b].y, reach):
          inc hoppers
      check guns >= 2
      check hoppers >= 2

  test "a seeded crate loots by touch exactly like any other crate":
    var config = brConfig()
    config.lootStart = true
    config.lootSpawnSeedGuns = 2
    config.lootSpawnSeedHoppers = 2
    config.lootSpawnSeedRadius = 40
    var sim = twoTeamSeatedGame(config)
    # Appended last by seedSpawnLoot, so this is a SEEDED crate, not the
    # base fallback's.
    let seededGunX = sim.weaponSpawns[^1].x
    let seededGunY = sim.weaponSpawns[^1].y
    sim.centerOn(0, seededGunX, seededGunY)
    sim.stepIdle(1)
    check sim.players[0].hasGun
    check not sim.weaponSpawns[^1].present

  test "determinism: two fresh sims of the same seed seed identical crates":
    proc buildSim(): SimServer =
      var config = brConfig()
      config.lootStart = true
      config.lootSpawnSeedGuns = 3
      config.lootSpawnSeedHoppers = 3
      config.lootSpawnSeedRadius = 48
      config.seed = 424242
      twoTeamSeatedGame(config)
    let simA = buildSim()
    let simB = buildSim()
    check simA.weaponSpawns == simB.weaponSpawns
    check simA.hopperSpawns == simB.hopperSpawns
    # ...keyed on the identical anchors the two sims independently derived.
    for i in 0 ..< simA.players.len:
      check simA.players[i].homeX == simB.players[i].homeX
      check simA.players[i].homeY == simB.players[i].homeY
proc ffRecutConfig(): GameConfig =
  ## `downedConfig` (armed downedMode) plus the v13 multiplier recut, so
  ## `gloryFfIncidents` -- otherwise permanently 0, see `awardDeed`'s own
  ## dark/armed split -- actually moves and is observable.
  result = downedConfig()
  result.gloryMultiplierRecut = true

suite "Amendment 5 (glory-2, spec owner override) — FF prices at the DOWN, not the finalize":
  ## The confirmed hole: a lethal friendly hit under downedMode reaches
  ## `downPlayer` and returns before `killPlayer`'s priceTheKill block ever
  ## runs -- so `dTeamKill`/`gloryFfIncidents` minted only if the downed
  ## partner actually bled out. A revived FF was free: "spray your partner,
  ## tag them back up" cost nothing. The fix moves the mint to the down
  ## itself, once per incident, and guards `finalizeDowned`'s later
  ## re-entry into `killPlayer` off so the same incident never mints twice.
  test "armed: a friendly down mints once immediately, even if revived (the hole)":
    var sim = startedGame(ffRecutConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 400 + DownedTagRange - 10, 300)   # teammate: downer + reviver
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    let team = sim.players[1].team
    check sim.players[1].team == sim.players[3].team  # 1, 3 are teammates
    check sim.gloryFfIncidents[team] == 0
    check sim.deedCounts[dTeamKill] == 0
    sim.killPlayer(1, 3)                              # 3 downs its own teammate
    check sim.players[1].downed
    check sim.players[1].alive
    check sim.gloryFfIncidents[team] == 1              # minted AT THE DOWN
    check sim.deedCounts[dTeamKill] == 1
    # Revived before any bleed-out -- pre-fix this incident never re-entered
    # killPlayer's pricing at all, so it minted NOTHING. Post-fix: unchanged
    # from the down, no second mint from the revive either.
    sim.stepIdle(5)                                    # downedReviveTicks
    check not sim.players[1].downed
    check sim.players[1].alive
    check sim.gloryFfIncidents[team] == 1
    check sim.deedCounts[dTeamKill] == 1

  test "armed: a friendly down that bleeds out still mints exactly once (no double-mint)":
    var sim = startedGame(ffRecutConfig(), 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 900, 500)                          # teammate out of tag range
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    let team = sim.players[1].team
    sim.killPlayer(1, 3)                               # friendly down
    check sim.gloryFfIncidents[team] == 1
    check sim.deedCounts[dTeamKill] == 1
    let window = 3 * DownedMinBleedOutTicks
    sim.stepIdle(window + 1)                           # bleeds out -> finalizeDowned
    check not sim.players[1].downed
    check not sim.players[1].alive
    check sim.players[1].deaths == 1
    check sim.gloryFfIncidents[team] == 1               # NOT re-minted at finalize
    check sim.deedCounts[dTeamKill] == 1

  test "dark (non-downedMode) friendly kill mints dTeamKill exactly as before (regression)":
    var config = brConfig()
    config.gloryMultiplierRecut = true
    check config.downedMode == false
    var sim = startedGame(config, 4)
    let team = sim.players[1].team
    check sim.players[1].team == sim.players[3].team
    sim.killPlayer(1, 3)                                # friendly kill, no down state
    check not sim.players[1].downed
    check not sim.players[1].alive
    check sim.gloryFfIncidents[team] == 1
    check sim.deedCounts[dTeamKill] == 1
