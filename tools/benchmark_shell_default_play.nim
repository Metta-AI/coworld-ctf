## Phase P3-1 release microbenchmark: 32 lane-C default/finish/fold/install
## paths against the 4.0 ms runtime sub-allocation. Rotate and partner legs use
## lane A's concrete validateGoal proof path; nearest-cover query cost remains
## outside this measurement until the atlas scorer is relayed.

import std/[algorithm, monotimes, options, strformat, times]
import ../src/ctf/sim_types
import ../src/shell/[body_map, default_play, standing_order, types]

const
  Seats = 32
  WarmupBatches = 30
  SampleBatches = 1000
  RuntimeGateUs = 4000.0

proc benchmarkMap(): BodyMap =
  const Side = 1024
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(100, 100)])

proc percentile(sorted: seq[float], numerator, denominator: int): float =
  sorted[min(sorted.high,
    (sorted.len * numerator + denominator - 1) div denominator - 1)]

proc main() =
  let map = benchmarkMap()
  var bodies = newSeq[SeatBody](Seats)
  var states = newSeq[StandingOrderState](Seats)
  for seat in 0 ..< Seats:
    bodies[seat] = activateSeatBody(map, uint8(seat))
    bodies[seat].brSnapshot = LaneABrSnapshot(
      selfPos: MapPoint(x: 100 + seat, y: 100),
      currentZone: MapRect(x: 0, y: 0, w: 800, h: 800),
      nextZone: MapRect(x: 100, y: 100, w: 600, h: 600),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zoneDps: 2,
      idleAimCenterBrads: seat * 7 mod 256,
      threatPositions: @[
        MapPoint(x: 500, y: 500), MapPoint(x: 510, y: 490),
        MapPoint(x: 520, y: 480), MapPoint(x: 530, y: 470),
        MapPoint(x: 540, y: 460), MapPoint(x: 550, y: 450),
        MapPoint(x: 560, y: 440), MapPoint(x: 570, y: 430)])
    bodies[seat].partner = PartnerTelemetry(
      identity: SeatRef(uint8(seat xor 1)),
      pos: MapPoint(x: 120 + seat, y: 120),
      aimBrads: seat * 11 mod 256,
      alive: true)
    states[seat].annotations = newSeqOfCap[ShellAnnotation](
      WarmupBatches + SampleBatches)

  proc runBatch(tick: int) =
    for seat in 0 ..< Seats:
      let point = MapPoint(x: 200 + (tick and 1), y: 300 + seat)
      case tick mod 3
      of 0:
        bodies[seat].brSnapshot.ticksToNextShrink = BrRotateLeadTicks
        bodies[seat].brSnapshot.rotateTarget = some(point)
        bodies[seat].brSnapshot.partnerTarget = none(MapPoint)
        bodies[seat].brSnapshot.coverGoal = none(ValidatedGoal)
        bodies[seat].brSnapshot.threatPositions.setLen(0)
      of 1:
        bodies[seat].brSnapshot.ticksToNextShrink = BrRotateLeadTicks + 1
        bodies[seat].partner.pos = MapPoint(x: 900, y: 900)
        bodies[seat].brSnapshot.rotateTarget = none(MapPoint)
        bodies[seat].brSnapshot.partnerTarget = some(point)
        bodies[seat].brSnapshot.coverGoal = none(ValidatedGoal)
        bodies[seat].brSnapshot.threatPositions.setLen(0)
      else:
        bodies[seat].brSnapshot.ticksToNextShrink = BrRotateLeadTicks + 1
        bodies[seat].partner.pos = MapPoint(x: 120 + seat, y: 120)
        bodies[seat].brSnapshot.rotateTarget = none(MapPoint)
        bodies[seat].brSnapshot.partnerTarget = none(MapPoint)
        bodies[seat].brSnapshot.coverGoal =
          some(map.validateGoal(point.toBodyPoint,
            bodies[seat].brSnapshot.selfPos.toBodyPoint).get)
        bodies[seat].brSnapshot.threatPositions = @[MapPoint(x: 500, y: 500)]
      states[seat].stepFirstLightDefault(bodies[seat], uint32(tick))

  for tick in 1 .. WarmupBatches:
    runBatch(tick)

  var samples = newSeqOfCap[float](SampleBatches)
  for sample in 0 ..< SampleBatches:
    let started = getMonoTime()
    runBatch(WarmupBatches + sample + 1)
    samples.add(float((getMonoTime() - started).inNanoseconds) / 1000.0)

  samples.sort()
  var checksum = 0
  for seat in 0 ..< Seats:
    checksum += bodies[seat].installCount
    checksum += states[seat].intentBytes.len

  let median = percentile(samples, 50, 100)
  let p95 = percentile(samples, 95, 100)
  let p99 = percentile(samples, 99, 100)
  let maximum = samples[^1]
  echo &"DEFAULT_PLAY_BENCH seats={Seats} samples={SampleBatches} " &
    &"median_us={median:.3f} p95_us={p95:.3f} p99_us={p99:.3f} " &
    &"max_us={maximum:.3f} gate_us={RuntimeGateUs:.3f} " &
    "lane_a_query=measured-real " &
    (if maximum <= RuntimeGateUs: "verdict=PASS" else: "verdict=FAIL") &
    &" checksum={checksum}"
  if maximum > RuntimeGateUs:
    quit(1)

main()
