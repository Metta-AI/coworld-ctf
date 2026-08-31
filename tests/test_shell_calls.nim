## Total validation for decoded canonical ladder-call bytes.

import std/[json, sequtils, strutils, tables, unittest]

import ../src/shell/[call_validation, canonical, emit_validator, guards,
  manifest, types]
import ../src/ctf/sim_types

proc canonical(text: string): string =
  canonicalJson(parseJson(text))

proc manifestFor(name: string, playClass = "controller",
                 modes = @["br"]; params = "{}"): PlayManifest =
  parseManifest(canonical("""
    {"abi":1,"class":"$1","modes":$2,"name":"$3","params":$4,"retune":false}
  """ % [playClass, $(%modes), name, params]), false)

proc bound(name: string, playClass = "controller", modes = @["br"];
           params = "{}"; ready = true): BoundPlay =
  BoundPlay(manifest: manifestFor(name, playClass, modes, params),
    ready: ready)

proc call(text: string): string = canonical(text)

proc guardCtx(nums: Table[string, float] = {"world.alive_teams": 8.0}.toTable,
              bools: Table[string, bool] = {"partner.alive": true}.toTable):
              IntentContext =
  let n = nums
  let b = bools
  IntentContext(
    resolveNumber: proc(path: string): float = n.getOrDefault(path, 0.0),
    resolveBool: proc(path: string): bool = b.getOrDefault(path, false))

proc validationCtx(mode = gmBr): CallValidationContext =
  result.mode = mode
  result.registry = newPathRegistry([
    ("partner.alive", pkBool),
    ("world.alive_teams", pkNumber),
  ])
  result.guardContext = guardCtx()
  result.duoSeats[Navy] = DuoSeats(configured: true,
    seats: [SeatRef(10), SeatRef(11)])

proc entries(count: int; play = "base"): string =
  result = "{\"plays\":["
  for i in 0 ..< count:
    if i > 0: result.add ","
    result.add "{\"play\":\"" & play & "\"}"
  result.add "]}"

proc overlays(count: int): string =
  result = "{\"plays\":["
  for i in 0 ..< count:
    if i > 0: result.add ","
    result.add "{\"play\":\"overlay" & $i & "\"}"
  result.add ",{\"play\":\"base\"}]}"

proc repeated(ch: char, count: int): string =
  result = newString(count)
  for item in result.mitems:
    item = ch

suite "shell call validation":
  test "valid call is accepted atomically and evaluates guards":
    let partnerSpec =
      """{"kind":"set","max_items":8,"min_items":1,"of":"seat_or_duo_ref","required":true}"""
    let leashSpec =
      """{"integer":true,"kind":"number","max":500,"min":1}"""
    let bindings = [
      bound("pact", "overlay", params = "{\"partners\":" & partnerSpec & "}"),
      bound("bodyguard", params = "{\"leash\":" & leashSpec & "}")].toSeq
    let bytes = call("""
      {"plays":[
        {"params":{"partners":["duo:navy","seat:2"]},"play":"pact",
         "when":["<",["get","world.alive_teams"],9]},
        {"params":{"leash":250},"play":"bodyguard"}
      ]}
    """)
    let validated = validateCall(bytes, bindings, validationCtx())
    check validated.accepted
    check validated.reason.len == 0
    check validated.canonicalBytes == bytes
    check validated.entries.len == 2
    check validated.activeOverlays == @[0]
    check validated.controllerIndex == 1
    check validated.entries[0].entryId == "pact#0"
    check validated.entries[0].paramsBytes ==
      "{\"partners\":[\"duo:navy\",\"seat:2\"]}"

  test "call validation rejects the whole call with a path-rich error":
    let bindings = @[bound("base", params = "{}")]
    let rejected = validateCall(call("""
      {"plays":[{"params":{"bogus":1},"play":"base"}]}
    """), bindings, validationCtx())
    check not rejected.accepted
    check rejected.entries.len == 0
    check rejected.reason == "unknownField"
    check rejected.path == "call.plays[0].params.bogus"

  test "bound play, readiness, mode, and entry-id failures are named":
    check validateCall(call("""{"plays":[{"play":"missing"}]}"""),
      newSeq[BoundPlay](), validationCtx()).reason == "playUnknown"
    check validateCall(call("""{"plays":[{"play":"base"}]}"""),
      @[bound("base", ready = false)], validationCtx()).reason == "playNotReady"
    check validateCall(call("""{"plays":[{"play":"base"}]}"""),
      @[bound("base", modes = @["ctf"])], validationCtx()).reason ==
      "modeExcluded"
    check validateCall(call("""
      {"plays":[{"entry_id":"dup","play":"base"},
                {"entry_id":"dup","play":"base"}]}
    """), @[bound("base")], validationCtx()).reason == "duplicateEntryId"

  test "call byte cap accepts minus and at, rejects one over":
    let bindings = @[bound("base")]
    for size in [MaxCallBytes - 1, MaxCallBytes]:
      let rejected = validateCall("x".repeat(size), bindings, validationCtx())
      check rejected.reason == "nonCanonical"
    let tooLarge = validateCall("x".repeat(MaxCallBytes + 1), bindings,
      validationCtx())
    check tooLarge.reason == "callTooLarge"

  test "ladder entry cap accepts minus and at, rejects one over":
    let bindings = @[bound("base")]
    check validateCall(call(entries(MaxLadderEntries - 1)), bindings,
      validationCtx()).accepted
    check validateCall(call(entries(MaxLadderEntries)), bindings,
      validationCtx()).accepted
    let rejected = validateCall(call(entries(MaxLadderEntries + 1)), bindings,
      validationCtx())
    check rejected.reason == "tooManyEntries"
    check rejected.path == "call.plays"

  test "overlay cap accepts minus and at, rejects one over":
    var bindings = @[bound("base")]
    for i in 0 ..< MaxActiveOverlays + 1:
      bindings.add bound("overlay" & $i, "overlay")
    check validateCall(call(overlays(MaxActiveOverlays - 1)), bindings,
      validationCtx()).accepted
    check validateCall(call(overlays(MaxActiveOverlays)), bindings,
      validationCtx()).accepted
    let rejected = validateCall(call(overlays(MaxActiveOverlays + 1)),
      bindings, validationCtx())
    check rejected.reason == "tooManyOverlays"

    let inactiveExtra = validateCall(call("""
      {"plays":[
        {"play":"overlay0"},
        {"play":"overlay1"},
        {"play":"overlay2","when":false},
        {"play":"base"}]}
    """), bindings, validationCtx())
    check inactiveExtra.accepted
    check inactiveExtra.activeOverlays == @[0, 1]

  test "parameter list cap accepts minus and at, rejects one over":
    let spec = """{"kind":"list","of":"number"}"""
    let bindings = @[bound("base", params = "{\"xs\":" & spec & "}")]
    for count in [ParamListMax - 1, ParamListMax]:
      let values = toSeq(0 ..< count).mapIt($it).join(",")
      check validateCall(call("{\"plays\":[{\"params\":{\"xs\":[" &
        values & "]},\"play\":\"base\"}]}"), bindings, validationCtx()).accepted
    let tooMany = toSeq(0 .. ParamListMax).mapIt($it).join(",")
    let rejected = validateCall(call("{\"plays\":[{\"params\":{\"xs\":[" &
      tooMany & "]},\"play\":\"base\"}]}"), bindings, validationCtx())
    check rejected.reason == "tooLong"
    check rejected.path == "call.plays[0].params.xs"

  test "parameter string cap accepts minus and at, rejects one over":
    let minus = repeated('a', ParamStringMaxBytes - 1)
    let at = repeated('a', ParamStringMaxBytes)
    let over = repeated('a', ParamStringMaxBytes + 1)
    let spec = canonicalJson(%*{"kind": "enum", "of": [minus, at]})
    let bindings = @[bound("base", params = "{\"tag\":" & spec & "}")]
    for value in [minus, at]:
      check validateCall(call("{\"plays\":[{\"params\":{\"tag\":\"" &
        value & "\"},\"play\":\"base\"}]}"), bindings, validationCtx()).accepted
    let rejected = validateCall(call("{\"plays\":[{\"params\":{\"tag\":\"" &
      over & "\"},\"play\":\"base\"}]}"), bindings, validationCtx())
    check rejected.reason == "stringTooLong"
    check rejected.path == "call.plays[0].params.tag"

  test "number, enum, tuple, union, point, and condition params validate":
    let params = """
      {"aim":{"kind":"enum","of":["cover","hold"]},
       "at":{"kind":"point"},
       "cond":{"kind":"condition"},
       "limit":{"integer":true,"kind":"number","max":10,"min":1,"required":true},
       "pair":{"items":[{"kind":"number"},{"kind":"bool"}],"kind":"tuple"},
       "until":{"arms":{"aliveTeams":{"integer":true,"kind":"number","max":16,"min":2}},"kind":"union"}}
    """
    let bindings = @[bound("base", params = params)]
    check validateCall(call("""
      {"plays":[{"params":{"aim":"cover","at":[1,2],
        "cond":["get","partner.alive"],"limit":4,"pair":[3,true],
        "until":{"aliveTeams":2}},"play":"base"}]}
    """), bindings, validationCtx()).accepted
    check validateCall(call("""
      {"plays":[{"params":{"aim":"bogus","at":[1,2],
        "cond":["get","partner.alive"],"limit":4,"pair":[3,true],
        "until":{"aliveTeams":2}},"play":"base"}]}
    """), bindings, validationCtx()).reason == "range"

  test "duo params follow noDuosInMode":
    let spec = """{"kind":"seat_or_duo_ref","required":true}"""
    let bindings = @[bound("base", modes = @["br", "ctf"],
      params = "{\"ward\":" & spec & "}")]
    let rejected = validateCall(call("""
      {"plays":[{"params":{"ward":"duo:navy"},"play":"base"}]}
    """), bindings, validationCtx(gmCtf))
    check rejected.reason == "noDuosInMode"
    check rejected.path == "call.plays[0].params.ward"

  test "guard failures inside calls keep the entry path":
    let rejected = validateCall(call("""
      {"plays":[{"play":"base","when":["get","partner.alvie"]}]}
    """), @[bound("base")], validationCtx())
    check rejected.reason == "guardInvalid"
    check rejected.path == "call.plays[0].when"
    check "partner.alvie" in rejected.detail
