## Per-seat ladder driver for Season 2 plays.
##
## This module owns only tick-boundary ladder semantics. It starts from
## already-validated call bytes and already-bound compiled plays; it performs no
## packet decoding, hashing, validation, compilation, or module-cache work.

import std/options
when defined(tickShareProbe):
  import std/[json, math, strutils]

import crunchy/[common, sha256]

import ../ctf/policy_page
import ../ctf/sim_types
import body_map, call_validation, emit_validator, guards, instance,
  manifest, module_cache, replacement, replay_records, types

type
  LadderEmission* = object
    intent*: Option[Intent]
    goal*: Option[ValidatedGoal]
    policy*: Option[CombatPolicy]
    canonicalBytes*: string
    acceptedTick*: uint32

  LadderInvocationResult* = object
    faulted*: bool
    refused*: bool
    reason*: string
    emission*: LadderEmission

  LadderGuest* = ref object
    runInit*: proc(paramsBytes, contextBytes: string): LadderInvocationResult {.closure.}
    runStep*: proc(viewBytes: string; tick: uint32;
      selfPos: BodyPoint): LadderInvocationResult {.closure.}
    runRetune*: proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult {.closure.}
    close*: proc() {.closure.}

  LadderGuestFactory* = proc(seatIndex: int; entry: ValidatedCallEntry,
    emitClass: EmitClass): LadderGuest {.closure.}

  LadderBinding* = object
    manifest*: PlayManifest
    hash*: string
    ready*: bool
    makeGuest*: LadderGuestFactory

  LadderNativeBase* = object
    ## Engine-native base selected above guest controllers: currently an
    ## Appendix R reflex. Ladder keeps this shape generic so it does not import
    ## reflex observer state or body execution code.
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingEpoch*: uint64

  LadderSeatInput* = object
    alive*: bool
    selfPos*: BodyPoint
    contextBytes*: string
    viewBytes*: string
    guardContext*: IntentContext
    defaultIntent*: Intent
    defaultGoal*: Option[ValidatedGoal]
    nativeBase*: Option[LadderNativeBase]
    probeViewJson*: string
      ## FOUR DIGITS lane instrument only: the SOCKET's JSON view copy
      ## (episode.firstLightSocketViewBytes), never the GUEST's PV1 binary
      ## frame `viewBytes` above is. Always "" outside `-d:tickShareProbe`
      ## builds (see episode.nim's probeViewFor) -- one extra string field,
      ## zero behavior change, cheapest way to keep this diagnostic-only
      ## without a conditional field shape on a struct two call sites
      ## construct by full object literal.

  LadderStatus* = object
    seat*: int
    entryId*: string
    status*: StatusEntry
    statusBytes*: string

  LadderEntryIdentity* = object
    entryId*: string
    play*: string

  LadderSeatTick* = object
    seat*: int
    epoch*: uint64
    initialized*: seq[string]
    retuned*: seq[LadderEntryIdentity]
    stepped*: seq[string]
    statuses*: seq[LadderStatus]
    selectedEntryId*: string
    usedDefault*: bool
    stepCount*: int
    intent*: Intent
    goal*: Option[ValidatedGoal]
    provenance*: Provenance
    contributingEpoch*: uint64

  LadderTickResult* = object
    seats*: seq[LadderSeatTick]
    stepCount*: int
    initCount*: int

  LadderCallResult* = object
    accepted*: bool
    reason*: string
    path*: string
    epoch*: uint64
    ladderBytes*: string
    entries*: seq[PlayCallEntryIdentity]
    status*: StatusEntry
    statusBytes*: string
    pendingRetunes*: seq[LadderEntryIdentity]

  LadderEntrySnapshot* = object
    entryId*: string
    play*: string
    hash*: string
    paramsBytes*: string
    oldParamsBytes*: string
    state*: PlayInstanceState
    originGeneration*: uint64
    hasGuest*: bool
    hasCachedIntent*: bool
    hasCachedPolicy*: bool

  LadderEntry = object
    call: ValidatedCallEntry
    hash: string
    originGeneration: uint64
    guard: Option[CompiledGuard]
    state: PlayInstanceState
    guest: LadderGuest
    cachedIntent: Option[LadderEmission]
    cachedPolicy: Option[LadderEmission]
    oldParamsBytes: string
    callEpoch: uint64

  LadderSeat = object
    entries: seq[LadderEntry]
    epoch: uint64
    nextStatusOrdinal: uint64

  LadderDriver* = ref object
    seats: seq[LadderSeat]
    nextInitSeat: int
    registry: PathRegistry
    mode: GameMode
    map: BodyMap
    duoSeats: array[Team, DuoSeats]

proc toLadder(invocation: ShellInvocationResult,
              emitClass: EmitClass): LadderInvocationResult =
  result.faulted = invocation.faulted
  result.refused = invocation.refused
  result.reason = invocation.reason
  if invocation.lastAccepted.isSome:
    let accepted = invocation.lastAccepted.get
    result.emission.canonicalBytes = accepted.bytes
    case emitClass
    of ecController:
      result.emission.intent = some(accepted.intent)
      result.emission.goal = accepted.goal
    of ecOverlay:
      result.emission.policy = some(accepted.policy)

proc shellGuest*(instance: ShellInstance,
                 emitClass: EmitClass): LadderGuest =
  ## Adapter for production Wasmtime-backed instances. Tests usually provide a
  ## deterministic fake `LadderGuest` so ladder ordering can be pinned without
  ## tying those cases to guest code.
  new(result)
  result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
    instance.invokeInit(paramsBytes, contextBytes).toLadder(emitClass)
  result.runStep = proc(viewBytes: string; tick: uint32;
      selfPos: BodyPoint): LadderInvocationResult =
    instance.invokeStep(viewBytes, tick, selfPos).toLadder(emitClass)
  result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
    instance.invokeRetune(oldParamsBytes, newParamsBytes).toLadder(emitClass)
  result.close = proc() =
    instance.close()

proc newLadderDriver*(seatCount: int; registry: PathRegistry;
                      mode = gmBr; map: BodyMap = nil;
                      duoSeats: array[Team, DuoSeats] =
                        default(array[Team, DuoSeats])): LadderDriver =
  doAssert seatCount > 0
  new(result)
  result.seats = newSeq[LadderSeat](seatCount)
  result.registry = registry
  result.mode = mode
  result.map = map
  result.duoSeats = duoSeats

proc close(entry: var LadderEntry) =
  if entry.guest != nil and entry.guest.close != nil:
    entry.guest.close()
  entry.guest = nil

proc clearCache(entry: var LadderEntry) =
  entry.cachedIntent = none(LadderEmission)
  entry.cachedPolicy = none(LadderEmission)

proc close*(driver: LadderDriver) =
  if driver == nil:
    return
  for seat in driver.seats.mitems:
    for entry in seat.entries.mitems:
      entry.close()
    seat.entries.setLen(0)

proc newStatusOrdinal(seat: var LadderSeat): uint64 =
  inc seat.nextStatusOrdinal
  seat.nextStatusOrdinal

proc fitStatus(entry: var StatusEntry) =
  while encodeStatusEntry(entry).len > StatusEntryMaxBytes:
    case entry.kind
    of skCallRejected:
      if entry.callReason.len == 0: break
      entry.callReason.setLen(entry.callReason.len - 1)
    of skRetuneRefused, skPlayFaulted:
      if entry.faultReason.len == 0: break
      entry.faultReason.setLen(entry.faultReason.len - 1)
    else:
      break

proc callAcceptedStatus(seat: var LadderSeat; proposalId, generation: uint64;
                        epoch: uint64; tick: uint32): StatusEntry =
  StatusEntry(kind: skCallAccepted, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, acceptedProposalId: proposalId,
    epoch: epoch, tick: tick)

proc callRejectedStatus(seat: var LadderSeat; proposalId, generation: uint64;
                        reason, path: string): StatusEntry =
  result = StatusEntry(kind: skCallRejected, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, rejectedProposalId: proposalId,
    callReason: reason & ":" & path)
  result.fitStatus()

proc playFaultStatus(seat: var LadderSeat; epoch, generation: uint64;
                     entryId, reason: string): StatusEntry =
  result = StatusEntry(kind: skPlayFaulted, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, faultEpoch: epoch, entryId: entryId,
    faultReason: reason)
  result.fitStatus()

proc retuneRefusedStatus(seat: var LadderSeat; epoch, generation: uint64;
                         entryId, reason: string): StatusEntry =
  result = StatusEntry(kind: skRetuneRefused, ordinal: seat.newStatusOrdinal(),
    originGeneration: generation, faultEpoch: epoch, entryId: entryId,
    faultReason: reason)
  result.fitStatus()

proc boundFor(bindings: openArray[LadderBinding],
              name: string): Option[LadderBinding] =
  for binding in bindings:
    if binding.manifest.name == name:
      return some(binding)

proc boundPlays(bindings: openArray[LadderBinding]): seq[BoundPlay] =
  for binding in bindings:
    result.add BoundPlay(manifest: binding.manifest, ready: binding.ready)

proc compiledGuard(bytes: string; registry: PathRegistry): Option[CompiledGuard] =
  if bytes.len == 0:
    none(CompiledGuard)
  else:
    some(compileGuard(bytes, registry))

proc matchingEntry(oldEntries: var seq[LadderEntry],
                   call: ValidatedCallEntry; hash: string): int =
  for index, old in oldEntries:
    if old.call.entryId == call.entryId and old.call.play == call.play and
        old.hash == hash:
      return index
  -1

proc replacementEntry(entry: LadderEntry): ReplacementEntry =
  ReplacementEntry(entryId: entry.call.entryId, playName: entry.call.play,
    moduleHash: entry.hash, paramsBytes: entry.call.paramsBytes,
    state: entry.state)

proc replacementEntry(call: ValidatedCallEntry; hash: string): ReplacementEntry =
  ReplacementEntry(entryId: call.entryId, playName: call.play,
    moduleHash: hash, paramsBytes: call.paramsBytes, retune: call.retune)

proc entrySnapshots*(driver: LadderDriver; seatIndex: int):
    seq[LadderEntrySnapshot] =
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len:
    return
  for entry in driver.seats[seatIndex].entries:
    result.add LadderEntrySnapshot(entryId: entry.call.entryId,
      play: entry.call.play, hash: entry.hash,
      paramsBytes: entry.call.paramsBytes,
      oldParamsBytes: entry.oldParamsBytes, state: entry.state,
      originGeneration: entry.originGeneration, hasGuest: entry.guest != nil,
      hasCachedIntent: entry.cachedIntent.isSome,
      hasCachedPolicy: entry.cachedPolicy.isSome)

proc seatEpoch*(driver: LadderDriver; seatIndex: int): uint64 =
  if driver == nil or seatIndex < 0 or seatIndex >= driver.seats.len:
    return 0
  driver.seats[seatIndex].epoch

proc acceptCall*(driver: LadderDriver; seatIndex: int; proposalId,
                 originGeneration: uint64; tick: uint32; bytes: sink string;
                 bindings: openArray[LadderBinding];
                 guardContext: IntentContext): LadderCallResult =
  if seatIndex < 0 or seatIndex >= driver.seats.len:
    result.accepted = false
    result.reason = "badSeat"
    result.path = "seat"
    return
  var ctx = CallValidationContext(mode: driver.mode, map: driver.map,
    registry: driver.registry, guardContext: guardContext,
    duoSeats: driver.duoSeats)
  let validated = validateCall(move(bytes), bindings.boundPlays, ctx)
  var seat = addr driver.seats[seatIndex]
  if not validated.accepted:
    result.status = seat[].callRejectedStatus(proposalId, originGeneration,
      validated.reason, validated.path)
    result.statusBytes = encodeStatusEntry(result.status)
    result.reason = validated.reason
    result.path = validated.path
    return

  let nextEpoch = seat[].epoch + 1
  var oldEntries = move(seat[].entries)
  var newEntries: seq[LadderEntry]
  for call in validated.entries:
    let binding = bindings.boundFor(call.play).get
    result.entries.add PlayCallEntryIdentity(
      entryId: call.entryId,
      code: CodeIdentity(kind: cikModule, moduleSha256: binding.hash))
    var entry = LadderEntry(call: call, hash: binding.hash,
      originGeneration: originGeneration,
      guard: compiledGuard(call.guardBytes, driver.registry),
      callEpoch: nextEpoch)
    let oldIndex = oldEntries.matchingEntry(call, binding.hash)
    if oldIndex >= 0:
      var old = addr oldEntries[oldIndex]
      let replacement = classifyReplacement([old[].replacementEntry],
        replacementEntry(call, binding.hash))
      case replacement.action
      of raAdoptIdentical:
        entry.state = old[].state
        entry.guest = old[].guest
        entry.cachedIntent = old[].cachedIntent
        entry.cachedPolicy = old[].cachedPolicy
        old[].guest = nil
      of raPendingRetune:
        entry.state = pisPendingRetune
        entry.guest = old[].guest
        entry.oldParamsBytes = replacement.oldParamsBytes
        entry.callEpoch = nextEpoch
        old[].guest = nil
        result.pendingRetunes.add LadderEntryIdentity(entryId: call.entryId,
          play: call.play)
      of raStartAbsent:
        discard
    newEntries.add entry

  for old in oldEntries.mitems:
    old.close()

  seat[].entries = move(newEntries)
  seat[].epoch = nextEpoch
  result.accepted = true
  result.epoch = nextEpoch
  result.ladderBytes = validated.canonicalBytes
  result.status = seat[].callAcceptedStatus(proposalId, originGeneration,
    nextEpoch, tick)
  result.statusBytes = encodeStatusEntry(result.status)

proc guardPasses(entry: LadderEntry, ctx: IntentContext): bool =
  if entry.state == pisFaulted or entry.state == pisPendingRetune:
    return false
  if entry.guard.isSome:
    return entry.guard.get.evaluate(ctx)
  true

proc emitClass(entry: LadderEntry): EmitClass =
  if entry.call.playClass == mcOverlay: ecOverlay else: ecController

proc bindingFactory(bindings: openArray[LadderBinding],
                    entry: LadderEntry): LadderGuestFactory =
  for binding in bindings:
    if binding.manifest.name == entry.call.play and binding.hash == entry.hash:
      return binding.makeGuest

proc needsInit(entry: LadderEntry, guardActive: bool): bool =
  guardActive and entry.state == pisAbsent and entry.guest == nil

proc entryActiveForInit(entries: openArray[LadderEntry], index: int,
                        ctx: IntentContext): bool =
  let entry = entries[index]
  if entry.call.playClass == mcOverlay:
    return entry.guardPasses(ctx)
  for i in 0 ..< entries.len:
    if entries[i].call.playClass == mcOverlay:
      continue
    if entries[i].guardPasses(ctx):
      return i == index
  false

proc appendStatus(output: var LadderSeatTick; seatIndex: int; entryId: string;
                  status: StatusEntry) =
  output.statuses.add LadderStatus(seat: seatIndex, entryId: entryId,
    status: status, statusBytes: encodeStatusEntry(status))

proc initializeEntry(driver: LadderDriver; seatIndex, entryIndex: int;
                     input: LadderSeatInput;
                     bindings: openArray[LadderBinding];
                     output: var LadderSeatTick): bool =
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  let factory = bindings.bindingFactory(entry[])
  if factory == nil:
    return false
  entry[].guest = factory(seatIndex, entry[].call, entry[].emitClass)
  if entry[].guest == nil:
    entry[].state = pisFaulted
    let status = seat[].playFaultStatus(seat[].epoch, entry[].originGeneration,
      entry[].call.entryId, "instantiate returned nil")
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  let initResult = entry[].guest.runInit(entry[].call.paramsBytes,
    input.contextBytes)
  if initResult.faulted:
    entry[].state = pisFaulted
    entry[].close()
    let status = seat[].playFaultStatus(seat[].epoch, entry[].originGeneration,
      entry[].call.entryId, initResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  entry[].state = pisLive
  output.initialized.add entry[].call.entryId
  true

proc retuneEntry(driver: LadderDriver; seatIndex, entryIndex: int;
                 bindings: openArray[LadderBinding];
                 output: var LadderSeatTick): bool =
  discard bindings
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  if entry[].guest == nil:
    entry[].state = pisAbsent
    return false
  let retuneResult = entry[].guest.runRetune(entry[].oldParamsBytes,
    entry[].call.paramsBytes)
  if retuneResult.refused or retuneResult.faulted:
    entry[].state = pisAbsent
    entry[].close()
    let status = seat[].retuneRefusedStatus(seat[].epoch,
      entry[].originGeneration,
      entry[].call.entryId, retuneResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return false
  entry[].state = pisLive
  entry[].oldParamsBytes.setLen(0)
  output.retuned.add LadderEntryIdentity(entryId: entry[].call.entryId,
    play: entry[].call.play)
  true

proc firstInitializationCandidate(seat: LadderSeat,
                                  ctx: IntentContext): int =
  for index in 0 ..< seat.entries.len:
    if seat.entries[index].state == pisPendingRetune:
      return index
    if seat.entries[index].needsInit(seat.entries.entryActiveForInit(index, ctx)):
      return index
  -1

proc scheduleInitializations(driver: LadderDriver;
    inputs: openArray[LadderSeatInput]; bindings: openArray[LadderBinding];
    seatOutputs: var seq[LadderSeatTick]): int =
  if driver.seats.len == 0:
    return
  var
    granted = 0
    scanned = 0
    grantedSeat = newSeq[bool](driver.seats.len)
  while granted < MaxInitsPerTick and scanned < driver.seats.len:
    let seatIndex = driver.nextInitSeat
    driver.nextInitSeat = (driver.nextInitSeat + 1) mod driver.seats.len
    inc scanned
    if seatIndex >= inputs.len or grantedSeat[seatIndex]:
      continue
    let candidate = driver.seats[seatIndex].firstInitializationCandidate(
      inputs[seatIndex].guardContext)
    if candidate < 0:
      continue
    if driver.seats[seatIndex].entries[candidate].state == pisPendingRetune:
      discard driver.retuneEntry(seatIndex, candidate, bindings,
        seatOutputs[seatIndex])
    else:
      if not inputs[seatIndex].alive:
        continue
      discard driver.initializeEntry(seatIndex, candidate, inputs[seatIndex],
        bindings, seatOutputs[seatIndex])
    inc granted
    grantedSeat[seatIndex] = true
    result = granted
    scanned = 0

proc mergeProtected(target: var ProtectedSet; overlay: ProtectedSet) =
  target.teams = target.teams + overlay.teams
  for seat in overlay.seats:
    if seat notin target.seats:
      target.seats.add seat

proc foldOverlay(target: var CombatPolicy; overlay: CombatPolicy) =
  target.noShoot.mergeProtected(overlay.noShoot)
  target.protect.mergeProtected(overlay.protect)
  var seen: set[PreferTag]
  for tag in target.prefer:
    seen.incl tag
  for tag in overlay.prefer:
    if tag notin seen:
      target.prefer.add tag
      seen.incl tag
  target.holdFire = target.holdFire or overlay.holdFire

proc provenanceFor(entry: LadderEntry; tick: uint32): ProvenanceBase =
  discard tick
  ProvenanceBase(kind: pbEntry, entryId: entry.call.entryId,
    moduleSha256: entry.hash, emitTick: entry.cachedIntent.get.acceptedTick)

proc overlayContribution(entry: LadderEntry; tick: uint32): OverlayContribution =
  discard tick
  OverlayContribution(entryId: entry.call.entryId, moduleSha256: entry.hash,
    acceptedTick: entry.cachedPolicy.get.acceptedTick,
    policySha256: sha256(entry.cachedPolicy.get.canonicalBytes).toHex())

proc sameEmission(a, b: LadderEmission): bool =
  a.canonicalBytes == b.canonicalBytes

proc stepEntry(driver: LadderDriver; seatIndex, entryIndex: int;
               input: LadderSeatInput; tick: uint32;
               output: var LadderSeatTick) =
  var seat = addr driver.seats[seatIndex]
  var entry = addr seat[].entries[entryIndex]
  if entry[].guest == nil or entry[].state != pisLive:
    return
  let stepResult = entry[].guest.runStep(input.viewBytes, tick, input.selfPos)
  inc output.stepCount
  output.stepped.add entry[].call.entryId
  if stepResult.faulted:
    entry[].state = pisFaulted
    entry[].cachedIntent = none(LadderEmission)
    entry[].cachedPolicy = none(LadderEmission)
    entry[].close()
    let status = seat[].playFaultStatus(seat[].epoch, entry[].originGeneration,
      entry[].call.entryId, stepResult.reason)
    output.appendStatus(seatIndex, entry[].call.entryId, status)
    return
  if stepResult.emission.intent.isSome:
    var emission = stepResult.emission
    if entry[].cachedIntent.isNone or
        not entry[].cachedIntent.get.sameEmission(emission):
      emission.acceptedTick = tick
      entry[].cachedIntent = some(emission)
  if stepResult.emission.policy.isSome:
    var emission = stepResult.emission
    if entry[].cachedPolicy.isNone or
        not entry[].cachedPolicy.get.sameEmission(emission):
      emission.acceptedTick = tick
      entry[].cachedPolicy = some(emission)

proc livePassingController(seat: LadderSeat, ctx: IntentContext;
                           start = 0): int =
  for index in start ..< seat.entries.len:
    let entry = seat.entries[index]
    if entry.call.playClass != mcOverlay and entry.state == pisLive and
        entry.guardPasses(ctx):
      return index
  -1

## FOUR DIGITS lane, tick-share + track-presence instrument (plan-4digits.md
## levers 2+4, 2026-09-22). Compile-time gated (`-d:tickShareProbe`) so the
## default/shipped server binary is byte-for-byte unchanged -- this is a
## diagnostic-only probe, never armed via container env per house rule.
##
## Emits one `[tickshare]` line per sampled (seat, tick) to stdout, which
## run_series.sh already captures into `$SEED_DIR/server.log`. Answers,
## per alive tick: (a) did this tick take the native zone-escape reflex
## branch (`input.nativeBase.isSome`, ladder.nim stepSeat ~line 600) instead
## of the controller loop; (b) within controller-loop ticks, is there a
## fresh enemy track inside fire_superiority's own engageDist (mirrors
## fire_superiority.nim:415-438's own freshness/engageDist test exactly:
## FreshGunTicks=60, engageDist=750 -- both duplicated here as named
## constants rather than imported, since this module cannot see a WASM
## play's internals); (c) which phase bucket the tick falls in (opening
## tick<1500 per the plan; mid/endgame split at tick<6000/>=6000 is this
## instrument's own convention -- the plan did not pin an endgame
## threshold); (d) distance to the current zone rect's center and to its
## nearest edge (negative distEdge = outside the rect, by that many px).
##
## ALLY EXCLUSION for (b): `view.nim`'s playViewFor appends every
## fog-visible ENEMY track first (body.tracks[], already same-team-excluded
## by src/ctf/server.nim firstLightBodyInputs's visibleTracks seam), THEN
## appends the duo partner's separate unconditional grant row last, only
## when present (view.nim ~1017-1023). This probe has no cheap access to
## self/partner seat identity at this layer, so it excludes the LAST
## element of `tracks` from the engageDist scan whenever the array is
## non-empty. When a partner grant row is present this is exactly correct;
## when it is absent (partner dead/never bound) this drops one real enemy
## candidate from the scan, a conservative (undercounting, never inflating)
## bias -- documented, not hidden.
when defined(tickShareProbe):
  const
    TickShareProbeStride = 4'u32   ## sample every Nth tick: cuts log volume
                                    ## ~4x; tick-share is a proportion, so a
                                    ## stride does not bias the estimate.
    TickShareEngageDist = 750.0    ## FIRE_SUPERIORITY_ENGAGE_DIST, policy.py:246
    TickShareFreshTicks = 60'i64   ## FreshGunTicks, fire_superiority.nim:91
    TickShareOpeningEnd = 1500'u32 ## plan-4digits.md's own opening boundary
    TickShareMidEnd = 6000'u32     ## this instrument's mid/endgame split

  proc tickSharePhase(tick: uint32): string =
    if tick < TickShareOpeningEnd: "opening"
    elif tick < TickShareMidEnd: "mid"
    else: "endgame"

  proc tickShareProbeTick(seatIndex: int; input: LadderSeatInput;
                           tick: uint32; nativeFired: bool) =
    if tick mod TickShareProbeStride != 0:
      return
    var distCenter = -1.0
    var distEdge = -1.0
    var trackHit = -1  # -1 = n/a (native tick, or zone/track unreadable)
    try:
      if input.probeViewJson.len == 0:
        return
      let node = parseJson(input.probeViewJson)
      let px = input.selfPos.x.float
      let py = input.selfPos.y.float
      let world = node{"world"}
      if world != nil:
        let zone = world{"zone"}
        if zone != nil and zone.kind == JObject:
          let rect = zone{"current"}
          if rect != nil and rect.kind == JArray and rect.len == 4:
            let rx = rect[0].getFloat()
            let ry = rect[1].getFloat()
            let rw = rect[2].getFloat()
            let rh = rect[3].getFloat()
            let cx = rx + rw / 2.0
            let cy = ry + rh / 2.0
            distCenter = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
            let insideX = px >= rx and px <= rx + rw
            let insideY = py >= ry and py <= ry + rh
            if insideX and insideY:
              distEdge = min(min(px - rx, rx + rw - px),
                              min(py - ry, ry + rh - py))
            else:
              let dx = max(max(rx - px, px - (rx + rw)), 0.0)
              let dy = max(max(ry - py, py - (ry + rh)), 0.0)
              distEdge = -sqrt(dx * dx + dy * dy)
      if not nativeFired:
        let tracksNode = node{"tracks"}
        if tracksNode != nil and tracksNode.kind == JArray and
            tracksNode.len > 0:
          trackHit = 0
          # exclude the trailing partner grant row -- see module note above.
          for i in 0 ..< tracksNode.len - 1:
            let t = tracksNode[i]
            if t.kind != JObject: continue
            let posN = t{"pos"}
            if posN == nil or posN.kind != JArray or posN.len != 2: continue
            let ftick = t{"fresh_tick"}
            if ftick == nil or ftick.kind != JInt: continue
            let age = tick.int64 - ftick.getInt()
            if age > TickShareFreshTicks: continue
            let tx = posN[0].getFloat()
            let ty = posN[1].getFloat()
            let d = sqrt((px - tx) * (px - tx) + (py - ty) * (py - ty))
            if d <= TickShareEngageDist:
              trackHit = 1
              break
    except CatchableError:
      discard
    echo "[tickshare] seat=", seatIndex, " tick=", tick,
         " phase=", tickSharePhase(tick),
         " native=", (if nativeFired: 1 else: 0),
         " trackHit=", trackHit,
         " distCenter=", distCenter.formatFloat(ffDecimal, 1),
         " distEdge=", distEdge.formatFloat(ffDecimal, 1)

proc stepSeat(driver: LadderDriver; seatIndex: int; input: LadderSeatInput;
              tick: uint32; output: var LadderSeatTick) =
  output.seat = seatIndex
  output.epoch = driver.seats[seatIndex].epoch
  if not input.alive:
    for entry in driver.seats[seatIndex].entries.mitems:
      if entry.state == pisLive:
        entry.clearCache()
        entry.state = pisParked
    output.usedDefault = true
    output.intent = input.defaultIntent
    output.goal = input.defaultGoal
    output.provenance = Provenance(base: ProvenanceBase(kind: pbDefault))
    return

  for entry in driver.seats[seatIndex].entries.mitems:
    if entry.state == pisParked:
      entry.clearCache()
      entry.state = pisLive

  for index in 0 ..< driver.seats[seatIndex].entries.len:
    let entry = driver.seats[seatIndex].entries[index]
    if entry.call.playClass == mcOverlay and entry.state == pisLive and
        entry.guardPasses(input.guardContext):
      driver.stepEntry(seatIndex, index, input, tick, output)

  var base = input.defaultIntent
  output.goal = input.defaultGoal
  var provenance = Provenance(base: ProvenanceBase(kind: pbDefault))
  if input.nativeBase.isSome:
    let native = input.nativeBase.get
    base = native.intent
    output.goal = native.goal
    provenance = native.provenance
    output.contributingEpoch = max(output.contributingEpoch,
      native.contributingEpoch)
    output.usedDefault = false
  else:
    var controllerIndex = driver.seats[seatIndex].livePassingController(
      input.guardContext)
    if controllerIndex >= 0:
      while controllerIndex >= 0:
        output.selectedEntryId =
          driver.seats[seatIndex].entries[controllerIndex].call.entryId
        driver.stepEntry(seatIndex, controllerIndex, input, tick, output)
        let controller = driver.seats[seatIndex].entries[controllerIndex]
        if controller.state == pisLive and controller.cachedIntent.isSome:
          base = controller.cachedIntent.get.intent.get
          output.goal = controller.cachedIntent.get.goal
          provenance.base = controller.provenanceFor(tick)
          output.contributingEpoch = max(output.contributingEpoch,
            controller.callEpoch)
          break
        if controller.state == pisFaulted:
          controllerIndex = driver.seats[seatIndex].livePassingController(
            input.guardContext, controllerIndex + 1)
        else:
          output.usedDefault = true
          break
      if provenance.base.kind == pbDefault:
        output.usedDefault = true
      else:
        output.usedDefault = false
    else:
      output.usedDefault = true

  for entry in driver.seats[seatIndex].entries:
    if entry.call.playClass == mcOverlay and entry.state == pisLive and
        entry.guardPasses(input.guardContext) and entry.cachedPolicy.isSome:
      base.combat.foldOverlay(entry.cachedPolicy.get.policy.get)
      provenance.overlays.add entry.overlayContribution(tick)
      output.contributingEpoch = max(output.contributingEpoch, entry.callEpoch)

  output.intent = base
  output.provenance = provenance
  when defined(tickShareProbe):
    tickShareProbeTick(seatIndex, input, tick, input.nativeBase.isSome)

proc tick*(driver: LadderDriver; inputs: openArray[LadderSeatInput];
           tick: uint32;
           bindings: openArray[LadderBinding]): LadderTickResult =
  doAssert inputs.len == driver.seats.len
  result.seats = newSeq[LadderSeatTick](driver.seats.len)
  result.initCount = driver.scheduleInitializations(inputs, bindings,
    result.seats)
  for seatIndex in 0 ..< driver.seats.len:
    driver.stepSeat(seatIndex, inputs[seatIndex], tick, result.seats[seatIndex])
    result.stepCount += result.seats[seatIndex].stepCount
  doAssert result.stepCount <= driver.seats.len * MaxStepsPerSeatPerTick
