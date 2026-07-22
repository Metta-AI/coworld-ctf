import
  std/[math, os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const GameDir = currentSourcePath().parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc none(sim: SimServer): seq[InputState] =
  newSeq[InputState](sim.players.len)

proc placeAtCenter(player: var Player, x, y: int) =
  player.x = x - CollisionW div 2
  player.y = y - CollisionH div 2

proc stepNone(sim: var SimServer, ticks: int) =
  let input = sim.none()
  for _ in 0 ..< ticks:
    sim.step(input, input)

# The left capture column (x < 210) is protected floor — never walled — so
# arc-fire tests anchor the attacker there for guaranteed line of sight.
const
  ClearX = 60
  ClearY = MapHeight div 2

suite "plasma arcs":
  test "two plasma arcs spawn walkable in the top half of the side columns":
    let game = twoTeamGame()
    for i in 0 ..< game.plasmaArcSpawns.len:
      check game.plasmaArcSpawns[i].present
      check game.canOccupy(game.plasmaArcSpawns[i].x, game.plasmaArcSpawns[i].y)
      # Plasma arcs live in the TOP half (quarter height); the shields hold
      # the matching bottom-half spots.
      check abs(game.plasmaArcSpawns[i].y - MapHeight div 4) < 120
      check game.plasmaArcSpawns[i].y < MapHeight div 2
      if i == 0:
        check game.plasmaArcSpawns[i].x < MapWidth div 2
      else:
        check game.plasmaArcSpawns[i].x > MapWidth div 2

  test "pickup has a one-arc limit and respawns after 30 seconds":
    var game = twoTeamGame()
    let spawn = game.plasmaArcSpawns[0]
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupPlasmaArcs(0)
    check game.players[0].hasPlasmaArc
    check not game.plasmaArcSpawns[0].present
    game.players[1].placeAtCenter(game.plasmaArcSpawns[1].x, game.plasmaArcSpawns[1].y)
    game.tryPickupPlasmaArcs(1)
    check game.players[1].hasPlasmaArc
    game.players[0].placeAtCenter(spawn.x, spawn.y)
    game.tryPickupPlasmaArcs(0)
    check game.players[0].hasPlasmaArc
    game.players[0].placeAtCenter(400, 400)
    game.stepNone(PlasmaArcRespawnTicks)
    check game.plasmaArcSpawns[0].present

  test "a carried plasma arc is lost on death":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.killPlayer(0, 1)
    check not game.players[0].hasPlasmaArc

  test "a plasma arc carrier cannot fire the gun":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[1].placeAtCenter(game.players[0].x + 100, game.players[0].y)
    check not game.canFire(0)
    game.tryFire(0)
    check game.players[1].alive

  test "an arc kills a target in the forward cone and credits the attacker":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let ax = game.players[0].x + CollisionW div 2
    let ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.plasmaArcFlashes.len == 1

  test "an arc misses behind, outside the cone, and beyond reach":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax - 20, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    # Forward 90px: the cone's half-width there is only 22px.
    game.players[1].placeAtCenter(ax + 90, ay + 40)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + PlasmaArcReach + 10, ay)
    game.tryFireArc(0)
    check game.players[1].alive

  test "the cone spans 4 squares of reach and 2 squares of width at max":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    check PlasmaArcReach == 4 * PlasmaArcSquare
    check PlasmaArcMaxWidth == 2 * PlasmaArcSquare
    # Near max reach the half-width approaches PlasmaArcMaxWidth / 2
    # (32.5px at forward 130 of the 136px reach).
    game.players[1].placeAtCenter(ax + 130, ay + 30)
    game.tryFireArc(0)
    check not game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].respawnTimer = 0
    game.players[1].alive = true
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(ax + 130, ay + 36)
    game.tryFireArc(0)
    check game.players[1].alive
    # Near the muzzle the cone is proportionally narrow (7.5px at 30).
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + 30, ay + 12)
    game.tryFireArc(0)
    check game.players[1].alive
    game.players[0].fireCooldown = 0
    game.players[1].placeAtCenter(ax + 30, ay + 6)
    game.tryFireArc(0)
    check not game.players[1].alive

  test "friendly fire: the cone kills a teammate":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.players[1].team = game.players[0].team
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "same-tick arc fires can kill each other":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[1].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[1].aimBrads = 128
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + PlasmaArcReach - 2, ay)
    game.startArcFire(0)
    game.startArcFire(1)
    game.resolveActiveArcCones()
    check not game.players[0].alive
    check not game.players[1].alive
    check game.players[0].kills == 1
    check game.players[1].kills == 1

  test "a shield carrier survives one plasma touch, and only one per firing":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].hasShield = true
    game.players[1].shieldHp = ShieldLayerHp
    game.players[1].placeAtCenter(ax + 60, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    # The shield layer soaks the arc touch before base hp.
    check game.players[1].shieldHp == ShieldLayerHp - PlasmaArcDamage
    check game.players[1].hp == game.config.hitPoints
    check game.players[0].kills == 0
    # Staying inside the cone for the rest of the window adds no damage.
    for _ in 0 ..< PlasmaArcActiveTicks:
      game.resolveActiveArcCones()
    check game.players[1].shieldHp == ShieldLayerHp - PlasmaArcDamage
    # A second firing lands a second touch, which finishes the carrier.
    game.players[0].fireCooldown = 0
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.players[0].kills == 1

  test "the cone stays live for 5 ticks and catches late entrants":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax - 40, ay)
    game.tryFireArc(0)
    check game.players[1].alive
    check game.players[0].arcTicksLeft == PlasmaArcActiveTicks - 1
    # Walking into the still-live cone two ticks later is fatal.
    game.resolveActiveArcCones()
    game.players[1].placeAtCenter(ax + 60, ay)
    game.resolveActiveArcCones()
    check not game.players[1].alive
    # Exhaust the window: the cone shuts off and stops touching anyone.
    game.resolveActiveArcCones()
    game.resolveActiveArcCones()
    check game.players[0].arcTicksLeft == 0
    game.players[1].respawnTimer = 0
    game.players[1].alive = true
    game.players[1].hp = game.config.hitPoints
    game.players[1].placeAtCenter(ax + 60, ay)
    game.resolveActiveArcCones()
    check game.players[1].alive

  test "firing takes 20 ticks to reset after the 5-tick window":
    var game = twoTeamGame()
    game.players[0].hasPlasmaArc = true
    game.players[0].placeAtCenter(ClearX, ClearY)
    game.tryFireArc(0)
    check game.players[0].fireCooldown ==
      PlasmaArcActiveTicks + PlasmaArcResetTicks
    check not game.canFireArc(0)

  test "plasma arc state is in the game hash":
    var game = twoTeamGame()
    let initial = game.gameHash()
    game.players[0].hasPlasmaArc = true
    check game.gameHash() != initial
    let carried = game.gameHash()
    game.players[0].hasPlasmaArc = false
    game.plasmaArcSpawns[0].present = not game.plasmaArcSpawns[0].present
    check game.gameHash() != carried
    let toggled = game.gameHash()
    game.players[0].arcTicksLeft = 3
    check game.gameHash() != toggled
