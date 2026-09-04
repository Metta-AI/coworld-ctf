## S2 DROP (button-chord item drop) — lever-liveness + hash-stability tests
## (2026-09-03 dropchord lane).
##
## The mechanic is config-gated (`dropItem`) and DARK by default. The drop is
## a CHORD: the aim-pair (ButtonB and ButtonSelect together), which the engine
## has always ignored for aim (`applyInput` turns only on `b != select`), so
## the combination was a dead no-op before this feature — which is exactly why
## it is safe to repurpose WITHOUT a new bit. Held DropChordTicks WHILE
## carrying a droppable, it spills the highest-priority carried item (spray
## first) to the ground as an open, no-respawn item. Each suite proves BOTH
## directions on the real step loop, never by restating config prose:
##   * dark: the chord is inert — twin runs (chord vs idle) are gameHash-equal
##     every tick, no item ever drops, and the aim never moves (the dead-combo
##     proof, so no archived replay ever depended on it);
##   * armed: the chord — held long enough, hands full — drops exactly one
##     item, unlocks the gun when that item is the spray can, and the drop is
##     an OPEN pickup any cog may steal.

import
  helpers,
  std/[json, os, unittest],
  ctf/[sim, events]

proc brConfig(): GameConfig =
  result = defaultGameConfig()
  result.brMode = true

proc dropConfig(): GameConfig =
  result = brConfig()
  result.dropItem = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc eventsOf(sim: SimServer, kind: SimEventKind): seq[SimEvent] =
  for event in sim.events:
    if event.kind == kind:
      result.add event

proc holdChord(sim: var SimServer, playerIndex, ticks: int) =
  ## Drives the aim-pair drop chord (b+select) for one seat, `ticks` ticks.
  var held = sim.none()
  held[playerIndex].b = true
  held[playerIndex].select = true
  for _ in 0 ..< ticks:
    sim.step(held, held)

# ─────────────────────────────────────────────────────────────────────────
suite "drop-item config surface (dark by default)":
  test "default is dark and the default echo carries no key":
    let config = defaultGameConfig()
    check config.dropItem == false
    check not parseJson(config.configJson()).hasKey("dropItem")

  test "an armed config echoes exactly the gate key":
    var config = dropConfig()
    check parseJson(config.configJson())["dropItem"].getBool()

  test "the schema key is consumed: a non-default sample changes the config":
    var config = defaultGameConfig()
    config.update("""{"dropItem": true}""")
    check config.dropItem == true

# ─────────────────────────────────────────────────────────────────────────
suite "the aim-pair chord is a dead no-op when dark (hash-stable)":
  test "chord-held and idle runs share the gameHash every tick":
    var a = startedGame(brConfig(), 4)  # dropItem OFF
    var b = startedGame(brConfig(), 4)
    var held = a.none()
    held[0].b = true
    held[0].select = true
    for _ in 0 ..< 60:
      a.step(held, held)
      b.step(b.none(), b.none())
      check a.gameHash() == b.gameHash()

  test "even hands-full, a dark chord drops nothing":
    var sim = startedGame(brConfig(), 2)  # dropItem OFF
    sim.players[0].hasSprayPaint = true
    sim.holdChord(0, DropChordTicks * 3)
    check sim.players[0].hasSprayPaint      # still held
    check sim.droppedItems.len == 0
    check sim.eventsOf(ItemDrop).len == 0
    check sim.players[0].dropChordTicks == 0

  test "b+select leaves the aim unchanged — it is the dead combo":
    var sim = startedGame(brConfig(), 2)
    let aim0 = sim.players[0].aimBrads
    sim.holdChord(0, 20)
    check sim.players[0].aimBrads == aim0

# ─────────────────────────────────────────────────────────────────────────
suite "armed: the drop chord spills the held item":
  test "dropping the spray can clears the lock and hands the gun back":
    var sim = startedGame(dropConfig(), 2)
    sim.players[0].hasSprayPaint = true
    check not sim.canFire(0)                # spray lock: gun is out
    sim.holdChord(0, DropChordTicks)
    check not sim.players[0].hasSprayPaint  # the can is gone
    check sim.canFire(0)                    # the gun is back
    check sim.droppedItems.len == 1
    check sim.droppedItems[0].kind == dkSpray
    let drops = sim.eventsOf(ItemDrop)
    check drops.len == 1
    check drops[0].source == 0
    check drops[0].item == "spray_can"

  test "held-N gate: one tick short never drops; the Nth tick does":
    var sim = startedGame(dropConfig(), 2)
    sim.players[0].hasSprayPaint = true
    sim.holdChord(0, DropChordTicks - 1)
    check sim.players[0].hasSprayPaint      # not yet
    check sim.droppedItems.len == 0
    sim.holdChord(0, 1)                     # the Nth consecutive tick
    check not sim.players[0].hasSprayPaint
    check sim.droppedItems.len == 1

  test "releasing the chord resets the counter (one hold = one drop)":
    var sim = startedGame(dropConfig(), 2)
    sim.players[0].hasSprayPaint = true
    sim.holdChord(0, DropChordTicks - 1)
    sim.step(sim.none(), sim.none())        # release: counter resets
    check sim.players[0].dropChordTicks == 0
    sim.holdChord(0, DropChordTicks - 1)    # a fresh short hold
    check sim.players[0].hasSprayPaint      # still nothing dropped
    check sim.droppedItems.len == 0

  test "context gate: an empty-handed chord never trips the counter":
    var sim = startedGame(dropConfig(), 2)
    check not sim.holdsDroppable(0)
    sim.holdChord(0, DropChordTicks * 3)
    check sim.droppedItems.len == 0
    check sim.players[0].dropChordTicks == 0

  test "priority is spray-first when several items are held":
    var sim = startedGame(dropConfig(), 2)
    sim.players[0].hasSprayPaint = true
    sim.players[0].hasGrenade = true
    sim.holdChord(0, DropChordTicks)
    check sim.droppedItems.len == 1
    check sim.droppedItems[0].kind == dkSpray
    check sim.players[0].hasGrenade         # the lower-priority item stays

# ─────────────────────────────────────────────────────────────────────────
suite "armed: open pickup and the dropper's re-grab delay":
  test "any cog in range steals a dropped item (no team gate)":
    var sim = startedGame(dropConfig(), 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.centerOn(0, 200, 200)
    sim.players[0].hasSprayPaint = true
    sim.holdChord(0, DropChordTicks)        # 0 drops the can where it stands
    check sim.droppedItems.len == 1
    sim.players[0].hasSprayPaint = true     # 0 keeps a can of its own so the
                                            # can it dropped is free to steal
    sim.centerOn(1, 200, 200)               # the enemy walks onto the drop
    sim.step(sim.none(), sim.none())
    check sim.players[1].hasSprayPaint      # the enemy took it
    check sim.droppedItems.len == 0         # removed, never respawns

  test "the dropper cannot re-grab its own drop until the delay elapses":
    var sim = startedGame(dropConfig(), 2)
    sim.centerOn(0, 300, 300)
    sim.players[0].hasSprayPaint = true
    sim.holdChord(0, DropChordTicks)
    check not sim.players[0].hasSprayPaint  # dropped, standing on it
    check sim.droppedItems.len == 1
    let liftsAt = sim.droppedItems[0].dropTick + DropperRegrabTicks
    # Idle on the tile: within the delay the dropper does NOT vacuum it back.
    while sim.tickCount < liftsAt - 1:
      sim.step(sim.none(), sim.none())
    check not sim.players[0].hasSprayPaint
    check sim.droppedItems.len == 1
    # Crossing the delay: the dropper may finally re-grab it.
    for _ in 0 ..< 2:
      sim.step(sim.none(), sim.none())
    check sim.players[0].hasSprayPaint
    check sim.droppedItems.len == 0

# ─────────────────────────────────────────────────────────────────────────
suite "manifest wiring":
  const ManifestName = "coworld_manifest_paintbot.json"

  proc findSchema(node: JsonNode): JsonNode =
    if node.kind == JObject:
      if node.hasKey("config_schema"): return node["config_schema"]
      for _, v in node:
        let f = findSchema(v)
        if f != nil: return f
    elif node.kind == JArray:
      for v in node:
        let f = findSchema(v)
        if f != nil: return f
    nil

  proc brS2Config(node: JsonNode): JsonNode =
    if node.kind == JObject:
      if node.getOrDefault("id").getStr() == "battle-royale-s2" and
          node.hasKey("game_config"):
        return node["game_config"]
      for _, v in node:
        let f = brS2Config(v)
        if f != nil: return f
    elif node.kind == JArray:
      for v in node:
        let f = brS2Config(v)
        if f != nil: return f
    nil

  test "the schema advertises dropItem as an off-by-default boolean":
    let schema = findSchema(parseFile(GameDir / ManifestName))
    check schema != nil
    let props = schema["properties"]
    check props.hasKey("dropItem")
    check props["dropItem"]["type"].getStr() == "boolean"
    check props["dropItem"]["default"].getBool() == false

  test "the battle-royale-s2 variant ships dropItem armed, beside giveItem":
    let gc = brS2Config(parseFile(GameDir / ManifestName))
    check gc != nil
    check gc["dropItem"].getBool() == true
    check gc["giveItem"].getBool() == true   # drop COEXISTS with handoff
