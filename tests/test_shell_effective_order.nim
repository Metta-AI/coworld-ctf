## Phase P3-12: full §7.4 standing-order cache, provenance, epoch, and
## annotation behavior over ladder outputs.

import std/[json, options, strutils, tables, unittest]

import ../src/ctf/sim_types
import ../src/shell/[body, body_map, body_nav, call_validation, canonical,
  emit_validator, finisher, guards, ladder, manifest, standing_order, types]

type
  FakeBook = ref object
    controllerSilent: seq[string]
    faultAt: Table[string, uint32]
    paramsByEntry: Table[string, string]

proc canonical(text: string): string =
  canonicalJson(parseJson(text))

proc manifestFor(name: string; playClass = "controller"): PlayManifest =
  parseManifest(canonical("""
    {"abi":1,"class":"$1","modes":["br"],"name":"$2","params":{"n":{"integer":true,"kind":"number","max":99,"min":0}},"retune":true}
  """ % [playClass, name]), true)

proc hashFor(name: string): string =
  repeat(name[0], 64)

proc holdIntent(reason: string): Intent =
  Intent(kind: ikHold, arriveRadius: 0.0, reason: reason)

proc overlayPolicy(entryId: string): CombatPolicy =
  case entryId
  of "pact":
    CombatPolicy(protect: ProtectedSet(teams: {Navy}),
      prefer: @[ptWeakened])
  of "target_law":
    CombatPolicy(holdFire: true,
      noShoot: ProtectedSet(seats: @[SeatRef(9)]))
  else:
    CombatPolicy(holdFire: true)

proc fakeGuest(book: FakeBook; entry: ValidatedCallEntry;
               emitClass: EmitClass): LadderGuest =
  new(result)
  result.runInit = proc(paramsBytes, contextBytes: string): LadderInvocationResult =
    discard contextBytes
    book.paramsByEntry[entry.entryId] = paramsBytes
  result.runStep = proc(viewBytes: string; tick: uint32): LadderInvocationResult =
    discard viewBytes
    if book.faultAt.hasKey(entry.entryId) and book.faultAt[entry.entryId] == tick:
      return LadderInvocationResult(faulted: true, reason: "fault:" & entry.entryId)
    if emitClass == ecController:
      if entry.entryId in book.controllerSilent:
        return
      let intent = holdIntent(entry.entryId & ":" &
        book.paramsByEntry.getOrDefault(entry.entryId, entry.paramsBytes))
      result.emission.intent = some(intent)
      result.emission.canonicalBytes = canonicalIntent(intent)
    else:
      let policy = overlayPolicy(entry.entryId)
      result.emission.policy = some(policy)
      result.emission.canonicalBytes = canonicalCombatPolicy(policy)
  result.runRetune = proc(oldParamsBytes, newParamsBytes: string): LadderInvocationResult =
    discard oldParamsBytes
    book.paramsByEntry[entry.entryId] = newParamsBytes
  result.close = proc() =
    discard

proc binding(book: FakeBook; name: string; playClass = "controller"):
    LadderBinding =
  result.manifest = manifestFor(name, playClass)
  result.hash = hashFor(name)
  result.ready = true
  result.makeGuest = proc(entry: ValidatedCallEntry,
                          emitClass: EmitClass): LadderGuest =
    fakeGuest(book, entry, emitClass)

proc registry(): PathRegistry =
  newPathRegistry([
    ("a", pkBool),
    ("b", pkBool),
    ("pact_on", pkBool),
    ("target_on", pkBool),
  ])

proc ctx(a = true; b = true; pactOn = true; targetOn = true):
    IntentContext =
  let bools = {
    "a": a,
    "b": b,
    "pact_on": pactOn,
    "target_on": targetOn}.toTable
  IntentContext(
    resolveNumber: proc(path: string): float = 0.0,
    resolveBool: proc(path: string): bool = bools.getOrDefault(path, false))

proc input(a = true; b = true; pactOn = true; targetOn = true):
    LadderSeatInput =
  LadderSeatInput(alive: true, contextBytes: "{}", viewBytes: "{}",
    guardContext: ctx(a, b, pactOn, targetOn),
    defaultIntent: holdIntent("default"))

proc body(): SeatBody =
  const Side = 96
  var walkable = newSeq[bool](Side * Side)
  for cell in walkable.mitems:
    cell = true
  let map = newBodyMap(walkable, Side, Side, 1, @[(10, 10)])
  activateSeatBody(newBodyNavSystem(map, 1, GunRange), 0)

proc toResolved(tick: LadderSeatTick): ResolvedStandingOrder =
  ResolvedStandingOrder(intent: tick.intent, goal: tick.goal,
    provenance: tick.provenance,
    contributingEpoch: tick.contributingEpoch)

proc install(standing: var StandingOrderState; body: SeatBody;
             output: LadderSeatTick; tick: uint32; idleAim = 64) =
  standing.stepResolvedOrder(body, tick, output.toResolved, idleAim)

proc installRecorded(standing: var StandingOrderState; body: SeatBody;
                     output: LadderSeatTick; tick: uint32;
                     installedBytes: var seq[string]; idleAim = 64) =
  let before = standing.annotations.len
  standing.install(body, output, tick, idleAim)
  if standing.annotations.len > before:
    installedBytes.add standing.intentBytes

proc accept(driver: LadderDriver; bytes: string;
            bindings: openArray[LadderBinding];
            proposalId = 1'u64): LadderCallResult =
  driver.acceptCall(0, proposalId, 7, 1, canonical(bytes), bindings, ctx())

proc replayBytes(annotations: openArray[ShellAnnotation]): seq[string] =
  for order in reconstructStandingOrders(annotations):
    result.add order.intentBytes

suite "shell effective order":
  test "two active overlays leave on the exact tick their pact or target-law guard stops passing":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32]())
    let bindings = @[
      binding(book, "base"),
      binding(book, "pact", "overlay"),
      binding(book, "target_law", "overlay")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    var installedBytes: seq[string]
    let seatBody = body()
    check driver.accept("""
      {"plays":[
        {"entry_id":"base","params":{"n":1},"play":"base"},
        {"entry_id":"pact","params":{"n":1},"play":"pact","when":["get","pact_on"]},
        {"entry_id":"target_law","params":{"n":1},"play":"target_law","when":["get","target_on"]}]}
    """, bindings).accepted

    for tick in 1'u32 .. 3'u32:
      standing.installRecorded(seatBody, driver.tick([input()], tick,
        bindings).seats[0], tick, installedBytes)
    check standing.intent.combat.protect.teams == {Navy}
    check standing.intent.combat.noShoot.seats == @[SeatRef(9)]
    check standing.intent.combat.holdFire
    check standing.provenance.overlays.len == 2
    check standing.installedEffectiveEpoch == 1

    let targetOff = driver.tick([input(targetOn = false)], 4, bindings).seats[0]
    standing.installRecorded(seatBody, targetOff, 4, installedBytes)
    check standing.intent.combat.protect.teams == {Navy}
    check standing.intent.combat.noShoot.seats.len == 0
    check not standing.intent.combat.holdFire
    check standing.provenance.overlays.len == 1
    check standing.annotations[^1].tick == 4

    let pactOff = driver.tick([input(pactOn = false, targetOn = false)], 5,
      bindings).seats[0]
    standing.installRecorded(seatBody, pactOff, 5, installedBytes)
    check standing.intent.combat.protect.teams == {}
    check standing.provenance.overlays.len == 0
    check standing.annotations[^1].tick == 5
    check standing.annotations.replayBytes == installedBytes

  test "overlay fault removes its cached policy on the faulting tick":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32]())
    book.faultAt["pact"] = 4
    let bindings = @[binding(book, "base"), binding(book, "pact", "overlay")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    let seatBody = body()
    check driver.accept("""
      {"plays":[
        {"entry_id":"base","params":{"n":1},"play":"base"},
        {"entry_id":"pact","params":{"n":1},"play":"pact"}]}
    """, bindings).accepted
    for tick in 1'u32 .. 3'u32:
      standing.install(seatBody, driver.tick([input()], tick, bindings).seats[0],
        tick)
    check standing.provenance.overlays.len == 1
    let fault = driver.tick([input()], 4, bindings).seats[0]
    standing.install(seatBody, fault, 4)
    check fault.statuses.len == 1
    check fault.statuses[0].status.kind == skPlayFaulted
    check standing.provenance.overlays.len == 0
    check standing.intent.combat.protect.teams == {}
    check standing.annotations[^1].tick == 4

  test "selection A to B uses default while B is silent, then credits B when it emits":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32](), controllerSilent: @["b"])
    let bindings = @[binding(book, "a"), binding(book, "b")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    let seatBody = body()
    check driver.accept("""
      {"plays":[
        {"entry_id":"a","params":{"n":1},"play":"a","when":["get","a"]},
        {"entry_id":"b","params":{"n":1},"play":"b","when":["get","b"]}]}
    """, bindings).accepted
    standing.install(seatBody, driver.tick([input(a = true, b = true)], 1,
      bindings).seats[0], 1)
    check standing.provenance.base.kind == pbEntry
    check standing.provenance.base.entryId == "a"
    check standing.installedEffectiveEpoch == 1

    standing.install(seatBody, driver.tick([input(a = false, b = true)], 2,
      bindings).seats[0], 2)
    check standing.provenance.base.kind == pbDefault
    check standing.installedEffectiveEpoch == 1
    check standing.intent.reason == "default"

    book.controllerSilent.setLen(0)
    standing.install(seatBody, driver.tick([input(a = false, b = true)], 3,
      bindings).seats[0], 3)
    check standing.provenance.base.kind == pbEntry
    check standing.provenance.base.entryId == "b"
    check standing.provenance.base.emitTick == 3
    check standing.installedEffectiveEpoch == 1

  test "reflex base can be replaced by a silent controller without advancing epoch until the controller contributes":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32](), controllerSilent: @["a"])
    let bindings = @[binding(book, "a")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    let seatBody = body()

    standing.stepResolvedOrder(seatBody, 1, ResolvedStandingOrder(
      intent: holdIntent("reflex"),
      provenance: Provenance(base: ProvenanceBase(kind: pbReflex,
        reflexName: "reflex_zone_escape"))), 64)
    check standing.provenance.base.kind == pbReflex
    check standing.installedEffectiveEpoch == 0

    check driver.accept("""
      {"plays":[{"entry_id":"a","params":{"n":1},"play":"a"}]}
    """, bindings).accepted
    standing.install(seatBody, driver.tick([input()], 2, bindings).seats[0], 2)
    check standing.provenance.base.kind == pbDefault
    check standing.installedEffectiveEpoch == 0

    book.controllerSilent.setLen(0)
    standing.install(seatBody, driver.tick([input()], 3, bindings).seats[0], 3)
    check standing.provenance.base.kind == pbEntry
    check standing.provenance.base.entryId == "a"
    check standing.installedEffectiveEpoch == 1

  test "retune success with silent post-retune steps never attributes old output to the new epoch":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32]())
    let bindings = @[binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    let seatBody = body()
    check driver.accept("""
      {"plays":[{"entry_id":"base","params":{"n":1},"play":"base"}]}
    """, bindings).accepted
    standing.install(seatBody, driver.tick([input()], 1, bindings).seats[0], 1)
    check standing.intent.reason.contains("\"n\":1")
    check standing.installedEffectiveEpoch == 1

    book.controllerSilent.add "base"
    check driver.accept("""
      {"plays":[{"entry_id":"base","params":{"n":2},"play":"base","retune":true}]}
    """, bindings, 2).accepted
    for tick in 2'u32 .. 4'u32:
      standing.install(seatBody, driver.tick([input()], tick, bindings).seats[0],
        tick)
      check not standing.intent.reason.contains("\"n\":1")
      check standing.provenance.base.kind == pbDefault
      check standing.installedEffectiveEpoch == 1

    book.controllerSilent.setLen(0)
    standing.install(seatBody, driver.tick([input()], 5, bindings).seats[0], 5)
    check standing.intent.reason.contains("\"n\":2")
    check standing.provenance.base.kind == pbEntry
    check standing.provenance.base.emitTick == 5
    check standing.installedEffectiveEpoch == 2

  test "long identical-emission run preserves accepted tick and emits one annotation":
    let book = FakeBook(paramsByEntry: initTable[string, string](),
      faultAt: initTable[string, uint32]())
    let bindings = @[binding(book, "base")]
    let driver = newLadderDriver(1, registry())
    defer: driver.close()
    var standing: StandingOrderState
    let seatBody = body()
    check driver.accept("""
      {"plays":[{"entry_id":"base","params":{"n":1},"play":"base"}]}
    """, bindings).accepted

    for tick in 1'u32 .. 20'u32:
      standing.install(seatBody, driver.tick([input()], tick, bindings).seats[0],
        tick)
      check standing.provenance.base.kind == pbEntry
      check standing.provenance.base.emitTick == 1
      check standing.intent.reason.contains("\"n\":1")
    check standing.annotations.len == 1
    check standing.annotations.replayBytes.len == 1
    check standing.annotations.replayBytes[0] == standing.intentBytes
