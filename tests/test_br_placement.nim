## BR placement ranking + reward (docs §7.3, the survival-pricing lane).
##
## finishGame's win-gate only ever scored the LAST-standing team; every
## other team took a flat lossReward, and AchievementPacifist (attacks==0)
## / AchievementSpotless (taken==0) stacked on that win reward with no
## regard for whether the winning team ever fought — a pure-hiding winner
## (never attacked, never touched) earned the win AND both badges. This
## suite covers the fix:
##   1. `brPlacements` — a 1..N placement rank for every seated team, from
##      the same total order `brTiebreakWinner` already used to break a
##      maxTicks timeout (living, then last-death, then kills, then
##      damage, then seat index — a strict total order, so it assigns a
##      distinct rank to every team with no ties left over).
##   2. finishGame's BR placement reward: a losing team's reward is keyed
##      on that rank via the named `BrPlacementBonus` schedule, GATED on
##      engagement evidence (attacksMade>0 or damageDealt>0 somewhere on
##      the team) — no evidence, no schedule, just the plain loss floor.
##      Clamped below the winner's own reward so a placement can never
##      out-earn winning outright, at any team count.
##   3. the achievement gate: brMode requires that SAME engagement
##      evidence for Pacifist/Spotless, so neither can pay on top of an
##      unengaged win. Classic (non-BR) play is untouched throughout —
##      every new code path here is behind `sim.config.brMode`.

import
  helpers,
  std/[algorithm, json, sequtils, unittest],
  ctf/[global, sim]

const
  Groups = 16
  W = 1235
  H = 659
  SpawnClear = 40

proc gridSpawnPointsNode(count = Groups): JsonNode =
  ## 16 fixed points on a 4x4 grid across the board — the same shape
  ## test_br_team_bridge.nim's bridge fixture uses, just for a lighter
  ## 1-seat-per-team roster here (this suite pokes combat/elimination
  ## state directly; it never needs real navigation).
  result = newJArray()
  for i in 0 ..< count:
    let
      col = i mod 4
      row = i div 4
    result.add %*[154 + 308 * col, 82 + 165 * row]

proc br16Spec(): string =
  ## A minimal 16-group BR-shaped map spec (symNone, flagless, all four
  ## neutral item pools authored so validateMap accepts it).
  var node = %*{
    "name": "br-placement-demo",
    "width": W, "height": H,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": SpawnClear, "spawnClearH": SpawnClear,
    "gunRange": 331,
    "symmetry": "none",
    "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "medKitSpawns": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "medKitCandidates": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "leftObstacles": newJArray(),
    "flagless": true,
  }
  node["spawnPoints"] = gridSpawnPointsNode()
  node["shieldSpawns"] = gridSpawnPointsNode()
  node["spraySpawns"] = gridSpawnPointsNode()
  node["grenadeSpawns"] = gridSpawnPointsNode()
  node["spawnGroups"] = %Groups
  $node

proc br16Game(seats = Groups): SimServer =
  ## A started 16-team BR game, one seat per team (round-robin over 16
  ## seats deals player i to Team(i) exactly), so every test below can
  ## address "the team ranked Kth" as player index K.
  var config = defaultGameConfig()
  config.teams = Groups
  config.mapSpec = br16Spec()
  config.brMode = true
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  ## Process-global board/endzone bakes are keyed on byte size alone —
  ## defend against a same-sized sibling test's cached map (see
  ## test_br_team_bridge.nim, which does the same for the same reason).
  invalidateBoardMapCaches()

proc brDuo2Game(): SimServer =
  ## A started 2-team BR game — the small-team-count edge the placement
  ## reward's clamp exists for (see "clamp" tests below).
  var config = defaultGameConfig()
  config.brMode = true
  config.teams = 2
  result = initCtfForTest(config)
  discard result.addPlayer("p0")
  discard result.addPlayer("p1")
  result.startGame()

proc earned(sim: SimServer, address: string): seq[string] =
  for account in sim.rewardAccounts:
    if account.address == address:
      return account.earnedAchievements

suite "BR placement ranking":
  test "brPlacements: full 1..16 assignment, ties resolved by the total order":
    var sim = br16Game()
    # Team(0) and Team(1) both stay alive all game (never die) -- tied on
    # every measured axis, so only their seat index (0 < 1) separates
    # them: Team(0) ranks ahead of Team(1).
    # Teams 2..15 are all eliminated on the SAME tick with identical
    # kills/damage (0) -- another full tie, broken the same way: lower
    # seat index ranks better.
    for k in 2 .. 15:
      sim.killPlayer(k, -1)

    let placement = sim.brPlacements()

    check placement[Team(0)] == 1
    check placement[Team(1)] == 2
    for k in 2 .. 15:
      check placement[Team(k)] == k + 1   # team2->3, team3->4, ..., team15->16

    # Holistic check: every seated team got a DISTINCT rank, and together
    # they are exactly the permutation 1..16 -- no gaps, no duplicates,
    # even though half the field tied on every measured stat.
    var ranks: seq[int]
    for team in sim.teams():
      ranks.add placement[team]
    ranks.sort()
    check ranks == toSeq(1 .. 16)

  test "brPlacements: kills and damage outrank a plain seat tie":
    var sim = br16Game()
    for k in 2 .. 15:
      sim.killPlayer(k, -1)
    # Team(1) and Team(0) are tied on living/last-death (both never die);
    # give Team(1) a kill so it outranks Team(0) on that axis instead of
    # falling through to seat.
    sim.players[1].kills = 1

    let placement = sim.brPlacements()

    check placement[Team(1)] == 1
    check placement[Team(0)] == 2

suite "BR placement reward":
  test "engagement gate: zero engagement collapses to the plain loss floor":
    var sim = br16Game()
    for k in 2 .. 15:
      sim.killPlayer(k, -1)
    # Team(1) (rank 2, the best-placed loser) never attacked and never
    # dealt damage -- no engagement evidence.
    check sim.players[1].attacksMade == 0
    check sim.players[1].damageDealt == 0

    sim.finishGame(Team(0))

    check sim.players[1].reward == LossReward

  test "engagement gate: an engaged 2nd place scores the schedule":
    var sim = br16Game()
    for k in 2 .. 15:
      sim.killPlayer(k, -1)
    sim.players[1].attacksMade = 1   # engaged: fired at least once.

    sim.finishGame(Team(0))

    check sim.brPlacements()[Team(1)] == 2
    check sim.players[1].reward == LossReward + BrPlacementBonus[2]
    check sim.players[1].reward > LossReward   # strictly better than the floor.

  test "engagement gate: damageDealt alone (no attacksMade) also counts as engaged":
    ## The OR is defensive, not decorative -- exercise the second arm too.
    var sim = br16Game()
    for k in 1 .. 15:
      sim.killPlayer(k, -1)
    sim.players[1].damageDealt = 5   # rank 2 (first-eliminated among 1..15
                                      # ties on seat), damage-only engaged.

    sim.finishGame(Team(0))

    check sim.brPlacements()[Team(1)] == 2
    check sim.players[1].reward == LossReward + BrPlacementBonus[2]

  test "placement reward never exceeds the winner's own reward, worse ranks score less":
    var sim = br16Game()
    for k in 1 .. 15:
      sim.killPlayer(k, -1)
      sim.players[k].attacksMade = 1  # every eliminated team engaged, so
                                       # every one of them reads the
                                       # schedule instead of the floor.

    sim.finishGame(Team(0))

    let winnerReward = sim.players[0].reward
    check winnerReward == WinReward * (Groups - 1)  # untouched by placement.
    var previous = winnerReward
    for k in 1 .. 15:
      check sim.players[k].reward < winnerReward
      check sim.players[k].reward <= previous  # monotone non-increasing by rank.
      previous = sim.players[k].reward
    # Worst rank (16th) added nothing on top of the loss floor.
    check sim.players[15].reward == LossReward

  test "clamp: at a small team count the reward never reaches the winner's":
    ## BrPlacementBonus[2] (5) would push a naive lossReward+bonus (4) past
    ## a 2-team BR game's winReward (1) -- finishGame clamps it to
    ## winReward - 1 instead, so a placement can never out-earn the win,
    ## regardless of team count.
    var sim = brDuo2Game()
    sim.killPlayer(1, -1)
    sim.players[1].attacksMade = 1

    sim.finishGame(Red)

    let winnerReward = sim.players[0].reward
    check winnerReward == WinReward * 1
    check sim.players[1].reward < winnerReward
    check sim.players[1].reward == winnerReward - 1

  test "brMode off: reward stays exactly the classic +1/-1, unaffected by the new plumbing":
    var sim = twoTeamGame()
    check not sim.config.brMode
    sim.players[1].attacksMade = 0   # would-be "unengaged 2nd place" shape,
    sim.players[1].damageDealt = 0   # but brMode is off so it never matters.

    sim.finishGame(Red)

    check sim.players[0].reward == WinReward * 1
    check sim.players[1].reward == LossReward

suite "BR achievement gate":
  test "brMode: a zero-engagement win earns NEITHER pacifist nor spotless":
    ## The exact "pure-hiding winner" doctrine SS7.3 caps: every cog on the
    ## winning team made zero attacks and took zero damage -- before this
    ## gate, that win alone earned both badges on top of the win reward.
    var sim = br16Game()
    for k in 1 .. 15:
      sim.killPlayer(k, -1)
    check sim.players[0].attacksMade == 0
    check sim.players[0].damageTaken == 0

    sim.finishGame(Team(0))

    check AchievementPacifist notin sim.earned("p0")
    check AchievementSpotless notin sim.earned("p0")

  test "brMode: an engaged, untouched win still earns spotless (never pacifist)":
    var sim = br16Game()
    for k in 1 .. 15:
      sim.killPlayer(k, -1)
    sim.players[0].attacksMade = 3
    sim.players[0].damageDealt = 10
    check sim.players[0].damageTaken == 0

    sim.finishGame(Team(0))

    check AchievementPacifist notin sim.earned("p0")  # attacked -- can't be pacifist anyway.
    check AchievementSpotless in sim.earned("p0")      # fought AND never touched.

  test "brMode off: pacifist/spotless behave exactly as before the gate":
    var sim = twoTeamGame()
    check not sim.config.brMode

    sim.finishGame(Red)

    check AchievementPacifist in sim.earned("red0")
    check AchievementSpotless in sim.earned("red0")

suite "BR placement hash discipline":
  test "account-level bookkeeping (rewardAccounts) never enters gameHash":
    var sim = br16Game()
    for k in 2 .. 15:
      sim.killPlayer(k, -1)
    sim.players[1].attacksMade = 1
    sim.finishGame(Team(0))
    let hashBefore = sim.gameHash()

    # Mutate ONLY the address-level reward account bookkeeping -- as if
    # placement/achievements had computed something else entirely -- and
    # confirm the hash does not move. gameHash deliberately excludes
    # rewardAccounts (derived bookkeeping); this is the machine-checked
    # guard that stays true after this lane.
    for i in 0 ..< sim.rewardAccounts.len:
      sim.rewardAccounts[i].reward = 999999
      sim.rewardAccounts[i].earnedAchievements = @["bogus"]

    check sim.gameHash() == hashBefore

  test "determinism: BR placement reward is a pure function of already-hashed state":
    proc runScenario(): SimServer =
      result = br16Game()
      for k in 2 .. 15:
        result.killPlayer(k, -1)
      result.players[1].attacksMade = 1
      result.finishGame(Team(0))
    let a = runScenario()
    let b = runScenario()

    check a.players[1].reward == b.players[1].reward
    check a.players[0].reward == b.players[0].reward
    check a.gameHash() == b.gameHash()
