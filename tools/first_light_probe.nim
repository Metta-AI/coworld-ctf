## Deterministic FIRST LIGHT wiring/timing probe. It drives the concrete lane A
## FL-B body through hold/rotate/cover/partner changes, prints install telemetry
## and movement summaries, then measures 32 seats after 30 warm ticks.

import std/[algorithm, options, os, strformat, strutils]
import bitworld/spriteprotocol
import ../src/ctf/sim_types
import ../src/shell/[body, body_map, body_nav, body_planner, default_play,
  episode, standing_order]

when ShellRuntimeAvailable:
  import ../src/shell/[module_validation, runtime, types]

const
  Seats = 32
  WarmTicks = 30
  Samples = 120
  BodyGateNs = 5_000_000'i64
  RuntimeGateNs = 4_000_000'i64
  TelemetryTicks = 300
  InstallTelemetryTicks = 8

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir

proc probeMap(): BodyMap =
  const Side = 1024
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(100, 100)])

proc movementProbeMap(): BodyMap =
  const Side = 128
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(10, 10)])

proc dangerProbeMap(): BodyMap =
  const
    Width = 384
    Height = 160
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      let wall = x in 184 .. 200 and
        y notin 24 .. 40 and y notin 72 .. 88
      walkable[y * Width + x] = not wall
  newBodyMap(walkable, Width, Height, 1, @[(32, 80)])

proc controls(): seq[SlotControl] =
  result = newSeq[SlotControl](Seats)
  for control in result.mitems:
    control = scPlay

proc frame(tick, seat: int, map: BodyMap,
           positions: array[Seats, BodyPoint]): FirstLightSeatFrame =
  let self = positions[seat]
  var input = BodyTickInputs(
    self: BodySelfState(pos: self, hp: 4, hpFrac: 1.0,
      lives: some(1), aimBrads: seat * 7 mod 256, fireCooldown: 0,
      fireWindup: 0, windup: none(int), hasGrenade: false,
      hasShield: false, shieldHp: 0, hasSprayPaint: false,
      arcTicksLeft: 0, alive: true, carrying: false),
    partner: some(PartnerSample(seat: uint8(seat xor 1),
      pos: (120 + seat, 120), aimBrads: seat * 11 mod 256,
      alive: true)))
  var fallback = BrDefaultFallbacks(
    currentZone: MapRect(x: 0, y: 0, w: 800, h: 800),
    nextZone: MapRect(x: 100, y: 100, w: 600, h: 600),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zoneDps: 2,
    idleAimCenterBrads: seat * 7 mod 256,
    coverGoal: none(ValidatedGoal))
  if tick <= 100:
    input.partner = some(PartnerSample(seat: uint8(seat xor 1),
      pos: (300 + seat, 300), aimBrads: seat * 11 mod 256,
      alive: true))
  elif tick <= 200:
    input.visibleTracks = @[BodyTrackUpdate(seat: 31 - seat,
      pos: (500, 500), team: Blue, aimBrads: some(0), hpKnown: some(3),
      shielded: false, weapon: some(bwGun), veteranMarker: false,
      tick: uint32(tick))]
    fallback.coverGoal = some(map.validateGoal((200 + seat, 250), self).get)
  else:
    fallback.ticksToNextShrink = BrRotateLeadTicks
    fallback.rotateTarget = some((400 + seat, 400))
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: true,
    alive: true,
    bodyInputs: input,
    defaultFallbacks: fallback)

proc frames(tick: int, map: BodyMap,
            positions: array[Seats, BodyPoint]): seq[FirstLightSeatFrame] =
  for seat in 0 ..< Seats:
    result.add(frame(tick, seat, map, positions))

proc movementFrame(map: BodyMap, seat: int,
                   positions: array[Seats, BodyPoint]): FirstLightSeatFrame =
  let self = positions[seat]
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: true,
    alive: true,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: self, hp: 4, hpFrac: 1.0,
        lives: some(1), aimBrads: seat mod 256, fireCooldown: 0,
        fireWindup: 0, windup: none(int), hasGrenade: false,
        hasShield: false, shieldHp: 0, hasSprayPaint: false,
        arcTicksLeft: 0, alive: true, carrying: false),
      partner: some(PartnerSample(seat: uint8(seat xor 1),
        pos: (20 + seat, 20), alive: true))),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
      nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
      ticksToNextShrink: BrRotateLeadTicks,
      zoneDps: 1,
      idleAimCenterBrads: seat mod 256,
      rotateTarget: some((100, 100)),
      coverGoal: none(ValidatedGoal)))

proc movementFrames(map: BodyMap,
                    positions: array[Seats, BodyPoint]): seq[FirstLightSeatFrame] =
  for seat in 0 ..< Seats:
    result.add(movementFrame(map, seat, positions))

proc dangerFrame(map: BodyMap, self, target: BodyPoint, tick: int,
                 withThreat: bool): FirstLightSeatFrame =
  result = FirstLightSeatFrame(
    seat: 0,
    playerIndex: 0,
    present: true,
    playing: true,
    alive: true,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: self, hp: 4, hpFrac: 1.0,
        lives: some(1), aimBrads: 0, fireCooldown: 0, fireWindup: 0,
        windup: none(int), hasGrenade: false, hasShield: false,
        shieldHp: 0, hasSprayPaint: false, arcTicksLeft: 0,
        alive: true, carrying: false)),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 384, h: 160),
      nextZone: MapRect(x: 0, y: 0, w: 384, h: 160),
      ticksToNextShrink: BrRotateLeadTicks,
      zoneDps: 1,
      idleAimCenterBrads: 0,
      rotateTarget: some(target),
      coverGoal: none(ValidatedGoal)))
  if withThreat:
    for seat in 8 .. 15:
      result.bodyInputs.visibleTracks.add(BodyTrackUpdate(
        seat: seat,
        pos: (192, 80),
        team: Blue,
        aimBrads: some(0),
        hpKnown: some(3),
        shielded: false,
        weapon: some(bwGun),
        veteranMarker: false,
        tick: uint32(tick)))

proc applyMask(pos: var BodyPoint, input: InputState) =
  let bits = input.encodeInputMask()
  if (bits and ButtonLeft) != 0:
    dec pos.x, 4
  if (bits and ButtonRight) != 0:
    inc pos.x, 4
  if (bits and ButtonUp) != 0:
    dec pos.y, 4
  if (bits and ButtonDown) != 0:
    inc pos.y, 4

proc pathDanger(map: BodyMap, danger: BodyDangerField,
                path: openArray[BodyPoint]): float =
  for point in path:
    result += danger.sample(map, point)

proc movementSummary(tick: int, masks: openArray[FirstLightMask]): string =
  var moving, aiming = 0
  for mask in masks:
    let bits = mask.input.encodeInputMask()
    if (bits and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0:
      inc moving
    if (bits and (ButtonB or ButtonSelect)) != 0:
      inc aiming
  &"FIRST_LIGHT_MASK_SUMMARY tick={tick} seats={masks.len} " &
    &"moving={moving} aiming={aiming}"

proc configureDemoPlay(episode: var FirstLightEpisode) =
  let path = getEnv("FIRST_LIGHT_CONFIG_PATH")
  if path.len == 0 or not fileExists(path):
    return
  for line in episode.configureFirstLightDemoPlayFromJson(readFile(path),
      repoRoot()):
    echo line

proc configureAllSeatEdgeRide(episode: var FirstLightEpisode) =
  var seats: seq[int]
  for seat in 0 ..< Seats:
    seats.add seat
  for line in episode.configureFirstLightPlay(FirstLightPlayConfig(
      modulePath: repoRoot() / "play_sdk" / ".build" / "edge_ride.wasm",
      playName: "edge_ride",
      paramsBytes: "{\"coverBias\":0.8,\"enterLead\":120,\"margin\":220}",
      seats: seats,
      uploadIdBase: 30_000,
      proposalIdBase: 40_000,
      originGeneration: 1)):
    echo line

when ShellRuntimeAvailable:
  proc readBytes(path: string): seq[byte] =
    let text = readFile(path)
    result = newSeq[byte](text.len)
    if text.len > 0:
      copyMem(addr result[0], unsafeAddr text[0], text.len)

  proc printModuleSize(engine: RuntimeEngine; label, path: string): bool =
    if not fileExists(path):
      echo &"SHELL_MODULE_SIZE target={runtimeTarget()} play={label} " &
        &"path={path} available=false"
      return
    let bytes = readBytes(path)
    var outcome = engine.validateUploadedModule(bytes)
    defer: outcome.close()
    let reservation = compiledReservationBytes(bytes.len)
    if not outcome.accepted:
      echo &"SHELL_MODULE_SIZE target={runtimeTarget()} play={label} " &
        &"raw_bytes={bytes.len} reservation_bytes={reservation} " &
        &"accepted=false reason={outcome.reason} detail={outcome.detail}"
      return
    let serialized = outcome.module.serializedModuleBytes()
    let ratio = serialized.float / bytes.len.float
    result = serialized <= reservation
    echo &"SHELL_MODULE_SIZE target={runtimeTarget()} play={label} " &
      &"raw_bytes={bytes.len} serialized_bytes={serialized} " &
      &"reservation_bytes={reservation} ratio={ratio:.6f} accepted=true " &
      &"over_reservation={serialized > reservation}"

  proc moduleSizeProof(): bool =
    let engine = newRuntimeEngine()
    defer: engine.close()
    echo "SHELL_RUNTIME_MANIFEST ", runtimeManifest()
    result = true
    result = engine.printModuleSize("hello_play",
      repoRoot() / "play_sdk" / ".build" / "hello_play.wasm") and result
    result = engine.printModuleSize("edge_ride",
      repoRoot() / "play_sdk" / ".build" / "edge_ride.wasm") and result

else:
  proc moduleSizeProof(): bool = true

proc dangerProof() =
  let map = dangerProbeMap()
  let start: BodyPoint = (32, 80)
  let target: BodyPoint = (352, 80)

  proc run(withThreat: bool): tuple[path: seq[BodyPoint],
                                   maximum: float32,
                                   pathDanger: float,
                                   sources: seq[int]] =
    var episode = initFirstLightEpisode(true, true, @[scPlay], map, 32)
    var pos = start
    for tick in 1 .. 160:
      let output = episode.step([
        dangerFrame(map, pos, target, tick, withThreat)], uint32(tick))
      for mask in output.masks:
        pos.applyMask(mask.input)
    result.path = episode.nav.seats[0].activePath
    result.maximum = episode.nav.seats[0].danger.maximum
    result.pathDanger = pathDanger(map, episode.nav.seats[0].danger,
      result.path)
    result.sources = episode.nav.seats[0].selectedDangerSourceSeats

  let baseline = run(false)
  let threatened = run(true)
  let repriced = baseline.path.len > 0 and threatened.path.len > 0 and
    baseline.pathDanger == 0.0 and threatened.pathDanger > baseline.pathDanger
  let sourced = threatened.sources == @[8, 9, 10, 11, 12, 13, 14, 15]
  let dangerPass = threatened.maximum > 0.0'f32 and sourced and repriced
  let verdict = if dangerPass: "PASS" else: "FAIL"
  echo &"FIRST_LIGHT_DANGER tick=160 seat=0 baseline_max={baseline.maximum:.3f} " &
    &"threat_max={threatened.maximum:.3f} sources={threatened.sources.len} " &
    &"baseline_path_danger={baseline.pathDanger:.3f} " &
    &"threat_path_danger={threatened.pathDanger:.3f} " &
    &"repriced={repriced} verdict={verdict}"
  if not dangerPass:
    quit(1)

proc percentile(values: seq[int64], numerator, denominator: int): int64 =
  values[min(values.high,
    (values.len * numerator + denominator - 1) div denominator - 1)]

proc main() =
  let map = probeMap()
  let inventory = firstLightInventory()
  echo &"FIRST_LIGHT_INVENTORY wasmtime={inventory.wasmtime} " &
    &"uploads={inventory.uploads} calls={inventory.calls} " &
    &"stores={inventory.stores} ladder={inventory.ladder} " &
    "executor=lane-a-fl-b"
  let moduleSizePass = moduleSizeProof()

  var telemetry = initFirstLightEpisode(true, true, controls(), map, 331)
  telemetry.configureDemoPlay()
  var telemetryPositions: array[Seats, BodyPoint]
  for seat in 0 ..< Seats:
    telemetryPositions[seat] = (100 + seat, 100)
  for tick in 1 .. TelemetryTicks:
    let output = telemetry.step(frames(tick, map, telemetryPositions),
      uint32(tick))
    doAssert output.masks.len == Seats
    if tick <= InstallTelemetryTicks or tick in [101, 201]:
      for install in output.installs:
        echo install.formatInstall()
    echo movementSummary(tick, output.masks)
    for mask in output.masks:
      telemetryPositions[mask.seat.int].applyMask(mask.input)

  let moveMap = movementProbeMap()
  var movement = initFirstLightEpisode(true, true, controls(), moveMap, 331)
  var movementPositions: array[Seats, BodyPoint]
  for seat in 0 ..< Seats:
    movementPositions[seat] = (10 + seat, 10)
  for tick in 1 .. 400:
    let output = movement.step(movementFrames(moveMap, movementPositions),
      uint32(tick))
    let summary = movementSummary(tick, output.masks)
    if tick <= 8 or summary.find("moving=0") < 0 or tick mod 50 == 0:
      echo summary & " scenario=stable_rotate"
    for mask in output.masks:
      movementPositions[mask.seat.int].applyMask(mask.input)

  dangerProof()

  var measured = initFirstLightEpisode(true, true, controls(), moveMap, 331)
  measured.configureAllSeatEdgeRide()
  var measuredPositions: array[Seats, BodyPoint]
  for seat in 0 ..< Seats:
    measuredPositions[seat] = (10 + seat, 10)
  for tick in 1 .. WarmTicks:
    let output = measured.step(movementFrames(moveMap, measuredPositions),
      uint32(tick))
    for mask in output.masks:
      measuredPositions[mask.seat.int].applyMask(mask.input)

  var body, runtime: seq[int64]
  for tick in WarmTicks + 1 .. WarmTicks + Samples:
    let output = measured.step(movementFrames(moveMap, measuredPositions),
      uint32(tick))
    doAssert output.masks.len == Seats
    for mask in output.masks:
      measuredPositions[mask.seat.int].applyMask(mask.input)
    body.add(output.bodyNanoseconds)
    runtime.add(output.runtimeNanoseconds)
  body.sort()
  runtime.sort()

  let bodyPass = body[^1] <= BodyGateNs
  let runtimePass = runtime[^1] <= RuntimeGateNs
  echo &"FIRST_LIGHT_BODY seats={Seats} warm_ticks={WarmTicks} " &
    &"samples={Samples} median_us={body.percentile(50, 100).float / 1000.0:.3f} " &
    &"p95_us={body.percentile(95, 100).float / 1000.0:.3f} " &
    &"max_us={body[^1].float / 1000.0:.3f} gate_us=5000.000 " &
    (if bodyPass: "verdict=PASS" else: "verdict=FAIL")
  echo &"FIRST_LIGHT_RUNTIME seats={Seats} warm_ticks={WarmTicks} " &
    &"samples={Samples} median_us={runtime.percentile(50, 100).float / 1000.0:.3f} " &
    &"p95_us={runtime.percentile(95, 100).float / 1000.0:.3f} " &
    &"max_us={runtime[^1].float / 1000.0:.3f} gate_us=4000.000 " &
    (if runtimePass: "verdict=PASS" else: "verdict=FAIL")
  if not moduleSizePass or not bodyPass or not runtimePass:
    quit(1)

main()
