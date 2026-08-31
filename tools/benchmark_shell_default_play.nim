## Phase P3-1 release microbenchmark: 32 lane-C default/finish/fold/install
## paths against the 4.0 ms runtime sub-allocation. Rotate and partner legs use
## lane A's concrete validateGoal proof path; nearest-cover query cost remains
## outside this measurement until the atlas scorer is relayed.

import std/[algorithm, monotimes, options, strformat, times]
import ../src/ctf/sim_types
import ../src/shell/[body, body_map, default_play, standing_order, types]

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
    bodies[seat] = activateSeatBody(map, seat, 331)
    states[seat].annotations = newSeqOfCap[ShellAnnotation](
      WarmupBatches + SampleBatches)

  proc runBatch(tick: int) =
    for seat in 0 ..< Seats:
      let point = MapPoint(x: 200 + (tick and 1), y: 300 + seat)
      var input = BodyTickInputs(
        self: BodySelfState(pos: (100 + seat, 100), hpFrac: 1.0,
          aimBrads: seat * 7 mod 256, alive: true, carrying: false),
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
      case tick mod 3
      of 0:
        fallback.ticksToNextShrink = BrRotateLeadTicks
        fallback.rotateTarget = some(point.toBodyPoint)
      of 1:
        input.partner = some(PartnerSample(seat: uint8(seat xor 1),
          pos: point.toBodyPoint, aimBrads: seat * 11 mod 256, alive: true))
      else:
        fallback.coverGoal = some(map.validateGoal(point.toBodyPoint,
          input.self.pos).get)
        input.visibleTracks = @[BodyTrackUpdate(seat: 31 - seat,
          pos: (500, 500), team: Blue, aimBrads: some(0), hpKnown: some(3),
          tick: uint32(tick))]
      bodies[seat].updateBelief(input, uint32(tick))
      states[seat].stepFirstLightDefault(bodies[seat], uint32(tick),
        fallback)

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
    checksum += states[seat].annotations.len
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
