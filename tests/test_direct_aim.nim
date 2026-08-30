import std/[unittest, json]

include ../src/ctf/server

import ../tests/helpers

proc leagueConfig(): GameConfig =
  ## What a league server runs: neither play capability armed.
  result = defaultGameConfig()
  result.slots = @[PlayerSlotConfig(token: "")]

proc playConfig(): GameConfig =
  ## What a freeplay server runs.
  result = leagueConfig()
  result.allowSeatTakeover = true
  result.allowDirectAim = true

suite "direct aim: the turret points where the cursor is":
  test "a cursor bearing is the map-space angle from the muzzle":
    # The player POV ships the map layer at scale 1, origin (0, 0), so the
    # packet's x,y ARE map pixels: the conversion is the sim's own inverse of
    # aimVector and nothing else. Screen y points down, so north is -y.
    var player = Player(x: 500, y: 400)
    check player.directAimBrads(900, 400) == 0                    # east
    check player.directAimBrads(500, 100) == AimBradsTurn div 4   # north
    check player.directAimBrads(100, 400) == AimBradsTurn div 2   # west
    check player.directAimBrads(500, 900) == AimBradsTurn * 3 div 4  # south

  test "the cursor sitting on the muzzle holds a bearing rather than spinning":
    var player = Player(x: 500, y: 400)
    check player.directAimBrads(500, 400) == 0

  test "a flick lands in ONE tick, where the traverse needs twenty-six":
    # The whole point of the channel. aimTurnRate is 5 brads/tick, so a
    # half-turn is 26 ticks of swinging; direct aim is one write.
    var sim = twoTeamGame()
    sim.players[0].alive = true
    sim.players[0].aimBrads = 0
    let target = AimBradsTurn div 2
    sim.applyDirectAim(0, target)
    check sim.players[0].aimBrads == target
    check (target + sim.config.aimTurnRate - 1) div sim.config.aimTurnRate == 26

  test "a bearing is normalised onto the turn, never left out of range":
    var sim = twoTeamGame()
    sim.players[0].alive = true
    sim.applyDirectAim(0, AimBradsTurn + 7)
    check sim.players[0].aimBrads == 7
    sim.applyDirectAim(0, -1)
    check sim.players[0].aimBrads == AimBradsTurn - 1

  test "a dead cog's turret is never written":
    # Aim resets to spawnAimBrads at every respawn and the client re-seeds its
    # dead reckoning on that edge. Writing aim through a death would desync it.
    var sim = twoTeamGame()
    sim.players[0].alive = false
    sim.players[0].aimBrads = 12
    sim.applyDirectAim(0, 200)
    check sim.players[0].aimBrads == 12
    sim.applyDirectAim(-1, 200)
    sim.applyDirectAim(sim.players.len, 200)

suite "direct aim: the gate discriminates":
  test "a league config advertises neither capability":
    let config = leagueConfig()
    check not config.allowSeatTakeover
    check not config.allowDirectAim
    check not defaultGameConfig().allowDirectAim

  test "a league server REFUSES a client that asks for direct aim":
    let config = leagueConfig()
    check config.takeoverRejection(0, "", true, false).len > 0
    check config.takeoverRejection(0, "", false, false).len > 0

  test "takeover without direct aim is still refused when only takeover is on":
    # Discrimination, not a blanket yes: the two arms are independent fields.
    var config = leagueConfig()
    config.allowSeatTakeover = true
    check config.takeoverRejection(0, "", false, false) == ""
    check config.takeoverRejection(0, "", true, false) ==
      "Direct aim is not enabled on this server."

  test "a play server admits exactly the request it advertises":
    let config = playConfig()
    check config.takeoverRejection(0, "", true, false) == ""
    check config.takeoverRejection(0, "", false, false) == ""
    # ...and still refuses everything the seat rules refuse.
    check config.takeoverRejection(9, "", true, false).len > 0
    check config.takeoverRejection(0, "", true, true).len > 0

  test "a wrong token is refused even with both capabilities armed":
    var config = playConfig()
    config.slots = @[PlayerSlotConfig(token: "secret")]
    check config.takeoverRejection(0, "nope", true, false).len > 0
    check config.takeoverRejection(0, "secret", true, false) == ""

  test "a MATCHING pinned token supersedes a stale takeover instead of queuing behind it":
    # The resume-vs-fresh-join bug: a browser reload's new /takeover upgrade
    # can win the race against this process's own once-per-tick cleanup of
    # the OLD (closing) socket, so `seatTaken` is still true when the reload
    # arrives. A pinned token that matches IS proof this connection holds the
    # seat's own secret -- the reload is admitted (server.nim's httpHandler
    # then calls evictSeatTakeover to drop the stale holder) rather than
    # bounced into the client's blind ~2s retry with a black arena meanwhile.
    var config = playConfig()
    config.slots = @[PlayerSlotConfig(token: "secret")]
    check config.takeoverRejection(0, "secret", false, true) == ""

  test "an UNTOKENED seat keeps the old exclusivity -- no secret to prove identity with":
    var config = playConfig()
    config.slots = @[PlayerSlotConfig(token: "")]
    check config.takeoverRejection(0, "", false, true).len > 0

  test "the advertised capabilities are read off the same config fields":
    initAppState()
    check capabilitiesJson().parseJson()["directAim"].getBool() == false
    check capabilitiesJson().parseJson()["seatTakeover"].getBool() == false
    appState.config = playConfig()
    check capabilitiesJson().parseJson()["directAim"].getBool()
    check capabilitiesJson().parseJson()["seatTakeover"].getBool()
    initAppState()

  test "all four armed gates are mirrored on /capabilities, not just two":
    # truth-lens audit #3: /capabilities used to report only seatTakeover and
    # directAim, silently omitting allowAimAssist/allowCallouts even when the
    # running config had them on. A league config (nothing armed) must still
    # refuse on all four; a freeplay config with every gate on must advertise
    # all four honestly, driven off the real config fields, not literals.
    initAppState()
    appState.config = leagueConfig()
    let refused = capabilitiesJson().parseJson()
    check refused["seatTakeover"].getBool() == false
    check refused["directAim"].getBool() == false
    check refused["allowAimAssist"].getBool() == false
    check refused["allowCallouts"].getBool() == false
    var armed = playConfig()
    armed.allowAimAssist = true
    armed.allowCallouts = true
    appState.config = armed
    let granted = capabilitiesJson().parseJson()
    check granted["seatTakeover"].getBool()
    check granted["directAim"].getBool()
    check granted["allowAimAssist"].getBool()
    check granted["allowCallouts"].getBool()
    initAppState()

suite "direct aim: a PLAY replay says so, and re-simulates":
  test "a league replay's config JSON does not gain a byte":
    var config = defaultGameConfig()
    check "allowDirectAim" notin config.configJson()
    config.allowDirectAim = true
    check "allowDirectAim" in config.configJson()

  test "a PLAY replay self-identifies through its header config":
    # The header config IS the provenance: a replay carrying human aim must be
    # readable as one without trusting the filename or the fleet that made it.
    var config = playConfig()
    let header = config.configJson()
    var reread = defaultGameConfig()
    reread.update(header)
    check reread.allowDirectAim
    check reread.allowSeatTakeover

  test "an aim record can never be read as a cog's button mask":
    # The record rides the input stream under a player byte no cog index can
    # produce (MaxPlayers is 32), so an aim-blind reader cannot mistake one for
    # a mask -- and this build intercepts it before the roster arrays grow.
    for cog in 0 ..< MaxPlayers:
      check (uint8(cog) and ReplayAimRecordFlag) == 0
      check not ReplayInput(player: uint8(cog), keys: 200).isDirectAimRecord()
    let record = ReplayInput(player: 5'u8 or ReplayAimRecordFlag, keys: 200)
    check record.isDirectAimRecord()
    check record.directAimRecordPlayer() == 5
    check record.directAimRecordBrads() == 200
    let cleared = ReplayInput(
      player: 5'u8 or ReplayAimRecordFlag or ReplayAimClearFlag, keys: 0)
    check cleared.isDirectAimRecord()
    check cleared.directAimRecordPlayer() == 5
    check cleared.directAimRecordBrads() == -1

  test "the aim stream records a change and holds it in between":
    var
      writer = ReplayWriter(enabled: false)
      lastAim: seq[int] = @[]
    writer.writeDirectAimChange(lastAim, 0'u32, 3, 90)
    check lastAim[3] == 90
    writer.writeDirectAimChange(lastAim, 1'u32, 3, 90)   # unchanged: no record
    check lastAim[3] == 90
    writer.writeDirectAimChange(lastAim, 2'u32, 3, -1)   # the human left
    check lastAim[3] == -1

  test "a recorded aim stream replays to the identical bearing, through a death":
    # The state transition the whole design turns on. A cursor held still while
    # the cog walks, dies, and respawns produces: bearings, a CLEAR at the
    # death, then bearings again from the new spawn. Playback must reproduce
    # every one -- a dropped record would re-simulate the human's match with
    # the turret on its policy heading.
    var
      sim = twoTeamGame()
      writer = ReplayWriter(enabled: false)
      lastAim: seq[int] = @[]
      records: seq[ReplayInput] = @[]
      livePath: seq[int] = @[]
    let cursorX = 900
    let cursorY = 200
    sim.players[0].x = 400
    sim.players[0].y = 400
    sim.players[0].alive = true
    for tick in 0 ..< 40:
      # A death at tick 12, back on its feet at tick 24.
      sim.players[0].alive = tick < 12 or tick >= 24
      if sim.players[0].alive:
        sim.players[0].x = 400 + tick * 5       # walking under a still cursor
      var brads = -1
      if sim.players[0].alive:
        brads = sim.players[0].directAimBrads(cursorX, cursorY)
        sim.applyDirectAim(0, brads)
      let before = lastAim
      writer.writeDirectAimChange(lastAim, uint32(tick), 0, brads)
      if before.len == 0 or before[0] != lastAim[0]:
        records.add(ReplayInput(
          time: uint32(tick),
          player: (
            if brads < 0: 0'u8 or ReplayAimRecordFlag or ReplayAimClearFlag
            else: 0'u8 or ReplayAimRecordFlag),
          keys: (if brads < 0: 0'u8 else: uint8(brads))))
      livePath.add(sim.players[0].aimBrads)

    # Fewer records than ticks: the stream is deduped, which is exactly why
    # playback has to HOLD the last bearing rather than clear it each tick.
    check records.len < 40
    check records.len > 2

    # Now replay it: hold the last bearing, apply it every tick, same order.
    var
      playback = twoTeamGame()
      held = -1
      index = 0
      replayPath: seq[int] = @[]
    playback.players[0].x = 400
    playback.players[0].y = 400
    for tick in 0 ..< 40:
      playback.players[0].alive = tick < 12 or tick >= 24
      if playback.players[0].alive:
        playback.players[0].x = 400 + tick * 5
      while index < records.len and int(records[index].time) <= tick:
        held = records[index].directAimRecordBrads()
        inc index
      if held >= 0:
        playback.applyDirectAim(0, held)
      replayPath.add(playback.players[0].aimBrads)

    check replayPath == livePath
    check livePath[0] != livePath[11]   # the bearing really did move
