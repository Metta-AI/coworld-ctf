## Phase P3-11: §7.2 replacement, park/resume, respawn, and pendingRetune.

import std/[json, options, sequtils, strutils, tables, unittest]

import ../src/shell/[body_map, call_validation, canonical, emit_validator,
  finisher, guards, ladder, manifest, module_cache, replacement, types]

type
  RetuneMode = enum
    rmOk
    rmMissingExport
    rmNonzero
    rmTrap

  FakeBook = ref object
    initCounts: Table[string, int]
    stepCounts: Table[string, int]
    retuneCounts: Table[string, int]
    closeCounts: Table[string, int]
    retuneModes: Table[string, RetuneMode]
    silentEntries: seq[string]
    stepFaults: seq[string]
    retunePairs: seq[string]

proc incKey(table: var Table[string, int], key: string) =
  table[key] = table.getOrDefault(key, 0) + 1

proc newBook(): FakeBook =
  FakeBook(initCounts: initTable[string, int](),
    stepCounts: initTable[string, int](),
    retuneCounts: initTable[string, int](),
    closeCounts: initTable[string, int](),
    retuneModes: initTable[string, RetuneMode]())

proc countValues(table: Table[string, int]): int =
  for value in table.values:
    result += value

proc storeCount(book: FakeBook): int =
  book.initCounts.countValues - book.closeCounts.countValues

proc canonical(text: string): string =
  canonicalJson(parseJson(text))

proc manifestFor(name: string; playClass = "controller"): PlayManifest =
  parseManifest(canonical("""
    {"abi":1,"class":"$1","modes":["br"],"name":"$2","params":{"n":{"integer":true,"kind":"number","max":999,"min":0}},"retune":true}
  """ % [playClass, name]), true)

proc hashFor(name: string): string =
  repeat(name[0], 64)

proc controllerIntent(entryId, paramsBytes: string): Intent =
  Intent(kind: ikHold, arriveRadius: 0.0,
    reason: entryId & ":" & paramsBytes)

proc fakeGuest(book: FakeBook; entry: ValidatedCallEntry;
               emitClass: EmitClass): LadderGuest =
  var
    params = entry.paramsBytes
    closed = false
  new(result)
  result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
    discard contextBytes
    params = paramsBytes
    book.initCounts.incKey(entry.entryId)
  result.runStep = proc(viewBytes: string; tick: uint32; selfPos: BodyPoint): LadderInvocationResult =
    discard viewBytes
    discard tick
    book.stepCounts.incKey(entry.entryId)
    if entry.entryId in book.stepFaults:
      return LadderInvocationResult(faulted: true, reason: "step fault")
    if entry.entryId in book.silentEntries:
      return
    if emitClass == ecController:
      result.emission.intent = some(controllerIntent(entry.entryId, params))
      result.emission.canonicalBytes = canonicalIntent(
        result.emission.intent.get)
    else:
      result.emission.policy = some(CombatPolicy(holdFire: true))
      result.emission.canonicalBytes =
        canonicalCombatPolicy(result.emission.policy.get)
  result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
    book.retuneCounts.incKey(entry.entryId)
    book.retunePairs.add oldParamsBytes & " -> " & newParamsBytes
    case book.retuneModes.getOrDefault(entry.entryId, rmOk)
    of rmOk:
      params = newParamsBytes
    of rmMissingExport:
      result.refused = true
      result.reason = "play_retune export absent"
    of rmNonzero:
      result.refused = true
      result.reason = "retune refused"
    of rmTrap:
      result.faulted = true
      result.reason = "retune trap"
  result.close = proc() =
    if not closed:
      closed = true
      book.closeCounts.incKey(entry.entryId)

proc binding(book: FakeBook; name: string; playClass = "controller"):
    LadderBinding =
  result.manifest = manifestFor(name, playClass)
  result.hash = hashFor(name)
  result.ready = true
  result.makeGuest = proc(seatIndex: int; entry: ValidatedCallEntry,
                          emitClass: EmitClass): LadderGuest =
    discard seatIndex
    fakeGuest(book, entry, emitClass)

proc registry(): PathRegistry =
  newPathRegistry([("a", pkBool)])

proc ctx(a = true): IntentContext =
  let bools = {"a": a}.toTable
  IntentContext(
    resolveNumber: proc(path: string): float = 0.0,
    resolveBool: proc(path: string): bool = bools.getOrDefault(path, false))

proc input(alive = true; a = true): LadderSeatInput =
  LadderSeatInput(alive: alive, contextBytes: "{}",
    viewSource: proc(seatIndex: int; tick: uint32): string =
      discard seatIndex
      discard tick
      "{}",
    guardContext: ctx(a),
    defaultIntent: Intent(kind: ikHold, arriveRadius: 0.0,
      reason: "default"))

proc call(entryId = "base"; play = "base"; n = 1; retune = false): string =
  let retuneField = if retune: ""","retune":true""" else: ""
  canonical("""{"plays":[{"entry_id":"$1","params":{"n":$2},"play":"$3"$4}]}""" %
    [entryId, $n, play, retuneField])

proc accept(driver: LadderDriver; seat: int; bytes: string;
            bindings: openArray[LadderBinding]; proposalId: uint64):
    LadderCallResult =
  driver.acceptCall(seat, proposalId, 7, 10, bytes, bindings, ctx())

proc snapshots(driver: LadderDriver; seat = 0): seq[LadderEntrySnapshot] =
  driver.entrySnapshots(seat)

proc first(driver: LadderDriver; seat = 0): LadderEntrySnapshot =
  driver.snapshots(seat)[0]

proc setupState(state: PlayInstanceState; book: FakeBook;
                bindings: openArray[LadderBinding]): LadderDriver =
  result = newLadderDriver(1, registry())
  case state
  of pisAbsent:
    check result.accept(0, call(), bindings, 1).accepted
  of pisLive:
    check result.accept(0, call(), bindings, 1).accepted
    discard result.tick([input()], 1, bindings)
  of pisParked:
    check result.accept(0, call(), bindings, 1).accepted
    discard result.tick([input()], 1, bindings)
    discard result.tick([input(alive = false)], 2, bindings)
  of pisPendingRetune:
    check result.accept(0, call(), bindings, 1).accepted
    discard result.tick([input()], 1, bindings)
    check result.accept(0, call(n = 2, retune = true), bindings, 2).accepted
  of pisFaulted:
    check result.accept(0, call(), bindings, 1).accepted
    discard result.tick([input()], 1, bindings)
    book.stepFaults.add "base"
    discard result.tick([input()], 2, bindings)
    check result.first().state == pisFaulted

suite "shell replacement":
  test "pure section 7.2 replacement table covers every state and incoming kind":
    for state in PlayInstanceState:
      let outgoing = ReplacementEntry(entryId: "entry", playName: "play",
        moduleHash: "h", paramsBytes: """{"n":1}""", state: state)
      let identical = classifyReplacement([outgoing],
        ReplacementEntry(entryId: "entry", playName: "play", moduleHash: "h",
          paramsBytes: """{"n":1}""", retune: true))
      let changed = classifyReplacement([outgoing],
        ReplacementEntry(entryId: "entry", playName: "play", moduleHash: "h",
          paramsBytes: """{"n":2}""", retune: true))
      let unretuned = classifyReplacement([outgoing],
        ReplacementEntry(entryId: "entry", playName: "play", moduleHash: "h",
          paramsBytes: """{"n":1}"""))

      if state in {pisLive, pisParked}:
        check identical.action == raAdoptIdentical
        check identical.nextState == state
        check identical.keepGuest
        check identical.keepCache
        check changed.action == raPendingRetune
        check changed.nextState == pisPendingRetune
        check changed.keepGuest
        check not changed.keepCache
        check changed.oldParamsBytes == """{"n":1}"""
      else:
        check identical.action == raStartAbsent
        check identical.nextState == pisAbsent
        check not identical.keepGuest
        check not identical.keepCache
        check changed.action == raStartAbsent
        check changed.nextState == pisAbsent
        check not changed.keepGuest
        check not changed.keepCache

      check unretuned.action == raStartAbsent
      check unretuned.nextState == pisAbsent
      check not unretuned.keepGuest
      check not unretuned.keepCache

    let noMatch = classifyReplacement([
      ReplacementEntry(entryId: "entry", playName: "play", moduleHash: "h",
        paramsBytes: "{}", state: pisLive)],
      ReplacementEntry(entryId: "other", playName: "play", moduleHash: "h",
        paramsBytes: "{}", retune: true))
    check not noMatch.matched
    check noMatch.action == raStartAbsent

  test "driver replacement cells assert state, Store count, status, cache, provenance, and epoch":
    type IncomingKind = enum ikIdenticalRetune, ikChangedRetune, ikNoRetune
    for state in PlayInstanceState:
      for incoming in IncomingKind:
        let book = newBook()
        let bindings = @[binding(book, "base")]
        let driver = setupState(state, book, bindings)
        defer: driver.close()
        let beforeStores = book.storeCount
        let bytes =
          case incoming
          of ikIdenticalRetune: call(retune = true)
          of ikChangedRetune: call(n = 2, retune = true)
          of ikNoRetune: call()
        let accepted = driver.accept(0, bytes, bindings, 100 + ord(incoming).uint64)
        check accepted.accepted
        check accepted.status.kind == skCallAccepted
        check driver.seatEpoch(0) == accepted.epoch
        let entry = driver.first()

        if state in {pisLive, pisParked} and incoming == ikIdenticalRetune:
          check entry.state == state
          check entry.hasGuest
          check book.storeCount == beforeStores
          if state == pisLive:
            check entry.hasCachedIntent
          else:
            check not entry.hasCachedIntent
        elif state in {pisLive, pisParked} and incoming == ikChangedRetune:
          check entry.state == pisPendingRetune
          check entry.hasGuest
          check not entry.hasCachedIntent
          check entry.oldParamsBytes == """{"n":1}"""
          check book.storeCount == beforeStores
        else:
          check entry.state == pisAbsent
          check not entry.hasGuest
          check not entry.hasCachedIntent
          check book.storeCount == 0

        if entry.state == pisPendingRetune:
          book.silentEntries.add "base"
        let tick = driver.tick([input()], 20, bindings)
        check tick.seats[0].epoch == accepted.epoch
        if entry.state == pisPendingRetune:
          check tick.seats[0].provenance.base.kind == pbDefault

  test "thirty-two changed retunes share the server quota over two ticks":
    let book = newBook()
    let bindings = @[binding(book, "base")]
    let driver = newLadderDriver(32, registry())
    defer: driver.close()
    for seat in 0 ..< 32:
      check driver.accept(seat, call(), bindings, uint64(seat + 1)).accepted
    for tick in 1'u32 .. 2'u32:
      discard driver.tick(newSeqWith(32, input()), tick, bindings)
    check book.storeCount == 32

    for seat in 0 ..< 32:
      check driver.accept(seat, call(n = 2, retune = true), bindings,
        uint64(100 + seat)).accepted
      check driver.first(seat).state == pisPendingRetune
    book.silentEntries.add "base"

    var retunedSeats: seq[int]
    for tick in 3'u32 .. 4'u32:
      let output = driver.tick(newSeqWith(32, input()), tick, bindings)
      check output.initCount == MaxInitsPerTick
      for seatIndex, seat in output.seats:
        if seat.retuned.len > 0:
          retunedSeats.add seatIndex
          check seat.retuned == @[
            LadderEntryIdentity(entryId: "base", play: "base")]
          check driver.first(seatIndex).state == pisLive
          check not driver.first(seatIndex).hasCachedIntent
          check seat.epoch == 2
    check retunedSeats == toSeq(0 .. 31)
    check book.retuneCounts["base"] == 32
    check book.storeCount == 32

  test "death and respawn while pending retune preserve guest memory but never old output":
    let book = newBook()
    let bindings = @[binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept(0, call(), bindings, 1).accepted
    discard driver.tick([input()], 1, bindings)
    check driver.first().hasCachedIntent
    let accepted = driver.accept(0, call(n = 2, retune = true), bindings, 2)
    check accepted.accepted
    check driver.first().state == pisPendingRetune
    check not driver.first().hasCachedIntent
    book.silentEntries.add "base"

    let dead = driver.tick([input(alive = false)], 2, bindings)
    check dead.seats[0].retuned == @[
      LadderEntryIdentity(entryId: "base", play: "base")]
    check dead.seats[0].usedDefault
    check dead.seats[0].provenance.base.kind == pbDefault
    check driver.first().state == pisParked
    check not driver.first().hasCachedIntent
    check book.storeCount == 1

    let respawned = driver.tick([input(alive = true)], 3, bindings)
    check respawned.seats[0].usedDefault
    check respawned.seats[0].provenance.base.kind == pbDefault
    check driver.first().state == pisLive
    check not driver.first().hasCachedIntent
    check book.storeCount == 1

  test "second replacement drops a pending retune instead of adopting it":
    let book = newBook()
    let bindings = @[binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept(0, call(), bindings, 1).accepted
    discard driver.tick([input()], 1, bindings)
    check driver.accept(0, call(n = 2, retune = true), bindings, 2).accepted
    check driver.first().state == pisPendingRetune
    check book.storeCount == 1

    let second = driver.accept(0, call(n = 2, retune = true), bindings, 3)
    check second.accepted
    check second.status.kind == skCallAccepted
    check driver.first().state == pisAbsent
    check not driver.first().hasGuest
    check not driver.first().hasCachedIntent
    check book.retuneCounts.getOrDefault("base", 0) == 0
    check book.storeCount == 0

  test "retune refusal modes drop the Store and emit retuneRefused":
    let refusals: seq[tuple[mode: RetuneMode, reason: string]] = @[
      (rmMissingExport, "play_retune export absent"),
      (rmNonzero, "retune refused"),
      (rmTrap, "retune trap")]
    for refusal in refusals:
      let book = newBook()
      book.retuneModes["base"] = refusal.mode
      let bindings = @[binding(book, "base")]
      let driver = newLadderDriver(1, registry())
      defer: driver.close()
      check driver.accept(0, call(), bindings, 1).accepted
      discard driver.tick([input()], 1, bindings)
      check book.storeCount == 1
      check driver.accept(0, call(n = 2, retune = true), bindings, 2).accepted
      let output = driver.tick([input()], 2, bindings)
      check output.seats[0].retuned.len == 0
      check output.seats[0].statuses.len == 1
      check output.seats[0].statuses[0].status.kind == skRetuneRefused
      check output.seats[0].statuses[0].status.faultEpoch == 2
      check output.seats[0].statuses[0].status.entryId == "base"
      check output.seats[0].statuses[0].status.faultReason == refusal.reason
      check output.seats[0].statuses[0].statusBytes ==
        encodeStatusEntry(output.seats[0].statuses[0].status)
      check driver.first().state == pisAbsent
      check not driver.first().hasGuest
      check not driver.first().hasCachedIntent
      check book.storeCount == 0
