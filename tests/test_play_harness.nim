## Native play_harness CLI parity with the production shell runtime path.

import std/[json, os, osproc, sequtils, strutils, unittest]

import ../src/shell/[module_validation, play_harness_core, runtime, wasmtime_c]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell" / "play_harness"
  HelloSource = "play_sdk" / "examples" / "hello_play.nim"
  HelloCase = FixtureDir / "hello_success.case.json"
  HelloWasm = "play_sdk" / ".build" / "hello_play.wasm"
  HarnessExe = "tools" / "play_harness" / "play_harness"

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

proc ensureHarnessBuilt() =
  let wasmtime = toolPath("WASMTIME_C_API")
  let command = "WASMTIME_C_API=" & quoteShell(wasmtime) &
    " nim c --threads:on -d:noSignalHandler -d:release " &
    quoteShell(HarnessExe & ".nim")
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(HarnessExe)

proc ensureHelloBuilt() =
  let wasi = toolPath("WASI_SDK_PATH")
  let command = "WASI_SDK_PATH=" & quoteShell(wasi) & " nim c " &
    quoteShell(HelloSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(HelloWasm)

proc watEscape(bytes: string): string =
  const Hex = "0123456789abcdef"
  for ch in bytes:
    let value = ord(ch)
    result.add '\\'
    result.add Hex[(value shr 4) and 0xf]
    result.add Hex[value and 0xf]

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "play-harness WAT fixture must be syntactically valid"
  defer: wasmByteVecDelete(addr output)
  result = newSeq[byte](output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc writeBytes(path: string; bytes: openArray[byte]) =
  var text = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr text[0], unsafeAddr bytes[0], bytes.len)
  writeFile(path, text)

proc moduleWat(name, stepBody: string; retuneBody = "i32.const 0";
               memory = "1 16"): string =
  let manifest = "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"" & name & "\",\"params\":{},\"retune\":true}"
  let blockedIntent =
    "{\"arrive_radius\":24.0,\"kind\":\"navigate_to\",\"point\":[0,0]," &
    "\"schema\":\"intent\",\"v\":1}"
  "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
    "  (memory (export \"memory\") " & memory & ")\n" &
    "  (global $next (mut i32) (i32.const 4096))\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (data (i32.const 512) \"" & blockedIntent.watEscape & "\")\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32)\n" &
    "    global.get $next\n" &
    "    global.get $next local.get $len i32.add global.set $next)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      "i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      stepBody & ")\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) " &
      "(result i32) " & retuneBody & "))"

proc writeCase(dir, name, frames: string): string =
  result = dir / (name & ".case.json")
  writeFile(result, "{\"module\":\"" & dir / (name & ".wasm") &
    "\",\"self\":[30,30],\"frames\":" & frames & "}")

proc makeCase(dir, name, stepBody: string; frames: string;
              retuneBody = "i32.const 0"; memory = "1 16"): string =
  createDir(dir)
  writeBytes(dir / (name & ".wasm"),
    watBytes(moduleWat(name, stepBody, retuneBody, memory)))
  writeCase(dir, name, frames)

proc runCli(casePath: string): string =
  let run = execCmdEx(quoteShell(HarnessExe) & " " & quoteShell(casePath))
  require run.exitCode == 0
  run.output.strip

proc readModuleBytes(path: string): seq[byte] =
  readFile(path).toOpenArrayByte(0, getFileSize(path).int - 1).toSeq

proc assertValidationParity(casePath, output: string) =
  let caseData = parseHarnessCase(readFile(casePath), casePath.parentDir)
  let trace = parseJson(output)
  let engine = newRuntimeEngine()
  defer: engine.close()
  var validation = engine.validateUploadedModule(readModuleBytes(caseData.modulePath))
  defer: validation.close()
  check trace["accepted"].getBool == validation.accepted
  check trace["reason"].getStr == validation.reason
  check trace["detail"].getStr == validation.detail
  check trace["sha256"].getStr == validation.sha256

suite "play harness":
  test "hello SDK play is the first harness fixture and matches shared core":
    ensureHarnessBuilt()
    ensureHelloBuilt()
    let cli = runCli(HelloCase)
    check cli == runHarnessFile(HelloCase)
    assertValidationParity(HelloCase, cli)
    let trace = parseJson(cli)
    check trace["accepted"].getBool
    check trace["manifest_name"].getStr == "hello"
    check trace["frames"].len == 4
    check trace["frames"][2]["last_accepted"].getStr ==
      "{\"arrive_radius\":24.0,\"kind\":\"navigate_to\",\"point\":[30,30]," &
      "\"reason\":\"hello\",\"schema\":\"intent\",\"v\":1}"

  test "CLI golden fixtures cover success, normalization, rejection, fault, and retune":
    ensureHarnessBuilt()
    ensureHelloBuilt()
    check runCli(HelloCase) == readFile(FixtureDir / "hello_success.golden.json").strip
    assertValidationParity(HelloCase, runCli(HelloCase))

    let dir = getTempDir() / ("coworld-play-harness-fixtures-" &
      $getCurrentProcessId())
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    let blockedIntent =
      "{\"arrive_radius\":24.0,\"kind\":\"navigate_to\",\"point\":[0,0]," &
      "\"schema\":\"intent\",\"v\":1}"
    let normalization = makeCase(dir, "normalize",
      "i32.const 512 i32.const " & $blockedIntent.len &
        " call $emit drop i32.const 0",
      frames = "[{\"op\":\"manifest\"},{\"op\":\"init\",\"params\":{}," &
        "\"context\":{}},{\"op\":\"step\",\"view\":{},\"tick\":1}]")
    let rejection = makeCase(dir, "reject", "i32.const 0",
      frames = "[{\"op\":\"manifest\"}]", memory = "1")
    let fault = makeCase(dir, "faulty", "unreachable i32.const 0",
      frames = "[{\"op\":\"manifest\"},{\"op\":\"init\",\"params\":{}," &
        "\"context\":{}},{\"op\":\"step\",\"view\":{},\"tick\":1}]")
    let retune = makeCase(dir, "retuner", "i32.const 0",
      retuneBody = "i32.const 1",
      frames = "[{\"op\":\"manifest\"},{\"op\":\"init\",\"params\":{}," &
        "\"context\":{}},{\"op\":\"retune\",\"old_params\":{}," &
        "\"new_params\":{\"level\":1}}]")

    for pair in [
      (normalization, "normalization.golden.json"),
      (rejection, "rejection.golden.json"),
      (fault, "fault.golden.json"),
      (retune, "retune.golden.json")]:
      let cli = runCli(pair[0])
      check cli == runHarnessFile(pair[0])
      check cli == readFile(FixtureDir / pair[1]).strip
      assertValidationParity(pair[0], cli)
