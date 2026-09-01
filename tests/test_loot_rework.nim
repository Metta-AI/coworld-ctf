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
