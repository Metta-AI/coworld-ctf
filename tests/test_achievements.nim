import
  helpers,
  std/[json, unittest],
  ctf/[roster, sim]

## Achievement evaluation (finishGame) and export (playerResultsJson).
## All achievements are WIN-GATED: only the winning team's cogs are
## considered, so idle policies cannot farm pacifist/spotless. Earned ids
## live on the address reward accounts (deduplicated across a maxGames > 1
## episode) and export per slot as results.json `achievements`.

proc earned(sim: SimServer, address: string): seq[string] =
  for account in sim.rewardAccounts:
    if account.address == address:
      return account.earnedAchievements

suite "achievements":
  test "an untouched winner earns pacifist and spotless; the loser nothing":
    var sim = twoTeamGame()
    sim.finishGame(Red)
    check AchievementPacifist in sim.earned("red0")
    check AchievementSpotless in sim.earned("red0")
    check AchievementAlmost notin sim.earned("red0")   # full hp, no cliffhanger
    check AchievementGrenadier notin sim.earned("red0")  # dealt no damage
    check sim.earned("blue0").len == 0

  test "a draw awards nothing to anyone":
    var sim = twoTeamGame()
    sim.finishGame(Red, isDraw = true)
    check sim.earned("red0").len == 0
    check sim.earned("blue0").len == 0

  test "any attack forfeits pacifist; the other badges survive":
    var sim = twoTeamGame()
    sim.players[0].attacksMade = 1
    sim.finishGame(Red)
    check AchievementPacifist notin sim.earned("red0")
    check AchievementSpotless in sim.earned("red0")

  test "damage taken forfeits spotless even when the shield soaked it":
    var sim = twoTeamGame()
    sim.players[0].hasShield = true
    sim.players[0].shieldHp = ShieldLayerHp
    let hpBefore = sim.players[0].hp
    sim.absorbDamage(0, 1, attackerIndex = 1, weapon = "gun")
    check sim.players[0].hp == hpBefore          # the shield ate the hit...
    check sim.players[0].damageTaken == 1        # ...but it still counts
    sim.finishGame(Red)
    check AchievementSpotless notin sim.earned("red0")
    check AchievementPacifist in sim.earned("red0")

  test "almost: one survivor, one hp, no respawns owed":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.players[0].lives = 1                # alive on its last life
    sim.finishGame(Red)
    check AchievementAlmost in sim.earned("red0")
    check AchievementAlmost notin sim.earned("blue0")

  test "almost counts respawns still owed as a full hp bar each":
    # A 1-hp survivor with a respawn in hand is not on the brink.
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.players[0].lives = 2
    sim.finishGame(Red)
    check AchievementAlmost notin sim.earned("red0")
    # Neither is a team whose only remaining cog is dead but respawning —
    # the barrage endgame's usual finish, which the living-hp rule scored
    # as a cliffhanger in one win out of eight.
    var sim2 = twoTeamGame()
    sim2.players[0].alive = false
    sim2.players[0].hp = 0
    sim2.players[0].lives = 1
    sim2.finishGame(Red)
    check AchievementAlmost notin sim2.earned("red0")
    # Out of lives entirely (wipe traded for the win): budget 0 < 2, almost.
    var sim3 = twoTeamGame()
    sim3.players[0].alive = false
    sim3.players[0].hp = 0
    sim3.players[0].lives = 0
    sim3.finishGame(Red)
    check AchievementAlmost in sim3.earned("red0")

  test "almost counts the whole team: two survivors on 1 hp each miss it":
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("red0")
    discard sim.addPlayer("red1")
    discard sim.addPlayer("blue0")
    sim.startGame()
    sim.players[0].team = Red
    sim.players[1].team = Red
    sim.players[2].team = Blue
    sim.players[0].hp = 1
    sim.players[1].hp = 1
    sim.players[0].lives = 1
    sim.players[1].lives = 1
    sim.finishGame(Red)
    check AchievementAlmost notin sim.earned("red0")
    # A dead, out-of-lives teammate contributes nothing: the sole survivor
    # on 1 hp with no respawn left earns it.
    var sim2 = initCtfForTest(defaultGameConfig())
    discard sim2.addPlayer("red0")
    discard sim2.addPlayer("red1")
    discard sim2.addPlayer("blue0")
    sim2.startGame()
    sim2.players[0].team = Red
    sim2.players[1].team = Red
    sim2.players[2].team = Blue
    sim2.players[0].hp = 1
    sim2.players[0].lives = 1
    sim2.players[1].alive = false
    sim2.players[1].hp = 0
    sim2.players[1].lives = 0
    sim2.finishGame(Red)
    check AchievementAlmost in sim2.earned("red0")
    check AchievementAlmost in sim2.earned("red1")  # team badge: whole team

  test "grenadier: at least 80% of the damage dealt came from grenades":
    var sim = twoTeamGame()
    sim.players[0].damageDealt = 5
    sim.players[0].grenadeDamageDealt = 4
    sim.finishGame(Red)
    check AchievementGrenadier in sim.earned("red0")
    # 79% (19 of 24) misses; half certainly does.
    var sim2 = twoTeamGame()
    sim2.players[0].damageDealt = 24
    sim2.players[0].grenadeDamageDealt = 19
    sim2.finishGame(Red)
    check AchievementGrenadier notin sim2.earned("red0")
    var sim3 = twoTeamGame()
    sim3.players[0].damageDealt = 4
    sim3.players[0].grenadeDamageDealt = 2
    sim3.finishGame(Red)
    check AchievementGrenadier notin sim3.earned("red0")

  test "grenadier: under the threshold, or zero damage dealt, does not qualify":
    var sim = twoTeamGame()
    sim.players[0].damageDealt = 4
    sim.players[0].grenadeDamageDealt = 1
    sim.finishGame(Red)
    check AchievementGrenadier notin sim.earned("red0")
    var sim2 = twoTeamGame()
    check sim2.players[0].damageDealt == 0
    sim2.finishGame(Red)
    check AchievementGrenadier notin sim2.earned("red0")

  test "absorbDamage attributes dealt and taken, and never self-dealt":
    var sim = twoTeamGame()
    sim.absorbDamage(1, 2, attackerIndex = 0, weapon = "grenade")
    check sim.players[0].damageDealt == 2
    check sim.players[0].grenadeDamageDealt == 2
    check sim.players[1].damageTaken == 2
    sim.absorbDamage(1, 1, attackerIndex = 0, weapon = "gun")
    check sim.players[0].damageDealt == 3
    check sim.players[0].grenadeDamageDealt == 2
    # Self-damage (a grenade at your own feet) is taken, never dealt.
    sim.players[0].hp = 10
    sim.absorbDamage(0, 2, attackerIndex = 0, weapon = "grenade")
    check sim.players[0].damageDealt == 3
    check sim.players[0].damageTaken == 2

  test "a gun shot, a grenade throw, and a spray firing each count an attack":
    var sim = twoTeamGame()
    const ClearX = 60
    let clearY = MapHeight div 2
    sim.players[0].placeAtCenter(ClearX, clearY)
    sim.players[0].aimBrads = 0
    check sim.players[0].attacksMade == 0
    # Gun: pull the trigger, then idle through the windup to the release.
    sim.armToFire(0)
    var trigger = sim.none()
    trigger[0].attack = true
    sim.step(trigger, sim.none())
    var previous = trigger
    for _ in 0 ..< sim.config.fireWindupTicks:
      sim.step(sim.none(), previous)
      previous = sim.none()
    check sim.players[0].shotsFired == 1
    check sim.players[0].attacksMade == 1
    # Grenade: charge and release.
    sim.players[0].hasGrenade = true
    sim.chargeAndThrow(0, 1)
    check sim.players[0].attacksMade == 2
    # Spray: ignite the spray paint cone.
    sim.players[0].hasSprayPaint = true
    sim.players[0].fireCooldown = 0
    sim.startArcFire(0)
    check sim.players[0].attacksMade == 3

  test "results.json carries per-slot achievement arrays":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.players[0].lives = 1
    sim.finishGame(Red)
    let results = parseJson(sim.playerResultsJson())
    check "achievements" in results
    check results["achievements"].len == results["scores"].len
    var slot0: seq[string]
    for id in results["achievements"][0]:
      slot0.add(id.getStr)
    check AchievementPacifist in slot0
    check AchievementSpotless in slot0
    check AchievementAlmost in slot0
    check results["achievements"][1].len == 0

  test "a maxGames episode reports the deduplicated union across games":
    var sim = twoTeamGame()
    sim.finishGame(Red)                     # game 1: pacifist + spotless
    sim.startGame()                         # counters reset for game 2
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.players[0].damageTaken = 1          # spotless lost this game
    sim.players[0].hp = 1                   # almost earned this game
    sim.players[0].lives = 1
    sim.finishGame(Red)
    let red = sim.earned("red0")
    check AchievementPacifist in red
    check AchievementSpotless in red        # kept from game 1
    check AchievementAlmost in red
    var pacifistCount = 0
    for id in red:
      if id == AchievementPacifist:
        inc pacifistCount
    check pacifistCount == 1                # deduplicated, not re-appended

  proc policyPairGame(): SimServer =
    ## Red seats two cogs of ONE policy ("pol0" and its hosted-runtime
    ## sibling "pol0_(2)"), Blue one cog of another.
    result = initCtfForTest(defaultGameConfig())
    discard result.addPlayer("pol0")
    discard result.addPlayer("pol0_(2)")
    discard result.addPlayer("pol1")
    result.startGame()
    result.players[0].team = Red
    result.players[1].team = Red
    result.players[2].team = Blue

  test "pacifist and spotless are judged for the whole team, not per cog":
    # One teammate fights and gets hit; the idle teammate does NOT earn the
    # badges on its own — the team attacked and took damage.
    var sim = policyPairGame()
    sim.players[1].attacksMade = 3
    sim.players[1].damageTaken = 2
    sim.finishGame(Red)
    check AchievementPacifist notin sim.earned("pol0")
    check AchievementPacifist notin sim.earned("pol0_(2)")
    check AchievementSpotless notin sim.earned("pol0")
    check AchievementSpotless notin sim.earned("pol0_(2)")
    # When nobody on the team attacks or gets hit, every seat on the team
    # records the badge (the platform dedupes per player).
    var sim2 = policyPairGame()
    sim2.finishGame(Red)
    check AchievementPacifist in sim2.earned("pol0")
    check AchievementPacifist in sim2.earned("pol0_(2)")
    check AchievementSpotless in sim2.earned("pol0")
    check AchievementSpotless in sim2.earned("pol0_(2)")

  test "grenadier sums damage across the team's cogs":
    # Cog A: 1 grenade damage only. Cog B: 5 gun damage. Per cog, A would be
    # a grenadier; per policy, 1 of 6 is not. Then 4 grenade + 1 gun = 80%.
    var sim = policyPairGame()
    sim.players[0].damageDealt = 1
    sim.players[0].grenadeDamageDealt = 1
    sim.players[1].damageDealt = 5
    sim.finishGame(Red)
    check AchievementGrenadier notin sim.earned("pol0")
    check AchievementGrenadier notin sim.earned("pol0_(2)")
    var sim2 = policyPairGame()
    sim2.players[0].damageDealt = 4
    sim2.players[0].grenadeDamageDealt = 4
    sim2.players[1].damageDealt = 1
    sim2.finishGame(Red)
    check AchievementGrenadier in sim2.earned("pol0")
    check AchievementGrenadier in sim2.earned("pol0_(2)")

  test "the losing team's cogs never enter the winner's aggregate":
    var sim = policyPairGame()
    sim.players[2].attacksMade = 9
    sim.players[2].damageTaken = 9
    sim.finishGame(Red)
    check AchievementPacifist in sim.earned("pol0")
    check AchievementSpotless in sim.earned("pol0")
    check sim.earned("pol1").len == 0

  test "rambo: nine kills in one life; a death resets the streak":
    var sim = policyPairGame()
    for _ in 0 ..< 8:
      sim.noteLifeKill(0)
    sim.finishGame(Red)
    check AchievementRambo notin sim.earned("pol0")
    var sim2 = policyPairGame()
    for _ in 0 ..< 9:
      sim2.noteLifeKill(1)                 # the sibling cog's streak counts
    sim2.finishGame(Red)
    check AchievementRambo in sim2.earned("pol0")
    check AchievementRambo in sim2.earned("pol0_(2)")
    var sim3 = policyPairGame()
    for _ in 0 ..< 5:
      sim3.noteLifeKill(0)
    sim3.players[0].hp = 10
    sim3.killPlayer(0, 2)                  # death: streak back to zero
    for _ in 0 ..< 5:
      sim3.noteLifeKill(0)
    sim3.finishGame(Red)
    check AchievementRambo notin sim3.earned("pol0")
    check sim3.players[0].bestKillsInLife == 5

  test "medic: four med kits in one life":
    var sim = policyPairGame()
    for _ in 0 ..< 4:
      sim.noteLifeHeal(0)
    sim.finishGame(Red)
    check AchievementMedic in sim.earned("pol0")
    var sim2 = policyPairGame()
    for _ in 0 ..< 3:
      sim2.noteLifeHeal(0)
    sim2.players[0].hp = 10
    sim2.killPlayer(0, 2)
    sim2.noteLifeHeal(0)
    sim2.finishGame(Red)
    check AchievementMedic notin sim2.earned("pol0")

  test "sniper: gun-only damage across the policy; banksy: 90% spray":
    var sim = policyPairGame()
    sim.absorbDamage(2, 2, attackerIndex = 0, weapon = "gun")
    sim.absorbDamage(2, 1, attackerIndex = 1, weapon = "gun")
    sim.finishGame(Red)
    check AchievementSniper in sim.earned("pol0")
    check AchievementBanksy notin sim.earned("pol0")
    var sim2 = policyPairGame()
    sim2.players[2].hp = 50
    sim2.absorbDamage(2, 9, attackerIndex = 0, weapon = "spray")
    sim2.absorbDamage(2, 1, attackerIndex = 1, weapon = "gun")   # one gun hit
    sim2.finishGame(Red)
    check AchievementSniper notin sim2.earned("pol0")
    check AchievementBanksy in sim2.earned("pol0")                # 9 of 10
    var sim3 = policyPairGame()
    sim3.players[2].hp = 50
    sim3.absorbDamage(2, 8, attackerIndex = 0, weapon = "spray")
    sim3.absorbDamage(2, 2, attackerIndex = 1, weapon = "gun")
    sim3.finishGame(Red)
    check AchievementBanksy notin sim3.earned("pol0")             # 8 of 10
    # No damage at all: neither badge.
    var sim4 = policyPairGame()
    sim4.finishGame(Red)
    check AchievementSniper notin sim4.earned("pol0")
    check AchievementBanksy notin sim4.earned("pol0")

  test "pit-master: 90% of damage dealt from inside a trench":
    # absorbDamage reads the attacker's trench live; stand-ins set the
    # counters the way the trench check would have.
    var sim = policyPairGame()
    sim.players[2].hp = 50
    sim.absorbDamage(2, 10, attackerIndex = 0, weapon = "gun")
    sim.players[0].pitDamageDealt = 9
    sim.finishGame(Red)
    check AchievementPitMaster in sim.earned("pol0")
    var sim2 = policyPairGame()
    sim2.players[2].hp = 50
    sim2.absorbDamage(2, 10, attackerIndex = 0, weapon = "gun")
    sim2.players[0].pitDamageDealt = 8
    sim2.finishGame(Red)
    check AchievementPitMaster notin sim2.earned("pol0")

  test "pack: every cog keeps two teammates within the pack radius":
    # Three Red cogs of one policy stacked on one tile; one Blue far away.
    var sim = initCtfForTest(defaultGameConfig())
    discard sim.addPlayer("pol0")
    discard sim.addPlayer("pol0_(2)")
    discard sim.addPlayer("pol0_(3)")
    discard sim.addPlayer("pol1")
    sim.startGame()
    for i in 0 ..< 3:
      sim.players[i].team = Red
      sim.players[i].x = 100 + i * 4
      sim.players[i].y = 100
      sim.players[i].alive = true
    sim.players[3].team = Blue
    sim.players[3].x = 1000
    sim.players[3].y = 500
    for _ in 0 ..< 10:
      sim.updatePackTicks()
    check sim.players[0].aliveTicks == 10
    check sim.players[0].packTicks == 10
    check sim.players[3].packTicks == 0
    sim.finishGame(Red)
    check AchievementPack in sim.earned("pol0")
    check AchievementPack in sim.earned("pol0_(3)")
    # One straggler (90% bar missed by a single cog) fails the whole team.
    var sim2 = initCtfForTest(defaultGameConfig())
    discard sim2.addPlayer("pol0")
    discard sim2.addPlayer("pol0_(2)")
    discard sim2.addPlayer("pol0_(3)")
    discard sim2.addPlayer("pol1")
    sim2.startGame()
    for i in 0 ..< 3:
      sim2.players[i].team = Red
      sim2.players[i].x = 100
      sim2.players[i].y = 100
    sim2.players[3].team = Blue
    for _ in 0 ..< 9:
      sim2.updatePackTicks()
    sim2.players[2].x = 1100                # wanders off for the last tick
    sim2.players[2].y = 600
    sim2.updatePackTicks()
    check sim2.players[2].packTicks == 9    # 9 of 10 = 90%: still in
    sim2.updatePackTicks()
    check sim2.players[2].packTicks == 9    # 9 of 11: out
    sim2.finishGame(Red)
    check AchievementPack notin sim2.earned("pol0")
    # A lone cog never has two teammates: no pack.
    var sim3 = twoTeamGame()
    sim3.updatePackTicks()
    sim3.finishGame(Red)
    check AchievementPack notin sim3.earned("red0")

  test "heist: a capture win with no kills by the team":
    var sim = policyPairGame()
    sim.lastCaptureTeam = Red
    sim.lastCaptureTick = sim.tickCount     # the capture ended the game
    sim.finishGame(Red)
    check AchievementHeist in sim.earned("pol0")
    check AchievementHeist notin sim.earned("pol1")
    var sim2 = policyPairGame()
    sim2.lastCaptureTeam = Red
    sim2.lastCaptureTick = sim2.tickCount
    sim2.recordKill(1)                      # a teammate killed someone
    sim2.finishGame(Red)
    check AchievementHeist notin sim2.earned("pol0")
    # A wipe win (no capture this tick) is not a heist.
    var sim3 = policyPairGame()
    sim3.finishGame(Red)
    check AchievementHeist notin sim3.earned("pol0")
    var sim4 = policyPairGame()
    sim4.lastCaptureTeam = Red
    sim4.lastCaptureTick = sim4.tickCount - 5
    sim4.finishGame(Red)
    check AchievementHeist notin sim4.earned("pol0")


  test "silent: no cog of the team shouted; one applied shout forfeits it":
    var sim = policyPairGame()
    sim.finishGame(Red)
    check AchievementSilent in sim.earned("pol0")
    var sim2 = policyPairGame()
    check sim2.applyShout(1, "go")          # the sibling cog speaks
    sim2.finishGame(Red)
    check AchievementSilent notin sim2.earned("pol0")
    check AchievementSilent notin sim2.earned("pol0_(2)")
    # A rejected shout (empty text) leaves the team silent.
    var sim3 = policyPairGame()
    check not sim3.applyShout(0, "   ")
    sim3.finishGame(Red)
    check AchievementSilent in sim3.earned("pol0")

  test "assassin: first-touch kill shots; spray, teammates, softened kills excluded":
    proc freshKill(sim: var SimServer, victim: int, weapon: string) =
      # Respawn the victim at 1 hp, untouched, and drop it with one hit.
      sim.players[victim].alive = true
      sim.players[victim].hp = 1
      sim.players[victim].hurtByMask = 0
      sim.absorbDamage(victim, 1, attackerIndex = 0, weapon = weapon)
      sim.killPlayer(victim, 0)
    var sim = policyPairGame()
    for _ in 0 ..< 9:
      sim.freshKill(2, "gun")
    check sim.players[0].assassinKills == 9
    sim.freshKill(2, "spray")               # spray never counts
    check sim.players[0].assassinKills == 9
    sim.finishGame(Red)
    check AchievementAssassin notin sim.earned("pol0")
    var simTen = policyPairGame()
    for _ in 0 ..< 9:
      simTen.freshKill(2, "gun")
    simTen.freshKill(2, "grenade")          # a grenade kill shot does
    check simTen.players[0].assassinKills == 10
    simTen.finishGame(Red)
    check AchievementAssassin in simTen.earned("pol0")
    check AchievementAssassin in simTen.earned("pol0_(2)")
    check AchievementAssassin notin simTen.earned("pol1")
    # A kill on a victim this cog already wounded in that life is not fresh;
    # a death wipes the mask so the NEXT life is fresh again.
    var sim2 = policyPairGame()
    sim2.players[2].hp = 2
    sim2.absorbDamage(2, 1, attackerIndex = 0, weapon = "gun")
    sim2.absorbDamage(2, 1, attackerIndex = 0, weapon = "gun")
    check sim2.players[0].assassinKills == 0
    sim2.killPlayer(2, 0)
    check sim2.players[2].hurtByMask == 0
    # A teammate's earlier hit does not spoil the assassin's first touch.
    sim2.players[2].alive = true
    sim2.players[2].hp = 2
    sim2.absorbDamage(2, 1, attackerIndex = 1, weapon = "gun")
    sim2.absorbDamage(2, 1, attackerIndex = 0, weapon = "gun")
    check sim2.players[0].assassinKills == 1
    # Killing a teammate is no assassination.
    var sim3 = policyPairGame()
    sim3.players[1].hp = 1
    sim3.absorbDamage(1, 1, attackerIndex = 0, weapon = "gun")
    check sim3.players[0].assassinKills == 0

  proc blast(sim: var SimServer, thrower, victim: int) =
    ## A real max-range throw from `thrower` that lands on `victim` (both
    ## stood on a clear row), stepped through to the detonation.
    sim.players[thrower].x = 460
    sim.players[thrower].y = sim.gameMap.center.y
    sim.players[thrower].aimBrads = 0
    sim.players[thrower].hasGrenade = true
    sim.players[thrower].fireCooldown = 0
    sim.players[victim].x = 460 + GrenadeMaxRange
    sim.players[victim].y = sim.gameMap.center.y
    sim.chargeAndThrow(thrower, GrenadeChargeTicks)
    check sim.airborneGrenades.len == 1
    let flight = sim.airborneGrenades[0].flightTicks
    let prev = sim.none()
    for _ in 0 .. flight:
      sim.step(sim.none(), prev)
    check sim.airborneGrenades.len == 0

  test "lucky: five grenade blasts survived in one game":
    var sim = policyPairGame()
    sim.players[0].hp = 100
    for _ in 0 ..< 5:
      sim.blast(2, 0)
    check sim.players[0].alive
    check sim.players[0].blastsSurvived == 5
    sim.finishGame(Red)
    check AchievementLucky in sim.earned("pol0")
    check AchievementLucky notin sim.earned("pol1")
    # The fatal fifth blast is not survived.
    var sim2 = policyPairGame()
    sim2.players[0].hp = 4 * GrenadeDamage + 1
    for _ in 0 ..< 4:
      sim2.blast(2, 0)
    check sim2.players[0].blastsSurvived == 4
    sim2.players[0].hp = GrenadeDamage
    sim2.blast(2, 0)
    check not sim2.players[0].alive
    check sim2.players[0].blastsSurvived == 4
    sim2.finishGame(Red)
    check AchievementLucky notin sim2.earned("pol0")

  test "assassin: a real grenade kill shot on an untouched cog counts once":
    var sim = policyPairGame()
    sim.players[2].hp = GrenadeDamage
    sim.blast(0, 2)
    check not sim.players[2].alive
    check sim.players[0].assassinKills == 1

  test "achievement focus names the receiving cog per badge":
    var sim = policyPairGame()
    for _ in 0 ..< 9:
      sim.noteLifeKill(1)                   # the sibling cog is the streaker
    sim.finishGame(Red)
    var ramboFocus = -1
    for focus in sim.achievementFocus:
      if focus.id == AchievementRambo:
        ramboFocus = focus.playerIndex
    check ramboFocus == 1
    # heist focuses the capturer, and a team-wide badge (pacifist) still
    # names SOME winning cog so the watch link has a face to select.
    var sim2 = policyPairGame()
    sim2.lastCaptureTeam = Red
    sim2.lastCaptureTick = sim2.tickCount
    sim2.lastCaptureIndex = 1
    sim2.finishGame(Red)
    var heistFocus, pacifistFocus = -1
    for focus in sim2.achievementFocus:
      if focus.id == AchievementHeist: heistFocus = focus.playerIndex
      if focus.id == AchievementPacifist: pacifistFocus = focus.playerIndex
    check heistFocus == 1
    check pacifistFocus in [0, 1]
