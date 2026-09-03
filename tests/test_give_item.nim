## S2 GIVE-ITEM (EXCHANGE) — lever-liveness tests (2026-09-03 lane).
##
## The mechanic is config-gated (`giveItem`) and DARK by default, and it is
## PLAY-CALLED ONLY by owner ruling (2026-09-02): proximity can never imply
## consent, so there is no auto-share path — no item ever moves without a
## declared handoff (declareHandoff, the engine seam for the play shell's
## HANDOFF play). Each suite proves BOTH directions on the real step-loop
## channel, never by restating config prose:
##   * dark: the default config carries no key, declarations are refused,
##     and the step loop is byte-identical (gameHash-equal twin runs);
##   * armed: a declared, held, in-range channel — and ONLY that — moves
##     the declared item and emits the ItemGive wire row byte-exactly.

import
  helpers,
  std/[json, unittest],
  ctf/[sim, events, broadcast]

proc brConfig(): GameConfig =
  result = defaultGameConfig()
  result.brMode = true

proc giveConfig(): GameConfig =
  result = brConfig()
  result.giveItem = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  ## A started game with `seats` players dealt round-robin (0,2.. Red,
  ## 1,3.. Blue on two teams — so 0's duo partner is 2), tier-2 events on.
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc eventsOf(sim: SimServer, kind: SimEventKind): seq[SimEvent] =
  for event in sim.events:
    if event.kind == kind:
      result.add event

proc stepIdle(sim: var SimServer, ticks: int) =
  for _ in 0 ..< ticks:
    sim.step(sim.none(), sim.none())

proc pocketed(sim: var SimServer, playerIndex, count: int) =
  ## Hands a seat `count` carried bandages directly (arrangement, not
  ## mechanism — the pickup path has its own suite in test_loot_rework).
  sim.players[playerIndex].bandages = count

suite "give-item config surface (dark by default)":
  test "default is dark and the default echo carries no key":
    let config = defaultGameConfig()
    check config.giveItem == false
    check not parseJson(config.configJson()).hasKey("giveItem")

  test "armed key round-trips through config JSON":
    var config = defaultGameConfig()
    config.update("""{"brMode": true, "giveItem": true}""")
    check config.giveItem
    check parseJson(config.configJson())["giveItem"].getBool

  test "giveItem refuses a non-BR config":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"giveItem": true}""")

  test "the event kind has a wire key and a stable tail ordinal":
    check key(ItemGive) == "item_give"
    # Appended AFTER every pre-existing kind: archived ordinals unchanged.
    check ord(ItemGive) == ord(Revived) + 1

  test "the channel constants derive from the revive channel's own":
    check GiveItemRange == DownedTagRange
    check GiveChannelTicks == DownedReviveTicksDefault

suite "consent gate — nothing moves without a declaration":
  test "dark: a declaration is refused and no state is touched":
    var sim = startedGame(brConfig(), 4)
    check not sim.declareHandoff(0, "bandage")
    check sim.players[0].giveDeclItem == ""

  test "armed, adjacent, holding items, NO declaration: nothing ever moves":
    # The owner's cover-huddle principle, tested literally: a duo camped
    # in-range for a long endgame stretch with full pockets trades nothing.
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 2)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + GiveItemRange - 10, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    sim.stepIdle(GiveChannelTicks * 4)
    check sim.players[0].bandages == 2
    check sim.players[2].bandages == 0
    check sim.eventsOf(ItemGive).len == 0

  test "armed-but-idle is gameHash-identical to a dark twin":
    var dark = startedGame(brConfig(), 4)
    var armed = startedGame(giveConfig(), 4)
    for s in [0, 1, 2, 3]:
      dark.centerOn(s, 400 + s * 20, 300)
      armed.centerOn(s, 400 + s * 20, 300)
    dark.stepIdle(120)
    armed.stepIdle(120)
    check dark.gameHash() == armed.gameHash()

  test "declaration guards: bad item, bad seat, dead giver all refuse":
    var sim = startedGame(giveConfig(), 4)
    check not sim.declareHandoff(0, "shield")
    check not sim.declareHandoff(-1, "bandage")
    check not sim.declareHandoff(99, "bandage")
    sim.players[0].alive = false
    check not sim.declareHandoff(0, "bandage")

  test "an empty item clears a standing declaration":
    var sim = startedGame(giveConfig(), 4)
    check sim.declareHandoff(0, "bandage")
    check sim.players[0].giveDeclItem == "bandage"
    check sim.declareHandoff(0, "")
    check sim.players[0].giveDeclItem == ""

suite "the declared channel — held adjacency transfers the item":
  test "a declared bandage crosses after the full held channel, byte-exact row":
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 2)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + GiveItemRange - 10, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "bandage")
    sim.stepIdle(GiveChannelTicks - 1)
    check sim.players[0].bandages == 2          # one tick short: nothing yet
    sim.stepIdle(1)
    check sim.players[0].bandages == 1
    check sim.players[2].bandages == 1
    check sim.players[0].giveDeclItem == ""     # declaration consumed
    check sim.players[0].handoffs == 1
    let gives = sim.eventsOf(ItemGive)
    check gives.len == 1
    let row = jsonRow(gives[0])
    # The dHandoff contract fields, byte-exact: actor/recipient/item/tick.
    check row["kind"].getStr == "item_give"
    check row["source"].getInt == 0             # actor = the giving seat
    check row["target"].getInt == 2             # recipient = the duo partner
    check row["item"].getStr == "bandage"
    check row["tick"].getInt == gives[0].tick
    check row["amount"].getInt == GiveChannelTicks
    # The full shared jsonRow column set rides along, same as every kind.
    for column in ["tick", "kind", "source", "target", "weapon", "amount",
        "hp", "blocked", "x", "y", "action_id", "heading_brads", "distance",
        "item", "content", "damages"]:
      check row.hasKey(column)

  test "a broken channel resets and needs the full hold again":
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 1)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "bandage")
    sim.stepIdle(GiveChannelTicks div 2)
    check sim.players[0].giveProgress == GiveChannelTicks div 2
    sim.centerOn(2, 400 + GiveItemRange * 3, 300)   # partner walks off
    sim.stepIdle(1)
    check sim.players[0].giveProgress == 0
    check sim.players[0].giveDeclItem == "bandage"  # declaration stands
    sim.centerOn(2, 400 + 20, 300)                  # back in range
    sim.stepIdle(GiveChannelTicks - 1)
    check sim.eventsOf(ItemGive).len == 0           # full hold required
    sim.stepIdle(1)
    check sim.eventsOf(ItemGive).len == 1

  test "a declared marker crosses only to an unarmed partner (lootStart)":
    var config = giveConfig()
    config.lootStart = true
    var sim = startedGame(config, 4)
    check not sim.players[0].hasGun and not sim.players[2].hasGun
    sim.players[0].hasGun = true                    # looted earlier
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "gun")
    sim.stepIdle(GiveChannelTicks)
    check not sim.players[0].hasGun
    check sim.players[2].hasGun
    check sim.eventsOf(ItemGive).len == 1
    check sim.eventsOf(ItemGive)[0].item == "gun"

  test "a hopper crosses the same way":
    var config = giveConfig()
    config.lootStart = true
    var sim = startedGame(config, 4)
    sim.players[0].hasHopper = true
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "hopper")
    sim.stepIdle(GiveChannelTicks)
    check not sim.players[0].hasHopper
    check sim.players[2].hasHopper

  test "a full recipient blocks the channel — guns never crowd a holder":
    # Without lootStart every seat holds the marker: the declared give can
    # never find a lacking recipient, so the channel must never advance.
    var sim = startedGame(giveConfig(), 4)
    check sim.players[0].hasGun and sim.players[2].hasGun
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "gun")
    sim.stepIdle(GiveChannelTicks * 2)
    check sim.players[0].hasGun and sim.players[2].hasGun
    check sim.players[0].giveProgress == 0
    check sim.eventsOf(ItemGive).len == 0

  test "a bandage pocket at cap blocks the channel":
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 1)
    sim.pocketed(2, BandageCarryCap)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "bandage")
    sim.stepIdle(GiveChannelTicks * 2)
    check sim.players[0].bandages == 1
    check sim.players[2].bandages == BandageCarryCap
    check sim.eventsOf(ItemGive).len == 0

  test "a dead partner blocks; a dead giver drops the declaration":
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 1)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    check sim.declareHandoff(0, "bandage")
    sim.players[2].alive = false
    sim.stepIdle(GiveChannelTicks * 2)
    check sim.players[0].bandages == 1
    check sim.eventsOf(ItemGive).len == 0
    sim.players[0].alive = false
    sim.stepIdle(1)
    check sim.players[0].giveDeclItem == ""

suite "give-item wire surfaces (arc feed)":
  test "dark: the roster wire never carries a handoff key":
    var sim = startedGame(brConfig(), 2)
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 100, false, true, -1, -1
    ))
    for seat in state["roster"]:
      check not seat.hasKey("handoff")

  test "armed: only a DECLARED giver's roster row carries the channel":
    var sim = startedGame(giveConfig(), 4)
    sim.pocketed(0, 1)
    sim.centerOn(0, 400, 300)
    sim.centerOn(2, 400 + 20, 300)
    sim.centerOn(1, 1200, 700)
    sim.centerOn(3, 1200, 740)
    let idle = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 100, false, true, -1, -1
    ))
    for seat in idle["roster"]:
      check not seat.hasKey("handoff")          # armed-but-idle: untouched
    check sim.declareHandoff(0, "bandage")
    sim.stepIdle(3)
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 100, false, true, -1, -1
    ))
    var flagged = 0
    for seat in state["roster"]:
      if seat.hasKey("handoff"):
        inc flagged
        check seat["handoff"]["item"].getStr == "bandage"
        check seat["handoff"]["progress"].getInt == 3
        check seat["handoff"]["needed"].getInt == GiveChannelTicks
    check flagged == 1
