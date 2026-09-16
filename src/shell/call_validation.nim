## Total validation for canonical ladder-call bytes.
##
## This starts at lane B's decoded canonical ladder JSON bytes. It performs no
## packet decoding and applies the call atomically: any validation error rejects
## the whole document before a caller observes entries.

import std/[math, options, sets, strutils, unicode]

import ../ctf/policy_page
import ../ctf/sim_types
import body_map, canonical_fast, emit_validator, guards, manifest, types

type
  CallValidationError* = object of CatchableError
    reason*: string
    path*: string

  JsonKind = enum
    jkNull, jkBool, jkInt, jkFloat, jkString, jkArray, jkObject

  JsonValue = ref object
    case kind: JsonKind
    of jkNull: discard
    of jkBool: boolean: bool
    of jkInt: integer: int64
    of jkFloat: floating: float
    of jkString: text: string
    of jkArray: elements: seq[JsonValue]
    of jkObject: members: seq[tuple[name: string, value: JsonValue]]

  BoundPlay* = object
    manifest*: PlayManifest
    ready*: bool

  CallValidationContext* = object
    mode*: GameMode
    map*: BodyMap
    registry*: PathRegistry
    guardContext*: IntentContext
    duoSeats*: array[Team, DuoSeats]

  ValidatedCallEntry* = object
    entryId*: string
    play*: string
    paramsBytes*: string
    guardBytes*: string
    guardPassed*: bool
    retune*: bool
    playClass*: ManifestClass

  CallValidationResult* = object
    accepted*: bool
    reason*: string
    path*: string
    detail*: string
    canonicalBytes*: string
    entries*: seq[ValidatedCallEntry]
    activeOverlays*: seq[int]
    controllerIndex*: int

proc invalid(reason, path, detail: string) {.noreturn.} =
  var error = newException(CallValidationError, detail)
  error.reason = reason
  error.path = path
  raise error

proc parseValue(r: var CanonicalReader): JsonValue =
  case r.peekKind()
  of cvNull:
    r.readNull()
    result = JsonValue(kind: jkNull)
  of cvBool:
    result = JsonValue(kind: jkBool, boolean: r.readBool())
  of cvInt:
    result = JsonValue(kind: jkInt, integer: r.readInt())
  of cvFloat:
    result = JsonValue(kind: jkFloat, floating: r.readFloat())
  of cvString:
    result = JsonValue(kind: jkString, text: r.readString())
  of cvArray:
    result = JsonValue(kind: jkArray)
    r.enterArray()
    while r.nextElement():
      result.elements.add r.parseValue()
  of cvObject:
    result = JsonValue(kind: jkObject)
    r.enterObject()
    var key: string
    while r.nextKey(key):
      result.members.add (key, r.parseValue())

proc encodeValue(value: JsonValue; w: var CanonicalWriter) =
  case value.kind
  of jkNull: w.addNull()
  of jkBool: w.addBool(value.boolean)
  of jkInt: w.addInt(value.integer)
  of jkFloat: w.addFloat(value.floating)
  of jkString: w.addString(value.text)
  of jkArray:
    w.beginArray()
    for element in value.elements:
      encodeValue(element, w)
    w.endArray()
  of jkObject:
    w.beginObject()
    for member in value.members:
      w.key(member.name)
      encodeValue(member.value, w)
    w.endObject()

proc valueBytes(value: JsonValue): string =
  var writer = initCanonicalWriter()
  encodeValue(value, writer)
  writer.take()

proc member(value: JsonValue, name: string): JsonValue =
  if value != nil and value.kind == jkObject:
    for item in value.members:
      if item.name == name:
        return item.value

proc has(value: JsonValue, name: string): bool =
  value.member(name) != nil

proc requireKind(value: JsonValue, kind: JsonKind, path: string) =
  if value == nil or value.kind != kind:
    invalid("wrongKind", path, path & " has the wrong value kind")

proc stringValue(value: JsonValue, path: string): string =
  value.requireKind(jkString, path)
  result = value.text

proc boolValue(value: JsonValue, path: string): bool =
  value.requireKind(jkBool, path)
  result = value.boolean

proc intValue(value: JsonValue, path: string): int64 =
  value.requireKind(jkInt, path)
  result = value.integer

proc numberValue(value: JsonValue, path: string): float =
  if value == nil or value.kind notin {jkInt, jkFloat}:
    invalid("wrongKind", path, path & " must be a number")
  result = if value.kind == jkInt: value.integer.float else: value.floating
  if result.classify in {fcNan, fcInf, fcNegInf}:
    invalid("nonFinite", path, path & " must be finite")

proc parseRoot(bytes: string): JsonValue =
  var reader = initCanonicalReader(bytes)
  result = reader.parseValue()
  reader.finish()

proc modeName(mode: GameMode): string =
  case mode
  of gmCtf: "ctf"
  of gmKoth: "koth"
  of gmBr: "br"

proc teamName(team: Team): string {.inline.} =
  ($team).toLowerAscii

proc parseTeamRef(value, path: string): Team =
  for team in Team:
    if team.teamName == value:
      return team
  invalid("unknownReference", path, path & " names an unknown team")

proc validateSeatOrDuoRef(value, path: string,
                          ctx: CallValidationContext) =
  if value.startsWith("seat:"):
    let digits = value[5 .. ^1]
    if digits.len == 0:
      invalid("unknownReference", path, path & " names an unknown seat")
    var parsed = 0
    for ch in digits:
      if ch notin {'0' .. '9'}:
        invalid("unknownReference", path, path & " names an unknown seat")
      parsed = parsed * 10 + ord(ch) - ord('0')
      if parsed >= MaxPlayers:
        invalid("unknownReference", path, path & " names an unknown seat")
  elif value.startsWith("duo:"):
    if ctx.mode != gmBr:
      invalid("noDuosInMode", path, "noDuosInMode")
    let suffix = value[4 .. ^1]
    if suffix.len == 0:
      invalid("unknownReference", path, path & " names an unknown duo")
    let team = parseTeamRef(suffix, path)
    if not ctx.duoSeats[team].configured:
      invalid("unknownReference", path, path & " names an unconfigured duo")
  else:
    invalid("unknownReference", path, path & " must be a seat or duo reference")

proc specKind(spec: JsonValue, path: string): string =
  spec.requireKind(jkObject, path)
  let kindNode = spec.member("kind")
  if kindNode == nil:
    invalid("schemaInvalid", path & ".kind", path & ".kind is missing")
  kindNode.stringValue(path & ".kind")

proc scalarSpec(value: JsonValue, path: string): JsonValue =
  if value.kind == jkObject:
    return value
  value.requireKind(jkString, path)
  JsonValue(kind: jkObject, members: @[("kind", value)])

proc validateParamValue(spec, value: JsonValue, path: string,
                        ctx: CallValidationContext, depth: int)

proc validateSortedUnique(encoded: string, previous: var string,
                          seen: var HashSet[string], path: string,
                          requireSorted: bool) =
  if encoded in seen:
    invalid("duplicateValue", path, path & " contains a duplicate")
  seen.incl encoded
  if requireSorted and previous.len > 0 and encoded <= previous:
    invalid("notSorted", path, path & " set is not sorted")
  previous = encoded

proc validateParamValue(spec, value: JsonValue, path: string,
                        ctx: CallValidationContext, depth: int) =
  if depth > ParamNestingMax:
    invalid("tooDeep", path, path & " exceeds ParamNestingMax")
  let kind = spec.specKind(path & ".spec")
  case kind
  of "number":
    let number = value.numberValue(path)
    if spec.has("integer") and spec.member("integer").boolValue(
        path & ".spec.integer") and value.kind != jkInt:
      invalid("range", path, path & " must be integral")
    if spec.has("min") and number < spec.member("min").numberValue(
        path & ".spec.min"):
      invalid("range", path, path & " is below min")
    if spec.has("max") and number > spec.member("max").numberValue(
        path & ".spec.max"):
      invalid("range", path, path & " is above max")
  of "bool":
    value.requireKind(jkBool, path)
  of "enum":
    let text = value.stringValue(path)
    if text.len > ParamStringMaxBytes or validateUtf8(text) != -1:
      invalid("stringTooLong", path, path & " is not valid capped UTF-8")
    let choices = spec.member("of")
    choices.requireKind(jkArray, path & ".spec.of")
    var found = false
    for choice in choices.elements:
      if choice.stringValue(path & ".spec.of") == text:
        found = true
    if not found:
      invalid("range", path, path & " is outside the enum")
  of "point":
    value.requireKind(jkArray, path)
    if value.elements.len != 2:
      invalid("wrongKind", path, path & " must be two integers")
    let x = value.elements[0].intValue(path & "[0]")
    let y = value.elements[1].intValue(path & "[1]")
    if x < 0 or y < 0 or x > int64(high(int32)) or y > int64(high(int32)):
      invalid("range", path, path & " is outside int32 range")
    if ctx.map != nil and (x >= ctx.map.width or y >= ctx.map.height):
      invalid("range", path, path & " is outside the map")
  of "team_list":
    value.requireKind(jkArray, path)
    if value.elements.len > ParamListMax:
      invalid("tooLong", path, path & " exceeds ParamListMax")
    var previous = ""
    for i, element in value.elements:
      let item = element.stringValue(path & "[" & $i & "]")
      discard parseTeamRef(item, path & "[" & $i & "]")
      if i > 0 and item <= previous:
        invalid("notSorted", path, path & " must be sorted and unique")
      previous = item
  of "seat_or_duo_ref":
    let text = value.stringValue(path)
    if text.len > ParamStringMaxBytes or validateUtf8(text) != -1:
      invalid("stringTooLong", path, path & " is not valid capped UTF-8")
    validateSeatOrDuoRef(text, path, ctx)
  of "set", "list":
    value.requireKind(jkArray, path)
    let minimum = if spec.has("min_items"):
      spec.member("min_items").intValue(path & ".spec.min_items") else: 0
    let maximum = if spec.has("max_items"):
      spec.member("max_items").intValue(path & ".spec.max_items") else:
      ParamListMax
    if value.elements.len < minimum or value.elements.len > maximum:
      invalid("tooLong", path, path & " violates list bounds")
    let child = scalarSpec(spec.member("of"), path & ".spec.of")
    var previous = ""
    var seen: HashSet[string]
    for i, element in value.elements:
      validateParamValue(child, element, path & "[" & $i & "]", ctx,
        depth + 1)
      validateSortedUnique(valueBytes(element), previous, seen, path,
        kind == "set")
  of "tuple":
    value.requireKind(jkArray, path)
    let items = spec.member("items")
    items.requireKind(jkArray, path & ".spec.items")
    if value.elements.len != items.elements.len:
      invalid("wrongKind", path, path & " has the wrong tuple arity")
    for i, element in value.elements:
      validateParamValue(items.elements[i], element,
        path & "[" & $i & "]", ctx, depth + 1)
  of "union":
    value.requireKind(jkObject, path)
    if value.members.len != 1:
      invalid("wrongKind", path, path & " must select exactly one arm")
    let arms = spec.member("arms")
    arms.requireKind(jkObject, path & ".spec.arms")
    let armSpec = arms.member(value.members[0].name)
    if armSpec == nil:
      invalid("unknownField", path & "." & value.members[0].name,
        path & " selects an unknown arm")
    validateParamValue(armSpec, value.members[0].value,
      path & "." & value.members[0].name, ctx, depth + 1)
  of "condition":
    try:
      let guard = compileGuard(valueBytes(value), ctx.registry)
      discard guard.evaluate(ctx.guardContext)
    except GuardError as error:
      invalid("guardInvalid", path, error.msg)
  else:
    invalid("schemaInvalid", path & ".spec.kind", path & ".spec.kind is unknown")

proc findParam(params: openArray[ManifestParam], name: string): Option[ManifestParam] =
  for param in params:
    if param.name == name:
      return some(param)

proc specRequires(spec: JsonValue, path: string): bool =
  if spec.has("required"):
    spec.member("required").boolValue(path & ".required")
  else:
    false

proc validateParams(params: JsonValue, manifest: PlayManifest, path: string,
                    ctx: CallValidationContext): string =
  let paramsObject =
    if params == nil:
      JsonValue(kind: jkObject)
    else:
      params
  paramsObject.requireKind(jkObject, path)
  for entry in paramsObject.members:
    let param = findParam(manifest.params, entry.name)
    if param.isNone:
      invalid("unknownField", path & "." & entry.name,
        path & "." & entry.name & " is not declared by " & manifest.name)
    let spec = parseRoot(param.get.spec.bytes)
    validateParamValue(spec, entry.value, path & "." & entry.name, ctx, 1)
  for param in manifest.params:
    if not paramsObject.has(param.name):
      let spec = parseRoot(param.spec.bytes)
      if spec.specRequires("manifest.params." & param.name):
        invalid("missingParam", path & "." & param.name,
          path & "." & param.name & " is required")
  valueBytes(paramsObject)

proc manifestFor(bindings: openArray[BoundPlay], name: string): Option[BoundPlay] =
  for binding in bindings:
    if binding.manifest.name == name:
      return some(binding)

proc validEntryId(value: string): bool =
  if value.len == 0 or value.len > 64 or validateUtf8(value) != -1:
    return false
  for ch in value:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', ':', '.', '#'}:
      return false
  true

proc validateCall*(bytes: sink string, bindings: openArray[BoundPlay],
                   ctx: CallValidationContext): CallValidationResult =
  result.controllerIndex = -1
  if bytes.len > MaxCallBytes:
    return CallValidationResult(accepted: false, reason: "callTooLarge",
      path: "call", detail: "call exceeds MaxCallBytes",
      controllerIndex: -1)
  let original = bytes
  try:
    let root = parseRoot(original)
    root.requireKind(jkObject, "call")
    for entry in root.members:
      if entry.name != "plays":
        invalid("unknownField", "call." & entry.name,
          "call has unknown field " & entry.name)
    let plays = root.member("plays")
    if plays == nil:
      invalid("missingField", "call.plays", "call.plays is required")
    plays.requireKind(jkArray, "call.plays")
    if plays.elements.len == 0 or plays.elements.len > MaxLadderEntries:
      invalid("tooManyEntries", "call.plays",
        "call.plays violates MaxLadderEntries")

    var
      entries: seq[ValidatedCallEntry]
      activeOverlays: seq[int]
      seenIds: HashSet[string]

    for index, entryValue in plays.elements:
      let entryPath = "call.plays[" & $index & "]"
      entryValue.requireKind(jkObject, entryPath)
      for member in entryValue.members:
        if member.name notin ["entry_id", "params", "play", "retune", "when"]:
          invalid("unknownField", entryPath & "." & member.name,
            entryPath & " has unknown field " & member.name)
      let playNode = entryValue.member("play")
      if playNode == nil:
        invalid("missingField", entryPath & ".play",
          entryPath & ".play is required")
      let playName = playNode.stringValue(entryPath & ".play")
      let binding = manifestFor(bindings, playName)
      if binding.isNone:
        invalid("playUnknown", entryPath & ".play",
          entryPath & ".play is not bound")
      if not binding.get.ready:
        invalid("playNotReady", entryPath & ".play",
          entryPath & ".play is not ready")
      let playManifest = binding.get.manifest
      if ctx.mode.modeName notin playManifest.modes:
        invalid("modeExcluded", entryPath & ".play",
          playName & " excludes mode " & ctx.mode.modeName)

      let entryId =
        if entryValue.has("entry_id"):
          entryValue.member("entry_id").stringValue(entryPath & ".entry_id")
        else:
          playName & "#" & $index
      if not validEntryId(entryId):
        invalid("invalidEntryId", entryPath & ".entry_id",
          entryPath & ".entry_id is invalid")
      if entryId in seenIds:
        invalid("duplicateEntryId", entryPath & ".entry_id",
          entryPath & ".entry_id duplicates an earlier entry")
      seenIds.incl entryId

      let retune =
        if entryValue.has("retune"):
          entryValue.member("retune").boolValue(entryPath & ".retune")
        else:
          false
      let guardBytes =
        if entryValue.has("when"):
          valueBytes(entryValue.member("when"))
        else:
          ""
      let guardPassed =
        if guardBytes.len == 0:
          true
        else:
          try:
            compileGuard(guardBytes, ctx.registry).evaluate(ctx.guardContext)
          except GuardError as error:
            invalid("guardInvalid", entryPath & ".when", error.msg)

      let paramsBytes = validateParams(entryValue.member("params"),
        playManifest, entryPath & ".params", ctx)
      let playClass = playManifest.playClass
      if playClass == mcOverlay and guardPassed:
        if activeOverlays.len >= MaxActiveOverlays:
          invalid("tooManyOverlays", entryPath,
            "call exceeds MaxActiveOverlays")
        activeOverlays.add index
      entries.add ValidatedCallEntry(entryId: entryId, play: playName,
        paramsBytes: paramsBytes, guardBytes: guardBytes,
        guardPassed: guardPassed, retune: retune, playClass: playClass)
      if guardPassed:
        if playClass != mcOverlay and result.controllerIndex < 0:
          result.controllerIndex = index

    result.accepted = true
    result.canonicalBytes = original
    result.entries = move(entries)
    result.activeOverlays = move(activeOverlays)
  except CallValidationError as error:
    result = CallValidationResult(accepted: false, reason: error.reason,
      path: error.path, detail: error.msg, controllerIndex: -1)
  except CanonicalError as error:
    result = CallValidationResult(accepted: false, reason: "nonCanonical",
      path: "call", detail: error.msg, controllerIndex: -1)
