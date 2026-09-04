## Shared implementation behind tools/play_harness.
##
## This module intentionally routes through the production runtime,
## validation, and instance invocation code. The CLI is only argument parsing
## and printing; it does not get a private validation or ABI mode.

import std/[json, options, os, strutils]

import ../ctf/[arena, sim_types]
import abi, binary_view, body_map, canonical, canonical_fast, emit_validator,
  instance, manifest, module_validation, runtime, types, view

type
  HarnessError* = object of CatchableError

  HarnessFrameKind* = enum
    hfManifest
    hfInit
    hfStep
    hfRetune

  HarnessFrame* = object
    kind*: HarnessFrameKind
    paramsBytes*: string
    contextBytes*: string
    viewBytes*: string
    oldParamsBytes*: string
    newParamsBytes*: string
    tick*: uint32

  HarnessCase* = object
    modulePath*: string
    mapSpecPath*: string
    selfPos*: BodyPoint
    emitClass*: EmitClass
    mode*: GameMode
    duoSeats*: array[Team, DuoSeats]
    frames*: seq[HarnessFrame]

  HarnessLogTrace* = object
    level*: int32
    bytesHex*: string

  HarnessFrameTrace* = object
    op*: string
    returned*: int32
    refused*: bool
    faulted*: bool
    reason*: string
    code*: FaultCode           ## written only on a faulted or refused frame
    counters*: AbiCounters
    emitCodes*: seq[int32]
    logs*: seq[HarnessLogTrace]
    manifestBytes*: string
    lastAcceptedBytes*: string
    fuelRemaining*: uint64
    fuelInstalledBeforeAlloc*: bool

  HarnessTrace* = object
    accepted*: bool
    reason*: string
    detail*: string
    sha256*: string
    manifestName*: string
    frames*: seq[HarnessFrameTrace]

proc harnessInvalid(message: string) {.noreturn.} =
  raise newException(HarnessError, message)

proc parseFrameKind(text: string): HarnessFrameKind =
  case text
  of "manifest": hfManifest
  of "init": hfInit
  of "step": hfStep
  of "retune": hfRetune
  else: harnessInvalid("unknown harness frame op " & text)

proc wireName(kind: HarnessFrameKind): string =
  case kind
  of hfManifest: "manifest"
  of hfInit: "init"
  of hfStep: "step"
  of hfRetune: "retune"

proc payloadBytes(node: JsonNode; field, fallback: string): string =
  if not node.hasKey(field):
    return fallback
  let value = node[field]
  if value.kind == JString:
    value.getStr()
  else:
    canonicalJson(value)

proc rectFromNode(node: JsonNode): PlayRect =
  if node.kind != JArray or node.len != 4:
    harnessInvalid("view zone rect must be [x,y,w,h]")
  PlayRect(x: node[0].getInt(), y: node[1].getInt(),
    w: node[2].getInt(), h: node[3].getInt())

proc binaryViewBytes(node: JsonNode; tick: uint32; mode: GameMode;
                     selfPos: BodyPoint): string =
  if node.kind == JString:
    return node.getStr()
  if node.kind != JObject:
    return canonicalJson(node)
  var source = PlayViewSource(
    tick: if node.hasKey("tick"): uint32(node["tick"].getInt()) else: tick,
    mode: mode,
    self: PlaySelf(pos: selfPos, hp: 1, hpFrac: 1.0, aimBrads: 0,
      alive: true),
    aliveTeams: 2)
  if node.hasKey("self") and node["self"].kind == JObject:
    let self = node["self"]
    if self.hasKey("pos") and self["pos"].kind == JArray and
        self["pos"].len == 2:
      source.self.pos = (self["pos"][0].getInt(), self["pos"][1].getInt())
    if self.hasKey("hp"):
      source.self.hp = self["hp"].getInt()
    if self.hasKey("hp_frac"):
      source.self.hpFrac = self["hp_frac"].getFloat()
    if self.hasKey("aim_brads"):
      source.self.aimBrads = self["aim_brads"].getInt()
    if self.hasKey("alive"):
      source.self.alive = self["alive"].getBool()
  if node.hasKey("world") and node["world"].kind == JObject:
    let world = node["world"]
    if world.hasKey("alive_teams"):
      source.aliveTeams = world["alive_teams"].getInt()
    if world.hasKey("zone") and world["zone"].kind == JObject:
      let zone = world["zone"]
      var playZone = PlayZone()
      if zone.hasKey("phase"):
        playZone.phase = zone["phase"].getInt()
      if zone.hasKey("current"):
        playZone.current = rectFromNode(zone["current"])
      else:
        playZone.current = PlayRect(x: 0, y: 0, w: 720, h: 96)
      if zone.hasKey("next"):
        playZone.next = some(rectFromNode(zone["next"]))
      if zone.hasKey("ticks_to_shrink"):
        playZone.ticksToShrink = zone["ticks_to_shrink"].getInt()
      if zone.hasKey("dps"):
        playZone.dps = zone["dps"].getInt()
      source.zone = some(playZone)
  buildBinaryPlayView(source)

proc parsePoint(node: JsonNode; field: string; fallback: BodyPoint): BodyPoint =
  if not node.hasKey(field):
    return fallback
  let point = node[field]
  if point.kind != JArray or point.len != 2:
    harnessInvalid(field & " must be a two-element point")
  (point[0].getInt(), point[1].getInt())

proc parseEmitClass(text: string): EmitClass =
  case text
  of "controller": ecController
  of "overlay": ecOverlay
  else: harnessInvalid("emit_class must be controller or overlay")

proc emitClassName(value: EmitClass): string =
  case value
  of ecController: "controller"
  of ecOverlay: "overlay"

proc emitClassOf(value: ManifestClass): EmitClass =
  case value
  of mcController: ecController
  of mcOverlay: ecOverlay

proc parseMode(text: string): GameMode =
  case text
  of "ctf": gmCtf
  of "koth": gmKoth
  of "br": gmBr
  else: harnessInvalid("mode must be ctf, koth, or br")

proc parseTeam(text: string): Team =
  for team in Team:
    if ($team).toLowerAscii == text:
      return team
  harnessInvalid("unknown team in duo_seats: " & text)

proc parseSeat(node: JsonNode; field: string): SeatRef =
  let value = node.getInt()
  if value < 0 or value >= MaxPlayers:
    harnessInvalid(field & " must be a valid seat")
  SeatRef(uint8(value))

proc resolveRelative(path, baseDir: string): string =
  if path.len == 0 or path.isAbsolute:
    return path
  let fromCase = baseDir / path
  if baseDir.len > 0 and fileExists(fromCase):
    fromCase
  else:
    path

proc parseHarnessCase*(bytes: string; baseDir = ""): HarnessCase =
  let root = parseJson(bytes)
  if root.kind != JObject:
    harnessInvalid("harness case must be an object")
  if not root.hasKey("module"):
    harnessInvalid("harness case requires module")
  result.modulePath = resolveRelative(root["module"].getStr(), baseDir)
  result.mapSpecPath =
    if root.hasKey("map_spec"):
      resolveRelative(root["map_spec"].getStr(), baseDir)
    else:
      ""
  result.selfPos = root.parsePoint("self", (30, 30))
  result.emitClass =
    if root.hasKey("emit_class"): parseEmitClass(root["emit_class"].getStr())
    else: ecController
  result.mode =
    if root.hasKey("mode"): parseMode(root["mode"].getStr())
    else: gmCtf
  if root.hasKey("duo_seats"):
    let duos = root["duo_seats"]
    if duos.kind != JObject:
      harnessInvalid("duo_seats must be an object")
    for teamName, seats in duos:
      if seats.kind != JArray or seats.len != 2:
        harnessInvalid("duo_seats." & teamName & " must hold two seats")
      let team = parseTeam(teamName)
      result.duoSeats[team] = DuoSeats(configured: true,
        seats: [seats[0].parseSeat("duo_seats." & teamName & "[0]"),
          seats[1].parseSeat("duo_seats." & teamName & "[1]")])
  if not root.hasKey("frames") or root["frames"].kind != JArray:
    harnessInvalid("harness case requires frames array")
  for frameNode in root["frames"]:
    if frameNode.kind != JObject or not frameNode.hasKey("op"):
      harnessInvalid("each frame requires op")
    let kind = parseFrameKind(frameNode["op"].getStr())
    let tick = if frameNode.hasKey("tick"): frameNode["tick"].getInt().uint32
      else: 0'u32
    var frame = HarnessFrame(kind: kind,
      paramsBytes: frameNode.payloadBytes("params", "{}"),
      contextBytes: frameNode.payloadBytes("context", "{}"),
      viewBytes: if frameNode.hasKey("view"):
        binaryViewBytes(frameNode["view"], tick, result.mode, result.selfPos)
        else: "{}",
      oldParamsBytes: frameNode.payloadBytes("old_params", "{}"),
      newParamsBytes: frameNode.payloadBytes("new_params", "{}"),
      tick: tick)
    result.frames.add(frame)

proc openRoomsMap(): BodyMap =
  const
    Width = 720
    Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc mapFor(caseData: HarnessCase): BodyMap =
  if caseData.mapSpecPath.len > 0:
    newBodyMap(mapFromSpecJson(readFile(caseData.mapSpecPath)))
  else:
    openRoomsMap()

proc readModuleBytes(path: string): seq[byte] =
  let bytes = readFile(path)
  result = newSeq[byte](bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc toTrace(kind: HarnessFrameKind; invocationResult: ShellInvocationResult):
    HarnessFrameTrace =
  result = HarnessFrameTrace(
    op: kind.wireName,
    returned: invocationResult.returned,
    refused: invocationResult.refused,
    faulted: invocationResult.faulted,
    reason: invocationResult.reason,
    code: invocationResult.code,
    counters: invocationResult.counters,
    emitCodes: invocationResult.emitCodes,
    manifestBytes: invocationResult.manifestBytes,
    lastAcceptedBytes:
      if invocationResult.lastAccepted.isSome:
        invocationResult.lastAccepted.get.bytes
      else:
        "",
    fuelRemaining: invocationResult.fuelRemaining,
    fuelInstalledBeforeAlloc: invocationResult.fuelInstalledBeforeAlloc)
  for log in invocationResult.logs:
    result.logs.add HarnessLogTrace(
      level: log.level, bytesHex: log.bytes.toHex.toLowerAscii)

proc runHarnessCase*(caseData: HarnessCase): HarnessTrace =
  let moduleBytes = readModuleBytes(caseData.modulePath)
  let engine = newRuntimeEngine()
  defer: engine.close()
  var validation = engine.validateUploadedModule(moduleBytes)
  defer: validation.close()
  result.accepted = validation.accepted
  result.reason = validation.reason
  result.detail = validation.detail
  result.sha256 = validation.sha256
  if not validation.accepted:
    return
  result.manifestName = validation.manifest.name

  let manifestClass = emitClassOf(validation.manifest.playClass)
  if caseData.emitClass != manifestClass:
    harnessInvalid("emit_class " & caseData.emitClass.emitClassName &
      " disagrees with manifest class " & manifestClass.emitClassName)

  let map = caseData.mapFor()
  var shell = newShellInstance(validation.module, map, caseData.selfPos,
    caseData.emitClass, caseData.mode, caseData.duoSeats)
  defer: shell.close()

  for frame in caseData.frames:
    let invocation =
      case frame.kind
      of hfManifest:
        shell.invokeManifest()
      of hfInit:
        shell.invokeInit(frame.paramsBytes, frame.contextBytes)
      of hfStep:
        shell.invokeStep(frame.viewBytes, frame.tick, caseData.selfPos)
      of hfRetune:
        shell.invokeRetune(frame.oldParamsBytes, frame.newParamsBytes)
    result.frames.add(frame.kind.toTrace(invocation))
    if invocation.faulted or invocation.refused:
      break

proc encodeFrameTrace(frame: HarnessFrameTrace; w: var CanonicalWriter) =
  w.beginObject()
  if frame.faulted or frame.refused:
    w.field("code", $frame.code)
  w.key("counters")
  w.beginObject()
  w.field("allocations", int64(frame.counters.allocations))
  w.field("emits", int64(frame.counters.emits))
  w.field("logs", int64(frame.counters.logs))
  w.field("spatial_calls", int64(frame.counters.spatialCalls))
  w.endObject()
  w.key("emit_codes")
  w.beginArray()
  for code in frame.emitCodes:
    w.addInt(int64(code))
  w.endArray()
  w.field("faulted", frame.faulted)
  w.field("fuel_installed_before_alloc", frame.fuelInstalledBeforeAlloc)
  w.fieldUint64("fuel_remaining", frame.fuelRemaining)
  w.field("last_accepted", frame.lastAcceptedBytes)
  w.key("logs")
  w.beginArray()
  for log in frame.logs:
    w.beginObject()
    w.field("bytes_hex", log.bytesHex)
    w.field("level", int64(log.level))
    w.endObject()
  w.endArray()
  w.field("manifest_bytes", frame.manifestBytes)
  w.field("op", frame.op)
  w.field("reason", frame.reason)
  w.field("refused", frame.refused)
  w.field("returned", int64(frame.returned))
  w.endObject()

proc encodeHarnessTrace*(trace: HarnessTrace): string =
  var w = initCanonicalWriter(1024)
  w.beginObject()
  w.field("accepted", trace.accepted)
  w.field("detail", trace.detail)
  w.key("frames")
  w.beginArray()
  for frame in trace.frames:
    encodeFrameTrace(frame, w)
  w.endArray()
  w.field("manifest_name", trace.manifestName)
  w.field("reason", trace.reason)
  w.field("sha256", trace.sha256)
  w.endObject()
  w.take()

proc runHarnessJson*(bytes: string; baseDir = ""): string =
  encodeHarnessTrace(runHarnessCase(parseHarnessCase(bytes, baseDir)))

proc runHarnessFile*(path: string): string =
  runHarnessJson(readFile(path), path.parentDir)
