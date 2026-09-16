import
  std/[os, strutils, unittest],
  bitworld/replays as replayCodec,
  zippy,
  ctf/[replay_codec as ctfReplayCodec, replays, sim_types],
  shell/types,
  helpers

proc addU8(bytes: var string, value: uint8) =
  bytes.add(char(value))

proc addU16(bytes: var string, value: uint16) =
  bytes.addU8(uint8(value and 0xff'u16))
  bytes.addU8(uint8(value shr 8))

proc addI16(bytes: var string, value: int) =
  bytes.addU16(cast[uint16](int16(value)))

proc addU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u32))

proc addU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u64))

proc addReplayString(bytes: var string, value: string) =
  bytes.addU16(uint16(value.len))
  bytes.add(value)

proc addReplayBytes(bytes: var string, value: openArray[uint8]) =
  bytes.addU32(uint32(value.len))
  for item in value:
    bytes.addU8(item)

proc replayHeader(
  formatVersion: uint16,
  gameVersion = ReplayCompatibleGameVersions[0],
  gameName = "ctf",
  configJson = "{}"
): string =
  result = CtfReplayMagic
  result.addU16(formatVersion)
  result.addReplayString(gameName)
  result.addReplayString(gameVersion)
  result.addU64(1_735_689_600_000'u64)
  result.addReplayString(configJson)

proc hashRecord(tick: uint32, hash: uint64): string =
  result.addU8(ReplayTickHashRecord)
  result.addU32(tick)
  result.addU64(hash)

proc inputRecord(time: uint32, player, keys: uint8): string =
  result.addU8(ReplayInputRecord)
  result.addU32(time)
  result.addU8(player)
  result.addU8(keys)

proc joinRecord(time: uint32, player: uint8, name: string, slot: int,
                token: string): string =
  result.addU8(ReplayJoinRecord)
  result.addU32(time)
  result.addU8(player)
  result.addReplayString(name)
  result.addI16(slot)
  result.addReplayString(token)

proc leaveRecord(time: uint32, player: uint8): string =
  result.addU8(ReplayLeaveRecord)
  result.addU32(time)
  result.addU8(player)

proc chatRecord(time: uint32, player: uint8, message: string): string =
  result.addU8(ReplayChatRecord)
  result.addU32(time)
  result.addU8(player)
  result.addReplayString(message)

proc debugRecord(time: uint32, player: uint8,
                 packet: openArray[uint8]): string =
  result.addU8(ReplayDebugSpriteRecord)
  result.addU32(time)
  result.addU8(player)
  result.addReplayBytes(packet)

proc format2LegacyBytes(): string =
  result = replayHeader(2)
  result.add(hashRecord(7, 0x0102_0304_0506_0708'u64))
  result.add(inputRecord(10, 2, 0xa5))
  result.add(joinRecord(11, 0, "alpha", 3, "token"))
  result.add(leaveRecord(12, 0))
  result.add(chatRecord(13, 0, "hello"))
  result.add(debugRecord(14, 0, [1'u8, 2, 3]))

template expectReplayError(expected: string, body: untyped) =
  block:
    var caught = false
    try:
      body
    except ReplayError as error:
      caught = true
      check expected in error.msg
    check caught

const
  FixtureDir = GameDir / "tests" / "fixtures" / "replay_compat"
  NamedRejectedReplayVersion = "47"
  OtherRejectedReplayVersion = "46"
    ## Membership is derived from real archived replays: reject a version if a
    ## keyframe/flatty layout moved or its gate-off rules differ from the
    ## current engine. GV47 is excluded because GV48 put the glory ledger into
    ## gameHash, so every earlier hash trajectory diverges. GV46 is excluded
    ## because GV47 relaid RewardAccount in flatty keyframes. A header rewrite
    ## is not compatibility evidence; an admitted archive must initialize and
    ## step under the current engine.

when defined(writeReplayCompatFixtures):
  createDir(FixtureDir)
  writeFile(
    FixtureDir / "format1-rejected.golden.bin",
    replayHeader(1, gameVersion = NamedRejectedReplayVersion)
  )
  writeFile(FixtureDir / "format2-legacy.golden.bin", format2LegacyBytes())

suite "CTF replay compatibility frontend":
  test "current format-1 fixture is unchanged from bitworld parsing":
    let
      bytes = readFile(GameDir / "tests" / "fixtures" /
        "capture-seed1.bitreplay")
      compatible = parseReplayBytes(bytes)
      pinned = replayCodec.parseReplayBytes(bytes, CtfReplaySpec)
    check compatible == pinned
    check compatible.gameVersion == GameVersion
    check compatible.configJson.len > 0

  test "the compatibility allowlist excludes both named prior versions":
    check ReplayCompatibleGameVersions == [GameVersion]
    let rejectedBytes = readFile(FixtureDir /
      "format1-rejected.golden.bin")
    check rejectedBytes == replayHeader(
      1,
      gameVersion = NamedRejectedReplayVersion
    )
    expectReplayError(NamedRejectedReplayVersion):
      discard parseReplayBytes(rejectedBytes)
    expectReplayError(OtherRejectedReplayVersion):
      discard parseReplayBytes(replayHeader(
        1,
        gameVersion = OtherRejectedReplayVersion
      ))

  test "format versions outside 1 and 2 are rejected":
    expectReplayError("Unsupported replay format version"):
      discard parseReplayBytes(replayHeader(0))
    expectReplayError("Unsupported replay format version"):
      discard parseReplayBytes(replayHeader(3))

  test "format 2 reads every legacy record byte-for-byte":
    let
      expectedBytes = format2LegacyBytes()
      fixturePath = FixtureDir / "format2-legacy.golden.bin"
      fixtureBytes = readFile(fixturePath)
      replay = parseReplayBytes(fixtureBytes)
    check fixtureBytes == expectedBytes
    check replay.gameName == "ctf"
    check replay.gameVersion == ReplayCompatibleGameVersions[0]
    check replay.configJson == "{}"
    check replay.hashes == @[ReplayHash(
      tick: 7,
      hash: 0x0102_0304_0506_0708'u64
    )]
    check replay.inputs == @[ReplayInput(time: 10, player: 2, keys: 0xa5)]
    check replay.joins == @[ReplayJoin(
      time: 11,
      player: 0,
      name: "alpha",
      slot: 3,
      token: "token"
    )]
    check replay.leaves == @[ReplayLeave(time: 12, player: 0)]
    check replay.chats == @[ReplayChat(
      time: 13,
      player: 0,
      message: "hello"
    )]
    check replay.debugSprites == @[ReplayDebugSprite(
      time: 14,
      player: 0,
      packet: @[1'u8, 2, 3]
    )]
    check loadReplay(fixturePath) == replay

  test "backward hashes stop format 1 and format 2 without reading the tail":
    let body = hashRecord(2, 20) & hashRecord(1, 10) & char(0xff)
    for formatVersion in [1'u16, 2'u16]:
      let replay = parseReplayBytes(replayHeader(formatVersion) & body)
      check replay.hashes == @[ReplayHash(tick: 2, hash: 20)]

  test "format 2 keeps high-bit hash ticks in the uint32 domain":
    # High-bit ticks are legal, not hostile: native bitworld accepts them, so
    # the wasm32 reader must preserve that behavior rather than reject them.
    let forward = parseReplayBytes(
      replayHeader(2) &
      hashRecord(0x7fff_ffff'u32, 1) &
      hashRecord(0x8000_0000'u32, 2)
    )
    check forward.hashes == @[
      ReplayHash(tick: 0x7fff_ffff'u32, hash: 1),
      ReplayHash(tick: 0x8000_0000'u32, hash: 2)
    ]

    let backward = parseReplayBytes(
      replayHeader(2) &
      hashRecord(0x8000_0000'u32, 2) &
      hashRecord(0x7fff_ffff'u32, 1) &
      char(0xff)
    )
    check backward.hashes == @[
      ReplayHash(tick: 0x8000_0000'u32, hash: 2)
    ]

  test "format 2 rejects backward timestamps independently per stream":
    let cases = [
      (inputRecord(2, 0, 0) & inputRecord(1, 0, 0), "input"),
      (joinRecord(2, 0, "a", 0, "t") &
        joinRecord(1, 0, "b", 1, "u"), "join"),
      (leaveRecord(2, 0) & leaveRecord(1, 0), "leave"),
      (chatRecord(2, 0, "a") & chatRecord(1, 0, "b"), "chat"),
      (debugRecord(2, 0, [1'u8]) & debugRecord(1, 0, [2'u8]),
        "debug sprite")
    ]
    for (records, stream) in cases:
      expectReplayError("Replay " & stream & " timestamps move backward"):
        discard parseReplayBytes(replayHeader(2) & records)

  test "format 2 preserves truncation errors for the header and each record":
    let completeHeader = replayHeader(2)
    expectReplayError("Replay file is truncated at byte"):
      discard parseReplayBytes(completeHeader[0 .. ^2])
    let records = [
      hashRecord(1, 1),
      inputRecord(1, 0, 0),
      joinRecord(1, 0, "a", 0, "t"),
      leaveRecord(1, 0),
      chatRecord(1, 0, "a"),
      debugRecord(1, 0, [1'u8])
    ]
    for record in records:
      let truncated = completeHeader & record[0 .. ^2]
      expectReplayError("Replay file is truncated at byte"):
        discard parseReplayBytes(truncated)

  test "format 2 rejects a high-bit debug length before int conversion":
    var hostile = replayHeader(2)
    hostile.addU8(ReplayDebugSpriteRecord)
    hostile.addU32(1)
    hostile.addU8(0)
    hostile.addU32(0x8000_0000'u32)
    expectReplayError("Replay file is truncated at byte"):
      discard parseReplayBytes(hostile)

  test "format 2 obeys the chat-allowed rule":
    var noChatSpec = CtfReplaySpec
    noChatSpec.allowChat = false
    expectReplayError("Replay chat record is not supported"):
      discard ctfReplayCodec.parseReplayBytes(
        replayHeader(2) & chatRecord(1, 0, "no"),
        noChatSpec,
        ReplayCompatibleGameVersions
      )

  test "format 2 opens shell arms while preserving unknown-type rejection":
    expectReplayError("shell replay record is truncated"):
      discard parseReplayBytes(replayHeader(2) & char(RecPlayCall))
    expectReplayError("Unknown replay record type"):
      discard parseReplayBytes(replayHeader(2) & char(0xff))

  test "gzip and zlib replay artifacts use the same frontend":
    let raw = format2LegacyBytes()
    for dataFormat in [dfGzip, dfZlib]:
      check parseReplayBytes(compress(raw, BestSpeed, dataFormat)) ==
        parseReplayBytes(raw)

  test "header identity checks remain strict":
    expectReplayError("Replay magic does not match"):
      discard parseReplayBytes("NOTACTF!" & replayHeader(2)[8 .. ^1])
    expectReplayError("Replay game name does not match"):
      discard parseReplayBytes(replayHeader(2, gameName = "other"))

  test "the existing writer remains on format 1":
    let path = getTempDir() / ("ctf-replay-compat-" &
      $getCurrentProcessId() & ".bitreplay")
    try:
      var writer = openReplayWriter(path, "{}")
      writer.closeReplayWriter()
      let bytes = readFile(path)
      check bytes[8].uint8 == 1'u8
      check bytes[9].uint8 == 0'u8
    finally:
      if fileExists(path):
        removeFile(path)
