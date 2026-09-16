## Portable, stencil-free half of the Season 2 body P0 benchmark.

when not defined(release):
  {.error: "bench_body must be compiled with -d:release".}

import std/[algorithm, json, math, monotimes, options, os, osproc,
  strutils, times]
import body_bench/[edt_probe, view_frames]
import ../src/shell/canonical

type
  Options = object
    selectedCase: string
    seeds: seq[int]
    warmups, samples: int
    output: string

proc parseIntList(text: string): seq[int] =
  for item in text.split(','):
    result.add(parseInt(item.strip()))

proc parseOptions(): Options =
  result = Options(selectedCase: "all",
    seeds: @[4242, 14005, 23011, 41017, 65003], warmups: 5, samples: 50)
  let args = commandLineParams()
  var index = 0
  while index < args.len:
    if not args[index].startsWith("--"):
      raise newException(ValueError, "unexpected positional argument: " & args[index])
    let parts = args[index][2 .. ^1].split('=', 1)
    let key = parts[0]
    var value = if parts.len == 2: parts[1] else: ""
    if value.len == 0:
      inc index
      if index >= args.len:
        raise newException(ValueError, "missing value for --" & key)
      value = args[index]
    case key
    of "case": result.selectedCase = value
    of "seeds": result.seeds = parseIntList(value)
    of "warmups": result.warmups = parseInt(value)
    of "samples": result.samples = parseInt(value)
    of "output", "o": result.output = value
    else: raise newException(ValueError, "unknown option --" & key)
    inc index
  if result.warmups < 0 or result.samples <= 0 or result.seeds.len == 0:
    raise newException(ValueError, "warmups must be >= 0; samples and seeds must be nonzero")

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc measure(warmups, samples: int, body: proc() {.closure.}): seq[int64] =
  for _ in 0 ..< warmups:
    body()
  for _ in 0 ..< samples:
    let started = getMonoTime()
    body()
    result.add(elapsedNs(started))

proc percentile(samples: openArray[int64], fraction: float): int64 =
  var ordered = @samples
  ordered.sort()
  ordered[clamp(int(ceil(fraction * ordered.len.float)) - 1, 0, ordered.high)]

proc row(name: string, samples: seq[int64], details = newJObject()): JsonNode =
  %*{"name": name, "samples": samples.len, "median_ns": percentile(samples, 0.5),
    "p95_ns": percentile(samples, 0.95), "details": details}

proc validatorCase(options: Options): seq[JsonNode] =
  let
    width = 720
    height = 64
  var components = newSeq[uint16](width * height)
  for y in 7 .. 56:
    for x in 7 .. 94: components[y * width + x] = 1
    for x in 606 .. 712: components[y * width + x] = 2
  # Same-component equal-distance tie fixture: a one-pixel hole has four
  # row-major-equidistant component-1 neighbours.
  components[20 * width + 50] = 0
  var table: EdtTable
  let buildSamples = measure(options.warmups, options.samples,
    proc() = table = buildEdt(components, width, height, 1))
  let baseQueries = @[
    (name: "standable_site", point: (x: 20, y: 20)),
    (name: "blocked_point", point: (x: 100, y: 20)),
    (name: "map_edge", point: (x: 0, y: 0)),
    (name: "exact_radius_256", point: (x: 350, y: 20)),
    (name: "one_past_radius_256", point: (x: 351, y: 20)),
    (name: "equal_distance_tie", point: (x: 50, y: 20)),
    (name: "nearer_other_component", point: (x: 650, y: 20))]
  var queries: seq[PixelPoint]
  var classCounts = newJObject()
  let repetitions = if options.selectedCase == "smoke": 1 else: 1429
  for item in baseQueries:
    classCounts[item.name] = %repetitions
    for _ in 0 ..< repetitions: queries.add(item.point)
  let parity = parityCheck(components, width, height, 1, queries, 256)
  if parity.failures != 0:
    raise newException(ValueError, "EDT parity failed for " & $parity.failures & " queries")
  var resolved = 0
  let lookupSamples = measure(options.warmups, options.samples,
    proc() =
      for query in queries:
        if table.resolveNearest(query, 256).isSome:
          inc resolved)
  result.add(row("validator.edt_build", buildSamples,
    %*{"width": width, "height": height, "logical_bytes": table.distances.len * sizeof(uint32)}))
  result.add(row("validator.lookup_batch", lookupSamples,
    %*{"queries": parity.checked, "failures": parity.failures,
      "classes": classCounts, "resolved_accumulator": resolved}))

proc viewCase(options: Options): seq[JsonNode] =
  var realNode, capNode: JsonNode
  let buildSamples = measure(options.warmups, options.samples,
    proc() = realNode = buildPlayView())
  realNode = buildPlayView()
  var encoded = ""
  let encodeSamples = measure(options.warmups, options.samples,
    proc() = encoded = canonicalJson(realNode))
  let batchSamples = measure(options.warmups, options.samples,
    proc() =
      for _ in 0 ..< 32:
        discard canonicalJson(buildPlayView()))
  capNode = buildPlayView(padding = true)
  let capBytes = canonicalJson(capNode).len
  if capBytes >= ViewCap:
    raise newException(ValueError, "cap-stress play_view is at or over MaxViewFrameBytes")
  result.add(row("view.build", buildSamples, %*{"real_bytes": encoded.len}))
  result.add(row("view.encode", encodeSamples, %*{"real_bytes": encoded.len}))
  result.add(row("view.batch32", batchSamples))
  let capSamples = measure(options.warmups, options.samples,
    proc() = encoded = canonicalJson(capNode))
  result.add(row("view.cap_stress_encode", capSamples,
    %*{"bytes": capBytes, "cap": ViewCap}))

proc contextCase(options: Options): seq[JsonNode] =
  var realNode: JsonNode
  let buildSamples = measure(options.warmups, options.samples,
    proc() = realNode = buildPlayContext())
  realNode = buildPlayContext()
  var encoded = ""
  let encodeSamples = measure(options.warmups, options.samples,
    proc() = encoded = canonicalJson(realNode))
  let batchSamples = measure(options.warmups, options.samples,
    proc() =
      for _ in 0 ..< 32:
        discard canonicalJson(buildPlayContext()))
  let capNode = buildPlayContext(padding = true)
  let capBytes = canonicalJson(capNode).len
  if capBytes >= ContextCap:
    raise newException(ValueError, "cap-stress play_context is at or over MaxContextBytes")
  result.add(row("context.build", buildSamples, %*{"real_bytes": encoded.len}))
  result.add(row("context.encode", encodeSamples, %*{"real_bytes": encoded.len}))
  result.add(row("context.batch32", batchSamples))
  let capSamples = measure(options.warmups, options.samples,
    proc() = encoded = canonicalJson(capNode))
  result.add(row("context.cap_stress_encode", capSamples,
    %*{"bytes": capBytes, "cap": ContextCap}))

proc gitHead(): string =
  try:
    execProcess("git", args = ["rev-parse", "HEAD"], options = {poUsePath}).strip()
  except OSError:
    "unknown"

proc addRows(target: JsonNode, rows: seq[JsonNode]) =
  for item in rows:
    target.add(item)

proc main() =
  var options = parseOptions()
  if options.selectedCase == "smoke":
    options.warmups = 0
    options.samples = 1
  var rows = newJArray()
  case options.selectedCase
  of "smoke", "all":
    rows.addRows(validatorCase(options))
    rows.addRows(viewCase(options))
    rows.addRows(contextCase(options))
  of "validator": rows.addRows(validatorCase(options))
  of "view": rows.addRows(viewCase(options))
  of "context": rows.addRows(contextCase(options))
  else:
    raise newException(ValueError,
      "stencil-free cases are smoke, all, validator, view, context")
  let output = %*{
    "harness": "body-p0-stencil-free", "repo_commit": gitHead(),
    "release": true, "case": options.selectedCase, "seeds": options.seeds,
    "warmups": options.warmups, "samples": options.samples, "rows": rows
  }
  let encoded = pretty(output)
  if options.output.len > 0:
    let destination = absolutePath(options.output)
    let repo = getCurrentDir() & DirSep
    if destination.startsWith(repo):
      raise newException(ValueError, "benchmark output must stay outside the repository")
    writeFile(destination, encoded & "\n")
  echo encoded

when isMainModule:
  main()
