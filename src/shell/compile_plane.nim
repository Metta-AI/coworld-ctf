## Season 2 module compile plane.
##
## This layer starts after packet decoding: callers hand it already-admitted
## raw module bytes and a seat/upload identity. The tick thread performs only
## stage-1 checks and stage-7 commits; hashing, validation, compilation, and
## manifest probing are worker work.

import core/locks
import std/[deques, monotimes, options, os, times, tables]
import crunchy/[common, sha256]

import manifest, module_cache, module_validation, runtime, types

when not compileOption("threads"):
  {.error: "shell compile plane requires --threads:on".}

type
  AdmissionRefusal* = enum
    arNone
    arBadSeat
    arTooLarge
    arTickUploadLimit
    arUploadId
    arStatusBackpressure
    arTooManyModules
    arSeatByteBudget
    arPendingBytes
    arCompiledCache
    arSeatQueueFull

  UploadStage* = enum
    usQueued
    usHashing
    usWaitingForLeader
    usNeedsContent
    usContentRunning
    usFinished
    usCommitted

  TerminalKind* = enum
    tkNone
    tkReady
    tkRejected

  CompileWork* = object
    uploadIndex*: int
    seat*: int
    uploadId*: uint64
    rawBytes*: int
    hash*: string

  AdmissionResult* = object
    accepted*: bool
    refusal*: AdmissionRefusal
    uploadIndex*: int
    status*: StatusEntry
    statusBytes*: string

  CompileCommit* = object
    seat*: int
    uploadId*: uint64
    hash*: string
    terminal*: TerminalKind
    duplicateRefunded*: bool
    rawBudgetRefunded*: int
    pendingReleased*: int
    reservationReleased*: int
    compiledResidentDelta*: int
    status*: StatusEntry
    statusBytes*: string

  CompilePlaneSnapshot* = object
    pendingBytes*: int
    compiledReservedBytes*: int
    compiledResidentBytes*: int
    perSeatChargedModules*: seq[int]
    perSeatChargedBytes*: seq[int]
    cache*: CacheSnapshot

  BoundModule* = object
    ## Production binding surface after stage-7 commit: the seat-local name
    ## table chooses a content hash, then the content cache supplies the
    ## compiled module for instance creation.
    name*: string
    hash*: string
    manifest*: PlayManifest
    module*: RuntimeModule

  WorkerTaskKind = enum
    wtkStop
    wtkHash
    wtkContent

  WorkerResultKind = enum
    wrkHash
    wrkContent

  WorkerTask = object
    kind: WorkerTaskKind
    uploadIndex: int
    bytes: seq[byte]
    hash: string

  WorkerResult = object
    kind: WorkerResultKind
    uploadIndex: int
    hash: string
    outcome: ContentOutcome

  WorkerState = ref object
    runtime: RuntimeEngine
    shared: WorkerShared

  WorkerShared = ref object
    lock: Lock
    cond: Cond
    tasks: Deque[WorkerTask]
    results: Deque[WorkerResult]

  SeatState = object
    queue: Deque[int]
    uploadOrder: seq[int]
    nextCommit: int
    names: Table[string, string]
    lastUploadId: uint64
    hasUpload: bool
    uploadsThisTick: int
    chargedModules: int
    chargedBytes: int
    reservedRegularStatuses: int
    nextStatusOrdinal: uint64

  UploadState = object
    seat: int
    uploadId: uint64
    originGeneration: uint64
    bytes: seq[byte]
    rawBytes: int
    reservationBytes: int
    stage: UploadStage
    hash: string
    duplicate: bool
    outcome: ContentOutcome
    finished: bool
    committed: bool

  CompilePlane* = ref object
    runtime: RuntimeEngine
    cache: ModuleCache
    seats: seq[SeatState]
    uploads: seq[UploadState]
    waitersByHash: Table[string, seq[int]]
    pendingBytes: int
    compiledReservedBytes: int
    nextDispatchSeat: int
    nextCommitSeat: int
    workersStarted: bool
    workerCount: int
    activeWorkerTasks: int
    shared: WorkerShared
    workerThreads: seq[Thread[WorkerState]]
    workerState: WorkerState

const RegularStatusCapacity = MaxRetainedStatusEntries - StatusFaultReserve

proc refusalReason*(refusal: AdmissionRefusal): string =
  case refusal
  of arNone: ""
  of arBadSeat: "badSeat"
  of arTooLarge: "tooLarge"
  of arTickUploadLimit: "tickUploadLimit"
  of arUploadId: "uploadId"
  of arStatusBackpressure: "statusBackpressure"
  of arTooManyModules: "tooManyModules"
  of arSeatByteBudget: "seatByteBudget"
  of arPendingBytes: "pendingBytes"
  of arCompiledCache: "cacheFull"
  of arSeatQueueFull: "seatQueueFull"

proc newStatusOrdinal(seat: var SeatState): uint64 =
  inc seat.nextStatusOrdinal
  seat.nextStatusOrdinal

proc acceptedStatus(seat: var SeatState; uploadId, generation: uint64):
    StatusEntry =
  StatusEntry(kind: skModuleAccepted, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, acceptedUploadId: uploadId)

proc readyStatus(seat: var SeatState; uploadId, generation: uint64;
    name, hash: string): StatusEntry =
  StatusEntry(kind: skModuleReady, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, readyUploadId: uploadId, name: name,
    sha256: hash)

proc rejectedStatus(seat: var SeatState; uploadId, generation: uint64;
    reason: string): StatusEntry =
  result = StatusEntry(kind: skModuleRejected, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, rejectedUploadId: uploadId,
    moduleReason: reason)
  result.fitModuleRejectedReason()

proc newCompilePlane*(runtime: RuntimeEngine; seatCount: int;
    workerCount = 2): CompilePlane =
  doAssert seatCount > 0
  doAssert workerCount == 2, "Season 2 compile plane has exactly two workers"
  new(result)
  result.runtime = runtime
  result.cache = newModuleCache()
  result.seats = newSeq[SeatState](seatCount)
  for seat in 0 ..< seatCount:
    result.seats[seat].queue = initDeque[int]()
    result.seats[seat].names = initTable[string, string]()
  result.waitersByHash = initTable[string, seq[int]]()
  result.workerCount = workerCount

proc close*(plane: CompilePlane)

proc close*(plane: CompilePlane) =
  if plane == nil:
    return
  if plane.workersStarted:
    acquire(plane.shared.lock)
    for _ in 0 ..< plane.workerCount:
      plane.shared.tasks.addLast(WorkerTask(kind: wtkStop))
    broadcast(plane.shared.cond)
    release(plane.shared.lock)
    for thread in plane.workerThreads.mitems:
      joinThread(thread)
    while plane.shared.results.len > 0:
      var output = plane.shared.results.popFirst()
      if output.kind == wrkContent and output.outcome.module != nil:
        output.outcome.module.close()
    plane.workerThreads.setLen(0)
    deinitCond(plane.shared.cond)
    deinitLock(plane.shared.lock)
    plane.shared = nil
    plane.workersStarted = false
    plane.activeWorkerTasks = 0
  if plane.cache != nil:
    plane.cache.close()

proc beginTick*(plane: CompilePlane) =
  for seat in plane.seats.mitems:
    seat.uploadsThisTick = 0

proc cacheUsed(plane: CompilePlane): int =
  plane.cache.residentBytes + plane.compiledReservedBytes

proc snapshot*(plane: CompilePlane): CompilePlaneSnapshot =
  if plane == nil:
    return
  result.pendingBytes = plane.pendingBytes
  result.compiledReservedBytes = plane.compiledReservedBytes
  result.compiledResidentBytes = plane.cache.residentBytes
  result.cache = plane.cache.snapshot()
  result.perSeatChargedModules = newSeq[int](plane.seats.len)
  result.perSeatChargedBytes = newSeq[int](plane.seats.len)
  for i, seat in plane.seats:
    result.perSeatChargedModules[i] = seat.chargedModules
    result.perSeatChargedBytes[i] = seat.chargedBytes

proc admitModule*(plane: CompilePlane; seatIndex: int; uploadId: uint64;
    originGeneration: uint64; bytes: openArray[byte]): AdmissionResult =
  ## Stage 1: content-blind admission and accounting.
  if seatIndex < 0 or seatIndex >= plane.seats.len:
    return AdmissionResult(refusal: arBadSeat)
  if bytes.len > MaxModuleBytes:
    return AdmissionResult(refusal: arTooLarge)
  var seat = addr plane.seats[seatIndex]
  if seat[].uploadsThisTick >= MaxUploadsPerSeatPerTick:
    return AdmissionResult(refusal: arTickUploadLimit)
  if seat[].hasUpload and uploadId <= seat[].lastUploadId:
    return AdmissionResult(refusal: arUploadId)
  if seat[].reservedRegularStatuses + 2 > RegularStatusCapacity:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arStatusBackpressure)
  if seat[].chargedModules + 1 > MaxModulesPerSeatPerEpisode:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arTooManyModules)
  if seat[].chargedBytes + bytes.len > MaxUploadBytesPerSeatPerEpisode:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arSeatByteBudget)
  if plane.pendingBytes + bytes.len > MaxPendingCompileBytes:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arPendingBytes)
  let reservation = compiledReservationBytes(bytes.len)
  if plane.cacheUsed + reservation > MaxCompiledCacheBytes:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arCompiledCache)
  if seat[].queue.len >= MaxModulesPerSeatPerEpisode:
    inc seat[].uploadsThisTick
    return AdmissionResult(refusal: arSeatQueueFull)

  let index = plane.uploads.len
  var copy = newSeq[byte](bytes.len)
  if bytes.len > 0:
    copyMem(addr copy[0], unsafeAddr bytes[0], bytes.len)
  plane.uploads.add UploadState(seat: seatIndex, uploadId: uploadId,
    originGeneration: originGeneration, bytes: move(copy), rawBytes: bytes.len,
    reservationBytes: reservation, stage: usQueued)
  seat[].queue.addLast(index)
  seat[].uploadOrder.add(index)
  seat[].hasUpload = true
  seat[].lastUploadId = uploadId
  inc seat[].uploadsThisTick
  inc seat[].chargedModules
  seat[].chargedBytes += bytes.len
  seat[].reservedRegularStatuses += 2
  plane.pendingBytes += bytes.len
  plane.compiledReservedBytes += reservation

  result.accepted = true
  result.uploadIndex = index
  result.status = seat[].acceptedStatus(uploadId, originGeneration)
  result.statusBytes = encodeStatusEntry(result.status)

proc nextQueuedSeat(plane: CompilePlane): int =
  if plane.seats.len == 0:
    return -1
  for offset in 0 ..< plane.seats.len:
    let seat = (plane.nextDispatchSeat + offset) mod plane.seats.len
    if plane.seats[seat].queue.len > 0:
      plane.nextDispatchSeat = (seat + 1) mod plane.seats.len
      return seat
  -1

proc dispatchAvailable*(plane: CompilePlane): seq[CompileWork] =
  ## Deterministic fake-worker scheduler. Each returned item represents one
  ## hash-stage worker slot; callers complete it with `completeHash`.
  while plane.activeWorkerTasks < plane.workerCount:
    let seatIndex = plane.nextQueuedSeat()
    if seatIndex < 0:
      break
    let uploadIndex = plane.seats[seatIndex].queue.popFirst()
    plane.uploads[uploadIndex].stage = usHashing
    inc plane.activeWorkerTasks
    result.add CompileWork(uploadIndex: uploadIndex, seat: seatIndex,
      uploadId: plane.uploads[uploadIndex].uploadId,
      rawBytes: plane.uploads[uploadIndex].rawBytes)

proc completeHash*(plane: CompilePlane; work: CompileWork; hash: string):
    Option[CompileWork] =
  ## Completes stage 2 for a fake worker. Leaders return a content work item;
  ## waiters and terminal duplicates wait for or copy the cached content result.
  doAssert work.uploadIndex >= 0 and work.uploadIndex < plane.uploads.len
  doAssert plane.uploads[work.uploadIndex].stage == usHashing
  dec plane.activeWorkerTasks
  var upload = addr plane.uploads[work.uploadIndex]
  upload[].hash = hash
  let claim = plane.cache.claimHash(hash)
  case claim.kind
  of hckLeader:
    upload[].stage = usNeedsContent
    result = some(CompileWork(uploadIndex: work.uploadIndex, seat: work.seat,
      uploadId: work.uploadId, rawBytes: work.rawBytes, hash: hash))
  of hckWaiter:
    upload[].duplicate = true
    upload[].stage = usWaitingForLeader
    plane.waitersByHash.mgetOrPut(hash, @[]).add(work.uploadIndex)
  of hckTerminal:
    upload[].duplicate = true
    upload[].outcome = claim.outcome
    upload[].finished = true
    upload[].stage = usFinished

proc contentOutcomeFromValidation(validation: sink ModuleValidationResult;
    compiledBytes: int): ContentOutcome =
  result.accepted = validation.accepted
  result.reason = validation.reason
  result.detail = validation.detail
  result.manifest = validation.manifest
  result.module = validation.module
  result.compiledBytes = compiledBytes
  validation.module = nil

proc completeContent*(plane: CompilePlane; work: CompileWork;
    outcome: ContentOutcome) =
  ## Completes stages 3-6 for a fake worker and wakes every hash waiter.
  doAssert work.uploadIndex >= 0 and work.uploadIndex < plane.uploads.len
  var terminal = outcome
  let reservation = plane.uploads[work.uploadIndex].reservationBytes
  if terminal.accepted and terminal.compiledBytes > reservation:
    if terminal.module != nil:
      terminal.module.close()
      terminal.module = nil
    terminal = ContentOutcome(accepted: false, reason: "cacheFull",
      detail: "compiled artifact exceeds reserved cache bytes")
  plane.cache.finishLeader(work.hash, terminal)
  var leader = addr plane.uploads[work.uploadIndex]
  leader[].outcome = terminal
  leader[].finished = true
  leader[].stage = usFinished
  if work.hash in plane.waitersByHash:
    for waiterIndex in plane.waitersByHash[work.hash]:
      var waiter = addr plane.uploads[waiterIndex]
      waiter[].outcome = terminal
      waiter[].finished = true
      waiter[].stage = usFinished
    plane.waitersByHash.del(work.hash)

proc workerLoop(state: WorkerState) {.thread, gcsafe.} =
  while true:
    acquire(state.shared.lock)
    while state.shared.tasks.len == 0:
      wait(state.shared.cond, state.shared.lock)
    let task = state.shared.tasks.popFirst()
    release(state.shared.lock)
    case task.kind
    of wtkStop:
      break
    of wtkHash:
      let hash = sha256(task.bytes).toHex()
      acquire(state.shared.lock)
      state.shared.results.addLast(WorkerResult(kind: wrkHash,
        uploadIndex: task.uploadIndex, hash: hash))
      release(state.shared.lock)
    of wtkContent:
      var validation: ModuleValidationResult
      {.cast(gcsafe).}:
        validation = state.runtime.validateUploadedModule(task.bytes)
      var compiledBytes = 0
      if validation.accepted:
        try:
          compiledBytes = validation.module.serializedModuleBytes()
        except ShellRuntimeError as error:
          validation.close()
          validation.accepted = false
          validation.reason = "compileFailed"
          validation.detail = error.msg
      let output = WorkerResult(kind: wrkContent,
        uploadIndex: task.uploadIndex, hash: task.hash,
        outcome: contentOutcomeFromValidation(move(validation), compiledBytes))
      acquire(state.shared.lock)
      state.shared.results.addLast(output)
      release(state.shared.lock)

proc startCompileWorkers*(plane: CompilePlane) =
  if plane.workersStarted:
    return
  plane.shared = WorkerShared(tasks: initDeque[WorkerTask](),
    results: initDeque[WorkerResult]())
  initLock(plane.shared.lock)
  initCond(plane.shared.cond)
  plane.workerState = WorkerState(runtime: plane.runtime, shared: plane.shared)
  plane.workerThreads = newSeq[Thread[WorkerState]](plane.workerCount)
  for worker in plane.workerThreads.mitems:
    createThread(worker, workerLoop, plane.workerState)
  plane.workersStarted = true

proc enqueueHashTasks(plane: CompilePlane) =
  if not plane.workersStarted:
    return
  while plane.activeWorkerTasks < plane.workerCount:
    let seatIndex = plane.nextQueuedSeat()
    if seatIndex < 0:
      break
    let uploadIndex = plane.seats[seatIndex].queue.popFirst()
    plane.uploads[uploadIndex].stage = usHashing
    inc plane.activeWorkerTasks
    acquire(plane.shared.lock)
    plane.shared.tasks.addLast(WorkerTask(kind: wtkHash, uploadIndex: uploadIndex,
      bytes: plane.uploads[uploadIndex].bytes))
    signal(plane.shared.cond)
    release(plane.shared.lock)

proc processWorkerResult(plane: CompilePlane; output: WorkerResult) =
  case output.kind
  of wrkHash:
    dec plane.activeWorkerTasks
    let index = output.uploadIndex
    plane.uploads[index].hash = output.hash
    let claim = plane.cache.claimHash(output.hash)
    case claim.kind
    of hckLeader:
      plane.uploads[index].stage = usContentRunning
      inc plane.activeWorkerTasks
      acquire(plane.shared.lock)
      plane.shared.tasks.addLast(WorkerTask(kind: wtkContent, uploadIndex: index,
        bytes: plane.uploads[index].bytes, hash: output.hash))
      signal(plane.shared.cond)
      release(plane.shared.lock)
    of hckWaiter:
      plane.uploads[index].duplicate = true
      plane.uploads[index].stage = usWaitingForLeader
      plane.waitersByHash.mgetOrPut(output.hash, @[]).add(index)
    of hckTerminal:
      plane.uploads[index].duplicate = true
      plane.uploads[index].outcome = claim.outcome
      plane.uploads[index].finished = true
      plane.uploads[index].stage = usFinished
  of wrkContent:
    dec plane.activeWorkerTasks
    let index = output.uploadIndex
    let work = CompileWork(uploadIndex: index, seat: plane.uploads[index].seat,
      uploadId: plane.uploads[index].uploadId,
      rawBytes: plane.uploads[index].rawBytes, hash: output.hash)
    plane.completeContent(work, output.outcome)

proc pollCompileWorkers*(plane: CompilePlane) =
  if not plane.workersStarted:
    return
  while true:
    acquire(plane.shared.lock)
    if plane.shared.results.len == 0:
      release(plane.shared.lock)
      break
    let output = plane.shared.results.popFirst()
    release(plane.shared.lock)
    plane.processWorkerResult(output)
  plane.enqueueHashTasks()

proc drainCompileWorkers*(plane: CompilePlane; timeoutMs = 5000): bool =
  ## Test helper for the real-worker integration path.
  plane.startCompileWorkers()
  plane.enqueueHashTasks()
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    plane.pollCompileWorkers()
    if plane.activeWorkerTasks == 0:
      var queued = false
      for seat in plane.seats:
        if seat.queue.len > 0:
          queued = true
          break
      if not queued and plane.waitersByHash.len == 0:
        return true
    sleep(1)
  false

proc terminalForUpload(plane: CompilePlane; uploadIndex: int):
    tuple[kind: TerminalKind, reason: string, name: string, hash: string] =
  var upload = addr plane.uploads[uploadIndex]
  if not upload[].outcome.accepted:
    return (tkRejected, upload[].outcome.reason, "", upload[].hash)
  let name = upload[].outcome.manifest.name
  var seat = addr plane.seats[upload[].seat]
  if name in seat[].names and seat[].names[name] != upload[].hash:
    return (tkRejected, "nameBound", name, upload[].hash)
  seat[].names[name] = upload[].hash
  (tkReady, "", name, upload[].hash)

proc sameAccountingContent(a, b: UploadState): bool =
  if a.hash.len > 0 and b.hash.len > 0:
    return a.hash == b.hash
  a.bytes == b.bytes

proc earlierAccountingHolder(a, b: UploadState): bool =
  a.seat < b.seat or (a.seat == b.seat and a.uploadId < b.uploadId)

proc duplicateChargeRefunded(plane: CompilePlane; uploadIndex: int): bool =
  ## Compile leadership is allowed to follow worker arrival order; quota
  ## ownership is not. The earliest admitted holder of identical content by
  ## `(seat, uploadId)` keeps the charge, and every later holder refunds at
  ## commit.
  let upload = plane.uploads[uploadIndex]
  for otherIndex, other in plane.uploads:
    if otherIndex != uploadIndex and other.sameAccountingContent(upload) and
        other.earlierAccountingHolder(upload):
      return true

proc commitUpload(plane: CompilePlane; uploadIndex: int): CompileCommit =
  var upload = addr plane.uploads[uploadIndex]
  var seat = addr plane.seats[upload[].seat]
  let terminal = plane.terminalForUpload(uploadIndex)
  let refundDuplicateCharge = plane.duplicateChargeRefunded(uploadIndex)

  result.seat = upload[].seat
  result.uploadId = upload[].uploadId
  result.hash = upload[].hash
  result.terminal = terminal.kind
  result.pendingReleased = upload[].rawBytes
  result.reservationReleased = upload[].reservationBytes
  plane.pendingBytes -= upload[].rawBytes
  plane.compiledReservedBytes -= upload[].reservationBytes

  if refundDuplicateCharge:
    result.duplicateRefunded = true
    result.rawBudgetRefunded = upload[].rawBytes
    dec seat[].chargedModules
    seat[].chargedBytes -= upload[].rawBytes
  elif upload[].outcome.accepted and terminal.kind == tkReady:
    result.compiledResidentDelta = upload[].outcome.compiledBytes
    plane.cache.addResidentBytes(upload[].outcome.compiledBytes)
  elif upload[].outcome.accepted and terminal.kind == tkRejected:
    # The leader's compiled artifact can still be reused by another seat/hash;
    # the seat-local name rejection is not cached as a content failure.
    result.compiledResidentDelta = upload[].outcome.compiledBytes
    plane.cache.addResidentBytes(upload[].outcome.compiledBytes)

  case terminal.kind
  of tkReady:
    result.status = seat[].readyStatus(upload[].uploadId,
      upload[].originGeneration, terminal.name, terminal.hash)
  of tkRejected:
    result.status = seat[].rejectedStatus(upload[].uploadId,
      upload[].originGeneration, terminal.reason)
  of tkNone:
    doAssert false
  result.statusBytes = encodeStatusEntry(result.status)
  upload[].committed = true
  upload[].stage = usCommitted

proc commitCompileResults*(plane: CompilePlane;
    maxCommits = MaxCompileCommitsPerTick): seq[CompileCommit] =
  ## Stage 7: commit at most eight finished uploads, round-robin by seat, while
  ## preserving strict uploadId order within every seat.
  if maxCommits <= 0 or plane.seats.len == 0:
    return
  var idleScans = 0
  while result.len < maxCommits and idleScans < plane.seats.len:
    let seatIndex = plane.nextCommitSeat
    plane.nextCommitSeat = (plane.nextCommitSeat + 1) mod plane.seats.len
    var seat = addr plane.seats[seatIndex]
    if seat[].nextCommit >= seat[].uploadOrder.len:
      inc idleScans
      continue
    let uploadIndex = seat[].uploadOrder[seat[].nextCommit]
    if not plane.uploads[uploadIndex].finished:
      inc idleScans
      continue
    result.add plane.commitUpload(uploadIndex)
    inc seat[].nextCommit
    idleScans = 0

proc stageOf*(plane: CompilePlane; uploadIndex: int): UploadStage =
  plane.uploads[uploadIndex].stage

proc hashOf*(plane: CompilePlane; uploadIndex: int): string =
  plane.uploads[uploadIndex].hash

proc boundHash*(plane: CompilePlane; seatIndex: int; name: string): string =
  if seatIndex < 0 or seatIndex >= plane.seats.len:
    return ""
  plane.seats[seatIndex].names.getOrDefault(name, "")

proc boundModule*(plane: CompilePlane; seatIndex: int;
                  name: string): Option[BoundModule] =
  if plane == nil or seatIndex < 0 or seatIndex >= plane.seats.len:
    return none(BoundModule)
  let hash = plane.boundHash(seatIndex, name)
  if hash.len == 0:
    return none(BoundModule)
  let outcome = plane.cache.cachedOutcome(hash)
  if outcome.isNone:
    return none(BoundModule)
  let content = outcome.get
  some(BoundModule(name: name, hash: hash, manifest: content.manifest,
    module: content.module))
