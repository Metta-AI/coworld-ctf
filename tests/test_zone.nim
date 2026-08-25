## Battle-royale shrink zone (config-gated): rect geometry derived from
## W/H/z, the drawn-center bound, schedule validation, the damage cadence,
## the stated markers, determinism, and the unconfigured no-op path. See
## docs/designs/BR_MAPGEN.md §4.3.

import
  helpers,
  std/[algorithm, json, math, os, sets, strutils, unittest],
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

proc zoneGameOnRealMap(zonePhasesJson: string): SimServer =
  ## A started game on the TRACKED showmatch map spec (br-match-showmatch-
  ## 4242.json — the real giant, multi-room-building draw Fable's machine
  ## checks are meant to run against; the default 1235x659 test map's own
  ## interior nooks turned out too shallow, see the room-depth guard on the
  ## door-first check). Only `teams` (must equal the map's own spawnGroups,
  ## per resolveCtfMapMetadata) and the zone schedule are configured beyond
  ## the map spec itself — no full 32-seat BR roster, since these checks
  ## only touch the paint-arrival field, never combat/spawns.
  let mapSpecJson = readFile(GameDir / "br-match-showmatch-4242.json")
  var config = defaultGameConfig()
  config.update("{\"mapSpec\": " & mapSpecJson & ", \"teams\": 16, " &
    "\"zonePhases\": " & zonePhasesJson & "}")
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
  ## The doctrine's real five-phase table (record_br_match.sh, verbatim) —
  ## used by the paint-arrival honesty gate below so it stresses the same
  ## long-wait/short-shrink cadence a real match runs, not ToyPhases' much
  ## faster synthetic one.
  BrShowmatchPhases = """[
    {"z": 0.75, "waitTicks": 600, "shrinkTicks": 420, "dps": 0},
    {"z": 0.55, "waitTicks": 480, "shrinkTicks": 360, "dps": 2},
    {"z": 0.40, "waitTicks": 360, "shrinkTicks": 300, "dps": 4},
    {"z": 0.28, "waitTicks": 240, "shrinkTicks": 240, "dps": 8},
    {"z": 0.17, "waitTicks": 180, "shrinkTicks": 180, "dps": 12}
  ]"""
  BrShowmatchTotalTicks = 600 + 420 + 480 + 360 + 360 + 300 + 240 + 240 +
    180 + 180  ## 3360 — sum of every phase's wait+shrink.

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
      ## Built about the DRIFTING centre, not the drawn one — the drawn
      ## centre is only where the schedule ARRIVES (zoneCenterAtScale).
      let c = sim.zoneCenterAtScale(zPermille)
      check rect.x == c.x - rect.w div 2
      check rect.y == c.y - rect.h div 2
      # Geometrically similar to the field within one pixel of integer
      # rounding: w/h and W/H agree up to the rounding both scales share.
      check abs(rect.w * h - rect.h * w) <= w + h

  test "the rect holds the previous scale during the wait, exactly":
    ## Expectations are CLAMPED (zoneClampToBoard): zoneRectAtScale states
    ## the geometry, zoneRectAndDps ships the EFFECTIVE zone, and at large z
    ## about a drawn center those differ — see the clamp ruling.
    var sim = zoneGame(ToyPhases)
    let full = sim.zoneClampToBoard(sim.zoneRectAtScale(1000))
    for t in [0, 5, 9]:
      let (cur, next, dps) = sim.zoneRectAndDps(t)
      check cur == full
      check next == sim.zoneClampToBoard(sim.zoneRectAtScale(600))
      check dps == 1

  test "the rect interpolates and lands exactly on target at t=shrink end":
    ## The interpolation runs on the RAW rects and is clamped afterwards, so
    ## the mid-shrink rect is bounded by the clamped endpoints rather than
    ## equal to a raw lerp: while the shrinking edge is still off-board the
    ## visible edge legitimately does not move at all.
    var sim = zoneGame(ToyPhases)
    let
      full = sim.zoneClampToBoard(sim.zoneRectAtScale(1000))
      target = sim.zoneClampToBoard(sim.zoneRectAtScale(600))
    # wait=10, shrink=20: shrink covers elapsed 10..29 (0-indexed).
    let (mid, _, _) = sim.zoneRectAndDps(10 + 9)   # tShrink = 10 of 20.
    check mid.w <= max(full.w, target.w)
    check mid.w >= min(full.w, target.w)
    check mid.h <= max(full.h, target.h)
    check mid.h >= min(full.h, target.h)
    let (final, next, _) = sim.zoneRectAndDps(10 + 19)  # tShrink = 20 of 20.
    check final == target
    check next == target

  test "shrinkTicks 0 snaps to the target the instant the wait ends":
    var sim = zoneGame("""[{"z": 0.4, "waitTicks": 3, "shrinkTicks": 0, "dps": 1}]""")
    let
      full = sim.zoneClampToBoard(sim.zoneRectAtScale(1000))
      target = sim.zoneClampToBoard(sim.zoneRectAtScale(400))
    check sim.zoneRectAndDps(0).cur == full
    check sim.zoneRectAndDps(2).cur == full
    check sim.zoneRectAndDps(3).cur == target

  test "z = 1.0 leaves the WHOLE board inside the zone, whatever the center":
    ## THE CLAMP RULING (Maxwell, 2026-08-24). zoneRectAtScale centers a
    ## full-SIZE rect on the drawn center, so off-center it hangs off one
    ## edge and leaves an equal band of real field outside the zone. The
    ## doctrine calls phase 0 the DROP and says z = 1.00, i.e. the whole
    ## field is safe — and it was not: the first BR match killed 6 of 16
    ## duos at tick 256, before a shot was fired, purely because their
    ## spawns sat in that band. The effective rect is now rect INTERSECT
    ## board, so this is true by construction at every center.
    ##
    ## An AUTHORED, deliberately off-centre centre (the map centre is
    ## 617,329) makes the raw z=1.0 rect hang off the left and top edges.
    ## It still has to keep the FINAL rect on-board, which is what bounds
    ## how far off-centre a schedule may legally close.
    var sim = zoneGame(ToyPhases, """"zoneCenter": [400, 220]""")
    let
      w = sim.gameMap.width
      h = sim.gameMap.height
      raw = sim.zoneRectAtScale(1000)
      full = sim.zoneClampToBoard(raw)
    ## Clamping alone CANNOT deliver this, which is why the centre drifts:
    ## intersecting a rect that hangs off the left edge removes the overhang
    ## but leaves the strip on the RIGHT outside the zone. The rect at z=1.0
    ## is therefore the board exactly, before any clamping.
    check raw == MapRect(x: 0, y: 0, w: w, h: h)
    check full == raw
    ## ...and the centre really is off-board-centre where it ARRIVES, so
    ## this is not passing because the draw happened to be central.
    ## ToyPhases closes at z = 0.15, and the drift has fully arrived there:
    ## the authored (400, 220) centre, which is NOT the board centre.
    check sim.zoneCenterAtScale(150) == MapPoint(x: 400, y: 220)
    check sim.zoneCenterAtScale(150) != MapPoint(x: w div 2, y: h div 2)
    ## Every corner of the board is inside the effective zone.
    for (cx, cy) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
      check cx >= full.x and cx <= full.x + full.w - 1
      check cy >= full.y and cy <= full.y + full.h - 1

  test "a cog in the far corner takes NO zone damage during the drop":
    ## The same ruling, asserted through the DAMAGE path rather than the
    ## geometry: the corner furthest from the drawn centre is exactly where
    ## the old behaviour killed people.
    var sim = zoneGame(
      """[{"z": 0.6, "waitTicks": 400, "shrinkTicks": 20, "dps": 3}]""",
      """"zoneCenter": [400, 220]""")
    sim.placeAt(0, sim.gameMap.width - 2, sim.gameMap.height - 2)
    let before = sim.players[0].hp
    sim.stepTicks(300)          # deep into the wait, at z = 1.0.
    check sim.players[0].hp == before
    check sim.players[0].alive

  test "the effective rect's area never grows across the whole schedule":
    ## Monotonicity of the CLAMPED area. The raw rects are nested by
    ## construction (one centre, uniform scale), and intersecting nested
    ## rects with the same board preserves nesting — but the clamp is
    ## applied after a lerp, so it is worth asserting rather than assuming.
    ## A zone that ever grew would hand back ground it had already taken.
    var sim = zoneGame(ToyPhases, """"zoneCenter": [400, 220]""")
    var previousArea = -1
    for t in 0 .. 200:
      let (cur, _, _) = sim.zoneRectAndDps(t)
      let area = cur.w * cur.h
      if previousArea >= 0:
        check area <= previousArea
      previousArea = area
    ## And it really did close: the last area is a small fraction of the
    ## board, not a rounding wobble away from it.
    check previousArea < sim.gameMap.width * sim.gameMap.height div 4

  test "the published label carries the CLAMPED rect, not the geometric one":
    ## The honest-boundary rule: art, damage and the policy-facing label all
    ## read one rect. The label is the contract, so it is the one asserted
    ## here — and against the CLAMPED value specifically, with the raw value
    ## proven different so the check cannot pass vacuously.
    var sim = zoneGame(ToyPhases, """"zoneCenter": [400, 220]""")
    sim.stepTicks(15)   # partway into the first shrink, centre mid-drift.
    let
      (raw, _, _) = sim.zoneRectAndDps(sim.tickCount - sim.gameStartTick)
      clamped = sim.zoneClampToBoard(raw)
    ## With the drifting centre the effective rect never leaves the board,
    ## so the clamp is a no-op here BY CONSTRUCTION. That is the invariant
    ## worth pinning: the clamp is the belt-and-braces guarantee, and if it
    ## ever starts biting, the drift maths has regressed.
    check raw == clamped
    var state = initGlobalViewerState()
    var foundClamped = false
    var foundRaw = false
    for message in sim.buildGlobalMessages(state):
      if message.kind != spkSprite:
        continue
      if message.sprite.label == labelZone(
          clamped.x, clamped.y,
          clamped.x + clamped.w - 1, clamped.y + clamped.h - 1):
        foundClamped = true
      if message.sprite.label == labelZone(
          raw.x, raw.y, raw.x + raw.w - 1, raw.y + raw.h - 1):
        foundRaw = true
    check foundClamped
    check foundRaw          ## same rect: clamped == raw, see above.
    ## No published corner may sit off the board: a policy reading the label
    ## must never be told to stand somewhere that does not exist.
    check clamped.x >= 0
    check clamped.y >= 0
    check clamped.x + clamped.w <= sim.gameMap.width
    check clamped.y + clamped.h <= sim.gameMap.height

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

suite "shrink zone paint arrival honesty":
  ## The round-3 arrival-time field's HARD ACCEPTANCE GATE (Fable's audit,
  ## binding, not a style note): paint may only ever be LATE relative to the
  ## true damage boundary, never early and never elsewhere. Checked as an
  ## automated assertion over the WHOLE schedule against the SAME
  ## roundedRectSignedDist/zoneRectAndDps math the render reads and the
  ## damage system (sim.nim, untouched by this file) authorizes — not an
  ## eyeball check, and it must pass before any screenshot is trusted.
  test "painted(p) at tick T implies p is outside rect(T), zero tolerance beyond the corner-round bound":
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    check gw > 0
    check gh > 0
    var sampleTicks: seq[int]
    for frac in [0.0, 0.05, 0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.0]:
      sampleTicks.add(int(float(BrShowmatchTotalTicks) * frac))
    var checkedCells = 0
    for t in sampleTicks:
      let rect = sim.zoneRectAndDps(t).cur
      for gy in 0 ..< gh:
        for gx in 0 ..< gw:
          let
            px = gx * ZoneFieldCellPx + ZoneFieldCellPx div 2
            py = gy * ZoneFieldCellPx + ZoneFieldCellPx div 2
            cell = zoneArrivalFieldCellAt(px, py)
          if not cell.has:
            continue
          inc checkedCells
          let
            painted = cell.arrival <= t
            sd = roundedRectSignedDist(rect, ZoneCornerRoundPx, px.float, py.float)
          # painted ⇒ outside-rect(T), within the SAME rounded-corner bound
          # every other consumer of this SDF already accepts (the honesty
          # bound is spatial rounding, not a licence to paint the interior).
          check (not painted) or sd >= -ZoneCornerRoundPx - 1.0

  test "dry(p) ∧ outside-rect(p) ⇒ arrival delay at p never exceeds the flow-delay cap":
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    var sampleTicks: seq[int]
    for frac in [0.0, 0.05, 0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.0]:
      sampleTicks.add(int(float(BrShowmatchTotalTicks) * frac))
    for t in sampleTicks:
      let rect = sim.zoneRectAndDps(t).cur
      for gy in 0 ..< gh:
        for gx in 0 ..< gw:
          let
            px = gx * ZoneFieldCellPx + ZoneFieldCellPx div 2
            py = gy * ZoneFieldCellPx + ZoneFieldCellPx div 2
            cell = zoneArrivalFieldCellAt(px, py)
          if not cell.has or cell.arrival == ZoneNeverArrives.int:
            continue
          let sd = roundedRectSignedDist(rect, ZoneCornerRoundPx, px.float, py.float)
          # Clearly outside (past the corner-round bound) and still dry at
          # T: its arrival may not be overdue past the capped flow delay —
          # +60 is slack for the base term's own integer-tick bisection
          # rounding, never the flow term itself.
          if sd > ZoneCornerRoundPx and cell.arrival > t:
            check cell.arrival - t <= ZoneFlowDelayCapTicks + 60

  test "the field is built ONCE per episode: ensureZoneArrivalField is a no-op past the first call, and values never drift":
    ## D1's whole fix hinges on this: nothing about the field may depend on
    ## `sim.tickCount`, so calling ensureZoneArrivalField again later in the
    ## SAME episode (exactly what addZoneEdgeBand does every tick) must be a
    ## cache hit (returns false) with byte-identical values — never a
    ## rebuild, and never a different answer for the same cell.
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)  # startGame() may have already
                                          # built it (addZoneEdgeBand runs
                                          # off tick 0 too) — either way,
                                          # this call must not have rebuilt.
    let (gw, gh) = zoneArrivalFieldGridDims()
    var before: seq[int]
    for gy in countup(0, gh - 1, 7):
      for gx in countup(0, gw - 1, 7):
        before.add(zoneArrivalFieldCellAt(
          gx * ZoneFieldCellPx + ZoneFieldCellPx div 2,
          gy * ZoneFieldCellPx + ZoneFieldCellPx div 2).arrival)
    sim.stepTicks(50)
    check ensureZoneArrivalField(sim) == false  # cache hit, not a rebuild.
    var idx = 0
    for gy in countup(0, gh - 1, 7):
      for gx in countup(0, gw - 1, 7):
        check zoneArrivalFieldCellAt(
          gx * ZoneFieldCellPx + ZoneFieldCellPx div 2,
          gy * ZoneFieldCellPx + ZoneFieldCellPx div 2).arrival == before[idx]
        inc idx

proc rankTransform(values: seq[float]): seq[float] =
  ## Standard competition-rank-with-ties-averaged transform, for Spearman
  ## rank correlation: sort indices by value, assign 0-based ranks, and for
  ## any run of equal values, replace their ranks with the run's own mean
  ## (the textbook tie-handling — an untied dataset gets ordinary ranks).
  let n = values.len
  var order = newSeq[int](n)
  for i in 0 ..< n: order[i] = i
  order.sort(proc(a, b: int): int = cmp(values[a], values[b]))
  result = newSeq[float](n)
  var i = 0
  while i < n:
    var j = i
    while j + 1 < n and values[order[j + 1]] == values[order[i]]:
      inc j
    let avgRank = (i.float + j.float) / 2.0
    for k in i .. j:
      result[order[k]] = avgRank
    i = j + 1

proc frontierTipCoord(
  fixedCoord, startCoord, stepSign, otherGridMaxPx: int, t: int, alongX: bool
): int =
  ## Walks OUTWARD from `startCoord` (assumed painted — just past the
  ## rect's own edge) in `stepSign` direction, returning the coordinate of
  ## the LAST painted cell before the first unpainted one: the frontier's
  ## own tip position for this row/column. -1 if the walk never finds an
  ## unpainted cell within a generous range (degenerate — deep "never"
  ## territory or an unreached row), or if `startCoord` itself isn't
  ## painted yet (too early for this row to have a tip at all).
  proc paintedAt(v: int): bool =
    if v < 0 or v >= otherGridMaxPx: return false
    let cell = if alongX: zoneArrivalFieldCellAt(v, fixedCoord)
      else: zoneArrivalFieldCellAt(fixedCoord, v)
    cell.has and cell.arrival <= t
  if not paintedAt(startCoord):
    return -1
  const MaxWalkSteps = 300  ## * ZoneFieldCellPx ≈ 1200px, generous vs the
                            ## flow-delay cap's own spatial reach at any
                            ## realistic baseSpeed.
  var
    coord = startCoord
    steps = 0
  while paintedAt(coord + stepSign * ZoneFieldCellPx) and steps < MaxWalkSteps:
    let next = coord + stepSign * ZoneFieldCellPx
    if next < 0 or next >= otherGridMaxPx:
      # Ran off the MAP'S OWN edge while still painted — this row's paint
      # genuinely reached the boundary (plausible late in the schedule),
      # so there is no interior "tip" here at all, only an artifact of
      # where the map stops. Never let this read as a stable, repeatable
      # tip position (every such row would otherwise clamp to the same
      # boundary coordinate and look like one giant straight run).
      return -1
    coord = next
    inc steps
  if steps >= MaxWalkSteps:
    return -1
  const MapEdgeExclusionPx = 40  ## paint physically cannot finger PAST the
                                 ## map's own boundary — a frontier hugging
                                 ## flat against x=0 (or any edge) late in
                                 ## the schedule is correct clipping, not a
                                 ## stiff-rectangle regression. Exclude tips
                                 ## this close to the boundary from the
                                 ## straight-run measurement the same way
                                 ## the map-edge walk-off above is excluded.
  if coord < MapEdgeExclusionPx or coord >= otherGridMaxPx - MapEdgeExclusionPx:
    return -1
  coord

proc longestStraightRunPx(sim: SimServer, rect: MapRect, t: int, gw, gh: int): int =
  ## For each of the rect's 4 sides, traces the frontier's own TIP position
  ## row-by-row (or column-by-column) — frontierTipCoord — and returns the
  ## longest run of CONSECUTIVE samples whose tip position is IDENTICAL: a
  ## fingered isoline's tip position varies every finger wavelength; a
  ## straight run means the isoline traces a flat line there instead. This
  ## reads the isoline directly (not a fixed px band around the CURRENT
  ## rect, which the earlier version used and which broke down once the
  ## frontier's accumulated delay carried it far from that band — a bug in
  ## the CHECK, not the field: dumping raw values showed long uniform
  ## PAINTED runs deep past the band, not the frontier at all).
  let
    gwPx = gw * ZoneFieldCellPx
    ghPx = gh * ZoneFieldCellPx
  var longest = 0
  # Left / right edges: trace the tip's X per row Y.
  for (edgeX, stepSign) in [(rect.x, -1), (rect.x + rect.w - 1, 1)]:
    var
      runLen = 0
      prevTip = -2
    for y in countup(max(0, rect.y - 10), min(ghPx - 1, rect.y + rect.h - 1 + 10),
        ZoneFieldCellPx):
      let tip = frontierTipCoord(y, edgeX, stepSign, gwPx, t, alongX = false)
      if tip == prevTip and tip != -1:
        runLen += ZoneFieldCellPx
      else:
        runLen = ZoneFieldCellPx
      prevTip = tip
      if tip != -1:
        longest = max(longest, runLen)
  # Top / bottom edges: trace the tip's Y per column X.
  for (edgeY, stepSign) in [(rect.y, -1), (rect.y + rect.h - 1, 1)]:
    var
      runLen = 0
      prevTip = -2
    for x in countup(max(0, rect.x - 10), min(gwPx - 1, rect.x + rect.w - 1 + 10),
        ZoneFieldCellPx):
      let tip = frontierTipCoord(x, edgeY, stepSign, ghPx, t, alongX = true)
      if tip == prevTip and tip != -1:
        runLen += ZoneFieldCellPx
      else:
        runLen = ZoneFieldCellPx
      prevTip = tip
      if tip != -1:
        longest = max(longest, runLen)
  longest

suite "shrink zone paint arrival: fingering and front-propagation causality":
  ## The remaining four of Fable's six machine checks, all against the real
  ## BrShowmatchPhases schedule: no straight runs (the frontier must read
  ## as fingered, not a bare rectangle), a room never fills faster than the
  ## open floor outside its own doorway, and a room fills door-first (its
  ## arrival is monotone with walk-distance from the door — the emergent
  ## proof that computeZoneFrontierField's causality, not a hand-built
  ## room classifier, is what produces the shape).
  test "no axis-aligned straight run longer than ~100px at any sampled tick":
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    var worst = 0
    for frac in [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85]:
      let t = int(float(BrShowmatchTotalTicks) * frac)
      let rect = sim.zoneRectAndDps(t).cur
      worst = max(worst, longestStraightRunPx(sim, rect, t, gw, gh))
    echo "straight-run check: worst=", worst
    check worst <= 100

  test "a room never fills faster than the open floor just outside its own doorway":
    var sim = zoneGameOnRealMap(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    let roomId = zoneTestClassifyRooms(sim)
    var maxRoomId = -1
    for r in roomId:
      if r > maxRoomId: maxRoomId = r
    var cellsByRoom = newSeq[seq[int]](maxRoomId + 1)
    for idx in 0 ..< roomId.len:
      if roomId[idx] >= 0:
        cellsByRoom[roomId[idx]].add(idx)
    proc arrivalOf(idx: int): tuple[has: bool, v: int] =
      let gx = idx mod gw
      let gy = idx div gw
      let c = zoneArrivalFieldCellAt(
        gx * ZoneFieldCellPx + ZoneFieldCellPx div 2,
        gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
      (c.has and c.arrival != ZoneNeverArrives.int, c.arrival)
    var
      roomsChecked = 0
      lagViolations = 0
    for cells in cellsByRoom:
      if cells.len < 4:
        continue
      var doorSet = initHashSet[int]()
      for idx in cells:
        let gx = idx mod gw
        let gy = idx div gw
        for off in ZoneFrontierOffsets:
          let
            nx = gx + off.dx
            ny = gy + off.dy
          if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
          let nidx = ny * gw + nx
          if roomId[nidx] == -1:
            doorSet.incl(nidx)
      if doorSet.len == 0:
        continue
      var roomMin = high(int)
      var doorMin = high(int)
      var roomN, doorN: int
      for idx in cells:
        let a = arrivalOf(idx)
        if a.has:
          roomMin = min(roomMin, a.v)
          inc roomN
      for idx in doorSet:
        let a = arrivalOf(idx)
        if a.has:
          doorMin = min(doorMin, a.v)
          inc doorN
      if roomN == 0 or doorN == 0:
        continue
      inc roomsChecked
      echo "  room cells=", cells.len, " roomN=", roomN, " doorN=", doorN,
        " roomMin=", roomMin, " doorMin=", doorMin
      # The invariant the construction actually guarantees: every room
      # cell's arrival = SOME door-adjacent cell's own arrival + a non-
      # negative march cost, so the room's OWN fastest cell can never beat
      # the FASTEST of its doors — comparing against the door band's MEAN
      # is a noisier proxy (fingering gives different doors different
      # arrivals, and the room's fastest path need not route through the
      # door band's average member), and produced sub-tick "violations"
      # that were exactly that noise, not a real fills-faster-than-its-
      # door regression.
      if roomMin < doorMin:
        inc lagViolations
    echo "room-lag check: roomsChecked=", roomsChecked,
      " lagViolations=", lagViolations
    check roomsChecked > 0
    check lagViolations == 0

  test "a room fills door-first: arrival correlates with walk-distance from the doorway":
    var sim = zoneGameOnRealMap(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    let roomId = zoneTestClassifyRooms(sim)
    var maxRoomId = -1
    for r in roomId:
      if r > maxRoomId: maxRoomId = r
    var cellsByRoom = newSeq[seq[int]](maxRoomId + 1)
    for idx in 0 ..< roomId.len:
      if roomId[idx] >= 0:
        cellsByRoom[roomId[idx]].add(idx)
    block:
      var sizes: seq[int]
      for c in cellsByRoom: sizes.add(c.len)
      sizes.sort(SortOrder.Descending)
      echo "  total room components=", maxRoomId + 1,
        " sizes(top 15)=", sizes[0 ..< min(15, sizes.len)]
    let wallDist = zoneTestWallDistGrid(sim)
    proc arrivalOf(idx: int): tuple[has: bool, v: int] =
      let gx = idx mod gw
      let gy = idx div gw
      let c = zoneArrivalFieldCellAt(
        gx * ZoneFieldCellPx + ZoneFieldCellPx div 2,
        gy * ZoneFieldCellPx + ZoneFieldCellPx div 2)
      (c.has and c.arrival != ZoneNeverArrives.int, c.arrival)
    var
      roomsChecked = 0
      corrViolations = 0
    for cells in cellsByRoom:
      if cells.len < 8:  # need enough spread for a meaningful correlation
        continue
      # WEIGHTED geodesic distance from the doorway (every room cell
      # adjacent to an exterior/aperture cell), over ONLY this room's own
      # cells, using the SAME aperture+wallDrag clearance data the solver's
      # own F(p) reads (zoneTestWallDistGrid) — a plain unweighted hop
      # count correlates only loosely with the solver's actual march time
      # whenever a room's own clearance varies internally (which it does,
      # by design: aperture/wallDrag are real physics, not noise), so this
      # is the fair "walk-distance" to test the construction against, not
      # a cruder proxy. Simple bounded relaxation (no heap needed — a
      # room's own cell count is small): repeat until stable.
      var dist = newSeq[float](gw * gh)
      for i in 0 ..< dist.len: dist[i] = Inf
      var doorSeedCount = 0
      for idx in cells:
        let gx = idx mod gw
        let gy = idx div gw
        var isDoor = false
        for off in ZoneFrontierOffsets:
          let
            nx = gx + off.dx
            ny = gy + off.dy
          if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
          if roomId[ny * gw + nx] == -1:
            isDoor = true
        if isDoor:
          dist[idx] = 0.0
          inc doorSeedCount
      proc edgeCost(nidx: int): float =
        let clearance = wallDist[nidx].float * 2.0
        let aperture = clamp(clearance / 26.0, 0.15, 1.0)
        let wallDrag = clamp(wallDist[nidx].float / 10.0, 0.0, 1.0)
        let wallMult = 0.5 + wallDrag * 0.5
        1.0 / max(0.05, aperture * wallMult)
      var changed = true
      var iterGuard = 0
      while changed and iterGuard < cells.len + 5:
        changed = false
        inc iterGuard
        for idx in cells:
          if dist[idx] >= Inf: continue
          let gx = idx mod gw
          let gy = idx div gw
          for off in ZoneFrontierOffsets:
            let
              nx = gx + off.dx
              ny = gy + off.dy
            if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
            let nidx = ny * gw + nx
            if roomId[nidx] != roomId[idx]: continue
            let step = (if off.dx != 0 and off.dy != 0: 1.41421356 else: 1.0)
            let cand = dist[idx] + step * edgeCost(nidx)
            if cand < dist[nidx]:
              dist[nidx] = cand
              changed = true
      if doorSeedCount == 0:
        continue  # no doorway reached this room — skip (not a
                  # front-propagation failure, a classifier edge case).
      # SPEARMAN rank correlation between arrival and the weighted walk-
      # distance over the room's own cells.
      var xs, ys: seq[float]
      var maxHopSeen = 0
      for idx in cells:
        if dist[idx] >= Inf: continue
        maxHopSeen = max(maxHopSeen, (dist[idx] / 4.0).int)
        let a = arrivalOf(idx)
        if not a.has: continue
        xs.add(dist[idx])
        ys.add(a.v.float)
      if xs.len < 8:
        continue
      if maxHopSeen < 3:
        # A room this shallow (every cell within 1-2 hops of its own door)
        # has no meaningful "back" to correlate against — rank correlation
        # is numerically unstable on a near-constant x, and "door-first" is
        # trivially true when there is nowhere else to fill from. Covered
        # instead by the room-lag check above, which needs no depth.
        continue
      inc roomsChecked
      let rxs = rankTransform(xs)
      let rys = rankTransform(ys)
      let n = rxs.len.float
      var sumX, sumY, sumXY, sumX2, sumY2: float
      for i in 0 ..< rxs.len:
        sumX += rxs[i]; sumY += rys[i]
        sumXY += rxs[i] * rys[i]
        sumX2 += rxs[i] * rxs[i]
        sumY2 += rys[i] * rys[i]
      let
        num = n * sumXY - sumX * sumY
        den = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))
        corr = if den > 1e-6: num / den else: 0.0
      var maxHop, minArr, maxArr: float
      minArr = ys[0]
      for i in 0 ..< xs.len:
        if xs[i] > maxHop: maxHop = xs[i]
        if ys[i] < minArr: minArr = ys[i]
        if ys[i] > maxArr: maxArr = ys[i]
      echo "  room cells=", cells.len, " n=", xs.len, " corr=", corr,
        " maxHop=", maxHop, " arrRange=[", minArr, "..", maxArr, "]"
      if corr <= 0.8:
        inc corrViolations
    echo "door-first check: roomsChecked=", roomsChecked,
      " corrViolations=", corrViolations
    check roomsChecked > 0
    check corrViolations == 0
