## PERCEPTION (glory-2 §17), part 1/3 of the frame-loadout-flags increment:
## per-seat hasGun/hasHopper exposed on the replay frame (roster + the
## first-person self/map objects), gated by `frameLoadoutFlags`. The
## UNDERLYING hasGun/hasHopper fields already drive real gameplay
## (canFire, LOOT(s2)) — this flag gates PERCEPTION of them only. Two
## proof obligations, the increment's own contract:
##   * dark (flag off): roster/self/map JSON never carry the keys —
##     byte-identical to a build without this field, because the flag
##     drives no sim behavior of its own (gameHash-equal twin runs).
##   * armed: every row's hasGun/hasHopper is byte-exact against Player
##     state; classic (non-lootStart) spawn emits constant true/true; a
##     lootStart pickup sets it; a death drops it (gated on lootStart,
##     never on this flag — see sim.nim killPlayer); downed persists it;
##     a play-called give (test_give_item.nim's channel) transfers it
##     atomically on the wire — receiver true and giver false in the SAME
##     frame, never a frame with both or neither.

import
  helpers,
  std/[json, unittest],
  ctf/[sim, broadcast]

proc brConfig(): GameConfig =
  result = defaultGameConfig()
  result.brMode = true

proc lootConfig(): GameConfig =
  result = brConfig()
  result.lootStart = true

proc frameConfig(): GameConfig =
  result = brConfig()
  result.frameLoadoutFlags = true

proc lootFrameConfig(): GameConfig =
  result = lootConfig()
  result.frameLoadoutFlags = true

proc downedLootFrameConfig(): GameConfig =
  result = lootFrameConfig()
  result.downedMode = true
  result.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
  result.downedReviveTicks = 5

proc giveLootFrameConfig(): GameConfig =
  result = lootFrameConfig()
  result.giveItem = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  ## A started game with `seats` players dealt round-robin (0,2.. Red,
  ## 1,3.. Blue — so 0's duo partner is 2), same shape as test_give_item.
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc stepIdle(sim: var SimServer, ticks: int) =
  for _ in 0 ..< ticks:
    sim.step(sim.none(), sim.none())

proc roster(sim: SimServer): JsonNode =
  parseJson(sim.buildStateJson(
    newJArray(), false, 1, 100, false, true, -1, -1
  ))["roster"]

proc fpFrame(sim: SimServer, povSlot: int): JsonNode =
  let frame = sim.buildStateJson(
    events = newJArray(), playing = false, speed = 1, maxTick = 1000,
    looping = false, transportEnabled = true, mismatchTick = -1,
    povSlot = povSlot
  )
  let parsed = parseJson(frame)
  if parsed.hasKey("fp"): parsed["fp"] else: newJNull()

suite "frame loadout-flags config surface (dark by default, per-flag)":
  test "default is dark and the default echo carries no key":
    let config = defaultGameConfig()
    check config.frameLoadoutFlags == false
    check not parseJson(config.configJson()).hasKey("frameLoadoutFlags")

  test "armed key round-trips through config JSON, independent of lootStart":
    var config = defaultGameConfig()
    config.update("""{"frameLoadoutFlags": true}""")
    check config.frameLoadoutFlags
    check not config.lootStart
    check parseJson(config.configJson())["frameLoadoutFlags"].getBool

  test "the realized-config stamp pins the flag, false included by default":
    var config = defaultGameConfig()
    config.update("""{"stampRealizedConfig": true}""")
    let stamp = parseJson(config.realizedConfigStampJson())
    var saw = false
    for f in stamp["flagSet"]:
      if f.getStr == "frameLoadoutFlags=false":
        saw = true
    check saw

suite "dark: roster/self/map never carry hasGun/hasHopper":
  test "dark roster carries neither key on any seat":
    var sim = startedGame(lootConfig(), 4)     # lootStart armed, flag dark
    for seat in sim.roster:
      check not seat.hasKey("hasGun")
      check not seat.hasKey("hasHopper")

  test "dark self/map carry neither key":
    var sim = startedGame(lootConfig(), 2)
    let fp = sim.fpFrame(sim.players[0].joinOrder)
    check fp.kind == JObject
    check not fp["self"].hasKey("hasGun")
    check not fp["self"].hasKey("hasHopper")
    for p in fp["map"]["players"]:
      check not p.hasKey("hasGun")
      check not p.hasKey("hasHopper")

  test "armed-but-idle is gameHash-identical to a dark twin":
    # The flag drives JSON exposure only -- no sim behavior -- so arming it
    # alone (lootStart OFF on both sides) must never move the hash, even
    # under real combat stepping, not just idling.
    var dark = startedGame(brConfig(), 4)
    var armed = startedGame(frameConfig(), 4)
    for s in [0, 1, 2, 3]:
      dark.centerOn(s, 400 + s * 20, 300)
      armed.centerOn(s, 400 + s * 20, 300)
    dark.stepIdle(120)
    armed.stepIdle(120)
    check dark.gameHash() == armed.gameHash()

suite "armed: roster/self/map carry byte-exact hasGun/hasHopper":
  test "classic CTF (non-BR, non-lootStart) emits constant true/true":
    var config = defaultGameConfig()
    config.frameLoadoutFlags = true
    var sim = startedGame(config, 2)
    for seat in sim.roster:
      check seat["hasGun"].getBool
      check seat["hasHopper"].getBool
    sim.stepIdle(30)
    for seat in sim.roster:
      check seat["hasGun"].getBool
      check seat["hasHopper"].getBool

  test "BR non-lootStart also emits constant true/true, roster and self/map":
    var sim = startedGame(frameConfig(), 2)
    for seat in sim.roster:
      check seat["hasGun"].getBool
      check seat["hasHopper"].getBool
    let fp = sim.fpFrame(sim.players[0].joinOrder)
    check fp["self"]["hasGun"].getBool
    check fp["self"]["hasHopper"].getBool
    for p in fp["map"]["players"]:
      check p["hasGun"].getBool
      check p["hasHopper"].getBool

  test "lootStart spawns unarmed on the wire; a pickup flips it live":
    var sim = startedGame(lootFrameConfig(), 2)
    check not sim.roster[0]["hasGun"].getBool
    check not sim.roster[0]["hasHopper"].getBool
    sim.centerOn(0, sim.weaponSpawns[0].x, sim.weaponSpawns[0].y)
    sim.stepIdle(1)
    check sim.roster[0]["hasGun"].getBool
    check not sim.roster[0]["hasHopper"].getBool     # only the marker so far

  test "downed persists the flags; the eventual death-drop clears them":
    var sim = startedGame(downedLootFrameConfig(), 4)
    sim.players[1].hasGun = true
    sim.players[1].hasHopper = true
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 900, 500)             # teammate out of tag range
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    check sim.roster[1]["hasGun"].getBool       # persists through the down
    check sim.roster[1]["hasHopper"].getBool
    let window = 3 * DownedMinBleedOutTicks
    sim.stepIdle(window + 1)                    # bleed out -> finalizeDowned
    check not sim.players[1].downed
    check not sim.players[1].alive
    check not sim.roster[1]["hasGun"].getBool    # death-drop: cleared
    check not sim.roster[1]["hasHopper"].getBool

  test "a plain lootStart death (no downedMode) drops the loot immediately":
    var sim = startedGame(lootFrameConfig(), 2)
    sim.players[0].hasGun = true
    sim.players[0].hasHopper = true
    sim.killPlayer(0, 1)
    check not sim.players[0].alive
    check not sim.roster[0]["hasGun"].getBool
    check not sim.roster[0]["hasHopper"].getBool

  test "a death under classic (non-lootStart) never clears the constant flags":
    # The death-drop is gated on lootStart, never on frameLoadoutFlags: the
    # "classic emits constant true/true" contract must survive a death too.
    var sim = startedGame(frameConfig(), 2)
    sim.killPlayer(0, 1)
    check not sim.players[0].alive
    check sim.roster[0]["hasGun"].getBool
    check sim.roster[0]["hasHopper"].getBool

  test "a play-called give transfers the flag atomically on the wire":
    var sim = startedGame(giveLootFrameConfig(), 4)
    sim.players[0].hasGun = true
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "gun")
    sim.stepIdle(GiveChannelTicks - 1)
    # One tick short: still fully on the giver's row, wire and all.
    check sim.roster[0]["hasGun"].getBool
    check not sim.roster[2]["hasGun"].getBool
    sim.stepIdle(1)                              # the completion tick
    # Same frame: receiver true, giver false -- never both, never neither.
    check not sim.roster[0]["hasGun"].getBool
    check sim.roster[2]["hasGun"].getBool
