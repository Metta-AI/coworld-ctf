## Pure and byte-level tests for the Phase 4 persistent-seat boundary.

import std/[os, unittest]

import ../src/ctf/[sim_config, sim_types]
import ../src/shell/[dispatch, packets, replay_records, seats, types]

const LifecycleFixtureDir = "tests" / "fixtures" / "shell" / "replay"

proc lifecycleFixture(name: string): LifecycleRecord =
  case name
  of "disconnect.bin":
    LifecycleRecord(kind: lrDisconnect, replayTimeMs: 0x44434241'u32,
      seat: 0x45)
  of "kick.bin":
    LifecycleRecord(kind: lrKick, replayTimeMs: 0x54535251'u32, seat: 0x55)
  of "rebind.bin":
    LifecycleRecord(kind: lrRebind, replayTimeMs: 0x64636261'u32, seat: 0x65)
  else:
    raise newException(ValueError, "unknown lifecycle fixture " & name)

when defined(writeLifecycleGoldens):
  createDir(LifecycleFixtureDir)
  for name in ["disconnect.bin", "kick.bin", "rebind.bin"]:
    writeFile(LifecycleFixtureDir / name,
      lifecycleFixture(name).encodeLifecycleRecord())

suite "shell persistent socket binding":
  test "bind loss rebind and teardown are generation-checked":
    var binding = initPlaySeatBinding[int]()
    check binding.state == pssUnbound
    check binding.generation == 0
    check not binding.admits(10, 0)

    let first = binding.bindSocket(10)
    check first.generation == 1
    check not first.replaced
    check binding.state == pssBound
    check binding.admits(10, 1)

    check not binding.lose(11)
    check binding.admits(10, 1)
    check binding.lose(10)
    check binding.state == pssLost
    check not binding.admits(10, 1)

    let rebound = binding.bindSocket(20)
    check rebound.generation == 2
    check not rebound.replaced
    check binding.admits(20, 2)
    check not binding.admits(10, 1)

    binding.close()
    check binding.state == pssClosed
    check not binding.admits(20, 2)
    expect SeatStateError:
      discard binding.bindSocket(30)

  test "newest authenticated socket wins before same-drain admission":
    var binding = initPlaySeatBinding[int]()
    discard binding.bindSocket(10)
    let oldGeneration = binding.generation
    let replacement = binding.bindSocket(20)
    check replacement.replaced
    check replacement.oldSocket == 10
    check replacement.generation == oldGeneration + 1
    # A queued old-socket message and a new-socket message can share a drain;
    # identity plus generation admits only the replacement.
    check not binding.admits(10, oldGeneration)
    check binding.admits(20, replacement.generation)
    check not binding.lose(10)
    check binding.state == pssBound

  test "play-seat episode gate requires shell and at least one play slot":
    var config = defaultGameConfig()
    check not config.isPlaySeatEpisode()
    config.season2Shell = true
    check not config.isPlaySeatEpisode()
    config.slots = @[
      PlayerSlotConfig(control: scInput),
      PlayerSlotConfig(control: scPlay),
    ]
    check config.isPlaySeatEpisode()
    check not config.isPlaySeat(0)
    check config.isPlaySeat(1)
    config.season2Shell = false
    check not config.isPlaySeatEpisode()
    check not config.isPlaySeat(1)

suite "shell tombstones":
  test "input disconnect is reconnectable only in the lobby":
    var seat = initSeatTombstone()
    check seat.presence == spConnected
    check seat.disconnect(inGame = false)
    check seat.presence == spReconnectable
    check seat.timing == stPreStart
    check seat.rebind(inLobby = true)
    check seat.presence == spConnected
    check seat.timing == stNone

    check seat.disconnect(inGame = true)
    check seat.timing == stInGame
    check not seat.rebind(inLobby = false)
    check seat.presence == spReconnectable

  test "kick is terminal and reset never clears a tombstone":
    var seat = initSeatTombstone()
    check seat.kick(inGame = false)
    check seat.presence == spTerminal
    check seat.timing == stPreStart
    seat.preserveAcrossReset()
    check seat.presence == spTerminal
    check not seat.rebind(inLobby = true)
    check not seat.disconnect(inGame = true)

  test "an in-game tombstone stays an abandoned participant":
    var seat = initSeatTombstone()
    check seat.kick(inGame = true)
    check seat.presence == spTerminal
    check seat.timing == stInGame
    check seat.isInGameAbandonment
    check not seat.isNeverParticipant

suite "shell lifecycle records":
  test "checked-in lifecycle fixtures pin the independent record bytes":
    for name in ["disconnect.bin", "kick.bin", "rebind.bin"]:
      let bytes = readFile(LifecycleFixtureDir / name)
      check bytes.len == 6
      check bytes == lifecycleFixture(name).encodeLifecycleRecord()
      check bytes.decodeLifecycleRecord() == lifecycleFixture(name)

  test "disconnect kick and rebind have exact six-byte encodings":
    let cases = [
      (LifecycleRecord(kind: lrDisconnect, replayTimeMs: 0x04030201'u32,
        seat: 5'u8), "\x14\x01\x02\x03\x04\x05"),
      (LifecycleRecord(kind: lrKick, replayTimeMs: 0x88776655'u32,
        seat: 9'u8), "\x15\x55\x66\x77\x88\x09"),
      (LifecycleRecord(kind: lrRebind, replayTimeMs: 0xffffffff'u32,
        seat: 31'u8), "\x16\xff\xff\xff\xff\x1f"),
    ]
    for (record, golden) in cases:
      check record.encodeLifecycleRecord() == golden
      check golden.decodeLifecycleRecord() == record

  test "decoder rejects wrong type truncation and trailing bytes":
    for bytes in ["", "\x14", "\x14\0", "\x14\0\0", "\x14\0\0\0",
        "\x14\0\0\0\0", "\x13\0\0\0\0\0", "\x14\0\0\0\0\0x"]:
      expect LifecycleRecordError:
        discard bytes.decodeLifecycleRecord()

  test "valid input disconnect and rebind update playback state":
    var state = initLifecyclePlayback(@[false, true])
    state.applyLifecycleRecord(LifecycleRecord(
      kind: lrDisconnect, replayTimeMs: 10, seat: 0))
    check state.presence(0) == spReconnectable
    state.applyLifecycleRecord(LifecycleRecord(
      kind: lrRebind, replayTimeMs: 10, seat: 0))
    check state.presence(0) == spConnected
    check state.lastReplayTimeMs == 10

  test "playback rejects every named invalid rebind":
    block outOfRange:
      var state = initLifecyclePlayback(@[false])
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 1, seat: 1))
    block backwardTime:
      var state = initLifecyclePlayback(@[false])
      state.applyLifecycleRecord(LifecycleRecord(
        kind: lrDisconnect, replayTimeMs: 10, seat: 0))
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 9, seat: 0))
    block playSeat:
      var state = initLifecyclePlayback(@[true])
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 1, seat: 0))
    block afterKick:
      var state = initLifecyclePlayback(@[false])
      state.applyLifecycleRecord(LifecycleRecord(
        kind: lrKick, replayTimeMs: 1, seat: 0))
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 2, seat: 0))
    block duplicate:
      var state = initLifecyclePlayback(@[false])
      state.applyLifecycleRecord(LifecycleRecord(
        kind: lrDisconnect, replayTimeMs: 1, seat: 0))
      state.applyLifecycleRecord(LifecycleRecord(
        kind: lrRebind, replayTimeMs: 2, seat: 0))
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 3, seat: 0))
    block withoutDisconnect:
      var state = initLifecyclePlayback(@[false])
      expect LifecycleRecordError:
        state.applyLifecycleRecord(LifecycleRecord(
          kind: lrRebind, replayTimeMs: 1, seat: 0))

  test "high-bit u32 times stay ordered without wasm32 narrowing":
    var state = initLifecyclePlayback(@[false])
    state.applyLifecycleRecord(LifecycleRecord(
      kind: lrDisconnect, replayTimeMs: 0x7fffffff'u32, seat: 0))
    state.applyLifecycleRecord(LifecycleRecord(
      kind: lrRebind, replayTimeMs: 0x80000000'u32, seat: 0))
    check state.lastReplayTimeMs == 0x80000000'u32

suite "play-seat receive dispatch":
  test "0xA0 through 0xA3 decode before the Sprite parser":
    let upload = classifyPlaySeatMessage(
      ModuleUploadPacket(uploadId: 7, wasm: "wasm").encodePacket())
    check upload.kind == prModuleUpload
    check upload.moduleUpload.uploadId == 7
    check upload.moduleUpload.wasm == "wasm"

    let call = classifyPlaySeatMessage(
      PlayCallPacket(proposalId: 8, callBytes: "{}").encodePacket())
    check call.kind == prPlayCall
    check call.playCall.proposalId == 8

    let ack = classifyPlaySeatMessage(StatusAckPacket(mark: 9).encodePacket())
    check ack.kind == prStatusAck
    check ack.statusAck.mark == 9

    let lobby = classifyPlaySeatMessage(
      LobbyChatSendPacket(text: "hello").encodePacket())
    check lobby.kind == prLobbyChat
    check lobby.lobbyChat.text == "hello"

  test "Sprite messages stay whole while input and ready are ignored":
    let chat = "\x81\x01\x00x"
    let debug = "\x86\x01\x00\x00\x00z"
    let mouse = "\x82\0\0\0\0"
    check classifyPlaySeatMessage(chat).spriteBytes == chat
    check classifyPlaySeatMessage(debug).spriteBytes == debug
    check classifyPlaySeatMessage(mouse).spriteBytes == mouse
    check classifyPlaySeatMessage("\x84\0").kind == prIgnoredSpriteInput
    check classifyPlaySeatMessage("\x85").kind == prIgnoredSpriteReady

  test "malformed shell packets empty messages and unknown opcodes reject":
    for message in ["", "\xA0", "\xA0\x02", "\xA3\x01\xff\xff\xff\xff",
        "\x80", "\x87"]:
      check classifyPlaySeatMessage(message).kind == prRejected
