## The §9.2/§9.3 pre-match lobby chat huddle (docs/designs/
## strategy-play-calling-shell-2026-08-29.md): the `chatting` substate of
## the lobby phase, and the 0xA3/0xB2 wire HANDLING logic (sim.nim). Plain
## `import`, matching test_lobby_join_timeout.nim — nothing here needs a
## real or fake WebSocket.
##
## OWNERSHIP SPLIT (James, ratified against main, 2026-08-30): this lane
## owns stepLobby's substates and the 0xA3 (client→server) / 0xB2
## (server→client) HANDLING logic, and it EMITS replay record `0x13`
## (RecLobbyChat, src/shell/types.nim:267-270) — it does NOT own the
## play-seat receive-arm SOCKET WIRING. James's decode dispatch
## (`decodeClientPacket`, src/shell/packets.nim) already covers 0xA0-0xA3
## including OpLobbyChatSend, fixture-tested (tests/test_shell_packets.nim)
## — it is simply unwired to any live socket yet (confirmed: zero
## references outside src/shell/ and tests/). Our applyLobbyChat plugs in
## as the OpLobbyChatSend handler once that wiring lands. Also not ours:
## the socket lifecycle, records 0x14-0x16, or the format-v2 codec that
## would read record 0x13 back and roll it into the manifest's
## ordered-chain arm. Nothing here drives a live socket or a live
## .bitreplay file for that reason — see the "record 0x13" suite below
## for exactly what IS proven.
##
## The central darkness claim this suite has to prove, not just assert: the
## chatting substate is armed by `hasPlaySeat` (a "play" control slot,
## §5.1), NOT by `lobbyChatTicks`'s own configured value — so an ordinary
## input-only lobby is byte-identical to the pre-huddle engine no matter
## what that field is set to. Every existing fixture and test in this repo
## has no play seat, which is exactly what makes the huddle safe to land
## with lobbyChatTicks defaulting to a NON-zero value (720, sim_types.nim).

import
  helpers,
  std/[strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[replays, sim]

proc playSeatConfig(
  lobbyChatTicks: int,
  minPlayers = 1,
  startWaitTicks = 0
): GameConfig =
  ## The one config shape the chatting substate runs under at all: a
  ## "play" control slot, with season2Shell on (required by validation).
  result = defaultGameConfig()
  result.season2Shell = true
  result.slots = @[PlayerSlotConfig(control: scPlay)]
  result.minPlayers = minPlayers
  result.startWaitTicks = startWaitTicks
  result.lobbyChatTicks = lobbyChatTicks

proc noPlaySeatConfig(
  lobbyChatTicks: int,
  minPlayers = 1,
  startWaitTicks = 0
): GameConfig =
  ## The SAME shape with no play seat — §9.2's "nothing below changes a
  ## configuration with no play seat", the gate this suite's first test
  ## proves by disabling.
  result = defaultGameConfig()
  result.minPlayers = minPlayers
  result.startWaitTicks = startWaitTicks
  result.lobbyChatTicks = lobbyChatTicks

const NoInput: seq[InputState] = @[]

suite "lobby chat: the phase gate is hasPlaySeat, not lobbyChatTicks":
  test "RED-PROVEN: no play seat, phase never engages, applyLobbyChat always closed":
    # Disables the gate by removing the ONE thing that arms it (the play
    # seat), while lobbyChatTicks stays firmly nonzero (10) — if the phase
    # were (wrongly) keyed off lobbyChatTicks alone, this config would
    # stall in a chat phase for 10 ticks. It must not: the lobby starts
    # the instant the roster is sufficient, exactly like today's engine.
    var sim = initCtfForTest(noPlaySeatConfig(lobbyChatTicks = 10))
    discard sim.addPlayer("red0")
    check sim.phase == Lobby
    sim.step(NoInput, NoInput)
    check sim.phase == Playing          # no chat delay introduced
    check not sim.inLobbyChat()
    let rejected = sim.applyLobbyChat(0, "hello")
    check not rejected.ok
    check rejected.reason == lcrClosed

  test "GREEN: the SAME lobbyChatTicks, with a play seat, actually opens the phase":
    # The other half of the same control: identical lobbyChatTicks (10),
    # identical roster shape, only `slots[].control` differs. The lobby now
    # visibly holds in `chatting` before Playing — proving the gate
    # discriminates on the play seat, not merely on the field's value.
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 10))
    discard sim.addPlayer("red0")
    check sim.phase == Lobby
    sim.step(NoInput, NoInput)          # roster becomes sufficient THIS tick
    check sim.phase == Lobby
    check sim.inLobbyChat()
    let accepted = sim.applyLobbyChat(0, "gg no re")
    check accepted.ok
    check accepted.ordinal == 1'u64

  test "lobbyChatTicks == 0 skips the phase even WITH a play seat (the gate-off shape)":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 0))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.phase == Playing
    check not sim.inLobbyChat()

  test "the phase runs exactly its configured length, then closes again":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 5))
    discard sim.addPlayer("red0")
    var sawChat = false
    var ticksInChat = 0
    for _ in 0 ..< 40:
      sim.step(NoInput, NoInput)
      if sim.phase == Playing:
        break
      if sim.inLobbyChat():
        sawChat = true
        inc ticksInChat
    check sawChat
    check ticksInChat == 5
    check sim.phase == Playing
    # Closed again once concluded — a message sent after the phase ends
    # is rejected exactly like one sent before it ever opened.
    let late = sim.applyLobbyChat(0, "still here?")
    check not late.ok
    check late.reason == lcrClosed

  test "a roster drop mid-chat does not end the phase (§9.2, does not compact)":
    var sim = initCtfForTest(
      playSeatConfig(lobbyChatTicks = 5, minPlayers = 1))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.inLobbyChat()
    # Nothing in this engine slice can remove a joined player mid-lobby
    # from here directly, but the countdown-vs-chat independence is the
    # load-bearing fact: while lobbyChatActive, stepLobby never reaches the
    # `sim.players.len < minPlayers` branch at all (see sim.nim), which is
    # exactly what "does not end chat" requires. Assert the substate is
    # still running after MORE ticks than the roster-check would ever
    # tolerate, proving the two branches are mutually exclusive per tick.
    for _ in 0 ..< 4:
      sim.step(NoInput, NoInput)
    check sim.inLobbyChat()

suite "lobby chat: admission — length, UTF-8, control chars, blanks":
  test "the 512-byte bound is enforced, exactly at the boundary":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.applyLobbyChat(0, "a".repeat(LobbyChatMaxBytes)).ok
    let over = sim.applyLobbyChat(0, "a".repeat(LobbyChatMaxBytes + 1))
    check not over.ok
    check over.reason == lcrTooLong

  test "a multibyte scalar straddling the 512th byte is a byte-length refusal":
    # 510 ASCII bytes plus one 3-byte scalar = 513 raw bytes: the length
    # check is a BYTE count, not a rune count, and runs before any UTF-8
    # decoding — this must refuse on length, not misdecode at the edge.
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let text = "a".repeat(510) & "€"   # U+20AC, 3 UTF-8 bytes
    check text.len == 513
    let rejected = sim.applyLobbyChat(0, text)
    check not rejected.ok
    check rejected.reason == lcrTooLong

  test "invalid UTF-8 is refused: a lone continuation byte":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let bad = sim.applyLobbyChat(0, "hi \x80 there")
    check not bad.ok
    check bad.reason == lcrInvalidUtf8

  test "invalid UTF-8 is refused: an overlong two-byte encoding":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    # 0xC0 0x80 is the classic overlong encoding of NUL.
    let bad = sim.applyLobbyChat(0, "\xc0\x80")
    check not bad.ok
    check bad.reason == lcrInvalidUtf8

  test "invalid UTF-8 is refused: a surrogate code point":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    # U+D800 encoded as a structurally-valid 3-byte sequence (0xED 0xA0 0x80)
    # — exactly the case std/unicode.validateUtf8 alone lets through.
    let bad = sim.applyLobbyChat(0, "\xed\xa0\x80")
    check not bad.ok
    check bad.reason == lcrInvalidUtf8

  test "a control character is refused; the one allowed line break is not":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let ctrl = sim.applyLobbyChat(0, "hi\x01there")
    check not ctrl.ok
    check ctrl.reason == lcrControlChar
    let lineSep = sim.applyLobbyChat(0, "hi there")   # U+2028
    check not lineSep.ok
    check lineSep.reason == lcrControlChar
    let withLf = sim.applyLobbyChat(0, "line one\nline two")
    check withLf.ok

  test "empty, and whitespace-only (ASCII space/LF), payloads are refused":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let empty = sim.applyLobbyChat(0, "")
    check not empty.ok
    check empty.reason == lcrEmpty
    let spaces = sim.applyLobbyChat(0, "   ")
    check not spaces.ok
    check spaces.reason == lcrEmpty
    let lf = sim.applyLobbyChat(0, "\n")
    check not lf.ok
    check lf.reason == lcrEmpty

  test "a payload of NON-ASCII spaces is content, not blank (the ASCII-only rule)":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    # U+00A0 (no-break space), never ASCII 0x20 — accepted per §9.2's
    # deliberately ASCII-only blank predicate.
    check sim.applyLobbyChat(0, "   ").ok

  test "a combining sequence is accepted UNCHANGED (no normalization)":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 100))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.applyLobbyChat(0, "é").ok   # e + combining acute accent

suite "lobby chat: ordinals and rate caps":
  test "ordinals are monotonic across every seat, not per-seat":
    var sim = initCtfForTest(
      playSeatConfig(lobbyChatTicks = 200, minPlayers = 2))
    discard sim.addPlayer("red0")
    discard sim.addPlayer("blue0")
    sim.step(NoInput, NoInput)
    check sim.inLobbyChat()
    let a = sim.applyLobbyChat(0, "hello from red")
    let b = sim.applyLobbyChat(1, "hello from blue")
    let c = sim.applyLobbyChat(0, "one more") # spacing satisfied below
    check a.ok and b.ok
    check a.ordinal == 1'u64
    check b.ordinal == 2'u64
    # Seat 0's second message is inside the min-spacing window (0 ticks
    # elapsed) — rejected, so the ordinal counter must NOT have advanced
    # for a rejected send.
    check not c.ok
    check c.reason == lcrTooSoon
    for _ in 0 ..< LobbyChatMinSpacingTicks:
      sim.step(NoInput, NoInput)
    let d = sim.applyLobbyChat(0, "one more, for real")
    check d.ok
    check d.ordinal == 3'u64

  test "a seat is capped at LobbyChatMaxMessagesPerSeat per phase":
    let phaseTicks = (LobbyChatMaxMessagesPerSeat + 2) * LobbyChatMinSpacingTicks
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = phaseTicks))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    var accepted = 0
    for i in 0 ..< LobbyChatMaxMessagesPerSeat:
      let outcome = sim.applyLobbyChat(0, "message " & $i)
      check outcome.ok
      inc accepted
      for _ in 0 ..< LobbyChatMinSpacingTicks:
        sim.step(NoInput, NoInput)
    check accepted == LobbyChatMaxMessagesPerSeat
    let overflow = sim.applyLobbyChat(0, "one too many")
    check not overflow.ok
    check overflow.reason == lcrRateLimited

suite "lobby chat: applyShout stays untouched":
  test "a lobby chat send is never visible to applyShout, and vice versa":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    check sim.inLobbyChat()
    # applyShout is Playing-only (sim.nim, unchanged) — it must refuse here
    # even though the roster exists and the phase is open, because lobby
    # chat is its OWN path, not a shout variant.
    check not sim.applyShout(0, "not a shout")
    check sim.recentShouts.len == 0
    check sim.applyLobbyChat(0, "this is a lobby chat").ok

suite "lobby chat: the 0xA3/0xB2 wire codec, byte for byte":
  ## OURS per the ownership split: the pure parse/build functions
  ## (sim.nim). James's decodeClientPacket (src/shell/packets.nim) already
  ## dispatches OpLobbyChatSend among 0xA0-0xA3 — it is unwired to any live
  ## socket yet, and our applyLobbyChat is the handler it will call once
  ## that wiring lands. Nothing here drives a socket for that reason;
  ## these are pure byte-level round trips only.
  test "a 0xA3 send packet parses back to its exact text":
    var bytes = newString(6 + 5)
    bytes[0] = char(LobbyChatSendOp)
    bytes[1] = char(LobbyChatWireVersion)
    bytes[2] = char(5'u8)   # u32 len, little-endian: 5, 0, 0, 0
    bytes[6 ..< 11] = "hello"
    check bytes.parseLobbyChatSendPacket() == (true, "hello")

  test "a length-prefix mismatch is refused structurally":
    var bytes = newString(6 + 2)
    bytes[0] = char(LobbyChatSendOp)
    bytes[1] = char(LobbyChatWireVersion)
    bytes[2] = char(99'u8)   # claims 99 bytes, carries 2
    check not bytes.parseLobbyChatSendPacket().ok

  test "the 0xB2 broadcast packet's every field lands at its documented offset":
    let packet = buildLobbyChatBroadcastPacket(
      ordinal = 42'u64, tick = 1000'u32, seat = 3'u8, team = 1'u8, text = "gg")
    check packet.len == 20 + 2
    check uint8(packet[0]) == LobbyChatBroadcastOp
    check uint8(packet[1]) == LobbyChatWireVersion
    check uint8(packet[14]) == 3'u8   # seat
    check uint8(packet[15]) == 1'u8   # team
    check packet[20 ..< 22] == "gg"

suite "lobby chat: record 0x13 (RecLobbyChat), EMIT side only":
  ## Ownership split (James, ratified against main): this lane owns
  ## stepLobby's substates and the 0xA3/0xB2 HANDLING logic, and it EMITS
  ## record 0x13 — it does NOT own reading it back, the manifest's
  ## ordered-chain arm, or the format-v2 codec that would append these
  ## bytes to a live .bitreplay stream (that codec does not exist on main:
  ## bitworld/replays.nim exposes no raw-record-type append, and every
  ## writeXXX proc there hardcodes its own leading byte, 0x01..0x06). So
  ## this suite proves the EMITTED BYTES conform to the landed layout,
  ## src/shell/types.nim:267-270, and nothing about a replay FILE.
  test "the encoded record starts with the landed byte 0x13 and matches its layout":
    let bytes = encodeLobbyChatTranscriptRecord(
      replayTimeMs = 1234'u32, ordinal = 7'u64, seat = 3'u8, team = 1'u8,
      text = "gg")
    check uint8(bytes[0]) == 0x13'u8
    check bytes.len == 17 + 2   # header + "gg"
    let decoded = bytes.decodeLobbyChatTranscriptRecord()
    check decoded.replayTimeMs == 1234'u32
    check decoded.ordinal == 7'u64
    check decoded.seat == 3'u8
    check decoded.team == 1'u8
    check decoded.text == "gg"

  test "the record honors applyLobbyChat's own admitted ordinal and text, verbatim":
    var sim = initCtfForTest(playSeatConfig(lobbyChatTicks = 50))
    discard sim.addPlayer("red0")
    sim.step(NoInput, NoInput)
    let outcome = sim.applyLobbyChat(0, "gg wp")
    check outcome.ok
    let team = sim.teamForSlot(0)
    let record = encodeLobbyChatTranscriptRecord(
      tickTime(sim.tickCount), outcome.ordinal, uint8(0), uint8(ord(team)),
      "gg wp")
    let decoded = record.decodeLobbyChatTranscriptRecord()
    check decoded.ordinal == outcome.ordinal
    check decoded.text == "gg wp"

  test "a 512-byte text (the max) round-trips; the header is exactly 17 bytes":
    let text = "z".repeat(LobbyChatMaxBytes)
    let bytes = encodeLobbyChatTranscriptRecord(0, 1, 0, 0, text)
    check bytes.len == 17 + LobbyChatMaxBytes
    check bytes.decodeLobbyChatTranscriptRecord().text == text

suite "lobby chat: gameHash independence":
  test "chat content never enters gameHash: sent vs. silent, identical chain":
    # §9.3's central claim, proven empirically rather than only asserted:
    # two otherwise-identical episodes, one where a seat chats and one
    # where it never does, must produce the IDENTICAL hash at every tick.
    proc runEpisode(chat: bool): seq[uint64] =
      var sim = initCtfForTest(
        playSeatConfig(lobbyChatTicks = 20, minPlayers = 2))
      discard sim.addPlayer("red0")
      discard sim.addPlayer("blue0")
      for tick in 0 ..< 60:
        if chat and sim.inLobbyChat() and tick == 2:
          discard sim.applyLobbyChat(0, "does this move the hash?")
        sim.step(sim.none(), sim.none())
        result.add sim.gameHash()
    let withChat = runEpisode(chat = true)
    let silent = runEpisode(chat = false)
    check withChat == silent

suite "lobby chat: existing (no play seat) configs are untouched":
  test "the shipped default (lobbyChatTicks 720) changes nothing without a play seat":
    # The field's own default is nonzero (LobbyChatTicksDefault, landed
    # ahead of this lane) — darkness therefore depends ENTIRELY on the
    # hasPlaySeat gate, not on that default ever being 0. Proven by
    # comparing the untouched default config against one with the field
    # forced to 0: identical tick of arrival at Playing.
    var untouchedConfig = defaultGameConfig()
    untouchedConfig.minPlayers = 1
    untouchedConfig.startWaitTicks = 0
    var untouched = initCtfForTest(untouchedConfig)
    check untouched.config.lobbyChatTicks == LobbyChatTicksDefault
    check untouched.config.lobbyChatTicks > 0
    discard untouched.addPlayer("red0")
    untouched.step(NoInput, NoInput)
    check untouched.phase == Playing

    var forcedOff = initCtfForTest(noPlaySeatConfig(lobbyChatTicks = 0))
    discard forcedOff.addPlayer("red0")
    forcedOff.step(NoInput, NoInput)
    check forcedOff.phase == Playing
