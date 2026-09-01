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
  ctf/[sim, events, arena]

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
