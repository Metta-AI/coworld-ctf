## Phase P3-19: FIRST LIGHT episode owns the optional ladder path.

import std/[algorithm, options, os, osproc, sequtils, strformat,
  strutils, unittest]

import bitworld/spriteprotocol

import ../src/ctf/sim_types
import ../src/shell/[body, body_map, default_play, episode, standing_order,
  wasmtime_c]

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

proc leb(value: int): string =
  var remaining = value
  while true:
    var byte = remaining and 0x7f
    remaining = remaining shr 7
    if remaining != 0:
      byte = byte or 0x80
    result.add char(byte)
    if remaining == 0:
      break

proc padded(wasm: string): string =
  ## Avoids the known raw-bytes x8/no-floor cacheFull behavior so this test
  ## isolates live self-position propagation, not admission accounting.
  result = wasm
  if result.len >= 64 * 1024:
    return
  let name = "p21_cache_padding"
  let payload = char(name.len) & name & repeat('\0', 64 * 1024 - result.len)
  result.add '\0'
  result.add payload.len.leb
  result.add payload

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
  writeFile(path, wat.watBytes.padded)

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

proc probeConfig(modulePath: string): FirstLightPlayConfig =
  FirstLightPlayConfig(
    modulePath: modulePath,
    playName: "current_self_probe",
    paramsBytes: "{}",
    seats: @[0],
    uploadIdBase: 90_000,
    proposalIdBase: 91_000,
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
      self: BodySelfState(pos: pos, hpFrac: 1.0, aimBrads: 32,
        alive: true, carrying: false)),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 512, h: 256),
      nextZone: MapRect(x: 100, y: 50, w: 200, h: 100),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zoneDps: 1,
      idleAimCenterBrads: 32,
      coverGoal: none(ValidatedGoal)))

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

suite "shell episode ladder":
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
