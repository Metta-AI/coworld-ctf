## Startup and config hygiene: a bad runtime config fails cleanly, the seed is
## randomised when unpinned, and both entrypoints exist.
import std/[json, os, strutils, unittest]
import pb_helpers

suite "squad mode arming (server.nim's socket-input-discard gate)":
  ## Regression for b25ee144 (2026-08-25): `DefaultCogsPerTeam` shipped at
  ## 4 alongside Paintball KOTH, so every variant that leaves `cogsPerTeam`
  ## unset -- every classic and BR variant in coworld_manifest_paintbot.json
  ## and coworld_manifest_br.json -- silently armed `squadModeArmed`
  ## (sim_config.nim), whose true branch is server.nim's `squadMode`: masks
  ## come from the KOTH DecisionEngine instead of real seat sockets, so
  ## every one of those episodes played with zero real input (verified
  ## against real round-3543 replays: 0 kills/0 captures across all 16
  ## seats). This asserts the exact predicate server.nim calls, not a
  ## restatement of it, so a future edit to squadModeArmed itself still
  ## trips this test.
  test "a default classic config (cogsPerTeam unset) does not arm squad mode":
    var config = defaultGameConfig()
    config.numAgents = 16
    check config.cogsPerTeam == 1
    check not squadModeArmed(config, replayLoaded = false)

  test "a KOTH-style config (cogsPerTeam=4, matching the paintball variant's pin) arms squad mode":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check config.numAgents > 0
    check config.cogsPerTeam == 4
    check squadModeArmed(config, replayLoaded = false)

  test "squad mode never arms over a loaded replay, regardless of cogsPerTeam":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check not squadModeArmed(config, replayLoaded = true)

suite "startup":
  test "an unparseable config raises a clean CtfError, not a traceback":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("{not json")
    var other = defaultGameConfig()
    expect CtfError:
      other.update("[1, 2, 3]")

  test "an out-of-range paintball field is rejected with a named message":
    var config = defaultGameConfig()
    try:
      config.update("""{"hillOwnPermille": 400}""")
      check false
    except CtfError as error:
      check "hillOwnPermille" in error.msg
    var second = defaultGameConfig()
    try:
      second.update("""{"loadout": "lasertag"}""")
      check false
    except CtfError as error:
      check "loadout" in error.msg
    var third = defaultGameConfig()
    try:
      third.update("""{"regimes": ["resident", "sightseeing"]}""")
      check false
    except CtfError as error:
      check "regimes" in error.msg

  test "paintBuff and hill both require floorPaint":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"paintBuff": true, "floorPaint": false}""")
    var second = defaultGameConfig()
    expect CtfError:
      second.update("""{"hill": true, "floorPaint": false}""")

  test "a pinned seed is honoured and echoed into the replay config":
    var config = defaultGameConfig()
    config.update(paintballConfigJson(seed = 424242))
    check config.seed == 424242
    let echoed = parseJson(config.configJson())
    check echoed["seed"].getInt() == 424242
    ## Every paintball field the viewer re-derives from must be in the echo.
    for key in ["num_agents", "cogsPerTeam", "loadout", "floorPaint",
                "paintBuff", "hill", "paintTile", "hillRadiusTiles",
                "hillOwnPermille", "hillDecisiveTicks", "paintSpeedOwnPct",
                "paintSpeedEnemyPct", "paintHealTicks", "sprayDamage",
                "regimes", "turnTicks", "wallClockBudgetSeconds"]:
      check echoed.hasKey(key)
    check echoed["regimes"][0].getStr() == "resident"

  test "the config echo round-trips through update unchanged":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    var round = defaultGameConfig()
    round.update(config.configJson())
    check round.configJson() == config.configJson()

  test "the gate-off default is the starter's game, untouched":
    let config = defaultGameConfig()
    check config.loadout == LoadoutCtf
    check not config.floorPaint
    check not config.paintBuff
    check not config.hill
    check config.sprayDamage == SprayPaintDamage
    check config.numAgents == 0

  test "the paintball loadout places NO pickups at all":
    ## Design §Loadout 3: grenades, med kits, shields, spray cans and cardboard
    ## barriers are skipped. The pickup/update path was already skipped, so
    ## nothing could be TAKEN — but the spawns were still drawn on the board and
    ## listed to the seats, so the picture and the LLM's view carried objects
    ## the rules do not have.
    var sim = newPaintballSim()
    check sim.paintballLoadout()
    check sim.medKitSpawns.len == 0
    check sim.shieldSpawns.len == 0
    check sim.sprayPaintSpawns.len == 0
    check sim.barrierSpawns.len == 0
    for spawn in sim.grenadeSpawns:
      check not spawn.present
    ## Every consumer keys off `present` / the family length — the seats'
    ## first-person item list (broadcast.firstPersonJson), the spectator's map
    ## items (broadcast.rosterJson) and all five board draw passes — so an
    ## empty family is the one place that makes them all agree with the rules.
    ## And the cog still holds its can: the loadout issues it for good.
    check sim.players[0].hasSprayPaint

  test "the ctf loadout still places the starter's pickups":
    ## The gate composes: a gate-off config plays the starter's rules, which is
    ## what keeps the inherited engine meaningful.
    var sim = newPaintballSim(paintballConfigJson(
      paintBuff = false, hill = false, floorPaint = false, loadout = "ctf"))
    check not sim.paintballLoadout()
    check sim.medKitSpawns.len > 0
    check sim.shieldSpawns.len > 0
    var anyGrenade = false
    for spawn in sim.grenadeSpawns:
      if spawn.present:
        anyGrenade = true
    check anyGrenade

  test "a seat's registration is durable on both ends":
    ## paintball round 3, 2026-08-25: champion #2 connected FIRST on slot 1.
    ## Joins are slot-sequential, so it was not admitted until slot 0 joined —
    ## and the lobby sends frames to an unadmitted socket, so its registration
    ## AND the single re-send keyed on the first received frame both landed
    ## while it had no seat index. The server dropped both (chatMessages.clear)
    ## and the champion played the scripted holdline baseline for the whole
    ## episode with no `register` record at all.
    let server = readFile("src/ctf/server.nim")
    ## The server HOLDS a registration it cannot apply yet, and re-seeds the
    ## table after the clear.
    check "var heldRegistrations: seq[(WebSocket, string)]" in server
    check "heldRegistrations.add((websocket, chatText))" in server
    let cleared = server.find("appState.chatMessages.clear()",
      server.find("heldRegistrations.add"))
    check cleared > 0
    check server.find("for (websocket, chatText) in heldRegistrations",
      cleared) > cleared
    ## And the seat keeps re-sending through the lobby instead of once.
    let player = readFile("src/paintball_player.nim")
    check "RegistrationResends = 10" in player
    check "resends < RegistrationResends" in player
    check "sessionFrames mod ResendEveryFrames == 1" in player
    ## It also never exits while the game is still serving: a dead socket is
    ## re-dialled (bounded) and re-registered, and only a session that received
    ## nothing — or an exhausted re-dial — exits, always 0.
    check "socket = dial(ReconnectAttempts)" in player
    check "if sessionFrames == 0 or reconnects >= ReconnectAttempts:" in player
    ## The session loop's only exit is quit(0) (the raid 0.1.3 scar: a player
    ## that exits 1 on a socket the game closed fails certification
    ## intermittently). The two quit(…, 1) paths above it are startup faults —
    ## no URL, and a game that never accepted a connection at all.
    check player.strip().endsWith("quit(0)")

  test "both entrypoints are declared in the Dockerfile and the manifest":
    ## ONE image, TWO entrypoints: /bin/ctf (which serves the paintball mode
    ## when the config gates it on) and /bin/paintball-player (the thin seat
    ## registrar the paintball policies run).
    let dockerfile = readFile("Dockerfile")
    check "src/paintball_player.nim" in dockerfile
    check "/bin/ctf" in dockerfile
    check "/bin/paintball-player" in dockerfile
    let manifest = parseJson(readFile("coworld_manifest_paintbot.json"))
    check manifest["game"]["runnable"]["run"][0].getStr() == "/bin/ctf"
    ## The paintball baselines are deliberately NOT manifest players: the
    ## certifier requires every declared player to occupy a certification
    ## slot, and the fixture is the classic 16-seat game. They are uploaded
    ## as ordinary policies (coworld upload-policy --run /bin/paintball-player
    ## --secret-env PLAYER_SCRIPTED=holdline|sprayer) instead.
    for player in manifest["player"]:
      check not player["id"].getStr().startsWith("paintball-")
