import
  std/[json, tables],
  flatty,
  bitworld/spriteprotocol,
  bitworld/replays as replayCodec,
  broadcast, sim, global

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    ## Player leaves shift overlay indices, so keyframes snapshot overlay state.
    overlaysBytes*: string
    masks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    debugSpriteIndex*: int
    hashIndex*: int
    overlays*: seq[DebugOverlay]
    masks*: seq[uint8]
    pressedMasks*: seq[uint8]
    lastAppliedMasks*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
      ## First tick the match is actually being PLAYED (the Lobby "WAITING FOR
      ## PLAYERS" span before this is dead air a spectator should never have to
      ## watch). Playback auto-starts here, loops back here, and the scrubber /
      ## tick clock are offset by it so the shown timeline is 0 = first action.
    livesSeries*: seq[seq[int]]
      ## [tick, livesPerTeam…] change-points across the WHOLE match (one lives
      ## count per team, in Team order), precomputed on the deterministic
      ## keyframe walk so the momentum graph can draw its full-timeline shape
      ## immediately (not accumulate as it plays). Only points where some
      ## team's lives CHANGE are stored (compact step series); the client holds
      ## each value to the next point and to maxTick.
    endHoldFrames*: int
      ## Real-time frames left to HOLD on the final game-over frame before a
      ## looping replay restarts, so the end segment (winner, win condition,
      ## stats) is readable instead of flashing for one frame. 0 = not holding.
    skipLulls*: bool
      ## When on, playback fast-forwards through the lull spans below. ON for
      ## every replay `initReplayPlayer` builds: a spectator's default watch
      ## should not sit through the quiet stretches. 'f' turns it off.
    lullSpans*: seq[array[2, int]]
      ## Inclusive [firstTick, lastTick] spans where nothing beat-worthy
      ## happens (no kill/steal/return/capture/phase change within
      ## LullLeadTicks), precomputed on the same keyframe walk. Spans shorter
      ## than MinLullTicks are dropped: skipping a short breather is more
      ## jarring than watching it.
    beatEvents*: JsonNode
      ## Full-match flag-story beats (steal/return/capture) plus the terminal
      ## gameover verdict, exactly as `stepEvents` emits them, precomputed on
      ## the same keyframe walk. Shipped once to the HUD client so the
      ## scrubber can place its flag markers and winner cap up front instead
      ## of accumulating them as playback happens to pass each beat.

const
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
    ## How long a looping replay holds on its final game-over frame (real
    ## seconds) before restarting.
  LullLeadTicks* = 2 * ReplayFps
    ## Context kept before and after every beat event.
  MinLullTicks* = 6 * ReplayFps
    ## Shortest quiet stretch worth fast-forwarding.
  LullSpeedBoost* = 8
    ## Speed multiplier applied inside a lull span.
  MaxLullTicksPerFrame* = 64
    ## Per-frame cap on boosted stepping so the server stays responsive.
  CtfReplayMagic = "COWLDCTF"
  CtfReplayFormatVersion = 1'u16
  CtfReplaySpec = ReplaySpec(
    magic: CtfReplayMagic,
    formatVersion: CtfReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

export replayCodec

proc tickTime*(tick: int): uint32 =
  ## Converts a simulation tick to replay milliseconds.
  replayCodec.tickTime(tick, ReplayFps)

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  ## Opens a replay file and writes the header.
  replayCodec.openReplayWriter(path, configJson, CtfReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  ## Parses one replay file buffer into memory.
  replayCodec.parseReplayBytes(bytes, CtfReplaySpec)

proc loadReplay*(path: string): ReplayData =
  ## Loads a replay file into memory.
  replayCodec.loadReplay(path, CtfReplaySpec)

proc serializeReplaySim*(sim: SimServer): string =
  ## Serializes one simulation state for replay keyframes.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string): SimServer =
  ## Deserializes one simulation state from a replay keyframe.
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  ## Builds replay playback state.
  result.data = data
  result.masks = @[]
  result.pressedMasks = @[]
  result.lastAppliedMasks = @[]
  result.overlays = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1

proc replaySpeed*(replay: ReplayPlayer): int =
  ## Returns the current integer replay speed.
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayMaxTick*(replay: ReplayPlayer): int =
  ## Returns the final tick available in the replay.
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  ## Returns the first tick a spectator should watch: the moment the match
  ## leaves the lobby (never negative, never past the end).
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  ## Resets replay playback cursors.
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.debugSpriteIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.masks = @[]
  replay.pressedMasks = @[]
  replay.lastAppliedMasks = @[]
  replay.overlays = @[]

proc saveReplayKeyframe(
  replay: ReplayPlayer,
  sim: SimServer
): ReplayKeyframe =
  ## Builds one replay keyframe from the current playback state.
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    debugSpriteIndex: replay.debugSpriteIndex,
    hashIndex: replay.hashIndex,
    overlaysBytes: replay.overlays.toFlatty(),
    masks: replay.masks,
    lastAppliedMasks: replay.lastAppliedMasks,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer,
  sim: var SimServer,
  keyframe: ReplayKeyframe
) =
  ## Restores playback state from one replay keyframe.
  let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
  sim = deserializeReplaySim(keyframe.simBytes)
  sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.debugSpriteIndex = keyframe.debugSpriteIndex
  replay.hashIndex = keyframe.hashIndex
  replay.overlays = keyframe.overlaysBytes.fromFlatty(seq[DebugOverlay])
  replay.masks = keyframe.masks
  replay.pressedMasks = newSeq[uint8](replay.masks.len)
  replay.lastAppliedMasks = keyframe.lastAppliedMasks
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  ## Returns the newest keyframe at or before one tick.
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureReplayPlayer(replay: var ReplayPlayer, player: int) =
  ## Expands replay input tables for one player.
  while replay.masks.len <= player:
    replay.masks.add(0)
    replay.pressedMasks.add(0)
    replay.lastAppliedMasks.add(0)
    replay.overlays.add(DebugOverlay())

proc clearReplayPressedMasks(replay: var ReplayPlayer) =
  ## Clears per-step replay press events.
  for mask in replay.pressedMasks.mitems:
    mask = 0

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins and inputs for the current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    if int(leave.player) < 0 or int(leave.player) >= sim.players.len:
      raise newException(ReplayError, "Replay player leave is invalid")
    sim.removePlayerAt(int(leave.player))
    if int(leave.player) < replay.masks.len:
      replay.masks.delete(int(leave.player))
    if int(leave.player) < replay.pressedMasks.len:
      replay.pressedMasks.delete(int(leave.player))
    if int(leave.player) < replay.lastAppliedMasks.len:
      replay.lastAppliedMasks.delete(int(leave.player))
    if int(leave.player) < replay.overlays.len:
      replay.overlays.delete(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    replay.ensureReplayPlayer(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureReplayPlayer(int(input.player))
    replay.pressedMasks[int(input.player)] =
      replay.pressedMasks[int(input.player)] or
        (input.keys and not replay.masks[int(input.player)])
    replay.masks[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    sim.applyShout(int(chat.player), chat.message)
    inc replay.chatIndex

  # Leaves are consumed first, so equal-time debug records use shifted indices.
  while replay.debugSpriteIndex < replay.data.debugSprites.len and
      replay.data.debugSprites[replay.debugSpriteIndex].time <= time:
    let debugSprite = replay.data.debugSprites[replay.debugSpriteIndex]
    replay.ensureReplayPlayer(int(debugSprite.player))
    # Crafted replay records are skipped so one malformed packet is non-fatal.
    try:
      replay.overlays[int(debugSprite.player)].applyDebugSpritePacket(
        debugSprite.packet
      )
    except SpriteProtocolError:
      discard
    inc replay.debugSpriteIndex

proc replayPrevInputs(
  replay: var ReplayPlayer,
  playerCount: int
): seq[InputState] =
  ## Builds previous replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    let mask =
      replay.lastAppliedMasks[playerIndex] and
        not replay.pressedMasks[playerIndex]
    result[playerIndex] = decodeInputMask(mask)

proc replayInputs(
  replay: var ReplayPlayer,
  playerCount: int
): seq[InputState] =
  ## Builds replay inputs for the current tick.
  result = newSeq[InputState](playerCount)
  for playerIndex in 0 ..< playerCount:
    replay.ensureReplayPlayer(playerIndex)
    let mask = replay.masks[playerIndex] or replay.pressedMasks[playerIndex]
    result[playerIndex] = decodeInputMask(mask)
    replay.lastAppliedMasks[playerIndex] = mask

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  ## Checks the recorded hash for the current tick.
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message =
      "Replay hash mismatch at tick " & $sim.tickCount &
        "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick.
  replay.clearReplayPressedMasks()
  replay.applyReplayEvents(sim)
  let prevInputs = replay.replayPrevInputs(sim.players.len)
  let inputs = replay.replayInputs(sim.players.len)
  sim.step(inputs, prevInputs)
  replay.clearReplayPressedMasks()
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int],
  startTick, maxTick: int
): seq[array[2, int]] =
  ## Turns the ascending beat-tick list into the quiet spans between beats,
  ## keeping LullLeadTicks of context on both sides and dropping spans shorter
  ## than MinLullTicks.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len:
        beatTicks[i]
      else:
        # The stretch after the final beat runs lead-free to the end: there is
        # no upcoming action that needs a lead-in.
        maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc buildReplayKeyframes*(
  replay: var ReplayPlayer,
  initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## Builds serialized replay seek keyframes.
  replay.keyframes = @[]
  var
    sim = initialSim
    builder = initReplayPlayer(replay.data)
  sim.gameEventLoggingEnabled = false
  builder.looping = false
  builder.mismatchQuit = replay.mismatchQuit
  replay.keyframes.add(builder.saveReplayKeyframe(sim))
  let maxTick = builder.replayMaxTick()
  # Record the per-team lives change-points across the full match so the
  # momentum graph draws its whole-timeline shape up front (deterministic
  # replay: a tick's lives are fixed). One count per team, in Team order, so
  # the series reads the same for any team count. Store only where some
  # team's lives change to keep it compact.
  replay.livesSeries = @[]
  proc teamLives(sim: SimServer): seq[int] =
    for team in sim.teams():
      result.add(sim.teamLivesRemaining(team))
  proc seriesPoint(tick: int, lives: seq[int]): seq[int] =
    result = @[tick]
    result.add(lives)
  var lastLives = teamLives(sim)
  replay.livesSeries.add(seriesPoint(sim.tickCount, lastLives))
  # Beat ticks for the lull map, derived by the SAME tracker the broadcast
  # channel uses, so "nothing happens here" agrees with the story the kill
  # feed and banners tell. Respawns are excluded: they trail kills on a fixed
  # timer and are not drama worth slowing down for.
  var
    beatTracker = initBroadcastTracker()
    beatTicks: seq[int]
  beatTracker.resync(sim)
  replay.beatEvents = newJArray()
  # -1 until the match leaves the lobby: the first tick the game is Playing is
  # where a spectator's watch should begin (everything before is warmup).
  replay.startTick = if sim.phase == Playing: sim.gameStartTick else: -1
  while builder.playing and sim.tickCount < maxTick:
    builder.stepReplay(sim)
    if replay.startTick < 0 and sim.phase == Playing:
      replay.startTick = sim.gameStartTick
    let lives = teamLives(sim)
    if lives != lastLives:
      replay.livesSeries.add(seriesPoint(sim.tickCount, lives))
      lastLives = lives
    var stepBeats = newJArray()
    sim.stepEvents(beatTracker, stepBeats)
    for event in stepBeats:
      # The flag story + verdict for the scrubber's up-front timeline. Kills
      # stay out: dozens of same-looking ticks would bury the flag beats.
      if event["k"].getStr() in ["steal", "return", "capture", "gameover"]:
        replay.beatEvents.add(event)
    for event in stepBeats:
      if event["k"].getStr() != "respawn":
        beatTicks.add(sim.tickCount)
        break
    if sim.tickCount mod max(interval, 1) == 0 or sim.tickCount == maxTick:
      replay.keyframes.add(builder.saveReplayKeyframe(sim))
  # Anchor the final tick so the client can hold the last value to the end.
  if replay.livesSeries.len == 0 or
      replay.livesSeries[^1][0] != sim.tickCount:
    replay.livesSeries.add(seriesPoint(sim.tickCount, lastLives))
  replay.lullSpans = buildLullSpans(
    beatTicks,
    replay.replayStartTick(),
    maxTick
  )

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  ## Returns true when one tick sits inside a precomputed lull span.
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## Returns how many ticks playback may advance this frame from one tick:
  ## the chosen speed, boosted inside a lull while skip-lulls is on.
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Seeks replay playback to a target tick.
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim,
      replay.keyframes[replay.replayKeyframeIndex(tick)]
    )
  else:
    let gameEventLoggingEnabled = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = gameEventLoggingEnabled
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc applyReplaySeek*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tick: int
) =
  ## Seeks replay playback and pauses on the target tick.
  replay.playing = false
  replay.seekReplay(sim, clamp(tick, replay.replayStartTick(), replay.replayMaxTick()))

proc applyReplayCommand*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  command: char
) =
  ## Applies one global viewer replay command.
  case command
  of ' ':
    replay.playing = not replay.playing
  of 'p':
    replay.playing = true
  of 'P':
    replay.playing = false
  of '+', '=':
    replay.speedIndex = min(replay.speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    replay.speedIndex = max(replay.speedIndex - 1, 0)
  of '1':
    replay.speedIndex = 0
  of '2':
    replay.speedIndex = 1
  of '3':
    replay.speedIndex = 2
  of '4':
    replay.speedIndex = 3
  of '8':
    replay.speedIndex = 4
  of '6':
    replay.speedIndex = 5
  of ',', '<':
    replay.playing = false
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.seekReplay(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.seekReplay(sim, replay.replayMaxTick())
  of 'r':
    replay.looping = not replay.looping
  of 'f':
    replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.seekReplay(sim, sim.tickCount + ReplayFps * 5)
  else:
    discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  ## Cancels the end-of-replay hold. Callers cancel after any manual
  ## seek/jump — a scrub off the final frame leaves the end segment.
  replay.endHoldFrames = 0

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  ## Whole seconds left in the end-of-replay hold (0 when not holding), for
  ## the broadcast chrome's "replaying in N" countdown.
  if replay.endHoldFrames <= 0:
    0
  else:
    (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## Advances one real-time playback frame (call once per TargetFps frame,
  ## after replay seeks/commands have been applied). Steps the sim
  ## `replaySpeed` ticks while playing; `onStep` runs after every sim tick
  ## (beat-event derivation), `onJump` after any playback jump (tracker
  ## resync). Shared by the native replay server and the static WASM viewer
  ## so both tell the same story at the end of a match: a LOOPING replay does
  ## NOT restart the moment playback stops — the final game-over frame (the
  ## end segment: winner, win condition, stats) holds for
  ## ReplayEndHoldSeconds of real time first. A play command during the hold
  ## skips the wait and loops immediately.
  if replay.playing and replay.endHoldFrames > 0:
    # Play pressed during the end hold: skip the wait and loop now.
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    # The step budget is re-read every tick: inside a lull it is boosted, and
    # the moment stepping crosses back into action it drops to the plain
    # speed, so a fast-forward never overshoots a beat's lead-in.
    var stepsTaken = 0
    while replay.playing and
        stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      # Playback just reached the end: begin the end-segment hold.
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## Applies one live playback speed command.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, 0)
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '3':
    speedIndex = 2
  of '4':
    speedIndex = 3
  of '8':
    speedIndex = 4
  of '6':
    speedIndex = 5
  else:
    discard

proc playbackSpeed*(speedIndex: int): int =
  ## Returns the live playback speed for an index.
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
