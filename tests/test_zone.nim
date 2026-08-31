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
  let mapSpecJson = readFile(GameDir / "tests" / "fixtures" / "br-match-showmatch-4242.json")
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
    {"z": 0.824, "waitTicks": 3000, "shrinkTicks": 528, "dps": 0},
    {"z": 0.648, "waitTicks": 0, "shrinkTicks": 528, "dps": 2},
    {"z": 0.472, "waitTicks": 0, "shrinkTicks": 528, "dps": 4},
    {"z": 0.296, "waitTicks": 0, "shrinkTicks": 528, "dps": 8},
    {"z": 0.120, "waitTicks": 0, "shrinkTicks": 528, "dps": 12},
    {"z": 0.060, "waitTicks": 0, "shrinkTicks": 180, "dps": 16},
    {"z": 0.001, "waitTicks": 0, "shrinkTicks": 180, "dps": 20}
  ]"""
  BrShowmatchGearUpTicks = 3000
    ## Phase 0's own waitTicks, named once so no check restates it. Every
    ## meniscus measure below samples the CLOSE WINDOW rather than fracs of
    ## the whole schedule: a meniscus only exists on an ADVANCING front (see
    ## EdgeRegimeMinRangePx), and now that half the schedule is a wait,
    ## fracs of the whole thing land mostly in the gear-up where there is
    ## nothing to measure BY CONSTRUCTION. That is not the paint being flat,
    ## it is the instrument sampling a stationary rect — the fracs were
    ## chosen when the whole schedule was a close.
  BrShowmatchTotalTicks = 3000 + 528 + 528 + 528 + 528 + 528 + 180 + 180
    ## 6000 — the GEAR-UP wait plus SEVEN contiguous shrink segments, and
    ## it equals the match's own maxTicks on purpose (see below).
    ##
    ## THE PINK DOES NOT MOVE UNTIL THE SECOND HALF (Maxwell's ruling,
    ## 2026-08-26, after watching the preview: "it should wait a bit, THEN
    ## slowly encroach and not stop until all is pink"). G is 3000, set as
    ## maxTicks/2 by his order and left a plain table number so he can tune
    ## it again. The close then spans 3000 -> 6000 at ~0.6px/tick, which is
    ## still an encroachment rather than a snap. There
    ## are no intermediate holds by design (Maxwell's ruling, 2026-08-25):
    ## every phase past the first carries waitTicks 0, so once the zone
    ## starts closing it never stops. z steps by a constant 0.176 per
    ## 720-tick segment, which makes the rect's own half-extent recede at a
    ## CONSTANT px/tick — "slowly and continuously" stated as geometry
    ## rather than as prose.
    ##
    ## AND IT CLOSES TO NOTHING (Maxwell's spec read faithfully, 2026-08-25:
    ## "continuous to the end, until last man standing"). The earlier table
    ## stopped at z=0.120 and HELD there, which left a 385x205 terminal
    ## room — and a terminal room is a place three duos can sit in forever.
    ## Measured: seed 90210 froze exactly that way, three duos alive and
    ## 13-70px apart for 2205 ticks, not one shot fired, ending on maxTicks.
    ## The last two rows continue the SAME constant recession down to the
    ## smallest scale the config allows (z=0.001; readZonePhaseZ requires
    ## z > 0, so this is the floor, not a rounded zero), with dps ramping
    ## 12 -> 16 -> 20. Their tick counts are proportional to their z steps
    ## precisely so the recession rate does not change: 0.060/245 and
    ## 0.059/241 both equal 0.176/720 to three significant figures.
    ##
    ## With no interior left there is no place to sit, so the wipe rule
    ## fires by ATTRITION rather than by anyone choosing to fight — which
    ## is what makes the endgame independent of the policy stall this
    ## schedule cannot fix (full-health cogs declining point-blank kills;
    ## banked separately as a pre-existing policy defect).

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

suite "shrink zone schedule shape: gear-up then a continuous close":
  ## What 6c122c0 exists to deliver, asserted instead of asserted-in-prose.
  ## The branch's claim is a GEAR-UP (a wait long enough that the natural
  ## opening fight resolves before anything moves) followed by a close that
  ## never stops until terminal size. Both halves were only ever stated in
  ## the config and the commit message; nothing measured them. Measured here
  ## against zoneRectAndDps — the SAME function the damage system reads.
  test "no shrink before the gear-up ends, and the close never HOLDS":
    ## A HOLD is a RUN of zero-recession ticks. Single zero ticks are not
    ## holds: the rect's width is an integer and the schedule recedes it at a
    ## constant SUB-PIXEL rate, so a constant close necessarily alternates
    ## 1,0,1,0. The bound is therefore DERIVED from that rate — a constant
    ## rate r px/tick cannot round to more than ceil(1/r) zeros in a row —
    ## rather than picked, so it holds on any map without retuning.
    var sim = zoneGame(BrShowmatchPhases)
    let
      gearUp = BrShowmatchGearUpTicks
      total = BrShowmatchTotalTicks
      wStart = sim.zoneRectAndDps(gearUp).cur.w
      wEnd = sim.zoneRectAndDps(total).cur.w
      closeTicks = total - gearUp
      ratePxPerTick = float(wStart - wEnd) / float(closeTicks)
      maxRunFromRounding = int(ceil(1.0 / max(ratePxPerTick, 1e-9))) + 1
    var
      firstRecession = -1
      longestZeroRun = 0
      run = 0
      prevW = -1
    for t in 0 .. total:
      let w = sim.zoneRectAndDps(t).cur.w
      if prevW >= 0:
        let d = prevW - w
        if d > 0 and firstRecession < 0: firstRecession = t
        if t > gearUp:
          if d == 0:
            inc run
            longestZeroRun = max(longestZeroRun, run)
          else:
            run = 0
      prevW = w
    echo "schedule shape: firstRecession=", firstRecession, " (gearUp=", gearUp,
      ") closeTicks=", closeTicks, " rate=", ratePxPerTick,
      "px/tick longestZeroRun=", longestZeroRun,
      " bound=", maxRunFromRounding, " terminal=",
      sim.zoneRectAndDps(total).cur.w, "x", sim.zoneRectAndDps(total).cur.h
    ## GEAR-UP: nothing moves until the wait is over.
    check firstRecession > gearUp
    ## CONTINUITY: no run of stillness longer than integer rounding explains.
    check longestZeroRun <= maxRunFromRounding

  test "the zone CLOSES TO NOTHING: no terminal room a duo can sit in":
    ## The land-blocking half of the ruling. Holding at a terminal rect left
    ## a room three duos occupied for 2205 ticks without firing (seed 90210,
    ## which then ended on maxTicks with three duos alive). The fix is not a
    ## bigger dps or a shorter clock — it is that there is NOWHERE LEFT.
    ##
    ## Asserted against the REAL predicate updateZone uses, which is a plain
    ## axis-aligned rect test on the player's CENTRE (no corner rounding —
    ## ZoneCornerRoundPx applies to the PAINT, not to damage), so this
    ## measures the thing that actually kills rather than a lookalike.
    for (label, sim) in [("small test map", zoneGame(BrShowmatchPhases)),
                         ("real showmatch map",
                          zoneGameOnRealMap(BrShowmatchPhases))]:
      var g = sim
      let
        term = g.zoneRectAndDps(BrShowmatchTotalTicks).cur
        footprint = 2 * PlayerHalf   ## a cog's own solid extent, 12px
      echo "  ", label, ": terminal rect ", term.w, "x", term.h,
        " at tick ", BrShowmatchTotalTicks, " (cog footprint ", footprint,
        "px; dps ", g.zoneRectAndDps(BrShowmatchTotalTicks).dps, ")"
      ## SMALLER THAN A COG. Not "small": a rect at least a footprint across
      ## is a place two cogs can stand, which is all the stall needed.
      check term.w < footprint
      check term.h < footprint
      ## ...and it STAYS gone. The schedule holds its last target forever,
      ## so a late tick must not re-open an interior.
      let late = g.zoneRectAndDps(BrShowmatchTotalTicks * 2).cur
      check late.w < footprint
      check late.h < footprint
      ## THE FLOOR IS NOT SILENT. zoneRectAtScale clamps both extents at 1px,
      ## which is what keeps every downstream divisor finite (see
      ## zoneFrontLoopCoordAt's own note). Assert it holds rather than
      ## trusting it: a zero extent would make the rect empty and the
      ## perimeter degenerate.
      check term.w >= 1
      check term.h >= 1
      ## The terminal phase must actually BITE, or "no interior" resolves
      ## nothing.
      check g.zoneRectAndDps(BrShowmatchTotalTicks).dps > 0

  test "the finger family survives a degenerate terminal rect":
    ## The numerics guard the close-to-nothing schedule needed. The paint's
    ## whole fingering family is parameterized against the FINAL rect, and
    ## that rect is now a few px on a side. The failure mode is silent: a
    ## degenerate perimeter collapses the loop coordinate to the origin for
    ## every point on the board, the noise reads one constant, and the front
    ## goes dead flat everywhere — green everywhere except the eye.
    ##
    ## Directly measured: the loop coordinate must still SEPARATE points
    ## that sit at different places along the front. (The straight-run and
    ## turning-angle checks below would also catch a flat front, but they
    ## run on one schedule; this pins the mechanism itself.)
    var sim = zoneGameOnRealMap(BrShowmatchPhases)
    let term = sim.zoneRectAndDps(BrShowmatchTotalTicks).cur
    echo "  terminal rect ", term.w, "x", term.h,
      " -> loop-coord spread over a ring of sample points:"
    var
      lo = Inf
      hi = -Inf
      distinct8 = 0
    var seen: seq[float]
    for k in 0 ..< 16:
      let
        ang = 2.0 * PI * float(k) / 16.0
        px = float(term.x) + 700.0 * cos(ang)
        py = float(term.y) + 700.0 * sin(ang)
        loop = zoneTestFrontLoopCoordAt(px, py, term,
          float(sim.gameMap.width), float(sim.gameMap.height))
        mag = sqrt(loop.a * loop.a + loop.b * loop.b)
      lo = min(lo, mag)
      hi = max(hi, mag)
      var isNew = true
      for v in seen:
        if abs(v - loop.a) < 1e-6: isNew = false
      if isNew:
        seen.add loop.a
        inc distinct8
    echo "    |loop| range [", lo, ",", hi, "]  distinct a-coords=", distinct8
    ## A collapsed family gives |loop| == 0 everywhere and ONE distinct
    ## coordinate. A live one gives a real ring with distinct positions.
    check hi > 1.0
    check distinct8 >= 8

    ## THE METRIC CONTRACT IS NOT 1.0, AND CANNOT BE — measured, and
    ## recorded here instead of asserted, because I wrote the assertion
    ## first and it FAILED (2026-08-26).
    ##
    ## zoneFrontLoopCoordAt's doc says "a stated 160px finger wavelength
    ## means 160px measured along the front", which reads as
    ## |d(loop)/ds| == 1 everywhere on the loop. It is not, and the reason
    ## is structural rather than a bug: the construction maps a RECTANGLE
    ## onto a CIRCLE of the same circumference, and no such map is
    ## arc-length preserving. In the normalized frame the front is a unit
    ## square; the loop's arc rate is ds/dtheta = rho^2 where rho is the
    ## centre-to-boundary distance, so it runs 1.0 at an edge midpoint and
    ## 2.0 at a corner. MEASURED after the aspect fix, sampling all the way
    ## around including corners: 0.75..1.83 at every z from 1000 to 1
    ## permille — flat in z, which is the point. What the aspect fix
    ## removed was the SCALE-DEPENDENT, aspect-induced part (the terminal
    ## rect's per-axis floor turning a 1.874:1 board's fronts into
    ## squares); what remains is the fixed corner-vs-edge variation the
    ## parameterization has always had and always will.
    ##
    ## So the honest claim is "160px on average around the loop, within a
    ## bounded 2x corner/edge variation", and check #7's term A carries
    ## that variation as real slack rather than as a hidden error. Asserted
    ## as: the metric is bounded and, crucially, does NOT drift with z —
    ## a z-dependent metric is exactly what the aspect defect was.
    var mAllLo = Inf
    var mAllHi = -Inf
    for zPermille in [1000, 500, 200, 60, 10, 1]:
      let r = sim.zoneRectAtScale(zPermille)
      var mLo = Inf
      var mHi = -Inf
      for k in 0 ..< 24:
        let
          ang = 2.0 * PI * float(k) / 24.0
          onX = float(r.x) + float(r.w) * 0.5 * (1.0 + cos(ang))
          onY = float(r.y) + float(r.h) * 0.5 * (1.0 + sin(ang))
          tanX = -sin(ang) * float(r.w)
          tanY = cos(ang) * float(r.h)
          tanLen = max(1e-9, sqrt(tanX * tanX + tanY * tanY))
          ux = tanX / tanLen
          uy = tanY / tanLen
          h = 0.05
          a = zoneTestFrontLoopCoordAt(onX - ux * h, onY - uy * h, term,
            float(sim.gameMap.width), float(sim.gameMap.height))
          b = zoneTestFrontLoopCoordAt(onX + ux * h, onY + uy * h, term,
            float(sim.gameMap.width), float(sim.gameMap.height))
          m = sqrt((b.a - a.a) * (b.a - a.a) + (b.b - a.b) * (b.b - a.b)) /
            (2.0 * h)
        mLo = min(mLo, m)
        mHi = max(mHi, m)
      echo "    z=", zPermille, "/1000 -> |d(loop)/ds| in [", mLo, ",", mHi, "]"
      mAllLo = min(mAllLo, mLo)
      mAllHi = max(mAllHi, mHi)
    ## Bounded by the rectangle-onto-circle geometry above (1.0 .. 2.0),
    ## with probe slack. A regression to the per-axis floor would push the
    ## spread WELL outside this and would move with z.
    check mAllLo > 0.70
    check mAllHi < 2.10

  test "the reference speed is anchored to the rect's REAL motion":
    ## The assertion zoneBaseSpeedPxPerTick's own doc had been making in
    ## prose only — and prose is exactly what let it be wrong. That speed
    ## converts ZoneFingerAmpPx into a tick budget, so if it disagrees with
    ## how fast the rect ACTUALLY moves, the meniscus renders at the wrong
    ## depth on every map.
    ##
    ## The existing px->tick conversion test cannot catch that, by
    ## construction: it checks ampTicks * speed == ZoneFingerAmpPx, which is
    ## true for ANY speed because ampTicks is DEFINED as ZoneFingerAmpPx /
    ## speed. It is a tautology dressed as a measurement. This one instead
    ## derives the moving window from the RECT'S OBSERVED MOTION — the first
    ## tick its extents actually change — and never reads waitTicks from the
    ## config, so a schedule whose declared waits and real motion disagree
    ## fails here rather than silently retuning the paint.
    for (label, sim) in [("small test map", zoneGame(BrShowmatchPhases)),
                         ("real showmatch map",
                          zoneGameOnRealMap(BrShowmatchPhases))]:
      var g = sim
      let total = BrShowmatchTotalTicks
      var firstMove = -1
      var prevW = -1
      var prevH = -1
      for t in 0 .. total:
        let r = g.zoneRectAndDps(t).cur
        if prevW >= 0 and (r.w != prevW or r.h != prevH) and firstMove < 0:
          firstMove = t
        prevW = r.w
        prevH = r.h
      let
        final = g.zoneRectAndDps(total).cur
        closure = (float(g.gameMap.width - final.w) * 0.5 +
                   float(g.gameMap.height - final.h) * 0.5) / 2.0
        movingTicks = float(total - (firstMove - 1))
        fromMotion = closure / movingTicks
        reported = g.zoneBaseSpeedPxPerTick(total)
        fromWholeSchedule = closure / float(total)   ## the OLD, wrong form
      echo "  ", label, ": firstMove=", firstMove, " movingTicks=",
        movingTicks, " speedFromMotion=", fromMotion, " reported=", reported,
        " (whole-schedule form would say ", fromWholeSchedule, ")"
      ## ANCHORED: what the code reports IS the rect's own motion.
      check abs(reported - fromMotion) < 0.005
      ## AND THE TEST HAS TEETH ON THIS SCHEDULE: the discarded
      ## whole-schedule form is materially different here, so a regression
      ## back to it fails loudly instead of drifting. (On a schedule with no
      ## wait the two coincide and this arm is vacuous — which is precisely
      ## why the bug was invisible until the gear-up got long.)
      check abs(fromWholeSchedule - fromMotion) > 0.02

  test "ALL PINK: the whole floor is painted by the time the episode ends":
    ## Maxwell's ruling (2026-08-26): "not stop until all is pink." The
    ## close-to-nothing schedule is only half of that promise — the other
    ## half is that the paint actually ARRIVES everywhere before the episode
    ## is over. Those are different claims: the rect reaching zero says the
    ## damage boundary swept the board, while the paint is a FLOW and can
    ## still owe a room its arrival for up to ZoneFlowDelayCapTicks after
    ## the boundary passed. So coverage is measured at the END TICK the
    ## viewer actually stops at, not at "eventually".
    ##
    ## Two residuals are legitimate and are counted separately rather than
    ## waved at:
    ##   * the FINAL CORE — zoneBaseArrivalTickAt reports "never" for points
    ##     inside the final rect grown by ZoneCornerRoundPx, which at a 3x1
    ##     terminal rect is a ~16px disc. It is excluded BY CONSTRUCTION and
    ##     each such cell is checked to actually lie there;
    ##   * SEALED POCKETS — floor with no walkable path from the exterior.
    ##     The solve cannot reach them and neither can a player.
    ## Anything else unpainted is a real hole in the promise.
    for (label, sim) in [("small test map", zoneGame(BrShowmatchPhases)),
                         ("real showmatch map",
                          zoneGameOnRealMap(BrShowmatchPhases))]:
      var g = sim
      discard ensureZoneArrivalField(g)
      let
        (gw, gh) = zoneArrivalFieldGridDims()
        endTick = BrShowmatchTotalTicks
        finalRect = g.zoneRectAndDps(endTick).cur
      var
        paintable = 0
        pinkByEnd = 0
        lateAfterEnd = 0
        neverInCore = 0
        neverElsewhere = 0
        worstArrival = 0
      for gy in 0 ..< gh:
        for gx in 0 ..< gw:
          let
            px = gx * ZoneFieldCellPx + ZoneFieldCellPx div 2
            py = gy * ZoneFieldCellPx + ZoneFieldCellPx div 2
          if not zoneTestPaintableAt(px, py): continue
          inc paintable
          let cell = zoneArrivalFieldCellAt(px, py)
          if not cell.has or cell.arrival == ZoneNeverArrives.int:
            if roundedRectSignedDist(finalRect, ZoneCornerRoundPx,
                float(px), float(py)) <= float(ZoneFieldCellPx):
              inc neverInCore
            else:
              inc neverElsewhere
          elif cell.arrival <= endTick:
            inc pinkByEnd
            worstArrival = max(worstArrival, cell.arrival)
          else:
            inc lateAfterEnd
            worstArrival = max(worstArrival, cell.arrival)
      let pct = 100.0 * float(pinkByEnd) / float(max(1, paintable))
      echo "  ", label, ": paintable=", paintable, " PINK by tick ", endTick,
        "=", pinkByEnd, " (", pct, "%)  stillDryAtEnd=", lateAfterEnd,
        "  neverArrives inCore=", neverInCore, " elsewhere=", neverElsewhere,
        "  worstArrival=", worstArrival
      ## THE PROMISE: the board is pink when the episode ends, and the only
      ## cells allowed to be dry are the mathematically excluded core.
      ##
      ## Measured, real map: 296903 of 296904 cells are pink AT tick 6000 and
      ## the single hold-out arrives at 6001 — ONE tick past the close. That
      ## is not a hole, it is the paint being LATE by a tick, which is the
      ## one direction the honesty contract explicitly allows (paint may lag
      ## the boundary, never precede it). Demanding zero at exactly the close
      ## tick would be asserting that a FLOW finishes on the same tick as the
      ## geometry that drives it.
      ##
      ## So the bound is the close tick plus one second (ZoneDamageRollTicks
      ## — the zone's own cadence, and the coarsest unit anything in this
      ## feature acts on). The client covers precisely this gap: the endcard
      ## completion runs the paint clock past the end to the field's own
      ## maximum, so a cell arriving a tick or sixty late is still SEEN. The
      ## margin is reported, so a real regression — a room owing hundreds of
      ## ticks — fails loudly instead of hiding inside a tolerance.
      let overrun = worstArrival - endTick
      echo "    -> overrun past close = ", overrun,
        " ticks (bound ", ZoneDamageRollTicks, ")"
      check neverElsewhere == 0
      check overrun <= ZoneDamageRollTicks
      check pct > 99.99

  test "the continuity measure DISCRIMINATES: a mid-close hold fails it":
    ## House rule — a gate must MOVE on the defect it names. The same walk
    ## over a schedule carrying a deliberate 300-tick wait in the middle of
    ## the close must read a zero-recession run far above the rounding bound,
    ## or the check above is measuring nothing.
    const HeldPhases = """[
      {"z": 0.824, "waitTicks": 1200, "shrinkTicks": 720, "dps": 0},
      {"z": 0.648, "waitTicks": 0, "shrinkTicks": 720, "dps": 2},
      {"z": 0.472, "waitTicks": 300, "shrinkTicks": 720, "dps": 4},
      {"z": 0.296, "waitTicks": 0, "shrinkTicks": 720, "dps": 8},
      {"z": 0.120, "waitTicks": 0, "shrinkTicks": 720, "dps": 12}
    ]"""
    var sim = zoneGame(HeldPhases)
    let total = BrShowmatchTotalTicks + 300
    var
      longestZeroRun = 0
      run = 0
      prevW = -1
    for t in 0 .. total:
      let w = sim.zoneRectAndDps(t).cur.w
      if prevW >= 0 and t > BrShowmatchGearUpTicks:
        if prevW - w == 0:
          inc run
          longestZeroRun = max(longestZeroRun, run)
        else:
          run = 0
      prevW = w
    echo "held-schedule control: longestZeroRun=", longestZeroRun,
      " ticks (the planted hold is 300)"
    ## The planted hold must be visible as itself, not merely "large".
    check longestZeroRun >= 300

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
  sim: SimServer, fixedCoord, startCoord, stepSign, otherGridMaxPx: int,
  t: int, alongX: bool
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
    let cell = if alongX: zoneArrivalFieldCellAt(fixedCoord, v)
      else: zoneArrivalFieldCellAt(v, fixedCoord)
    cell.has and cell.arrival <= t
  proc walkableAt(v: int): bool =
    if v < 0 or v >= otherGridMaxPx: return false
    let mask = if alongX: zoneD4MaskAt(sim, fixedCoord, v)
      else: zoneD4MaskAt(sim, v, fixedCoord)
    mask.walkable
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
  # Fable's audit (2026-08-25): the ORIGINAL exclusion band here was a
  # generous 40px, wide enough to swallow a genuinely straight run sitting
  # near (but not AT) the map's own edge — exactly what let a real stiff-
  # rectangle regression on one side of a near-edge zone read as "worst=68"
  # instead of flagging it. Paint truly cannot finger PAST the map's own
  # boundary, but that only requires excluding the LITERAL border cell (the
  # walk-off case above already excludes anything that actually ran off the
  # edge); one grid cell of margin is enough to never misread quantization
  # at the exact edge as a straight run, without hiding anything real.
  const MapEdgeExclusionPx = ZoneFieldCellPx
  if coord < MapEdgeExclusionPx or coord >= otherGridMaxPx - MapEdgeExclusionPx:
    return -1
  # A WALL is the other thing paint cannot finger past, same reasoning as
  # the map's own canvas edge above — most real levels wrap their whole
  # playable floor in a boundary wall (see ensureZoneFloorGrid's own
  # border-flood note), so a frontier's tip sitting flat against the
  # floor's OWN edge is the floor genuinely ending, not a stiff-rectangle
  # regression. Only the first cell PAST the tip needs checking: if it is
  # unwalkable, the tip is pinned by geometry, not a fingering failure.
  if not walkableAt(coord + stepSign * ZoneFieldCellPx):
    return -1
  coord

const ZoneSeedBranchTolTicks = 2.0
  ## How far BELOW its own seed a cell may read and still count as sitting on
  ## the seeded branch. Derived from the storage, not chosen for an outcome:
  ## computeZoneFrontierField carries float32 and ensureZoneArrivalField
  ## stores `uint16(clamp(frontier[idx].int, ...))`, and `.int` on a float32
  ## TRUNCATES — up to 1 whole tick — with float32 rounding of the sum
  ## t0 + delay accounting for the other. Deliberately GENEROUS: a larger
  ## tolerance counts MORE cells as seeded and therefore EXCLUDES FEWER
  ## samples, which is the conservative direction for an excluder.

proc zoneSeedBranchAt(sim: SimServer, px, py: int): bool =
  ## Is this cell reading its OWN SEED, t0(p) + zoneBoundaryFingerDelayAt(p)?
  ##
  ## THIS IS THE PREDICATE THAT DECIDES WHETHER CHECK #7'S BOUND APPLIES AT
  ## ALL, and it is the solver's own arithmetic rather than a proxy for it —
  ## the same discipline the room-interior guard uses in reading
  ## zoneTestRoomIdAt, the solver's own source-eligibility test.
  ##
  ## computeZoneFrontierField seeds every eligible exterior cell at exactly
  ## t0 + delay and then lets fast marching relax it DOWNWARD. So a cell
  ## whose stored arrival still equals its seed was never improved by
  ## propagation: its value is the receding boundary plus the nudge, which
  ## is precisely and only what term A models. A cell reading BELOW its seed
  ## was reached by flow from somewhere else — a different branch of the
  ## minimum-time solution — and term A, derived wholly from
  ## zoneBoundaryFingerDelayAt's two octaves, says nothing about it.
  let cell = zoneArrivalFieldCellAt(px, py)
  if not cell.has or cell.arrival == ZoneNeverArrives.int: return false
  let
    totalTicks = zoneTestScheduleTotalTicks(sim)
    finalRect = sim.zoneRectAndDps(totalTicks).cur
    ampTicks = zoneFingerAmpTicksFor(zoneBaseSpeedPxPerTick(sim, totalTicks))
    cx = float((px div ZoneFieldCellPx) * ZoneFieldCellPx +
      ZoneFieldCellPx div 2)
    cy = float((py div ZoneFieldCellPx) * ZoneFieldCellPx +
      ZoneFieldCellPx div 2)
    t0 = zoneTestBaseArrivalTickAt(sim, cx, cy, totalTicks, finalRect)
  if t0 == high(int): return false
  let delay = zoneTestFingerDelayAt(cx, cy, finalRect,
    float(sim.gameMap.width), float(sim.gameMap.height), ampTicks)
  (float(t0) + delay) - float(cell.arrival) <= ZoneSeedBranchTolTicks

proc frontierIsolineCoord(
  sim: SimServer, fixedCoord, startCoord, stepSign, otherGridMaxPx: int,
  t: int, alongX: bool
): tuple[pos: float, span: int, seeded: bool] =
  ## The frontier's own position on one row/column, at tick t — the
  ## INNERMOST painted cell, found by walking OUTWARD from the rect's own
  ## edge and returning the FIRST painted cell, then INTERPOLATED to
  ## sub-cell precision against the bracketing cells' own arrival ticks.
  ##
  ## Fable's audit (2026-08-25), two separate instrument defects:
  ##
  ## PREMISE. `frontierTipCoord` walks the same ray but returns the LAST
  ## painted cell before the first unpainted one, and bails (-1) unless
  ## `startCoord` is ALREADY painted. That is inverted for a SHRINKING
  ## zone. The rect contracts, so the exterior is painted FIRST and the
  ## paint advances INWARD: at tick t there is an unpainted band just
  ## outside the rect (every exterior cell owes its own flow delay before
  ## it arrives), and the newest paint — the meniscus — is the cell
  ## CLOSEST to the rect. Measured on the real showmatch map at t=2520
  ## (rect y-span [943,1627]), the profile walking out from the rect's
  ## right edge reads `......PPPPPP...`: six unpainted cells, THEN paint.
  ## frontierTipCoord returns -1 for every one of those rows, and the only
  ## rows it does report are ~200px ABOVE the rect's y-span, where the
  ## whole row is old exterior — there its "tip" lands either on the 4px
  ## unpainted sliver against the map's own border wall (x=3196, D4 dump
  ## `P_########`) or on an unpainted ROOM interior mid-map (x=2720, dump
  ## `P_____PPPP`, room row `eerrrreeee`). Those two artifacts, not the
  ## paint, produced the 89.7deg turning angle and the 394.9px amplitude
  ## three previous passes chased through the propagation term and the
  ## corner frame — and they are why two propagation-side hypotheses
  ## measured EXACTLY zero effect to 11 significant figures.
  ##
  ## RESOLUTION. Returning the painted CELL's own coordinate quantizes the
  ## isoline onto the 4px field grid while the polyline is also sampled
  ## every 4px, so a one-cell step reads as a 45deg turn and a two-cell
  ## step as atan(2) = 63.43deg — for ANY isoline that is not perfectly
  ## flat, at any true curvature. Those were exactly the first two numbers
  ## the rewired check #7 reported. The arrival field is continuous in
  ## TIME even where it is discrete in space, so the honest sub-cell
  ## position is where arrival crosses t between the last unpainted cell
  ## (arrival > t) and the first painted one (arrival <= t), linearly in
  ## the arrival tick. That is a real measurement of the field, not a
  ## smoothing of the polyline: no window, no lost spike.
  ##
  ## Invalid (-1.0), each case an honest "this row has no open-field
  ## meniscus", never a silently-clamped number:
  ##  * `startCoord` already painted — the front is not ahead of this edge
  ##    on this row (a row wholly outside the rect's own span, or inside
  ##    the corner-round tolerance), so this edge does not own it;
  ##  * a wall / off-grid cell reached before any paint — the row is
  ##    occluded by architecture, and a room's fill is the room-lag and
  ##    door-first checks' business, not this one's;
  ##  * an INTERIOR-ROOM cell (zoneTestRoomIdAt >= 0) reached before any
  ##    paint — architecture just as much as a wall is, and the third
  ##    instrument defect this walk has now had (Fable's audit, 2026-08-25;
  ##    the 16x excess over check #7's analytic turning bound). A ray that
  ##    grazes a building crosses its INTERIOR without ever touching a wall
  ##    CELL, and that interior is unpainted long after the open floor
  ##    around it is — door-first fill is the design, asserted by its own
  ##    two checks. The walk then steps straight over the building and
  ##    reports the first painted cell on its FAR side, so the number it
  ##    returns is the building's own back wall, not the paint meniscus.
  ##    Measured on the small map at t=2640, zesBottom: samples 45-48 all
  ##    walk through ROOM 24's interior (arrivals 2791..2916 against
  ##    t=2640), room 24 is one 4px cell deeper at sample 48 than at 47,
  ##    and the isoline duly "steps" 4.15px in one 4px stride — a 41.01deg
  ##    turn, the single worst in the whole check, produced entirely by
  ##    architecture. Guarding it drops the small map's worst turning angle
  ##    from 41.01deg to 3.37deg at a cost of 8 of 925 samples. The
  ##    predicate is zoneTestRoomIdAt, i.e. LITERALLY the one
  ##    computeZoneFrontierField's own source-eligibility test uses, so
  ##    "what counts as architecture" cannot drift between the solver and
  ##    the instrument that measures it;
  ##  * a never-arriving cell reached before any paint — a sealed pocket;
  ##  * no paint at all within the walk budget.
  proc probe(v: int): tuple[ok, occluded: bool, arrival: int] =
    if v < 0 or v >= otherGridMaxPx: return (false, true, 0)
    let mask = if alongX: zoneD4MaskAt(sim, fixedCoord, v)
      else: zoneD4MaskAt(sim, v, fixedCoord)
    if not mask.walkable: return (false, true, 0)
    # An interior-room cell is ARCHITECTURE, and gets a wall's treatment
    # exactly — see the invalid-case list above for the measurement.
    let roomId = if alongX: zoneTestRoomIdAt(fixedCoord, v)
      else: zoneTestRoomIdAt(v, fixedCoord)
    if roomId >= 0: return (false, true, 0)
    let cell = if alongX: zoneArrivalFieldCellAt(fixedCoord, v)
      else: zoneArrivalFieldCellAt(v, fixedCoord)
    if not cell.has or cell.arrival == ZoneNeverArrives.int:
      return (false, true, 0)
    (cell.arrival <= t, false, cell.arrival)
  const MaxWalkSteps = 300  ## * ZoneFieldCellPx = 1200px
  const Invalid = (pos: -1.0, span: 0, seeded: false)
  var prev = probe(startCoord)
  if prev.occluded or prev.ok:
    return Invalid
  var
    coord = startCoord
    steps = 0
  while steps < MaxWalkSteps:
    let nextCoord = coord + stepSign * ZoneFieldCellPx
    inc steps
    let cur = probe(nextCoord)
    if cur.occluded:
      return Invalid
    if cur.ok:
      # Require the paint to CONTINUE outward, so one speckled cell is
      # never read as the front (the same discipline frontierTipCoord's
      # own map-edge/wall guards apply to its end of the ray).
      for k in 1 .. 2:
        let n = probe(nextCoord + stepSign * k * ZoneFieldCellPx)
        if not n.ok:
          return Invalid
      # Never let the literal map-border cell read as a front position.
      if nextCoord < ZoneFieldCellPx or
          nextCoord >= otherGridMaxPx - ZoneFieldCellPx:
        return Invalid
      # Sub-cell crossing: arrival DECREASES walking outward, so the
      # isoline arrival == t sits between `coord` (arrival > t) and
      # `nextCoord` (arrival <= t).
      #
      # The SPAN — this bracket's own arrival difference, in whole ticks —
      # is returned alongside the position because it IS this sample's
      # measurement resolution. The shipped arrival field is uint16 WHOLE
      # TICKS (ensureZoneArrivalField truncates the solver's float32), so
      # `frac` is a ratio of integers and the finest position increment
      # this walk can express is ZoneFieldCellPx/span px. Check #7 needs
      # that number to tell a real kink from the instrument's own floor —
      # see ZoneQuantTurnDeg.
      let span = prev.arrival - cur.arrival
      var frac = 0.0
      if span > 0:
        frac = clamp(float(prev.arrival - t) / float(span), 0.0, 1.0)
      # Both bracket cells must be on the seeded branch for this sample to
      # be one check #7's bound describes — see zoneSeedBranchAt.
      let seeded =
        (if alongX: zoneSeedBranchAt(sim, fixedCoord, coord)
         else: zoneSeedBranchAt(sim, coord, fixedCoord)) and
        (if alongX: zoneSeedBranchAt(sim, fixedCoord, nextCoord)
         else: zoneSeedBranchAt(sim, nextCoord, fixedCoord))
      return (pos: float(coord) +
        float(stepSign) * float(ZoneFieldCellPx) * frac, span: span,
        seeded: seeded)
    coord = nextCoord
    prev = cur
  Invalid

proc frontierIsolineSeq(
  sim: SimServer, fixedCoord, startCoord, stepSign, otherGridMaxPx: int,
  loStart, hiEnd: int, t: int, alongX: bool
): tuple[pos: seq[float], span: seq[int], seeded: seq[bool]] =
  ## frontierIsolineCoord sampled every ZoneFieldCellPx along one edge —
  ## the raw isoline polyline (-1.0 for a gap), the input checks #7 and #8
  ## measure, plus each sample's own interpolation SPAN in whole ticks (0
  ## for a gap) so check #7 can price the instrument's own resolution.
  ## ONE walk produces both: the real showmatch map is 3211x1713 and this
  ## is the dominant cost in the paint suite, so a second pass just to
  ## recover the spans is not free.
  var v = loStart
  while v <= hiEnd:
    let s = frontierIsolineCoord(sim, v, startCoord, stepSign,
      otherGridMaxPx, t, alongX)
    result.pos.add s.pos
    result.span.add s.span
    result.seeded.add s.seeded
    v += ZoneFieldCellPx

template isoValid(v: float): bool = v >= 0.0

proc validCount(seqv: seq[float]): int =
  for v in seqv:
    if isoValid(v): inc result

proc longestFlatRunPx(tipSeq: seq[float], tolPx: float): float =
  ## The longest run of CONSECUTIVE valid samples whose isoline position
  ## never leaves a +/-tolPx band around the run's own first value — the
  ## sub-cell-resolved successor to "the tip coordinate repeated exactly",
  ## which is meaningless once the position is interpolated rather than
  ## snapped to the 4px grid. A fingered isoline leaves the band every
  ## finger wavelength; a bare rectangle edge never leaves it at all.
  result = 0.0
  var
    runStart = 0.0
    runLen = 0.0
    inRun = false
  for v in tipSeq:
    if not isoValid(v):
      inRun = false
      continue
    if not inRun or abs(v - runStart) > tolPx:
      runStart = v
      runLen = float(ZoneFieldCellPx)
      inRun = true
    else:
      runLen += float(ZoneFieldCellPx)
    result = max(result, runLen)

const
  ## The rect's own CORNER is a designed 90-degree turn (rounded to
  ## ZoneCornerRoundPx), so any sample window that crosses it necessarily
  ## reads a near-90deg turning angle no matter how smooth the paint is.
  ## Measured: with the isoline instrument correct, EVERY worst turning
  ## step on the real map landed 5-8px from a rect y-extreme (t=1008 y=1672
  ## of span [382,1677]; t=2520 y=1620 of [943,1627]; t=2856 y=1612 of
  ## [1019,1620]) — the corner, every time. An edge is therefore sampled
  ## only over its own STRAIGHT section, inset past the corner round plus
  ## the furthest the front can lag behind the rect at this amplitude
  ## (~21px), which is how far the corner's influence actually reaches.
  EdgeCornerInsetPx = 40
  ## A meniscus only exists on an ADVANCING front. During a wait phase —
  ## and for the first ticks of a shrink that follows one — the paint has
  ## caught up with the rect, every exterior cell has already arrived, and
  ## the isoline IS the rect's own edge: straight by construction, and the
  ## honesty check already guarantees it never precedes the rect. Measured
  ## with fingering compiled OUT (-d:zoneFlatPaintControl) against
  ## fingering ON, the longest flat run at those ticks is IDENTICAL
  ## (t=2184: 344px both ways; t=1512: 468 vs 460), while at genuinely
  ## advancing ticks it moves hard (t=1848: 108 vs 344; t=2520: 116 vs
  ## 252). An edge whose isoline has less dynamic range than this is not
  ## below tolerance, it is outside the regime the check measures, and it
  ## SKIPS AND SAYS SO rather than passing silently or failing on physics
  ## that cannot exist.
  EdgeRegimeMinRangePx = 6.0

proc isoRangePx(tipSeq: seq[float]): float =
  ## Dynamic range of the valid samples — the regime measure above.
  var lo = Inf
  var hi = -Inf
  for v in tipSeq:
    if isoValid(v):
      lo = min(lo, v)
      hi = max(hi, v)
  if lo > hi: 0.0 else: hi - lo

type ZoneEdgeSide = enum zesLeft, zesRight, zesTop, zesBottom

proc edgeIsolineFull(sim: SimServer, rect: MapRect, t: int, gw, gh: int,
    side: ZoneEdgeSide): tuple[pos: seq[float], span: seq[int], seeded: seq[bool]] =
  ## One edge's isoline over that edge's own STRAIGHT section — the single
  ## sampler every meniscus check shares, so the corner-inset and regime
  ## rules cannot drift apart between checks. Returns the polyline AND each
  ## sample's interpolation span (see frontierIsolineCoord); `edgeIsoline`
  ## below is the position-only view every check except #7 wants.
  let
    gwPx = gw * ZoneFieldCellPx
    ghPx = gh * ZoneFieldCellPx
    yLo = max(0, rect.y + EdgeCornerInsetPx)
    yHi = min(ghPx - 1, rect.y + rect.h - 1 - EdgeCornerInsetPx)
    xLo = max(0, rect.x + EdgeCornerInsetPx)
    xHi = min(gwPx - 1, rect.x + rect.w - 1 - EdgeCornerInsetPx)
  const Empty = (pos: newSeq[float](), span: newSeq[int](),
    seeded: newSeq[bool]())
  case side
  of zesLeft:
    if yHi <= yLo: return Empty
    frontierIsolineSeq(sim, 0, rect.x, -1, gwPx, yLo, yHi, t, alongX = false)
  of zesRight:
    if yHi <= yLo: return Empty
    frontierIsolineSeq(sim, 0, rect.x + rect.w - 1, 1, gwPx, yLo, yHi, t,
      alongX = false)
  of zesTop:
    if xHi <= xLo: return Empty
    frontierIsolineSeq(sim, 0, rect.y, -1, ghPx, xLo, xHi, t, alongX = true)
  of zesBottom:
    if xHi <= xLo: return Empty
    frontierIsolineSeq(sim, 0, rect.y + rect.h - 1, 1, ghPx, xLo, xHi, t,
      alongX = true)

proc edgeIsoline(sim: SimServer, rect: MapRect, t: int, gw, gh: int,
    side: ZoneEdgeSide): seq[float] =
  edgeIsolineFull(sim, rect, t, gw, gh, side).pos

proc inRegime(iso: seq[float]): bool =
  ## An edge measures a meniscus only if it has enough valid samples AND
  ## enough dynamic range to tell one from a straight line at all.
  validCount(iso) >= 3 and isoRangePx(iso) >= EdgeRegimeMinRangePx

proc longestStraightRunPx(sim: SimServer, rect: MapRect, t: int, gw, gh: int
): tuple[longestPx: float, samples: int, edgesUsed, edgesSkipped: int,
         minRange, maxRange: float] =
  ## For each of the rect's 4 sides, traces the frontier ISOLINE (see
  ## frontierIsolineCoord — this used to call frontierTipCoord, whose
  ## inverted premise returned -1 for every row that has a frontier at
  ## all, which is why this check reported worst=0 on ZERO valid samples
  ## and had never once measured the paint) and returns the longest run of
  ## consecutive samples whose position never leaves a +/-1px band: a
  ## fingered isoline leaves the band every finger wavelength, a bare
  ## rectangle edge never leaves it.
  ##
  ## Each edge is sampled over its own STRAIGHT section only
  ## (EdgeCornerInsetPx), and an edge whose isoline dynamic range is below
  ## EdgeRegimeMinRangePx is SKIPPED and reported, never folded into the
  ## result — see those constants for the measurements behind both.
  const FlatTolPx = 1.0
  var
    longest = 0.0
    samples = 0
    used = 0
    skipped = 0
    minRange = Inf
    maxRange = 0.0
  for side in ZoneEdgeSide:
    let iso = edgeIsoline(sim, rect, t, gw, gh, side)
    let n = validCount(iso)
    if n < 3:
      inc skipped
      continue
    let r = isoRangePx(iso)
    minRange = min(minRange, r)
    maxRange = max(maxRange, r)
    if not inRegime(iso):
      inc skipped
      continue
    inc used
    samples += n
    longest = max(longest, longestFlatRunPx(iso, FlatTolPx))
  if minRange == Inf: minRange = 0.0
  (longest, samples, used, skipped, minRange, maxRange)

proc maxTurningAngleDeg(tipSeq: seq[float]): float =
  ## Turning angle (degrees, unsigned) between every pair of CONSECUTIVE
  ## segments of the polyline (alongEdge, tip) traced by tipSeq — each
  ## sample is ZoneFieldCellPx apart along the edge; a -1 (gap: no tip this
  ## sample, per frontierTipCoord's own degenerate cases) breaks the
  ## polyline rather than being treated as a real vertex, the same
  ## discipline longestStraightRunPx's run-tracking already uses. A real
  ## viscous meniscus is curvature-limited (Maxwell's "no sharp points"
  ## ruling, 2026-08-25) — every tongue and cove rounded, never a jagged
  ## triangular spike — so the polyline's own turning angle between
  ## adjacent 2-segment windows is the direct, measurable proxy: a smooth
  ## arc turns a little every step; a spike turns a lot in one step.
  result = 0.0
  var prevDx, prevDy: float
  var havePrev = false
  for i in 1 ..< tipSeq.len:
    if not isoValid(tipSeq[i - 1]) or not isoValid(tipSeq[i]):
      havePrev = false
      continue
    let
      dx = float(ZoneFieldCellPx)
      dy = tipSeq[i] - tipSeq[i - 1]
    if havePrev:
      let
        cross = prevDx * dy - prevDy * dx
        dot = prevDx * dx + prevDy * dy
        angleRad = arctan2(abs(cross), dot)
        angleDeg = angleRad * 180.0 / PI
      result = max(result, angleDeg)
    prevDx = dx
    prevDy = dy
    havePrev = true

const
  ## CHECK #7's OWN RESOLUTION FLOOR, derived, never chosen. The shipped
  ## arrival field is uint16 WHOLE TICKS (ensureZoneArrivalField truncates
  ## the solver's float32), and frontierIsolineCoord recovers a sub-cell
  ## position by interpolating between two of those integers — so the
  ## finest position increment it can express is ZoneFieldCellPx/span px,
  ## where `span` is that bracket's own arrival difference in ticks. A
  ## SMALL span therefore means a COARSE isoline, and a coarse isoline
  ## manufactures turning angle out of nothing.
  ##
  ## THE FLOOR IS A PERPENDICULAR-CROSSING FLOOR, AND ONLY THAT (corrected
  ## 2026-08-26). It used to be asserted as a floor on EVERY sample, from
  ## this argument: F = zoneSpeedFieldAt is a product of three multipliers
  ## each <= 1.0, so the arrival field's |grad T| = 1/(baseSpeed*F) is at
  ## least 1/baseSpeed, so one ZoneFieldCellPx step must differ by at least
  ## ZoneFieldCellPx/baseSpeed ticks.
  ##
  ## That argument silently assumes the WALK RAY IS PARALLEL TO grad T. The
  ## instrument does not measure |grad T|; it measures the arrival
  ## difference along its own fixed walk axis, which is |grad T| * cos(theta)
  ## for theta the angle between that axis and the gradient. An OBLIQUE
  ## crossing therefore has a legitimately smaller span, and as the isoline
  ## tilts toward the walk direction the span goes to ZERO — no positive
  ## floor survives, and a single ray cannot separate theta from |grad T| to
  ## recover one. MEASURED: 14.2% of the real map's scored vertices and
  ## 22.7% of the small map's are tilted past the tuning's own slope, and
  ## the real map duly reported minSpan 2 against this "floor" of 3. The
  ## check was failing on a theorem that is not true.
  ##
  ## What IS true, and is what the two checks below now assert:
  ##  * span >= 1 for any valid bracket, by the bracket's own definition
  ##    (prev.arrival > t >= cur.arrival);
  ##  * a PERPENDICULAR crossing still obeys the original derivation, so the
  ##    steepest sample on an edge must reach it. Asserting the MAXIMUM span
  ##    clears the perpendicular floor proves the field really is as steep
  ##    as the schedule says AND that the instrument really does see
  ##    square-on crossings — which is the thing the old floor was reaching
  ##    for, stated about the sample it actually holds for.
  ## Term B is priced PER SAMPLE anyway (see maxTurningExcessDeg), so one
  ## coarse oblique sample can only loosen its own vertex, never the edge.
  ZoneArrivalSpanFloorTicks = 1  ## a valid bracket's own definition
proc zoneSpanPerpFloorTicks(baseSpeed: float): float =
  ## The original derivation, kept and stated where it is TRUE: a crossing
  ## square-on to the front differs by at least ZoneFieldCellPx/baseSpeed
  ## ticks over one cell (F <= 1), less the 1 tick that truncating both ends
  ## to whole ticks can cost.
  float(ZoneFieldCellPx) / max(baseSpeed, 1e-9) - 1.0
const
  ## The px amplitude each of the two meniscus octaves carries, derived
  ## from zoneBoundaryFingerDelayAt's own arithmetic: it combines the two
  ## octaves as 0.5*n1 + 0.5*n2 (each n in [-1,1]), maps that to [0,1] and
  ## scales by ampTicks, whose PIXEL value is ZoneFingerAmpPx by the
  ## conversion the first test in this suite asserts. Displacement along
  ## the front is therefore
  ##   y(s) = ZoneFingerAmpPx * (0.5 + 0.25*n1(s) + 0.25*n2(s)),
  ## i.e. ZoneFingerAmpPx/4 per octave.
  ZoneFingerOctaveAmpPx = ZoneFingerAmpPx / 4.0

proc octaveTurnDeg(ampPx, wavelenPx: float): float =
  ## One octave's worst contribution to the turning angle of a polyline
  ## sampled every ZoneFieldCellPx, in degrees.
  ##
  ## Modelled as the WORST curve of that wavelength — a pure sinusoid of
  ## amplitude `ampPx`, peak curvature ampPx*(2*PI/wavelenPx)^2 — and a
  ## polyline turns by curvature * arc length per step. DELIBERATELY
  ## conservative: the real octave is cosine-eased value noise on a
  ## lattice of that same spacing (zoneMeniscusOctave), whose peak
  ## curvature is ampPx*PI^2/wavelenPx^2, a FOURTH of the sinusoid's. This
  ## is an upper bound on the configured look, not a fit to it.
  ampPx * pow(2.0 * PI / wavelenPx, 2.0) * float(ZoneFieldCellPx) *
    180.0 / PI

proc zoneFingerAmplitudeTurnDeg(): float =
  ## TERM A of check #7's honest bound: the turning angle the CONFIGURED
  ## look itself asks for, per ZoneFieldCellPx step. Board-independent by
  ## construction — every input is a tuning constant, and the px
  ## re-denomination is exactly what makes it so (the same 21px of visible
  ## meniscus on every map, see ZoneFingerAmpPx). Currently 2.56 deg:
  ## 1.86 from the 160px octave plus 0.70 from the 260px one.
  octaveTurnDeg(ZoneFingerOctaveAmpPx, ZoneFingerOctaveFinePx) +
    octaveTurnDeg(ZoneFingerOctaveAmpPx, ZoneFingerOctaveCoarsePx)

proc zoneQuantTurnDeg(span: int): float =
  ## TERM B of check #7's honest bound, and DISTINCT IN KIND from term A:
  ## term A is a property of the PAINT, this is a property of the
  ## INSTRUMENT — how much turning angle the arrival field's own whole-tick
  ## quantization can fabricate at a sample whose bracket spans `span`
  ## ticks (see ZoneArrivalSpanFloorTicks).
  ##
  ## One quantum of isoline position is q = ZoneFieldCellPx/span px. Two
  ## consecutive segments of the polyline can each be displaced by up to
  ## one quantum, in opposite directions, while the true front is dead
  ## straight; the angle that fabricates is 2*atan(q/ZoneFieldCellPx),
  ## i.e. 2*atan(1/span) — the cell size cancels, so this is a pure
  ## function of the field's tick resolution.
  ##
  ## MEASURED, and it is the whole of the residual: with the room-interior
  ## defect fixed, the worst turning angle on the small map is 3.366 deg
  ## at span 17 (atan(1/17) = 3.3665) and on the real map's right edge
  ## 11.310 deg at span 5 (atan(1/5) = 11.3099) — both EXACTLY one
  ## quantum, to five significant figures, on two maps whose base speeds
  ## differ 2.6x. The bound allows two (one per segment), so it carries
  ## real slack over what the instrument actually does.
  2.0 * arctan(1.0 / float(max(span, 1))) * 180.0 / PI

const
  ## EdgeRegimeMinRangePx's rule, applied LOCALLY. That constant already
  ## states the principle — "a meniscus only exists on an ADVANCING front;
  ## once the paint has caught up with the rect the isoline IS the rect's
  ## own edge, straight by construction" — but it is tested once per EDGE,
  ## against the whole edge's dynamic range, and the phenomenon is LOCAL:
  ## an edge can be firmly in regime over most of its length while a short
  ## stretch of it has already touched down on the rect line.
  ##
  ## At a touchdown the measured isoline is max(front, rectEdge) — the
  ## honesty clamp (computeZoneFrontierField's closing pass raises every
  ## cell to its own t0), which is an asserted invariant of the paint, not
  ## a defect. A max() of a smooth curve against a straight line has a
  ## genuine corner at every crossing, so a sample window spanning one
  ## necessarily reads a large turning angle no matter how smooth the
  ## paint is — EXACTLY the argument EdgeCornerInsetPx already makes for
  ## the rect's own 90-degree corners, which are the clamp's other
  ## corner-generator.
  ##
  ## A touchdown shows up as a SHORT run of valid samples: the rows to
  ## either side report no meniscus at all (frontierIsolineCoord's
  ## "startCoord already painted" case). So the rule is a run-length floor,
  ## and the floor is the finest feature the tuning can actually put on the
  ## front — half of ZoneFingerOctaveFinePx. A run shorter than that cannot
  ## contain a meniscus feature; it can only contain a touchdown.
  ##
  ## MEASURED, real showmatch map, TOP edge at t=2160: a 5-sample run at
  ## x=1209..1225 where the front lags the rect line by 0.31, 2.08, 4.31,
  ## 2.46, 0.59px, with every row on both sides already caught up. Wall
  ## distance is 24-64px across all of it, so this is open field, not
  ## architecture. It reads 53.89 degrees — a 4.3px bump over 20px of a
  ## 3211px map. (That edge is not one the real-map check below samples,
  ## which is why the suite was green without this rule; it is in because a
  ## bound that holds only by not looking is not justified.)
  MinMeniscusRunSamples = int(ZoneFingerOctaveFinePx / 2.0) div ZoneFieldCellPx

proc runLengths(pos: seq[float]): seq[int] =
  ## For each sample, the length of the maximal run of consecutive VALID
  ## samples containing it (0 if invalid).
  result = newSeq[int](pos.len)
  var i = 0
  while i < pos.len:
    if not isoValid(pos[i]):
      inc i
      continue
    var j = i
    while j < pos.len and isoValid(pos[j]): inc j
    for k in i ..< j: result[k] = j - i
    i = j

proc maxTurningExcessDeg(pos: seq[float], span: seq[int],
    seeded: seq[bool], ampDeg: float):
    tuple[excessDeg, turnDeg, allowDeg: float,
          idx, atSpan, minSpan, maxSpan, scored, offRegime, offBranch: int] =
  ## Check #7's assertion quantity: the worst amount by which the measured
  ## turning angle EXCEEDS what term A plus that sample's OWN term B allow.
  ##
  ## Priced per sample rather than once per edge on purpose. A single
  ## low-span sample would otherwise loosen the bound across the whole
  ## edge, which is exactly how a derived bound quietly becomes a chosen
  ## one. Gaps break the polyline, the same discipline every other measure
  ## here uses, and a run too short to hold a meniscus feature at all is
  ## reported as off-regime rather than scored (MinMeniscusRunSamples).
  result = (-Inf, 0.0, 0.0, -1, 0, high(int), 0, 0, 0, 0)
  let runs = runLengths(pos)
  for i in 0 ..< pos.len:
    if isoValid(pos[i]):
      result.minSpan = min(result.minSpan, span[i])
      result.maxSpan = max(result.maxSpan, span[i])
  if result.minSpan == high(int): result.minSpan = 0
  for i in 2 ..< pos.len:
    if not isoValid(pos[i - 2]) or not isoValid(pos[i - 1]) or
        not isoValid(pos[i]):
      continue
    if runs[i] < MinMeniscusRunSamples:
      inc result.offRegime
      continue
    ## THE SHOCK EXCLUDER (Fable's ruling, 2026-08-26). A vertex is scored
    ## only if all three of its samples sit on the SEEDED branch — see
    ## zoneSeedBranchAt, and check #7's own doc for the derivation. Counted
    ## and printed, never silent, exactly like the other two excluders.
    if not (seeded[i - 2] and seeded[i - 1] and seeded[i]):
      inc result.offBranch
      continue
    inc result.scored
    let
      h = float(ZoneFieldCellPx)
      prevDy = pos[i - 1] - pos[i - 2]
      dy = pos[i] - pos[i - 1]
      cross = h * dy - prevDy * h
      dot = h * h + prevDy * dy
      turn = arctan2(abs(cross), dot) * 180.0 / PI
      s = min(span[i - 2], min(span[i - 1], span[i]))
      allow = ampDeg + zoneQuantTurnDeg(s)
    if turn - allow > result.excessDeg:
      result = (turn - allow, turn, allow, i, s, result.minSpan,
        result.maxSpan, result.scored, result.offRegime, result.offBranch)
  ## An edge with NO scored vertex reports -Inf and `idx < 0`, never 0.0:
  ## a zero would be indistinguishable from a perfectly-met bound, would
  ## win the max() against every real (negative) excess on every other
  ## edge, and would then PASS a `<= 0.0` assertion on no evidence at all.
  ## Callers must gate on `idx >= 0`.

proc worstStepOf(tipSeq: seq[float]): tuple[px: float, idx: int] =
  ## The single largest jump between CONSECUTIVE valid samples, and where.
  ## Reported unconditionally next to every turning-angle result: an angle
  ## alone cannot tell a genuine curvature failure from the isoline
  ## stepping around a piece of architecture, and locating the worst step
  ## is what turned the original 89.7deg number from "a kink in the paint"
  ## into "a map-border sliver 200px outside the sampled edge".
  result = (0.0, -1)
  for i in 1 ..< tipSeq.len:
    if isoValid(tipSeq[i - 1]) and isoValid(tipSeq[i]):
      let j = abs(tipSeq[i] - tipSeq[i - 1])
      if j > result.px: result = (j, i)

proc maxAmplitudeDeviationPx(tipSeq: seq[float], windowSamples: int): float =
  ## Check #8 (Maxwell's ruling, 2026-08-25, close-zoom review of the
  ## fresh recording: "it gets way too stretched out at points, there
  ## should be a limit to the amplitude at the meniscus"): for every VALID
  ## sample in the tip polyline, compares it against the mean of a LOCAL
  ## window (+/- windowSamples along the edge, gaps skipped) and returns
  ## the worst |tip - localMean| seen — a smoothed local reference instead
  ## of one global mean, so a genuine gentle drift over hundreds of px
  ## (the front is not required to sit still) is never confused with a
  ## sharp local stretch (a tongue racing far past its own neighbourhood).
  result = 0.0
  let n = tipSeq.len
  for i in 0 ..< n:
    if not isoValid(tipSeq[i]): continue
    var
      sum = 0.0
      count = 0
    for j in max(0, i - windowSamples) .. min(n - 1, i + windowSamples):
      if not isoValid(tipSeq[j]): continue
      sum += tipSeq[j]
      inc count
    if count < 3: continue  # not enough local context to mean anything
    let localMean = sum / float(count)
    result = max(result, abs(tipSeq[i] - localMean))

suite "shrink zone paint arrival: fingering and front-propagation causality":
  ## The remaining four of Fable's six machine checks, all against the real
  ## BrShowmatchPhases schedule: no straight runs (the frontier must read
  ## as fingered, not a bare rectangle), a room never fills faster than the
  ## open floor outside its own doorway, and a room fills door-first (its
  ## arrival is monotone with walk-distance from the door — the emergent
  ## proof that computeZoneFrontierField's causality, not a hand-built
  ## room classifier, is what produces the shape).
  test "the px->tick amplitude conversion is honoured, and its clamp is never silent":
    ## Coordinator's condition on the px re-denomination (2026-08-25):
    ## ZoneFingerAmpPx is converted per map via that map's own front speed,
    ## and a pathologically slow schedule would balloon 21px into hundreds
    ## of ticks — so the conversion is CLAMPED, and the clamp must never
    ## bind quietly. This asserts the clamp is clear on both real maps and
    ## prints the conversion either way, plus the fidelity condition: the
    ## map Maxwell actually judged must still get the amplitude he
    ## approved (70 ticks, i.e. ZoneFingerAmpPx / 0.304).
    for (label, sim) in [("small test map", zoneGame(BrShowmatchPhases)),
                         ("real showmatch map", zoneGameOnRealMap(BrShowmatchPhases))]:
      var g = sim
      let
        speed = g.zoneBaseSpeedPxPerTick(BrShowmatchTotalTicks)
        ticks = zoneFingerAmpTicksFor(speed)
        binds = zoneFingerAmpClampBinds(speed)
      echo "  ", label, ": baseSpeed=", speed, "px/tick -> ampTicks=", ticks,
        " (ampPx=", ZoneFingerAmpPx, ", ceiling=", ZoneFingerAmpMaxTicks,
        ", clampBinds=", binds, ") -> visible amplitude=",
        ticks * speed, "px"
      check not binds
      # The whole point of the re-denomination: the visible amplitude is
      # the SAME on every map, which is what "Maxwell approved a look"
      # means once the ruling stops being denominated in ticks.
      check abs(ticks * speed - ZoneFingerAmpPx) < 0.5

  test "the three meniscus measures DISCRIMINATE (synthetic controls)":
    ## House rule: a gate must DISCRIMINATE, not just hit. The isoline
    ## measures below are what checks #7, #8 and the straight-run check
    ## reduce to, so each one is exercised here against a synthetic
    ## polyline it MUST pass and a synthetic polyline it MUST fail —
    ## always on, no sim, no field build. Three of these four shapes are
    ## defects the paint has actually shipped at some point in this
    ## lane's history, which is the point: a green from a measure that
    ## cannot move is not evidence.
    const
      Samples = 400          ## * ZoneFieldCellPx = 1600px of edge
      FlatTolPx = 1.0        ## longestStraightRunPx's own band
      MaxAmplitudePx = 6.0 * ZoneFingerAmpPx  ## check #8's own bound
      MaxFlatRunPx = ZoneFingerOctaveCoarsePx ## straight-run's own bound
      WindowSamples = 50          ## check #8's own window
    const ControlSpanTicks = ZoneFieldCellPx - 1  ## = 3
      ## The coarsest instrument resolution the CONTROLS must still
      ## separate at. Deliberately pessimistic, and deliberately its own
      ## constant rather than ZoneArrivalSpanFloorTicks: that one is a
      ## statement about the FIELD (and, corrected 2026-08-26, is now the
      ## bracket's definitional 1), while this is a statement about how
      ## hard this synthetic test makes itself work. Wiring the control
      ## threshold to the field floor would have let a correction to the
      ## field's own theory silently widen the controls to 92.6 deg.
    let MaxTurningAngleDeg = zoneFingerAmplitudeTurnDeg() +
      zoneQuantTurnDeg(ControlSpanTicks)
      ## check #7's own bound at its LOOSEST — the amplitude term plus the
      ## quantization term at ControlSpanTicks. 39.4 deg, which is where
      ## the hand-picked 40.0 this line replaces had landed by eye; the
      ## point is that it is now DERIVED, so it moves when the tuning does.
      ## The controls must separate at check #7's weakest, not just at its
      ## typical.
    proc synth(amp, wavelenPx: float): seq[float] =
      for i in 0 ..< Samples:
        let x = float(i * ZoneFieldCellPx)
        result.add 1000.0 + amp * sin(2.0 * PI * x / wavelenPx)
    # 1. A BARE RECTANGLE EDGE — the regression the straight-run check
    #    exists to catch. Flat forever, so it never leaves the band.
    var flat: seq[float]
    for i in 0 ..< Samples: flat.add 1000.0
    let flatRun = longestFlatRunPx(flat, FlatTolPx)
    echo "  control BARE-RECT: straightRun=", flatRun, "px (bound ",
      MaxFlatRunPx, ") turning=", maxTurningAngleDeg(flat), "deg amplitude=",
      maxAmplitudeDeviationPx(flat, WindowSamples), "px"
    check flatRun > MaxFlatRunPx   ## MUST fail the straight-run bound
    # 2. A HEALTHY FINGERED FRONT — 30px amplitude on a 160px wavelength,
    #    the shape ZoneFingerAmpTicks is tuned to produce. Must pass all
    #    three.
    let good = synth(30.0, 160.0)
    let goodRun = longestFlatRunPx(good, FlatTolPx)
    let goodAngle = maxTurningAngleDeg(good)
    let goodAmp = maxAmplitudeDeviationPx(good, WindowSamples)
    echo "  control FINGERED: straightRun=", goodRun, "px turning=",
      goodAngle, "deg amplitude=", goodAmp, "px"
    check goodRun <= MaxFlatRunPx
    check goodAngle <= MaxTurningAngleDeg
    check goodAmp <= MaxAmplitudePx
    # 3. A STREAMER — Maxwell's "way too stretched out at points", the
    #    regression check #8 exists to catch: a healthy front with ONE
    #    localized tongue racing far past its own neighbourhood. (A long-
    #    wavelength sine is deliberately NOT the control here: a wave the
    #    local window can partly track is not what "stretched out" means,
    #    and measured only 235.9px at 400px amplitude — see control 5 for
    #    the drift case this check is designed to tolerate.)
    var streamer = synth(30.0, 160.0)
    for i in 0 ..< Samples:
      let d = float((i - Samples div 2) * ZoneFieldCellPx)
      streamer[i] = streamer[i] + 500.0 * exp(-(d * d) / (2.0 * 40.0 * 40.0))
    let streamerAmp = maxAmplitudeDeviationPx(streamer, WindowSamples)
    echo "  control STREAMER: amplitude=", streamerAmp, "px (bound ",
      MaxAmplitudePx, ")"
    check streamerAmp > MaxAmplitudePx   ## MUST fail the amplitude bound
    # 4. A SHARP POINT — Maxwell's "no sharp points", the regression
    #    check #7 exists to catch: one sample yanked far off an otherwise
    #    healthy front, so amplitude barely moves but curvature explodes.
    var spike = synth(30.0, 160.0)
    spike[Samples div 2] = spike[Samples div 2] + 200.0
    let spikeAngle = maxTurningAngleDeg(spike)
    echo "  control SHARP-POINT: turning=", spikeAngle, "deg (bound ",
      MaxTurningAngleDeg, ") amplitude=",
      maxAmplitudeDeviationPx(spike, WindowSamples), "px"
    check spikeAngle > MaxTurningAngleDeg   ## MUST fail the angle bound
    # 5. A GENTLE DRIFT must NOT fire. The front is not required to sit
    #    still: a slow lean across hundreds of px is legitimate, and the
    #    local-window reference exists precisely so it never reads as a
    #    stretch. This is the false-positive side of check #8's bound.
    var drift: seq[float]
    for i in 0 ..< Samples:
      drift.add 1000.0 + 600.0 * float(i) / float(Samples)
    let driftAmp = maxAmplitudeDeviationPx(drift, WindowSamples)
    echo "  control GENTLE-DRIFT: amplitude=", driftAmp, "px (bound ",
      MaxAmplitudePx, ")"
    check driftAmp <= MaxAmplitudePx
    # 6. GAPS never fabricate a vertex: a polyline that is entirely
    #    invalid measures nothing and must not read as a clean zero that
    #    a caller could mistake for a pass.
    var allGaps: seq[float]
    for i in 0 ..< Samples: allGaps.add -1.0
    check validCount(allGaps) == 0
    check longestFlatRunPx(allGaps, FlatTolPx) == 0.0
    check maxTurningAngleDeg(allGaps) == 0.0

  test "no axis-aligned straight run longer than the coarsest finger wavelength":
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    var worst = 0.0
    var samples = 0
    var edgesUsedTotal = 0
    for frac in [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85]:
      let t = BrShowmatchGearUpTicks +
        int(float(BrShowmatchTotalTicks - BrShowmatchGearUpTicks) * frac)
      let rect = sim.zoneRectAndDps(t).cur
      let prevRect = sim.zoneRectAndDps(max(0, t - 1)).cur
      let advancing = prevRect.w != rect.w or prevRect.h != rect.h
      let m = longestStraightRunPx(sim, rect, t, gw, gh)
      echo "  t=", t, " advancing=", advancing, " edgesUsed=", m.edgesUsed,
        " edgesSkipped(below regime)=", m.edgesSkipped,
        " isoRange=[", m.minRange, ",", m.maxRange, "]px samples=", m.samples,
        " longestFlatRun=", m.longestPx, "px"
      worst = max(worst, m.longestPx)
      samples += m.samples
      edgesUsedTotal += m.edgesUsed
    echo "straight-run check: edgesUsed=", edgesUsedTotal,
      " validSamples=", samples, " worst=", worst, " px"
    # THE REGIME SKIP MUST NOT BE AN ESCAPE HATCH. A paint with no
    # fingering at all puts EVERY edge below regime, which would skip the
    # whole check into a silent pass — the exact failure mode this lane
    # already found once (a check reporting worst=0 on zero samples).
    # Verified against the -d:zoneFlatPaintControl build, which drops to
    # edgesUsed=0 and fails HERE rather than passing quietly.
    check edgesUsedTotal >= 8
    check samples >= 200
    # DERIVED, not chosen (see ZoneFingerOctaveCoarsePx). The old 100px was
    # never calibrated against anything — it was set while this check was
    # reporting worst=0 on ZERO valid samples. A fingered front must break
    # out of its own +/-1px band at least once per coarsest feature;
    # staying inside it for longer than that IS a straight line. Measured
    # separation at this bound: a real front 160px, a bare rectangle 1600px
    # (BARE-RECT control), and the flat-paint build never reaches here at
    # all — it fails the in-regime floor above.
    check worst <= ZoneFingerOctaveCoarsePx

  test "check #7: the frontier never kinks — turning angle stays curvature-limited":
    ## Maxwell's ruling (2026-08-25, close-zoom screenshot review): "real
    ## physics on the frontier of the paint spill... wavey edge... no sharp
    ## points." A viscous meniscus is curvature-limited — every tongue and
    ## cove rounded, never a jagged triangular spike. Machine check #7: walk
    ## each of the rect's 4 sides the same way the straight-run check does,
    ## and bound the turning angle between consecutive polyline segments —
    ## a smooth arc turns a little every 4px step, a spike turns a lot in
    ## one.
    ##
    ## THE BOUND IS DERIVED, in TWO TERMS OF DIFFERENT KINDS (Fable's
    ## audit, 2026-08-25). The 40.0 deg this check used to carry was chosen
    ## by eye against a curvature-radius band nothing in the code actually
    ## sets, and it was 16x above what the CONFIGURED look analytically
    ## implies — a gap that size in a bound means the check is policing
    ## something other than the thing it names.
    ##   TERM A, zoneFingerAmplitudeTurnDeg (2.56 deg) — a property of the
    ##     PAINT: what 21px of meniscus across 160/260px octaves can bend
    ##     per 4px step. Every input is a tuning constant, so it is
    ##     board-independent and it moves when the tuning moves.
    ##   TERM B, zoneQuantTurnDeg (per sample) — a property of the
    ##     INSTRUMENT: the arrival field ships as uint16 WHOLE TICKS, so a
    ##     sample whose bracket spans `span` ticks can only place the
    ##     isoline to ZoneFieldCellPx/span px, and that alone fabricates
    ##     2*atan(1/span) of turning on a dead-straight front.
    ## Term B is priced PER SAMPLE, never once per edge, so one coarse
    ## sample cannot loosen the bound everywhere.
    ##
    ## THE 16x WAS A DEFECT, NOT PHYSICS, and it is fixed rather than
    ## budgeted for: the walk used to step straight through a BUILDING'S
    ## INTERIOR and report its far wall as the paint front (see
    ## frontierIsolineCoord's invalid-case list — 41.01 deg at t=2640
    ## zesBottom, entirely room 24's back wall). With interior-room cells
    ## treated as the architecture they are, the worst turning angle on
    ## this map falls to 3.37 deg, which is EXACTLY one quantum of term B
    ## at that sample's span of 17.
    ##
    ## ------------------------------------------------------------------
    ## THE THIRD CORNER-GENERATOR: A SHOCK (2026-08-26). There IS a third
    ## thing, and it is not a term — it is an EXCLUDER, because at a shock
    ## the quantity this check measures is not merely large, it is
    ## UNDEFINED. Two corner-generators were already handled this way and
    ## for exactly this reason: the rect's own 90-degree corner
    ## (EdgeCornerInsetPx) and the touchdown max(front, rectEdge)
    ## (MinMeniscusRunSamples). This is the third.
    ##
    ## WHAT A SHOCK IS HERE. computeZoneFrontierField is a minimum-time
    ## solve, so its value at a cell is a MIN over branches: the cell's own
    ## seed t0 + zoneBoundaryFingerDelayAt, and every path that flows in
    ## from elsewhere. Where two branches meet, the viscosity solution has
    ## a genuine derivative discontinuity — the isoline has a real corner,
    ## and its curvature is not bounded by anything, least of all by the
    ## fingering tuning. That is correct eikonal behaviour, and it is what
    ## real paint does when it wraps an obstacle and merges behind it.
    ##
    ## WHY MEASURING TURNING ACROSS ONE IS A CATEGORY ERROR. The check
    ## samples the isoline as a GRAPH over the rect's own edge, uniformly
    ## in s. A turning angle so measured is a curvature proxy only while
    ## the isoline stays near-perpendicular to the walk: the graph slope is
    ## |dT/ds| / |dT/dn|, and at a shock the front tilts hard (~44 deg at
    ## the sample that drove this) and the proxy diverges while the curve
    ## itself is simply creased.
    ##
    ## THE DETECTOR IS THE SOLVER'S OWN ARITHMETIC, not a threshold.
    ## zoneSeedBranchAt asks whether a cell still reads its own seed. Fast
    ## marching seeds every eligible exterior cell at exactly t0 + delay and
    ## then only ever relaxes it DOWNWARD, so a cell still at its seed was
    ## never improved by propagation and IS the boundary-plus-nudge that
    ## term A models; a cell below its seed came from another branch, about
    ## which term A — derived wholly from zoneBoundaryFingerDelayAt's two
    ## octaves — says nothing at all. A vertex is scored only if all three
    ## of its samples are seeded. The count is PRINTED as offBranch.
    ##
    ## MEASURED, and note which way the numbers fall:
    ##   small map: 977 vertices -> 310 seeded; worstExcess 68.03 -> -2.64
    ##   real map: 1579 vertices -> 1579 seeded; worstExcess -8.898,
    ##             UNCHANGED — the excluder is a NO-OP on the real map,
    ##             which is the strongest evidence it is not an escape
    ##             hatch: it removes nothing where nothing is shocked, and
    ##             the real map was already green with room to spare.
    ## The small map is the shocked one because its board is dense with
    ## architecture at the scale the rect closes through — the failing
    ## sample sat beside a 45-degree-staircased wall blob whose tip is at
    ## x~696,y~500, with the arrival field running up to 47 ticks BELOW the
    ## local seed there.
    ##
    ## REFUTED FIRST, so nobody re-chases them: quantization (span 34 is a
    ## 0.12px quantum against a 7.9px step); amplitude (survived the
    ## base-speed fix, 54.7 -> 53.2); touchdown (the worst sample's lag
    ## behind the honest boundary is 25 ticks, not 0, and no minimum-lag
    ## floor isolates it — at lag>=24, 549 of 973 vertices survive with the
    ## worst excess unchanged); and the seed nudge's own slope (board-wide
    ## max |d(delay)/ds| is 0.819 ticks/px against its own analytic ceiling
    ## of 2.13, so the octave is behaving). A fourth candidate, the loop
    ## coordinate's lost ASPECT at the terminal rect, turned out to be a
    ## real and separate defect: it is FIXED in zoneFrontLoopCoordAt, and
    ## fixing it made this number WORSE (47.3 -> 68.0), which is what
    ## restoring an under-priced instrument is supposed to do.
    ## ------------------------------------------------------------------
    var sim = zoneGame(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    let ampDeg = zoneFingerAmplitudeTurnDeg()
    let baseSpeed = zoneBaseSpeedPxPerTick(sim, zoneTestScheduleTotalTicks(sim))
    var worst = 0.0
    var worstAllow = 0.0
    var worstExcess = -Inf
    var worstExcessWhere = ""
    var minSpan = high(int)
    var maxSpan = 0
    var scored = 0
    var offRegime = 0
    var offBranch = 0
    var samples = 0
    ## `minSpan` is reported as 0, not high(int), when nothing was sampled at
    ## all — a 9223372036854775807 in a tick column reads as a real number.
    var edgesUsed = 0
    var edgesSkipped = 0
    var worstStepPx = 0.0
    var worstStepWhere = ""
    for frac in [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85]:
      let t = BrShowmatchGearUpTicks +
        int(float(BrShowmatchTotalTicks - BrShowmatchGearUpTicks) * frac)
      let rect = sim.zoneRectAndDps(t).cur
      for side in ZoneEdgeSide:
        let iso = edgeIsolineFull(sim, rect, t, gw, gh, side)
        if not inRegime(iso.pos):
          inc edgesSkipped
          continue
        inc edgesUsed
        samples += validCount(iso.pos)
        worst = max(worst, maxTurningAngleDeg(iso.pos))
        let ex = maxTurningExcessDeg(iso.pos, iso.span, iso.seeded, ampDeg)
        if ex.minSpan > 0: minSpan = min(minSpan, ex.minSpan)
        maxSpan = max(maxSpan, ex.maxSpan)
        scored += ex.scored
        offRegime += ex.offRegime
        offBranch += ex.offBranch
        if ex.idx >= 0 and ex.excessDeg > worstExcess:
          worstExcess = ex.excessDeg
          worstAllow = ex.allowDeg
          worstExcessWhere = "t=" & $t & " " & $side & " sampleIdx=" &
            $ex.idx & " turn=" & $ex.turnDeg & "deg span=" & $ex.atSpan
        let ws = worstStepOf(iso.pos)
        if ws.px > worstStepPx:
          worstStepPx = ws.px
          worstStepWhere = "t=" & $t & " " & $side & " sampleIdx=" & $ws.idx
    echo "turning-angle check (small map): edgesUsed=", edgesUsed,
      " edgesSkipped(below regime)=", edgesSkipped, " validSamples=", samples,
      " worstTurn=", worst, " deg worstStep=", worstStepPx, "px at ",
      worstStepWhere
    let reportSpan = if minSpan == high(int): 0 else: minSpan
    echo "  bound: ampTerm=", ampDeg, "deg minSpan=", reportSpan,
      " ticks -> quantTerm(minSpan)=", zoneQuantTurnDeg(reportSpan),
      "deg; maxSpan=", maxSpan, " vs perpFloor=",
      zoneSpanPerpFloorTicks(baseSpeed),
      "; scoredVertices=", scored, " offRegime(run<",
      MinMeniscusRunSamples, " samples)=", offRegime,
      " offBranch(propagated, not seeded)=", offBranch,
      "; worstExcess=", worstExcess, "deg over allow=", worstAllow,
      "deg at ", worstExcessWhere
    check edgesUsed >= 8   ## see the straight-run check: the regime skip
                           ## must never become a silent pass
    check samples >= 200
    ## ...and neither must the LOCAL regime rule: the run-length floor is
    ## reported and held to the same sample floor the edge-level one is.
    check scored >= 200
    ## The quantization term is only honest while the field's own tick
    ## resolution is: a span below the derived floor would mean term B had
    ## quietly grown into an escape hatch. Never silent.
    ## The bracket's own definition, and the PERPENDICULAR floor stated
    ## where it is true — see ZoneArrivalSpanFloorTicks for why the old
    ## every-sample floor was a theorem that is not true (an oblique
    ## crossing legitimately reads a smaller span).
    check minSpan >= ZoneArrivalSpanFloorTicks
    check float(maxSpan) >= zoneSpanPerpFloorTicks(baseSpeed)
    check worstExcess <= 0.0

  test "check #7: the frontier never kinks — ALL FOUR edges on the real map":
    ## The mandate's own specific regression target was the RIGHT edge of
    ## the real giant showmatch map — the exact edge Maxwell's rejected
    ## screenshot showed as a hard vertical line. This now sweeps all four,
    ## which is STRICTLY MORE coverage, and it had to:
    ##
    ## THE RIGHT EDGE OF THIS MAP NO LONGER ADVANCES. The zone centre is
    ## DRAWN, and on this map+seed it is drawn far to the right, so during
    ## the close the rect's right edge creeps while its left edge races.
    ## Measured between two sampled ticks: right edge 3181 -> 3163, i.e.
    ## 0.017 px/tick, against the left edge's 1312 -> 2123, i.e. 0.767
    ## px/tick — forty-five times faster. A front only lags behind an edge
    ## that MOVES, so the right edge here is flat by construction (isoRange
    ## 0.0-0.7px at every tick of the close), and the honesty gate already
    ## guarantees paint never precedes the rect. Measuring a turning angle
    ## there is measuring nothing; pinning the check to that one edge made
    ## it hostage to which way the centre happened to be drawn.
    ##
    ## Sweeping all four also closes a real gap: the other three real-map
    ## edges had NEVER been checked, and when I swept them by hand they were
    ## where the interesting defects lived (135deg before the room-interior
    ## fix, 53.9deg before the local regime rule). The regime rule picks
    ## whichever edges actually advance, and the floors below still
    ## guarantee that at least three of them did — so this cannot become a
    ## silent pass on a paint that has caught up everywhere. Same DERIVED two-term bound as the small-map
    ## check above (see its own doc for the derivation and for why the 16x
    ## excess over term A turned out to be an instrument defect rather than
    ## physics). This map is the other half of that evidence: its base speed
    ## is 2.6x the small map's, so its arrival field is 3x coarser in ticks
    ## per cell, and its residual worst turning angle is correspondingly
    ## larger — 11.31 deg, which is again EXACTLY one quantum of term B at
    ## that sample's own span. Two maps, two very different residuals, one
    ## term explaining both to five significant figures.
    var sim = zoneGameOnRealMap(BrShowmatchPhases)
    discard ensureZoneArrivalField(sim)
    let (gw, gh) = zoneArrivalFieldGridDims()
    let ampDeg = zoneFingerAmplitudeTurnDeg()
    let baseSpeed = zoneBaseSpeedPxPerTick(sim, zoneTestScheduleTotalTicks(sim))
    var worst = 0.0
    var worstAllow = 0.0
    var worstExcess = -Inf
    var worstExcessWhere = ""
    var minSpan = high(int)
    var maxSpan = 0
    var scored = 0
    var offRegime = 0
    var offBranch = 0
    var edgesSampled = 0
    var realSamples = 0
    var edgesSkipped = 0
    for frac in [0.25, 0.45, 0.65, 0.85]:
      let t = BrShowmatchGearUpTicks +
        int(float(BrShowmatchTotalTicks - BrShowmatchGearUpTicks) * frac)
      let rect = sim.zoneRectAndDps(t).cur
      for side in ZoneEdgeSide:
       let iso = edgeIsolineFull(sim, rect, t, gw, gh, side)
       block oneEdge:
        if not inRegime(iso.pos):
          inc edgesSkipped
          echo "  ", side, " t=", t, " SKIPPED: below regime (validSamples=",
            validCount(iso.pos), " isoRange=", isoRangePx(iso.pos), "px, needs >=",
            EdgeRegimeMinRangePx, "px) — the front has caught up with the rect, ",
            "so the isoline IS the rect edge and no meniscus exists to measure"
          break oneEdge
        inc edgesSampled
        realSamples += validCount(iso.pos)
        let angle = maxTurningAngleDeg(iso.pos)
        worst = max(worst, angle)
        let ex = maxTurningExcessDeg(iso.pos, iso.span, iso.seeded, ampDeg)
        if ex.minSpan > 0: minSpan = min(minSpan, ex.minSpan)
        maxSpan = max(maxSpan, ex.maxSpan)
        scored += ex.scored
        offRegime += ex.offRegime
        offBranch += ex.offBranch
        if ex.idx >= 0 and ex.excessDeg > worstExcess:
          worstExcess = ex.excessDeg
          worstAllow = ex.allowDeg
          worstExcessWhere = "t=" & $t & " " & $side & " sampleIdx=" & $ex.idx &
            " turn=" & $ex.turnDeg & "deg span=" & $ex.atSpan
        let ws = worstStepOf(iso.pos)
        echo "  ", side, " t=", t, " validSamples=", validCount(iso.pos),
          " isoRange=", isoRangePx(iso.pos), "px maxTurningAngle=", angle,
          " worstStep=", ws.px, "px minSpan=", ex.minSpan,
          " excess=", ex.excessDeg, "deg"
    echo "turning-angle check (real map, right edge): edgesSampled=",
      edgesSampled, " edgesSkipped(below regime)=", edgesSkipped,
      " validSamples=", realSamples, " worstTurn=", worst, " deg"
    let reportSpan = if minSpan == high(int): 0 else: minSpan
    echo "  bound: ampTerm=", ampDeg, "deg minSpan=", reportSpan,
      " ticks -> quantTerm(minSpan)=", zoneQuantTurnDeg(reportSpan),
      "deg; maxSpan=", maxSpan, " vs perpFloor=",
      zoneSpanPerpFloorTicks(baseSpeed),
      "; scoredVertices=", scored, " offRegime(run<",
      MinMeniscusRunSamples, " samples)=", offRegime,
      " offBranch(propagated, not seeded)=", offBranch,
      "; worstExcess=", worstExcess, "deg over allow=", worstAllow,
      "deg at ", worstExcessWhere
    check edgesSampled >= 3   ## regime skip must not absolve a flat paint
    check realSamples >= 100
    check scored >= 100
    ## The bracket's own definition, and the PERPENDICULAR floor stated
    ## where it is true — see ZoneArrivalSpanFloorTicks for why the old
    ## every-sample floor was a theorem that is not true (an oblique
    ## crossing legitimately reads a smaller span).
    check minSpan >= ZoneArrivalSpanFloorTicks
    check float(maxSpan) >= zoneSpanPerpFloorTicks(baseSpeed)
    check worstExcess <= 0.0

  test "check #8: the meniscus amplitude stays bounded — no streamers":
    ## Maxwell's ruling (2026-08-25, close-zoom review of the fresh
    ## recording): "it gets way too stretched out at points, there should
    ## be a limit to the amplitude at the meniscus" — open-field tongues
    ## were stretching into long pointed streamers because the seed-nudge
    ## amplitude (zoneBoundaryFingerDelayAt) was riding the SAME large
    ## budget raised for legitimately deep room/aperture lag. Split into
    ## ZoneFingerAmpTicks (small, open-field only) vs ZoneFlowDelayCapTicks
    ## (room/aperture lag, untouched) — this check is the machine-checkable
    ## version of "bounded," using the SAME tip-walker as checks #7: each
    ## sample's deviation from its own local-window mean must stay inside
    ## a generous multiple of what ZoneFingerAmpTicks can move the front by
    ## at the schedule's own base speed, with real slack for legitimate
    ## corner/aperture variation this bound is not meant to police (checks
    ## #7 and the room-lag/door-first suite already own those).
    const
      WindowSamples = 50  ## +/- 50 * ZoneFieldCellPx(4) = +/- 200px, per
                          ## the coordinator's own window size.
      MaxAmplitudePx = 6.0 * ZoneFingerAmpPx  ## 126px — SIX TIMES the
                          ## meniscus's own approved amplitude, now that
                          ## the amplitude is denominated in px and is the
                          ## same on every map (ZoneFingerAmpPx). Derived
                          ## rather than hard-coded, so retuning the look
                          ## retunes the bound with it. Verified to still
                          ## DISCRIMINATE at this tighter value: the
                          ## synthetic streamer control measures 377.5px
                          ## against it, a healthy front 30.0px and a
                          ## legitimate gentle drift 37.5px.
    var worstSmall = 0.0
    var smallSamples = 0
    var smallUsed = 0
    var smallSkipped = 0
    block smallMap:
      var sim = zoneGame(BrShowmatchPhases)
      discard ensureZoneArrivalField(sim)
      let (gw, gh) = zoneArrivalFieldGridDims()
      for frac in [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85]:
        let t = BrShowmatchGearUpTicks +
        int(float(BrShowmatchTotalTicks - BrShowmatchGearUpTicks) * frac)
        let rect = sim.zoneRectAndDps(t).cur
        for side in ZoneEdgeSide:
          let iso = edgeIsoline(sim, rect, t, gw, gh, side)
          if not inRegime(iso):
            inc smallSkipped
            continue
          inc smallUsed
          smallSamples += validCount(iso)
          worstSmall = max(worstSmall,
            maxAmplitudeDeviationPx(iso, WindowSamples))
    echo "amplitude check (small map): edgesUsed=", smallUsed,
      " edgesSkipped(below regime)=", smallSkipped, " validSamples=",
      smallSamples, " worst=", worstSmall, " px"
    var worstReal = 0.0
    var realEdgesSampled = 0
    var realSamples = 0
    var realSkipped = 0
    ## ALL FOUR EDGES, for the reason check #7 above already had to sweep
    ## all four (2026-08-26). This block used to sample zesRight ALONE, and
    ## on this map+seed that is the one edge which no longer advances: the
    ## zone centre is DRAWN far to the right, so during the close the right
    ## edge creeps at 0.017 px/tick against the left edge's 0.767. A front
    ## only lags an edge that MOVES, so zesRight is flat by construction
    ## (isoRange 0.0-0.7px at every sampled tick) and the regime gate
    ## correctly skipped it — all seven times, leaving realEdgesSampled at
    ## ZERO and this check asserting >= 3 against an edge that cannot ever
    ## supply one. That is a stale instrument, not a paint regression:
    ## check #7 was swept to all four edges when the drawn centre was
    ## diagnosed, and this one was left pinned to the same dead edge.
    block realMapAllEdges:
      var sim = zoneGameOnRealMap(BrShowmatchPhases)
      discard ensureZoneArrivalField(sim)
      let (gw, gh) = zoneArrivalFieldGridDims()
      for frac in [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85]:
        let t = BrShowmatchGearUpTicks +
        int(float(BrShowmatchTotalTicks - BrShowmatchGearUpTicks) * frac)
        let rect = sim.zoneRectAndDps(t).cur
        for side in ZoneEdgeSide:
          let iso = edgeIsoline(sim, rect, t, gw, gh, side)
          if not inRegime(iso):
            inc realSkipped
            continue
          inc realEdgesSampled
          realSamples += validCount(iso)
          worstReal = max(worstReal,
            maxAmplitudeDeviationPx(iso, WindowSamples))
    echo "amplitude check (real map, all four edges): edgesSampled=",
      realEdgesSampled, " edgesSkipped(below regime)=", realSkipped,
      " validSamples=", realSamples, " worst=", worstReal, " px"
    check smallUsed >= 8       ## regime skip must not absolve a flat paint
    check realEdgesSampled >= 3
    check worstSmall <= MaxAmplitudePx
    check worstReal <= MaxAmplitudePx

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
      when defined(zoneRoomClassifyDebug):
        if roomMin < doorMin:
          for idx in cells:
            let
              gx = idx mod gw
              gy = idx div gw
              a = arrivalOf(idx)
            stderr.writeLine("    ROOM cell gx=" & $gx & " gy=" & $gy &
              " arrival=" & $(if a.has: $a.v else: "none"))
          for idx in doorSet:
            let
              gx = idx mod gw
              gy = idx div gw
              a = arrivalOf(idx)
            stderr.writeLine("    DOOR cell gx=" & $gx & " gy=" & $gy &
              " arrival=" & $(if a.has: $a.v else: "none"))
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
    # Same baseSpeed formula the solver's own solve uses
    # (zoneBaseSpeedPxPerTick, global.nim — not exported, mirrored here):
    # needed below to seed each door cell at its OWN real arrival tick
    # rather than a flat 0, so a room with several separately-timed door
    # clusters (a large room can open onto the exterior in more than one
    # place, each crossing the shrinking rect boundary at a different
    # tick) gets a fair "predicted arrival" proxy instead of one blind to
    # WHICH door is actually earliest.
    let baseSpeed = block:
      let
        fullW = sim.gameMap.width
        fullH = sim.gameMap.height
        final = sim.zoneRectAndDps(BrShowmatchTotalTicks).cur
        closeX = float(max(0, fullW - final.w)) * 0.5
        closeY = float(max(0, fullH - final.h)) * 0.5
      max(0.05, (closeX + closeY) / 2.0 / float(BrShowmatchTotalTicks))
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
      # a cruder proxy. `hopDist` (0-seeded, unitless — depth bookkeeping
      # only) and `predArrival` (seeded at each door's own real arrival
      # tick, in the SAME tick units the solver's slowness=h/(baseSpeed*F)
      # update rule produces — see baseSpeed above) are relaxed together;
      # only `predArrival` feeds the correlation. Simple bounded relaxation
      # (no heap needed — a room's own cell count is small): repeat until
      # stable.
      var hopDist = newSeq[float](gw * gh)
      var predArrival = newSeq[float](gw * gh)
      for i in 0 ..< hopDist.len:
        hopDist[i] = Inf
        predArrival[i] = Inf
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
          let a = arrivalOf(idx)
          if a.has:
            hopDist[idx] = 0.0
            predArrival[idx] = a.v.float
            inc doorSeedCount
      proc edgeCostUnitless(nidx: int): float =
        let clearance = wallDist[nidx].float * 2.0
        let aperture = clamp(clearance / 26.0, 0.15, 1.0)
        let wallDrag = clamp(wallDist[nidx].float / 10.0, 0.0, 1.0)
        let wallMult = 0.5 + wallDrag * 0.5
        1.0 / max(0.05, aperture * wallMult)
      proc edgeCostTicks(nidx: int): float =
        # Same slowness=h/(baseSpeed*F) form the solver's own update rule
        # uses (computeZoneFrontierField) — predArrival is seeded in real
        # ticks, so each step must add a real tick cost too, not an
        # abstract unit, or the two would no longer share a scale.
        let clearance = wallDist[nidx].float * 2.0
        let aperture = clamp(clearance / 26.0, 0.15, 1.0)
        let wallDrag = clamp(wallDist[nidx].float / 10.0, 0.0, 1.0)
        let wallMult = 0.5 + wallDrag * 0.5
        float(ZoneFieldCellPx) / (baseSpeed * max(0.05, aperture * wallMult))
      var changed = true
      var iterGuard = 0
      while changed and iterGuard < cells.len + 5:
        changed = false
        inc iterGuard
        for idx in cells:
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
            if hopDist[idx] < Inf:
              let cand = hopDist[idx] + step * edgeCostUnitless(nidx)
              if cand < hopDist[nidx]:
                hopDist[nidx] = cand
                changed = true
            if predArrival[idx] < Inf:
              let cand = predArrival[idx] + step * edgeCostTicks(nidx)
              if cand < predArrival[nidx]:
                predArrival[nidx] = cand
                changed = true
      if doorSeedCount == 0:
        continue  # no doorway reached this room — skip (not a
                  # front-propagation failure, a classifier edge case).
      # SPEARMAN rank correlation between actual arrival and the weighted,
      # real-tick-seeded predicted arrival over the room's own cells.
      var xs, ys: seq[float]
      var maxHopSeen = 0
      for idx in cells:
        if hopDist[idx] >= Inf or predArrival[idx] >= Inf: continue
        maxHopSeen = max(maxHopSeen, (hopDist[idx] / 4.0).int)
        let a = arrivalOf(idx)
        if not a.has: continue
        xs.add(predArrival[idx])
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
      when defined(zoneRoomClassifyDebug):
        if corr <= 0.8:
          for idx in cells:
            let
              gx = idx mod gw
              gy = idx div gw
              a = arrivalOf(idx)
            var neighborRooms: seq[int]
            for off in ZoneFrontierOffsets:
              let
                nx = gx + off.dx
                ny = gy + off.dy
              if nx < 0 or ny < 0 or nx >= gw or ny >= gh: continue
              neighborRooms.add(roomId[ny * gw + nx])
            stderr.writeLine("    cell gx=" & $gx & " gy=" & $gy &
              " predArrival=" & $predArrival[idx] &
              " arrival=" & $(if a.has: $a.v else: "none") &
              " neighborRooms=" & $neighborRooms)
      if corr <= 0.8:
        inc corrViolations
    echo "door-first check: roomsChecked=", roomsChecked,
      " corrViolations=", corrViolations
    check roomsChecked > 0
    check corrViolations == 0
