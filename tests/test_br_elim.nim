## BR elimination ruleset (`config.brMode`, docs/designs/BR_MAPGEN.md §1):
## no respawns (a death is permanent), the game ends the moment at most one
## team has a living player, flags/captures never eliminate a team or end
## the game, and a maxTicks timeout resolves by a pre-registered tiebreak
## — most living, then latest last death, then kills, then damage, then
## slot index — which is a strict TOTAL order, so a timeout is never a
## draw. Generic over team count — tested at 2 and 4, the two team counts
## the engine seats today (`activeTeams` asserts `[2, 4]`); nothing here
## assumes either number, so it keeps working the day team16 lands.

import
  helpers,
  std/[json, unittest],
  bitworld/spriteprotocol,
  ctf/sim

proc brConfig(teams = 2): GameConfig =
  result = defaultGameConfig()
  result.brMode = true
  result.teams = teams
  if teams == 4:
    result.mapPath = "gen"
    result.mapGen.layout = "corners"
    result.mapSeed = 42

proc brGame(teams = 2): SimServer =
  ## A started BR game with one player per team (slots deal round-robin —
  ## the same one-per-team shape test_four_team.nim uses for its
  ## capture/wipe tests).
  result = initCtfForTest(brConfig(teams))
  for i in 0 ..< teams:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc brDuoGame(teams = 4): SimServer =
  ## A started BR game with two players per team (Red/Blue/Green/Yellow at
  ## 2 seats each, slots dealing round-robin: 0,4=Red 1,5=Blue 2,6=Green
  ## 3,7=Yellow) — enough headroom to give one team MORE living players
  ## than another without fully wiping anyone, for the tiebreak tests.
  result = initCtfForTest(brConfig(teams))
  for i in 0 ..< teams * 2:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

suite "BR elimination ruleset":
  test "brMode off leaves classic respawn untouched":
    var sim = twoTeamGame()
    check not sim.config.brMode
    sim.killPlayer(1, 0)
    check sim.players[1].lives == sim.config.lives - 1
    check sim.players[1].respawnTimer == max(1, sim.config.respawnTicks)

  test "brMode defaults to false and its echo is omitted when off":
    check defaultGameConfig().brMode == false
    let echoed = parseJson(defaultGameConfig().configJson())
    check not echoed.hasKey("brMode")

  test "brMode:true round-trips through config JSON":
    var config = defaultGameConfig()
    config.update("""{"brMode": true}""")
    check config.brMode
    let echoed = parseJson(config.configJson())
    check echoed["brMode"].getBool == true

  test "a killed player never re-enters, regardless of configured lives/respawnTicks":
    var sim = brGame()
    sim.config.lives = 5
    sim.config.respawnTicks = 3

    sim.killPlayer(1, 0)

    check sim.players[1].lives == 0
    check sim.players[1].respawnTimer == 0
    check not sim.players[1].alive
    # Step well past what would have been several respawn windows: the
    # respawn scheduler (respawnPlayers) only acts when lives > 0, so a
    # brMode death never gets a re-entry tick.
    let none = newSeq[InputState](sim.players.len)
    for _ in 1 .. 20:
      sim.step(none, none)
    check not sim.players[1].alive
    check sim.players[1].lives == 0

  test "win on last team standing: 2 teams":
    var sim = brGame(2)
    sim.players[1].alive = false
    sim.players[1].lives = 0

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw

  test "win on last team standing: 4 teams (one at a time, not a single wipe)":
    var sim = brGame(4)
    sim.players[1].alive = false  # Blue out
    sim.players[1].lives = 0
    sim.players[2].alive = false  # Green out
    sim.players[2].lives = 0
    sim.checkWinCondition()
    check sim.phase == Playing  # Red and Yellow both still stand

    sim.players[3].alive = false  # Yellow out — Red is the last team.
    sim.players[3].lives = 0
    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw

  test "simultaneous wipe is a draw":
    var sim = brGame(2)
    sim.players[0].alive = false
    sim.players[0].lives = 0
    sim.players[1].alive = false
    sim.players[1].lives = 0

    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.isDraw

  test "flags never end or score a BR game: a capture is a no-op":
    var sim = brGame(4)
    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0  # the pickup itself is unaffected —
                                          # brMode gates checkWinCondition,
                                          # not tryPickupFlags (that's the
                                          # spawn-points lane's flagless gate).
    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)

    sim.checkWinCondition()

    # The capture branch is skipped entirely in brMode: Green is NOT
    # eliminated and the game is NOT over, unlike classic play (see
    # test_four_team.nim's "a capture eliminates the captured team").
    check sim.phase == Playing
    ## Green holds exactly one seat here (brGame seats one per team), so its
    ## aliveness IS "not eliminated" — the whole claim, in one check.
    ##
    ## A `lives > 0` check used to sit alongside this one. It is gone rather
    ## than updated: in brMode a LIVING cog correctly holds zero spare lives
    ## (seatLivesFor — there are no respawns to spend them on), so that line
    ## was asserting an implementation detail the mode defines as 0, and it
    ## would now fail for a team that is perfectly healthy.
    check sim.players[2].alive
    check not sim.flags[Green].captured

  test "maxTicks tiebreak: most living players wins":
    var sim = brDuoGame()
    sim.config.maxTicks = 5
    # Wipe Green (2,6) and Yellow (3,7) entirely, and one of Blue's two
    # (5) — leaves Red with 2 living, Blue with 1. Two teams still stand
    # (Red, Blue), so the wipe check can't resolve it before the clock
    # does; the tiebreak must.
    for i in [2, 3, 5, 6, 7]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)

    check sim.phase == GameOver
    check sim.timeLimitReached
    check not sim.isDraw
    check sim.winner == Red

  test "maxTicks tiebreak: tied living players breaks on damage dealt":
    var sim = brDuoGame()
    sim.config.maxTicks = 5
    # Red and Blue tied at 1 living player each; Green/Yellow fully wiped.
    for i in [2, 3, 4, 6, 7]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.players[5].alive = false
    sim.players[5].lives = 0
    sim.players[0].damageDealt = 50  # Red's lone survivor
    sim.players[1].damageDealt = 10  # Blue's lone survivor
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)

    check sim.phase == GameOver
    check sim.timeLimitReached
    check not sim.isDraw
    check sim.winner == Red

  test "maxTicks tiebreak: a total tie still crowns a winner, NEVER a draw":
    ## This test asserted a DRAW until the draw-free ruling. Draws bred
    ## passive double-death play — if surviving to the clock splits the
    ## result, the dominant line is to avoid the fight — so the tiebreak is
    ## now a strict total order ending in slot index, and a timeout cannot
    ## return a draw however tied the teams are.
    var sim = brDuoGame()
    sim.config.maxTicks = 5
    for i in [2, 3, 4, 5, 6, 7]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    # Red's and Blue's lone survivors are tied on EVERY measured axis:
    # living (1 each), last death (neither of the survivors ever died),
    # kills (0) and damage (0). Only the final arbitrary rank is left.
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)

    check sim.phase == GameOver
    check sim.timeLimitReached
    check not sim.isDraw
    check sim.winner == Red      ## lowest seated slot index (0 vs 1).

  test "maxTicks tiebreak: equal living breaks on who stayed alive LONGER":
    ## Rank 2, ahead of kills and damage: of two teams equally reduced, the
    ## one that held its cogs longer was winning for longer. Deaths go
    ## through killPlayer so lastDeathTick is set the way a real match sets
    ## it, rather than by poking `alive` directly.
    var sim = brDuoGame()
    sim.config.maxTicks = 400
    # Wipe Green and Yellow outright so only Red and Blue stand.
    for i in [2, 3, 6, 7]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    let none = newSeq[InputState](sim.players.len)
    # Blue loses a cog EARLY...
    sim.step(none, none)
    sim.killPlayer(5, -1)
    # ...Red loses one much later, so Red held four-quarters of the match.
    for _ in 0 ..< 50:
      if sim.phase != Playing: break
      sim.step(none, none)
    sim.killPlayer(4, -1)
    # Both are now 1 living, 0 kills, 0 damage — only last-death separates.
    while sim.phase == Playing:
      sim.step(none, none)

    check sim.phase == GameOver
    check sim.timeLimitReached
    check not sim.isDraw
    check sim.winner == Red

  test "maxTicks tiebreak: equal living and equal survival breaks on KILLS":
    ## Rank 3, ahead of damage: a team that finished its fights outranks one
    ## that only chipped.
    var sim = brDuoGame()
    sim.config.maxTicks = 5
    for i in [2, 3, 4, 6, 7]:
      sim.players[i].alive = false
      sim.players[i].lives = 0
    sim.players[5].alive = false
    sim.players[5].lives = 0
    sim.players[0].kills = 2          ## Red's survivor finished two.
    sim.players[1].kills = 0
    sim.players[1].damageDealt = 999  ## Blue chipped far more, and loses.
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)

    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == Red

  test "classic maxTicks (brMode off) is still an unconditional scoreless draw":
    var sim = twoTeamGame()
    sim.config.maxTicks = 5
    sim.players[0].damageDealt = 999  # would win a BR tiebreak; must not
                                       # matter here.
    let none = newSeq[InputState](sim.players.len)
    while sim.phase == Playing:
      sim.step(none, none)
    check sim.isDraw
    check sim.timeLimitReached

  test "determinism: same seed twice gives the same winner and gameHash":
    proc runGame(): SimServer =
      result = brGame(4)
      result.killPlayer(1, 0)  # Blue out
      result.killPlayer(2, 0)  # Green out
      result.killPlayer(3, 0)  # Yellow out — Red is the sole survivor.
      let none = newSeq[InputState](0)
      for tick in 0 ..< 50:
        result.step(none, none)
    var a = runGame()
    let b = runGame()

    check a.phase == GameOver
    check a.phase == b.phase
    check a.winner == Red
    check a.winner == b.winner
    check not a.isDraw
    check a.gameHash() == b.gameHash()
    check a.tickCount == b.tickCount

suite "GLORY v11 (BR increment 3): partner-avenge PAYBACK":
  # BR increment 3: `avengesKiller` (avenging YOUR OWN killer) can never
  # fire in BR -- a killer who had ever died is already permanently
  # eliminated, so it can never be the one pulling the trigger on a later
  # tick. `avengesPartner` is BR's own gate: kill the same enemy that
  # killed your DEAD DUO PARTNER. `brDuoGame(teams=4)` seats slots
  # 0,4=Red 1,5=Blue 2,6=Green 3,7=Yellow -- Red's duo is {0, 4}.

  test "killing your dead partner's killer mints PAYBACK":
    var sim = brDuoGame()
    # 300px apart: strictly between PointBlankPx (110) and LongshotPx (700)
    # at this test's stock (reference) gunRange, so neither distance-based
    # descriptor in `killDeed`'s precedence (both rank ABOVE the avenge
    # check) preempts the classification this test is actually about.
    sim.centerOn(0, 500, 500)
    sim.centerOn(1, 500, 800)
    sim.killPlayer(0, 1)  # Blue (1) kills Red's p0.
    check sim.deedCounts[dRevengeKill] == 0
    sim.centerOn(4, 500, 500)
    sim.killPlayer(1, 4)  # Red's SURVIVING partner (4) kills Blue (1) back.
    check sim.deedCounts[dRevengeKill] == 1
    check sim.players[4].avengedPartner

  test "the taper holds: a second kill by the same avenger never re-mints it":
    var sim = brDuoGame()
    sim.centerOn(0, 500, 500)
    sim.centerOn(1, 500, 800)
    sim.killPlayer(0, 1)   # Blue kills Red's p0.
    sim.centerOn(4, 500, 500)
    sim.killPlayer(1, 4)   # Red's p4 avenges -- mints once.
    check sim.deedCounts[dRevengeKill] == 1
    sim.centerOn(5, 800, 800)
    sim.centerOn(6, 800, 1100)
    sim.killPlayer(5, 6)   # unrelated kill elsewhere on the board...
    sim.centerOn(4, 800, 800)
    sim.killPlayer(6, 4)   # ...p4 lands ANOTHER kill; must not re-mint.
    check sim.deedCounts[dRevengeKill] == 1

  test "avengesPartner never fires outside brMode (classic, same duo shape)":
    # Classic (brMode=false): even the identical "dead teammate, surviving
    # teammate avenges" shape must resolve as an ordinary kill -- the new
    # gate reads nothing but `sim.config.brMode`.
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("red1")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[0].team = Red
    sim.players[1].team = Red
    sim.players[2].team = Blue
    sim.killPlayer(0, 2)  # Blue's p2 kills Red's p0.
    sim.killPlayer(2, 1)  # Red's SURVIVING p1 kills Blue's p2 back.
    check sim.deedCounts[dRevengeKill] == 0
    check not sim.players[1].avengedPartner

  test "a cog with no dead partner never mints payback off an unrelated kill":
    var sim = brDuoGame()
    sim.killPlayer(5, 6)  # an unrelated kill: Green kills Blue's p5.
    check sim.deedCounts[dRevengeKill] == 0
    check not sim.players[4].avengedPartner

suite "GLORY v11 (BR increment 3): dWipe disabled in brMode":
  # MEASURED (re-simulating the GV47 episode-s830 reference recording and
  # its five 31337-seeded siblings, PR #313, 2026-08-30): winner glory
  # converged to 626-627g across every one of them -- a single `dWipe`
  # mint (paid to whichever team happens to survive) was 95.8% of the
  # winner's whole episode glory on s830 alone. Disabled outright in
  # brMode; CTF is untouched.

  test "the deciding elimination mints no dWipe in brMode":
    var sim = brGame(2)
    sim.killPlayer(1, 0)  # Red (0) kills Blue's only player -- Red wins.
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.deedCounts[dWipe] == 0

  test "dWipe still mints in classic play (brMode off), same shape, unaffected":
    var sim = twoTeamGame()
    sim.players[1].lives = 1  # Blue is on its last life.
    sim.killPlayer(1, 0)      # Red kills Blue's only life -- a real wipe.
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == Red
    check sim.deedCounts[dWipe] == 1
