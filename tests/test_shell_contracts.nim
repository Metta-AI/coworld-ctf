## The play-calling shell's contracts-first commit, held to its own rules
## (docs/designs/strategy-play-calling-shell-2026-08-29.md):
##
## - the canonical encoding is one byte encoding (src/shell/canonical.nim),
##   and every golden fixture in tests/fixtures/shell/ IS canonical bytes;
## - 64-bit identities are decimal strings, full uint64 range, malformed
##   spellings rejected (§5's cross-language rule, 2^53 boundaries included);
## - the packet opcodes and bumped-format record types collide with nothing;
## - the config fields (season2Shell, allowDeprecatedModes, slots[].control,
##   viewIntervalTicks, lobbyChatTicks, playSeatBindTicks) parse, validate,
##   and echo per §5.1/§9.2/P2/P36 — and a default config's replay JSON keeps
##   the shell defaults implicit.

import std/[algorithm, json, os, re, strutils, tables, unittest]
import ../src/ctf/sim_config
import ../src/ctf/sim_types
import ../src/shell/types
import ../src/shell/canonical
import ../src/shell/canonical_fast
import ../src/shell/manifest
import ../src/shell/policy_encoding
import std/math

const FixtureDir = "tests" / "fixtures" / "shell"

const GoldenFiles = [
  "intent.golden.json", "intent_safe_hold.golden.json",
  "intent_handoff.golden.json",
  "combat_policy.golden.json",
  "status_module_accepted.golden.json", "status_module_ready.golden.json",
  "status_module_rejected.golden.json", "status_call_accepted.golden.json",
  "status_call_rejected.golden.json", "status_retune_refused.golden.json",
  "status_play_faulted.golden.json",
  "control_view.golden.json", "control_context.golden.json",
  "play_context.golden.json", "play_view.golden.json",
  "manifest_edge_ride.golden.json", "manifest_pact.golden.json",
  "ladder_call.golden.json",
  "floats.golden.json"
]

const SchemaDir = "src" / "shell" / "schemas"

## golden -> the schema it must conform to ("" = canonical-bytes only:
## floats.golden.json pins the number grammar, not a message shape).
const GoldenSchemas = {
  "intent.golden.json": "intent.schema.json",
  "intent_safe_hold.golden.json": "intent.schema.json",
  "intent_handoff.golden.json": "intent.schema.json",
  "combat_policy.golden.json": "combat_policy.schema.json",
  "status_module_accepted.golden.json": "status_entry.schema.json",
  "status_module_ready.golden.json": "status_entry.schema.json",
  "status_module_rejected.golden.json": "status_entry.schema.json",
  "status_call_accepted.golden.json": "status_entry.schema.json",
  "status_call_rejected.golden.json": "status_entry.schema.json",
  "status_retune_refused.golden.json": "status_entry.schema.json",
  "status_play_faulted.golden.json": "status_entry.schema.json",
  "control_view.golden.json": "control_view.schema.json",
  "control_context.golden.json": "control_context.schema.json",
  "play_context.golden.json": "play_context.schema.json",
  "play_view.golden.json": "play_view.schema.json",
  "manifest_edge_ride.golden.json": "manifest.schema.json",
  "manifest_pact.golden.json": "manifest.schema.json",
  "ladder_call.golden.json": "ladder_call.schema.json"
}.toTable

var schemaCache = initTable[string, JsonNode]()

proc loadSchema(name: string): JsonNode =
  if name notin schemaCache:
    schemaCache[name] = parseJson(readFile(SchemaDir / name))
  schemaCache[name]

proc resolveRef(schema: JsonNode, root: JsonNode): (JsonNode, JsonNode) =
  ## Returns (resolved schema, its root document) for local (#/$defs/...)
  ## and cross-file references.
  if schema.kind == JObject and schema.hasKey("$ref"):
    let target = schema["$ref"].getStr()
    if target.startsWith("#/$defs/"):
      return (root["$defs"][target["#/$defs/".len .. ^1]], root)
    let fileRoot = loadSchema(target)
    return (fileRoot, fileRoot)
  (schema, root)

proc conforms(value: JsonNode, rawSchema: JsonNode, root: JsonNode,
              path: string): seq[string] =
  ## A deliberately minimal validator for exactly the features these
  ## schemas use (type/const/enum/required/properties/additionalProperties/
  ## items/pattern/minItems/maxItems/allOf-if-then/$ref/oneOf). NOT a
  ## general JSON Schema engine; the schemas remain the normative text.
  let (schema, root) = resolveRef(rawSchema, root)
  template fail(msg: string) = result.add(path & ": " & msg)
  if schema.hasKey("const"):
    if value != schema["const"]: fail("const mismatch")
  if schema.hasKey("enum"):
    var hit = false
    for option in schema["enum"]:
      if value == option: hit = true
    if not hit: fail("not in enum")
  if schema.hasKey("type"):
    let want = schema["type"].getStr()
    let ok = case want
      of "object": value.kind == JObject
      of "array": value.kind == JArray
      of "string": value.kind == JString
      of "boolean": value.kind == JBool
      of "integer": value.kind == JInt
      of "number": value.kind in {JInt, JFloat}
      else: true
    if not ok: fail("type is not " & want)
  if schema.hasKey("oneOf"):
    var passed = 0
    for arm in schema["oneOf"]:
      if conforms(value, arm, root, path).len == 0:
        inc passed
    if passed != 1: fail("oneOf matched " & $passed & " arms")
  if schema.hasKey("minimum") and value.kind in {JInt, JFloat}:
    if value.getFloat() < schema["minimum"].getFloat(): fail("below minimum")
  if schema.hasKey("maximum") and value.kind in {JInt, JFloat}:
    if value.getFloat() > schema["maximum"].getFloat(): fail("above maximum")
  if schema.hasKey("maxLength") and value.kind == JString:
    if value.getStr().len > schema["maxLength"].getInt():
      fail("over maxLength")
  if schema.hasKey("x_max_utf8_bytes") and value.kind == JString:
    # the NORMATIVE byte cap (README): counted on the UTF-8 encoding
    if value.getStr().len > schema["x_max_utf8_bytes"].getInt():
      fail("over the UTF-8 byte cap")
  if value.kind == JObject and schema.hasKey("maxProperties"):
    var count = 0
    for _ in value.keys: inc count
    if count > schema["maxProperties"].getInt(): fail("too many properties")
  if value.kind == JObject and schema.hasKey("propertyNames"):
    let namePattern = schema["propertyNames"]["pattern"].getStr()
    for key in value.keys:
      if not key.match(re("^(" & namePattern.strip(chars = {'^', '$'}) &
          ")$")):
        fail("property name " & key & " fails pattern")
  if schema.hasKey("pattern") and value.kind == JString:
    if not value.getStr().match(re("^(" &
        schema["pattern"].getStr().strip(chars = {'^', '$'}) & ")$")):
      fail("pattern mismatch")
  if value.kind == JObject:
    if schema.hasKey("required"):
      for key in schema["required"]:
        if not value.hasKey(key.getStr()): fail("missing " & key.getStr())
    for key, sub in value.pairs:
      if schema.hasKey("properties") and schema["properties"].hasKey(key):
        result.add(conforms(sub, schema["properties"][key], root,
                            path & "." & key))
      elif schema.hasKey("additionalProperties"):
        let extra = schema["additionalProperties"]
        if extra.kind == JBool and not extra.getBool():
          fail("unknown key " & key)
        elif extra.kind == JObject:
          result.add(conforms(sub, extra, root, path & "." & key))
  if value.kind == JArray:
    if schema.hasKey("minItems") and
        value.len < schema["minItems"].getInt(): fail("too few items")
    if schema.hasKey("maxItems") and
        value.len > schema["maxItems"].getInt(): fail("too many items")
    if schema.hasKey("items") and schema["items"].kind == JObject:
      for i, item in value.elems:
        result.add(conforms(item, schema["items"], root,
                            path & "[" & $i & "]"))
  if schema.hasKey("allOf"):
    for rule in schema["allOf"]:
      if rule.hasKey("if") and value.kind == JObject:
        var applies = true
        for key, cond in rule["if"]["properties"].pairs:
          if not value.hasKey(key):
            applies = false
          elif cond.hasKey("const"):
            if value[key] != cond["const"]: applies = false
          elif cond.hasKey("enum"):
            var hit = false
            for option in cond["enum"]:
              if value[key] == option: hit = true
            if not hit: applies = false
        if applies and rule.hasKey("then"):
          let then = rule["then"]
          if then.hasKey("properties"):
            for key, sub in then["properties"].pairs:
              if value.hasKey(key):
                result.add(conforms(value[key], sub, root,
                                    path & "." & key))
          if then.hasKey("required"):
            for key in then["required"]:
              if not value.hasKey(key.getStr()):
                fail("arm requires " & key.getStr())
          if then.hasKey("not"):
            var banned: seq[string]
            if then["not"].hasKey("required"):
              for key in then["not"]["required"]: banned.add(key.getStr())
            if then["not"].hasKey("anyOf"):
              for arm in then["not"]["anyOf"]:
                for key in arm["required"]: banned.add(key.getStr())
            for key in banned:
              if value.hasKey(key): fail("arm forbids " & key)
      elif not rule.hasKey("if"):
        result.add(conforms(value, rule, root, path))

suite "shell canonical encoding":
  test "every golden fixture is its own canonical re-encoding":
    ## Byte equality after a parse round trip is what makes the fixtures
    ## usable as cross-implementation goldens: any producer that emits
    ## canonical bytes reproduces the file exactly.
    for name in GoldenFiles:
      let bytes = readFile(FixtureDir / name)
      # Byte equality with the canonical re-encoding IS the whitespace and
      # key-order proof; raw newlines additionally can never appear
      # (escapeJson escapes them inside strings).
      check canonicalJson(parseJson(bytes)) == bytes
      # And every golden must pass the PRODUCTION validating parser —
      # schema conformance is not validator conformance (the lane C
      # golden-gap class); the reference re-encode above and the fast
      # path must agree that these bytes are canonical.
      validateCanonical(bytes)
      check '\n' notin bytes

  test "object keys are sorted and sets are pre-sorted in the goldens":
    let intent = parseJson(readFile(FixtureDir / "intent.golden.json"))
    var last = ""
    for key in intent.keys:
      check key > last or last.len == 0
      if key > last: last = key
    # Every SET-kind field is strictly increasing by wire text — which is
    # sortedness AND deduplication in one check. `prefer` is deliberately
    # absent: it is an ORDERED priority list, not a set.
    proc checkSet(node: JsonNode) =
      var prev = ""
      for element in node:
        check element.getStr() > prev
        prev = element.getStr()
    checkSet(intent["micro"])
    for setOwner in [intent["combat"]["no_shoot"], intent["combat"]["protect"]]:
      for field in ["teams", "seats"]:
        if setOwner.hasKey(field):
          checkSet(setOwner[field])
    let policy = parseJson(readFile(FixtureDir / "combat_policy.golden.json"))
    for setOwner in [policy["no_shoot"], policy["protect"]]:
      for field in ["teams", "seats"]:
        if setOwner.hasKey(field):
          checkSet(setOwner[field])
    # The manifest's SET fields: `modes`, and every enum param's `of` — the
    # closed option set is canonicalized too (the schema $comment states the
    # rule; the production validator lands with lane C's runtime, so this
    # golden check is main's only tripwire until then).
    let manifest = parseJson(readFile(FixtureDir / "manifest_pact.golden.json"))
    checkSet(manifest["modes"])
    for name, spec in manifest["params"]:
      if spec.kind == JObject and spec.hasKey("kind") and
          spec["kind"].getStr() == "enum":
        checkSet(spec["of"])

  test "set order is wire text, not numeric: two-digit seats sort before seat:4":
    # Every golden uses single-digit seats, so a producer sorting seat refs
    # NUMERICALLY would pass those. The production writer sorts by wire text
    # ("seat:10" < "seat:4"); this pins that against regression.
    var w = initCanonicalWriter()
    w.writeProtectedSet(ProtectedSet(
      seats: @[SeatRef(4'u8), SeatRef(12'u8), SeatRef(10'u8), SeatRef(4'u8)]))
    check w.take() == """{"seats":["seat:10","seat:12","seat:4"]}"""

  test "uint64 identities round-trip at the 2^53 boundaries and the top":
    for value in [0'u64, 9007199254740991'u64, 9007199254740992'u64,
                  high(uint64)]:
      check parseUint64Key(uint64Key(value)) == value

  test "malformed uint64 spellings are rejected":
    expect ValueError: discard parseUint64Key(%7)          # numeric
    expect ValueError: discard parseUint64Key(%"")         # empty
    expect ValueError: discard parseUint64Key(%"07")       # leading zero
    expect ValueError: discard parseUint64Key(%"12x")      # non-digit
    expect ValueError: discard parseUint64Key(%"18446744073709551616") # 2^64
    check parseUint64Key(%"0") == 0'u64                    # bare zero is legal

  test "canonicalFloat: the grammar is fixed and target-independent":
    ## Review finding: bare `$` is not one cross-language encoding. The
    ## grammar: shortest digits, plain notation inside [1e-6, 1e21),
    ## -0.0 normalized, non-finite and out-of-range refused.
    check canonicalFloat(-0.0) == "0.0"
    check canonicalFloat(0.5) == "0.5"
    check canonicalFloat(24.0) == "24.0"
    check canonicalFloat(-2.5) == "-2.5"
    check canonicalFloat(0.000001) == "0.000001"
    check canonicalFloat(999999999999999900000.0) ==
      "999999999999999900000.0"   # shortest digits, POINT-MOVED expansion
    # Outside the plain interval: the normalized exponent spelling (any
    # finite number is encodable — Appendix P.1 has no magnitude bounds).
    check canonicalFloat(1e-7) == "1e-7"
    check canonicalFloat(1.5e-7) == "1.5e-7"
    check canonicalFloat(1e21) == "1e+21"
    check canonicalFloat(2.5e30) == "2.5e+30"
    check canonicalFloat(1e-100) == "1e-100"
    check canonicalFloat(-2.5e-9) == "-2.5e-9"
    expect ValueError: discard canonicalFloat(NaN)
    expect ValueError: discard canonicalFloat(Inf)
    expect ValueError: discard canonicalFloat(-Inf)

  test "every message golden conforms to its normative schema":
    ## Review finding: canonical bytes alone let a fixture drift from its
    ## schema. The mini-validator covers exactly the features the schemas
    ## use (unions via allOf if/then included).
    for name, schemaName in GoldenSchemas.pairs:
      let value = parseJson(readFile(FixtureDir / name))
      let problems = conforms(value, loadSchema(schemaName),
                              loadSchema(schemaName), name)
      checkpoint($problems)
      check problems.len == 0

  test "manifest ParamSpec depth stays within ParamNestingMax":
    ## The recursive $ref cannot carry the depth cap, so it is enforced
    ## here semantically (and by the engine at upload, §6.2).
    proc specDepth(spec: JsonNode): int =
      result = 1
      if spec.kind != JObject: return
      if spec.hasKey("items"):
        for item in spec["items"]:
          result = max(result, 1 + specDepth(item))
      if spec.hasKey("arms"):
        for _, arm in spec["arms"].pairs:
          result = max(result, 1 + specDepth(arm))
      if spec.hasKey("of") and spec["of"].kind == JObject:
        result = max(result, 1 + specDepth(spec["of"]))
    let manifest = parseJson(readFile(FixtureDir / "manifest_pact.golden.json"))
    var params = 0
    for _, spec in manifest["params"].pairs:
      inc params
      check specDepth(spec) <= ParamNestingMax
    check params <= MaxParamsPerSchema

  test "every manifest golden is accepted by the production parser":
    ## JSON Schema cannot express canonical set order, so the production
    ## manifest parser is the contract oracle for sorted enum/set values.
    for name in GoldenFiles:
      if name.startsWith("manifest_"):
        let bytes = readFile(FixtureDir / name)
        let hasRetune = parseJson(bytes)["retune"].getBool
        let parsed = parseManifest(bytes, hasRetune = hasRetune)
        check parsed.name.len > 0

  test "the ParamSpec kind branches discriminate (negative controls)":
    proc badSpec(spec: JsonNode): bool =
      let wrapped = %*{"abi": 1, "name": "x", "class": "overlay",
        "modes": ["br"], "retune": false, "params": {"p": spec}}
      conforms(wrapped, loadSchema("manifest.schema.json"),
               loadSchema("manifest.schema.json"), "neg").len > 0
    check badSpec(%*{"kind": "bool", "arms": {}})          # bool bans arms
    check badSpec(%*{"kind": "enum", "of": "number"})      # enum needs array
    check badSpec(%*{"kind": "union"})                     # union needs arms
    check badSpec(%*{"kind": "number", "required": true,
      "default": 3})                                       # required+default
    check badSpec(%*{"kind": "team_list", "min_items": 1})  # list-only cap
    check not badSpec(%*{"kind": "bool", "default": false})

  test "seventeen parameters fail the manifest cap (negative control)":
    var params = newJObject()
    for i in 0 .. 16:
      params["p" & $i] = %*{"kind": "bool"}
    let manifest = %*{"abi": 1, "name": "x", "class": "overlay",
      "modes": ["br"], "retune": false, "params": params}
    check conforms(manifest, loadSchema("manifest.schema.json"),
                   loadSchema("manifest.schema.json"), "neg").len > 0

  test "the union arms actually discriminate (negative controls)":
    ## A hold with a point, a navigate_to without one, a module_ready
    ## missing its hash, and a visible_cone carrying the anonymous arm's
    ## field must all FAIL their schemas — proving the arm rules bite.
    proc bad(value: JsonNode, schemaName: string): bool =
      conforms(value, loadSchema(schemaName), loadSchema(schemaName),
               "neg").len > 0
    check bad(%*{"schema": "intent", "v": 1, "kind": "hold",
      "arrive_radius": 0.0, "point": [1, 2]}, "intent.schema.json")
    check bad(%*{"schema": "intent", "v": 1, "kind": "navigate_to",
      "arrive_radius": 0.0}, "intent.schema.json")
    check bad(%*{"kind": "module_ready", "ordinal": "1", "gen": "1",
      "upload_id": "1", "name": "pact"}, "status_entry.schema.json")
    check bad(%*{"kind": "module_accepted", "ordinal": "07", "gen": "1",
      "upload_id": "1"}, "status_entry.schema.json")
    check bad(%*{"kind": "module_accepted", "ordinal": "7", "gen": "1",
      "upload_id": "1", "code": "outOfFuel"}, "status_entry.schema.json")
    check bad(%*{"kind": "play_faulted", "ordinal": "7", "gen": "1",
      "epoch": "1", "entry_id": "x", "reason": "r"},
      "status_entry.schema.json")

  test "every status-entry golden fits the 256-byte entry cap":
    for name in GoldenFiles:
      if name.startsWith("status_"):
        check readFile(FixtureDir / name).len <= StatusEntryMaxBytes

suite "shell opcode and record blocks":
  test "packet opcodes sit outside the Sprite v1 client set":
    for op in [OpModuleUpload, OpPlayCall, OpStatusAck, OpLobbyChatSend,
               OpPlayContext, OpPlayView, OpLobbyChatBroadcast]:
      check op > 0x86'u8

  test "record types extend the codec's block without collision":
    for rec in [RecPlayCall, RecBehaviorAnnotation, RecManifest,
                RecLobbyChat, RecDisconnect, RecKick, RecRebind]:
      check rec > 0x06'u8 and rec < 0x81'u8
    check RecPlayCall == 0x10'u8 and RecRebind == 0x16'u8

  test "the derived limits agree with their derivations":
    check PlaySeatReceiveLimitBytes == 14 + MaxModuleBytes
    check MaxRetainedStatusBytes ==
      MaxRetainedStatusEntries * StatusEntryMaxBytes
    check MaxStepsPerSeatPerTick == MaxActiveOverlays + 1

suite "shell config gate":
  test "default config: the replay config JSON keeps shell defaults implicit":
    ## P36: season2Shell defaults on, but its replay-header echo is still
    ## silent at default. The new override key is silent unless it is true.
    let echoed = defaultGameConfig().configJson()
    for key in ["season2Shell", "viewIntervalTicks", "lobbyChatTicks",
                "playSeatBindTicks", "allowDeprecatedModes", "control"]:
      check key notin echoed

  test "defaults are the design's":
    let config = defaultGameConfig()
    check config.season2Shell
    check not config.allowDeprecatedModes
    check config.viewIntervalTicks == ViewIntervalTicksDefault
    check config.lobbyChatTicks == LobbyChatTicksDefault
    check config.playSeatBindTicks == PlaySeatBindTicksDefault

  test "play-seat config parses, validates, and echoes non-default keys":
    var config = defaultGameConfig()
    config.update($ %*{
      "season2Shell": true, "viewIntervalTicks": 12, "lobbyChatTicks": 480,
      "playSeatBindTicks": 9600, "closedRoster": true, "minPlayers": 2,
      "players": [{"name": "alpha"}, {"name": "beta"}],
      "tokens": ["t-alpha", "t-beta"],
      "slots": [
        {"team": "red", "control": "play"},
        {"team": "blue"}
      ]
    })
    check config.season2Shell
    check config.viewIntervalTicks == 12
    check config.lobbyChatTicks == 480
    check config.playSeatBindTicks == 9600
    check config.slots.len == 2
    check config.slots[0].control == scPlay
    check config.slots[1].control == scInput
    let echoed = config.configJson()
    let node = parseJson(echoed)
    check not node.hasKey("season2Shell")
    check not node.hasKey("allowDeprecatedModes")
    check node["viewIntervalTicks"].getInt() == 12
    check node["lobbyChatTicks"].getInt() == 480
    check node["playSeatBindTicks"].getInt() == 9600
    check node["slots"][0]["control"].getStr() == "play"
    check not node["slots"][1].hasKey("control")
    # Round trip: the echoed header re-parses to the same shell contract,
    # which is what makes the replay header the provenance.
    var reparsed = defaultGameConfig()
    reparsed.update(echoed)
    check reparsed.season2Shell
    check reparsed.viewIntervalTicks == 12
    check reparsed.slots[0].control == scPlay

  test "gate-on with an all-input roster is legal (the house rule's shape)":
    var config = defaultGameConfig()
    config.update($ %*{"season2Shell": true})
    check config.season2Shell

  test "a play slot under gate-off is playSeatRequiresShell":
    var config = defaultGameConfig()
    expect CtfError:
      config.update($ %*{
        "season2Shell": false,
        "minPlayers": 2, "closedRoster": true,
        "players": [{"name": "alpha"}, {"name": "beta"}],
        "tokens": ["t-alpha", "t-beta"],
        "slots": [{"team": "red", "control": "play"}, {"team": "blue"}]
      })

  test "an unknown control kind is rejected by name":
    var config = defaultGameConfig()
    expect CtfError:
      config.update($ %*{"slots": [{"control": "psychic"}]})

  test "viewIntervalTicks bounds: 1 and 48 pass, 0 and 49 reject":
    for (value, legal) in [(1, true), (48, true), (0, false), (49, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"viewIntervalTicks": value})
        check config.viewIntervalTicks == value
      else:
        expect CtfError:
          config.update($ %*{"viewIntervalTicks": value})

  test "lobbyChatTicks bounds: 0 and 4320 pass, 4321 rejects":
    for (value, legal) in [(0, true), (720, true), (4320, true),
                           (4321, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"lobbyChatTicks": value})
        check config.lobbyChatTicks == value
      else:
        expect CtfError:
          config.update($ %*{"lobbyChatTicks": value})

  test "playSeatBindTicks: 0 is inert without a play seat, rejected with":
    var inert = defaultGameConfig()
    inert.update($ %*{"playSeatBindTicks": 0})
    check inert.playSeatBindTicks == 0
    var withSeat = defaultGameConfig()
    expect CtfError:
      withSeat.update($ %*{
        "season2Shell": true, "playSeatBindTicks": 0,
        "minPlayers": 2, "closedRoster": true,
        "players": [{"name": "alpha"}, {"name": "beta"}],
        "tokens": ["t-alpha", "t-beta"],
        "slots": [{"team": "red", "control": "play"}, {"team": "blue"}]
      })

  test "playSeatBindTicks bounds: 1 and 14400 pass, 14401 rejects":
    for (value, legal) in [(1, true), (7200, true), (14400, true),
                           (14401, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"playSeatBindTicks": value})
        check config.playSeatBindTicks == value
      else:
        expect CtfError:
          config.update($ %*{"playSeatBindTicks": value})

  test "non-default shell fields echo even when season2Shell is implicit":
    ## The sprayDamage rule: an authored departure is pinned in the header
    ## so the replay identifies its config, while pure defaults stay silent.
    var config = defaultGameConfig()
    config.update($ %*{"lobbyChatTicks": 0})
    let echoed = config.configJson()
    check "lobbyChatTicks" in echoed
    check "season2Shell" notin echoed

  test "explicit season2Shell off and deprecated-mode override echo":
    block:
      var config = defaultGameConfig()
      config.update($ %*{"season2Shell": false})
      let node = parseJson(config.configJson())
      check node["season2Shell"].getBool() == false
      check not node.hasKey("allowDeprecatedModes")
    block:
      var config = defaultGameConfig()
      config.update($ %*{"allowDeprecatedModes": true})
      let node = parseJson(config.configJson())
      check not node.hasKey("season2Shell")
      check node["allowDeprecatedModes"].getBool()
