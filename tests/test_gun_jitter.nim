import
  helpers,
  std/unittest,
  ctf/sim

## The firing scene runs on the BARE hexagon (`helpers.bareHexMap`), down the
## board's CENTER ROW — the hexagon's widest chord, open from border to border
## once the arena's furniture is out of the way.
##
## Two things forced the move off the hand-authored arena. The widest fully
## clear corridor there is now 501px and it shifts whenever `arenaHexObstacles`
## is re-tuned, so a pinned lane would assert the arena's furniture rather than
## the jitter. And the fixed `GunRange` (1050) is longer than the standard
## board is WIDE (969) and far longer than its longest open run (626), so no
## hand-authored hex map can present a max-range shot at all. That is exactly
## what the jitter design is for: sigma derives from the LIVE config.gunRange,
## so "80% at max range" holds for any configured range and is pinned here with
## a 250px override.
const
  ShortRange = 250
  CenterX = HexStandardWidth div 2    # 484
  CenterY = HexStandardHeight div 2   # 559
  ShooterX = CenterX - 300
  ShooterY = CenterY
  LaneX0 = ShooterX - 14       # asserted wall-free rectangle around the lane:
  LaneX1 = ShooterX + ShortRange + 26   # covers both bodies (+-PlayerHalf) and
  LaneY0 = ShooterY - 8        # every silhouette sample the shots can probe.
  LaneY1 = ShooterY + 8
  MaxRangeTargetX = ShooterX + ShortRange
  BeyondTargetX = ShooterX + ShortRange + 12
  HalfRangeTargetX = ShooterX + ShortRange div 2
  PointBlankTargetX = ShooterX + 60

proc shortRangeSim(seed: int): SimServer =
  result = initCtfForTest(bareHexConfig(
    """"gunRange": """ & $ShortRange & """, "seed": """ & $seed))
  result.gameEventLoggingEnabled = false
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.players[0].x = ShooterX
  result.players[0].y = ShooterY
  result.players[0].aimBrads = 0    # due east, exactly down the lane.
  result.players[1].y = ShooterY

proc fireOnce(game: var SimServer, targetX: int): bool =
  ## One armed shot at a full-health target parked at (targetX, ShooterY);
  ## returns whether it connected.
  game.players[1].x = targetX
  game.players[0].windupBrads = -1
  game.players[0].fireCooldown = 0
  game.players[1].hp = 3
  game.tryFire(0)
  game.players[1].hp < 3

proc hitCount(game: var SimServer, targetX, shots: int): int =
  for _ in 0 ..< shots:
    if game.fireOnce(targetX):
      inc result

suite "gun range: one fixed cap, every map":
  test "the fixed range no longer outreaches the standard board's long axis":
    ## GunRange was frozen at 1050 on the rectangular board, where it was the
    ## width of the SMALLEST field (round(1235 * 0.85)). It is still frozen
    ## (GV34) and every jitter sigma below derives from it, so it is pinned.
    ##
    ## WHAT THE LANDSCAPE FLIP CHANGED. The portrait hexagon was 969 across its
    ## widest span, so 1050 outranged the entire standard board and range was
    ## simply not a constraint there. The flat-top board is 1119 vertex to
    ## vertex, so for the first time the playfield's longest chord EXCEEDS one
    ## gun range — while still being shorter than one along the board's other
    ## axis. That asymmetry is new and it lands on the base-to-base axis.
    check GunRange == 1050
    check GunRange < HexStandardWidth      # 1050 < 1119, the long axis
    check GunRange > HexStandardHeight     # 1050 >  969, the short axis
    ## It is the OPEN RUN, not the chord, that decides whether this matters:
    ## terrain is what ends a sightline on a hex arena. `tools/hex_range_probe`
    ## sweeps 180 directions on the shipped standard arena and measures 1033px,
    ## which still fits inside one gun range — with 17px to spare, where the
    ## portrait board had the whole question moot. Closing the last of that gap
    ## is what the sixth sightline family (arena.nim's SightlineAxisCount) is
    ## for; if this margin ever goes negative the board outranges the gun and
    ## spawn-to-spawn fire becomes possible.
    var config = defaultGameConfig()
    config.update("""{"mapPath": "gen", "mapSeed": 7, "mapSize": "small"}""")
    let smallMap = resolveCtfMapMetadata(config)
    check (smallMap.width, smallMap.height) == HexSizes[hxSmall]
    check config.gunRange == GunRange
    ## The small class is still entirely inside one gun range on both axes.
    check GunRange > smallMap.width

  test "larger maps keep the same absolute range":
    for lock in [
      """{"mapPath": "gen", "mapSeed": 7, "mapSize": "giant"}""",
      """{"mapPath": "arena-large"}""",
      """{"mapPath": "arena"}"""
    ]:
      var config = defaultGameConfig()
      config.update(lock)
      check config.gunRange == GunRange
      check resolveCtfMapMetadata(config).gunRange == GunRange

suite "gun jitter: fuzzed aim, calibrated at max range":
  test "the scene is laid out as documented":
    var game = shortRangeSim(1)
    for y in LaneY0 .. LaneY1:
      for x in LaneX0 .. LaneX1:
        check not game.isWall(x, y)
    check game.canOccupy(ShooterX, ShooterY)
    check game.canOccupy(BeyondTargetX, ShooterY)
    check game.config.gunRange == ShortRange

  test "a fully visible target past max range is never hit":
    var game = shortRangeSim(2)
    check game.hitCount(BeyondTargetX, 300) == 0

  test "a miss's tracer never travels past max range":
    var game = shortRangeSim(3)
    discard game.hitCount(BeyondTargetX, 50)
    for shot in game.recentShots:
      check shot.x1 - shot.x0 <= ShortRange

  test "a fully visible target at max range is hit ~80% of the time":
    var game = shortRangeSim(4)
    let hits = game.hitCount(MaxRangeTargetX, 5000)
    ## 0.80 +- 0.03 is ~5 standard errors at 5000 shots: deterministic per
    ## seed, and loose enough that any correct sigma stays inside.
    check hits >= 3850
    check hits <= 4150

  test "closer targets are hit near-deterministically":
    var game = shortRangeSim(5)
    ## At half range the same sigma leaves ~99% (2.57 sigma of margin).
    check game.hitCount(HalfRangeTargetX, 2000) >= 1940
    ## Point-blank the jitter cannot miss a fully visible body.
    check game.hitCount(PointBlankTargetX, 500) == 500

  test "jitter rides the seeded sim RNG: same seed, same shots":
    var
      a = shortRangeSim(999)
      b = shortRangeSim(999)
    for _ in 0 ..< 200:
      check a.fireOnce(MaxRangeTargetX) == b.fireOnce(MaxRangeTargetX)
