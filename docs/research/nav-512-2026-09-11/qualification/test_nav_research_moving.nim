## Focused probe for the `nav_research_moving` qualification play through the
## production runtime, validator and instance path. Run from the repo root:
##   nim c -r -d:release -d:noSignalHandler --threads:on docs/research/nav-512-2026-09-11/qualification/test_nav_research_moving.nim
## Needs WASMTIME_C_API and WASI_SDK_PATH (tools/runtime_spike/fetch_deps.sh).

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../../../../src/ctf/sim_types
import ../../../../src/shell/[abi, binary_view, body_map, emit_validator,
  instance, manifest, module_validation, runtime, types, view]

const
  QualificationDir = currentSourcePath.parentDir
  PlaySource = QualificationDir / "nav_research_moving.nim"
  PlayWasm = QualificationDir / ".build" / "nav_research_moving.wasm"

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

proc buildPlayWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(PlaySource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(PlayWasm)
  readFile(PlayWasm).toOpenArrayByte(0, getFileSize(PlayWasm).int - 1).toSeq

proc testMap(): BodyMap =
  ## Open 1800x1100 floor with two walls, as in the edge_ride probe.
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

proc viewFor(tick: int; self: BodyPoint; current: array[4, int];
             withZone = true): string =
  buildBinaryPlayView(PlayViewSource(
    tick: uint32(tick),
    mode: gmBr,
    callNumber: 0,
    self: PlaySelf(pos: self, hp: 2, hpFrac: 1.0, aimBrads: 32, alive: true),
    aliveTeams: 9,
    zone: if withZone:
        some(PlayZone(phase: 2,
          current: PlayRect(x: current[0], y: current[1], w: current[2], h: current[3]),
          next: none(PlayRect), ticksToShrink: 240, dps: 1))
      else: none(PlayZone),
    tracks: @[]))

proc pointOf(invocation: ShellInvocationResult): BodyPoint =
  let point = invocation.lastAccepted.get.intent.point.get
  (point.x, point.y)

suite "nav_research_moving qualification play":
  let engine = newRuntimeEngine()
  let module = engine.checkedModule(buildPlayWasm())
  let map = testMap()
  let current = [400, 200, 1200, 700]

  test "manifest is the registered name with no params and parses in production":
    var instance = newShellInstance(module, map, (550, 300), ecController, gmBr)
    defer: instance.close()
    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "nav_research_moving"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]
    check parsed.params.len == 0

  test "init logs once so a full-game runner can prove every seat loaded":
    var instance = newShellInstance(module, map, (550, 300), ecController, gmBr)
    defer: instance.close()
    let init = instance.invokeInit("{}", "{}")
    check not init.faulted
    check init.returned == 0
    check init.logs.len == 1
    check init.logs[0].level == 1
    check init.logs[0].bytes == "nav_research_moving initialized"

  test "emits a valid moving-goal intent once per 12-tick interval, alternating quarters and profiles":
    var instance = newShellInstance(module, map, (550, 300), ecController, gmBr)
    defer: instance.close()
    discard instance.invokeInit("{}", "{}")
    var emitted = 0
    var previous: BodyPoint
    for tick in 0 ..< 48:
      let step = instance.invokeStep(viewFor(tick, (550, 300), current), uint32(tick), (550, 300))
      check not step.faulted
      check step.returned == 0
      check step.counters.spatialCalls <= 1
      if tick mod 12 == 0:
        check step.counters.emits == 1
        require step.lastAccepted.isSome
        let intent = step.lastAccepted.get.intent
        check intent.kind == ikNavigateTo
        check intent.movingGoal
        check intent.arriveRadius == 24.0
        let odd = (tick div 12) mod 2 == 1
        check intent.profile == (if odd: cpHunter else: cpCarrier)
        check intent.reason == (if odd: "nav_research_moving:hunter" else: "nav_research_moving:carrier")
        let point = step.pointOf
        # Quarter centres of [400,200,1200,700]: (700,375) even, (1300,725) odd,
        # before the engine snaps to the nearest reachable pixel.
        let expected: BodyPoint = if odd: (1300, 725) else: (700, 375)
        check abs(point.x - expected.x) <= 16
        check abs(point.y - expected.y) <= 16
        if emitted > 0:
          check point != previous
        previous = point
        inc emitted
      else:
        check step.counters.emits == 0
    check emitted == 4

  test "a shrinking zone moves the quarter goals with it":
    var instance = newShellInstance(module, map, (550, 300), ecController, gmBr)
    defer: instance.close()
    discard instance.invokeInit("{}", "{}")
    let first = instance.invokeStep(viewFor(0, (550, 300), current), 0, (550, 300))
    let shrunk = [800, 400, 400, 200]
    let second = instance.invokeStep(viewFor(12, (550, 300), shrunk), 12, (550, 300))
    check first.counters.emits == 1 and second.counters.emits == 1
    let p = second.pointOf
    check abs(p.x - 1100) <= 16 and abs(p.y - 550) <= 16

  test "without a zone the play falls back to fixed goals on its own step clock":
    var instance = newShellInstance(module, map, (550, 300), ecController, gmBr)
    defer: instance.close()
    discard instance.invokeInit("{}", "{}")
    var emits = 0
    for tick in 0 ..< 24:
      let step = instance.invokeStep(viewFor(tick, (550, 300), current, withZone = false), uint32(tick), (550, 300))
      check not step.faulted
      emits += step.counters.emits.int
      if tick == 0:
        check step.pointOf == (256, 256)
      if tick == 12:
        check step.pointOf == (1024, 768)
    check emits == 2

  module.close()
  engine.close()
