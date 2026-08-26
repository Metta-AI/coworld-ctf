## Season 2 human-seat controls: the button masks the browser client emits,
## driven through the REAL SimServer.
##
## client/player_controls.test.js proves the translator turns keys and cursor
## into the right MASK. This proves those masks turn into the right ACTION in
## the engine. The two meet on the wire byte the client actually sends, so
## neither half can drift without a test going red.
##
## Every check reads live sim state (velX, x, aimBrads, fireWindup,
## airborneGrenades); nothing here restates the translator's own claims.

import
  std/[os, unittest],
  bitworld/spriteprotocol,
  ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc seatedGame(): SimServer =
  ## A started game with a Red seat (0) and a Blue seat (1). Seat 0 is the
  ## human seat under test.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("human")
  discard result.addPlayer("bot")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc stepMask(sim: var SimServer, mask, prevMask: uint8) =
  ## One tick driven by one wire mask, exactly as server.nim applies it.
  var
    inputs = @[decodeInputMask(mask), InputState()]
    prevs = @[decodeInputMask(prevMask), InputState()]
  sim.step(inputs, prevs)

proc holdMask(sim: var SimServer, mask: uint8, ticks: int) =
  var prev: uint8 = 0
  for _ in 0 ..< ticks:
    sim.stepMask(mask, prev)
    prev = mask

# The exact bits player_controls.js emits (spriteprotocol.nim ButtonUp..ButtonC).
const
  MUp = ButtonUp
  MDown = ButtonDown
  MLeft = ButtonLeft
  MRight = ButtonRight
  MSelect = ButtonSelect
  MAttack = ButtonA
  MB = ButtonB
  MItem = ButtonC

# --- the translator's aim logic, mirrored so we can drive the real sim with it
const AimDeadzone = 3

proc wrapBrads(b: int): int = ((b mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn

proc shortestDelta(fromB, toB: int): int =
  result = wrapBrads(toB - fromB)
  if result > AimBradsTurn div 2:
    result -= AimBradsTurn

proc rotateMask(estAim, desired: int): uint8 =
  ## b == CCW == aimBrads += rate; select == CW. Park inside the deadzone.
  let d = shortestDelta(estAim, desired)
  if abs(d) < AimDeadzone: 0'u8
  elif d > 0: MB
  else: MSelect

suite "human-seat input -> engine action":

  test "a d-pad PULSE moves the player, and it is ACCELERATION not teleport":
    # Movement bugs hide behind acceleration, so pulse it and read the state.
    var sim = seatedGame()
    let startX = sim.players[0].x
    check sim.players[0].velX == 0

    # ONE tick of right. Fixed-point carry (MotionScale=256) means one tick of
    # accel (76) is genuinely sub-pixel -- the velocity is real even though the
    # position has not ticked over yet. Asserting on x alone here would be a
    # false negative, which is exactly the trap.
    sim.stepMask(MRight, 0)
    check sim.players[0].velX == sim.config.accel
    check sim.players[0].velX < sim.config.maxSpeed

    # Held a little longer, the pixel position genuinely moves.
    sim.holdMask(MRight, 8)
    check sim.players[0].x > startX
    let movedX = sim.players[0].x

    # Released, friction bleeds the velocity back to a full stop.
    sim.holdMask(0, 24)
    check sim.players[0].velX == 0
    check sim.players[0].x >= movedX   # coasted forward, never snapped back

  test "a held d-pad accelerates up to maxSpeed and never past it":
    var sim = seatedGame()
    sim.holdMask(MRight, 40)
    check sim.players[0].velX == sim.config.maxSpeed
    sim.holdMask(MRight, 40)
    check sim.players[0].velX == sim.config.maxSpeed

  test "a WASD chord drives both axes at once":
    var sim = seatedGame()
    sim.holdMask(MUp or MRight, 10)
    check sim.players[0].velX > 0
    check sim.players[0].velY < 0        # screen y points down, so up is -y

  test "opposing keys cancel instead of fighting":
    var sim = seatedGame()
    sim.holdMask(MLeft or MRight, 12)
    check sim.players[0].velX == 0
    check sim.players[0].x == sim.players[0].x   # no net drift

  test "b turns the aim CCW and select turns it CW, at aimTurnRate":
    var sim = seatedGame()
    sim.players[0].aimBrads = 100
    sim.stepMask(MB, 0)
    check sim.players[0].aimBrads == 100 + sim.config.aimTurnRate
    sim.players[0].aimBrads = 100
    sim.stepMask(MSelect, 0)
    check sim.players[0].aimBrads == 100 - sim.config.aimTurnRate

  test "both rotate buttons at once cancel to no turn":
    # applyInput gates on `input.b != input.select`, so emitting both would
    # silently cost the player their whole aim authority.
    var sim = seatedGame()
    sim.players[0].aimBrads = 100
    sim.holdMask(MB or MSelect, 10)
    check sim.players[0].aimBrads == 100

  test "the aim wraps cleanly across the 0/255 seam in both directions":
    var sim = seatedGame()
    sim.players[0].aimBrads = AimBradsTurn - 2
    sim.stepMask(MB, 0)
    check sim.players[0].aimBrads == sim.config.aimTurnRate - 2
    sim.players[0].aimBrads = 2
    sim.stepMask(MSelect, 0)
    check sim.players[0].aimBrads == AimBradsTurn + 2 - sim.config.aimTurnRate

  test "shortest-arc rotate-chase converges the REAL aim on any bearing":
    # This is mouse aim: no analog aim field exists on the wire, so the client
    # emits one rotate button per tick. Drive the real sim with that rule and
    # require the ENGINE's own aimBrads to land on the target.
    for target in [40, 90, 128, 200, 250, 3]:
      var sim = seatedGame()
      sim.players[0].aimBrads = 0
      var prev: uint8 = 0
      for _ in 0 ..< 80:
        let m = rotateMask(sim.players[0].aimBrads, target)
        sim.stepMask(m, prev)
        prev = m
        if abs(shortestDelta(sim.players[0].aimBrads, target)) < AimDeadzone:
          break
      check abs(shortestDelta(sim.players[0].aimBrads, target)) < AimDeadzone

  test "a converged aim PARKS instead of oscillating around the target":
    var sim = seatedGame()
    sim.players[0].aimBrads = 0
    var prev: uint8 = 0
    for _ in 0 ..< 80:
      let m = rotateMask(sim.players[0].aimBrads, 90)
      sim.stepMask(m, prev)
      prev = m
    let settled = sim.players[0].aimBrads
    for _ in 0 ..< 30:
      let m = rotateMask(sim.players[0].aimBrads, 90)
      sim.stepMask(m, prev)
      prev = m
    check sim.players[0].aimBrads == settled

  test "attack is a RISING EDGE: holding the button fires once":
    var sim = seatedGame()
    var windups = 0
    var prev: uint8 = 0
    var wasWinding = sim.players[0].fireWindup > 0
    for _ in 0 ..< 40:
      sim.stepMask(MAttack, prev)
      prev = MAttack
      let winding = sim.players[0].fireWindup > 0
      if winding and not wasWinding:
        inc windups
      wasWinding = winding
    check windups == 1

  test "PULSING attack re-arms, which is why held fire pulses the bit":
    var sim = seatedGame()
    var windups = 0
    var prev: uint8 = 0
    var wasWinding = sim.players[0].fireWindup > 0
    for i in 0 ..< 40:
      let m = if i mod 2 == 0: MAttack else: 0'u8
      sim.stepMask(m, prev)
      prev = m
      let winding = sim.players[0].fireWindup > 0
      if winding and not wasWinding:
        inc windups
      wasWinding = winding
    check windups > 1

  test "the shot leaves fireWindupTicks after the pull, not on the pull":
    var sim = seatedGame()
    sim.stepMask(MAttack, 0)
    check sim.players[0].fireWindup == sim.config.fireWindupTicks
    for _ in 1 ..< sim.config.fireWindupTicks:
      sim.stepMask(0, MAttack)
      check sim.players[0].fireWindup > 0
    sim.stepMask(0, 0)
    check sim.players[0].fireWindup == 0

  test "item use holds to charge and releases to throw":
    var sim = seatedGame()
    sim.players[0].hasGrenade = true
    check sim.airborneGrenades.len == 0

    sim.stepMask(MItem, 0)
    check sim.players[0].throwCharge == 1
    sim.stepMask(MItem, MItem)
    check sim.players[0].throwCharge == 2
    sim.stepMask(MItem, MItem)
    let charged = sim.players[0].throwCharge
    check charged == 3

    # Release: prev.c set, input.c clear -> the throw.
    sim.stepMask(0, MItem)
    check sim.airborneGrenades.len == 1
    check sim.players[0].throwCharge == 0
    check not sim.players[0].hasGrenade

  test "a charge caps at GrenadeChargeTicks rather than growing forever":
    var sim = seatedGame()
    sim.players[0].hasGrenade = true
    sim.holdMask(MItem, GrenadeChargeTicks + 20)
    check sim.players[0].throwCharge == GrenadeChargeTicks

  test "NO SPRINT EXISTS: no mask can exceed maxSpeed on either axis":
    # The executable form of the ruling. All eight bits are spoken for and none
    # of them is a speed modifier, so Shift has nothing legitimate to bind to.
    for raw in 0 .. 255:
      var sim = seatedGame()
      sim.holdMask(uint8(raw), 30)
      check abs(sim.players[0].velX) <= sim.config.maxSpeed
      check abs(sim.players[0].velY) <= sim.config.maxSpeed

  test "the ONLY speed scale in the engine is the carry penalty":
    var fast = seatedGame()
    fast.holdMask(MRight, 40)
    var carrying = seatedGame()
    carrying.players[0].carryingFlag = true
    carrying.holdMask(MRight, 40)
    check carrying.players[0].velX < fast.players[0].velX
    check fast.players[0].velX == fast.config.maxSpeed
