## Phase P3-19: FIRST LIGHT episode owns the optional ladder path.

import std/[algorithm, json, options, os, osproc, sequtils, strformat,
  strutils, unittest]

import bitworld/spriteprotocol

import ../src/ctf/sim_types
import ../src/shell/[body, body_map, canonical, default_play, episode,
  replay_records, standing_order, reflexes, types, wasmtime_c]

const
  Seats = 32
  WarmTicks = 30
  Samples = 30
  RuntimeGateNs = 4_000_000'i64
  EdgeRideSource = "play_sdk" / "reference" / "edge_ride.nim"
  EdgeRideWasm = "play_sdk" / ".build" / "edge_ride.wasm"

proc parseToolPath(output, key: string): string =
  for line in output.splitLines:
    if line.startsWith(key & "="):
      return line[(key.len + 1) .. ^1]

proc toolPath(key: string): string =
  result = getEnv(key)
  if result.len > 0:
    return
  let fetched = execCmdEx("tools/runtime_spike/fetch_deps.sh")
  require fetched.exitCode == 0
  result = parseToolPath(fetched.output, key)
  require result.len > 0

proc buildEdgeRideWasm() =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(EdgeRideSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(EdgeRideWasm)

proc watEscape(bytes: string): string =
  const Hex = "0123456789abcdef"
  for ch in bytes:
    let value = ord(ch)
    result.add '\\'
    result.add Hex[(value shr 4) and 0xf]
    result.add Hex[value and 0xf]

proc watBytes(text: string): string =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  require error == nil
  defer: wasmByteVecDelete(addr output)
  result = newString(output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc writeCurrentSelfProbeWasm(path: string) =
  let manifest =
    "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"current_self_probe\",\"params\":{},\"retune\":true}"
  let intent =
    "{\"arrive_radius\":24.0,\"kind\":\"navigate_to\"," &
    "\"point\":[650,30],\"reason\":\"current_self_probe\"," &
    "\"schema\":\"intent\",\"v\":1}"
  let wat = "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
    "  (import \"play\" \"nearest_reachable\" " &
      "(func $nearest_reachable (param i32 i32) (result i64)))\n" &
    "  (import \"play\" \"nearest_cover\" " &
      "(func $nearest_cover (param i32 i32 i32 i32 i32 i32) (result i64)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (data (i32.const 512) \"" & intent.watEscape & "\")\n" &
    "  (global $heap (mut i32) (i32.const 4096))\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32) " &
      "global.get $heap global.get $heap local.get $len i32.add " &
      "global.set $heap)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      "i32.const 512 i32.const " & $intent.len & " call $emit drop " &
      "i32.const 0)\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0))"
  writeFile(path, wat.watBytes)

proc writeStepTrapWasm(path: string) =
  let manifest =
    "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"step_trap\",\"params\":{},\"retune\":true}"
  let wat = "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (global $heap (mut i32) (i32.const 4096))\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32) " &
      "global.get $heap global.get $heap local.get $len i32.add " &
      "global.set $heap)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      "unreachable)\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0))"
  writeFile(path, wat.watBytes)

proc writeRetuneRefuseWasm(path: string) =
  let manifest =
    "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"retune_refuse\",\"params\":{\"bias\":{\"default\":0," &
    "\"kind\":\"number\",\"max\":10,\"min\":0}},\"retune\":true}"
  let wat = "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (global $heap (mut i32) (i32.const 4096))\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32) " &
      "global.get $heap global.get $heap local.get $len i32.add " &
      "global.set $heap)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 1))"
  writeFile(path, wat.watBytes)

proc writeNamedNoopWasm(path, playName, salt: string) =
  let manifest =
    "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"" & playName & "\",\"params\":{},\"retune\":true}"
  let wat = "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (data (i32.const 1024) \"" & salt.watEscape & "\")\n" &
    "  (global $heap (mut i32) (i32.const 4096))\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32) " &
      "global.get $heap global.get $heap local.get $len i32.add " &
      "global.set $heap)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0))"
  writeFile(path, wat.watBytes)

proc playConfig(seats: seq[int]; coverBias = "0.0"): FirstLightPlayConfig =
  FirstLightPlayConfig(
    modulePath: EdgeRideWasm,
    playName: "edge_ride",
    paramsBytes: "{\"coverBias\":" & coverBias &
      ",\"enterLead\":120,\"margin\":100}",
    seats: seats,
    uploadIdBase: 70_000,
    proposalIdBase: 80_000,
    originGeneration: 1)

proc edgeRideCallBytes(coverBias = "0.0"; retune = false): string =
  let retuneField = if retune: ",\"retune\":true" else: ""
  canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"edge_ride\"," &
    "\"params\":{\"coverBias\":" & coverBias &
    ",\"enterLead\":120,\"margin\":100},\"play\":\"edge_ride\"" &
    retuneField & "}]}"))

proc trapCallBytes(): string =
  canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"step_trap\"," &
    "\"params\":{},\"play\":\"step_trap\"}]}"))

proc retuneRefuseCallBytes(bias: int; retune = false): string =
  let retuneField = if retune: ",\"retune\":true" else: ""
  canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"retune_refuse\"," &
    "\"params\":{\"bias\":" & $bias & "},\"play\":\"retune_refuse\"" &
    retuneField & "}]}"))

proc namedNoopCallBytes(playName: string): string =
  canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"" & playName &
    "\",\"params\":{},\"play\":\"" & playName & "\"}]}"))

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  if text.len > 0:
    copyMem(addr result[0], unsafeAddr text[0], text.len)

proc probeConfig(modulePath: string): FirstLightPlayConfig =
  FirstLightPlayConfig(
    modulePath: modulePath,
    playName: "current_self_probe",
    paramsBytes: "{}",
    seats: @[0],
    uploadIdBase: 90_000,
    proposalIdBase: 91_000,
    originGeneration: 1)

proc retuneRefuseConfig(modulePath: string): FirstLightPlayConfig =
  FirstLightPlayConfig(
    modulePath: modulePath,
    playName: "retune_refuse",
    paramsBytes: "{\"bias\":0}",
    seats: @[0],
    uploadIdBase: 160_000,
    proposalIdBase: 161_000,
    originGeneration: 1)

proc namedNoopConfig(modulePath, playName: string; seats: seq[int]):
    FirstLightPlayConfig =
  FirstLightPlayConfig(
    modulePath: modulePath,
    playName: playName,
    paramsBytes: "{}",
    seats: seats,
    uploadIdBase: 170_000,
    proposalIdBase: 171_000,
    originGeneration: 1)

proc controls(count: int): seq[SlotControl] =
  result = newSeq[SlotControl](count)
  for control in result.mitems:
    control = scPlay

proc testMap(): BodyMap =
  const
    Width = 512
    Height = 256
  var walkable = newSeq[bool](Width * Height)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Width, Height, 1, @[(20, 128), (480, 128)])

proc splitRoomsMap(): BodyMap =
  const
    Width = 720
    Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc frame(seat: int; pos: BodyPoint; tick: int): FirstLightSeatFrame =
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: true,
    alive: true,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: pos, hp: 4, hpFrac: 1.0, aimBrads: 32,
        alive: true, carrying: false)),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 4096, h: 4096),
      nextZone: MapRect(x: 100, y: 50, w: 200, h: 100),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zoneDps: 1,
      idleAimCenterBrads: 32,
      coverGoal: none(ValidatedGoal)))

proc floodFrame(seat: int; pos: BodyPoint; tick: int): FirstLightSeatFrame =
  result = frame(seat, pos, tick)
  result.defaultFallbacks.currentZone = MapRect(x: 100, y: 50, w: 200, h: 100)
  result.defaultFallbacks.nextZone = MapRect(x: 160, y: 70, w: 120, h: 80)
  result.defaultFallbacks.ticksToNextShrink = ReflexZoneTriggerTicks
  result.motionScale = MotionScale
  result.velocity = MaxSpeed

proc applyMask(pos: var BodyPoint; input: InputState) =
  let bits = input.encodeInputMask()
  if (bits and ButtonLeft) != 0:
    dec pos.x, 4
  if (bits and ButtonRight) != 0:
    inc pos.x, 4
  if (bits and ButtonUp) != 0:
    dec pos.y, 4
  if (bits and ButtonDown) != 0:
    inc pos.y, 4

proc percentile(values: seq[int64], numerator, denominator: int): int64 =
  values[min(values.high,
    (values.len * numerator + denominator - 1) div denominator - 1)]

proc waitReady(episode: var FirstLightEpisode; seat: int; uploadId: uint64;
               startTick: var int; pos: var BodyPoint): StatusEntry =
  while startTick <= 5000:
    let output = episode.step([frame(seat, pos, startTick)], uint32(startTick))
    check output.masks.len == 1
    pos.applyMask(output.masks[0].input)
    for status in output.moduleStatuses:
      if status.seat == seat and status.uploadId == uploadId and
          status.status.kind == skModuleReady:
        result = status.status
        inc startTick
        return
    sleep(1)
    inc startTick
  fail()

proc waitReadyMany(episode: var FirstLightEpisode;
                   expected: openArray[tuple[seat: int, uploadId: uint64]];
                   startTick: var int;
                   positions: var seq[BodyPoint]): seq[StatusEntry] =
  var seen = newSeq[bool](expected.len)
  result = newSeq[StatusEntry](expected.len)
  while startTick <= 5000:
    var batch: seq[FirstLightSeatFrame]
    for seat in 0 ..< positions.len:
      batch.add frame(seat, positions[seat], startTick)
    let output = episode.step(batch, uint32(startTick))
    check output.masks.len == positions.len
    for mask in output.masks:
      positions[mask.seat.int].applyMask(mask.input)
    for status in output.moduleStatuses:
      for index, item in expected:
        if not seen[index] and status.seat == item.seat and
            status.uploadId == item.uploadId and
            status.status.kind == skModuleReady:
          seen[index] = true
          result[index] = status.status
    if seen.allIt(it):
      inc startTick
      return
    sleep(1)
    inc startTick
  fail()

suite "shell episode ladder":
  test "final zone phase sentinel is representable in episode binary view":
    when ShellRuntimeAvailable:
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      var row = frame(0, (128, 128), 3361)
      row.defaultFallbacks.zonePhase = 5
      row.defaultFallbacks.currentZone = MapRect(x: 280, y: 28, w: 87, h: 43)
      row.defaultFallbacks.nextZone = row.defaultFallbacks.currentZone
      row.defaultFallbacks.zoneDps = 12
      row.defaultFallbacks.ticksToNextShrink = high(int) div 4

      let output = episode.step([row], 3361)
      check output.masks.len == 1
      let bytes = episode.firstLightViewBytes(0, 3361)
      check bytes.len > 0
      check bytes != "{}"

  test "live episode arms zone reflex above the default":
    let map = testMap()
    var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
    defer:
      episode.closeFirstLightEpisode()

    let output = episode.step([floodFrame(0, (20, 128), 1)], 1)
    check output.masks.len == 1
    check output.installs.anyIt(it.provenance == "reflex:zone_escape" and
      it.rule == ReflexZoneEscapeName and
      it.bytes.contains("\"reason\":\"reflex_zone_escape\"") and
      it.bytes.contains("\"kind\":\"navigate_to\""))

  test "runtime host calls validate against current frame self position":
    let modulePath = getTempDir() / "current-self-probe-" &
      $getCurrentProcessId() & ".wasm"
    writeCurrentSelfProbeWasm(modulePath)
    defer:
      if fileExists(modulePath):
        removeFile(modulePath)

    let map = splitRoomsMap()
    var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
    defer:
      episode.closeFirstLightEpisode()
    let configLines = episode.configureFirstLightPlay(probeConfig(modulePath))
    check configLines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL seat=0") and
      it.contains("accepted=true"))

    let oldRoom = episode.step([frame(0, (30, 30), 1)], 1)
    check oldRoom.installs.allIt(it.provenance !=
      "entry:current_self_probe")

    let newRoom = episode.step([frame(0, (650, 30), 2)], 2)
    check newRoom.installs.anyIt(it.provenance == "entry:current_self_probe" and
      it.bytes.contains("\"point\":[650,30]") and
      it.bytes.contains("\"reason\":\"current_self_probe\""))

  test "real edge_ride wasm drives a real episode tick and differs from default":
    buildEdgeRideWasm()
    let map = testMap()
    var defaultEpisode = initFirstLightEpisode(true, true, controls(1), map, 331)
    var playEpisode = initFirstLightEpisode(true, true, controls(1), map, 331)
    defer:
      defaultEpisode.closeFirstLightEpisode()
      playEpisode.closeFirstLightEpisode()

    let configLines = playEpisode.configureFirstLightPlay(playConfig(@[0]))
    check configLines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL seat=0") and
      it.contains("accepted=true"))

    var
      defaultPos: BodyPoint = (20, 128)
      playPos: BodyPoint = (20, 128)
      sawEntryInstall = false
      sawDifferentMask = false
    for tick in 1 .. 40:
      let defaultOutput = defaultEpisode.step([frame(0, defaultPos, tick)],
        uint32(tick))
      let playOutput = playEpisode.step([frame(0, playPos, tick)],
        uint32(tick))
      check defaultOutput.masks.len == 1
      check playOutput.masks.len == 1
      sawEntryInstall = sawEntryInstall or
        playOutput.installs.anyIt(it.provenance == "entry:edge_ride" and
          it.bytes.contains("edge_ride:margin"))
      if defaultOutput.masks[0].input.encodeInputMask() !=
          playOutput.masks[0].input.encodeInputMask():
        sawDifferentMask = true
      defaultPos.applyMask(defaultOutput.masks[0].input)
      playPos.applyMask(playOutput.masks[0].input)
    check sawEntryInstall
    check sawDifferentMask

  test "live admission seam drives upload, commit, call, and body install":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let admitted = episode.admitPlayModule(0, 120_000, 1,
        readFile(EdgeRideWasm).bytesOf)
      check admitted.accepted
      check admitted.reason == ""
      check admitted.status.kind == skModuleAccepted
      check admitted.statusBytes.len > 0

      var
        tick = 1
        pos: BodyPoint = (20, 128)
        sawReady = false
      while tick <= 5000 and not sawReady:
        let output = episode.step([frame(0, pos, tick)], uint32(tick))
        check output.masks.len == 1
        pos.applyMask(output.masks[0].input)
        for status in output.moduleStatuses:
          if status.seat == 0 and status.uploadId == 120_000:
            check status.terminal == "tkReady"
            check status.status.kind == skModuleReady
            check status.status.name == "edge_ride"
            check status.statusBytes.len > 0
            sawReady = true
        if not sawReady:
          sleep(1)
        inc tick
      check sawReady

      let accepted = episode.acceptPlayCall(0, 121_000, 1, uint32(tick),
        edgeRideCallBytes())
      check accepted.accepted
      check accepted.reason == ""
      check accepted.epoch == 1
      check accepted.status.kind == skCallAccepted
      check accepted.statusBytes.len > 0

      var sawEntryInstall = false
      for offset in 0 .. 20:
        let output = episode.step([frame(0, pos, tick + offset)],
          uint32(tick + offset))
        check output.masks.len == 1
        sawEntryInstall = sawEntryInstall or
          output.installs.anyIt(it.provenance == "entry:edge_ride")
        pos.applyMask(output.masks[0].input)
      check sawEntryInstall

  test "live admission upload quota resets on the episode tick":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let wasmBytes = readFile(EdgeRideWasm).bytesOf
      let first = episode.admitPlayModule(0, 130_000, 1, wasmBytes)
      check first.accepted
      check first.status.kind == skModuleAccepted
      let sameTick = episode.admitPlayModule(0, 130_001, 1, wasmBytes)
      check not sameTick.accepted
      check sameTick.reason == "tickUploadLimit"

      let output = episode.step([frame(0, (20, 128), 1)], 1)
      check output.masks.len == 1
      let nextTick = episode.admitPlayModule(0, 130_001, 1, wasmBytes)
      check nextTick.accepted
      check nextTick.status.kind == skModuleAccepted

  test "accepted call replay identity builds the landed play-call record":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let admitted = episode.admitPlayModule(0, 180_000, 1,
        readFile(EdgeRideWasm).bytesOf)
      check admitted.accepted
      var
        tick = 1
        pos: BodyPoint = (20, 128)
      let ready = episode.waitReady(0, 180_000, tick, pos)

      let accepted = episode.acceptPlayCall(0, 180_100, 1, uint32(tick),
        edgeRideCallBytes())
      check accepted.accepted
      check accepted.replayIdentity.isSome
      let identity = accepted.replayIdentity.get
      check identity.seat == 0
      check identity.epoch == accepted.epoch
      check identity.ladderBytes == edgeRideCallBytes()
      check identity.entries.len == 1
      check identity.entries[0].entryId == "edge_ride"
      check identity.entries[0].code.kind == cikModule
      check identity.entries[0].code.moduleSha256 == ready.sha256

      let record = identity.toPlayCallRecord(12_345)
      let encoded = record.encodePlayCallRecord()
      let decoded = encoded.decodePlayCallRecord()
      check encoded[0].uint8 == readFile(
        "tests" / "fixtures" / "shell" / "replay" / "play-call.bin")[0].uint8
      check decoded.seat == identity.seat
      check decoded.epoch == identity.epoch
      check decoded.ladderBytes == identity.ladderBytes
      check decoded.entries == identity.entries
      check decoded.contentSha256 == sha256Hex(encoded)
      check identity.contentSha256 == identity.toPlayCallRecord(0).contentSha256

  test "config and wire accept paths surface identical replay identity":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var configEpisode = initFirstLightEpisode(true, true, controls(1),
        map, 331)
      var wireEpisode = initFirstLightEpisode(true, true, controls(1),
        map, 331)
      defer:
        configEpisode.closeFirstLightEpisode()
        wireEpisode.closeFirstLightEpisode()

      let config = playConfig(@[0])
      let legacyLines = configEpisode.configureFirstLightPlay(config)
      var richEpisode = initFirstLightEpisode(true, true, controls(1),
        map, 331)
      defer:
        richEpisode.closeFirstLightEpisode()
      let rich = richEpisode.configureFirstLightPlayWithReplayIdentities(config)
      check rich.lines == legacyLines
      check rich.callIdentities.len == 1

      let admitted = wireEpisode.admitPlayModule(0, 181_000, 1,
        readFile(EdgeRideWasm).bytesOf)
      check admitted.accepted
      var
        tick = 1
        pos: BodyPoint = (20, 128)
      discard wireEpisode.waitReady(0, 181_000, tick, pos)
      let accepted = wireEpisode.acceptPlayCall(0, 181_100, 1, 0,
        edgeRideCallBytes())
      check accepted.accepted
      check accepted.replayIdentity.isSome
      check accepted.replayIdentity.get == rich.callIdentities[0]

  test "same play name on two seats reports each bound module hash":
    when ShellRuntimeAvailable:
      let
        playName = "collision_play"
        moduleA = getTempDir() / "collision-a-" &
          $getCurrentProcessId() & ".wasm"
        moduleB = getTempDir() / "collision-b-" &
          $getCurrentProcessId() & ".wasm"
      writeNamedNoopWasm(moduleA, playName, "module-a")
      writeNamedNoopWasm(moduleB, playName, "module-b")
      defer:
        if fileExists(moduleA):
          removeFile(moduleA)
        if fileExists(moduleB):
          removeFile(moduleB)

      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(2), map, 331)
      defer:
        episode.closeFirstLightEpisode()
      check episode.admitPlayModule(0, 182_000, 1,
        readFile(moduleA).bytesOf).accepted
      check episode.admitPlayModule(1, 182_001, 1,
        readFile(moduleB).bytesOf).accepted

      var
        tick = 1
        positions = @[(20, 128), (480, 128)]
      let ready = episode.waitReadyMany(
        [(seat: 0, uploadId: 182_000'u64),
         (seat: 1, uploadId: 182_001'u64)],
        tick, positions)
      check ready[0].sha256.len == 64
      check ready[1].sha256.len == 64
      check ready[0].sha256 != ready[1].sha256

      let call = namedNoopCallBytes(playName)
      let seat0 = episode.acceptPlayCall(0, 182_100, 1, uint32(tick), call)
      let seat1 = episode.acceptPlayCall(1, 182_101, 1, uint32(tick), call)
      check seat0.accepted
      check seat1.accepted
      check seat0.replayIdentity.isSome
      check seat1.replayIdentity.isSome
      check seat0.replayIdentity.get.entries[0].code.moduleSha256 ==
        ready[0].sha256
      check seat1.replayIdentity.get.entries[0].code.moduleSha256 ==
        ready[1].sha256

  test "rejected call surfaces no replay identity":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()
      let rich = episode.configureFirstLightPlayWithReplayIdentities(
        playConfig(@[0]))
      check rich.callIdentities.len == 1
      let rejected = episode.acceptPlayCall(0, 183_000, 1, 0,
        canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"missing\"," &
          "\"params\":{},\"play\":\"missing\"}]}")))
      check not rejected.accepted
      check rejected.replayIdentity.isNone

  test "config path surfaces one replay identity per configured play seat":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(2), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let config = playConfig(@[0, 1])
      let rich = episode.configureFirstLightPlayWithReplayIdentities(config)
      check rich.lines.countIt(it.contains("FIRST_LIGHT_PLAY_UPLOAD")) == 2
      check rich.lines.countIt(it.contains("FIRST_LIGHT_PLAY_COMMIT")) == 2
      check rich.lines.countIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true")) == 2
      check rich.callIdentities.len == 2
      check rich.callIdentities[0].seat == 0
      check rich.callIdentities[1].seat == 1
      check rich.callIdentities.allIt(it.entries.len == 1 and
        it.entries[0].entryId == "edge_ride" and
        it.entries[0].code.kind == cikModule and
        it.contentSha256.len == 64)

  test "playFaulted status survives the episode standing-order filter":
    when ShellRuntimeAvailable:
      let modulePath = getTempDir() / "step-trap-" &
        $getCurrentProcessId() & ".wasm"
      writeStepTrapWasm(modulePath)
      defer:
        if fileExists(modulePath):
          removeFile(modulePath)

      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let admitted = episode.admitPlayModule(0, 140_000, 1,
        readFile(modulePath).bytesOf)
      check admitted.accepted

      var
        tick = 1
        pos: BodyPoint = (20, 128)
        sawReady = false
      while tick <= 5000 and not sawReady:
        let output = episode.step([frame(0, pos, tick)], uint32(tick))
        check output.masks.len == 1
        pos.applyMask(output.masks[0].input)
        sawReady = output.moduleStatuses.anyIt(it.seat == 0 and
          it.uploadId == 140_000 and it.status.kind == skModuleReady)
        if not sawReady:
          sleep(1)
        inc tick
      check sawReady

      let accepted = episode.acceptPlayCall(0, 140_100, 1, uint32(tick),
        trapCallBytes())
      check accepted.accepted
      let fault = episode.step([frame(0, pos, tick)], uint32(tick))
      check fault.ladderStatuses.anyIt(it.seat == 0 and
        it.entryId == "step_trap" and
        it.status.kind == skPlayFaulted and
        it.status.entryId == "step_trap" and
        it.statusBytes.len > 0)

  test "pending retunes report identities and complete exactly once":
    when ShellRuntimeAvailable:
      buildEdgeRideWasm()
      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let configLines = episode.configureFirstLightPlay(playConfig(@[0]))
      check configLines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL seat=0") and
        it.contains("accepted=true"))

      var pos: BodyPoint = (20, 128)
      let initialized = episode.step([frame(0, pos, 1)], 1)
      check initialized.masks.len == 1
      pos.applyMask(initialized.masks[0].input)

      let changed = episode.acceptPlayCall(0, 150_000, 2, 2,
        edgeRideCallBytes("0.5", retune = true))
      check changed.accepted
      check changed.pendingRetunes == @[
        FirstLightEntryIdentity(seat: 0, entryId: "edge_ride",
          play: "edge_ride")]

      var completions: seq[FirstLightEntryIdentity]
      for tick in 2 .. 10:
        let output = episode.step([frame(0, pos, tick)], uint32(tick))
        check output.ladderStatuses.allIt(it.status.kind != skRetuneRefused)
        completions.add output.retuned
        if output.masks.len == 1:
          pos.applyMask(output.masks[0].input)
      check completions == changed.pendingRetunes

  test "retune refusal completes pending retune once and is not doubled":
    when ShellRuntimeAvailable:
      let modulePath = getTempDir() / "retune-refuse-" &
        $getCurrentProcessId() & ".wasm"
      writeRetuneRefuseWasm(modulePath)
      defer:
        if fileExists(modulePath):
          removeFile(modulePath)

      let map = testMap()
      var episode = initFirstLightEpisode(true, true, controls(1), map, 331)
      defer:
        episode.closeFirstLightEpisode()

      let configLines = episode.configureFirstLightPlay(
        retuneRefuseConfig(modulePath))
      check configLines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL seat=0") and
        it.contains("accepted=true"))

      var pos: BodyPoint = (20, 128)
      let initialized = episode.step([frame(0, pos, 1)], 1)
      check initialized.masks.len == 1
      pos.applyMask(initialized.masks[0].input)

      let changed = episode.acceptPlayCall(0, 162_000, 2, 2,
        retuneRefuseCallBytes(1, retune = true))
      check changed.accepted
      check changed.pendingRetunes == @[
        FirstLightEntryIdentity(seat: 0, entryId: "retune_refuse",
          play: "retune_refuse")]

      var
        refusals: seq[FirstLightLadderStatus]
        successes: seq[FirstLightEntryIdentity]
      for tick in 2 .. 10:
        let output = episode.step([frame(0, pos, tick)], uint32(tick))
        for status in output.ladderStatuses:
          if status.status.kind == skRetuneRefused:
            refusals.add status
        successes.add output.retuned
        if output.masks.len == 1:
          pos.applyMask(output.masks[0].input)

      check successes.len == 0
      check refusals.len == 1
      check refusals[0].seat == 0
      check refusals[0].entryId == "retune_refuse"
      check refusals[0].status.entryId == "retune_refuse"
      check refusals[0].statusBytes.len > 0

  test "32 configured play seats stay inside the runtime sub-allocation":
    buildEdgeRideWasm()
    let map = testMap()
    var episode = initFirstLightEpisode(true, true, controls(Seats), map, 331)
    defer:
      episode.closeFirstLightEpisode()
    var seats: seq[int]
    for seat in 0 ..< Seats:
      seats.add seat
    let configLines = episode.configureFirstLightPlay(playConfig(seats))
    check configLines.countIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
      it.contains("accepted=true")) == Seats

    var positions: array[Seats, BodyPoint]
    for seat in 0 ..< Seats:
      positions[seat] = (20 + seat, 128)
    for tick in 1 .. WarmTicks:
      var batch: seq[FirstLightSeatFrame]
      for seat in 0 ..< Seats:
        batch.add frame(seat, positions[seat], tick)
      let output = episode.step(batch, uint32(tick))
      for mask in output.masks:
        positions[mask.seat.int].applyMask(mask.input)

    var runtimeSamples: seq[int64]
    for tick in WarmTicks + 1 .. WarmTicks + Samples:
      var batch: seq[FirstLightSeatFrame]
      for seat in 0 ..< Seats:
        batch.add frame(seat, positions[seat], tick)
      let output = episode.step(batch, uint32(tick))
      check output.masks.len == Seats
      for mask in output.masks:
        positions[mask.seat.int].applyMask(mask.input)
      runtimeSamples.add output.runtimeNanoseconds
    runtimeSamples.sort()

    let pass = runtimeSamples[^1] <= RuntimeGateNs
    echo &"EPISODE_LADDER_RUNTIME seats={Seats} warm_ticks={WarmTicks} " &
      &"samples={Samples} median_us=" &
      &"{runtimeSamples.percentile(50, 100).float / 1000.0:.3f} " &
      &"p95_us={runtimeSamples.percentile(95, 100).float / 1000.0:.3f} " &
      &"max_us={runtimeSamples[^1].float / 1000.0:.3f} " &
      "gate_us=4000.000 " & (if pass: "verdict=PASS" else: "verdict=FAIL")
    check pass

  test "32 flood-zone seats with reflexes armed stay inside runtime share":
    let map = testMap()
    var episode = initFirstLightEpisode(true, true, controls(Seats), map, 331)
    defer:
      episode.closeFirstLightEpisode()

    var positions: array[Seats, BodyPoint]
    for seat in 0 ..< Seats:
      positions[seat] = (20 + seat, 128)
    var sawReflexInstall = false
    for tick in 1 .. WarmTicks:
      var batch: seq[FirstLightSeatFrame]
      for seat in 0 ..< Seats:
        batch.add floodFrame(seat, positions[seat], tick)
      let output = episode.step(batch, uint32(tick))
      check output.masks.len == Seats
      sawReflexInstall = sawReflexInstall or
        output.installs.anyIt(it.provenance == "reflex:zone_escape")
      for mask in output.masks:
        positions[mask.seat.int].applyMask(mask.input)

    var runtimeSamples: seq[int64]
    for tick in WarmTicks + 1 .. WarmTicks + Samples:
      var batch: seq[FirstLightSeatFrame]
      for seat in 0 ..< Seats:
        batch.add floodFrame(seat, positions[seat], tick)
      let output = episode.step(batch, uint32(tick))
      check output.masks.len == Seats
      sawReflexInstall = sawReflexInstall or
        output.installs.anyIt(it.provenance == "reflex:zone_escape")
      for mask in output.masks:
        positions[mask.seat.int].applyMask(mask.input)
      runtimeSamples.add output.runtimeNanoseconds
    runtimeSamples.sort()

    let pass = runtimeSamples[^1] <= RuntimeGateNs
    echo &"EPISODE_REFLEX_RUNTIME seats={Seats} warm_ticks={WarmTicks} " &
      &"samples={Samples} median_us=" &
      &"{runtimeSamples.percentile(50, 100).float / 1000.0:.3f} " &
      &"p95_us={runtimeSamples.percentile(95, 100).float / 1000.0:.3f} " &
      &"max_us={runtimeSamples[^1].float / 1000.0:.3f} " &
      "gate_us=4000.000 " & (if pass: "verdict=PASS" else: "verdict=FAIL")
    check sawReflexInstall
    check pass
