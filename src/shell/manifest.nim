## Canonical, tree-local validation of the upload manifest and ParamSpec.
## Parsing is performed exclusively by `CanonicalReader`; no std/json parser
## participates in the content-validation path.

import std/[math, sets, strutils, unicode]

import canonical_fast, types

type
  ManifestError* = object of CatchableError

  ManifestClass* = enum
    mcController, mcOverlay

  ValueKind = enum
    vkNull, vkBool, vkInt, vkFloat, vkString, vkArray, vkObject

  Value = ref object
    case kind: ValueKind
    of vkNull: discard
    of vkBool: boolean: bool
    of vkInt: integer: int64
    of vkFloat: floating: float
    of vkString: text: string
    of vkArray: elements: seq[Value]
    of vkObject: members: seq[tuple[name: string, value: Value]]

  ParamSpec* = ref object
    kind*: string
    bytes*: string

  ManifestParam* = object
    name*: string
    spec*: ParamSpec

  PlayManifest* = object
    abi*: int
    name*: string
    playClass*: ManifestClass
    doc*: string
    modes*: seq[string]
    retune*: bool
    params*: seq[ManifestParam]

proc invalid(detail: string) {.noreturn.} =
  raise newException(ManifestError, detail)

proc parseValue(r: var CanonicalReader): Value =
  case r.peekKind()
  of cvNull:
    r.readNull(); result = Value(kind: vkNull)
  of cvBool: result = Value(kind: vkBool, boolean: r.readBool())
  of cvInt: result = Value(kind: vkInt, integer: r.readInt())
  of cvFloat: result = Value(kind: vkFloat, floating: r.readFloat())
  of cvString: result = Value(kind: vkString, text: r.readString())
  of cvArray:
    result = Value(kind: vkArray)
    r.enterArray()
    while r.nextElement():
      result.elements.add r.parseValue()
  of cvObject:
    result = Value(kind: vkObject)
    r.enterObject()
    var key: string
    while r.nextKey(key):
      result.members.add (key, r.parseValue())

proc member(value: Value; name: string): Value =
  if value != nil and value.kind == vkObject:
    for entry in value.members:
      if entry.name == name:
        return entry.value

proc has(value: Value; name: string): bool = value.member(name) != nil

proc requireKind(value: Value; kind: ValueKind; path: string) =
  if value == nil or value.kind != kind:
    invalid(path & " has the wrong value kind")

proc stringValue(value: Value; path: string): string =
  value.requireKind(vkString, path)
  value.text

proc boolValue(value: Value; path: string): bool =
  value.requireKind(vkBool, path)
  value.boolean

proc intValue(value: Value; path: string): int64 =
  value.requireKind(vkInt, path)
  value.integer

proc numberValue(value: Value; path: string): float =
  if value == nil or value.kind notin {vkInt, vkFloat}:
    invalid(path & " must be a number")
  result = if value.kind == vkInt: value.integer.float else: value.floating
  if result.classify in {fcNan, fcInf, fcNegInf}:
    invalid(path & " must be finite")

proc validIdentifier(value: string; lowerFirst: bool): bool =
  if value.len == 0 or value.len > 32:
    return false
  if lowerFirst:
    if value[0] notin {'a' .. 'z'}: return false
  elif value[0] notin {'a' .. 'z', 'A' .. 'Z'}:
    return false
  for c in value.toOpenArray(1, value.high):
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      return false
  true

proc encodeValue(value: Value; w: var CanonicalWriter) =
  case value.kind
  of vkNull: w.addNull()
  of vkBool: w.addBool(value.boolean)
  of vkInt: w.addInt(value.integer)
  of vkFloat: w.addFloat(value.floating)
  of vkString: w.addString(value.text)
  of vkArray:
    w.beginArray()
    for element in value.elements: encodeValue(element, w)
    w.endArray()
  of vkObject:
    w.beginObject()
    for entry in value.members:
      w.key(entry.name); encodeValue(entry.value, w)
    w.endObject()

proc valueBytes(value: Value): string =
  var writer = initCanonicalWriter()
  encodeValue(value, writer)
  writer.take()

proc validateDefault(spec: Value; value: Value; path: string; depth: int)

proc validateSpec(spec: Value; path: string; depth: int): ParamSpec =
  spec.requireKind(vkObject, path)
  if depth > ParamNestingMax:
    invalid(path & " exceeds ParamNestingMax")
  const allFields = ["arms", "default", "integer", "items", "kind", "max",
    "max_items", "min", "min_items", "of", "required"]
  let allowedAll = allFields.toHashSet
  for entry in spec.members:
    if entry.name notin allowedAll:
      invalid(path & " has unknown field " & entry.name)
  let kind = spec.member("kind").stringValue(path & ".kind")
  if kind notin ["number", "bool", "enum", "point", "team_list", "set",
      "list", "seat_or_duo_ref", "tuple", "union", "condition"]:
    invalid(path & ".kind is unknown")
  new(result)
  result.kind = kind
  result.bytes = valueBytes(spec)

  var permitted = ["kind", "default", "required"].toHashSet
  case kind
  of "number":
    for field in ["integer", "min", "max"]: permitted.incl(field)
    if spec.has("integer"): discard spec.member("integer").boolValue(path & ".integer")
    var low = -Inf
    var high = Inf
    if spec.has("min"): low = spec.member("min").numberValue(path & ".min")
    if spec.has("max"): high = spec.member("max").numberValue(path & ".max")
    if low > high: invalid(path & " has min greater than max")
  of "enum":
    permitted.incl("of")
    let choices = spec.member("of")
    choices.requireKind(vkArray, path & ".of")
    if choices.elements.len > ParamListMax:
      invalid(path & ".of exceeds ParamListMax")
    var previous = ""
    for i, choice in choices.elements:
      let item = choice.stringValue(path & ".of[" & $i & "]")
      if item.len > ParamStringMaxBytes or validateUtf8(item) != -1:
        invalid(path & ".of contains an invalid string")
      if i > 0 and item <= previous:
        invalid(path & ".of must be sorted and deduplicated")
      previous = item
  of "set", "list":
    for field in ["of", "min_items", "max_items"]: permitted.incl(field)
    let elementSpec = spec.member("of")
    if elementSpec == nil:
      invalid(path & ".of is required")
    if elementSpec.kind == vkString:
      if elementSpec.text notin ["number", "bool", "enum", "point",
          "team_list", "seat_or_duo_ref"]:
        invalid(path & ".of names an unsupported scalar kind")
    else:
      discard validateSpec(elementSpec, path & ".of", depth + 1)
    let minimum = if spec.has("min_items"):
      spec.member("min_items").intValue(path & ".min_items") else: 0
    let maximum = if spec.has("max_items"):
      spec.member("max_items").intValue(path & ".max_items") else: ParamListMax
    if minimum < 0 or maximum < 1 or maximum > ParamListMax or minimum > maximum:
      invalid(path & " has invalid list bounds")
  of "tuple":
    permitted.incl("items")
    let items = spec.member("items")
    items.requireKind(vkArray, path & ".items")
    if items.elements.len notin 2 .. 4:
      invalid(path & ".items must contain 2 through 4 specs")
    for i, item in items.elements:
      discard validateSpec(item, path & ".items[" & $i & "]", depth + 1)
  of "union":
    permitted.incl("arms")
    let arms = spec.member("arms")
    arms.requireKind(vkObject, path & ".arms")
    if arms.members.len == 0 or arms.members.len > 8:
      invalid(path & ".arms must contain 1 through 8 specs")
    for arm in arms.members:
      if not validIdentifier(arm.name, false):
        invalid(path & ".arms has an invalid name")
      discard validateSpec(arm.value, path & ".arms." & arm.name, depth + 1)
  else:
    discard
  for entry in spec.members:
    if entry.name notin permitted:
      invalid(path & "." & entry.name & " is invalid for kind " & kind)
  if spec.has("required"):
    let required = spec.member("required").boolValue(path & ".required")
    if required and spec.has("default"):
      invalid(path & " cannot be required and have a default")
  if spec.has("default"):
    validateDefault(spec, spec.member("default"), path & ".default", depth)

proc scalarSpec(value: Value; path: string): Value =
  if value.kind == vkObject: return value
  value.requireKind(vkString, path)
  Value(kind: vkObject, members: @[("kind", value)])

proc validateDefault(spec: Value; value: Value; path: string; depth: int) =
  let kind = spec.member("kind").text
  case kind
  of "number":
    let number = value.numberValue(path)
    if spec.has("integer") and spec.member("integer").boolean and
        value.kind != vkInt:
      invalid(path & " must be integral")
    if spec.has("min") and number < spec.member("min").numberValue(path):
      invalid(path & " is below min")
    if spec.has("max") and number > spec.member("max").numberValue(path):
      invalid(path & " is above max")
  of "bool": value.requireKind(vkBool, path)
  of "enum":
    let text = value.stringValue(path)
    var found = false
    for choice in spec.member("of").elements:
      if choice.text == text: found = true
    if not found: invalid(path & " is outside the enum")
  of "point":
    value.requireKind(vkArray, path)
    if value.elements.len != 2 or value.elements[0].kind != vkInt or
        value.elements[1].kind != vkInt:
      invalid(path & " must be two integers")
  of "team_list":
    value.requireKind(vkArray, path)
    if value.elements.len > ParamListMax: invalid(path & " is too long")
    var previous = ""
    for i, element in value.elements:
      let item = element.stringValue(path)
      if i > 0 and item <= previous: invalid(path & " must be sorted and unique")
      previous = item
  of "seat_or_duo_ref":
    let text = value.stringValue(path)
    if not ((text.startsWith("seat:") or text.startsWith("duo:")) and
        text.find(':') < text.high):
      invalid(path & " must be a prefix-tagged roster reference")
  of "set", "list":
    value.requireKind(vkArray, path)
    let minimum = if spec.has("min_items"): spec.member("min_items").integer else: 0
    let maximum = if spec.has("max_items"): spec.member("max_items").integer else: ParamListMax
    if value.elements.len < minimum or value.elements.len > maximum:
      invalid(path & " violates list bounds")
    let child = scalarSpec(spec.member("of"), path & ".of")
    var previous = ""
    var seen: HashSet[string]
    for i, element in value.elements:
      validateDefault(child, element, path & "[" & $i & "]", depth + 1)
      let encoded = valueBytes(element)
      if encoded in seen: invalid(path & " contains a duplicate")
      seen.incl encoded
      if kind == "set" and i > 0 and encoded <= previous:
        invalid(path & " set is not sorted")
      previous = encoded
  of "tuple":
    value.requireKind(vkArray, path)
    if value.elements.len != spec.member("items").elements.len:
      invalid(path & " has the wrong tuple arity")
    for i, element in value.elements:
      validateDefault(spec.member("items").elements[i], element,
        path & "[" & $i & "]", depth + 1)
  of "union":
    value.requireKind(vkObject, path)
    if value.members.len != 1: invalid(path & " must select exactly one arm")
    let armSpec = spec.member("arms").member(value.members[0].name)
    if armSpec == nil: invalid(path & " selects an unknown arm")
    validateDefault(armSpec, value.members[0].value,
      path & "." & value.members[0].name, depth + 1)
  of "condition":
    # Full operator/path validation belongs to call validation, which has the
    # mode's registered paths. The manifest gate still enforces generic caps.
    var nodes = 0
    proc walk(item: Value; level: int) =
      inc nodes
      if nodes > GuardNodeMax or level > GuardDepthMax:
        invalid(path & " exceeds condition caps")
      if item.kind == vkArray:
        for child in item.elements: walk(child, level + 1)
      elif item.kind == vkObject:
        for child in item.members: walk(child.value, level + 1)
    walk(value, 1)
  else: invalid(path & " has an unsupported kind")

proc parseManifest*(bytes: sink string; hasRetune: bool): PlayManifest =
  var reader = initCanonicalReader(move(bytes))
  let root = reader.parseValue()
  reader.finish()
  root.requireKind(vkObject, "manifest")
  let allowed = ["abi", "class", "doc", "modes", "name", "params",
    "retune"].toHashSet
  for entry in root.members:
    if entry.name notin allowed:
      invalid("manifest has unknown field " & entry.name)
  for required in ["abi", "class", "modes", "name", "params", "retune"]:
    if not root.has(required): invalid("manifest is missing " & required)
  result.abi = root.member("abi").intValue("manifest.abi").int
  if result.abi != ShellAbiVersion: invalid("manifest.abi is unsupported")
  result.name = root.member("name").stringValue("manifest.name")
  if not validIdentifier(result.name, true) or result.name == "default" or
      result.name.startsWith(ReflexNamePrefix):
    invalid("manifest.name is invalid or reserved")
  let className = root.member("class").stringValue("manifest.class")
  case className
  of "controller": result.playClass = mcController
  of "overlay": result.playClass = mcOverlay
  else: invalid("manifest.class is unknown")
  if root.has("doc"):
    result.doc = root.member("doc").stringValue("manifest.doc")
    if result.doc.len > ManifestDocMaxBytes or validateUtf8(result.doc) != -1:
      invalid("manifest.doc is not valid capped UTF-8")
  let modes = root.member("modes")
  modes.requireKind(vkArray, "manifest.modes")
  if modes.elements.len notin 1 .. 3: invalid("manifest.modes must be nonempty")
  var previous = ""
  for mode in modes.elements:
    let name = mode.stringValue("manifest.modes")
    if name notin ["br", "ctf", "koth"] or
        (previous.len > 0 and name <= previous):
      invalid("manifest.modes must be a sorted, deduplicated known subset")
    result.modes.add name
    previous = name
  result.retune = root.member("retune").boolValue("manifest.retune")
  if result.retune != hasRetune:
    invalid("manifest.retune does not match the play_retune export")
  let params = root.member("params")
  params.requireKind(vkObject, "manifest.params")
  if params.members.len > MaxParamsPerSchema:
    invalid("manifest.params exceeds MaxParamsPerSchema")
  for param in params.members:
    if not validIdentifier(param.name, false):
      invalid("manifest.params has an invalid parameter name")
    result.params.add ManifestParam(name: param.name,
      spec: validateSpec(param.value, "manifest.params." & param.name, 1))
