## Map SELECTION: the per-scene RNG sub-streams (`src/ctf/map_seed.nim`) and
## the generator-agnostic best-of-K ranker (`arena.selectBestMap`).
##
## Three properties are load-bearing, none of them visible from a rendered map,
## which is why they are pinned here:
##
## 1. **Scene independence.** Every scene draws from its own name-derived
##    stream, so a scene can gain, lose or reorder draws — or simply not exist
##    yet — without disturbing any other scene. That is what lets a new
##    generator replace one scene wholesale and leave the med kits where they
##    were.
## 2. **The shell belongs to the SEED, not the attempt.** The old re-roll was
##    `seed + attempt` on one flat stream whose first draw was the size class,
##    so a rejected seed came back as a differently-SIZED map. Selection is
##    only meaningful if the K candidates are K tries at the same board.
## 3. **The ranker does not know its generator.** `selectBestMap` takes a
##    candidate-producing callback, so a replacement generator drives the same
##    selection with no rewrite. It is exercised here against a fake generator
##    that has nothing to do with the column lattice, which is the only way to
##    prove the seam is real.
##
## Runtime discipline: a full `generateCtfMap` costs ~1s (K candidates x
## generate + validate + score), so every call here passes a small explicit `k`
## or sticks to one seed.

import
  std/[sets, unittest],
  ctf/sim   # re-exports map_seed (via arena) and map_metrics

const Unlocked = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)

proc draws(rng: var MapRng, n = 8): seq[int] =
  for _ in 0 ..< n: result.add rng.pick(1_000_000)

suite "map_seed sub-streams":
  test "each scene name gets its own stream from the same seed":
    let s = mapSeed(1234)
    var seen = initHashSet[seq[int]]()
    for scene in KnownScenes:
      var rng = s.stream(scene)
      seen.incl rng.draws()
    check seen.len == KnownScenes.len
    # A scene nobody has written yet must already have a stream that collides
    # with nothing — that is the whole open-set claim.
    var novel = s.stream("structure/lanes")
    check novel.draws() notin seen

  test "a stream is a pure function of (seed, scene, attempt)":
    for attempt in 0 .. 3:
      var a = mapSeed(99, attempt).stream(SceneTerrain)
      var b = mapSeed(99, attempt).stream(SceneTerrain)
      check a.draws() == b.draws()
    var here = mapSeed(99).stream(SceneCover)
    var there = mapSeed(100).stream(SceneCover)
    check here.draws() != there.draws()

  test "the attempt index reaches stream but never seedStream":
    for scene in KnownScenes:
      var perAttempt0 = mapSeed(7, 0).stream(scene)
      var perAttempt5 = mapSeed(7, 5).stream(scene)
      check perAttempt0.draws() != perAttempt5.draws()
      var shell0 = mapSeed(7, 0).seedStream(scene)
      var shell5 = mapSeed(7, 5).seedStream(scene)
      check shell0.draws() == shell5.draws()

  test "withAttempt is the same root at another candidate index":
    let s = mapSeed(41)
    var a = s.withAttempt(3).stream(SceneTerrain)
    var b = mapSeed(41, 3).stream(SceneTerrain)
    check a.draws() == b.draws()

  test "a pinned scene overrides its derivation and leaves the rest alone":
    let
      base = mapSeed(2024, 1)
      pinned = base.pinScene(SceneTerrain, 0xABCDEF'u64)
    var
      pinnedTerrain = pinned.stream(SceneTerrain)
      expected = MapRng(state: 0xABCDEF'u64)
      baseTerrain = base.stream(SceneTerrain)
    let
      pinnedDraws = pinnedTerrain.draws()
      expectedDraws = expected.draws()
      baseDraws = baseTerrain.draws()
    check pinnedDraws == expectedDraws
    check pinnedDraws != baseDraws
    for scene in KnownScenes:
      if scene == SceneTerrain: continue
      var a = base.stream(scene)
      var b = pinned.stream(scene)
      check a.draws() == b.draws()
    # A pin survives re-pinning the same name rather than stacking entries.
    let twice = pinned.pinScene(SceneTerrain, 0x1234'u64)
    check twice.pins.len == 1
    # 0 means "not pinned" in the storage, so it must not read as unpinned.
    var zeroPin = base.pinScene(SceneCover, 0).stream(SceneCover)
    var unpinned = base.stream(SceneCover)
    check zeroPin.draws() != unpinned.draws()

  test "spawn makes independent children and costs the parent one draw":
    var parent = mapSeed(5, 0).stream(SceneTerrain)
    var probe = mapSeed(5, 0).stream(SceneTerrain)
    var roomA = parent.spawn("room:0")
    var roomB = parent.spawn("room:1")
    let roomADraws = roomA.draws(16)
    check roomADraws != roomB.draws(16)
    # Two spawns advanced the parent by exactly two draws — so a child that
    # draws a thousand times still cannot shift its siblings.
    discard probe.pick(1_000_000)
    discard probe.pick(1_000_000)
    check parent.draws() == probe.draws()
    # Re-spawning the same name from the same parent state reproduces it.
    var again = mapSeed(5, 0).stream(SceneTerrain)
    var roomAAgain = again.spawn("room:0")
    check roomAAgain.draws(16) == roomADraws

  test "children nest to arbitrary depth without colliding":
    var scene = mapSeed(11).stream("structure")
    var room = scene.spawn("room:3")
    var door = room.spawn("door:north")
    var window = room.spawn("window:east")
    let doorDraws = door.draws()
    check doorDraws != window.draws()
    var elsewhere = mapSeed(11).stream("structure")
    var sameRoom = elsewhere.spawn("room:3")
    var sameDoor = sameRoom.spawn("door:north")
    check sameDoor.draws() == doorDraws

suite "the board shell belongs to the seed":
  test "every best-of-K candidate for a seed is the same board":
    for seed in [1001, 1004, 1017]:
      let base = generateMapAttempt(seed, Unlocked)
      for attempt in 1 .. 6:
        let other = generateMapAttempt(seed, Unlocked, 2, attempt)
        check other.width == base.width
        check other.height == base.height
        check other.symmetry == base.symmetry
        check other.layout == base.layout
        check other.endzone == base.endzone
        check other.endzoneRadius == base.endzoneRadius
        check other.homeDepth == base.homeDepth
        check other.mapSizeClass() == base.mapSizeClass()

  test "candidates still differ where they are supposed to":
    var seenObstacles = initHashSet[int]()
    for attempt in 0 .. 5:
      seenObstacles.incl generateMapAttempt(
        1001, Unlocked, 2, attempt).leftObstacles.len
    check seenObstacles.len > 1

  test "4-team candidates keep their layout across attempts":
    let base = generateMapAttempt(1024, Unlocked, 4)
    for attempt in 1 .. 4:
      let other = generateMapAttempt(1024, Unlocked, 4, attempt)
      check other.layout == base.layout
      check other.width == base.width

suite "best-of-K selection":
  test "the static ranker is installed by importing the sim":
    # A binary without the hook falls back to first-valid and generates a
    # DIFFERENT map for the same seed. `sim` imports `map_metrics` precisely
    # so that cannot happen; this is the assertion that keeps it imported.
    check mapFitnessInstalled()
    check mapFitnessLabel() == "map_metrics.staticScore"

  test "k = 1 reproduces the historical first-valid draw":
    for seed in [1001, 1002]:
      var expected: CtfMap
      for attempt in 0 ..< 100:
        let candidate = generateMapAttempt(seed, Unlocked, 2, attempt)
        if validateGeneratedMap(candidate).len == 0:
          expected = candidate
          break
      check generateCtfMap(seed, Unlocked, 2, k = 1) == expected

  test "selection never ships a worse map than the first valid one":
    for seed in [1001, 1002, 1010]:
      let
        first = generateCtfMap(seed, Unlocked, 2, k = 1)
        best = generateCtfMap(seed, Unlocked, 2, k = 4)
      check validateGeneratedMap(best).len == 0
      check evaluateMap(best).staticScore() >=
        evaluateMap(first).staticScore()

  test "selection is deterministic":
    check generateCtfMap(1001, Unlocked, 2, k = 3) ==
      generateCtfMap(1001, Unlocked, 2, k = 3)

  test "K is read from the size class, not from the call site":
    for seed in [1001, 1004]:
      let gameMap = generateMapAttempt(seed, Unlocked)
      check gameMap.selectionK() == selectionK(gameMap.mapSizeClass())
    # Cost is linear in K and grows with board area, so the table must never
    # be flat or increasing: a giant board may not rank more candidates than
    # a standard one.
    for c in MapSizeClass:
      check MapSelectionK[c] >= 1
      if ord(c) > 0:
        check MapSelectionK[c] <= MapSelectionK[MapSizeClass(ord(c) - 1)]
    check MapSelectionK[mszColossal] == 1

  test "an over-constrained lock still raises rather than shipping garbage":
    expect CtfError:
      discard generateCtfMap(
        1001,
        MapGenOverrides(
          windows: -1, pits: -1, pitDensity: -1,
          size: "small", columns: 3, centerFeature: "walls",
          endzone: "disc", endzoneRadius: 200, baseDepth: 520),
        2, k = 2)
