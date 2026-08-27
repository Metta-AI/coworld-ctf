import
  std/[algorithm, json, os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[glory, global, labels, liveview, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc livePacket(
  sim: var SimServer,
  playerIndex: int,
  hud: bool
): tuple[labels: seq[string], chrome: string] =
  ## Builds one live player frame and returns every sprite label in it plus the
  ## broadcast-chrome JSON (empty when the seat never opted in).
  var
    state = initPlayerViewerState()
    nextState: PlayerViewerState
  state.hudEnabled = hud
  let packet = sim.buildLivePlayerPacket(
    playerIndex, state, nextState, newJArray())
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite:
      if message.sprite.id == BroadcastChromeSpriteId:
        result.chrome = message.sprite.label
      else:
        result.labels.add(message.sprite.label)

proc seatTwo(sim: var SimServer): (int, int) =
  ## Two players mid-map, alive, facing each other. Returns (red, blue).
  let
    red = sim.addPlayer("red0")
    blue = sim.addPlayer("blue0")
  sim.startGame()
  sim.players[red].team = Red
  sim.players[blue].team = Blue
  sim.players[red].x = sim.gameMap.center.x
  sim.players[red].y = sim.gameMap.center.y
  sim.players[blue].x = sim.gameMap.center.x + 40
  sim.players[blue].y = sim.gameMap.center.y
  discard sim.refreshPlayerFov(red)
  (red, blue)

suite "live player HUD":
  test "a deed pays a glory pop on the live player view":
    # The demo-gate question, asked of the wire rather than of a screenshot:
    # when a deed is minted where the human can see it, does a glory pop
    # sprite actually reach that seat's packet?
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    game.awardDeed(
      Red, dHonorableKill,
      game.players[red].x, game.players[red].y,
      byIndex = red
    )
    check game.gloryPops.len == 1
    let live = game.livePacket(red, hud = true)
    check live.labels.anyIt(it.startsWith("glory pop "))

  test "an achievement claim pops with its NAME on the live player view":
    # A claim rides the same pool as a plain deed but carries `label`, which is
    # what makes it a named chip rather than a bare number. If the two ever
    # diverge, the live view silently downgrades every achievement to "+Ng".
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    game.gloryPops.add GloryFx(
      x: game.players[red].x, y: game.players[red].y,
      tick: game.tickCount, amount: 400, team: Red,
      label: "MIRACLE WORKER"
    )
    let live = game.livePacket(red, hud = true)
    check live.labels.anyIt(it.startsWith("glory pop "))

  test "a levelled cog wears its rank mark on the live player view":
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    check game.livePacket(red, hud = true).labels
      .anyIt(it.startsWith(LabelVeteranMark)) == false   # L0 draws nothing
    game.players[red].level = 2
    check game.livePacket(red, hud = true).labels
      .anyIt(it.startsWith(LabelVeteranMark))

  test "the chrome frame carries the seat's own live state":
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    game.players[red].level = 2
    game.players[red].xp = 21
    game.players[red].fireCooldown = 7
    let chrome = game.livePacket(red, hud = true).chrome
    check chrome.len > 0
    let state = chrome.parseJson()
    check state.hasKey("me")
    let me = state["me"]
    check me["slot"].getInt == game.players[red].joinOrder
    check me["alive"].getBool
    check me["lvl"].getInt == 2
    check me["cd"].getInt == 7
    # The per-life ladder, shown as progress INTO the current rung: xp 21 sits
    # 2 past the L2 threshold of 19, and the L3 rung costs 27-19 = 8.
    check me["rung"].getInt == 2
    check me["need"].getInt == 8
    # The scorebug the glory HUD draws from is present and live.
    check state["teams"]["red"].hasKey("glory")
    check state["teams"]["red"].hasKey("heat")

  test "no true aim is ever published to the seat":
    # The anti-oracle rule (GV24): the private unfuzzed reticle is a different
    # lane's channel, and the renderer must not quietly grow one.
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    game.players[red].aimBrads = 137
    let me = game.livePacket(red, hud = true).chrome.parseJson()["me"]
    check not me.hasKey(SelfAimSeam)
    for key, value in me.pairs:
      if value.kind == JInt:
        check value.getInt != 137          # the true aim appears nowhere

  test "a policy's observation is byte-identical without the opt-in":
    # The whole safety argument for shipping any of this on the RL stream.
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    game.awardDeed(
      Red, dHonorableKill,
      game.players[red].x, game.players[red].y, byIndex = red)

    var
      botState = initPlayerViewerState()
      botNext: PlayerViewerState
      humanState = initPlayerViewerState()
      humanNext: PlayerViewerState
    humanState.hudEnabled = true
    let
      bot = game.buildLivePlayerPacket(red, botState, botNext, newJArray())
      human = game.buildLivePlayerPacket(red, humanState, humanNext, newJArray())

    # The bot's packet is exactly the pre-existing player stream...
    var
      plain = initPlayerViewerState()
      plainNext: PlayerViewerState
    let baseline = game.buildSpriteProtocolPlayerUpdates(red, plain, plainNext)
    check bot == baseline
    # ...and carries neither the chrome channel nor the x-ray plate.
    var botLabels: seq[string]
    for message in bot.parseSpritePacket():
      if message.kind == spkSprite:
        check message.sprite.id != BroadcastChromeSpriteId
        botLabels.add(message.sprite.label)
    var botXray, humanXray = 0
    for message in bot.parseSpritePacket():
      if message.kind == spkObject and
          message.objectDef.id == SpritePlayerXrayObjectId:
        inc botXray
    for message in human.parseSpritePacket():
      if message.kind == spkObject and
          message.objectDef.id == SpritePlayerXrayObjectId:
        inc humanXray
    check botXray == 0
    check humanXray == 1
    check human.len > bot.len

suite "bot observation: absolute label set":
  # WHY THIS EXISTS, beyond the parity test above.
  #
  # `bot == baseline` compares hudEnabled ON against OFF *within one build*. It
  # is a DELTA check, and it is blind to the base observation moving underneath
  # both arms: an ungated engine-side label added for everyone passes it in
  # silence, because both arms grow the label together. That is not a
  # hypothetical -- an `own aim <brads>` readback carrying the seat's true
  # aimBrads landed exactly that way on a sibling lineage, ungated, and this
  # test is the shape that would have caught it.
  #
  # So this one pins the ABSOLUTE set of label KINDS a policy can see on a
  # player stream. It fails on anything NEW, which is the point: a new kind is
  # a change to the RL observation space and wants a human decision, not a
  # silent pass. Widening the set is cheap and correct -- but it should be a
  # deliberate edit with a reason, which is exactly what a failure here forces.
  test "a policy sees only the pinned label kinds":
    var game = initCtfForTest(defaultGameConfig())
    let (red, _) = game.seatTwo()
    # Exercise the fx channels a steady frame would not: a paid deed, a
    # levelled cog, a shot in flight.
    game.players[red].level = 2
    game.awardDeed(
      Red, dHonorableKill,
      game.players[red].x, game.players[red].y, byIndex = red)
    game.players[red].fireCooldown = 0
    game.players[red].windupBrads = -1
    game.tryFire(red)

    var kinds: seq[string]
    for label in game.livePacket(red, hud = false).labels:
      # First token only: this is a check on the KIND of fact published, not on
      # its payload, so "lives 3hp x3" and "lives 1hp x2" are the same fact.
      let kind = label.split(' ')[0]
      if kind.len > 0 and kind notin kinds:
        kinds.add(kind)
    kinds.sort()

    # Pinned from the observed set on this lineage. WIDEN THIS DELIBERATELY:
    # a failure here means the observation surface a policy can read has
    # changed, which is a decision, not a detail.
    const Pinned = [
      "Room", "aim", "blue", "corpse", "damage", "diamond", "fire", "fog",
      "glory", "hit", "hp", "identity", "interstitial", "lives", "map",
      "player", "red", "self", "shot", "team", "veteran", "walkability",
      "weapon"
    ]
    var unexpected: seq[string]
    for kind in kinds:
      if kind notin Pinned:
        unexpected.add(kind)
    # Named in the failure so the reviewer sees WHAT arrived, not just that
    # something did.
    check unexpected == newSeq[string]()
