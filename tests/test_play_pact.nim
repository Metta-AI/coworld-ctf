## Reference `pact` play through the production shell runtime path.

import std/[json, options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, body_map, emit_validator, instance, manifest,
  module_validation, play_harness_core, runtime, types]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  HarnessFixtureDir = FixtureDir / "play_harness"
  PactSource = "play_sdk" / "reference" / "pact.nim"
  PactWasm = "play_sdk" / ".build" / "pact.wasm"
  ViewProbeSource = "play_sdk" / "test_fixtures" / "view_probe.nim"
  ViewProbeWasm = "play_sdk" / ".build" / "view_probe.wasm"
  ViewMeterSource = "play_sdk" / "test_fixtures" / "view_meter.nim"
  ViewMeterWasm = "play_sdk" / ".build" / "view_meter.wasm"
  ViewMeterDangerWasm = "play_sdk" / ".build" / "view_meter_danger.wasm"
  ViewFloorSource = "play_sdk" / "test_fixtures" / "view_floor.nim"
  ViewFloorWasm = "play_sdk" / ".build" / "view_floor.wasm"
  ViewFloorDangerWasm = "play_sdk" / ".build" / "view_floor_danger.wasm"

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

proc buildWasm(source, output: string; extraFlags = ""): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & extraFlags & (if extraFlags.len > 0: " " else: "") &
    quoteShell(source)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(output)
  readFile(output).toOpenArrayByte(0, getFileSize(output).int - 1).toSeq

proc pactBytes(): seq[byte] =
  buildWasm(PactSource, PactWasm)

proc viewProbeBytes(): seq[byte] =
  buildWasm(ViewProbeSource, ViewProbeWasm)

proc viewMeterBytes(): seq[byte] =
  buildWasm(ViewMeterSource, ViewMeterWasm)

proc viewMeterDangerBytes(): seq[byte] =
  buildWasm(ViewMeterSource, ViewMeterDangerWasm, "-d:danger")

proc viewFloorBytes(): seq[byte] =
  buildWasm(ViewFloorSource, ViewFloorWasm)

proc viewFloorDangerBytes(): seq[byte] =
  buildWasm(ViewFloorSource, ViewFloorDangerWasm, "-d:danger")

proc openRoomsMap(): BodyMap =
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

proc withDuo(duos: var array[Team, DuoSeats], team: Team, a, b: int) =
  duos[team] = DuoSeats(configured: true,
    seats: [SeatRef(uint8(a)), SeatRef(uint8(b))])

proc checkedModule(engine: RuntimeEngine; bytes: seq[byte]): RuntimeModule =
  var validation = engine.validateUploadedModule(bytes)
  require validation.accepted
  result = validation.module
  validation.module = nil
  validation.close()

proc newPactInstance(engine: RuntimeEngine;
                     duos: array[Team, DuoSeats] =
                       default(array[Team, DuoSeats])): ShellInstance =
  newShellInstance(engine.checkedModule(pactBytes()), openRoomsMap(), (30, 30),
    ecOverlay, gmBr, duos)

proc policyBytes(seats: openArray[int]; protect = false): string =
  var policy = CombatPolicy()
  for seat in seats:
    policy.noShoot.seats.add(SeatRef(uint8(seat)))
    if protect:
      policy.protect.seats.add(SeatRef(uint8(seat)))
  canonicalCombatPolicy(policy)

proc viewStep(engine: RuntimeEngine; module: RuntimeModule; viewBytes: string):
    ShellInvocationResult =
  var instance = newShellInstance(module, openRoomsMap(), (30, 30),
    ecOverlay, gmBr)
  defer: instance.close()
  let init = instance.invokeInit("{\"holdFire\":{\"tick\":999999}," &
    "\"partners\":[\"seat:7\"]}", "{}")
  doAssert not init.faulted and init.returned == 0
  instance.invokeStep(viewBytes, 1, (30, 30))

proc readerStep(engine: RuntimeEngine; module: RuntimeModule; viewBytes: string):
    ShellInvocationResult =
  var instance = newShellInstance(module, openRoomsMap(), (30, 30),
    ecOverlay, gmBr)
  defer: instance.close()
  let init = instance.invokeInit("{}", "{}")
  doAssert not init.faulted and init.returned == 0
  instance.invokeStep(viewBytes, 1, (30, 30))

proc trackRow(index: int): string =
  "{\"aim_brads\":" & $(index mod 256) & ",\"bounty\":" &
    (if index mod 2 == 0: "true" else: "false") &
    ",\"fresh_tick\":" & $(1000 + index) & ",\"hp\":" &
    $(1 + index mod 3) & ",\"pos\":[" & $(100 + index) & "," &
    $(200 + index) & "],\"seat\":" & $index & ",\"team\":\"" &
    (if index mod 2 == 0: "navy" else: "rust") & "\"}"

proc aggressorRow(index: int): string =
  if index mod 2 == 0:
    "{\"dir_brads\":" & $(index mod 256) & ",\"seat\":" & $index &
      ",\"tick\":" & $(2000 + index) & "}"
  else:
    "{\"dir_brads\":" & $(index mod 256) & ",\"tick\":" &
      $(2000 + index) & "}"

proc joinRows(count: int; row: proc(index: int): string): string =
  for index in 0 ..< count:
    if index > 0:
      result.add ","
    result.add row(index)

proc simpleItem(index: int): string =
  "{\"fresh_tick\":" & $(3000 + index) & ",\"kind\":\"medkit\"," &
    "\"pos\":[" & $(300 + index) & "," & $(400 + index) &
    "],\"present\":true}"

proc killFeedRow(index: int): string =
  "{\"killer_team\":\"" & (if index mod 2 == 0: "navy" else: "rust") &
    "\",\"tick\":" & $(4000 + index) & ",\"victim_seat\":" &
    $(index mod MaxPlayers) & "}"

proc shoutRow(index: int): string =
  "{\"pos\":[" & $(500 + index) & "," & $(600 + index) &
    "],\"slot_letter\":\"A\",\"team\":\"navy\",\"text\":\"go\"," &
    "\"tick\":" & $(5000 + index) & "}"

proc grenadeRow(index: int): string =
  "{\"pos\":[" & $(600 + index) & "," & $(700 + index) &
    "],\"predicted_blast_pos\":[" & $(610 + index) & "," &
    $(710 + index) & "],\"ticks_to_blast\":" & $(10 + index) & "}"

proc sprayRow(index: int): string =
  "{\"impact_pos\":[" & $(700 + index) & "," & $(800 + index) &
    "],\"incoming_dir_brads\":" & $(index mod 256) &
    ",\"kind\":\"anonymous_impact\",\"tick\":" & $(6000 + index) & "}"

proc syntheticView(tracks = 0; items = 0; aggressors = 0; killFeed = 0;
                   shouts = 0; grenades = 0; sprays = 0): string =
  result = "{\"aggressors\":[" & joinRows(aggressors, aggressorRow) &
    "],\"epoch\":\"99\",\"hazards\":{\"grenades\":[" &
    joinRows(grenades, grenadeRow) & "],\"own_throw\":{\"blast_radius\":96," &
    "\"release_tick\":1,\"target\":[640,380]},\"sprays\":[" &
    joinRows(sprays, sprayRow) & "]},\"intent\":{\"arrive_radius\":24.0," &
    "\"kind\":\"navigate_to\",\"point\":[700,300],\"schema\":\"intent\"," &
    "\"v\":1},\"items\":[" & joinRows(items, simpleItem) &
    "],\"kill_feed\":[" & joinRows(killFeed, killFeedRow) &
    "],\"schema\":\"play_view\",\"self\":{\"aim_brads\":32," &
    "\"alive\":true,\"hp\":2,\"hp_frac\":0.666666,\"pos\":[512,288]}," &
    "\"shouts\":[" & joinRows(shouts, shoutRow) & "],\"tick\":1441," &
    "\"tracks\":[" & joinRows(tracks, trackRow) &
    "],\"v\":1,\"world\":{\"alive_teams\":9,\"zone\":{\"current\":" &
    "[400,200,1600,900],\"dps\":1,\"next\":[700,350,800,450]," &
    "\"phase\":2,\"ticks_to_shrink\":240}}"
  result.add "}"

proc requiredOnlyView(): string =
  "{\"epoch\":\"0\",\"schema\":\"play_view\",\"self\":{\"aim_brads\":32," &
    "\"alive\":true,\"hp\":2,\"hp_frac\":0.666666,\"pos\":[512,288]}," &
    "\"tick\":1,\"v\":1,\"world\":{\"alive_teams\":2}}"

proc bytePayload(length: int): string =
  repeat("x", length)

proc fuelConsumed(invocation: ShellInvocationResult): uint64 =
  if invocation.faulted and invocation.reason.contains("all fuel consumed"):
    StepFuel.uint64
  else:
    StepFuel.uint64 - invocation.fuelRemaining

proc completedFuel(engine: RuntimeEngine; module: RuntimeModule;
                   viewBytes: string): uint64 =
  let measured = engine.readerStep(module, viewBytes)
  check not measured.faulted
  check measured.returned == 0
  measured.fuelConsumed

proc viewFor(tick, aliveTeams, zonePhase: int;
             tracks = ""; aggressors = ""): string =
  "{\"aggressors\":[" & aggressors & "],\"schema\":\"play_view\"," &
    "\"tick\":" & $tick & ",\"tracks\":[" & tracks & "],\"v\":1," &
    "\"world\":{\"alive_teams\":" & $aliveTeams & ",\"zone\":{\"phase\":" &
    $zonePhase & "}}}"

proc initOk(instance: ShellInstance; params: string) =
  let init = instance.invokeInit(params, "{}")
  check not init.faulted
  check init.returned == 0

proc step(instance: ShellInstance; view: string; tick = 1'u32):
    ShellInvocationResult =
  instance.invokeStep(view, tick, (30, 30))

suite "pact reference play":
  test "manifest bytes match the PM-ratified golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.checkedModule(pactBytes())
    defer: module.close()
    var instance = newShellInstance(module, openRoomsMap(), (30, 30), ecOverlay,
      gmBr)
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_pact.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "pact"
    check parsed.playClass == mcOverlay

  test "params decode defaults, required partners, and both non-default union arms":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var instance = engine.newPactInstance()
    defer: instance.close()

    instance.initOk("{\"partners\":[\"seat:7\"]}")
    let defaultStep = instance.step(viewFor(1, 2, 1))
    check not defaultStep.faulted
    check defaultStep.lastAccepted.get.bytes ==
      canonicalCombatPolicy(CombatPolicy())

    var missing = engine.newPactInstance()
    defer: missing.close()
    let refused = missing.invokeInit("{}", "{}")
    check refused.faulted
    check refused.reason == "play_init returned nonzero"

    var tickArm = engine.newPactInstance()
    defer: tickArm.close()
    tickArm.initOk("{\"holdFire\":{\"tick\":10},\"partners\":[\"seat:7\"]}")
    check tickArm.step(viewFor(9, 9, 1)).lastAccepted.get.bytes ==
      policyBytes([7])
    check tickArm.step(viewFor(10, 9, 1)).lastAccepted.get.bytes ==
      canonicalCombatPolicy(CombatPolicy())

    var zoneArm = engine.newPactInstance()
    defer: zoneArm.close()
    zoneArm.initOk("{\"holdFire\":{\"zonePhase\":3},\"partners\":[\"seat:7\"]}")
    check zoneArm.step(viewFor(1, 9, 2)).lastAccepted.get.bytes ==
      policyBytes([7])
    check zoneArm.step(viewFor(1, 9, 3)).lastAccepted.get.bytes ==
      canonicalCombatPolicy(CombatPolicy())

    var invalidPartner = engine.newPactInstance()
    defer: invalidPartner.close()
    let invalidInit = invalidPartner.invokeInit(
      "{\"partners\":[\"seat:7\",\"bogus\"],\"protect\":true}", "{}")
    check invalidInit.faulted
    check invalidInit.reason == "play_init returned nonzero"

  test "policy emissions are accepted and fold to host canonical bytes":
    let engine = newRuntimeEngine()
    defer: engine.close()

    var seatOnly = engine.newPactInstance()
    defer: seatOnly.close()
    seatOnly.initOk("{\"holdFire\":{\"tick\":9999},\"partners\":[\"seat:7\"]," &
      "\"protect\":true}")
    let seatStep = seatOnly.step(viewFor(1, 9, 1))
    check not seatStep.faulted
    check seatStep.emitCodes == @[AbiOk]
    check seatStep.lastAccepted.get.bytes == policyBytes([7], protect = true)

    var duos: array[Team, DuoSeats]
    duos.withDuo(Navy, 10, 2)
    var duo = engine.newPactInstance(duos)
    defer: duo.close()
    duo.initOk("{\"holdFire\":{\"tick\":9999},\"partners\":[\"duo:navy\"]," &
      "\"protect\":true}")
    let duoStep = duo.step(viewFor(1, 9, 1,
      tracks = "{\"fresh_tick\":1,\"pos\":[1,2],\"seat\":10," &
        "\"team\":\"navy\"},{\"fresh_tick\":1,\"pos\":[3,4]," &
        "\"seat\":2,\"team\":\"navy\"}"))
    check not duoStep.faulted
    check duoStep.emitCodes == @[AbiOk]
    check duoStep.lastAccepted.get.bytes == policyBytes([10, 2],
      protect = true)

  test "end conditions hit equality boundaries and latch across retune":
    let engine = newRuntimeEngine()
    defer: engine.close()

    for paramsView in [
      ("{\"holdFire\":{\"aliveTeams\":3},\"partners\":[\"seat:7\"]}",
        viewFor(1, 3, 1)),
      ("{\"holdFire\":{\"zonePhase\":3},\"partners\":[\"seat:7\"]}",
        viewFor(1, 9, 3)),
      ("{\"holdFire\":{\"tick\":7},\"partners\":[\"seat:7\"]}",
        viewFor(7, 9, 1))]:
      var instance = engine.newPactInstance()
      defer: instance.close()
      instance.initOk(paramsView[0])
      let ended = instance.step(paramsView[1])
      check not ended.faulted
      check ended.lastAccepted.get.bytes == canonicalCombatPolicy(CombatPolicy())
      let retune = instance.invokeRetune(paramsView[0],
        "{\"holdFire\":{\"tick\":9999},\"partners\":[\"seat:7\"]," &
        "\"protect\":true}")
      check not retune.faulted
      check not retune.refused
      let after = instance.step(viewFor(1, 9, 1))
      check not after.faulted
      check after.emitCodes.len == 0
      check after.lastAccepted.get.bytes == canonicalCombatPolicy(CombatPolicy())

  test "betrayal returnFire and disengage latch only for identified partners":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let view = viewFor(1, 9, 1,
      aggressors = "{\"dir_brads\":1,\"seat\":7,\"tick\":1}")

    var returnFire = engine.newPactInstance()
    defer: returnFire.close()
    returnFire.initOk("{\"holdFire\":{\"tick\":9999}," &
      "\"onBetrayal\":\"returnFire\",\"partners\":[\"seat:7\",\"seat:8\"]," &
      "\"protect\":true}")
    check returnFire.step(view).lastAccepted.get.bytes ==
      policyBytes([8], protect = true)
    check returnFire.step(viewFor(2, 9, 1)).lastAccepted.get.bytes ==
      policyBytes([8], protect = true)

    var disengage = engine.newPactInstance()
    defer: disengage.close()
    disengage.initOk("{\"holdFire\":{\"tick\":9999}," &
      "\"onBetrayal\":\"disengage\",\"partners\":[\"seat:7\",\"seat:8\"]," &
      "\"protect\":true}")
    check disengage.step(view).lastAccepted.get.bytes ==
      canonicalCombatPolicy(CombatPolicy(noShoot: ProtectedSet(seats: @[
        SeatRef(7), SeatRef(8)]), protect: ProtectedSet(seats: @[
        SeatRef(8)])))

    var anonymous = engine.newPactInstance()
    defer: anonymous.close()
    anonymous.initOk("{\"holdFire\":{\"tick\":9999},\"partners\":[\"seat:7\"]," &
      "\"protect\":true}")
    check anonymous.step(viewFor(1, 9, 1,
      aggressors = "{\"dir_brads\":1,\"tick\":1}")).lastAccepted.get.bytes ==
      policyBytes([7], protect = true)

  test "duo betrayal expands to remaining concrete seats":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var duos: array[Team, DuoSeats]
    duos.withDuo(Navy, 10, 2)
    let tracks = "{\"fresh_tick\":1,\"pos\":[1,2],\"seat\":10," &
      "\"team\":\"navy\"},{\"fresh_tick\":1,\"pos\":[3,4]," &
      "\"seat\":2,\"team\":\"navy\"}"
    let betrayed = viewFor(1, 9, 1, tracks = tracks,
      aggressors = "{\"dir_brads\":1,\"seat\":10,\"tick\":1}")

    var returnFire = engine.newPactInstance(duos)
    defer: returnFire.close()
    returnFire.initOk("{\"holdFire\":{\"tick\":9999}," &
      "\"onBetrayal\":\"returnFire\",\"partners\":[\"duo:navy\"]," &
      "\"protect\":true}")
    let returned = returnFire.step(betrayed)
    check not returned.faulted
    check returned.emitCodes == @[AbiOk]
    check returned.lastAccepted.get.bytes == policyBytes([2], protect = true)

    var disengage = engine.newPactInstance(duos)
    defer: disengage.close()
    disengage.initOk("{\"holdFire\":{\"tick\":9999}," &
      "\"onBetrayal\":\"disengage\",\"partners\":[\"duo:navy\"]," &
      "\"protect\":true}")
    let disengaged = disengage.step(betrayed)
    check not disengaged.faulted
    check disengaged.lastAccepted.get.bytes ==
      canonicalCombatPolicy(CombatPolicy(noShoot: ProtectedSet(seats: @[
        SeatRef(2), SeatRef(10)]), protect: ProtectedSet(seats: @[
        SeatRef(2)])))

  test "unchanged policy emits only once":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var instance = engine.newPactInstance()
    defer: instance.close()
    instance.initOk("{\"holdFire\":{\"tick\":9999},\"partners\":[\"seat:7\"]}")
    check instance.step(viewFor(1, 9, 1)).emitCodes == @[AbiOk]
    let quiet = instance.step(viewFor(2, 9, 1))
    check quiet.emitCodes.len == 0
    check quiet.lastAccepted.get.bytes == policyBytes([7])

  test "SDK view reader decodes golden, absent optional, unknown fields, and anonymous seats":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.checkedModule(viewProbeBytes())
    defer: module.close()
    for fixture in ["play_view.golden.json",
                    "play_view_absent_optional.golden.json",
                    "play_view_unknown_fields.golden.json"]:
      var instance = newShellInstance(module, openRoomsMap(), (30, 30),
        ecOverlay, gmBr)
      defer: instance.close()
      let init = instance.invokeInit(readFile(FixtureDir / fixture).strip, "{}")
      checkpoint(fixture & " init reason=" & init.reason & " returned=" &
        $init.returned)
      check not init.faulted
      check init.returned == 0
      let result = instance.step("{}", 1)
      checkpoint(fixture & " step reason=" & result.reason & " returned=" &
        $result.returned)
      check not result.faulted
      check result.returned == 0
      check result.emitCodes == @[AbiOk]

  test "harness cross-checks emit_class against manifest class":
    let engine = newRuntimeEngine()
    defer: engine.close()
    discard pactBytes()
    let caseJson = "{\"emit_class\":\"controller\",\"module\":\"" &
      PactWasm & "\",\"frames\":[{\"op\":\"manifest\"}]}"
    expect HarnessError:
      discard runHarnessJson(caseJson)

  test "pact harness golden uses overlay class":
    discard pactBytes()
    let path = HarnessFixtureDir / "pact_success.case.json"
    let output = runHarnessFile(path)
    check output == readFile(HarnessFixtureDir / "pact_success.golden.json").strip
    let parsed = parseJson(output)
    check parsed["accepted"].getBool
    check parsed["manifest_name"].getStr == "pact"
    check parsed["frames"][2]["emit_codes"][0].getInt == AbiOk

  test "view-decode fuel rows use real content and only completed rates":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let pactModule = engine.checkedModule(pactBytes())
    defer: pactModule.close()
    let floorModule = engine.checkedModule(viewFloorBytes())
    defer: floorModule.close()
    let floorDangerModule = engine.checkedModule(viewFloorDangerBytes())
    defer: floorDangerModule.close()
    let meterModule = engine.checkedModule(viewMeterBytes())
    defer: meterModule.close()
    let meterDangerModule = engine.checkedModule(viewMeterDangerBytes())
    defer: meterDangerModule.close()

    let goldenView = readFile(FixtureDir / "play_view.golden.json")
    let pactGolden = engine.viewStep(pactModule, goldenView)
    echo "PACT_VIEW_FUEL golden_len=", goldenView.len,
      " golden_consumed=", pactGolden.fuelConsumed,
      " golden_completed=", (not pactGolden.faulted and pactGolden.returned == 0),
      " exhausted_lower_bound=", pactGolden.faulted

    let maxView = syntheticView(tracks = 32, items = 32, aggressors = 16,
      killFeed = 32, shouts = 32, grenades = 8, sprays = 8)
    check maxView.len <= MaxViewFrameBytes

    proc reportFloor(build: string; module: RuntimeModule) =
      let small = requiredOnlyView()
      let large = bytePayload(1958)
      let smallFuel = engine.completedFuel(module, small)
      let largeFuel = engine.completedFuel(module, large)
      let marginalFuel = int64(largeFuel) - int64(smallFuel)
      let marginalBytes = large.len - small.len
      echo "VIEW_BYTE_FLOOR build=", build,
        " small_bytes=", small.len,
        " small_consumed=", smallFuel,
        " large_bytes=", large.len,
        " large_consumed=", largeFuel,
        " marginal_fuel=", marginalFuel,
        " marginal_bytes=", marginalBytes,
        " marginal_insn_per_byte=", (marginalFuel.float / marginalBytes.float)

    proc reportReader(build: string; module: RuntimeModule) =
      let minimal = requiredOnlyView()
      let fixedFuel = engine.completedFuel(module, minimal)
      var largestCompleted = minimal.len
      var largestCompletedLabel = "required"
      var worstMarginalFuel = 0'i64
      var worstMarginalBytes = 1
      var worstMarginalSource = ""
      proc recordMarginal(source: string; fuelDelta: int64; byteDelta: int) =
        if byteDelta > 0 and fuelDelta > 0:
          if worstMarginalFuel == 0 or
              fuelDelta * int64(worstMarginalBytes) >
                worstMarginalFuel * int64(byteDelta):
            worstMarginalFuel = fuelDelta
            worstMarginalBytes = byteDelta
            worstMarginalSource = source

      echo "VIEW_READER_FUEL build=", build,
        " kind=required rows=0 bytes=", minimal.len,
        " consumed=", fixedFuel,
        " completed=true insn_per_byte=", (fixedFuel.float / minimal.len.float)

      let fullEmpty = syntheticView()
      let fullEmptyFuel = engine.completedFuel(module, fullEmpty)
      if fullEmpty.len > largestCompleted:
        largestCompleted = fullEmpty.len
        largestCompletedLabel = "full_empty"
      recordMarginal("full_empty-required",
        int64(fullEmptyFuel) - int64(fixedFuel), fullEmpty.len - minimal.len)
      echo "VIEW_READER_FUEL build=", build,
        " kind=full_empty rows=0 bytes=", fullEmpty.len,
        " consumed=", fullEmptyFuel,
        " completed=true marginal_fuel=",
        int64(fullEmptyFuel) - int64(fixedFuel),
        " marginal_bytes=", fullEmpty.len - minimal.len,
        " marginal_fuel_per_byte=",
        ((int64(fullEmptyFuel) - int64(fixedFuel)).float /
          (fullEmpty.len - minimal.len).float),
        " insn_per_byte=", (fullEmptyFuel.float / fullEmpty.len.float)

      for kind in ["tracks", "items", "aggressors", "kill_feed", "shouts",
                   "grenades", "sprays"]:
        var lastAttemptRows = 0
        var previousRows = 0
        var previousBytes = fullEmpty.len
        var previousFuel = fullEmptyFuel
        for rows in [1, 2, 4, 8, 16, 32]:
          let capped =
            case kind
            of "aggressors": min(rows, 16)
            of "grenades", "sprays": min(rows, 8)
            else: rows
          if capped == lastAttemptRows:
            continue
          lastAttemptRows = capped
          let view =
            case kind
            of "tracks": syntheticView(tracks = capped)
            of "items": syntheticView(items = capped)
            of "aggressors": syntheticView(aggressors = capped)
            of "kill_feed": syntheticView(killFeed = capped)
            of "shouts": syntheticView(shouts = capped)
            of "grenades": syntheticView(grenades = capped)
            else: syntheticView(sprays = capped)
          check view.len <= MaxViewFrameBytes
          let measured = engine.readerStep(module, view)
          let consumed = measured.fuelConsumed
          let completed = not measured.faulted and measured.returned == 0
          let marginalRows = capped - previousRows
          let marginalFuel = int64(consumed) - int64(previousFuel)
          let marginalBytes = view.len - previousBytes
          if completed:
            if view.len > largestCompleted:
              largestCompleted = view.len
              largestCompletedLabel = kind & ":" & $capped
            recordMarginal(kind & ":" & $previousRows & "->" & $capped,
              marginalFuel, marginalBytes)
            echo "VIEW_READER_FUEL build=", build,
              " kind=", kind, " rows=", capped,
              " bytes=", view.len, " consumed=", consumed,
              " completed=true marginal_fuel=", marginalFuel,
              " marginal_bytes=", marginalBytes,
              " marginal_fuel_per_row=",
              (marginalFuel.float / marginalRows.float),
              " marginal_fuel_per_byte=",
              (marginalFuel.float / marginalBytes.float),
              " insn_per_byte=", (consumed.float / view.len.float)
            previousRows = capped
            previousBytes = view.len
            previousFuel = consumed
          else:
            echo "VIEW_READER_FUEL build=", build,
              " kind=", kind, " rows=", capped,
              " bytes=", view.len, " consumed_lower_bound=", consumed,
              " completed=false"

      let maxResult = engine.readerStep(module, maxView)
      echo "VIEW_READER_MAX build=", build,
        " len=", maxView.len,
        " consumed=", maxResult.fuelConsumed,
        " completed=", (not maxResult.faulted and maxResult.returned == 0),
        " exhausted_lower_bound=", maxResult.faulted

      var proportionalLargestCompleted = 0
      var previousProportionalRows = -1
      var previousProportionalBytes = 0
      var previousProportionalFuel = 0'u64
      for rows in [0, 1, 2, 4, 8, 16, 32]:
        let view = syntheticView(tracks = rows, items = rows,
          aggressors = min(rows, 16), killFeed = rows, shouts = rows,
          grenades = min(rows, 8), sprays = min(rows, 8))
        let measured = engine.readerStep(module, view)
        if not measured.faulted and measured.returned == 0:
          proportionalLargestCompleted = view.len
          let consumed = measured.fuelConsumed
          if previousProportionalRows >= 0:
            recordMarginal("proportional:" & $previousProportionalRows &
              "->" & $rows, int64(consumed) - int64(previousProportionalFuel),
              view.len - previousProportionalBytes)
          previousProportionalRows = rows
          previousProportionalBytes = view.len
          previousProportionalFuel = consumed
          echo "VIEW_READER_PROPORTIONAL build=", build,
            " rows=", rows, " bytes=", view.len,
            " consumed=", consumed, " completed=true"
        else:
          echo "VIEW_READER_PROPORTIONAL build=", build,
            " rows=", rows, " bytes=", view.len,
            " consumed_lower_bound=", measured.fuelConsumed,
            " completed=false"
      echo "VIEW_READER_LARGEST_COMPLETED build=", build,
        " len=", largestCompleted,
        " source=", largestCompletedLabel,
        " proportional_len=", proportionalLargestCompleted
      check worstMarginalFuel > 0
      let budget = (StepFuel * 60) div 100
      var affordable = 0'i64
      if int64(budget) > int64(fixedFuel):
        affordable = ((int64(budget) - int64(fixedFuel)) *
          int64(worstMarginalBytes)) div worstMarginalFuel
      var cap = 0
      var pow2 = 1
      while int64(pow2) <= affordable:
        cap = pow2
        pow2 *= 2
      echo "VIEW_READER_CAP_DERIVED build=", build,
        " fixed=", fixedFuel,
        " budget=", budget,
        " marginal_source=", worstMarginalSource,
        " marginal_fuel=", worstMarginalFuel,
        " marginal_bytes=", worstMarginalBytes,
        " marginal_insn_per_byte=",
        (worstMarginalFuel.float / worstMarginalBytes.float),
        " affordable_bytes=", affordable,
        " candidate_power2=", cap

    reportFloor("release", floorModule)
    reportFloor("danger", floorDangerModule)
    reportReader("release_scoped_unchecked_reader", meterModule)
    reportReader("danger_global", meterDangerModule)
