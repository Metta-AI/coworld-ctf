## FIRST LIGHT's play-seat episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## Lane A supplies the concrete body, belief-lite, navigation, and seatTick
## actuation. This module owns only the server-side lifecycle,
## default-order installation, mask handoff, annotations, and timing split.

import std/[json, monotimes, options, os, strformat, strutils, times]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
import body_nav
import reflexes
import replay_records
import types
import standing_order

const ShellRuntimeAvailable* =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0

when ShellRuntimeAvailable:
  import binary_view, call_validation, canonical, compile_plane, emit_validator,
    guards, instance, ladder, runtime, view

type
  FirstLightInventory* = object
    wasmtime*: bool
    uploads*: bool
    calls*: bool
    stores*: bool
    ladder*: bool

  FirstLightSeatFrame* = object
    ## One coherent tick-boundary handoff. bodyInputs is lane A's real
    ## belief-lite surface; defaultFallbacks carries only the first-light
    ## facts not yet exposed by lane A accessors.
    seat*: uint8
    playerIndex*: int
    present*: bool
    playing*: bool
    alive*: bool
    aliveTeams*: int
    motionScale*: int
    velocity*: int
    bodyInputs*: BodyTickInputs
    defaultFallbacks*: BrDefaultFallbacks

  FirstLightMask* = object
    seat*: uint8
    playerIndex*: int
    input*: InputState

  FirstLightInstall* = object
    tick*: uint32
    seat*: uint8
    rule*: string
    provenance*: string
    bytesHash*: string
    bytes*: string

  FirstLightModuleStatus* = object
    seat*: int
    uploadId*: uint64
    terminal*: string
    status*: StatusEntry
    statusBytes*: string

  FirstLightEntryIdentity* = object
    seat*: int
    entryId*: string
    play*: string

  FirstLightLadderStatus* = object
    seat*: int
    entryId*: string
    status*: StatusEntry
    statusBytes*: string

  FirstLightCallReplayIdentity* = object
    seat*: uint8
    epoch*: uint64
    ladderBytes*: string
    entries*: seq[PlayCallEntryIdentity]
    contentSha256*: string
      ## Codec-derived identity hash with replayTimeMs=0. Lane B owns real
      ## replay time and must call toPlayCallRecord(identity, replayTimeMs)
      ## for the queued record's time-stamped content hash.

  FirstLightAdmissionResult* = object
    accepted*: bool
    reason*: string
    status*: StatusEntry
    statusBytes*: string

  FirstLightCallResult* = object
    accepted*: bool
    reason*: string
    path*: string
    epoch*: uint64
    status*: StatusEntry
    statusBytes*: string
    pendingRetunes*: seq[FirstLightEntryIdentity]
    replayIdentity*: Option[FirstLightCallReplayIdentity]

  FirstLightPlayConfigResult* = object
    lines*: seq[string]
    callIdentities*: seq[FirstLightCallReplayIdentity]

  FirstLightTickResult* = object
    masks*: seq[FirstLightMask]
    annotations*: seq[ShellAnnotation]
    installs*: seq[FirstLightInstall]
    moduleStatuses*: seq[FirstLightModuleStatus]
    ladderStatuses*: seq[FirstLightLadderStatus]
    retuned*: seq[FirstLightEntryIdentity]
    bodyNanoseconds*: int64
    runtimeNanoseconds*: int64

  ViewSource* = proc(seatIndex: int; tick: uint32): string {.closure.}

  FirstLightPlayConfig* = object
    modulePath*: string
    playName*: string
    paramsBytes*: string
    seats*: seq[int]
    uploadIdBase*: uint64
    proposalIdBase*: uint64
    originGeneration*: uint64

  FirstLightViewFrameSlot = object
    present: bool
    frame: FirstLightSeatFrame

  FirstLightRuntimeState = ref object
    frames: seq[FirstLightViewFrameSlot]
    selfPositions: seq[BodyPoint]
    reflexStates: seq[ReflexSeatState]
    lastCompileTick: Option[uint32]

  FirstLightSeatState* = object
    seat*: uint8
    active*: bool
    eliminated*: bool
    everActivated*: bool
    body*: SeatBody
    standing*: StandingOrderState

  FirstLightEpisode* = object
    enabled*: bool
    brMode*: bool
    rosterSize*: int
    map*: BodyMap
    nav*: BodyNavSystem
    seats*: seq[FirstLightSeatState]
    bodyActivations: int
    viewSource*: ViewSource
    when ShellRuntimeAvailable:
      mapName: string
      gunRange: int
      viewInterval: int
      contextRoster: seq[PlayContextRosterRow]
      runtimeState: FirstLightRuntimeState
      engine: RuntimeEngine
      compilePlane: CompilePlane
      ladder: LadderDriver
      bindings: seq[LadderBinding]

proc firstLightInventory*(): FirstLightInventory =
  ## Runtime inventory is compile-time visible so ordinary server builds that
  ## lack the Wasmtime C API remain the zero-guest first-light path.
  when ShellRuntimeAvailable:
    FirstLightInventory(wasmtime: true, uploads: true, calls: true,
      stores: true, ladder: true)
  else:
    FirstLightInventory()

proc bodyActivationCount*(episode: FirstLightEpisode): int =
  ## Test/readback surface for the server invariant that playback consumes
  ## recorded masks and never constructs SeatBody instances.
  episode.bodyActivations

proc frameForSeat(episode: FirstLightEpisode; seatIndex: int):
    Option[FirstLightSeatFrame] =
  when ShellRuntimeAvailable:
    if episode.runtimeState != nil and seatIndex >= 0 and
        seatIndex < episode.runtimeState.frames.len and
        episode.runtimeState.frames[seatIndex].present:
      return some(episode.runtimeState.frames[seatIndex].frame)
  none(FirstLightSeatFrame)

const MaxPlayZoneTicksToShrink = high(int32).int

proc playZoneTicksToShrink(value: int): int =
  ## The sim uses high(int) div 4 as the "no more zone phases" sentinel, but
  ## the play view is an int32 ABI. Preserve the sentinel's meaning by
  ## saturating it to the largest representable future tick count; plays testing
  ## "ticks_to_shrink <= enterLead" still do not trigger at the final phase.
  if value < 0:
    0
  elif value > MaxPlayZoneTicksToShrink:
    MaxPlayZoneTicksToShrink
  else:
    value

proc firstLightViewBytes*(episode: FirstLightEpisode; seatIndex: int;
                          tick: uint32): string =
  when ShellRuntimeAvailable:
    let frame = episode.frameForSeat(seatIndex)
    if frame.isNone:
      return "{}"
    for state in episode.seats:
      if state.active and state.seat.int == seatIndex:
        let fallbacks = frame.get.defaultFallbacks
        let source = playViewSourceFromBody(
          state.body,
          tick,
          if episode.brMode: gmBr else: gmCtf,
          frame.get.aliveTeams,
          some(PlayZone(
            phase: fallbacks.zonePhase,
            current: PlayRect(x: fallbacks.currentZone.x,
              y: fallbacks.currentZone.y, w: fallbacks.currentZone.w,
              h: fallbacks.currentZone.h),
            next: some(PlayRect(x: fallbacks.nextZone.x,
              y: fallbacks.nextZone.y, w: fallbacks.nextZone.w,
              h: fallbacks.nextZone.h)),
            ticksToShrink:
              playZoneTicksToShrink(fallbacks.ticksToNextShrink),
            dps: fallbacks.zoneDps)))
        return buildBinaryPlayView(source)
    "{}"
  else:
    discard episode
    discard seatIndex
    discard tick
    "{}"

proc initFirstLightEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange,
    teams: openArray[Team] = [],
    mapName = "",
    viewInterval = ViewIntervalTicksDefault): FirstLightEpisode =
  if teams.len > 0 and teams.len != controls.len:
    raise newException(ValueError,
      "FIRST LIGHT team/control facts must have the same length")
  result.brMode = brMode
  result.rosterSize = controls.len
  result.map = map
  if not season2Shell:
    return
  if map == nil:
    raise newException(ValueError, "FIRST LIGHT requires a BodyMap")
  result.nav = newBodyNavSystem(map, controls.len, liveGunRangePx)
  when ShellRuntimeAvailable:
    result.mapName = mapName
    result.gunRange = liveGunRangePx
    result.viewInterval = viewInterval
    if teams.len > 0:
      for index, control in controls:
        result.contextRoster.add(PlayContextRosterRow(
          seat: index,
          team: teams[index],
          control: if control == scPlay: pccPlay else: pccInput))
    result.runtimeState = FirstLightRuntimeState(
      frames: newSeq[FirstLightViewFrameSlot](controls.len),
      selfPositions: newSeq[BodyPoint](controls.len),
      reflexStates: newSeq[ReflexSeatState](controls.len))
  for index, control in controls:
    if control == scPlay:
      result.enabled = true
      result.seats.add(FirstLightSeatState(seat: uint8(index)))

proc initFirstLightPlaybackEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange): FirstLightEpisode =
  ## Playback consumes recorded InputState masks; the body path is a live-server
  ## producer only. Even for a shell-on recording, this owner keeps no nav,
  ## seats, or SeatBody instances.
  discard season2Shell
  discard controls
  discard liveGunRangePx
  result.brMode = brMode
  result.rosterSize = controls.len
  result.map = map

proc closeFirstLightEpisode*(episode: var FirstLightEpisode) =
  ## Drops per-episode runtime ownership. The first-light body/nav state is
  ## owned by ordinary object replacement; runtime handles need explicit close.
  when ShellRuntimeAvailable:
    if episode.ladder != nil:
      episode.ladder.close()
      episode.ladder = nil
    if episode.compilePlane != nil:
      episode.compilePlane.close()
      episode.compilePlane = nil
    if episode.engine != nil:
      episode.engine.close()
      episode.engine = nil
    episode.bindings.setLen(0)
    episode.runtimeState = nil

proc resetFirstLightEpisode*(episode: var FirstLightEpisode,
    season2Shell, brMode: bool, controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange,
    teams: openArray[Team] = [],
    mapName = "",
    viewInterval = ViewIntervalTicksDefault) =
  ## Full episode replacement boundary for any server-side sim/config
  ## replacement. Fresh bodies re-run the activation safe install instead of
  ## carrying standing orders, nav state, or map-owned goals across matches.
  episode.closeFirstLightEpisode()
  episode = initFirstLightEpisode(season2Shell, brMode, controls, map,
    liveGunRangePx, teams, mapName, viewInterval)

proc safeIntent(reason: string, idleAimCenterBrads: int): FinishedOrder =
  finishDefault(Intent(
    kind: ikHold,
    arriveRadius: 0.0,
    reason: "first_light:safe_" & reason), idleAimCenterBrads)

proc provenanceText(provenance: Provenance): string =
  case provenance.base.kind
  of pbEntry: "entry:" & provenance.base.entryId
  of pbDefault: "default"
  of pbReflex:
    if provenance.base.reflexName.startsWith(ReflexNamePrefix):
      "reflex:" & provenance.base.reflexName[ReflexNamePrefix.len .. ^1]
    else:
      "reflex:" & provenance.base.reflexName

proc bytesHash(bytes: string): string =
  var hash = 14_695_981_039_346_656_037'u64
  for value in bytes:
    hash = (hash xor uint64(value.uint8)) * 1_099_511_628_211'u64
  hash.toHex(16).toLowerAscii

proc installRecord(annotation: ShellAnnotation,
    rule, provenance, bytes: string): FirstLightInstall =
  FirstLightInstall(
    tick: annotation.tick,
    seat: annotation.seat,
    rule: rule,
    provenance: provenance,
    bytesHash: bytes.bytesHash,
    bytes: bytes)

proc rawBytes(bytes: string): seq[byte] =
  result = newSeq[byte](bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc canonicalParams(node: JsonNode): string =
  if node == nil:
    return "{}"
  when ShellRuntimeAvailable:
    canonicalJson(node)
  else:
    $node

proc playConfigFromNode(node: JsonNode; repoRoot: string):
    FirstLightPlayConfig =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "firstLightPlay must be an object")
  result.modulePath = node{"modulePath"}.getStr("")
  if result.modulePath.len == 0:
    raise newException(ValueError, "firstLightPlay.modulePath is required")
  if not result.modulePath.isAbsolute:
    result.modulePath = repoRoot / result.modulePath
  result.playName = node{"playName"}.getStr(node{"play"}.getStr(""))
  if result.playName.len == 0:
    raise newException(ValueError, "firstLightPlay.playName is required")
  result.paramsBytes = canonicalParams(node{"params"})
  result.uploadIdBase = uint64(node{"uploadIdBase"}.getInt(10_000))
  result.proposalIdBase = uint64(node{"proposalIdBase"}.getInt(20_000))
  result.originGeneration = uint64(node{"originGeneration"}.getInt(1))
  let seats = node{"seats"}
  if seats == nil or seats.kind != JArray:
    raise newException(ValueError, "firstLightPlay.seats must be an array")
  for item in seats:
    if item.kind != JInt:
      raise newException(ValueError, "firstLightPlay.seats entries must be integers")
    let seat = item.getInt()
    if seat < 0 or seat >= MaxPlayers:
      raise newException(ValueError, "firstLightPlay.seats entry out of range")
    if seat in result.seats:
      raise newException(ValueError, "firstLightPlay.seats entry duplicated")
    result.seats.add seat

proc firstLightPlayNode(configJson: string): JsonNode =
  if configJson.len == 0:
    return nil
  let root = parseJson(configJson)
  root{"firstLightPlay"}

proc firstLightPlayConfigRefusal(episode: FirstLightEpisode;
    config: FirstLightPlayConfig): Option[string] =
  ## Config validity is independent of whether the Wasmtime runtime was linked.
  ## The compile-time runtime gate decides only whether a valid play can run.
  if not episode.enabled:
    return some("FIRST_LIGHT_PLAY configured=false reason=episode_disabled")
  if config.seats.len == 0:
    return some("FIRST_LIGHT_PLAY configured=false reason=no_seats")
  for seat in config.seats:
    if seat < 0 or seat >= episode.rosterSize:
      raise newException(ValueError,
        "firstLightPlay.seats entry outside roster")
  none(string)

proc toPlayCallRecord*(identity: FirstLightCallReplayIdentity;
    replayTimeMs: uint32): PlayCallRecord =
  ## Builds the landed replay record shape from the lane-C accepted-call
  ## identity. The decoder owns `contentSha256`; keep this helper on the codec
  ## path instead of maintaining a parallel hash definition.
  let bytes = PlayCallRecord(
    replayTimeMs: replayTimeMs,
    seat: identity.seat,
    epoch: identity.epoch,
    ladderBytes: identity.ladderBytes,
    entries: identity.entries).encodePlayCallRecord()
  bytes.decodePlayCallRecord()

proc withContentSha(identity: FirstLightCallReplayIdentity):
    FirstLightCallReplayIdentity =
  result = identity
  result.contentSha256 = identity.toPlayCallRecord(0).contentSha256

when ShellRuntimeAvailable:
  const NativeReflexSubscriptions = [
    ReflexSubscription(kind: rkClearGrenade, epoch: 0),
    ReflexSubscription(kind: rkClearSpray, epoch: 0),
    ReflexSubscription(kind: rkZoneEscape, epoch: 0)]

  proc noGuardContext(): IntentContext =
    IntentContext(
      resolveNumber: proc(path: string): float =
        discard path
        0.0,
      resolveBool: proc(path: string): bool =
        discard path
        false)

  proc firstLightContextBytes(episode: FirstLightEpisode; seatIndex: int;
                              frame: FirstLightSeatFrame): string =
    if seatIndex < 0 or seatIndex >= episode.contextRoster.len:
      return "{}"
    # binary_view.validateContextSource enforces the binary play_context
    # roster floor of 2..32 rows. One-seat harness episodes cannot encode
    # that context legally, so give guests the empty context instead.
    if episode.contextRoster.len < 2:
      return "{}"
    # The binary play_context contract carries duo_partner exactly in BR.
    # If the body has not observed a real partner yet, omit the context rather
    # than fabricating one.
    if episode.brMode and frame.bodyInputs.partner.isNone:
      return "{}"
    var source = PlayContextSource(
      mode: if episode.brMode: gmBr else: gmCtf,
      mapName: episode.mapName,
      mapWidth: if episode.map == nil: 0 else: episode.map.width,
      mapHeight: if episode.map == nil: 0 else: episode.map.height,
      selfSeat: seatIndex,
      selfTeam: episode.contextRoster[seatIndex].team,
      duoPartner:
        if episode.brMode:
          some(frame.bodyInputs.partner.get.seat.int)
        else:
          none(int),
      gunRange: episode.gunRange,
      viewInterval: episode.viewInterval)
    source.roster = episode.contextRoster
    buildBinaryPlayContext(source)

  proc ensureLadder(episode: var FirstLightEpisode) =
    if episode.ladder == nil:
      episode.ladder = newLadderDriver(episode.runtimeState.frames.len,
        DefaultPathRegistry, if episode.brMode: gmBr else: gmCtf,
        episode.map)

  proc ensureRuntime(episode: var FirstLightEpisode) =
    if episode.engine == nil:
      episode.engine = newRuntimeEngine()
    if episode.compilePlane == nil:
      episode.compilePlane = newCompilePlane(episode.engine,
        episode.runtimeState.frames.len)
    episode.ensureLadder()

  proc addBindingFor(episode: var FirstLightEpisode; bound: BoundModule) =
    for binding in episode.bindings.mitems:
      if binding.manifest.name == bound.manifest.name and
          binding.hash == bound.hash:
        return
    let runtimeState = episode.runtimeState
    let map = episode.map
    let mode = if episode.brMode: gmBr else: gmCtf
    let module = bound.module
    episode.bindings.add LadderBinding(
      manifest: bound.manifest,
      hash: bound.hash,
      ready: true,
      makeGuest: proc(seatIndex: int; entry: ValidatedCallEntry,
                      emitClass: EmitClass): LadderGuest =
        discard entry
        var selfPos: BodyPoint
        if runtimeState != nil and seatIndex >= 0 and
            seatIndex < runtimeState.selfPositions.len:
          selfPos = runtimeState.selfPositions[seatIndex]
        try:
          shellGuest(newShellInstance(module, map, selfPos, emitClass, mode),
            emitClass)
        except ShellRuntimeError:
          nil)

  proc seatIsConfiguredPlay(episode: FirstLightEpisode; seatIndex: int): bool =
    for state in episode.seats:
      if state.seat.int == seatIndex:
        return true

  proc moduleStatus(commit: CompileCommit): FirstLightModuleStatus =
    FirstLightModuleStatus(seat: commit.seat, uploadId: commit.uploadId,
      terminal: $commit.terminal, status: commit.status,
      statusBytes: commit.statusBytes)

  proc entryIdentity(seat: int; identity: LadderEntryIdentity):
      FirstLightEntryIdentity =
    FirstLightEntryIdentity(seat: seat, entryId: identity.entryId,
      play: identity.play)

  proc ladderStatus(status: LadderStatus): FirstLightLadderStatus =
    FirstLightLadderStatus(seat: status.seat, entryId: status.entryId,
      status: status.status, statusBytes: status.statusBytes)

  proc callReplayIdentity(seatIndex: int; accepted: LadderCallResult):
      FirstLightCallReplayIdentity =
    FirstLightCallReplayIdentity(
      seat: uint8(seatIndex),
      epoch: accepted.epoch,
      ladderBytes: accepted.ladderBytes,
      entries: accepted.entries).withContentSha()

  proc commitReadyModules(episode: var FirstLightEpisode;
      maxCommits = MaxCompileCommitsPerTick): seq[FirstLightModuleStatus] =
    if episode.compilePlane == nil:
      return
    for commit in episode.compilePlane.commitCompileResults(maxCommits):
      if commit.terminal == tkReady:
        let bound = episode.compilePlane.boundModule(commit.seat, commit.status.name)
        if bound.isSome:
          episode.addBindingFor(bound.get)
      result.add commit.moduleStatus

  proc progressCompilePlane(episode: var FirstLightEpisode):
      seq[FirstLightModuleStatus] =
    if episode.compilePlane == nil:
      return
    for commit in episode.compilePlane.progressCompileWorkers():
      if commit.terminal == tkReady:
        let bound = episode.compilePlane.boundModule(commit.seat, commit.status.name)
        if bound.isSome:
          episode.addBindingFor(bound.get)
      result.add commit.moduleStatus

  proc beginCompileTick(episode: var FirstLightEpisode; tick: uint32) =
    if episode.compilePlane == nil or episode.runtimeState == nil:
      return
    if episode.runtimeState.lastCompileTick.isSome and
        episode.runtimeState.lastCompileTick.get == tick:
      return
    episode.compilePlane.beginTick()
    episode.runtimeState.lastCompileTick = some(tick)

  proc seatBindings(episode: var FirstLightEpisode;
      seatIndex: int): seq[LadderBinding] =
    if episode.compilePlane == nil:
      return
    for bound in episode.compilePlane.boundModules(seatIndex):
      episode.addBindingFor(bound)
      for binding in episode.bindings:
        if binding.manifest.name == bound.manifest.name and
            binding.hash == bound.hash:
          result.add binding
          break

  proc admitPlayModule*(episode: var FirstLightEpisode; seatIndex: int;
      uploadId, originGeneration: uint64; bytes: openArray[byte]):
      FirstLightAdmissionResult =
    if not episode.enabled:
      result.reason = "episodeDisabled"
      return
    if seatIndex < 0 or seatIndex >= episode.rosterSize:
      result.reason = "badSeat"
      return
    if not episode.seatIsConfiguredPlay(seatIndex):
      result.reason = "seatNotPlay"
      return
    episode.ensureRuntime()
    let admitted = episode.compilePlane.admitModule(seatIndex, uploadId,
      originGeneration, bytes)
    result.accepted = admitted.accepted
    result.status = admitted.status
    result.statusBytes = admitted.statusBytes
    if admitted.accepted:
      result.reason = ""
    else:
      result.reason = admitted.refusal.refusalReason

  proc acceptPlayCall*(episode: var FirstLightEpisode; seatIndex: int;
      proposalId, originGeneration: uint64; tick: uint32; callBytes: string):
      FirstLightCallResult =
    if not episode.enabled:
      result.reason = "episodeDisabled"
      result.path = "episode"
      return
    if seatIndex < 0 or seatIndex >= episode.rosterSize:
      result.reason = "badSeat"
      result.path = "seat"
      return
    if not episode.seatIsConfiguredPlay(seatIndex):
      result.reason = "seatNotPlay"
      result.path = "seat"
      return
    episode.ensureRuntime()
    let accepted = episode.ladder.acceptCall(seatIndex, proposalId,
      originGeneration, tick, callBytes, episode.seatBindings(seatIndex),
      noGuardContext())
    result.accepted = accepted.accepted
    result.reason = accepted.reason
    result.path = accepted.path
    result.epoch = accepted.epoch
    result.status = accepted.status
    result.statusBytes = accepted.statusBytes
    for identity in accepted.pendingRetunes:
      result.pendingRetunes.add entryIdentity(seatIndex, identity)
    if accepted.accepted:
      result.replayIdentity = some(callReplayIdentity(seatIndex, accepted))

  proc callBytes(config: FirstLightPlayConfig): string =
    canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"" &
      config.playName & "\",\"params\":" & config.paramsBytes &
      ",\"play\":\"" & config.playName & "\"}]}"))

  proc configureFirstLightPlayWithReplayIdentities*(
      episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): FirstLightPlayConfigResult =
    ## Binds a configured first-light play through the production admission,
    ## compile, cache, instance, and call-validation seams.
    let refusal = episode.firstLightPlayConfigRefusal(config)
    if refusal.isSome:
      result.lines.add refusal.get
      return
    if not fileExists(config.modulePath):
      result.lines.add "FIRST_LIGHT_PLAY configured=false reason=module_missing path=" &
        config.modulePath
      return

    episode.ensureRuntime()
    let moduleBytes = readFile(config.modulePath)
    for index, seat in config.seats:
      let uploadId = config.uploadIdBase + uint64(index)
      let admitted = episode.admitPlayModule(seat, uploadId,
        config.originGeneration, moduleBytes.rawBytes)
      result.lines.add(&"FIRST_LIGHT_PLAY_UPLOAD seat={seat} upload_id={uploadId} " &
        &"accepted={admitted.accepted} status={admitted.statusBytes}")
    if not episode.compilePlane.drainCompileWorkers():
      result.lines.add("FIRST_LIGHT_PLAY_COMPILE drained=false")
      return
    var commits = 0
    while commits < config.seats.len:
      let batch = episode.commitReadyModules()
      if batch.len == 0:
        break
      for commit in batch:
        inc commits
        result.lines.add(&"FIRST_LIGHT_PLAY_COMMIT seat={commit.seat} " &
          &"upload_id={commit.uploadId} terminal={commit.terminal} " &
          &"status={commit.statusBytes}")

    for seat in config.seats:
      let accepted = episode.acceptPlayCall(seat,
        config.proposalIdBase + uint64(seat), config.originGeneration, 0,
        config.callBytes)
      result.lines.add(&"FIRST_LIGHT_PLAY_CALL seat={seat} accepted={accepted.accepted} " &
        &"epoch={accepted.epoch} reason={accepted.reason} " &
        &"status={accepted.statusBytes}")
      if accepted.replayIdentity.isSome:
        result.callIdentities.add accepted.replayIdentity.get

  proc configureFirstLightPlay*(episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): seq[string] =
    episode.configureFirstLightPlayWithReplayIdentities(config).lines

else:
  proc admitPlayModule*(episode: var FirstLightEpisode; seatIndex: int;
      uploadId, originGeneration: uint64; bytes: openArray[byte]):
      FirstLightAdmissionResult =
    discard seatIndex
    discard uploadId
    discard originGeneration
    discard bytes
    if not episode.enabled:
      result.reason = "episodeDisabled"
    else:
      result.reason = "runtimeUnavailable"

  proc acceptPlayCall*(episode: var FirstLightEpisode; seatIndex: int;
      proposalId, originGeneration: uint64; tick: uint32; callBytes: string):
      FirstLightCallResult =
    discard seatIndex
    discard proposalId
    discard originGeneration
    discard tick
    discard callBytes
    if not episode.enabled:
      result.reason = "episodeDisabled"
      result.path = "episode"
    else:
      result.reason = "runtimeUnavailable"
      result.path = "runtime"

  proc configureFirstLightPlay*(episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): seq[string] =
    let refusal = episode.firstLightPlayConfigRefusal(config)
    if refusal.isSome:
      return @[refusal.get]
    @["FIRST_LIGHT_PLAY configured=false reason=runtime_unavailable " &
      "hint=compile with --threads:on and WASMTIME_C_API"]

  proc configureFirstLightPlayWithReplayIdentities*(
      episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): FirstLightPlayConfigResult =
    result.lines = episode.configureFirstLightPlay(config)

proc configureFirstLightDemoPlayFromJsonWithReplayIdentities*(
    episode: var FirstLightEpisode; configJson: string;
    repoRoot = getCurrentDir()): FirstLightPlayConfigResult =
  let node = firstLightPlayNode(configJson)
  if node == nil:
    return
  try:
    result = episode.configureFirstLightPlayWithReplayIdentities(
      node.playConfigFromNode(repoRoot))
  except CatchableError as error:
    result.lines = @["FIRST_LIGHT_PLAY configured=false reason=parse_error detail=" &
      error.msg]

proc configureFirstLightDemoPlayFromJson*(episode: var FirstLightEpisode;
    configJson: string; repoRoot = getCurrentDir()): seq[string] =
  episode.configureFirstLightDemoPlayFromJsonWithReplayIdentities(
    configJson, repoRoot).lines

when ShellRuntimeAvailable:
  proc eventIdInt(value: uint64): int =
    if value <= uint64(high(int)): value.int else: high(int)

  proc zoneTicksUntilOutside(fallback: BrDefaultFallbacks):
      ZoneTicksUntilOutside =
    let
      current = fallback.currentZone
      ticksToShrink =
        int64(playZoneTicksToShrink(fallback.ticksToNextShrink))
    result = proc(point: BodyPoint): int64 =
      if point.x < current.x or point.y < current.y or
          point.x >= current.x + current.w or
          point.y >= current.y + current.h:
        0
      else:
        ticksToShrink

  proc reflexInput(state: FirstLightSeatState; frame: FirstLightSeatFrame;
                   tick: uint32; mode: GameMode): ReflexTickInput =
    result = ReflexTickInput(
      tick: tick,
      mode: mode,
      map: state.body.map,
      selfPos: frame.bodyInputs.self.pos,
      alive: frame.alive,
      motionScale: if frame.motionScale > 0: frame.motionScale else:
        MotionScale,
      velocity: if frame.velocity > 0: frame.velocity else: MaxSpeed,
      zoneTicksUntilOutside:
        zoneTicksUntilOutside(frame.defaultFallbacks),
      nextZone: frame.defaultFallbacks.nextZone)
    for hazard in state.body.hazards.grenades:
      result.visibleGrenades.add VisibleGrenade(
        predictedBlastPos: hazard.predictedBlastPos,
        ticksToBlast: hazard.ticksToBlast,
        blastRadius: GrenadeBlastRadius,
        eventId: hazard.eventId.eventIdInt)
    for cue in state.body.hazards.blastCues:
      result.blastCues.add BlastCue(
        pos: cue.pos,
        tick: cue.tick,
        eventId: cue.eventId.eventIdInt)
    for hazard in state.body.hazards.sprays:
      case hazard.kind
      of bshVisibleCone:
        result.sprayCones.add VisibleSprayCone(
          origin: hazard.origin,
          aimBrads: hazard.aimBrads,
          coversSelf: hazard.coversSelf,
          tick: hazard.tick,
          eventId: hazard.eventId.eventIdInt)
      of bshAnonymousImpact:
        result.sprayImpacts.add AnonymousSprayImpact(
          impactPos: hazard.impactPos,
          incomingDir: hazard.incomingDirBrads,
          tick: hazard.tick,
          eventId: hazard.eventId.eventIdInt)

  proc nativeBase(decision: ReflexDecision): Option[LadderNativeBase] =
    if not decision.selected:
      return none(LadderNativeBase)
    some(LadderNativeBase(
      intent: decision.order.intent,
      goal: decision.order.goal,
      provenance: decision.order.provenance,
      contributingEpoch: decision.order.contributingEpoch))

proc resetAfterDeath(state: var FirstLightSeatState, tick: uint32,
    nav: BodyNavSystem, annotations: var seq[ShellAnnotation]) =
  annotations.add(ShellAnnotation(
    tick: tick,
    seat: state.seat,
    kind: akClearOnDeath,
    clearGeneration: 0))
  state.active = false
  state.standing = StandingOrderState()
  state.body = nil
  nav.setSeatActive(state.seat.int, false)

proc activate(state: var FirstLightSeatState, frame: FirstLightSeatFrame,
    tick: uint32, reason: string, nav: BodyNavSystem,
    output: var FirstLightTickResult) =
  state.body = activateSeatBody(nav, state.seat.int)
  nav.setSeatActive(state.seat.int, true)
  state.body.updateBelief(frame.bodyInputs, tick)
  let safe = safeIntent(reason, frame.defaultFallbacks.idleAimCenterBrads)
  let safeBytes = canonicalIntent(safe.intent)
  setStandingIntent(state.body, safe.intent, none(ValidatedGoal), 0)
  state.standing = StandingOrderState(
    hasStanding: true,
    intent: safe.intent,
    intentBytes: safeBytes,
    provenance: safe.provenance,
    effectiveEpoch: 0,
    installedEffectiveEpoch: 0,
    lastDefaultRule: brHold)
  let annotation = ShellAnnotation(
    tick: tick,
    seat: state.seat,
    kind: akInstallSafeIntent,
    installGeneration: 0,
    installReason: reason,
    safeBytes: safeBytes)
  output.annotations.add(annotation)
  output.installs.add(annotation.installRecord(
    "safe_hold", "default", safeBytes))
  state.active = true
  state.everActivated = true

proc appendStandingChanges(state: var FirstLightSeatState,
    output: var FirstLightTickResult) =
  for annotation in state.standing.annotations:
    output.annotations.add(annotation)
    if annotation.kind == akAcceptedIntentChange:
      let rule =
        case annotation.provenance.base.kind
        of pbEntry: annotation.provenance.base.entryId
        of pbDefault: $state.standing.lastDefaultRule
        of pbReflex: annotation.provenance.base.reflexName
      output.installs.add(annotation.installRecord(
        rule,
        annotation.provenance.provenanceText,
        annotation.intentBytes))
  state.standing.annotations.setLen(0)

proc acceptDangerTrack(track: BodyTrack): bool =
  discard track
  true

proc dangerInputs(episode: FirstLightEpisode,
                  tick: uint32): seq[DangerInput] =
  result = newSeq[DangerInput](episode.nav.seats.len)
  for state in episode.seats:
    if state.active and state.body != nil:
      result[state.seat.int] =
        state.body.dangerInputFromTracks(tick, acceptDangerTrack)

proc step*(episode: var FirstLightEpisode,
    frames: openArray[FirstLightSeatFrame], tick: uint32): FirstLightTickResult =
  ## Runs configured play seats in configured-seat order. Disabled episodes
  ## return an empty result, so the server hook cannot touch legacy inputs or
  ## replay bytes on gate-off or gate-on/all-input configurations.
  if not episode.enabled:
    return

  when ShellRuntimeAvailable:
    if episode.runtimeState != nil:
      for slot in episode.runtimeState.frames.mitems:
        slot.present = false
      for frame in frames:
        let seat = frame.seat.int
        if seat >= 0 and seat < episode.runtimeState.frames.len:
          episode.runtimeState.frames[seat] =
            FirstLightViewFrameSlot(present: frame.present, frame: frame)
          episode.runtimeState.selfPositions[seat] = frame.bodyInputs.self.pos
    episode.beginCompileTick(tick)
    result.moduleStatuses = episode.progressCompilePlane()

  for state in episode.seats.mitems:
    var frameIndex = -1
    for index, frame in frames:
      if frame.seat == state.seat:
        frameIndex = index
        break
    if frameIndex < 0 or not frames[frameIndex].present:
      continue
    let frame = frames[frameIndex]

    let runtimeStarted = getMonoTime()
    if state.active and not frame.alive:
      state.resetAfterDeath(tick, episode.nav, result.annotations)
      if episode.brMode:
        state.eliminated = true
    if frame.playing and frame.alive and not state.active and
        not state.eliminated:
      state.activate(frame, tick,
        if state.everActivated: "respawn" else: "activation",
        episode.nav, result)
      inc episode.bodyActivations
    if state.active and frame.playing and frame.alive:
      state.body.updateBelief(frame.bodyInputs, tick)
      when ShellRuntimeAvailable:
        if episode.ladder == nil:
          state.standing.stepFirstLightDefault(state.body, tick,
            frame.defaultFallbacks)
          state.appendStandingChanges(result)
      else:
        state.standing.stepFirstLightDefault(state.body, tick,
          frame.defaultFallbacks)
        state.appendStandingChanges(result)
    result.runtimeNanoseconds += (getMonoTime() - runtimeStarted).inNanoseconds

  when ShellRuntimeAvailable:
    if episode.runtimeState != nil:
      episode.ensureLadder()
    if episode.ladder != nil:
      let runtimeStarted = getMonoTime()
      var inputs = newSeq[LadderSeatInput](episode.runtimeState.frames.len)
      for seat in 0 ..< inputs.len:
        inputs[seat] = LadderSeatInput(
          alive: false,
          contextBytes: "{}",
          viewBytes: "{}",
          guardContext: noGuardContext(),
          defaultIntent: Intent(kind: ikHold, arriveRadius: 0.0,
            reason: "default:hold"),
          defaultGoal: none(ValidatedGoal))

      for state in episode.seats.mitems:
        let seat = state.seat.int
        if seat < 0 or seat >= episode.runtimeState.frames.len:
          continue
        let slot = episode.runtimeState.frames[seat]
        if not slot.present or not state.active or not slot.frame.playing or
            not slot.frame.alive:
          continue
        let facts = brDefaultFacts(state.body, tick,
          slot.frame.defaultFallbacks)
        let decision = computeBrDefault(facts)
        state.standing.lastDefaultRule = decision.rule
        let finished = finishDefault(decision.intent,
          facts.idleAimCenterBrads)
        let reflexDecision =
          episode.runtimeState.reflexStates[seat].selectReflex(
            state.reflexInput(slot.frame, tick,
              if episode.brMode: gmBr else: gmCtf),
            NativeReflexSubscriptions)
        inputs[seat] = LadderSeatInput(
          alive: true,
          selfPos: slot.frame.bodyInputs.self.pos,
          contextBytes: episode.firstLightContextBytes(seat, slot.frame),
          viewBytes: (if episode.viewSource == nil:
            episode.firstLightViewBytes(seat, tick)
          else:
            episode.viewSource(seat, tick)),
          guardContext: noGuardContext(),
          defaultIntent: finished.intent,
          defaultGoal: decision.goal,
          nativeBase: reflexDecision.nativeBase)

      let ladderOutput = episode.ladder.tick(inputs, tick, episode.bindings)
      for row in ladderOutput.seats:
        for status in row.statuses:
          result.ladderStatuses.add status.ladderStatus
        for identity in row.retuned:
          result.retuned.add entryIdentity(row.seat, identity)
      for state in episode.seats.mitems:
        let seat = state.seat.int
        if seat < 0 or seat >= ladderOutput.seats.len or
            seat >= episode.runtimeState.frames.len:
          continue
        let slot = episode.runtimeState.frames[seat]
        if not slot.present or not state.active or not slot.frame.playing or
            not slot.frame.alive:
          continue
        let row = ladderOutput.seats[seat]
        state.standing.stepResolvedOrder(state.body, tick,
          ResolvedStandingOrder(
            intent: row.intent,
            goal: row.goal,
            provenance: row.provenance,
            contributingEpoch: row.contributingEpoch),
          slot.frame.defaultFallbacks.idleAimCenterBrads)
        state.appendStandingChanges(result)
      result.runtimeNanoseconds +=
        (getMonoTime() - runtimeStarted).inNanoseconds

  for state in episode.seats.mitems:
    var frameIndex = -1
    for index, frame in frames:
      if frame.seat == state.seat:
        frameIndex = index
        break
    if frameIndex < 0 or not frames[frameIndex].present:
      continue
    let frame = frames[frameIndex]
    # Every present play seat hands one mask to the caller each tick. Lane A's
    # FL-B seatTick is the sole movement/action executor for active seats.
    var input = InputState()
    if state.active and frame.playing and frame.alive:
      let bodyStarted = getMonoTime()
      input = seatTick(state.body, frame.bodyInputs, tick)
      result.bodyNanoseconds += (getMonoTime() - bodyStarted).inNanoseconds
    result.masks.add(FirstLightMask(
      seat: state.seat, playerIndex: frame.playerIndex, input: input))
  episode.nav.rebuildScheduledDanger(tick.int, episode.dangerInputs(tick))
  discard episode.nav.runPlanningTick(tick.int)

proc observeDeaths*(episode: var FirstLightEpisode,
    frames: openArray[FirstLightSeatFrame], tick: uint32): seq[ShellAnnotation] =
  ## Post-sim lifecycle hook: clear a seat on the exact tick whose sim step
  ## killed it, without running a default, a body, or a mask handoff twice.
  if not episode.enabled:
    return
  for state in episode.seats.mitems:
    if not state.active:
          continue
    for frame in frames:
      if frame.seat == state.seat and frame.present and not frame.alive:
        state.resetAfterDeath(tick, episode.nav, result)
        if episode.brMode:
          state.eliminated = true
        break

proc formatInstall*(install: FirstLightInstall): string =
  &"FIRST_LIGHT_INSTALL tick={install.tick} seat={install.seat} " &
    &"rule={install.rule} provenance={install.provenance} " &
    &"bytes_fnv1a64={install.bytesHash} bytes={install.bytes}"

proc formatLifecycleAnnotation*(annotation: ShellAnnotation): string =
  case annotation.kind
  of akClearOnDeath:
    &"FIRST_LIGHT_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=clear_on_death generation={annotation.clearGeneration}"
  of akInstallSafeIntent:
    &"FIRST_LIGHT_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=install_safe reason={annotation.installReason}"
  of akAcceptedIntentChange:
    &"FIRST_LIGHT_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=accepted_intent epoch={annotation.effectiveEpoch}"
  of akPlayFault:
    &"FIRST_LIGHT_ANNOTATION tick={annotation.tick} seat={annotation.seat} " &
      &"kind=play_fault epoch={annotation.faultAtEpoch}"
