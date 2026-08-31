## Phase P3-10: deterministic ladder driver ordering and quotas.

import std/[json, options, sequtils, strutils, tables, unittest]

import ../src/ctf/sim_types
import ../src/shell/[call_validation, canonical, emit_validator, finisher,
  guards, ladder, manifest, types]

type
  FakeBook = ref object
    initCounts: Table[string, int]
    stepCounts: Table[string, int]
    retuneCounts: Table[string, int]
    closeCounts: Table[string, int]
    trace: seq[string]
    silentControllers: seq[string]
    faultControllers: seq[string]
    retuneRefusers: seq[string]

proc newBook(silentControllers: seq[string] = @[];
             faultControllers: seq[string] = @[];
             retuneRefusers: seq[string] = @[]): FakeBook =
  FakeBook(initCounts: initTable[string, int](),
    stepCounts: initTable[string, int](),
    retuneCounts: initTable[string, int](),
    closeCounts: initTable[string, int](),
    silentControllers: silentControllers,
    faultControllers: faultControllers,
    retuneRefusers: retuneRefusers)

proc canonical(text: string): string =
  canonicalJson(parseJson(text))

proc manifestFor(name: string; playClass = "controller";
                 params = "{}"; retune = false): PlayManifest =
  parseManifest(canonical("""
    {"abi":1,"class":"$1","modes":["br"],"name":"$2","params":$3,"retune":$4}
  """ % [playClass, name, params, $retune]), retune)

proc hashFor(name: string): string =
  repeat(name[0], 64)

proc controllerIntent(name: string): Intent =
  Intent(kind: ikHold, arriveRadius: 0.0, reason: name)

proc overlayPolicy(name: string): CombatPolicy =
  case name
  of "law":
    CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(9)]),
      prefer: @[ptWeakened], holdFire: true)
  of "pact":
    CombatPolicy(noShoot: ProtectedSet(seats: @[SeatRef(2), SeatRef(9)]),
      protect: ProtectedSet(teams: {Navy}),
      prefer: @[ptWeakened, ptIsolated])
  else:
    CombatPolicy(holdFire: true)

proc incKey(table: var Table[string, int], key: string) =
  table[key] = table.getOrDefault(key, 0) + 1

proc fakeGuest(book: FakeBook; entryName: string;
               emitClass: EmitClass): LadderGuest =
  new(result)
  result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
    discard paramsBytes
    discard contextBytes
    book.initCounts.incKey(entryName)
  result.runStep = proc(viewBytes: string; tick: uint32): LadderInvocationResult =
    discard viewBytes
    discard tick
    book.stepCounts.incKey(entryName)
    book.trace.add(entryName)
    if entryName in book.faultControllers:
      return LadderInvocationResult(faulted: true, reason: "fake fault")
    if emitClass == ecController:
      if entryName notin book.silentControllers:
        result.emission.intent = some(controllerIntent(entryName))
        result.emission.canonicalBytes = canonicalIntent(result.emission.intent.get)
    else:
      result.emission.policy = some(overlayPolicy(entryName))
      result.emission.canonicalBytes =
        canonicalCombatPolicy(result.emission.policy.get)
  result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
    discard oldParamsBytes
    discard newParamsBytes
    book.retuneCounts.incKey(entryName)
    if entryName in book.retuneRefusers:
      return LadderInvocationResult(refused: true, reason: "retune refused")
  result.close = proc() =
    book.closeCounts.incKey(entryName)

proc binding(book: FakeBook; name: string; playClass = "controller";
             params = "{}"; retune = false): LadderBinding =
  result.manifest = manifestFor(name, playClass, params, retune)
  result.hash = hashFor(name)
  result.ready = true
  result.makeGuest = proc(seatIndex: int; entry: ValidatedCallEntry,
                          emitClass: EmitClass): LadderGuest =
    discard seatIndex
    fakeGuest(book, entry.entryId, emitClass)

proc registry(): PathRegistry =
  newPathRegistry([
    ("a", pkBool),
    ("b", pkBool),
    ("c", pkBool),
  ])

proc ctx(a = true; b = true; c = true): IntentContext =
  let bools = {"a": a, "b": b, "c": c}.toTable
  IntentContext(
    resolveNumber: proc(path: string): float = 0.0,
    resolveBool: proc(path: string): bool = bools.getOrDefault(path, false))

proc input(a = true; b = true; c = true; alive = true): LadderSeatInput =
  LadderSeatInput(alive: alive, contextBytes: "{}", viewBytes: "{}",
    guardContext: ctx(a, b, c),
    defaultIntent: Intent(kind: ikHold, arriveRadius: 0.0, reason: "default"))

proc accept(driver: LadderDriver; bytes: string;
            bindings: openArray[LadderBinding];
            proposalId = 1'u64): LadderCallResult =
  driver.acceptCall(0, proposalId, 7, 10, canonical(bytes), bindings, ctx())

suite "shell ladder":
  test "FIRST LIGHT is the zero-entry default case of the ladder driver":
    let book = newBook()
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    let tick = driver.tick([input()], 1, @[binding(book, "base")])
    check tick.initCount == 0
    check tick.stepCount == 0
    check tick.seats[0].epoch == 0
    check tick.seats[0].usedDefault
    check tick.seats[0].intent.reason == "default"

  test "first passing controller is selected top-down":
    let book = newBook()
    let bindings = @[binding(book, "alpha"), binding(book, "beta")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    let call = driver.accept("""
      {"plays":[
        {"entry_id":"alpha","play":"alpha","when":["get","a"]},
        {"entry_id":"beta","play":"beta","when":["get","b"]}]}
    """, bindings)
    check call.accepted
    let first = driver.tick([input(a = false, b = true)], 1, bindings)
    check first.seats[0].initialized == @["beta"]
    check first.seats[0].selectedEntryId == "beta"
    check first.seats[0].intent.reason == "beta"
    let second = driver.tick([input(a = true, b = true)], 2, bindings)
    check second.seats[0].initialized == @["alpha"]
    check second.seats[0].selectedEntryId == "alpha"
    check second.seats[0].intent.reason == "alpha"

  test "two overlays fold in ladder order over the controller":
    let book = newBook()
    let bindings = @[
      binding(book, "law", "overlay"),
      binding(book, "pact", "overlay"),
      binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept("""
      {"plays":[
        {"entry_id":"law","play":"law"},
        {"entry_id":"pact","play":"pact"},
        {"entry_id":"base","play":"base"}]}
    """, bindings).accepted
    discard driver.tick([input()], 1, bindings)
    discard driver.tick([input()], 2, bindings)
    let output = driver.tick([input()], 3, bindings)
    check output.stepCount == MaxStepsPerSeatPerTick
    check output.seats[0].stepped == @["law", "pact", "base"]
    check output.seats[0].intent.reason == "base"
    check output.seats[0].intent.combat.holdFire
    check output.seats[0].intent.combat.noShoot.seats == @[
      SeatRef(9), SeatRef(2)]
    check output.seats[0].intent.combat.protect.teams == {Navy}
    check output.seats[0].intent.combat.prefer == @[ptWeakened, ptIsolated]
    check output.seats[0].provenance.overlays.len == 2

  test "silent selected controller falls back to the native default":
    let book = newBook(silentControllers = @["alpha"])
    let bindings = @[binding(book, "alpha")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept("""
      {"plays":[{"entry_id":"alpha","play":"alpha"}]}
    """, bindings).accepted
    let output = driver.tick([input()], 1, bindings)
    check output.seats[0].selectedEntryId == "alpha"
    check output.seats[0].usedDefault
    check output.seats[0].intent.reason == "default"

  test "faulted controller falls through to the next initialized controller":
    let book = newBook()
    let bindings = @[binding(book, "alpha"), binding(book, "beta")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept("""
      {"plays":[
        {"entry_id":"alpha","play":"alpha","when":["get","a"]},
        {"entry_id":"beta","play":"beta"}]}
    """, bindings).accepted
    discard driver.tick([input()], 1, bindings)
    discard driver.tick([input(a = false)], 2, bindings)
    book.faultControllers.add "alpha"
    let output = driver.tick([input()], 3, bindings)
    check output.seats[0].stepped == @["alpha", "beta"]
    check output.seats[0].statuses.len == 1
    check output.seats[0].statuses[0].status.kind == skPlayFaulted
    check output.seats[0].selectedEntryId == "beta"
    check output.seats[0].intent.reason == "beta"

  test "guard flaps remove and restore overlay contribution without reinit":
    let book = newBook()
    let bindings = @[binding(book, "law", "overlay"), binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    check driver.accept("""
      {"plays":[
        {"entry_id":"law","play":"law","when":["get","a"]},
        {"entry_id":"base","play":"base"}]}
    """, bindings).accepted
    discard driver.tick([input(a = true)], 1, bindings)
    discard driver.tick([input(a = true)], 2, bindings)
    let off = driver.tick([input(a = false)], 3, bindings)
    check off.seats[0].intent.combat.noShoot.seats.len == 0
    let on = driver.tick([input(a = true)], 4, bindings)
    check on.seats[0].initialized.len == 0
    check book.initCounts["law"] == 1
    check on.seats[0].intent.combat.noShoot.seats == @[SeatRef(9)]

  test "init quotas are one per seat and two server-wide round-robin":
    let book = newBook()
    let bindings = @[binding(book, "base", params =
      "{\"n\":{\"integer\":true,\"kind\":\"number\",\"max\":10,\"min\":0}}",
      retune = true)]
    let driver = newLadderDriver(32, registry())
    defer: driver.close()
    for seat in 0 ..< 32:
      check driver.acceptCall(seat, uint64(seat + 1), 7, 1,
        canonical("""{"plays":[{"entry_id":"base","params":{"n":1},"play":"base"}]}"""),
        bindings, ctx()).accepted
    let first = driver.tick(newSeqWith(32, input()), 1, bindings)
    check first.initCount == MaxInitsPerTick
    check first.seats[0].initialized == @["base"]
    check first.seats[1].initialized == @["base"]
    check first.seats[2].initialized.len == 0
    let second = driver.tick(newSeqWith(32, input()), 2, bindings)
    check second.seats[2].initialized == @["base"]
    check second.seats[3].initialized == @["base"]

  test "retunes share the init quota and clear old output until stepped":
    let book = newBook()
    let bindings = @[binding(book, "base", params =
      "{\"n\":{\"integer\":true,\"kind\":\"number\",\"max\":10,\"min\":0}}",
      retune = true)]
    let driver = newLadderDriver(2, registry())
    defer: driver.close()
    for seat in 0 ..< 2:
      check driver.acceptCall(seat, uint64(seat + 1), 7, 1,
        canonical("""{"plays":[{"entry_id":"base","params":{"n":1},"play":"base"}]}"""),
        bindings, ctx()).accepted
    discard driver.tick(newSeqWith(2, input()), 1, bindings)
    book.silentControllers.add "base"
    check driver.acceptCall(0, 100, 8, 2,
      canonical("""{"plays":[{"entry_id":"base","params":{"n":2},"play":"base","retune":true}]}"""),
      bindings, ctx()).accepted
    check driver.acceptCall(1, 101, 8, 2,
      canonical("""{"plays":[{"entry_id":"base","params":{"n":2},"play":"base","retune":true}]}"""),
      bindings, ctx()).accepted
    let retuned = driver.tick(newSeqWith(2, input()), 2, bindings)
    check retuned.initCount == MaxInitsPerTick
    check retuned.seats[0].retuned == @["base"]
    check retuned.seats[1].retuned == @["base"]
    check retuned.seats[0].usedDefault
    check retuned.seats[0].intent.reason == "default"
    check retuned.seats[1].usedDefault
    check retuned.seats[1].intent.reason == "default"
    check book.retuneCounts["base"] == 2

  test "full 32-seat shape is capped at exactly 96 guest steps":
    let book = newBook()
    let bindings = @[
      binding(book, "law", "overlay"),
      binding(book, "pact", "overlay"),
      binding(book, "base")]
    let driver = newLadderDriver(32, registry())
    defer: driver.close()
    for seat in 0 ..< 32:
      check driver.acceptCall(seat, uint64(seat + 1), 7, 1,
        canonical("""
          {"plays":[
            {"entry_id":"law","play":"law"},
            {"entry_id":"pact","play":"pact"},
            {"entry_id":"base","play":"base"}]}
        """), bindings, ctx()).accepted
    for tick in 1'u32 .. 48'u32:
      discard driver.tick(newSeqWith(32, input()), tick, bindings)
    let full = driver.tick(newSeqWith(32, input()), 49, bindings)
    check full.stepCount == MaxPlayers * MaxStepsPerSeatPerTick
    for seat in full.seats:
      check seat.stepCount == MaxStepsPerSeatPerTick
