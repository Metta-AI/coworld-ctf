import std/[options, os, strutils, unittest]

import ../src/shell/[compile_plane, manifest, module_cache, runtime, types,
  wasmtime_c]

const FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"

proc hex(ch: char): string = repeat($ch, 64)

proc hexFor(index: int): string =
  let digits = "0123456789abcdef"
  let text = $digits[(index shr 4) and 0xf] & $digits[index and 0xf]
  repeat(text, 32)

proc manifestNamed(name: string): PlayManifest =
  PlayManifest(abi: ShellAbiVersion, name: name, playClass: mcController,
    modes: @["br"], retune: false)

proc okContent(name: string; compiledBytes = 64): ContentOutcome =
  ContentOutcome(accepted: true, manifest: manifestNamed(name),
    compiledBytes: compiledBytes)

proc badContent(reason: string): ContentOutcome =
  ContentOutcome(accepted: false, reason: reason, detail: reason)

proc admitOne(plane: CompilePlane; seat: int; uploadId: uint64;
    size = 16; gen = 1'u64): AdmissionResult =
  var bytes = newSeq[byte](size)
  for i in 0 ..< bytes.len:
    bytes[i] = byte((seat + int(uploadId) + i) and 0xff)
  result = plane.admitModule(seat, uploadId, gen, bytes)
  check result.accepted
  plane.beginTick()

proc finishFake(plane: CompilePlane; work: CompileWork; hash, name: string;
    compiledBytes = 64) =
  let content = plane.completeHash(work, hash)
  check content.isSome
  plane.completeContent(content.get(), okContent(name, compiledBytes))

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "compile-plane WAT fixture must be syntactically valid"
  defer: wasmByteVecDelete(addr output)
  result = newSeq[byte](output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc uleb(outBytes: var seq[byte]; value: int) =
  var remaining = value
  while true:
    var current = byte(remaining and 0x7f)
    remaining = remaining shr 7
    if remaining != 0:
      current = current or 0x80
    outBytes.add current
    if remaining == 0:
      break

proc paddedCustomSection(bytes: seq[byte]; targetLen: int): seq[byte] =
  ## Custom sections are ignored by the shell interface inspector and Wasmtime
  ## validator, but they keep reservation accounting realistic for tiny tests.
  result = bytes
  if result.len >= targetLen:
    return
  let payloadLen = targetLen - result.len - 2
  doAssert payloadLen > 4
  var body: seq[byte]
  body.uleb(3)
  body.add @[byte ord('p'), ord('a'), ord('d')]
  body.add newSeq[byte](payloadLen - body.len)
  result.add 0'u8
  result.uleb(body.len)
  result.add body

suite "shell compile plane":
  test "CanonicalWriter status bytes match contract goldens":
    let accepted = StatusEntry(kind: skModuleAccepted, ordinal: 1,
      originGeneration: 1, acceptedUploadId: 9_007_199_254_740_991'u64)
    check encodeStatusEntry(accepted) ==
      readFile(FixtureDir / "status_module_accepted.golden.json")
    let ready = StatusEntry(kind: skModuleReady, ordinal: 2,
      originGeneration: 1, readyUploadId: 9_007_199_254_740_992'u64,
      name: "pact",
      sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
    check encodeStatusEntry(ready) ==
      readFile(FixtureDir / "status_module_ready.golden.json")
    let rejected = StatusEntry(kind: skModuleRejected, ordinal: 3,
      originGeneration: 1, rejectedUploadId: 3, moduleReason: "nameBound")
    check encodeStatusEntry(rejected) ==
      readFile(FixtureDir / "status_module_rejected.golden.json")

  test "stage-1 admission charges pending and compiled reservations":
    let plane = newCompilePlane(nil, 2)
    defer: plane.close()
    let admission = plane.admitModule(0, 1, 7, @[byte 1, 2, 3, 4])
    check admission.accepted
    check admission.statusBytes ==
      "{\"gen\":\"7\",\"kind\":\"module_accepted\",\"ordinal\":\"1\",\"upload_id\":\"1\"}"
    let snap = plane.snapshot()
    check snap.pendingBytes == 4
    check snap.compiledReservedBytes == 4 * CompiledBytesPerRawByte
    check snap.perSeatChargedModules[0] == 1
    check snap.perSeatChargedBytes[0] == 4
    check plane.admitModule(0, 2, 7, @[byte 9]).refusal == arTickUploadLimit

  test "pending-byte backpressure accepts exactly 8 MiB and refuses one over":
    let plane = newCompilePlane(nil, 33)
    defer: plane.close()
    for seat in 0 ..< 32:
      check plane.admitOne(seat, 1, MaxModuleBytes).accepted
    check plane.snapshot().pendingBytes == MaxPendingCompileBytes
    let refused = plane.admitModule(32, 1, 1, @[byte 1])
    check not refused.accepted
    check refused.refusal == arPendingBytes

  test "fake scheduler is round-robin across seats":
    let plane = newCompilePlane(nil, 3)
    defer: plane.close()
    for seat in 0 ..< 3:
      discard plane.admitOne(seat, 1)
    let first = plane.dispatchAvailable()
    check first.len == 2
    check first[0].seat == 0
    check first[1].seat == 1
    discard plane.completeHash(first[0], hex('a'))
    let second = plane.dispatchAvailable()
    check second.len == 1
    check second[0].seat == 2

  test "same-seat reverse completion still commits uploadId order":
    let plane = newCompilePlane(nil, 1)
    defer: plane.close()
    discard plane.admitOne(0, 1)
    discard plane.admitOne(0, 2)
    let work = plane.dispatchAvailable()
    check work.len == 2
    plane.finishFake(work[1], hex('b'), "pact")
    check plane.commitCompileResults().len == 0
    plane.finishFake(work[0], hex('a'), "pact")
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].uploadId == 1
    check commits[0].terminal == tkReady
    check commits[1].uploadId == 2
    check commits[1].terminal == tkRejected
    check commits[1].status.moduleReason == "nameBound"

  test "same-seat duplicate waits on the leader and refunds only at commit":
    let plane = newCompilePlane(nil, 1)
    defer: plane.close()
    discard plane.admitOne(0, 1, 100)
    discard plane.admitOne(0, 2, 100)
    let chargedBefore = plane.snapshot().perSeatChargedBytes[0]
    let work = plane.dispatchAvailable()
    let leader = plane.completeHash(work[0], hex('c'))
    check leader.isSome
    check plane.completeHash(work[1], hex('c')).isNone
    check plane.snapshot().perSeatChargedBytes[0] == chargedBefore
    plane.completeContent(leader.get(), okContent("pact", 128))
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].terminal == tkReady
    check not commits[0].duplicateRefunded
    check commits[1].terminal == tkReady
    check commits[1].duplicateRefunded
    check commits[1].rawBudgetRefunded == 100
    check plane.snapshot().perSeatChargedModules[0] == 1

  test "cross-seat duplicate refunds without globalizing names":
    let plane = newCompilePlane(nil, 2)
    defer: plane.close()
    discard plane.admitOne(0, 1, 80)
    discard plane.admitOne(1, 1, 80)
    let work = plane.dispatchAvailable()
    let leader = plane.completeHash(work[0], hex('d'))
    check plane.completeHash(work[1], hex('d')).isNone
    plane.completeContent(leader.get(), okContent("pact", 128))
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].terminal == tkReady
    check commits[1].terminal == tkReady
    check commits[1].duplicateRefunded
    check plane.boundHash(0, "pact") == hex('d')
    check plane.boundHash(1, "pact") == hex('d')

  test "thirty-two seats may bind the same local name to different hashes":
    let plane = newCompilePlane(nil, 32)
    defer: plane.close()
    for seat in 0 ..< 32:
      discard plane.admitOne(seat, 1)
    var dispatched = plane.dispatchAvailable()
    while dispatched.len > 0:
      for work in dispatched:
        plane.finishFake(work, hexFor(work.seat), "pact")
      dispatched = plane.dispatchAvailable()
    var total = 0
    while true:
      let commits = plane.commitCompileResults()
      if commits.len == 0: break
      total += commits.len
      for commit in commits:
        check commit.terminal == tkReady
    check total == 32

  test "content failure is cached globally and duplicate refunds at commit":
    let plane = newCompilePlane(nil, 2)
    defer: plane.close()
    discard plane.admitOne(0, 1, 50)
    discard plane.admitOne(1, 1, 50)
    let work = plane.dispatchAvailable()
    let leader = plane.completeHash(work[0], hex('e'))
    check plane.completeHash(work[1], hex('e')).isNone
    plane.completeContent(leader.get(), badContent("badInterface"))
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].status.moduleReason == "badInterface"
    check commits[1].status.moduleReason == "badInterface"
    check commits[1].duplicateRefunded
    check plane.snapshot().cache.contentInvalid == 1

  test "terminal compiled hash is reused without another content job":
    let plane = newCompilePlane(nil, 1)
    defer: plane.close()
    discard plane.admitOne(0, 1, 40)
    var work = plane.dispatchAvailable()
    plane.finishFake(work[0], hex('f'), "pact", 120)
    let first = plane.commitCompileResults()
    check first.len == 1
    check first[0].terminal == tkReady
    discard plane.admitOne(0, 2, 40)
    work = plane.dispatchAvailable()
    check plane.completeHash(work[0], hex('f')).isNone
    check plane.stageOf(work[0].uploadIndex) == usFinished
    let second = plane.commitCompileResults()
    check second.len == 1
    check second[0].terminal == tkReady
    check second[0].duplicateRefunded
    check plane.snapshot().cache.compiled == 1

  test "seat-local nameBound never poisons the global hash table":
    let plane = newCompilePlane(nil, 2)
    defer: plane.close()
    discard plane.admitOne(0, 1, 40)
    discard plane.admitOne(0, 2, 40)
    var work = plane.dispatchAvailable()
    plane.finishFake(work[0], hex('a'), "pact", 100)
    plane.finishFake(work[1], hex('b'), "pact", 100)
    let seat0 = plane.commitCompileResults()
    check seat0.len == 2
    check seat0[0].terminal == tkReady
    check seat0[1].terminal == tkRejected
    check seat0[1].status.moduleReason == "nameBound"

    discard plane.admitOne(1, 1, 40)
    work = plane.dispatchAvailable()
    check plane.completeHash(work[0], hex('b')).isNone
    let seat1 = plane.commitCompileResults()
    check seat1.len == 1
    check seat1[0].terminal == tkReady
    check plane.boundHash(1, "pact") == hex('b')

  test "cacheFull is first terminal when compiled artifact exceeds reservation":
    let plane = newCompilePlane(nil, 3)
    defer: plane.close()
    for seat in 0 ..< 3:
      discard plane.admitOne(seat, 1, 10)
    let work = plane.dispatchAvailable()
    plane.finishFake(work[0], hex('1'), "minus", 79)
    plane.finishFake(work[1], hex('2'), "at", 80)
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].terminal == tkReady
    check commits[1].terminal == tkReady
    let more = plane.dispatchAvailable()
    plane.finishFake(more[0], hex('3'), "over", 81)
    let over = plane.commitCompileResults()
    check over.len == 1
    check over[0].terminal == tkRejected
    check over[0].status.moduleReason == "cacheFull"

  test "every content terminal reason reaches moduleRejected":
    let reasons = ["binaryInvalid", "badInterface", "tooManyFunctions",
      "compileFailed", "manifestProbe", "manifestInvalid", "cacheFull"]
    let plane = newCompilePlane(nil, reasons.len)
    defer: plane.close()
    for seat in 0 ..< reasons.len:
      discard plane.admitOne(seat, 1)
    var dispatched = plane.dispatchAvailable()
    var seen = 0
    while dispatched.len > 0:
      for work in dispatched:
        let content = plane.completeHash(work, hex(char(ord('a') + work.seat)))
        plane.completeContent(content.get(), badContent(reasons[work.seat]))
        inc seen
      dispatched = plane.dispatchAvailable()
    check seen == reasons.len
    var got: seq[string]
    while true:
      let commits = plane.commitCompileResults()
      if commits.len == 0: break
      for commit in commits:
        got.add commit.status.moduleReason
    check got == @reasons

  test "stage-7 commits at most eight and resumes round-robin next tick":
    let plane = newCompilePlane(nil, 10)
    defer: plane.close()
    for seat in 0 ..< 10:
      discard plane.admitOne(seat, 1)
    var dispatched = plane.dispatchAvailable()
    while dispatched.len > 0:
      for work in dispatched:
        plane.finishFake(work, hexFor(work.seat), "pact", 100)
      dispatched = plane.dispatchAvailable()
    let first = plane.commitCompileResults()
    check first.len == MaxCompileCommitsPerTick
    for i, commit in first:
      check commit.seat == i
    let second = plane.commitCompileResults()
    check second.len == 2
    check second[0].seat == 8
    check second[1].seat == 9

  test "real two-worker integration validates once and wakes duplicate waiter":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let plane = newCompilePlane(engine, 2)
    defer: plane.close()
    let alpha = paddedCustomSection(
      watBytes(readFile(FixtureDir / "wasm" / "valid.wat")), 65_536)
    let beta = alpha
    check plane.admitModule(0, 1, 1, alpha).accepted
    plane.beginTick()
    check plane.admitModule(1, 1, 1, beta).accepted
    check plane.drainCompileWorkers(10000)
    let commits = plane.commitCompileResults()
    check commits.len == 2
    check commits[0].terminal == tkReady
    check commits[1].terminal == tkReady
    var duplicateCommits = 0
    for commit in commits:
      if commit.duplicateRefunded:
        inc duplicateCommits
    check duplicateCommits == 1
    check engine.moduleCompilationCount() == 1
    check plane.snapshot().cache.compiled == 1

  test "worker shutdown is idempotent":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let plane = newCompilePlane(engine, 1)
    plane.startCompileWorkers()
    plane.close()
    plane.close()
