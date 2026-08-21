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

  test "almost: the winning team's living cogs hold under 2 hp in total":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.finishGame(Red)
    check AchievementAlmost in sim.earned("red0")
    check AchievementAlmost notin sim.earned("blue0")

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
    sim.finishGame(Red)
    check AchievementAlmost notin sim.earned("red0")
    # A dead teammate contributes nothing: sole survivor on 1 hp earns it.
    var sim2 = initCtfForTest(defaultGameConfig())
    discard sim2.addPlayer("red0")
    discard sim2.addPlayer("red1")
    discard sim2.addPlayer("blue0")
    sim2.startGame()
    sim2.players[0].team = Red
    sim2.players[1].team = Red
    sim2.players[2].team = Blue
    sim2.players[0].hp = 1
    sim2.players[1].alive = false
    sim2.players[1].hp = 0
    sim2.finishGame(Red)
    check AchievementAlmost in sim2.earned("red0")
    check AchievementAlmost in sim2.earned("red1")  # team badge: whole team

  test "grenadier: at least half the damage dealt came from grenades":
    var sim = twoTeamGame()
    sim.players[0].damageDealt = 4
    sim.players[0].grenadeDamageDealt = 2
    sim.finishGame(Red)
    check AchievementGrenadier in sim.earned("red0")

  test "grenadier: under half, or zero damage dealt, does not qualify":
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
    # Spray: ignite the plasma cone.
    sim.players[0].hasPlasmaArc = true
    sim.players[0].fireCooldown = 0
    sim.startArcFire(0)
    check sim.players[0].attacksMade == 3

  test "results.json carries per-slot achievement arrays":
    var sim = twoTeamGame()
    sim.players[0].hp = 1
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
