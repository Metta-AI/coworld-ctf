## Reference `edge_ride` controller through the production shell runtime path.

import std/[json, math, options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, body, body_map, default_play, emit_validator,
  instance, manifest, module_validation, runtime, types]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
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

proc buildEdgeRideWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(EdgeRideSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(EdgeRideWasm)
  readFile(EdgeRideWasm).toOpenArrayByte(0, getFileSize(EdgeRideWasm).int - 1).toSeq

proc testMap(): BodyMap =
  const
    Width = 1800
    Height = 1100
  var walkable = newSeq[bool](Width * Height)
  for value in walkable.mitems:
    value = true
  for y in 220 .. 780:
    for x in 900 .. 920:
      walkable[y * Width + x] = false
  for y in 650 .. 670:
    for x in 420 .. 760:
      walkable[y * Width + x] = false
  newBodyMap(walkable, Width, Height, 2, @[(100, 100), (1600, 900)])

proc checkedModule(engine: RuntimeEngine; bytes: seq[byte]): RuntimeModule =
  var validation = engine.validateUploadedModule(bytes)
  require validation.accepted
  result = validation.module
  validation.module = nil
  validation.close()

proc edgeModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildEdgeRideWasm())

proc newEdgeInstance(engine: RuntimeEngine; module: RuntimeModule;
                     map: BodyMap; selfPos: BodyPoint): ShellInstance =
  newShellInstance(module, map, selfPos, ecController, gmBr)

proc initOk(instance: ShellInstance; params: string) =
  let init = instance.invokeInit(params, "{}")
  check not init.faulted
  check init.returned == 0

proc fuelConsumed(invocation: ShellInvocationResult): uint64 =
  if invocation.faulted and invocation.reason.contains("all fuel consumed"):
    StepFuel.uint64
  else:
    StepFuel.uint64 - invocation.fuelRemaining

proc trackRow(index: int): string =
  "{\"aim_brads\":" & $(index mod 256) & ",\"bounty\":" &
    (if index mod 2 == 0: "true" else: "false") &
    ",\"fresh_tick\":" & $(1000 + index) & ",\"hp\":" &
    $(1 + index mod 3) & ",\"pos\":[" & $(100 + index) & "," &
    $(200 + index) & "],\"seat\":" & $index & ",\"team\":\"" &
    (if index mod 2 == 0: "navy" else: "rust") & "\"}"

proc joinTracks(count: int): string =
  for index in 0 ..< count:
    if index > 0:
      result.add ","
    result.add trackRow(index)

proc viewFor(tick: int; self: BodyPoint; current: array[4, int];
             ticksToShrink: int; next: array[4, int] = [0, 0, 0, 0];
             includeNext = true; tracks = 0): string =
  result = "{\"schema\":\"play_view\",\"self\":{\"aim_brads\":32," &
    "\"alive\":true,\"hp\":2,\"hp_frac\":1.0," &
    "\"pos\":[" & $self.x & "," & $self.y & "]},\"tick\":" & $tick
  if tracks > 0:
    result.add ",\"tracks\":[" & joinTracks(tracks) & "]"
  result.add ",\"v\":1,\"world\":{\"alive_teams\":9,\"zone\":{\"current\":[" &
    $current[0] & "," & $current[1] & "," & $current[2] & "," &
    $current[3] & "],\"dps\":1"
  if includeNext:
    result.add ",\"next\":[" & $next[0] & "," & $next[1] & "," &
      $next[2] & "," & $next[3] & "]"
  result.add ",\"phase\":2,\"ticks_to_shrink\":" & $ticksToShrink & "}}}"

proc fullViewFor(tick: int; self: BodyPoint; current: array[4, int];
                 ticksToShrink: int; tracks = 0): string =
  "{\"aggressors\":[],\"epoch\":\"0\",\"hazards\":{\"grenades\":[]," &
    "\"sprays\":[]},\"items\":[],\"kill_feed\":[],\"schema\":\"play_view\"," &
    "\"self\":{\"aim_brads\":32,\"alive\":true,\"hp\":2,\"hp_frac\":1.0," &
    "\"pos\":[" & $self.x & "," & $self.y & "]},\"shouts\":[]," &
    "\"tick\":" & $tick & ",\"tracks\":[" & joinTracks(tracks) &
    "],\"v\":1," &
    "\"world\":{\"alive_teams\":9,\"zone\":{\"current\":[" & $current[0] &
    "," & $current[1] & "," & $current[2] & "," & $current[3] &
    "],\"dps\":1,\"phase\":2,\"ticks_to_shrink\":" & $ticksToShrink & "}}}"

proc rectArray(node: JsonNode): array[4, int] =
  require node.kind == JArray
  require node.len == 4
  for index in 0 .. 3:
    result[index] = node[index].getInt

proc goldenZoneRects(): tuple[current, next: array[4, int]] =
  let zone = parseJson(readFile(FixtureDir / "play_view.golden.json"))[
    "world"]["zone"]
  result.current = zone["current"].rectArray
  result.next = zone["next"].rectArray

proc pointOf(invocation: ShellInvocationResult): BodyPoint =
  let point = invocation.lastAccepted.get.intent.point.get
  (point.x, point.y)

proc reasonOf(invocation: ShellInvocationResult): string =
  invocation.lastAccepted.get.intent.reason

proc isAtlasPost(map: BodyMap; point: BodyPoint): bool =
  for index in map.atlasNear(point, 1):
    if map.atlasPostAt(index).pos == point:
      return true
  false

proc rectContains(rect: array[4, int]; point: BodyPoint): bool =
  point.x >= rect[0] and point.x <= rect[0] + rect[2] and
    point.y >= rect[1] and point.y <= rect[1] + rect[3]

proc advance(pos, target: BodyPoint; speed: float): BodyPoint =
  let
    dx = target.x.float - pos.x.float
    dy = target.y.float - pos.y.float
    distance = hypot(dx, dy)
  if distance <= speed or distance == 0.0:
    return target
  (int(round(pos.x.float + dx / distance * speed)),
   int(round(pos.y.float + dy / distance * speed)))

proc defaultDecision(map: BodyMap; pos: BodyPoint; ticksToShrink: int;
                     rotateTarget: BodyPoint): DefaultDecision =
  computeBrDefault(BrDefaultFacts(
    tick: uint32(240 - ticksToShrink),
    map: map,
    selfPos: pos,
    currentZone: MapRect(x: 400, y: 200, w: 1200, h: 700),
    nextZone: MapRect(x: 900, y: 450, w: 350, h: 300),
    ticksToNextShrink: ticksToShrink,
    zoneDps: 1,
    idleAimCenterBrads: 32,
    partner: none(PartnerTelemetry),
    rotateTarget: rotateTarget,
    coverGoal: none(ValidatedGoal)))

suite "edge_ride reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    var instance = engine.newEdgeInstance(module, map, (550, 300))
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_edge_ride.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "edge_ride"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]

  test "params decode defaults, non-integral coverBias, and bounds":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    let current = [400, 200, 1200, 700]

    var defaults = engine.newEdgeInstance(module, map, (550, 300))
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.invokeStep(
      viewFor(1, (550, 300), current, 240, includeNext = false), 1,
      (550, 300))
    check not defaultStep.faulted
    check defaultStep.returned == 0
    check defaultStep.counters.spatialCalls == 2
    check defaultStep.reasonOf == "edge_ride:cover"

    var fractional = engine.newEdgeInstance(module, map, (550, 300))
    defer: fractional.close()
    fractional.initOk("{\"coverBias\":0.5,\"enterLead\":120,\"margin\":220}")

    for params in ["{\"coverBias\":1.5}", "{\"enterLead\":601}",
                   "{\"margin\":39}"]:
      var rejected = engine.newEdgeInstance(module, map, (550, 300))
      defer: rejected.close()
      let init = rejected.invokeInit(params, "{}")
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "ladder rules are deterministic at their boundaries":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    let
      current = [400, 200, 1200, 700]
      next = [900, 450, 350, 300]

    block outsideCurrent:
      var instance = engine.newEdgeInstance(module, map, (300, 300))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":100}")
      let step = instance.invokeStep(viewFor(1, (300, 300), current, 240,
        next), 1, (300, 300))
      check not step.faulted
      check step.reasonOf == "edge_ride:inside"
      check current.rectContains(step.pointOf)

    block enterLeadBoundary:
      var instance = engine.newEdgeInstance(module, map, (700, 500))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":80}")
      let step = instance.invokeStep(viewFor(1, (700, 500), current, 120,
        next), 1, (700, 500))
      check not step.faulted
      check step.reasonOf == "edge_ride:enter"
      check next.rectContains(step.pointOf)

    block insideMargin:
      var instance = engine.newEdgeInstance(module, map, (450, 500))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":100}")
      let step = instance.invokeStep(viewFor(1, (450, 500), current, 240,
        next), 1, (450, 500))
      check not step.faulted
      check step.reasonOf == "edge_ride:margin"
      check step.pointOf.x >= current[0] + 100

    block exactlyAtMarginHolds:
      var instance = engine.newEdgeInstance(module, map, (500, 500))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":100}")
      let step = instance.invokeStep(viewFor(1, (500, 500), current, 240,
        next), 1, (500, 500))
      check not step.faulted
      check step.reasonOf == "edge_ride:hold"

  test "spatial-call accounting stays inside the two-call envelope":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    let current = [400, 200, 1200, 700]

    var plain = engine.newEdgeInstance(module, map, (550, 300))
    defer: plain.close()
    plain.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":220}")
    let plainStep = plain.invokeStep(viewFor(1, (550, 300), current, 240,
      includeNext = false), 1, (550, 300))
    check not plainStep.faulted
    check plainStep.counters.spatialCalls == 1

    var covered = engine.newEdgeInstance(module, map, (550, 300))
    defer: covered.close()
    covered.initOk("{\"coverBias\":0.8,\"enterLead\":120,\"margin\":220}")
    let coveredStep = covered.invokeStep(viewFor(1, (550, 300), current, 240,
      includeNext = false), 1, (550, 300))
    check not coveredStep.faulted
    check coveredStep.counters.spatialCalls == MaxSpatialCallsPerStep
    check coveredStep.reasonOf == "edge_ride:cover"
    check map.isAtlasPost(coveredStep.pointOf)

  test "byte-identical decisions emit once and then stay cached":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    var instance = engine.newEdgeInstance(module, map, (550, 300))
    defer: instance.close()
    instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":220}")
    let view = viewFor(1, (550, 300), [400, 200, 1200, 700], 240,
      includeNext = false)

    let first = instance.invokeStep(view, 1, (550, 300))
    let second = instance.invokeStep(view, 2, (550, 300))
    check first.emitCodes == @[AbiOk]
    check second.emitCodes.len == 0
    check second.lastAccepted == first.lastAccepted

  test "structural reader rejects malformed skipped values and nested tick traps":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()

    for badView in [
        "{\"bogus\":tru,\"schema\":\"play_view\",\"self\":{\"pos\":[550,300]}," &
          "\"tick\":1441,\"v\":1,\"world\":{\"zone\":{\"current\":" &
          "[400,200,1200,700],\"ticks_to_shrink\":240}}}",
        "{\"bogus\":1e+,\"schema\":\"play_view\",\"self\":{\"pos\":[550,300]}," &
          "\"tick\":1441,\"v\":1,\"world\":{\"zone\":{\"current\":" &
          "[400,200,1200,700],\"ticks_to_shrink\":240}}}",
        "{\"bogus\":{],\"schema\":\"play_view\",\"self\":{\"pos\":[550,300]}," &
          "\"tick\":1441,\"v\":1,\"world\":{\"zone\":{\"current\":" &
          "[400,200,1200,700],\"ticks_to_shrink\":240}}}",
        "{\"bogus\":[},\"schema\":\"play_view\",\"self\":{\"pos\":[550,300]}," &
          "\"tick\":1441,\"v\":1,\"world\":{\"zone\":{\"current\":" &
          "[400,200,1200,700],\"ticks_to_shrink\":240}}}",
        "{\"aggressors\":[{\"dir_brads\":64,\"tick\":1400}]," &
          "\"schema\":\"play_view\",\"self\":{\"pos\":[550,300]},\"v\":1," &
          "\"world\":{\"zone\":{\"current\":[400,200,1200,700]," &
          "\"ticks_to_shrink\":240}}}"]:
      var instance = engine.newEdgeInstance(module, map, (550, 300))
      defer: instance.close()
      instance.initOk("{}")
      let step = instance.invokeStep(badView, 1441, (550, 300))
      check step.faulted
      check step.reason == "play_step returned nonzero"

    var good = engine.newEdgeInstance(module, map, (550, 300))
    defer: good.close()
    good.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":220}")
    let goodStep = good.invokeStep(fullViewFor(1441, (550, 300),
      [400, 200, 1200, 700], 240, tracks = 1), 1441, (550, 300))
    check not goodStep.faulted
    check goodStep.returned == 0

  test "zone rectangles decode the schema width-height form":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    let (goldenCurrent, goldenNext) = goldenZoneRects()
    check goldenCurrent == [400, 200, 1600, 900]
    check goldenNext == [700, 350, 800, 450]

    block currentSpansWidthHeight:
      var instance = engine.newEdgeInstance(module, map, (1700, 850))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":0,\"margin\":40}")
      let view = viewFor(1441, (1700, 850), goldenCurrent, 240,
        includeNext = false)
      let step = instance.invokeStep(view, 1441, (1700, 850))
      check not step.faulted
      check step.returned == 0
      check step.reasonOf == "edge_ride:hold"

    block nextSpansWidthHeight:
      var instance = engine.newEdgeInstance(module, map, (1000, 600))
      defer: instance.close()
      instance.initOk("{\"coverBias\":0.0,\"enterLead\":120,\"margin\":40}")
      let view = viewFor(1441, (1000, 600), goldenCurrent, 120,
        goldenNext)
      let step = instance.invokeStep(view, 1441, (1000, 600))
      check not step.faulted
      check step.returned == 0
      check step.reasonOf == "edge_ride:enter"
      check step.pointOf == (1000, 600)

  test "lean and large BR controller view fuel rows are reported honestly":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()

    block lean:
      var instance = engine.newEdgeInstance(module, map, (550, 300))
      defer: instance.close()
      instance.initOk("{}")
      let view = viewFor(1441, (550, 300), [400, 200, 1200, 700], 240,
        includeNext = false)
      let step = instance.invokeStep(view, 1441, (550, 300))
      let consumed = step.fuelConsumed
      echo "EDGE_RIDE_VIEW_FUEL kind=lean view_len=", view.len,
        " tracks=0 consumed=", consumed,
        " completed=", (not step.faulted and step.returned == 0),
        " fuel_remaining=", step.fuelRemaining,
        " spatial_calls=", step.counters.spatialCalls
      check not step.faulted
      check step.returned == 0
      check consumed < StepFuel.uint64

    block large:
      var instance = engine.newEdgeInstance(module, map, (550, 300))
      defer: instance.close()
      instance.initOk("{}")
      let view = fullViewFor(1441, (550, 300), [400, 200, 1200, 700], 240,
        tracks = 32)
      let step = instance.invokeStep(view, 1441, (550, 300))
      echo "EDGE_RIDE_VIEW_FUEL kind=large view_len=", view.len,
        " tracks=32 consumed=", step.fuelConsumed,
        " completed=", (not step.faulted and step.returned == 0),
        " fuel_remaining=", step.fuelRemaining,
        " spatial_calls=", step.counters.spatialCalls

  test "head-to-head reaches the next rectangle before the default trigger":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.edgeModule()
    defer: module.close()
    let map = testMap()
    var edge = engine.newEdgeInstance(module, map, (760, 260))
    defer: edge.close()
    edge.initOk("{\"coverBias\":0.0,\"enterLead\":200,\"margin\":80}")

    let
      current = [400, 200, 1200, 700]
      next = [900, 450, 350, 300]
      rotateTarget = (1075, 600)
    var
      edgePos: BodyPoint = (760, 260)
      defaultPos: BodyPoint = (760, 260)
      edgeInsideBeforeDefault = false
      defaultOutsideBeforeTrigger = false
      edgeHeldMargin = false

    for ticksToShrink in [240, 200, 160, 120, 80, 40, 0]:
      let edgeStep = edge.invokeStep(viewFor(240 - ticksToShrink, edgePos,
        current, ticksToShrink, next), uint32(240 - ticksToShrink), edgePos)
      check not edgeStep.faulted
      check edgeStep.returned == 0
      let defaultStep = defaultDecision(map, defaultPos, ticksToShrink,
        rotateTarget)

      if edgeStep.lastAccepted.isSome and
          edgeStep.lastAccepted.get.intent.kind == ikNavigateTo:
        edgePos = advance(edgePos, edgeStep.pointOf, 140.0)
      if defaultStep.intent.kind == ikNavigateTo:
        let target = defaultStep.intent.point.get
        defaultPos = advance(defaultPos, (target.x, target.y), 140.0)

      if ticksToShrink == 240 and edgeStep.reasonOf == "edge_ride:margin":
        edgeHeldMargin = true
      if ticksToShrink > BrRotateLeadTicks:
        edgeInsideBeforeDefault = edgeInsideBeforeDefault or next.rectContains(edgePos)
        defaultOutsideBeforeTrigger = defaultOutsideBeforeTrigger or
          not next.rectContains(defaultPos)

      echo "EDGE_RIDE_HEAD_TO_HEAD tts=", ticksToShrink,
        " edge=(", edgePos.x, ",", edgePos.y, ")",
        " edge_reason=", edgeStep.reasonOf,
        " edge_in_next=", next.rectContains(edgePos),
        " default=(", defaultPos.x, ",", defaultPos.y, ")",
        " default_rule=", defaultStep.rule,
        " default_in_next=", next.rectContains(defaultPos)

    check edgeHeldMargin
    check edgeInsideBeforeDefault
    check defaultOutsideBeforeTrigger
    check next.rectContains(edgePos)
