## Diagnostic packer regimes; not a whole-body acceptance gate.
import std/[algorithm, json, monotimes, times]
import ../src/shell/[body_danger, body_map, body_route_query]

const
  Width = 402
  Height = 215
  CallsPerSample = 10

let pixelWidth = Width * NavCell + NavCell - 1
let pixelHeight = Height * NavCell + NavCell - 1
var walkable = newSeq[bool](pixelWidth * pixelHeight)
for value in walkable.mitems: value = true
let map = newBodyMap(walkable, pixelWidth, pixelHeight, 1, @[(7, 7)])
let graph = BodyMixedGraph(map: map)
var rows = newJArray()
for regime in ["zero", "single", "dense"]:
  var danger = BodyDangerField(values: newSeq[float32](Width * Height))
  case regime
  of "single": danger.values[(Height div 2) * Width + Width div 2] = 0.5
  of "dense":
    for value in danger.values.mitems: value = 0.5
  else: discard
  var weights: seq[int16]
  for warmup in 0 ..< 5: graph.rebuildPackedWeights(danger, weights)
  var samples: seq[int64]
  for sample in 0 ..< 120:
    let started = getMonoTime()
    for call in 0 ..< CallsPerSample:
      graph.rebuildPackedWeights(danger, weights)
    samples.add (getMonoTime() - started).inNanoseconds div CallsPerSample
  var sorted = samples
  sorted.sort()
  var checksum = 0'u64
  for value in weights:
    checksum = (checksum shl 5) xor (checksum shr 59) xor cast[uint16](value).uint64
  rows.add %*{"regime": regime, "samples_ns_per_call": samples,
    "p95_ns_per_call": sorted[(sorted.len * 95 + 99) div 100 - 1],
    "max_ns_per_call": sorted[^1], "checksum": $checksum}
echo %*{"width": Width, "height": Height, "calls_per_sample": CallsPerSample,
  "rows": rows, "acceptance_gate": false}
