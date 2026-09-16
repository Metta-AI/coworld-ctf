## Aim assist (`allowAimAssist`): at the fire-press edge, a direct-aimed human
## seat's turret snaps onto the nearest live enemy's `fireWindupTicks`
## intercept bearing, PROVIDED that bearing is already within
## `aimAssistConeBrads` of the seat's own current aim. See applyAimAssist
## (sim.nim) for the mechanism; this suite is the config-gate contract
## (doctrine #1), the byte-identical-when-off and hash-clean-replay contracts
## (doctrine #2/#3), and the scripted moving-target discrimination test
## (doctrine #5).
import
  helpers,
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[replays, sim]

suite "aim assist: the gate is a real config field":
  test "off unless the config turns it on":
    check not defaultGameConfig().allowAimAssist
    check defaultGameConfig().aimAssistConeBrads == AimAssistConeBrads

  test "requires direct aim, or the config refuses":
    # The only already-recorded, replay-safe signal for "a human is driving
    # this seat" is a direct-aim write landing this tick (Player.
    # directAimActive) — without allowDirectAim that signal never fires, so
    # the knob would look armed and never assist a single shot. Refused
    # outright, same shape as test_direct_aim's league-config refusals.
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"allowAimAssist": true}""")
    # ...but paired with direct aim, it is accepted.
    config = defaultGameConfig()
    config.update("""{"allowDirectAim": true, "allowAimAssist": true}""")
    check config.allowAimAssist

  test "the cone width is bounded to a half turn":
    var config = defaultGameConfig()
    config.allowDirectAim = true
    expect CtfError:
      config.update("""{"allowDirectAim": true, "aimAssistConeBrads": -1}""")
    expect CtfError:
      config.update(
        """{"allowDirectAim": true, "aimAssistConeBrads": """ &
        $(AimBradsTurn div 2 + 1) & "}")

  test "a league config's replay JSON does not gain a byte":
    # Same rule the puddle, barrier, seat-takeover and direct-aim knobs
    # follow: the key is echoed ONLY when the mode is on, so a league game's
    # recorded config does not gain a byte because this feature exists.
    var config = defaultGameConfig()
    check not parseJson(config.configJson()).hasKey("allowAimAssist")
    check not parseJson(config.configJson()).hasKey("aimAssistConeBrads")
    config.allowDirectAim = true
    config.allowAimAssist = true
    config.aimAssistConeBrads = 20
    let node = parseJson(config.configJson())
    check node.hasKey("allowAimAssist")
    check node["allowAimAssist"].getBool()
    check node["aimAssistConeBrads"].getInt() == 20

  test "the mode and cone width survive a config round trip":
    var config = defaultGameConfig()
    config.allowDirectAim = true
    config.allowAimAssist = true
    config.aimAssistConeBrads = 30
    var reread = defaultGameConfig()
    reread.update(config.configJson())
    check reread.allowAimAssist
    check reread.aimAssistConeBrads == 30

proc assistConfig(assistOn: bool, cone = AimAssistConeBrads,
    windupTicks = FireWindupTicks): GameConfig =
  result = defaultGameConfig()
  result.allowDirectAim = true
  result.allowAimAssist = assistOn
  result.aimAssistConeBrads = cone
  result.fireWindupTicks = windupTicks
  # A 2-player scripted scene: the lobby would otherwise wait for the
  # default 16-player roster (or, for the tests that DO call startGame()
  # by hand, this is simply unused).
  result.minPlayers = 2
  result.startWaitTicks = 0

proc twoCogGame(assistOn: bool, cone = AimAssistConeBrads,
    windupTicks = FireWindupTicks): SimServer =
  ## A started Red-vs-Blue game, shooter cog 0 (Red), target cog 1 (Blue).
  result = initCtfForTest(assistConfig(assistOn, cone, windupTicks))
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

suite "aim assist: the cone gate on a stationary target":
  test "within the cone, the press snaps onto the target's own bearing":
    var sim = twoCogGame(assistOn = true)
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 590, 496)     # bearing from the shooter, exact and small
    let targetBrads = bradsOfVector(90, -4)
    check targetBrads > 0
    check targetBrads <= AimAssistConeBrads   # scenario sanity: inside the cone
    sim.applyDirectAim(0, 0)         # cursor points due east, near but not on
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState()]
    let prev = @[InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == targetBrads
    check sim.players[0].aimBrads == targetBrads

  test "outside the cone, the press changes nothing":
    var sim = twoCogGame(assistOn = true)
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 500, 400)      # due north: 64 brads away from due east
    sim.applyDirectAim(0, 0)
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState()]
    let prev = @[InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == 0
    check sim.players[0].aimBrads == 0

  test "a teammate in the cone is never a candidate":
    var sim = twoCogGame(assistOn = true)
    sim.players[1].team = Red        # now a teammate, not a target
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 590, 496)       # would have been well inside the cone
    sim.applyDirectAim(0, 0)
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState()]
    let prev = @[InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == 0

  test "a dead enemy in the cone is never a candidate":
    var sim = twoCogGame(assistOn = true)
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 590, 496)
    sim.players[1].alive = false
    sim.applyDirectAim(0, 0)
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState()]
    let prev = @[InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == 0

  test "the nearer-bearing candidate wins over a farther one, both in cone":
    var sim = twoCogGame(assistOn = true)
    discard sim.addPlayer("blue1")
    sim.players[2].team = Blue
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 590, 496)       # bearing 2 off due east — the nearer one
    sim.placeStill(2, 590, 480)       # bearing 9 off due east — also in cone
    check bradsOfVector(90, -4) < bradsOfVector(90, -20)
    check bradsOfVector(90, -20) <= AimAssistConeBrads   # scenario sanity
    sim.applyDirectAim(0, 0)
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState(), InputState()]
    let prev = @[InputState(), InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == bradsOfVector(90, -4)

  test "gate OFF is byte-identical to a pre-assist build: the cursor bearing locks unchanged":
    var sim = twoCogGame(assistOn = false)
    sim.placeStill(0, 500, 500)
    sim.placeStill(1, 590, 496)       # same "well inside the cone" scenario
    sim.applyDirectAim(0, 0)
    sim.armToFire(0)
    let inputs = @[InputState(attack: true), InputState()]
    let prev = @[InputState(), InputState()]
    sim.step(inputs, prev)
    check sim.players[0].windupBrads == 0
    check sim.players[0].aimBrads == 0

proc clearOpenZone(sim: var SimServer, x0, y0, x1, y1: int) =
  ## blockAll/openField (helpers.nim) only clear walkMask (movement); a real
  ## fired shot also reads wallMask for line of sight (paintPathClear), so a
  ## fully synthetic scene has to clear both to be independent of whatever
  ## the default arena map happens to paint at these coordinates.
  sim.blockAll()
  sim.openField(x0, y0, x1, y1)
  for y in y0 .. y1:
    for x in x0 .. x1:
      sim.wallMask[mapIndex(x, y)] = false

const
  RampTicks = 20            ## >> ceil(MaxSpeed/Accel): the strafer is at a
                             ## constant top speed well before the press.
  WindupTicks = 30           ## exaggerated on purpose: gives the strafer's
                             ## real, engine-driven motion (not a teleport)
                             ## room to separate a clean hit from a clean
                             ## miss well past the aim-jitter/hit-corridor
                             ## noise floor.
  ShooterX = 300
  ShooterY = 400
  StrafeStartX = 1000        ## far east of the shooter: a long range means a
                             ## real, comfortably-hit-corridor-clearing pixel
                             ## displacement still stays a SMALL bearing swing
                             ## (angle ~= displacement/range) — the cone the
                             ## human is aiming inside stays a cone.
  StrafeStartY = 460

proc buildStrafeScene(assistOn: bool): SimServer =
  result = twoCogGame(assistOn, windupTicks = WindupTicks)
  result.clearOpenZone(200, 250, 1060, 620)
  result.placeStill(0, ShooterX, ShooterY)
  result.placeStill(1, StrafeStartX, StrafeStartY)

type StrafeRun = object
  bearingNow, bearingFuture, delta: int
  windupBradsAtPress: int
  enemyHpBefore, enemyHpAfter: int

proc runStrafeScenario(assistOn: bool): StrafeRun =
  ## Cog 1 (Blue) strafes north (perpendicular to the shooter's line of
  ## sight, at long range) at a real, engine-accelerated top speed while
  ## cog 0 (Red) tracks its CURRENT (not future) position with the cursor —
  ## exactly what a human who cannot compute the windup lead does — then
  ## pulls the trigger once. `assistOn` is the only thing that ever differs
  ## between two calls with the same script.
  var sim = buildStrafeScene(assistOn)
  var prev = sim.none()
  for _ in 0 ..< RampTicks:
    let cur = @[InputState(), InputState(up: true)]
    sim.step(cur, prev)
    prev = cur
  # The strafer is now at a steady top speed (held "up" clamps velY to
  # -config.maxSpeedFor and keeps it there) — read the exact state `step`
  # is about to hand `applyAimAssist` for the press tick.
  let
    sx = sim.players[0].x
    sy = sim.players[0].y
    ex = sim.players[1].x
    ey = sim.players[1].y
    vx = sim.players[1].velX
    vy = sim.players[1].velY
  check vy == -sim.config.maxSpeedFor(Blue, sim.players[1].perks)
  result.bearingNow = bradsOfVector(ex - sx, ey - sy)
  let
    predictedX = ex + (vx * WindupTicks) div MotionScale
    predictedY = ey + (vy * WindupTicks) div MotionScale
  result.bearingFuture = bradsOfVector(predictedX - sx, predictedY - sy)
  result.delta = abs(shortestAimBradsDelta(result.bearingNow, result.bearingFuture))
  # A human tracking the cog they can actually SEE aims at its current spot.
  sim.applyDirectAim(0, result.bearingNow)
  let pressCur = @[InputState(attack: true), InputState(up: true)]
  sim.step(pressCur, prev)
  prev = pressCur
  result.windupBradsAtPress = sim.players[0].windupBrads
  result.enemyHpBefore = sim.players[1].hp
  for _ in 0 ..< WindupTicks + 4:
    let cur = @[InputState(), InputState(up: true)]
    sim.step(cur, prev)
    prev = cur
  result.enemyHpAfter = sim.players[1].hp

suite "aim assist: a moving target — the gate must discriminate":
  test "scenario sanity: the windup lead is real, and inside the default cone":
    let onArm = runStrafeScenario(assistOn = true)
    check onArm.delta > 0
    check onArm.delta <= AimAssistConeBrads
    check onArm.bearingNow != onArm.bearingFuture

  test "assist ON: cursor near the target, trigger pulled once -> a hit":
    let onArm = runStrafeScenario(assistOn = true)
    check onArm.windupBradsAtPress == onArm.bearingFuture
    check onArm.enemyHpAfter < onArm.enemyHpBefore

  test "assist OFF: the IDENTICAL scripted scenario -> a miss":
    # Nothing here differs from the ON arm above but the config gate: same
    # positions, same strafe, same cursor bearing, same single trigger pull.
    let offArm = runStrafeScenario(assistOn = false)
    check offArm.windupBradsAtPress == offArm.bearingNow
    check offArm.enemyHpAfter == offArm.enemyHpBefore

proc wipeAllTerrain(sim: var SimServer) =
  ## No walls anywhere, over the WHOLE map. Unlike `clearOpenZone`, this is
  ## safe for the replay round trip below: it depends on nothing but the map
  ## dimensions, so applying it, unconditionally, right after construction,
  ## on BOTH the live sim and the independently-constructed replay-side sim,
  ## keeps them identical without needing anything replay-recordable.
  sim.blockAll()
  sim.openField(0, 0, MapWidth - 1, MapHeight - 1)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      sim.wallMask[mapIndex(x, y)] = false

suite "aim assist: replay round trip (determinism)":
  test "a recorded episode with the assist firing hash-verifies clean end to end":
    # Real end-to-end record/playback (openReplayWriter -> parseReplayBytes ->
    # ReplayPlayer.stepReplay), the same shape test_pb_replay.nim's hash-chain
    # test uses: this is the proof the assist needs NO new replay record type
    # -- it re-derives identically from the direct-aim stream already on disk.
    #
    # Two rules borrowed from test_pb_replay.nim's own comment, both load-
    # bearing here: never call sim.startGame() by hand (the first sim.step
    # runs stepLobby, which starts the game once the roster is full — calling
    # it early shifts gameStartTick and the hash chain diverges at tick 1),
    # and never mutate sim state that replay has no record of. placeStill and
    # wipeAllTerrain are therefore applied, at the identical tick, to BOTH the
    # live sim below AND the independent replay-side sim further down.
    let path = getTempDir() / "aim-assist-replay-test.bitreplay"
    var config = assistConfig(assistOn = true, windupTicks = WindupTicks)
    var sim = initCtfForTest(config)
    sim.wipeAllTerrain()
    var writer = openReplayWriter(path, config.configJson())
    defer: writer.closeReplayWriter()
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    for i in 0 ..< sim.players.len:
      writer.writeJoin(tickTime(sim.tickCount), i, sim.players[i].address, i, "")
      writer.lastMasks.add(0)

    var
      prev = sim.none()
      lastDirectAim: seq[int] = @[]
      hashesWritten = 0
      shooterAim = -1   # -1 = no cursor yet; matches the "not human-aimed"
                        # sentinel `directAim` (replays.nim) already uses.

    proc recordedStep(shooterIn, enemyIn: InputState) =
      # Mirrors the live server's own tick order exactly (server.nim, "direct
      # aim: point the turret, THEN run the tick"): re-derived and re-recorded
      # EVERY tick a cursor is engaged, not merely once at the press — a real
      # human's mouse keeps asserting a bearing every frame, and playback
      # (stepReplay) re-applies its HELD last-recorded value every tick the
      # same way, so recording it only once would desync aimBrads (in
      # gameHash) the very next tick.
      if shooterAim >= 0:
        sim.applyDirectAim(0, shooterAim)
      writer.writeDirectAimChange(
        lastDirectAim, tickTime(sim.tickCount), 0, shooterAim)
      let cur = @[shooterIn, enemyIn]
      writer.writeInputMaskChange(tickTime(sim.tickCount), 0, cur[0].encodeInputMask())
      writer.writeInputMaskChange(tickTime(sim.tickCount), 1, cur[1].encodeInputMask())
      sim.step(cur, prev)
      prev = cur
      writer.writeHash(uint32(sim.tickCount), sim.gameHash())
      inc hashesWritten

    # Tick 1: phase is still Lobby going in: minPlayers (2) is already met and
    # startWaitTicks is 0, so stepLobby starts the game THIS tick (arranging
    # home positions) and returns before any input is applied — matching
    # what a real server does on an instant-start config.
    recordedStep(InputState(), InputState())
    check sim.phase == Playing
    sim.placeStill(0, ShooterX, ShooterY)
    sim.placeStill(1, StrafeStartX, StrafeStartY)

    for _ in 0 ..< RampTicks:
      recordedStep(InputState(), InputState(up: true))

    let
      sx = sim.players[0].x
      sy = sim.players[0].y
      ex = sim.players[1].x
      ey = sim.players[1].y
      vy = sim.players[1].velY
      bearingNow = bradsOfVector(ex - sx, ey - sy)
      predictedY = ey + (vy * WindupTicks) div MotionScale
      bearingFuture = bradsOfVector(ex - sx, predictedY - sy)
    check abs(shortestAimBradsDelta(bearingNow, bearingFuture)) <=
      config.aimAssistConeBrads

    shooterAim = bearingNow   # the cursor engages, and stays here — held,
                              # exactly like a human keeping the mouse still.
    recordedStep(InputState(attack: true), InputState(up: true))
    check sim.players[0].windupBrads == bearingFuture   # the assist fired

    for _ in 0 ..< WindupTicks + 4:
      recordedStep(InputState(), InputState(up: true))

    check hashesWritten > WindupTicks
    let liveEnemyHp = sim.players[1].hp
    check liveEnemyHp < config.maxHpFor(Blue, {})   # the assisted shot hit

    # --- now forget everything above except the bytes on disk -----------
    let data = parseReplayBytes(readFile(path))
    check data.hashes.len == hashesWritten
    var replayConfig = defaultGameConfig()
    replayConfig.update(data.configJson)
    var replaySim = initSimServer(replayConfig)
    replaySim.gameEventLoggingEnabled = false
    replaySim.wipeAllTerrain()
    var player = initReplayPlayer(data)
    player.mismatchQuit = true

    player.stepReplay(replaySim)             # tick 1: the same lobby start
    check not player.hashValidationFailed
    check replaySim.phase == Playing
    replaySim.placeStill(0, ShooterX, ShooterY)
    replaySim.placeStill(1, StrafeStartX, StrafeStartY)

    var steps = 1
    while replaySim.tickCount < player.replayMaxTick():
      player.stepReplay(replaySim)
      inc steps
    check not player.hashValidationFailed
    check steps == hashesWritten
    # The replay re-derived the SAME intercept from the SAME recorded
    # direct-aim + input streams -- proof the assist needs no new record.
    check replaySim.players[1].hp == liveEnemyHp
    check replaySim.players[1].hp < config.maxHpFor(Blue, {})
