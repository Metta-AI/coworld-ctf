import
  helpers,
  std/[json, sets, unittest],
  ctf/[broadcast, global, sim]

# OPTICS(s2): the sight/scope item family. Two pickup-granted perks:
#   * PerkSight  ("scope")  — +sight DISTANCE (perkMods.sightVision) and +cone
#                             HALF-ANGLE (perkMods.sightConeDeg). Pure fog widen.
#   * PerkBarrel ("barrel") — +gun RANGE (perkMods.barrelRange). Drives target
#                             selection, tracer, and (Mode A only) the jitter
#                             calibration.
# Plant-to-aim (config.plantAimSigmaPermille) narrows the cone of a shooter that
# has held still for plantSettleTicks. Every axis defaults dark: a perk-free,
# plant-off game re-simulates byte-for-byte (guarded below + by test_replay).

suite "optics accessors (pure math)":
  let cfg = defaultGameConfig()   # stock gunRange 1050, cone 60, defaults.

  test "no perk returns today's global values byte-for-byte":
    check gunRangeFor(cfg, {}) == cfg.gunRange
    check visionRangeFor(cfg, {}) == cfg.gunRange * 3 div 2
    check visionConeDegFor(cfg, {}) == cfg.visionConeDeg

  test "barrel extends gun range and (via the range coupling) sight":
    check gunRangeFor(cfg, {PerkBarrel}) == 1365        # 1050 x1.30
    check visionRangeFor(cfg, {PerkBarrel}) == 2047     # 1365 * 3 div 2
    check visionConeDegFor(cfg, {PerkBarrel}) == 60     # barrel never touches cone

  test "scope extends sight distance and widens the cone":
    check visionRangeFor(cfg, {PerkSight}) == 2362      # 1575 x1.50
    check visionConeDegFor(cfg, {PerkSight}) == 80      # 60 + 20
    check gunRangeFor(cfg, {PerkSight}) == cfg.gunRange # scope never touches range

  test "scope and barrel compose":
    check visionRangeFor(cfg, {PerkSight, PerkBarrel}) == 3070  # 2047 x1.50
    check visionConeDegFor(cfg, {PerkSight, PerkBarrel}) == 80

  test "magnitudes are the tunable perkMods":
    var tuned = defaultGameConfig()
    tuned.update("""{"perkMods": {"barrelRange": 0.5, "sightVision": 1.0,
      "sightConeDeg": 40}}""")
    check gunRangeFor(tuned, {PerkBarrel}) == 1575       # 1050 x1.50
    check visionConeDegFor(tuned, {PerkSight}) == 100    # 60 + 40
    check visionRangeFor(tuned, {PerkSight}) == (1050 * 3 div 2) * 2  # x2.0

suite "optics dark-inertness (game hash)":
  # Same contract the perks already keep: an unequipped, plant-off game must
  # re-simulate byte-for-byte. Fires 50 shots without moving, then hashes.
  proc battle(configJsonText: string): uint64 =
    var config = defaultGameConfig()
    config.update(configJsonText)
    var sim = initCtfForTest(config)
    let shooter = sim.addPlayer("red0")
    let target = sim.addPlayer("blue0")
    sim.startGame()
    sim.players[shooter].x = sim.gameMap.center.x
    sim.players[shooter].y = sim.gameMap.center.y
    sim.players[shooter].aimBrads = 0
    sim.players[target].x = sim.gameMap.center.x + 40
    sim.players[target].y = sim.gameMap.center.y
    sim.players[target].hp = 100
    for _ in 0 ..< 50:
      sim.armToFire(shooter)
      sim.tryFire(shooter)
    sim.gameHash()

  test "optics perkMods alone (no perk assigned) leave the hash unchanged":
    check battle("{}") == battle("""{"perkMods": {"sightVision": 0.9,
      "barrelRange": 0.9, "sightConeDeg": 40}}""")

  test "the barrel calibration knob is dark without PerkBarrel":
    check battle("{}") == battle("""{"barrelRederiveJitter": true}""")

  test "the plant-scope knob is dark while plant is off":
    check battle("{}") == battle("""{"plantAimBarrelOnly": true}""")

  test "arming plant-to-aim changes the hash schema (stillTicks enters it)":
    # Off (1000) mixes nothing new; armed (<1000) mixes stillTicks per player,
    # so the same shots hash differently — proof the conditional mix is wired.
    check battle("{}") != battle("""{"plantAimSigmaPermille": 700}""")

suite "barrel extender: shot reach and calibration":
  # The gun_jitter lane: the widest fully clear corridor is ~313px from x=24,
  # so live fire runs with a short gunRange override inside it.
  const
    BaseRange = 200
    ExtRange = 260          # 200 x1.30 (default barrelRange)
    ShooterX = 24
    ShooterY = 80

  proc laneSim(seed: int, extraJson = ""): SimServer =
    var config = defaultGameConfig()
    config.update("""{"gunRange": """ & $BaseRange &
      """, "seed": """ & $seed & extraJson & "}")
    result = initCtfForTest(config)
    result.gameEventLoggingEnabled = false
    discard result.addPlayer("red0")
    discard result.addPlayer("blue0")
    result.startGame()
    result.players[0].x = ShooterX
    result.players[0].y = ShooterY
    result.players[0].aimBrads = 0
    result.players[1].y = ShooterY

  proc hits(game: var SimServer, targetDist, shots: int): int =
    for _ in 0 ..< shots:
      game.players[1].x = ShooterX + targetDist
      game.players[0].windupBrads = -1
      game.players[0].fireCooldown = 0
      game.players[1].hp = 3
      game.tryFire(0)
      if game.players[1].hp < 3:
        inc result

  test "a barrel shooter reaches a target a base shooter cannot":
    # 230px is past the base 200px reach but inside the barrel's 260px.
    var base = laneSim(7)
    var barrel = laneSim(7)
    barrel.players[0].perks = {PerkBarrel}
    check base.hits(230, 120) == 0            # out of range: never crossed
    check barrel.hits(230, 120) > 0           # in range now

  test "Mode B (default) holds sigma: the extended shot is a falling gamble":
    # Fresh same-seed sims per distance so the RNG stream is identical and the
    # ONLY variable is target distance (else two windows of one stream differ).
    var atBaseSim = laneSim(3)
    atBaseSim.players[0].perks = {PerkBarrel}
    var atExtSim = laneSim(3)
    atExtSim.players[0].perks = {PerkBarrel}
    let atBase = atBaseSim.hits(BaseRange, 200)  # ~80%, calibrated at base range
    let atExt = atExtSim.hits(250, 200)          # past base range, same sigma
    check atBase in 130 .. 190
    check atExt < atBase                          # hit-rate falls with distance

  test "Mode A re-derives sigma: tighter at the extended distance than Mode B":
    var modeB = laneSim(3)
    modeB.players[0].perks = {PerkBarrel}
    var modeA = laneSim(3, """, "barrelRederiveJitter": true""")
    modeA.players[0].perks = {PerkBarrel}
    let bExt = modeB.hits(250, 200)
    let aExt = modeA.hits(250, 200)
    check aExt > bExt                         # re-derived cone is tighter at range

suite "plant-to-aim: standing still narrows the cone":
  const
    BaseRange = 200
    ShooterX = 24
    ShooterY = 80

  proc laneSim(seed: int, extraJson = ""): SimServer =
    var config = defaultGameConfig()
    config.update("""{"gunRange": """ & $BaseRange &
      """, "seed": """ & $seed & extraJson & "}")
    result = initCtfForTest(config)
    result.gameEventLoggingEnabled = false
    discard result.addPlayer("red0")
    discard result.addPlayer("blue0")
    result.startGame()
    result.players[0].x = ShooterX
    result.players[0].y = ShooterY
    result.players[0].aimBrads = 0
    result.players[1].y = ShooterY

  proc hits(game: var SimServer, targetDist, shots, stillTicks: int): int =
    for _ in 0 ..< shots:
      game.players[1].x = ShooterX + targetDist
      game.players[0].windupBrads = -1
      game.players[0].fireCooldown = 0
      game.players[0].stillTicks = stillTicks
      game.players[1].hp = 3
      game.tryFire(0)
      if game.players[1].hp < 3:
        inc result

  # Each comparison uses two fresh same-seed sims (identical RNG stream), one
  # fired moving, one planted — so the ONLY variable is the plant state.
  const Armed = """, "plantAimSigmaPermille": 700, "plantSettleTicks": 1"""

  test "armed: a planted shooter out-hits a moving one at max range":
    var movingSim = laneSim(5, Armed)
    var plantedSim = laneSim(5, Armed)
    let moving = movingSim.hits(BaseRange, 200, stillTicks = 0)
    let planted = plantedSim.hits(BaseRange, 200, stillTicks = 5)
    check planted > moving          # planted sigma x0.70 => strictly more hits

  test "off (permille 1000): plant state makes no difference":
    var movingSim = laneSim(5)      # default: plantAimSigmaPermille 1000 = off
    var plantedSim = laneSim(5)
    let moving = movingSim.hits(BaseRange, 200, stillTicks = 0)
    let planted = plantedSim.hits(BaseRange, 200, stillTicks = 50)
    check planted == moving         # sigma untouched => identical shot stream

  test "barrel-only scope: a plain shooter gets no plant bonus":
    var movingSim = laneSim(5, Armed & """, "plantAimBarrelOnly": true""")
    var plantedSim = laneSim(5, Armed & """, "plantAimBarrelOnly": true""")
    # No PerkBarrel -> planted is never true -> identical to moving.
    let moving = movingSim.hits(BaseRange, 200, stillTicks = 0)
    let planted = plantedSim.hits(BaseRange, 200, stillTicks = 5)
    check planted == moving

suite "scope: wider and longer vision cone (fog-of-war)":
  # Wall-free field so the cone/range filter is the only gate. Short gunRange
  # so the base sight (300px) fits inside the 1235x659 map with room to extend.
  proc fovSim(): SimServer =
    var config = defaultGameConfig()
    config.update("""{"gunRange": 200}""")   # visionRange 300, scope 450
    result = initCtfForTest(config)
    result.fovBlocked = newSeq[bool](FovCellCount)   # no walls: reveal all
    discard result.addPlayer("red0")
    result.startGame()

  const
    OriginX = 600
    OriginY = 330

  test "scope extends sight DISTANCE (on-axis cell past base range)":
    var sim = fovSim()
    let (ocx, ocy) = fovCellAt(OriginX, OriginY)
    var base, scoped: seq[bool]
    # aim east (0 brads); a cell 370px east: past base 300, inside scope 450.
    sim.computeFovVisible(ocx, ocy, 0, base, {})
    sim.computeFovVisible(ocx, ocy, 0, scoped, {PerkSight})
    check not sim.fovAt(base, OriginX + 370, OriginY)
    check sim.fovAt(scoped, OriginX + 370, OriginY)

  test "scope WIDENS the cone (cell outside 60deg, inside 80deg)":
    var sim = fovSim()
    let (ocx, ocy) = fovCellAt(OriginX, OriginY)
    var base, scoped: seq[bool]
    sim.computeFovVisible(ocx, ocy, 0, base, {})
    sim.computeFovVisible(ocx, ocy, 0, scoped, {PerkSight})
    # 250px at ~70deg CCW from east (screen y up): dx=+85, dy=-235.
    check not sim.fovAt(base, OriginX + 85, OriginY - 235)
    check sim.fovAt(scoped, OriginX + 85, OriginY - 235)
