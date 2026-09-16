## Engine-side PRIVATE shooter/victim combat-outcome channel
## (GameConfig.allowShotFeedback, ShotFeedbackFx in sim_types.nim) — the
## SIM-side half. Asserted against the source contract, not this file's own
## prose: gate off must be provably byte-identical to a build without the
## field (gameHash untouched, `shotFeedback` never populated), gate on must
## still hash identically to gate off (the seq is excluded from gameHash
## entirely, so turning the feature on must not perturb it), and every
## populate site (applyFire/resolveActiveArcCones/explodeGrenade) must record
## exactly what the source computes: kill, friendlyFire, weapon, distance,
## shooterIndex, targetIndex, and (killcam) shooterX/shooterY — the
## shooter's center at the moment the damage resolved, captured on EVERY
## record here but serialized only into fatal hitsTaken wire entries
## (that half is test_shot_feedback_wire.nim's to assert).
##
## The server-side delivery half (buildShotFeedbackPacket's JSON, drained and
## routed to shooter/victim takeover sockets only) is asserted separately in
## test_shot_feedback_wire.nim.
##
## Also covers the BUG A fix: fovVisibleAt no longer fogs a player's own
## fatal-hit location from themselves (sim.nim's killPlayer adds the kill
## DamageFx pop at the victim's own x/y three lines before setting
## alive=false; fovVisibleAt used to return false unconditionally for any
## dead viewer, fogging that one pop from the one person it was for).

import
  helpers,
  std/unittest,
  ctf/sim

# The left capture column is protected floor (never walled), so arc-fire
# tests anchor the attacker there for guaranteed line of sight — same rig
# test_spraypaint.nim uses, including the template (not `let`) for the same
# "read MapHeight after this module's own game init installs the default
# arena" reason given there.
const ClearX = 60
template ClearY(): int = MapHeight div 2

proc feedbackGame(seats: int, allowShotFeedback: bool): SimServer =
  ## `seats` named players on a config whose allowShotFeedback gate is set
  ## explicitly, so a test can hold every other default fixed and vary only
  ## the one flag under test — same shape as test_callout_perception.nim's
  ## calloutGame.
  var config = defaultGameConfig()
  config.allowShotFeedback = allowShotFeedback
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("policy" & $i)
  result.startGame()

proc lineUpShot(sim: var SimServer, shooter, target: int, gap: int) =
  ## Shooter aims due east at a target `gap` px to the right — same
  ## point-blank rig test_shot_accuracy.nim uses, so tryFire always locks on.
  sim.players[shooter].team = Red
  sim.players[target].team = Blue
  sim.players[shooter].x = sim.gameMap.center.x
  sim.players[shooter].y = sim.gameMap.center.y
  sim.players[shooter].aimBrads = 0
  sim.armToFire(shooter)
  sim.players[target].x = sim.gameMap.center.x + gap
  sim.players[target].y = sim.gameMap.center.y

proc landGrenadeAt(sim: var SimServer, throwerIndex, tx, ty: int) =
  ## Bursts one grenade on an exact map point on the next step, bypassing aim
  ## and charge — same rig test_grenades.nim uses.
  sim.airborneGrenades.add AirborneGrenade(
    sx: tx, sy: ty, tx: tx, ty: ty,
    launchTick: sim.tickCount, flightTicks: 1,
    thrower: throwerIndex,
    throwerSlot: sim.players[throwerIndex].joinOrder,
    throwerAccount: -1
  )
  let prev = sim.none()
  sim.step(sim.none(), prev)

suite "shot feedback gate off: byte-identical to a build without it":
  test "the channel does not exist: a landed kill pushes nothing to shotFeedback":
    var game = feedbackGame(2, allowShotFeedback = false)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.players[1].hp = 1
    game.tryFire(0)
    check not game.players[1].alive
    check game.shotFeedback.len == 0

  test "gameHash is unaffected by a landed kill when the gate is off":
    var a = feedbackGame(2, allowShotFeedback = false)
    var b = feedbackGame(2, allowShotFeedback = false)
    a.lineUpShot(0, 1, 40)
    b.lineUpShot(0, 1, 40)
    a.players[1].hp = 1
    b.players[1].hp = 1
    check a.gameHash == b.gameHash
    a.tryFire(0)
    b.tryFire(0)
    check a.gameHash == b.gameHash

  test "gameHash is identical whether the gate is on or off, given the same kill":
    # The seq itself is excluded from gameHash entirely (sim_state.nim never
    # reads it) — so flipping the gate on must not perturb the hash even
    # though `shotFeedback` now actually fills up.
    var gateOff = feedbackGame(2, allowShotFeedback = false)
    var gateOn = feedbackGame(2, allowShotFeedback = true)
    gateOff.lineUpShot(0, 1, 40)
    gateOn.lineUpShot(0, 1, 40)
    gateOff.players[1].hp = 1
    gateOn.players[1].hp = 1
    check gateOff.gameHash == gateOn.gameHash
    gateOff.tryFire(0)
    gateOn.tryFire(0)
    check gateOn.shotFeedback.len == 1
    check gateOff.shotFeedback.len == 0
    check gateOff.gameHash == gateOn.gameHash

suite "shot feedback gate on: populated at the source, matching the event it describes":
  test "a gun kill on an enemy: kill, weapon, distance, indices all correct":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.players[1].hp = 1
    game.tryFire(0)
    check game.shotFeedback.len == 1
    let fx = game.shotFeedback[0]
    check fx.shooterIndex == 0
    check fx.targetIndex == 1
    check fx.kill == true
    check fx.friendlyFire == false
    check fx.weapon == "gun"
    check fx.distance == 40
    # Killcam: the shooter's center at release — exactly the sx/sy the shot's
    # ray was cast from (lineUpShot pinned the shooter at the map center).
    check fx.shooterX == game.gameMap.center.x + CollisionW div 2
    check fx.shooterY == game.gameMap.center.y + CollisionH div 2

  test "a non-fatal gun hit: kill is false (position still CAPTURED sim-side)":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.tryFire(0)
    check game.shotFeedback.len == 1
    check game.shotFeedback[0].kill == false
    # The capture is unconditional at the populate site; the fatal-only
    # narrowing is a SERIALIZATION rule (buildShotFeedbackPacket), so the
    # non-fatal record still carries the position it was born with.
    check game.shotFeedback[0].shooterX == game.gameMap.center.x + CollisionW div 2
    check game.shotFeedback[0].shooterY == game.gameMap.center.y + CollisionH div 2

  test "friendly fire is flagged when shooter and target share a team":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.players[1].team = Red     # same team as the shooter now
    game.tryFire(0)
    check game.shotFeedback.len == 1
    check game.shotFeedback[0].friendlyFire == true

  test "an arc (spray) kill populates weapon=spray with the right indices":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[0].hasSprayPaint = true
    game.players[0].aimBrads = 0
    game.players[0].placeAtCenter(ClearX, ClearY)
    let
      ax = game.players[0].x + CollisionW div 2
      ay = game.players[0].y + CollisionH div 2
    game.players[1].placeAtCenter(ax + SprayPaintReach - 2, ay)
    game.tryFireArc(0)
    check not game.players[1].alive
    check game.shotFeedback.len == 1
    let fx = game.shotFeedback[0]
    check fx.shooterIndex == 0
    check fx.targetIndex == 1
    check fx.kill == true
    check fx.friendlyFire == false
    check fx.weapon == "spray"
    # Killcam: the sprayer's center this cone tick — the same ax/ay this
    # test already computed to place the victim in reach.
    check fx.shooterX == ax
    check fx.shooterY == ay

  test "a grenade kill populates weapon=grenade with the right indices":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.players[0].team = Red
    game.players[1].team = Blue
    game.players[1].hp = 1
    game.players[1].placeAtCenter(game.gameMap.center.x, game.gameMap.center.y)
    game.landGrenadeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    check not game.players[1].alive
    check game.shotFeedback.len == 1
    let fx = game.shotFeedback[0]
    check fx.shooterIndex == 0
    check fx.targetIndex == 1
    check fx.kill == true
    check fx.weapon == "grenade"
    # Killcam: the THROWER's center at blast resolution (they never moved
    # this step — no inputs, zero velocity), not the blast point at map
    # center they lobbed it onto.
    check fx.shooterX == game.players[0].x + CollisionW div 2
    check fx.shooterY == game.players[0].y + CollisionH div 2

  test "a grenade never reports self-splash on its own thrower":
    var game = feedbackGame(2, allowShotFeedback = true)
    game.players[0].team = Red
    game.players[1].team = Blue
    # Thrower stands right on the blast center; only bystanders should ever
    # appear as a target (explodeGrenade's own `i != throwerIndex` guard).
    game.players[0].placeAtCenter(game.gameMap.center.x, game.gameMap.center.y)
    game.landGrenadeAt(0, game.gameMap.center.x, game.gameMap.center.y)
    for fx in game.shotFeedback:
      check fx.targetIndex != fx.shooterIndex

suite "BUG A: a player's own fatal hit is no longer fogged from them":
  test "fovVisibleAt reads true at a dead viewer's own last position":
    var game = feedbackGame(2, allowShotFeedback = false)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.players[1].hp = 1
    let (deathX, deathY) = (
      game.players[1].x + CollisionW div 2, game.players[1].y + CollisionH div 2
    )
    game.tryFire(0)
    check not game.players[1].alive
    # This is exactly the query addDamagePops makes for the victim's own kill
    # pop: viewerIndex == the now-dead player, point == their own death site.
    check game.fovVisibleAt(1, deathX, deathY)

  test "the bypass is narrowly scoped: a dead viewer still cannot see elsewhere on the map":
    var game = feedbackGame(2, allowShotFeedback = false)
    game.lineUpShot(shooter = 0, target = 1, gap = 40)
    game.players[1].hp = 1
    game.tryFire(0)
    check not game.players[1].alive
    # A point far from where this player died is not a "your own death"
    # query, and stays fogged like any other dead-viewer request.
    check not game.fovVisibleAt(1, game.players[1].x + 5000, game.players[1].y + 5000)

  test "gameHash is identical whether or not fovVisibleAt is ever called":
    # fovVisibleAt takes `sim: SimServer` (not `var`), so it cannot mutate
    # sim by construction; this is the runtime half of that proof.
    var a = feedbackGame(2, allowShotFeedback = false)
    var b = feedbackGame(2, allowShotFeedback = false)
    a.lineUpShot(0, 1, 40)
    b.lineUpShot(0, 1, 40)
    a.players[1].hp = 1
    b.players[1].hp = 1
    a.tryFire(0)
    b.tryFire(0)
    check a.gameHash == b.gameHash
    discard a.fovVisibleAt(1, a.players[1].x, a.players[1].y)
    discard a.fovVisibleAt(0, 0, 0)
    check a.gameHash == b.gameHash
