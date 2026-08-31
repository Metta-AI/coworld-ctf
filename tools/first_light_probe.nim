## Deterministic FIRST LIGHT wiring/timing probe. It drives the frozen
## concrete validateGoal boundary through hold/rotate/cover/partner changes, prints
## install telemetry, then measures 32 seats after 30 warm ticks.

import std/[algorithm, options, strformat]
import bitworld/spriteprotocol
import ../src/ctf/sim_types
import ../src/shell/[body_map, default_play, episode, standing_order, types]

const
  Seats = 32
  WarmTicks = 30
  Samples = 120
  BodyGateNs = 5_000_000'i64
  RuntimeGateNs = 4_000_000'i64

proc probeMap(): BodyMap =
  const Side = 1024
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(100, 100)])

proc controls(): seq[SlotControl] =
  result = newSeq[SlotControl](Seats)
  for control in result.mitems:
    control = scPlay

proc frames(tick: int, map: BodyMap): seq[FirstLightSeatFrame] =
  for seat in 0 ..< Seats:
    var snapshot = LaneABrSnapshot(
      selfPos: MapPoint(x: 100 + seat, y: 100),
      currentZone: MapRect(x: 0, y: 0, w: 800, h: 800),
      nextZone: MapRect(x: 100, y: 100, w: 600, h: 600),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zoneDps: 2,
      idleAimCenterBrads: seat * 7 mod 256)
    var partner = PartnerTelemetry(
      identity: SeatRef(uint8(seat xor 1)),
      pos: MapPoint(x: 120 + seat, y: 120),
      aimBrads: seat * 11 mod 256,
      alive: true)
    case tick mod 4
    of 0:
      snapshot.ticksToNextShrink = BrRotateLeadTicks
      snapshot.rotateTarget = some(MapPoint(x: 400 + seat, y: 400))
    of 1:
      partner.pos = MapPoint(x: 700, y: 700)
      snapshot.partnerTarget = some(MapPoint(x: 300 + seat, y: 300))
    of 2:
      snapshot.threatPositions = @[MapPoint(x: 500, y: 500)]
      snapshot.coverGoal = some(map.validateGoal(
        (200 + seat, 250), snapshot.selfPos.toBodyPoint).get)
    else:
      discard
    result.add(FirstLightSeatFrame(
      seat: uint8(seat),
      playerIndex: seat,
      present: true,
      playing: true,
      alive: true,
      snapshot: snapshot,
      partner: partner,
      bodyInputs: BodyTickInputs()))

proc percentile(values: seq[int64], numerator, denominator: int): int64 =
  values[min(values.high,
    (values.len * numerator + denominator - 1) div denominator - 1)]

proc main() =
  let map = probeMap()
  let inventory = firstLightInventory()
  echo &"FIRST_LIGHT_INVENTORY wasmtime={inventory.wasmtime} " &
    &"uploads={inventory.uploads} calls={inventory.calls} " &
    &"stores={inventory.stores} ladder={inventory.ladder} " &
    "executor=ADOPT-ON-RELAY-noop"

  var telemetry = initFirstLightEpisode(true, true, controls(), map)
  for tick in 1 .. 5:
    let output = telemetry.step(frames(tick, map), uint32(tick))
    doAssert output.masks.len == Seats
    for mask in output.masks:
      doAssert mask.input.encodeInputMask() == 0
    for install in output.installs:
      echo install.formatInstall()

  var measured = initFirstLightEpisode(true, true, controls(), map)
  for tick in 1 .. WarmTicks:
    discard measured.step(frames(tick, map), uint32(tick))

  var body, runtime: seq[int64]
  for tick in WarmTicks + 1 .. WarmTicks + Samples:
    let output = measured.step(frames(tick, map), uint32(tick))
    doAssert output.masks.len == Seats
    for mask in output.masks:
      doAssert mask.input.encodeInputMask() == 0
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
  if not bodyPass or not runtimePass:
    quit(1)

main()
