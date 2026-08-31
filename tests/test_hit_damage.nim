## GV47: hp removed is credited to the attacker's reward account, split
## enemy/teammate. The split is the whole point — an earlier reward that paid
## for kills without splitting taught a policy to farm its own teammates — so
## every case here asserts BOTH counters, never just the one it moves.
import
  helpers,
  std/[json, unittest],
  ctf/sim

proc damageGame(): SimServer =
  ## Two Red (0, 1) and one Blue (2), so both a friendly and an enemy target
  ## are one shot away from player 0.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("red1")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Red
  result.players[2].team = Blue

proc credited(sim: var SimServer, playerIndex: int): tuple[enemy, team: int] =
  ## (hitDamage, teamHitDamage) on one player's reward account.
  let index = sim.rewardAccountForPlayer(playerIndex)
  doAssert index >= 0
  (sim.rewardAccounts[index].hitDamage,
    sim.rewardAccounts[index].teamHitDamage)

proc pointBlank(sim: var SimServer, shooter, target: int) =
  ## Stands the target one body-width east of the shooter, cooldown cleared.
  ## Everyone else is parked well south of the ray: a bullet stops at the
  ## FIRST body it meets, so a bystander left on the line silently steals the
  ## hit (and, with a mixed roster, the wrong counter).
  sim.players[shooter].x = 300
  sim.players[shooter].y = 300
  sim.players[shooter].aimBrads = 0            # east
  sim.players[shooter].fireCooldown = 0
  for i in 0 ..< sim.players.len:
    if i == shooter or i == target:
      continue
    sim.players[i].x = 300
    sim.players[i].y = 300 + 200
  sim.players[target].x = 300 + 30
  sim.players[target].y = 300

suite "hit damage credit":
  test "a gun hit on an enemy credits hitDamage only":
    var game = damageGame()
    game.pointBlank(0, 2)
    game.tryFire(0)
    check game.players[2].hp == game.config.hitPoints - 1
    check game.credited(0) == (enemy: 1, team: 0)

  test "a gun hit on a teammate credits teamHitDamage only":
    # The lesson this stat exists to encode: friendly fire must never reach
    # the counter the shaping pays for.
    var game = damageGame()
    game.pointBlank(0, 1)
    game.tryFire(0)
    check game.players[1].hp == game.config.hitPoints - 1
    check game.credited(0) == (enemy: 0, team: 1)

  test "the two counters accumulate independently":
    var game = damageGame()
    game.pointBlank(0, 2)
    game.tryFire(0)
    game.pointBlank(0, 1)
    game.tryFire(0)
    game.pointBlank(0, 2)
    game.tryFire(0)
    # Two enemy hits and one backstab: neither total cancels the other out.
    check game.credited(0) == (enemy: 2, team: 1)

  test "self-damage counts as neither":
    var game = damageGame()
    discard game.absorbDamage(0, 5, 0, "grenade")
    check game.players[0].hp == game.config.hitPoints - 5
    check game.credited(0) == (enemy: 0, team: 0)

  test "environmental damage credits nobody":
    # Puddles and barrage shells name no attacker.
    var game = damageGame()
    discard game.absorbDamage(2, 3, -1, "")
    check game.credited(0) == (enemy: 0, team: 0)
    check game.credited(1) == (enemy: 0, team: 0)
    check game.credited(2) == (enemy: 0, team: 0)

  test "a shield-soaked hit still credits the shooter":
    # hitDamage carries the hp the hit REMOVED, before the shield layer took
    # its share — the same figure the per-player damageDealt counters use.
    var game = damageGame()
    game.pointBlank(0, 2)
    game.players[2].hasShield = true
    game.players[2].shieldHp = ShieldLayerHp
    let baseBefore = game.players[2].hp
    game.tryFire(0)
    check game.players[2].hp == baseBefore       # the bubble ate it
    check game.credited(0) == (enemy: 1, team: 0)

  test "the results doc carries both counters per slot":
    var game = damageGame()
    game.pointBlank(0, 2)
    game.tryFire(0)
    game.pointBlank(0, 1)
    game.tryFire(0)
    let results = parseJson(game.playerResultsJson())
    check results["hitDamage"][0].getInt == 1
    check results["teamHitDamage"][0].getInt == 1
    check results["hitDamage"][1].getInt == 0
    check results["teamHitDamage"][1].getInt == 0
    check results["hitDamage"][2].getInt == 0
    check results["teamHitDamage"][2].getInt == 0
