## Direct spec-key ingest tests for the four neutral item pools: a map that
## authors its own `shieldSpawns`/`spraySpawns`/`grenadeSpawns` (BR's neutral
## pools, brmapkit round 13) or `medKitSpawns` (pre-BR, the classic active
## pair) wins over resetShields/resetSprayPaints/resetGrenades/resetMedKits'
## own per-team or fixed-formula placement — see sim.nim's own comments on
## each proc ("the map's own list first, formula fallback"). These are the
## POSITIVE-path complements to the validateMap REJECTION tests
## (test_br_team_bridge.nim's "BR item-pool defense", 73f5971): this suite
## proves the winning branch actually places the AUTHORED points (nudged to
## the nearest walkable floor via placeWalkablePickups), not merely that a
## malformed spec is refused.
##
## JSON spec in, sim state out: every test here builds a `mapSpec`, boots a
## bare SimServer (`initSimServer` alone already runs every reset* proc — no
## players or `startGame` needed, see sim.nim's construction tail), and reads
## the populated `sim.<family>Spawns` back.

import
  helpers,
  std/[json, unittest],
  ctf/[arena, sim, sim_config, sim_types]

proc baseArenaSpec(): JsonNode =
  ## The hand-authored default arena's own spec, round-tripped through
  ## mapSpecJson — a real, always-valid classic 2-team map, so every test
  ## below only has to override the one pool field it is testing.
  parseJson(mapSpecJson(loadCtfMapMetadata("arena")))

proc configWithPool(key: string, points: seq[array[2, int]]): GameConfig =
  var node = baseArenaSpec()
  node[key] = %points
  result = defaultGameConfig()
  result.mapSpec = $node

proc configWithoutPool(key: string): GameConfig =
  ## "Not authored": the three BR neutral pools (shieldSpawns/spraySpawns/
  ## grenadeSpawns) are optional spec keys, simply absent from the default
  ## arena's own echoed spec (mapSpecJson omits an empty seq, the same
  ## "pin only when non-default" convention `flagless` uses) — deleting
  ## one that was never there is a no-op either way. medKitSpawns is
  ## DIFFERENT: a REQUIRED spec key (mapFromSpecJson raises a KeyError if
  ## it is missing outright), so "not authored" there means present but
  ## EMPTY, not absent.
  var node = baseArenaSpec()
  if key == "medKitSpawns":
    node[key] = %(newSeq[array[2, int]]())
  elif node.hasKey(key):
    node.delete(key)
  result = defaultGameConfig()
  result.mapSpec = $node

const
  ## Deliberately inside the perimeter wall (ArenaBorder = 10px): any
  ## authored point here MUST move for the nudge to be real, not a
  ## coincidental no-op equality.
  OffWallPoint = [2, 2]

suite "item pool ingest: authored spec pool wins over the classic formula":
  test "shieldSpawns: an authored pool is placed at nearestWalkable(authored), not the per-team formula":
    let authored = @[OffWallPoint, [400, 300]]
    let sim = initCtfForTest(configWithPool("shieldSpawns", authored))
    check sim.shieldSpawns.len == authored.len
    for i, p in authored:
      let want = sim.nearestWalkable(p[0], p[1])
      check sim.shieldSpawns[i].x == want.x
      check sim.shieldSpawns[i].y == want.y
      check sim.shieldSpawns[i].present
    ## The nudge actually moved the off-wall point (proves this is a real
    ## nudge, not a vacuous no-op equality check).
    check (sim.shieldSpawns[0].x, sim.shieldSpawns[0].y) != (OffWallPoint[0], OffWallPoint[1])
    ## And it genuinely displaced the classic per-team formula: the two
    ## point sets disagree, so the authored branch — not the fallback — is
    ## what ran.
    let formulaSim = initCtfForTest(configWithoutPool("shieldSpawns"))
    check formulaSim.shieldSpawns.len > 0
    check (formulaSim.shieldSpawns[0].x, formulaSim.shieldSpawns[0].y) !=
      (sim.shieldSpawns[0].x, sim.shieldSpawns[0].y)

  test "spraySpawns: an authored pool is placed at nearestWalkable(authored), not the per-team formula":
    let authored = @[OffWallPoint, [800, 500]]
    let sim = initCtfForTest(configWithPool("spraySpawns", authored))
    check sim.sprayPaintSpawns.len == authored.len
    for i, p in authored:
      let want = sim.nearestWalkable(p[0], p[1])
      check sim.sprayPaintSpawns[i].x == want.x
      check sim.sprayPaintSpawns[i].y == want.y
      check sim.sprayPaintSpawns[i].present
    check (sim.sprayPaintSpawns[0].x, sim.sprayPaintSpawns[0].y) !=
      (OffWallPoint[0], OffWallPoint[1])
    let formulaSim = initCtfForTest(configWithoutPool("spraySpawns"))
    check formulaSim.sprayPaintSpawns.len > 0
    check (formulaSim.sprayPaintSpawns[0].x, formulaSim.sprayPaintSpawns[0].y) !=
      (sim.sprayPaintSpawns[0].x, sim.sprayPaintSpawns[0].y)

  test "grenadeSpawns: an authored pool is placed at nearestWalkable(authored), not the corner formula":
    let authored = @[OffWallPoint, [300, 300], [700, 400]]
    let sim = initCtfForTest(configWithPool("grenadeSpawns", authored))
    check sim.grenadeSpawns.len == authored.len
    for i, p in authored:
      let want = sim.nearestWalkable(p[0], p[1])
      check sim.grenadeSpawns[i].x == want.x
      check sim.grenadeSpawns[i].y == want.y
      check sim.grenadeSpawns[i].present
    check (sim.grenadeSpawns[0].x, sim.grenadeSpawns[0].y) !=
      (OffWallPoint[0], OffWallPoint[1])
    ## grenadeSpawnPoints' classic formula is a FIXED array[4] regardless of
    ## how many points the authored pool carries — a 3-point authored pool
    ## (unlike the formula's always-4) is itself proof the authored branch
    ## ran, before even comparing coordinates.
    let formulaSim = initCtfForTest(configWithoutPool("grenadeSpawns"))
    check formulaSim.grenadeSpawns.len == 4
    check sim.grenadeSpawns.len != formulaSim.grenadeSpawns.len

  test "medKitSpawns: an authored pool is placed at nearestWalkable(authored), not the classic center-thirds pair":
    ## resetMedKits gates on `> 0`, not `>= 2` (its own recent fix) — a
    ## single authored point must win too, not just a pair.
    let authored = @[OffWallPoint]
    let sim = initCtfForTest(configWithPool("medKitSpawns", authored))
    check sim.medKitSpawns.len == 1
    let want = sim.nearestWalkable(OffWallPoint[0], OffWallPoint[1])
    check sim.medKitSpawns[0].x == want.x
    check sim.medKitSpawns[0].y == want.y
    check sim.medKitSpawns[0].present
    check (sim.medKitSpawns[0].x, sim.medKitSpawns[0].y) !=
      (OffWallPoint[0], OffWallPoint[1])
    let formulaSim = initCtfForTest(configWithoutPool("medKitSpawns"))
    check formulaSim.medKitSpawns.len == 2   ## the classic center-thirds pair.
    check (formulaSim.medKitSpawns[0].x, formulaSim.medKitSpawns[0].y) !=
      (sim.medKitSpawns[0].x, sim.medKitSpawns[0].y)

  test "all four pools authored together on one map: every family wins independently":
    ## The four gates are independent `len > 0` checks on four different
    ## map fields — proving them together (not just pairwise) is what rules
    ## out one family's branch accidentally reading another's field.
    var node = baseArenaSpec()
    node["medKitSpawns"] = %[[100, 100]]
    node["shieldSpawns"] = %[[150, 150]]
    node["spraySpawns"] = %[[200, 200]]
    node["grenadeSpawns"] = %[[250, 250], [260, 260]]
    var config = defaultGameConfig()
    config.mapSpec = $node
    let sim = initCtfForTest(config)
    check sim.medKitSpawns.len == 1
    check sim.shieldSpawns.len == 1
    check sim.sprayPaintSpawns.len == 1
    check sim.grenadeSpawns.len == 2
    check sim.medKitSpawns[0].x == sim.nearestWalkable(100, 100).x
    check sim.shieldSpawns[0].x == sim.nearestWalkable(150, 150).x
    check sim.sprayPaintSpawns[0].x == sim.nearestWalkable(200, 200).x
    check sim.grenadeSpawns[0].x == sim.nearestWalkable(250, 250).x
    check sim.grenadeSpawns[1].x == sim.nearestWalkable(260, 260).x
