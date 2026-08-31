import std/[os, strutils, unittest]

import shell/[manifest, module_interface, module_validation, runtime, types,
  wasmtime_c]

const FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell" / "wasm"

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "hostile fixture WAT must be syntactically valid"
  defer: wasmByteVecDelete(addr output)
  result = newSeq[byte](output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc fixture(name: string): seq[byte] =
  watBytes(readFile(FixtureDir / (name & ".wat")))

proc countedValidWat(count: int): string =
  doAssert count >= 4
  result = "(module\n" &
    "(import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "(memory (export \"memory\") 1 16)\n" &
    "(data (i32.const 0) \"{\\22abi\\22:1,\\22class\\22:\\22controller\\22,\\22modes\\22:[\\22br\\22],\\22name\\22:\\22alpha\\22,\\22params\\22:{},\\22retune\\22:false}\")\n"
  for _ in 0 ..< count - 4:
    result.add "(func)\n"
  result.add "(func (export \"play_alloc\") (param i32) (result i32) i32.const 1)\n"
  result.add "(func (export \"play_manifest\") i32.const 0 i32.const 87 call $emit drop)\n"
  result.add "(func (export \"play_init\") (param i32 i32 i32 i32) (result i32) i32.const 0)\n"
  result.add "(func (export \"play_step\") (param i32 i32) (result i32) i32.const 0))"

proc validManifestModule(prefix = ""; manifestBody = ""): string =
  const ManifestBytes =
    "{\\22abi\\22:1,\\22class\\22:\\22controller\\22,\\22modes\\22:[\\22br\\22],\\22name\\22:\\22alpha\\22,\\22params\\22:{},\\22retune\\22:false}"
  result = "(module\n" &
    "(import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    prefix &
    "(memory (export \"memory\") 1 16)\n" &
    "(data (i32.const 0) \"" & ManifestBytes & "\")\n" &
    "(func (export \"play_alloc\") (param i32) (result i32) i32.const 1024)\n" &
    "(func (export \"play_manifest\") " &
      (if manifestBody.len == 0:
        "i32.const 0 i32.const 87 call $emit drop"
      else:
        manifestBody) & ")\n" &
    "(func (export \"play_init\") (param i32 i32 i32 i32) (result i32) i32.const 0)\n" &
    "(func (export \"play_step\") (param i32 i32) (result i32) i32.const 0))"

proc uleb(output: var seq[byte]; value: uint32) =
  var remaining = value
  while true:
    var current = byte(remaining and 0x7f)
    remaining = remaining shr 7
    if remaining != 0: current = current or 0x80
    output.add current
    if remaining == 0: break

proc addSection(module: var seq[byte]; id: byte; body: seq[byte]) =
  module.add id
  module.uleb(body.len.uint32)
  module.add body

proc emptyFunctionsModule(count: int): seq[byte] =
  result = @[byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
  result.addSection(1, @[byte 0x01, 0x60, 0x00, 0x00])
  var functions: seq[byte]
  functions.uleb(count.uint32)
  functions.add newSeq[byte](count)
  result.addSection(3, functions)
  var code: seq[byte]
  code.uleb(count.uint32)
  for _ in 0 ..< count:
    code.add @[byte 0x02, 0x00, 0x0b]
  result.addSection(10, code)

suite "shell module content validation":
  test "fixed-feature validation rejects shared memory before interface":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let before = engine.moduleCompilationCount()
    var outcome = engine.validateUploadedModule(fixture("shared_memory"))
    check outcome.reason == "binaryInvalid"
    check engine.moduleCompilationCount() == before

  test "interface failures are named and remain pre-compile":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for name in ["bad_import", "start", "memory_no_max",
        "wrong_export_signature"]:
      let before = engine.moduleCompilationCount()
      var outcome = engine.validateUploadedModule(fixture(name))
      check outcome.reason == "badInterface"
      check engine.moduleCompilationCount() == before

  test "first failure ordering starts with size then binary then interface":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var oversized = newSeq[byte](MaxModuleBytes + 1)
    var outcome = engine.validateUploadedModule(oversized)
    check outcome.reason == "tooLarge"
    outcome = engine.validateUploadedModule(@[byte 1, 2, 3])
    check outcome.reason == "binaryInvalid"
    outcome = engine.validateUploadedModule(fixture("start"))
    check outcome.reason == "badInterface"

  test "4096 functions pass and return the manifest probe Store slot":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var outcome = engine.validateUploadedModule(
      watBytes(countedValidWat(MaxFunctionsPerModule)))
    defer: outcome.close()
    check outcome.accepted
    check outcome.moduleInterface.definedFunctions == MaxFunctionsPerModule
    check outcome.manifest.name == "alpha"
    check outcome.sha256.len == 64
    # A second probe proves the first probe's one Store was dropped.
    check outcome.module.probeManifestBytes().len == 87

  test "4097 functions are tooManyFunctions before module_new":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let bytes = watBytes(countedValidWat(MaxFunctionsPerModule + 1))
    let before = engine.moduleCompilationCount()
    var outcome = engine.validateUploadedModule(bytes)
    check outcome.reason == "tooManyFunctions"
    check engine.moduleCompilationCount() == before

  test "unbounded and oversized tables are rejected before module_new":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for text in [
        validManifestModule("(table 1 funcref)\n"),
        validManifestModule("(table 1 " &
          $(MaxInstanceTableElements + 1) & " funcref)\n")]:
      let before = engine.moduleCompilationCount()
      var outcome = engine.validateUploadedModule(watBytes(text))
      check outcome.reason == "badInterface"
      check engine.moduleCompilationCount() == before

  test "retained 65529-function control is refused before module_new":
    let bytes = emptyFunctionsModule(65_529)
    check bytes.len <= MaxModuleBytes
    let engine = newRuntimeEngine()
    defer: engine.close()
    let before = engine.moduleCompilationCount()
    var outcome = engine.validateUploadedModule(bytes)
    check outcome.reason == "tooManyFunctions"
    check engine.moduleCompilationCount() == before

  test "manifest probe requires exactly one emission":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for name in ["zero_emit", "two_emit"]:
      var outcome = engine.validateUploadedModule(fixture(name))
      check outcome.reason == "manifestProbe"

    var secondOob = engine.validateUploadedModule(watBytes(validManifestModule(
      manifestBody = "i32.const 0 i32.const 87 call $emit drop " &
        "i32.const 2147483647 i32.const 1 call $emit drop")))
    check secondOob.reason == "manifestProbe"
    check secondOob.detail.contains("play_manifest emitted more than once")
    check not secondOob.detail.contains("byte range")

  test "manifest probe owns traps and enforces fuel and epoch backstop":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for name in ["manifest_trap", "manifest_fuel"]:
      var outcome = engine.validateUploadedModule(fixture(name))
      check outcome.reason == "manifestProbe"

  test "manifest probe rejects OOB, spatial calls, and log flooding":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for name in ["manifest_oob", "manifest_spatial", "manifest_log_flood"]:
      var outcome = engine.validateUploadedModule(fixture(name))
      check outcome.reason == "manifestProbe"

  test "manifest probe Store limiter refuses growth beyond sixteen pages":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var outcome = engine.validateUploadedModule(fixture("manifest_limiter"))
    defer: outcome.close()
    check outcome.accepted

  test "epoch deadline independently interrupts a manifest loop":
    let bytes = fixture("manifest_fuel")
    let engine = newRuntimeEngine()
    defer: engine.close()
    engine.validateModuleBytes(bytes)
    discard inspectModuleInterface(bytes)
    let compiled = engine.compileValidatedModule(bytes)
    defer: compiled.close()
    expect ShellRuntimeTrap:
      discard compiled.probeManifestBytes(high(uint64))

  test "canonical manifest parser rejects reserved names":
    let engine = newRuntimeEngine()
    defer: engine.close()
    var outcome = engine.validateUploadedModule(fixture("reserved_name"))
    check outcome.reason == "manifestInvalid"

  test "canonical parser validates recursive ParamSpec defaults":
    let bytes = "{\"abi\":1,\"class\":\"overlay\",\"modes\":[\"br\",\"ctf\"]," &
      "\"name\":\"pact2\",\"params\":{\"choice\":{\"default\":\"cover\"," &
      "\"kind\":\"enum\",\"of\":[\"cover\",\"hold\"]}},\"retune\":false}"
    let parsed = parseManifest(bytes, false)
    check parsed.params.len == 1
    check parsed.params[0].spec.kind == "enum"
    expect ManifestError:
      discard parseManifest(bytes.replace("\"cover\",\"hold\"",
        "\"hold\",\"cover\""), false)

  test "binary hash is stable across identical accepted content":
    let bytes = fixture("valid")
    let engine = newRuntimeEngine()
    defer: engine.close()
    var first = engine.validateUploadedModule(bytes)
    defer: first.close()
    var second = engine.validateUploadedModule(bytes)
    defer: second.close()
    check first.accepted and second.accepted
    check first.sha256 == second.sha256
