## Format-2 shell replay codec, verification manifest, and local playbook archive.

import
  std/[os, strutils, unittest],
  bitworld/replays as replayCodec,
  crunchy,
  ctf/[replay_codec as ctfReplayCodec, replays, sim, sim_types],
  shell/[playbook_archive, replay_records, seats, types],
  helpers

const FixtureDir = GameDir / "tests" / "fixtures" / "shell" / "replay"

proc addU8(bytes: var string, value: uint8) =
  bytes.add(char(value))

proc addU16(bytes: var string, value: uint16) =
  bytes.addU8(uint8(value and 0xff'u16))
  bytes.addU8(uint8(value shr 8))

proc addU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u32))

proc addU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.addU8(uint8((value shr shift) and 0xff'u64))

proc addString16(bytes: var string, value: string) =
  bytes.addU16(uint16(value.len))
  bytes.add(value)

proc format2Header(configJson: string): string =
  result = CtfReplayMagic
  result.addU16(ShellReplayFormatVersion)
  result.addString16(GameName)
  result.addString16(GameVersion)
  result.addU64(1_735_689_600_000'u64)
  result.addString16(configJson)

proc shellConfig(): string =
  "{\"season2Shell\":true,\"slots\":[" &
    "{\"control\":\"play\"},{\"control\":\"input\"}]}"

proc moduleIdentity(name: string): CodeIdentity =
  CodeIdentity(kind: cikModule, moduleSha256: sha256Hex(name))

proc nativeIdentity(name: string): CodeIdentity =
  CodeIdentity(kind: cikNative, nativeName: name,
    nativeGameVersion: GameVersion)

proc everyReflexCall(time = 10'u32): PlayCallRecord =
  PlayCallRecord(
    replayTimeMs: time,
    seat: 0,
    epoch: 9,
    ladderBytes: "{\"plays\":[" &
      "{\"entry_id\":\"controller\",\"play\":\"pact\"}," &
      "{\"entry_id\":\"grenade\",\"play\":\"reflex_clear_grenade\"}," &
      "{\"entry_id\":\"spray\",\"play\":\"reflex_clear_spray\"}," &
      "{\"entry_id\":\"zone\",\"play\":\"reflex_zone_escape\"}]}",
    entries: @[
      PlayCallEntryIdentity(entryId: "controller",
        code: moduleIdentity("pact wasm")),
      PlayCallEntryIdentity(entryId: "grenade",
        code: nativeIdentity("reflex_clear_grenade")),
      PlayCallEntryIdentity(entryId: "spray",
        code: nativeIdentity("reflex_clear_spray")),
      PlayCallEntryIdentity(entryId: "zone",
        code: nativeIdentity("reflex_zone_escape"))])

proc acceptedAnnotation(tick = 20'u32): ShellAnnotation =
  ShellAnnotation(
    tick: tick,
    seat: 0,
    kind: akAcceptedIntentChange,
    effectiveEpoch: 9,
    provenance: Provenance(
      base: ProvenanceBase(
        kind: pbEntry,
        entryId: "controller",
        moduleSha256: sha256Hex("pact wasm"),
        emitTick: 18),
      overlays: @[
        OverlayContribution(
          entryId: "overlay",
          moduleSha256: sha256Hex("overlay wasm"),
          acceptedTick: 19,
          policySha256: sha256Hex("policy"))]),
    intentBytes: "{\"kind\":\"hold\"}")

proc sampleAnnotations(): seq[ShellAnnotation] =
  @[
    acceptedAnnotation(),
    ShellAnnotation(tick: 20, seat: 0, kind: akClearOnDeath,
      clearGeneration: 4),
    ShellAnnotation(tick: 21, seat: 0, kind: akInstallSafeIntent,
      installGeneration: 5, installReason: "respawn",
      safeBytes: "{\"kind\":\"hold\"}"),
    ShellAnnotation(tick: 21, seat: 0, kind: akPlayFault,
      faultAtEpoch: 9, faultEntryId: "controller",
      faultCode: fcOutOfFuel, annotationFaultReason: "fuel")]

proc sampleTranscript(): seq[LobbyChatRecord] =
  @[
    LobbyChatRecord(replayTimeMs: 8, ordinal: 1, seat: 0, team: 2,
      text: "ready"),
    LobbyChatRecord(replayTimeMs: 9, ordinal: 2, seat: 1, team: 2,
      text: "go")]

proc sampleBallots(): seq[BallotRecord] =
  ## docs/designs/prematch-vote-wire-2026-08-31.md §4: a two-seat ballot
  ## (seat 0 red casts A, seat 1 blue casts C) resolved to A (option 0) --
  ## the shape a replaying VIEWER (not the classifier lane) needs to render
  ## the transcript + winner. Timed no earlier than sampleTranscript()'s
  ## last entry (ms 9) and no later than everyReflexCall()'s default (ms
  ## 10): completeReplay() places ballots after the transcript and before
  ## calls in the byte stream, and record order enforces one GLOBAL
  ## non-decreasing replay time across every record type, not a per-type
  ## clock (same-time is fine; phase 3 -> phase 3 -> phase 4 only moves
  ## forward).
  @[
    BallotRecord(replayTimeMs: 9, ordinal: 1, kind: brkCast,
      seat: 0, team: 0, option: 0),
    BallotRecord(replayTimeMs: 9, ordinal: 2, kind: brkCast,
      seat: 1, team: 1, option: 2),
    BallotRecord(replayTimeMs: 10, ordinal: 3, kind: brkResolved,
      category: 1, tieBreakDrawn: 0, finalOption: 0)]

proc hexNibbleManual(value: char): uint8 =
  case value
  of '0' .. '9': uint8(ord(value) - ord('0'))
  of 'a' .. 'f': uint8(ord(value) - ord('a') + 10)
  else: raise newException(ValueError, "expected lowercase SHA-256 hex")

proc addHashRawManual(bytes: var string, value: string) =
  ## Independent contract-side hex decoding. The record encoder's hashRaw
  ## helper is deliberately not used by these golden builders.
  doAssert value.len == 64
  for index in 0 ..< 32:
    bytes.addU8((value[index * 2].hexNibbleManual shl 4) or
      value[index * 2 + 1].hexNibbleManual)

proc hashHexManual(bytes: openArray[uint8]): string =
  const Hex = "0123456789abcdef"
  result = newString(bytes.len * 2)
  for index, value in bytes:
    result[index * 2] = Hex[int(value shr 4)]
    result[index * 2 + 1] = Hex[int(value and 0x0f)]

proc orderedChainHashManual(records: openArray[string]): string =
  ## Independent implementation of SHA256(previous raw digest || record).
  var state = newString(32)
  for record in records:
    let digest = sha256(state & record)
    for index in 0 ..< 32:
      state[index] = char(digest[index])
  if records.len == 0:
    return "0".repeat(64)
  var raw = newSeq[uint8](32)
  for index in 0 ..< 32:
    raw[index] = state[index].uint8
  raw.hashHexManual

proc playCallGolden(record: PlayCallRecord): string =
  ## Hand-written 0x10 layout; never calls encodePlayCallRecord.
  result.addU8(0x10)
  result.addU32(record.replayTimeMs)
  result.addU8(record.seat)
  result.addU64(record.epoch)
  result.addString16(record.ladderBytes)
  result.addU8(uint8(record.entries.len))
  for entry in record.entries:
    result.addString16(entry.entryId)
    case entry.code.kind
    of cikModule:
      result.addU8(0)
      result.addHashRawManual(entry.code.moduleSha256)
    of cikNative:
      result.addU8(1)
      result.addString16(entry.code.nativeName)
      result.addString16(entry.code.nativeGameVersion)

proc annotationGolden(annotation: ShellAnnotation): string =
  ## Hand-written 0x11 layout; wire kind values are literal contract bytes.
  result.addU8(0x11)
  result.addU32(annotation.tick)
  result.addU8(annotation.seat)
  case annotation.kind
  of akAcceptedIntentChange:
    result.addU8(0)
    result.addU64(annotation.effectiveEpoch)
    case annotation.provenance.base.kind
    of pbEntry:
      result.addU8(0)
      result.addString16(annotation.provenance.base.entryId)
      result.addHashRawManual(annotation.provenance.base.moduleSha256)
      result.addU32(annotation.provenance.base.emitTick)
    of pbDefault:
      result.addU8(1)
    of pbReflex:
      result.addU8(2)
      result.addString16(annotation.provenance.base.reflexName)
    result.addU8(uint8(annotation.provenance.overlays.len))
    for overlay in annotation.provenance.overlays:
      result.addString16(overlay.entryId)
      result.addHashRawManual(overlay.moduleSha256)
      result.addU32(overlay.acceptedTick)
      result.addHashRawManual(overlay.policySha256)
    result.addString16(annotation.intentBytes)
  of akClearOnDeath:
    result.addU8(1)
    result.addU64(annotation.clearGeneration)
  of akInstallSafeIntent:
    result.addU8(2)
    result.addU64(annotation.installGeneration)
    result.addString16(annotation.installReason)
    result.addString16(annotation.safeBytes)
  of akPlayFault:
    result.addU8(4)  # the coded layout; 3 is the legacy pre-code layout
    result.addU64(annotation.faultAtEpoch)
    result.addU8(uint8(annotation.faultCode.ord))
    result.addString16(annotation.faultEntryId)
    result.addString16(annotation.annotationFaultReason)

proc lobbyChatGolden(record: LobbyChatRecord): string =
  ## Hand-written 0x13 layout; never calls encodeLobbyChatRecord.
  result.addU8(0x13)
  result.addU32(record.replayTimeMs)
  result.addU64(record.ordinal)
  result.addU8(record.seat)
  result.addU8(record.team)
  result.addString16(record.text)

proc lifecycleGolden(kind: LifecycleRecordKind, replayTimeMs: uint32,
    seat: uint8): string =
  ## Hand-written fixed layouts for 0x14, 0x15, and 0x16.
  result.addU8(case kind
    of lrDisconnect: 0x14'u8
    of lrKick: 0x15'u8
    of lrRebind: 0x16'u8)
  result.addU32(replayTimeMs)
  result.addU8(seat)

proc manifestGolden(call, annotation, transcript: string): string =
  ## Hand-written 0x12 layout for two seat arms. Counts and chain roots are
  ## derived independently from the exact record bytes above.
  result.addU8(0x12)
  result.addU16(2)
  result.addU8(0)
  result.addU32(1)
  result.addHashRawManual(orderedChainHashManual([call]))
  result.addU32(1)
  result.addHashRawManual(orderedChainHashManual([annotation]))
  result.addU8(1)
  result.addU32(0)
  result.addHashRawManual(orderedChainHashManual(newSeq[string]()))
  result.addU32(0)
  result.addHashRawManual(orderedChainHashManual(newSeq[string]()))
  result.addU32(1)
  result.addHashRawManual(orderedChainHashManual([transcript]))

proc completeReplay(
  calls: seq[PlayCallRecord] = @[everyReflexCall()],
  annotations: seq[ShellAnnotation] = sampleAnnotations(),
  transcript: seq[LobbyChatRecord] = sampleTranscript(),
  ballots: seq[BallotRecord] = @[],
): string =
  var
    callBuckets = newSeq[seq[string]](2)
    annotationBuckets = newSeq[seq[string]](2)
    transcriptBytes: seq[string]
  result = format2Header(shellConfig())
  for record in transcript:
    let bytes = record.encodeLobbyChatRecord()
    transcriptBytes.add(bytes)
    result.add(bytes)
  # `0x17` (RecVoteReserved) is hash-coupled, not manifest-arm'd (settled
  # 2c2f905c) -- unlike the transcript loop above, its bytes never feed
  # `transcriptBytes`/the manifest.
  for record in ballots:
    result.add(record.encodeBallotRecord())
  for record in calls:
    let bytes = record.encodePlayCallRecord()
    callBuckets[int(record.seat)].add(bytes)
    result.add(bytes)
  for annotation in annotations:
    let bytes = annotation.encodeAnnotationRecord()
    annotationBuckets[int(annotation.seat)].add(bytes)
    result.add(bytes)
  result.add(buildShellReplayManifest(
    callBuckets, annotationBuckets, transcriptBytes).encodeManifestRecord())

template expectReplayError(expected: string, body: untyped) =
  block:
    var caught = false
    try:
      body
    except ReplayError as error:
      caught = true
      check expected in error.msg
    check caught

template expectArchiveError(body: untyped) =
  block:
    var caught = false
    try:
      body
    except PlaybookArchiveError:
      caught = true
    check caught

when defined(writeShellReplayGoldens):
  createDir(FixtureDir)
  let
    call = everyReflexCall().playCallGolden()
    annotations = sampleAnnotations()
    transcript = sampleTranscript()[0].lobbyChatGolden()
    manifest = manifestGolden(call, annotations[0].annotationGolden(),
      transcript)
  writeFile(FixtureDir / "play-call.bin", call)
  writeFile(FixtureDir / "annotation-accepted.bin",
    annotations[0].annotationGolden())
  writeFile(FixtureDir / "annotation-clear.bin",
    annotations[1].annotationGolden())
  writeFile(FixtureDir / "annotation-install.bin",
    annotations[2].annotationGolden())
  writeFile(FixtureDir / "annotation-fault.bin",
    annotations[3].annotationGolden())
  writeFile(FixtureDir / "lobby-chat.bin", transcript)
  writeFile(FixtureDir / "disconnect.bin",
    lifecycleGolden(lrDisconnect, 0x44434241'u32, 0x45))
  writeFile(FixtureDir / "kick.bin",
    lifecycleGolden(lrKick, 0x54535251'u32, 0x55))
  writeFile(FixtureDir / "rebind.bin",
    lifecycleGolden(lrRebind, 0x64636261'u32, 0x65))
  writeFile(FixtureDir / "manifest.bin", manifest)

suite "shell replay record bytes":
  test "checked-in goldens cover calls annotations transcript and manifest":
    let annotations = sampleAnnotations()
    let callGolden = everyReflexCall().playCallGolden()
    let transcriptGolden = sampleTranscript()[0].lobbyChatGolden()
    check readFile(FixtureDir / "play-call.bin") == callGolden
    check callGolden == everyReflexCall().encodePlayCallRecord()
    for index, name in ["annotation-accepted.bin", "annotation-clear.bin",
        "annotation-install.bin", "annotation-fault.bin"]:
      let golden = annotations[index].annotationGolden()
      check readFile(FixtureDir / name) == golden
      check golden == annotations[index].encodeAnnotationRecord()
    check readFile(FixtureDir / "lobby-chat.bin") == transcriptGolden
    check transcriptGolden == sampleTranscript()[0].encodeLobbyChatRecord()
    for (name, kind, time, seat) in [
      ("disconnect.bin", lrDisconnect, 0x44434241'u32, 0x45'u8),
      ("kick.bin", lrKick, 0x54535251'u32, 0x55'u8),
      ("rebind.bin", lrRebind, 0x64636261'u32, 0x65'u8),
    ]:
      let golden = lifecycleGolden(kind, time, seat)
      check readFile(FixtureDir / name) == golden
      check golden == LifecycleRecord(kind: kind, replayTimeMs: time,
        seat: seat).encodeLifecycleRecord()
    let
      expectedManifest = manifestGolden(callGolden,
        annotations[0].annotationGolden(), transcriptGolden)
    check readFile(FixtureDir / "manifest.bin") == expectedManifest
    check expectedManifest == buildShellReplayManifest(
      @[@[callGolden], newSeq[string]()],
      @[@[annotations[0].annotationGolden()], newSeq[string]()],
      @[transcriptGolden]).encodeManifestRecord()

  test "call golden names a module and every native reflex":
    let bytes = readFile(FixtureDir / "play-call.bin")
    var offset = 0
    let decoded = bytes.decodePlayCallRecord(offset)
    check offset == bytes.len
    check decoded.entries == everyReflexCall().entries
    check decoded.entries[0].code.kind == cikModule
    check decoded.entries[1].code.nativeName == "reflex_clear_grenade"
    check decoded.entries[2].code.nativeName == "reflex_clear_spray"
    check decoded.entries[3].code.nativeName == "reflex_zone_escape"
    check decoded.contentSha256 == sha256Hex(bytes)

  test "annotation round trip preserves epochs provenance and exact order":
    for expected in sampleAnnotations():
      let bytes = expected.encodeAnnotationRecord()
      var offset = 0
      let decoded = bytes.decodeAnnotationRecord(offset)
      check decoded == expected
      check offset == bytes.len
    check sampleAnnotations()[0].provenance.overlays[0].acceptedTick == 19

  test "lobby u16 length is capped before conversion":
    var hostile = ""
    hostile.addU8(RecLobbyChat)
    hostile.addU32(1)
    hostile.addU64(1)
    hostile.addU8(0)
    hostile.addU8(0)
    hostile.addU16(0x8000'u16)
    var offset = 0
    expect ReplayRecordError:
      discard hostile.decodeLobbyChatRecord(offset)

  test "ballot round trip preserves cast and resolved records":
    for expected in sampleBallots():
      let bytes = expected.encodeBallotRecord()
      check bytes.len == RecBallotBytes
      var offset = 0
      let decoded = bytes.decodeBallotRecord(offset)
      check decoded == expected
      check offset == bytes.len

  test "whole-record decoders reject trailing bytes":
    let
      call = everyReflexCall().encodePlayCallRecord()
      annotation = acceptedAnnotation().encodeAnnotationRecord()
      lobby = sampleTranscript()[0].encodeLobbyChatRecord()
      manifest = buildShellReplayManifest(
        @[@[call], newSeq[string]()],
        @[@[annotation], newSeq[string]()],
        @[lobby]).encodeManifestRecord()
    expect ReplayRecordError:
      discard (call & "\xff").decodePlayCallRecord()
    expect ReplayRecordError:
      discard (annotation & "\xff").decodeAnnotationRecord()
    expect ReplayRecordError:
      discard (lobby & "\xff").decodeLobbyChatRecord()
    expect ReplayRecordError:
      discard (manifest & "\xff").decodeManifestRecord()

suite "shell replay file verification":
  test "format 2 eagerly verifies and retains every shell stream":
    let detailed = ctfReplayCodec.parseCtfReplayBytes(
      completeReplay(), CtfReplaySpec, ReplayCompatibleGameVersions)
    check detailed.shell.manifestVerified
    check detailed.shell.calls.len == 1
    check detailed.shell.annotations == sampleAnnotations()
    check detailed.shell.lobbyTranscript == sampleTranscript()
    check detailed.shell.moduleHashes() == @[
      sha256Hex("pact wasm")]
    check ctfReplayCodec.parseReplayBytes(
      completeReplay(), CtfReplaySpec,
      ReplayCompatibleGameVersions) == detailed.replay

  test "format 2 retains ballot records and enforces their ordinal order":
    let detailed = ctfReplayCodec.parseCtfReplayBytes(
      completeReplay(ballots = sampleBallots()),
      CtfReplaySpec, ReplayCompatibleGameVersions)
    check detailed.shell.ballots == sampleBallots()
    # `0x17` is hash-coupled, not manifest-arm'd (settled 2c2f905c) -- the
    # ONE record-level invariant a replay parse still enforces for it is the
    # same one `0x13` gets: ordinals strictly increase. A real corrupt
    # resolution is caught by the gameplay hash chain instead (out of scope
    # for a replay VIEWER's codec, which only decodes-and-retains).
    var outOfOrder = sampleBallots()
    outOfOrder[1].ordinal = outOfOrder[0].ordinal
    expectReplayError("Replay ballot ordinals are not increasing"):
      discard ctfReplayCodec.parseCtfReplayBytes(
        completeReplay(ballots = outOfOrder),
        CtfReplaySpec, ReplayCompatibleGameVersions)

  test "call drop shift and code-hash alteration fail the seat arm":
    let
      valid = completeReplay()
      call = everyReflexCall().encodePlayCallRecord()
      shiftedCall = everyReflexCall(11).encodePlayCallRecord()
      alteredRecord = block:
        var altered = everyReflexCall()
        altered.entries[0].code = moduleIdentity("other wasm")
        altered.encodePlayCallRecord()
    for damaged in [
      valid.replace(call, ""),
      valid.replace(call, shiftedCall),
      valid.replace(call, alteredRecord),
    ]:
      expectReplayError("play-call manifest verification failed"):
        discard ctfReplayCodec.parseCtfReplayBytes(
          damaged, CtfReplaySpec, ReplayCompatibleGameVersions)

  test "transcript drop reorder edit and truncation all fail":
    let
      valid = completeReplay()
      first = sampleTranscript()[0].encodeLobbyChatRecord()
      second = sampleTranscript()[1].encodeLobbyChatRecord()
      edited = LobbyChatRecord(replayTimeMs: 8, ordinal: 1, seat: 0,
        team: 2, text: "rEady").encodeLobbyChatRecord()
    let damaged = [
      valid.replace(first, ""),
      valid.replace(first & second, second & first),
      valid.replace(first, edited),
      valid.replace(second, ""),
    ]
    for bytes in damaged:
      expect ReplayError:
        discard ctfReplayCodec.parseCtfReplayBytes(
          bytes, CtfReplaySpec, ReplayCompatibleGameVersions)

  test "annotation contributor drop and alteration fail its seat arm":
    let
      valid = completeReplay()
      accepted = acceptedAnnotation().encodeAnnotationRecord()
      droppedContributor = block:
        var changed = acceptedAnnotation()
        changed.provenance.overlays.setLen(0)
        changed.encodeAnnotationRecord()
      alteredContributor = block:
        var changed = acceptedAnnotation()
        changed.provenance.overlays[0].policySha256 = sha256Hex("changed")
        changed.encodeAnnotationRecord()
    for damaged in [
      valid.replace(accepted, droppedContributor),
      valid.replace(accepted, alteredContributor),
    ]:
      expectReplayError("annotation manifest verification failed"):
        discard ctfReplayCodec.parseCtfReplayBytes(
          damaged, CtfReplaySpec, ReplayCompatibleGameVersions)

  test "same-time stream ordering is enforced around lobby and calls":
    let
      call = everyReflexCall(10).encodePlayCallRecord()
      lobby = LobbyChatRecord(replayTimeMs: 10, ordinal: 1, seat: 0,
        team: 0, text: "late").encodeLobbyChatRecord()
      manifest = buildShellReplayManifest(
        @[@[call], newSeq[string]()],
        @[newSeq[string](), newSeq[string]()],
        @[lobby]).encodeManifestRecord()
      wrong = format2Header(shellConfig()) & call & lobby & manifest
    expectReplayError("same-time record ordering violation"):
      discard ctfReplayCodec.parseCtfReplayBytes(
        wrong, CtfReplaySpec, ReplayCompatibleGameVersions)

  test "lifecycle file arms use the playback tracker":
    let
      disconnect = LifecycleRecord(kind: lrDisconnect,
        replayTimeMs: 7, seat: 1).encodeLifecycleRecord()
      rebind = LifecycleRecord(kind: lrRebind,
        replayTimeMs: 8, seat: 1).encodeLifecycleRecord()
      manifest = buildShellReplayManifest(
        @[newSeq[string](), newSeq[string]()],
        @[newSeq[string](), newSeq[string]()],
        newSeq[string]()).encodeManifestRecord()
      bytes = format2Header(shellConfig()) & disconnect & rebind & manifest
      detailed = ctfReplayCodec.parseCtfReplayBytes(
        bytes, CtfReplaySpec, ReplayCompatibleGameVersions)
    check detailed.shell.lifecycle.len == 2
    var forged = bytes.replace(rebind,
      LifecycleRecord(kind: lrRebind, replayTimeMs: 8,
        seat: 0).encodeLifecycleRecord())
    expectReplayError("invalid lifecycle record"):
      discard ctfReplayCodec.parseCtfReplayBytes(
        forged, CtfReplaySpec, ReplayCompatibleGameVersions)

  test "high-bit shell times stay ordered in the unsigned domain":
    let calls = @[
      everyReflexCall(0x7fff_ffff'u32),
      everyReflexCall(0x8000_0000'u32)]
    let detailed = ctfReplayCodec.parseCtfReplayBytes(
      completeReplay(calls = calls, annotations = @[], transcript = @[]),
      CtfReplaySpec, ReplayCompatibleGameVersions)
    check detailed.shell.calls[1].replayTimeMs == 0x8000_0000'u32

suite "CTF-owned replay writer":
  test "format 2 is selected only by the explicit shell decision":
    let base = getTempDir() / ("shell-replay-writer-" &
      $getCurrentProcessId())
    let legacyPath = base & "-legacy.bitreplay"
    let ctfPath = base & "-ctf.bitreplay"
    let allInputPath = base & "-all-input.bitreplay"
    let shellPath = base & "-shell.bitreplay"
    try:
      var legacy = replayCodec.openReplayWriter(
        legacyPath, "{}", CtfReplaySpec)
      legacy.writeInput(ReplayInput(time: 3, player: 0, keys: 4))
      legacy.closeReplayWriter()

      var delegated = ctfReplayCodec.openReplayWriter(
        ctfPath, "{}", CtfReplaySpec, shellEpisode = false)
      delegated.writeInput(ReplayInput(time: 3, player: 0, keys: 4))
      delegated.closeReplayWriter()
      check readFile(ctfPath) == readFile(legacyPath)

      var allInput = ctfReplayCodec.openReplayWriter(
        allInputPath,
        "{\"season2Shell\":true,\"slots\":[" &
          "{\"control\":\"input\"}]}",
        CtfReplaySpec, shellEpisode = false)
      allInput.closeReplayWriter()
      check readFile(allInputPath)[8].uint8 == 1'u8

      var shell = ctfReplayCodec.openReplayWriter(
        shellPath, shellConfig(), CtfReplaySpec,
        shellEpisode = true, shellSeatCount = 2,
        openedAtMs = 1_735_689_600_000'u64)
      shell.writeLobbyChat(sampleTranscript()[0])
      shell.writePlayCall(everyReflexCall())
      shell.writeAnnotation(acceptedAnnotation())
      shell.closeReplayWriter()
      let bytes = readFile(shellPath)
      check bytes[8].uint8 == 2'u8
      check ctfReplayCodec.parseCtfReplayBytes(
        bytes, CtfReplaySpec, ReplayCompatibleGameVersions
      ).shell.manifestVerified
    finally:
      for path in [legacyPath, ctfPath, allInputPath, shellPath]:
        if fileExists(path):
          removeFile(path)

  test "live decision writer round trips every shell stream and one manifest":
    let path = getTempDir() / ("shell-live-roundtrip-" &
      $getCurrentProcessId() & ".bitreplay")
    var config = defaultGameConfig()
    config.season2Shell = true
    config.slots = @[
      PlayerSlotConfig(name: "play", control: scPlay),
      PlayerSlotConfig(name: "input", control: scInput)]
    try:
      var writer = replays.openReplayWriter(
        path, config.configJson(), openedAtMs = 1_735_689_600_000'u64)
      check writer.shellEpisode
      writer.writeJoin(0, 0, "play", 0, "")
      writer.writeJoin(0, 1, "input", 1, "")
      # Exercise the live server's incidental call order: phase-2 input can
      # arrive before phase-1 lifecycle, and a call before lobby transcript.
      # The CTF writer must flush the timestamp in canonical phase order.
      writer.writeInput(ReplayInput(time: 7, player: 1, keys: 0))
      writer.writeLifecycle(LifecycleRecord(
        kind: lrDisconnect, replayTimeMs: 7, seat: 1))
      writer.writePlayCall(everyReflexCall(8))
      writer.writeLobbyChat(LobbyChatRecord(
        replayTimeMs: 8, ordinal: 1, seat: 0, team: 2, text: "ready"))
      writer.writeAnnotation(acceptedAnnotation(9))
      writer.closeReplayWriter()
      writer.closeReplayWriter() # Idempotent close cannot append a manifest.

      let
        bytes = readFile(path)
        detailed = loadCtfReplay(path)
      check detailed.replay.joins.len == 2
      check detailed.replay.inputs.len == 1
      check detailed.shell.lifecycle == @[LifecycleRecord(
        kind: lrDisconnect, replayTimeMs: 7, seat: 1)]
      check detailed.shell.lobbyTranscript == @[sampleTranscript()[0]]
      check detailed.shell.calls.len == 1
      check detailed.shell.annotations == @[acceptedAnnotation(9)]
      check detailed.shell.manifestVerified
      check detailed.shell.manifest.seats[0].callCount == 1
      check detailed.shell.manifest.seats[0].annotationCount == 1
      check detailed.shell.manifest.transcriptCount == 1

      # Gate 2 negative controls run against bytes produced through the live
      # selection wrapper, not a synthetic codec-only aggregate.
      for damaged in [
        bytes.replace(everyReflexCall(8).encodePlayCallRecord(), ""),
        bytes.replace(sampleTranscript()[0].encodeLobbyChatRecord(), ""),
        bytes.replace(acceptedAnnotation(9).encodeAnnotationRecord(), ""),
      ]:
        expect ReplayError:
          discard ctfReplayCodec.parseCtfReplayBytes(
            damaged, CtfReplaySpec, ReplayCompatibleGameVersions)
    finally:
      if fileExists(path):
        removeFile(path)

suite "shell lifecycle replay presence":
  test "disconnect and lobby rebind survive keyframes and seeks without compaction":
    var config = defaultGameConfig()
    config.season2Shell = true
    config.minPlayers = 3 # Keep the two recorded seats in Lobby for rebind.
    config.slots = @[
      PlayerSlotConfig(name: "play", control: scPlay),
      PlayerSlotConfig(name: "input", control: scInput),
      PlayerSlotConfig(name: "waiting", control: scInput)]
    let detailed = CtfReplayData(
      replay: ReplayData(
        configJson: config.configJson(),
        joins: @[
          ReplayJoin(time: 0, player: 0, name: "play", slot: 0),
          ReplayJoin(time: 0, player: 1, name: "input", slot: 1)],
        # A final-only hash supplies the deterministic scan horizon. Its value
        # is deliberately not reached by either assertion below.
        hashes: @[ReplayHash(tick: 150, hash: 0)]),
      shell: ShellReplayRecords(lifecycle: @[
        LifecycleRecord(kind: lrDisconnect,
          replayTimeMs: tickTime(10), seat: 1),
        LifecycleRecord(kind: lrRebind,
          replayTimeMs: tickTime(110), seat: 1)]))
    var
      replay = initReplayPlayer(detailed)
      simServer = initSimServer(config)
    replay.buildReplayKeyframes(simServer, interval = 25)

    replay.seekReplay(simServer, 50)
    check simServer.players.len == 2
    check simServer.players[0].address == "play"
    check simServer.players[1].address == "input"
    check replay.lifecyclePlayback.presence(1) == spReconnectable
    let abandonedIndex = simServer.rewardAccountForPlayer(1)
    check abandonedIndex >= 0
    check simServer.rewardAccounts[abandonedIndex].abandoned

    replay.seekReplay(simServer, 130)
    check simServer.players.len == 2
    check simServer.players[1].joinOrder == 1
    check replay.lifecyclePlayback.presence(1) == spConnected
    let reboundIndex = simServer.rewardAccountForPlayer(1)
    check reboundIndex >= 0
    check not simServer.rewardAccounts[reboundIndex].abandoned

suite "playbook archive":
  test "content-addressed modules verify against recorded hashes":
    let replayPath = getTempDir() / ("shell-archive-" &
      $getCurrentProcessId() & ".bitreplay")
    let archiveDir = replayPath.playbookArchiveDir()
    if dirExists(archiveDir):
      removeDir(archiveDir)
    try:
      let
        recorded = ctfReplayCodec.parseCtfReplayBytes(
          completeReplay(), CtfReplaySpec,
          ReplayCompatibleGameVersions).shell.moduleHashes()
        moduleHash = writePlaybookModule(replayPath, "pact wasm")
      check recorded == @[moduleHash]
      check readPlaybookModule(replayPath, moduleHash) == "pact wasm"
      writePlaybookManifest(replayPath, recorded)
      check readPlaybookManifest(replayPath) == recorded
      verifyPlaybookArchive(replayPath, recorded)
      writeFile(archiveDir / (moduleHash & ".wasm"), "corrupt")
      expectArchiveError:
        verifyPlaybookArchive(replayPath, @[moduleHash])
    finally:
      if dirExists(archiveDir):
        removeDir(archiveDir)
