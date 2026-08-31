## The Nim play SDK builds a no-WASI core module accepted by the production
## shell validation and invocation pipeline.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, body_map, finisher, instance, manifest,
  module_validation, runtime, types]

const
  HelloSource = "play_sdk" / "examples" / "hello_play.nim"
  HelloWasm = "play_sdk" / ".build" / "hello_play.wasm"
  HelloManifest =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"hello play\",\"modes\":[\"br\",\"ctf\",\"koth\"],\"name\":\"hello\",\"params\":{},\"retune\":true}"

proc parseToolPath(output, key: string): string =
  for line in output.splitLines:
    if line.startsWith(key & "="):
      return line[(key.len + 1) .. ^1]

proc wasiSdkPath(): string =
  result = getEnv("WASI_SDK_PATH")
  if result.len > 0:
    return
  let fetched = execCmdEx("tools/runtime_spike/fetch_deps.sh")
  require fetched.exitCode == 0
  result = parseToolPath(fetched.output, "WASI_SDK_PATH")
  require result.len > 0

proc buildHelloWasm(): seq[byte] =
  let wasi = wasiSdkPath()
  let command = "WASI_SDK_PATH=" & quoteShell(wasi) & " nim c " &
    quoteShell(HelloSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(HelloWasm)
  readFile(HelloWasm).toOpenArrayByte(0, getFileSize(HelloWasm).int - 1).toSeq

proc openRoomsMap(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

suite "play SDK":
  test "hello play builds as core wasm and passes the production pipeline":
    let bytes = buildHelloWasm()
    check bytes.len <= MaxModuleBytes

    let engine = newRuntimeEngine()
    defer: engine.close()
    var outcome = engine.validateUploadedModule(bytes)
    defer: outcome.close()

    check outcome.accepted
    check outcome.manifest.name == "hello"
    check outcome.manifest.playClass == mcController
    check outcome.manifest.retune
    check outcome.manifest.modes == @["br", "ctf", "koth"]
    check outcome.moduleInterface.hasRetune
    check outcome.moduleInterface.memoryMaximumPages == MaxInstancePages

    var instance = newShellInstance(outcome.module, openRoomsMap(), (30, 30))
    defer: instance.close()

    let manifest = instance.invokeManifest()
    check not manifest.faulted
    check manifest.manifestBytes == HelloManifest

    let init = instance.invokeInit("{}", "{}")
    check not init.faulted
    check init.returned == 0

    let step = instance.invokeStep("{}", 1)
    check not step.faulted
    check step.returned == 0
    check step.emitCodes == @[AbiOk]
    check step.lastAccepted.isSome
    let expected = canonicalIntent(Intent(kind: ikNavigateTo,
      point: some(MapPoint(x: 30, y: 30)), arriveRadius: 24.0,
      reason: "hello"))
    check step.lastAccepted.get.bytes == expected

    let retune = instance.invokeRetune("{}", "{\"level\":1}")
    check not retune.faulted
    check not retune.refused
    check retune.returned == 0
