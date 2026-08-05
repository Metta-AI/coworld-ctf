## Four-team CTF rules, on a HAND-AUTHORED Klein-four hexagon.
##
## Hex Stage 2 GENERATES 2-team boards only (`generateMapAttempt` raises for
## any other count — the cube-space orbit rasterizer that fills a hexagon with
## 3/4/6-fold terrain is Stage 2b), so the old `mapPath: "gen"` + `mapLayout:
## "corners"/"plus"` fixtures cannot exist. Nothing in this file was ever ABOUT
## the terrain, though: it tests seating, hearts, elimination, and pot scoring.
## So the fixture is a bare hexagon carrying `symKlein4` / `layoutHex4`, pinned
## through the same `mapSpec` channel a replay uses — which is a real supported
## map (`validateMap` accepts it, `teamAnchor`/`teamImagePoint`/`captureZone`
## all resolve it) and exercises the 4-team spec path end to end besides.
##
## The terrain-shaped assertions that USED to live here — the plus arm mouths
## and the diagonal corner zones — are gone with their geometries and are
## replaced by the V4 orbit properties that took their place: the four anchors
## and the four capture discs are exact images of one another under the map's
## own group.
import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/[global, sim]

proc fourTeamMap(): CtfMap =
  ## The standard-class 4-team board: the same 969 x 1119 hexagon every other
  ## test runs on. Built by `helpers.hexTeamMap`.
  hexTeamMap()

proc giantFourTeamMap(): CtfMap =
  ## The giant class (2.6x), for the 32-seat 4ffa8 shape.
  hexTeamMap(HexSizes[hxGiant].width, HexSizes[hxGiant].height, 26, 10)

proc fourTeamConfig(gameMap = fourTeamMap()): GameConfig =
  result = defaultGameConfig()
  result.update(fourTeamSpecJson(gameMap))

proc fourTeamGame(): SimServer =
  ## A started 4-team game with one player per team (slots deal mod 4).
  result = initCtfForTest(fourTeamConfig())
  for i in 0 ..< 4:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

suite "four team ctf":
  test "the hand-authored Klein-four board is a real 4-team map":
    ## The fixture has to be a map the engine would accept from a replay, not
    ## a struct the tests alone believe in: it round-trips through the spec,
    ## validates, and seats four teams.
    let gameMap = fourTeamMap()
    check gameMap.teamCount() == 4
    check gameMap.symmetry == symKlein4
    check gameMap.layout == layoutHex4
    check gameMap.endzone == ezDisc
    check mapFromSpecJson(mapSpecJson(gameMap)) == gameMap
    check resolveCtfMapMetadata(fourTeamConfig(gameMap)) == gameMap
    ## Every anchor is clear of the hull by more than its own protected apron,
    ## so all four endzones are real floor rather than half-void.
    let board = gameMap.mapBoard()
    for team in gameMap.teams():
      let anchor = gameMap.teamAnchor(team)
      check board.hexEdgeDist(anchor.x, anchor.y) >
        float(gameMap.endzoneRadius + EndzoneWallMargin + ArenaBorder)

  test "generating a 4-team map is refused until Stage 2b":
    ## The replacement for the old generated corners/plus fixtures: the
    ## generator says so out loud rather than emitting a rounded orbit.
    expect CtfError:
      discard generateMapAttempt(
        42, MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams = 4)
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "gen", "mapSeed": 42}""")

  test "seats deal round all four teams":
    let sim = fourTeamGame()
    check sim.gameMap.teamCount() == 4
    check sim.teams() == Red .. Yellow
    for i in 0 ..< 4:
      check sim.players[i].team == Team(i)

  test "all four flags start home on their own pedestals":
    let sim = fourTeamGame()
    for team in sim.teams():
      let home = sim.gameMap.flagHome(team)
      check sim.flags[team].carrier == -1
      check sim.flags[team].x == home.x
      check sim.flags[team].y == home.y

  test "any enemy flag can be stolen, never your own":
    var sim = fourTeamGame()
    let greenHome = sim.gameMap.flagHome(Green)
    # Red walks onto the GREEN pedestal and takes the heart.
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].carryingFlag
    # Green itself cannot interact with its own (returned) flag.
    sim.resetFlag(Green)
    sim.players[0].carryingFlag = false
    sim.centerOn(2, greenHome.x, greenHome.y)
    sim.tryPickupFlags(2)
    check sim.flags[Green].carrier == -1
    check not sim.players[2].carryingFlag

  proc captureHeart(sim: var SimServer, flagTeam: Team) =
    ## Has red player 0 steal one team's heart and run it home.
    let home = sim.gameMap.flagHome(flagTeam)
    sim.centerOn(0, home.x, home.y)
    sim.tryPickupFlags(0)
    check sim.flags[flagTeam].carrier == 0
    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.checkWinCondition()

  test "a capture eliminates the captured team and the game goes on":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Three teams still stand: no winner yet.
    check sim.phase == Playing
    # Green is out: its player is dead with no lives, its heart out of play.
    check not sim.players[2].alive
    check sim.players[2].lives == 0
    check sim.players[2].respawnTimer == 0
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    # The captor's hands are free to steal the next heart.
    check not sim.players[0].carryingFlag

  test "elimination deaths never count in the stats (GV35)":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Green's player folded with its team but was never killed: the deaths
    # stat (the endscreen D column) stays at zero, and the captor is not
    # credited with a kill.
    check not sim.players[2].alive
    check sim.players[2].deaths == 0
    check sim.players[0].kills == 0
    # A combat kill still counts as ever.
    sim.killPlayer(1, 0)
    check sim.players[1].deaths == 1

  test "a captured heart cannot be stolen again":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    # Blue walks onto the captured heart's resting spot: no steal.
    sim.centerOn(1, sim.flags[Green].x, sim.flags[Green].y)
    sim.tryPickupFlags(1)
    check sim.flags[Green].carrier == -1
    check not sim.players[1].carryingFlag

  test "eliminating a carrier's team returns the heart it was carrying":
    var sim = fourTeamGame()
    # Green steals the YELLOW heart, then Red captures the GREEN heart.
    let yellowHome = sim.gameMap.flagHome(Yellow)
    sim.centerOn(2, yellowHome.x, yellowHome.y)
    sim.tryPickupFlags(2)
    check sim.flags[Yellow].carrier == 2
    sim.captureHeart(Green)
    # Green's elimination sends the yellow heart home, still in play.
    check sim.flags[Yellow].carrier == -1
    check not sim.flags[Yellow].captured
    check sim.flags[Yellow].x == yellowHome.x
    check sim.flags[Yellow].y == yellowHome.y

  test "wiping a team retires its heart and the game goes on":
    var sim = fourTeamGame()
    # Green dies out with its heart still home: the heart leaves play.
    sim.players[2].alive = false
    sim.players[2].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    # A retired heart cannot be stolen off its resting spot.
    sim.centerOn(1, sim.flags[Green].x, sim.flags[Green].y)
    sim.tryPickupFlags(1)
    check sim.flags[Green].carrier == -1
    check not sim.players[1].carryingFlag

  test "wiping a team drops its heart off an enemy carrier's back":
    var sim = fourTeamGame()
    # Red steals the GREEN heart and runs with it...
    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].carryingFlag
    # ...then Green is wiped from the field: the heart retires straight off
    # the carrier's back and the ex-carrier's hands are free again.
    sim.players[2].alive = false
    sim.players[2].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    check sim.flags[Green].captured
    check sim.flags[Green].carrier == -1
    check not sim.players[0].carryingFlag

  test "capturing all three rival hearts pays the winner +3 and each loser -1":
    var sim = fourTeamGame()
    sim.captureHeart(Green)
    check sim.phase == Playing
    sim.captureHeart(Yellow)
    check sim.phase == Playing
    # The third capture leaves red the only team standing.
    sim.captureHeart(Blue)
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    check sim.players[0].captures == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "the game continues at two teams and ends on the last survivor":
    var sim = fourTeamGame()
    # Wipe Green and Yellow: two teams still stand, the game goes on.
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing
    # Wipe Blue too: Red is the last team standing and wins +3.
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.players[0].reward == 3
    check sim.players[1].reward == -1

  test "config round-trips teams and layout through replay JSON":
    let sim = fourTeamGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.teams == 4
    check config.mapSpec.len > 0
    let rebuilt = resolveCtfMapMetadata(config)
    check rebuilt.layout == layoutHex4
    check rebuilt.teamCount() == 4
    check rebuilt == sim.gameMap

  test "the four homes are an exact Klein-four orbit":
    ## The replacement for the plus-arm test. `GroupV4` is
    ## [identity, mirror-0, mirror-90, half-turn] IN TEAM ORDER, so Blue is
    ## Red flipped in y, Green is Red flipped in x, and Yellow is Red turned
    ## through 180 degrees — all three exact integer bijections on pixels.
    ## Anchors derived from the div-truncated center instead would sit a pixel
    ## off the orbit on an even side, which is a fairness difference.
    let gameMap = fourTeamMap()
    let
      red = gameMap.teamAnchor(Red)
      blue = gameMap.teamAnchor(Blue)
      green = gameMap.teamAnchor(Green)
      yellow = gameMap.teamAnchor(Yellow)
    # Red seeds the orbit off the diagonal, away from both symmetry axes.
    check red.x < gameMap.center.x
    check red.y < gameMap.center.y
    check blue == MapPoint(x: red.x, y: gameMap.height - 1 - red.y)
    check green == MapPoint(x: gameMap.width - 1 - red.x, y: red.y)
    check yellow == MapPoint(
      x: gameMap.width - 1 - red.x, y: gameMap.height - 1 - red.y)
    # Each opposing pair straddles the board's TRUE symmetry axis at
    # (side - 1) / 2 — a half pixel off the integer center on an even side.
    check red.y + blue.y == gameMap.height - 1
    check red.x + green.x == gameMap.width - 1
    # `teamImagePoint` is the same orbit, and the group acts freely: four
    # distinct homes, no two teams sharing one.
    var homes: seq[MapPoint]
    for team in gameMap.teams():
      check gameMap.teamImagePoint(red, team) == gameMap.teamAnchor(team)
      check gameMap.spawnPocketHalf(team) == gameMap.spawnPocketHalf(Red)
      homes.add gameMap.teamAnchor(team)
    for i in 0 ..< homes.len:
      for j in i + 1 ..< homes.len:
        check homes[i] != homes[j]

  test "the four endzones are discs and exact images of one another":
    ## The replacement for the diagonal corner zones. Every hex endzone is a
    ## DISC around its anchor — the one shape that survives a rotation — and
    ## the map's own group carries each team's zone onto the next's, pixel for
    ## pixel, which is the fairness promise the old rot90 test made.
    let gameMap = fourTeamMap()
    let
      redZone = gameMap.captureZone(Red)
      w = gameMap.width
      h = gameMap.height
    check redZone.disc
    check redZone.radius == gameMap.endzoneRadius
    let anchor = gameMap.teamAnchor(Red)
    check redZone.inCaptureZone(anchor.x, anchor.y)
    check redZone.inCaptureZone(anchor.x + redZone.radius, anchor.y)
    check not redZone.inCaptureZone(anchor.x + redZone.radius + 1, anchor.y)
    check not redZone.inCaptureZone(gameMap.center.x, gameMap.center.y)
    ## Green's zone is Red's mirrored in x, Blue's is Red's mirrored in y, and
    ## Yellow's is Red's turned through 180 — counted rather than `check`ed
    ## per pixel so the sweep costs one assertion, not a million.
    var mismatch = 0
    var x = 0
    while x < w:
      var y = 0
      while y < h:
        let inRed = redZone.inCaptureZone(x, y)
        if inRed != gameMap.captureZone(Green).inCaptureZone(w - 1 - x, y):
          inc mismatch
        if inRed != gameMap.captureZone(Blue).inCaptureZone(x, h - 1 - y):
          inc mismatch
        if inRed != gameMap.captureZone(Yellow).inCaptureZone(
            w - 1 - x, h - 1 - y):
          inc mismatch
        y += 3
      x += 3
    check mismatch == 0

  test "4-team pickups ride the same orbit as the homes":
    ## Placed by MIRRORING alone, a pickup lands in the image of some OTHER
    ## team's spot: different cover, different sightlines to the same item.
    ## Every set has to be closed under the map's whole group.
    let gameMap = fourTeamMap()
    let
      w = gameMap.width
      h = gameMap.height
      shields = gameMap.shieldSpawnPoints()
      cans = gameMap.plasmaArcSpawnPoints()
    for points in [shields, cans]:
      check points.len == 4
      let red = MapPoint(x: points[ord(Red)].x, y: points[ord(Red)].y)
      for team in gameMap.teams():
        let image = gameMap.teamImagePoint(red, team)
        check points[ord(team)] == (image.x, image.y)
        ## Each team holds the copy in its OWN endzone, not just somewhere on
        ## the orbit.
        check gameMap.captureZone(team).inCaptureZone(
          points[ord(team)].x, points[ord(team)].y)
    # Shields and cans are distinct spots, not a doubled-up pile.
    for shield in shields:
      check shield notin cans
    ## The grenades sit on four VERTICES of the hexagon — the four off-axis
    ## ones — so their set is closed under both mirrors and the half turn, i.e.
    ## under the whole Klein-four group, without going through `teamOp`.
    let nades = gameMap.grenadeSpawnPoints()
    check nades.len == 4
    for point in nades:
      check (w - 1 - point.x, point.y) in nades
      check (point.x, h - 1 - point.y) in nades
      check (w - 1 - point.x, h - 1 - point.y) in nades

  test "a stepped 4-team episode is deterministic and respawns in-zone":
    proc runGame(): SimServer =
      result = initCtfForTest(fourTeamConfig())
      for i in 0 ..< 8:
        discard result.addPlayer("p" & $i)
      result.startGame()
      # Kill one player so the respawn path (endzone-disc sampling) runs.
      result.killPlayer(5, 0)
      let none = newSeq[InputState](0)
      for tick in 0 ..< 400:
        result.step(none, none)
    var a = runGame()
    let b = runGame()
    check a.gameHash() == b.gameHash()
    check a.tickCount == b.tickCount
    # The killed player respawned somewhere inside its OWN endzone disc.
    check a.players[5].alive
    let
      zone = a.gameMap.captureZone(a.players[5].team)
      cx = a.players[5].x + CollisionW div 2
      cy = a.players[5].y + CollisionH div 2
    check zone.inCaptureZone(cx, cy)

  test "bad 4-team configs fail loudly":
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"teams": 3}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "arena"}""")
    expect CtfError:
      config.update("""{"teams": 4, "mapPath": "pool"}""")
    expect CtfError:
      config.update("""{"teams": 2, "mapPath": "gen", "mapLayout": "corners"}""")
    ## A 2-team game cannot run a 4-team spec.
    expect CtfError:
      config.update(
        """{"teams": 2, "mapSpec": """ & mapSpecJson(fourTeamMap()) & "}")

  test "classic 2-team configs reject green and yellow slots":
    var config = defaultGameConfig()
    config.slots = @[PlayerSlotConfig(team: Green, hasTeam: true)]
    expect CtfError:
      config.update("""{"teams": 2}""")

suite "pot scoring":
  ## Every team antes one point; the winning team takes the whole pot and the
  ## losing teams split the forfeit. 2 teams: +2/-2. 4 teams: +4/-1/-1/-1.

  proc twoTeamPotGame(): SimServer =
    var config = defaultGameConfig()
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 2:
      discard result.addPlayer("p" & $i)
    result.startGame()

  proc fourTeamPotGame(): SimServer =
    var config = fourTeamConfig()
    config.scoring = PotScoring
    result = initCtfForTest(config)
    for i in 0 ..< 4:
      discard result.addPlayer("p" & $i)
    result.startGame()

  test "classic scoring is the default and is untouched":
    check defaultGameConfig().scoring == ClassicScoring
    var sim = fourTeamGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    for i in [2, 3]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.winner == Red
    check sim.players[0].reward == 3
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "two teams pay the winner +2 and the loser -2":
    var sim = twoTeamPotGame()
    sim.players[1].alive = false
    sim.players[1].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 2
    check sim.players[1].reward == -2

  test "four teams pay the winner +4 and each loser -1":
    var sim = fourTeamPotGame()
    for i in 1 ..< 4:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.players[0].reward == 4
    for i in 1 ..< 4:
      check sim.players[i].reward == -1

  test "a time-limit draw still costs every player one point":
    var sim = fourTeamPotGame()
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
    check sim.isDraw
    for i in 0 ..< 4:
      check sim.players[i].reward == TimeoutReward

  test "scoring round-trips through replay JSON and rejects unknown rules":
    let sim = fourTeamPotGame()
    var config = defaultGameConfig()
    config.update(sim.config.configJson())
    check config.scoring == PotScoring
    var bad = defaultGameConfig()
    expect CtfError:
      bad.update("""{"scoring": "winner-take-all"}""")

  test "4ffa8 shape: 32 seats deal 8 per team on a giant board":
    ## The paintbot 4ffa8 variant: MaxPlayers seats, teams 4, giant class. The
    ## size lock used to come from the generator; on a pinned 4-team spec the
    ## board carries its own class, so the check is that the giant hexagon
    ## (2519 x 2909, the 2.6x class) is what got installed.
    var sim = initCtfForTest(fourTeamConfig(giantFourTeamMap()))
    for i in 0 ..< MaxPlayers:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    check sim.gameMap.teamCount() == 4
    check sim.gameMap.width == HexSizes[hxGiant].width
    check sim.gameMap.height == HexSizes[hxGiant].height
    var counts: array[Team, int]
    for i in 0 ..< MaxPlayers:
      inc counts[sim.players[i].team]
    for team in sim.teams():
      check counts[team] == 8
    # No two players share a spawn pixel.
    for i in 0 ..< MaxPlayers:
      for j in i + 1 ..< MaxPlayers:
        check sim.players[i].x != sim.players[j].x or
          sim.players[i].y != sim.players[j].y

## This module installs 4-team maps as the process map, and the standard-class
## one is the SAME 969 x 1119 board as the default arena — so the board render
## caches cannot self-heal on a size mismatch the way test_replay_switch_caches
## relies on. Put the default arena back and drop the caches explicitly.
installDefaultArena()
invalidateBoardMapCaches()
