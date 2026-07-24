import
  std/[os, unittest],
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  ## A started game with one Red player (0) and one Blue player (1), the tier-2
  ## event sink on so Damage events (and their `blocked` field) are collected.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.collectEvents = true

proc pointBlank(sim: var SimServer, shooter, target: int) =
  ## Stands the target one body-width east of the shooter, both aimed so the
  ## shooter's shot locks onto the target, cooldown cleared for an instant fire.
  sim.players[shooter].x = 300
  sim.players[shooter].y = 300
  sim.players[shooter].aimBrads = 0            # east
  sim.players[shooter].fireCooldown = 0
  sim.players[target].x = 300 + 30
  sim.players[target].y = 300

proc lastDamage(sim: SimServer): SimEvent =
  ## The most recently emitted Damage event.
  for i in countdown(sim.events.high, 0):
    if sim.events[i].kind == Damage:
      return sim.events[i]
  raise newException(ValueError, "no Damage event emitted")

suite "blocked damage (shield-absorbed hp)":
  test "a hit on a full shield carrier reports blocked = 1":
    var sim = twoTeamGame()
    sim.pointBlank(0, 1)
    sim.players[1].hasShield = true
    sim.players[1].hp = ShieldHitPoints          # 6: full shield, 3 over base
    sim.tryFire(0)
    let dmg = sim.lastDamage()
    check dmg.kind == Damage
    check dmg.amount == 1
    check dmg.hp == ShieldHitPoints - 1          # 5
    # The whole 1-hp hit landed on shield-bonus hp (well above the base 3).
    check dmg.blocked == 1

  test "blocked stops once hp drops to the base ceiling":
    # Walk a 6-hp carrier down one hp per shot. Every hit taken while hp is
    # ABOVE base (6->5->4->3) is shield-soaked; the hit that lands at base and
    # below (3->2, 2->1) touches the cog and is NOT blocked.
    var sim = twoTeamGame()
    sim.pointBlank(0, 1)
    sim.players[1].hasShield = true
    sim.players[1].hp = ShieldHitPoints          # 6
    let base = sim.config.hitPoints              # 3
    var blockedTotal = 0
    for _ in 0 ..< 5:
      sim.players[0].fireCooldown = 0            # re-arm each shot
      let hpBefore = sim.players[1].hp
      if not sim.players[1].alive:
        break
      sim.tryFire(0)
      let dmg = sim.lastDamage()
      # Blocked iff the hit began above base hp.
      if hpBefore > base:
        check dmg.blocked == 1
      else:
        check dmg.blocked == 0
      blockedTotal += dmg.blocked
    # Exactly the 3 bonus hp (6 - 3) were ever shield-absorbed.
    check blockedTotal == ShieldHitPoints - base

  test "a hit on a shieldless cog blocks nothing":
    var sim = twoTeamGame()
    sim.pointBlank(0, 1)
    check not sim.players[1].hasShield
    check sim.players[1].hp == sim.config.hitPoints
    sim.tryFire(0)
    let dmg = sim.lastDamage()
    check dmg.amount == 1
    check dmg.blocked == 0

  test "blocked never enters the game hash":
    # The field rides the analysis-only event sink; it must not perturb the
    # replay-safe hash.
    var a = twoTeamGame()
    var b = twoTeamGame()
    a.pointBlank(0, 1)
    b.pointBlank(0, 1)
    a.players[1].hasShield = true
    b.players[1].hasShield = true
    a.players[1].hp = ShieldHitPoints
    b.players[1].hp = ShieldHitPoints
    a.tryFire(0)
    b.tryFire(0)
    check a.lastDamage().blocked == 1
    check a.gameHash == b.gameHash
