## Battle-royale shrink zone (config-gated): rect geometry derived from
## W/H/z, the drawn-center bound, schedule validation, the damage cadence,
## the stated markers, determinism, and the unconfigured no-op path. See
## docs/designs/BR_MAPGEN.md §4.3.

import
  helpers,
  std/[json, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, replays, sim]

proc zoneGame(zonePhasesJson: string, extraJson = ""): SimServer =
  ## A started Red-vs-Blue game on the default (standard, 1235x659) map with
  ## the given shrink-zone schedule.
  var config = defaultGameConfig()
  let extra = if extraJson.len > 0: ", " & extraJson else: ""
  config.update("""{"zonePhases": """ & zonePhasesJson & extra & "}")
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc placeAt(game: var SimServer, playerIndex, px, py: int) =
  ## Puts one player's CENTER exactly on map pixel (px, py), at rest.
  game.players[playerIndex].x = px - CollisionW div 2
  game.players[playerIndex].y = py - CollisionH div 2
  game.players[playerIndex].velX = 0
  game.players[playerIndex].velY = 0

proc stepTicks(game: var SimServer, ticks: int) =
  let prev = game.none()
  for _ in 0 ..< ticks:
    game.step(game.none(), prev)

proc insideRect(rect: MapRect, px, py: int): bool =
  px >= rect.x and px <= rect.x + rect.w - 1 and
    py >= rect.y and py <= rect.y + rect.h - 1

const
  ToyPhases = """[
    {"z": 0.6, "waitTicks": 10, "shrinkTicks": 20, "dps": 1},
    {"z": 0.35, "waitTicks": 6, "shrinkTicks": 12, "dps": 2},
    {"z": 0.15, "waitTicks": 4, "shrinkTicks": 8, "dps": 3}
  ]"""

suite "shrink zone config":
  test "off by default, and the config echo carries no zonePhases key":
    let config = defaultGameConfig()
    check config.zonePhases.len == 0
    let echoed = parseJson(config.configJson())
    check not echoed.hasKey("zonePhases")

  test "JSON round-trip through update and the config echo":
    var config = defaultGameConfig()
    config.update("""{"zonePhases": """ & ToyPhases & "}")
    check config.zonePhases.len == 3
    check config.zonePhases[0].zPermille == 600
    check config.zonePhases[0].waitTicks == 10
    check config.zonePhases[0].shrinkTicks == 20
    check config.zonePhases[0].dps == 1
    check config.zonePhases[2].zPermille == 150
    let echo = config.configJson()
    var reread = defaultGameConfig()
    reread.update(echo)
    check reread.zonePhases == config.zonePhases

  test "z must be present, greater than 0, and at most 1":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"zonePhases": [{"waitTicks": 1}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": -0.1}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 1.1}]}""")
    # z == 1.0 is in-range per-entry, but phase 0's implicit "previous" is
    # ALSO 1.0 (the full field) — so z=1.0 can never satisfy the strictly-
    # decreasing rule as phase 0, and a wait AT full scale before the first
    # real shrink is authored via phases[0].waitTicks instead, never a
    # degenerate z=1.0 entry.
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 1.0}]}""")

  test "z must fall strictly across phases, including the implicit phase 0":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 1.0}, {"z": 0.5}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0.5}, {"z": 0.5}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0.5}, {"z": 0.6}]}""")
    # Strictly decreasing is accepted.
    config.update("""{"zonePhases": [{"z": 0.75}, {"z": 0.5}, {"z": 0.2}]}""")
    check config.zonePhases.len == 3

  test "waitTicks/shrinkTicks/dps must not be negative":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0.5, "waitTicks": -1}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0.5, "shrinkTicks": -1}]}""")
    expect CtfError:
      config.update("""{"zonePhases": [{"z": 0.5, "dps": -1}]}""")

  test "more than MaxZonePhases entries is rejected":
    var items: seq[string]
    for i in 0 ..< MaxZonePhases + 1:
      items.add """{"z": """ & $(1.0 - 0.01 * float(i + 1)) & "}"
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"zonePhases": [""" & items.join(",") & "]}")

suite "shrink zone rect geometry":
  test "zoneRectAtScale derives width/height from W, H, and z — integer math":
    var sim = zoneGame(ToyPhases)
    let
      w = sim.gameMap.width
      h = sim.gameMap.height
    for zPermille in [1000, 750, 600, 350, 150, 1]:
      let rect = sim.zoneRectAtScale(zPermille)
      check rect.w == max(1, w * zPermille div 1000)
      check rect.h == max(1, h * zPermille div 1000)
      check rect.x == sim.zoneCenter.x - rect.w div 2
      check rect.y == sim.zoneCenter.y - rect.h div 2
      # Geometrically similar to the field within one pixel of integer
      # rounding: w/h and W/H agree up to the rounding both scales share.
      check abs(rect.w * h - rect.h * w) <= w + h

  test "the rect holds the previous scale during the wait, exactly":
    var sim = zoneGame(ToyPhases)
    let full = sim.zoneRectAtScale(1000)
    for t in [0, 5, 9]:
      let (cur, next, dps) = sim.zoneRectAndDps(t)
      check cur == full
      check next == sim.zoneRectAtScale(600)
      check dps == 1

  test "the rect interpolates linearly and lands exactly on target at t=shrink end":
    var sim = zoneGame(ToyPhases)
    let
      full = sim.zoneRectAtScale(1000)
      target = sim.zoneRectAtScale(600)
    # wait=10, shrink=20: shrink covers elapsed 10..29 (0-indexed).
    let (mid, _, _) = sim.zoneRectAndDps(10 + 9)   # tShrink = 10 of 20.
    check mid.w == full.w + (target.w - full.w) * 10 div 20
    check mid.w > min(full.w, target.w)
    check mid.w < max(full.w, target.w)
    let (final, next, _) = sim.zoneRectAndDps(10 + 19)  # tShrink = 20 of 20.
    check final == target
    check next == target

  test "shrinkTicks 0 snaps to the target the instant the wait ends":
    var sim = zoneGame("""[{"z": 0.4, "waitTicks": 3, "shrinkTicks": 0, "dps": 1}]""")
    let
      full = sim.zoneRectAtScale(1000)
      target = sim.zoneRectAtScale(400)
    check sim.zoneRectAndDps(0).cur == full
    check sim.zoneRectAndDps(2).cur == full
    check sim.zoneRectAndDps(3).cur == target

  test "after every phase resolves, the rect holds at the last target forever":
    var sim = zoneGame(ToyPhases)
    let lastTarget = sim.zoneRectAtScale(150)
    let (cur, next, dps) = sim.zoneRectAndDps(100_000)
    check cur == lastTarget
    check next == lastTarget
    check dps == 3

  test "the drawn center keeps the FINAL rect fully on-board, over many seeds":
    for seed in 0 ..< 200:
      var config = defaultGameConfig()
      config.seed = seed
      config.update("""{"zonePhases": [{"z": 0.62, "waitTicks": 1, "shrinkTicks": 1, "dps": 1}]}""")
      var sim = initCtfForTest(config)
      discard sim.addPlayer("red0")
      discard sim.addPlayer("blue0")
      sim.startGame()
      let final = sim.zoneRectAtScale(620)
      check final.x >= ArenaBorder
      check final.y >= ArenaBorder
      check final.x + final.w - 1 <= sim.gameMap.width - 1 - ArenaBorder
      check final.y + final.h - 1 <= sim.gameMap.height - 1 - ArenaBorder

  test "an unconfigured game never draws a center":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    check sim.zoneCenter.x == 0
    check sim.zoneCenter.y == 0

suite "shrink zone authored center":
  test "off by default, and the config echo carries no zoneCenter key":
    let config = defaultGameConfig()
    check not config.zoneCenterConfigured
    let echoed = parseJson(config.configJson())
    check not echoed.hasKey("zoneCenter")

  test "JSON round-trip through update and the config echo":
    var config = defaultGameConfig()
    config.update("""{"zonePhases": """ & ToyPhases &
      """, "zoneCenter": [617, 329]}""")
    check config.zoneCenterConfigured
    check config.zoneCenterX == 617
    check config.zoneCenterY == 329
    let echo = config.configJson()
    var reread = defaultGameConfig()
    reread.update(echo)
    check reread.zoneCenterConfigured
    check reread.zoneCenterX == 617
    check reread.zoneCenterY == 329

  test "zoneCenter must be a [x, y] array of exactly two integers":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"zoneCenter": [1]}""")
    expect CtfError:
      config.update("""{"zoneCenter": [1, 2, 3]}""")
    expect CtfError:
      config.update("""{"zoneCenter": [1.5, 2]}""")
    expect CtfError:
      config.update("""{"zoneCenter": "617,329"}""")

  test "an authored center is used exactly, drawing no RNG":
    var sim = zoneGame(ToyPhases, """"zoneCenter": [400, 200]""")
    check sim.zoneCenter.x == 400
    check sim.zoneCenter.y == 200
    # Two different seeds with the same authored center land on the exact
    # same point (the random draw is skipped entirely — a differing seed
    # would only matter if the RNG were consulted).
    var config = defaultGameConfig()
    config.seed = 999
    config.update("""{"zonePhases": """ & ToyPhases &
      """, "zoneCenter": [400, 200]}""")
    var sim2 = initCtfForTest(config)
    discard sim2.addPlayer("red0")
    discard sim2.addPlayer("blue0")
    sim2.startGame()
    check sim2.zoneCenter.x == 400
    check sim2.zoneCenter.y == 200

  test "an authored center can close on the map's own center":
    var sim = zoneGame(ToyPhases, "")
    let mapCenter = sim.gameMap.center
    var config = defaultGameConfig()
    config.update("""{"zonePhases": """ & ToyPhases & """, "zoneCenter": [""" &
      $mapCenter.x & ", " & $mapCenter.y & "]}")
    var centered = initCtfForTest(config)
    discard centered.addPlayer("red0")
    discard centered.addPlayer("blue0")
    centered.startGame()
    check centered.zoneCenter.x == mapCenter.x
    check centered.zoneCenter.y == mapCenter.y
    let final = centered.zoneRectAtScale(150)
    check final.x == mapCenter.x - final.w div 2
    check final.y == mapCenter.y - final.h div 2

  test "absent zoneCenter still draws randomly, unaffected by the new field":
    var
      simA = zoneGame(ToyPhases, """"seed": 1""")
      simB = zoneGame(ToyPhases, """"seed": 2""")
    check not simA.config.zoneCenterConfigured
    # Different seeds still (almost certainly) draw different centers, same
    # as before this field existed.
    check simA.zoneCenter.x != simB.zoneCenter.x or
      simA.zoneCenter.y != simB.zoneCenter.y

  test "a zoneCenter that cannot keep the final rect on-board is rejected":
    var config = defaultGameConfig()
    # Standard map is 1235x659; a final z=0.62 rect is ~766x409 — anchoring
    # it dead in a corner cannot keep it on-board with the ArenaBorder
    # margin.
    expect CtfError:
      config.update(
        """{"zonePhases": [{"z": 0.62}], "zoneCenter": [5, 5]}""")
    expect CtfError:
      config.update(
        """{"zonePhases": [{"z": 0.62}], "zoneCenter": [1230, 655]}""")
    # The same map (a corner is always out of reach for a large rect) but a
    # near-center point is accepted once the final phase is small enough.
    config.update(
      """{"zonePhases": [{"z": 0.05}], "zoneCenter": [600, 300]}""")
    check config.zoneCenterConfigured

  test "a zoneCenter with no zonePhases configured is stored but unchecked":
    var config = defaultGameConfig()
    # Off-board for ANY realistic rect, but zonePhases is empty, so nothing
    # is validated against it (it is never read either — see resetZone).
    config.update("""{"zoneCenter": [5, 5]}""")
    check config.zoneCenterConfigured
    check config.zoneCenterX == 5
    check config.zoneCenterY == 5
    var sim = initCtfForTest(config)
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    check sim.zoneCenter.x == 0
    check sim.zoneCenter.y == 0

  test "an authored center round-trips a mid-shrink keyframe like the random draw":
    var sim = zoneGame(ToyPhases, """"zoneCenter": [500, 300]""")
    sim.stepTicks(25)
    let
      hash = sim.gameHash()
      bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.gameHash() == hash
    check restored.zoneCenter.x == 500
    check restored.zoneCenter.y == 300

suite "shrink zone damage":
  test "outside for a full second deals the phase's dps; inside is untouched":
    # z tiny enough that BOTH default spawn points land outside it, wait/
    # shrink both 0 so the small rect is live from tick 0.
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 2}]""")
    sim.players[0].hp = 20
    sim.players[1].hp = 20
    let rect = sim.zoneRectAtScale(100)
    check not rect.insideRect(sim.players[0].x + CollisionW div 2,
      sim.players[0].y + CollisionH div 2)
    # Player 1 stands dead center of the zone: never damaged.
    sim.placeAt(1, sim.zoneCenter.x, sim.zoneCenter.y)
    sim.stepTicks(ZoneDamageRollTicks - 1)
    check sim.players[0].hp == 20
    check sim.players[1].hp == 20
    sim.stepTicks(1)
    check sim.players[0].hp == 18
    check sim.players[1].hp == 20
    # The clock restarted: the next tick lands one full second later.
    sim.stepTicks(ZoneDamageRollTicks - 1)
    check sim.players[0].hp == 18
    sim.stepTicks(1)
    check sim.players[0].hp == 16
    check sim.players[1].hp == 20

  test "dipping back inside resets the outside-tick counter":
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 1}]""")
    let farX = 4
    let farY = 4
    sim.placeAt(0, farX, farY)
    sim.stepTicks(ZoneDamageRollTicks - 1)
    check sim.players[0].zoneOutsideTicks == ZoneDamageRollTicks - 1
    sim.placeAt(0, sim.zoneCenter.x, sim.zoneCenter.y)
    sim.stepTicks(1)
    check sim.players[0].zoneOutsideTicks == 0
    check sim.players[0].hp == sim.config.hitPoints

  test "the shield layer soaks the zone hit before base hp":
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 5}]""")
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = 3
    sim.players[0].hp = 20
    sim.placeAt(0, 4, 4)
    sim.stepTicks(ZoneDamageRollTicks)
    check sim.players[0].shieldHp == 0
    check sim.players[0].hasShield == false
    check sim.players[0].hp == 18   # 5 dps - 3 shield hp absorbed = 2 through.

  test "a lethal zone tick is an environmental death: nobody gets the kill":
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 1}]""")
    sim.players[0].hp = 1
    sim.placeAt(0, 4, 4)
    sim.stepTicks(ZoneDamageRollTicks)
    check not sim.players[0].alive
    check sim.players[0].deaths == 1
    check sim.players[0].zoneOutsideTicks == 0
    for player in sim.players:
      check player.kills == 0

  test "a dead body outside the zone never ticks the clock":
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 1}]""")
    sim.placeAt(0, 4, 4)
    sim.players[0].alive = false
    sim.stepTicks(ZoneDamageRollTicks)
    check sim.players[0].zoneOutsideTicks == 0

  test "dps 0 hurts nobody, even after standing outside for a long time":
    var sim = zoneGame(
      """[{"z": 0.1, "waitTicks": 0, "shrinkTicks": 0, "dps": 0}]""")
    sim.placeAt(0, 4, 4)
    sim.stepTicks(ZoneDamageRollTicks * 3)
    check sim.players[0].hp == sim.config.hitPoints

  test "an unconfigured game never touches hp, however long it runs":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.placeAt(0, 4, 4)
    sim.stepTicks(ZoneDamageRollTicks * 3)
    check sim.players[0].hp == sim.config.hitPoints
    check sim.players[0].zoneOutsideTicks == 0

suite "shrink zone emission":
  test "both streams state zone + zonenext whenever the mode is on":
    var sim = zoneGame(ToyPhases)
    var state = initGlobalViewerState()
    check sim.buildGlobalMessages(state).hasObject(ZoneMarkerBase)
    check sim.buildGlobalMessages(state).hasObject(ZoneMarkerBase + 1)
    check sim.playerMessages(0).hasObject(ZoneMarkerBase)
    check sim.playerMessages(0).hasObject(ZoneMarkerBase + 1)

  test "the markers carry the exact labelZone/labelZoneNext grammar":
    var sim = zoneGame(ToyPhases)
    sim.stepTicks(15)   # partway into phase 0's shrink.
    let (cur, next, _) = sim.zoneRectAndDps(sim.tickCount - sim.gameStartTick)
    var state = initGlobalViewerState()
    var
      foundZone = false
      foundNext = false
    for message in sim.buildGlobalMessages(state):
      if message.kind != spkSprite:
        continue
      if message.sprite.label ==
          labelZone(cur.x, cur.y, cur.x + cur.w - 1, cur.y + cur.h - 1):
        foundZone = true
      if message.sprite.label ==
          labelZoneNext(next.x, next.y, next.x + next.w - 1, next.y + next.h - 1):
        foundNext = true
    check foundZone
    check foundNext

  test "no marker in an unconfigured game":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.startGame()
    var state = initGlobalViewerState()
    let messages = sim.buildGlobalMessages(state)
    check not messages.hasObject(ZoneMarkerBase)
    check not messages.hasObject(ZoneMarkerBase + 1)
    for message in messages:
      if message.kind == spkSprite:
        check not message.sprite.label.startsWith(LabelPrefixZone)
        check not message.sprite.label.startsWith(LabelPrefixZoneNext)

suite "shrink zone determinism":
  test "the same seed produces an identical rect trajectory and gameHash":
    var
      simA = zoneGame(ToyPhases, """"seed": 12345""")
      simB = zoneGame(ToyPhases, """"seed": 12345""")
    check simA.zoneCenter.x == simB.zoneCenter.x
    check simA.zoneCenter.y == simB.zoneCenter.y
    for tick in [0, 9, 10, 29, 30, 41, 42, 53, 54, 500]:
      check simA.zoneRectAndDps(tick) == simB.zoneRectAndDps(tick)
    simA.stepTicks(70)
    simB.stepTicks(70)
    check simA.gameHash() == simB.gameHash()
    check simA.players[0].hp == simB.players[0].hp
    check simA.players[1].hp == simB.players[1].hp

  test "zoneCenter is mixed into gameHash only when zonePhases is configured":
    var
      sim1 = zoneGame(ToyPhases, """"seed": 777""")
      sim2 = zoneGame(ToyPhases, """"seed": 777""")
    check sim1.gameHash() == sim2.gameHash()
    sim1.zoneCenter.x = sim1.zoneCenter.x + 5
    check sim1.gameHash() != sim2.gameHash()
    # With the mode OFF, forcing the (never-read) center apart changes
    # nothing: the barrageStartTick-style gate never mixes it in.
    var
      plain1 = initCtfForTest(defaultGameConfig())
      plain2 = initCtfForTest(defaultGameConfig())
    discard plain1.addPlayer("red0"); discard plain1.addPlayer("blue0")
    discard plain2.addPlayer("red0"); discard plain2.addPlayer("blue0")
    plain1.startGame()
    plain2.startGame()
    check plain1.gameHash() == plain2.gameHash()
    plain1.zoneCenter = MapPoint(x: 999, y: 999)
    check plain1.gameHash() == plain2.gameHash()

  test "a mid-shrink keyframe round-trips the zone state":
    var sim = zoneGame(ToyPhases)
    sim.stepTicks(25)
    let
      hash = sim.gameHash()
      bytes = serializeReplaySim(sim)
    var restored = deserializeReplaySim(bytes, sim)
    check restored.gameHash() == hash
    check restored.zoneCenter.x == sim.zoneCenter.x
    check restored.zoneCenter.y == sim.zoneCenter.y
