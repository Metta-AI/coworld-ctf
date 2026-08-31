## FIRST LIGHT's gate-on episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## Lane A FL-B supplies the concrete body, belief-lite, navigation, and
## movement-only seatTick. This module owns only the server-side lifecycle,
## default-order installation, mask handoff, annotations, and timing split.

import std/[json, monotimes, options, os, strformat, strutils, times]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
import body_nav
import types
import standing_order

const ShellRuntimeAvailable* =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0

when ShellRuntimeAvailable:
  import call_validation, canonical, compile_plane, emit_validator, guards,
    instance, ladder, runtime

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

  FirstLightTickResult* = object
    masks*: seq[FirstLightMask]
    annotations*: seq[ShellAnnotation]
    installs*: seq[FirstLightInstall]
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
    map*: BodyMap
    nav*: BodyNavSystem
    seats*: seq[FirstLightSeatState]
    bodyActivations: int
    viewSource*: ViewSource
    when ShellRuntimeAvailable:
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

proc rectBytes(rect: MapRect): string =
  "[" & $rect.x & "," & $rect.y & "," & $rect.w & "," & $rect.h & "]"

proc provisionalFirstLightView*(frame: FirstLightSeatFrame;
                                tick: uint32): string =
  ## Provisional lane-C view source for the episode/ladder wiring proof. It
  ## emits only the lean JSON rows `edge_ride` reads today: self position,
  ## tick, and BR zone facts. Lane A's encoder replaces this source; do not
  ## grow it into a second view producer.
  let self = frame.bodyInputs.self
  "{\"schema\":\"play_view\",\"self\":{\"aim_brads\":" & $self.aimBrads &
    ",\"alive\":" & (if self.alive: "true" else: "false") &
    ",\"hp_frac\":" & $self.hpFrac &
    ",\"pos\":[" & $self.pos.x & "," & $self.pos.y & "]}," &
    "\"tick\":" & $tick &
    ",\"v\":1,\"world\":{\"alive_teams\":0,\"zone\":{\"current\":" &
    frame.defaultFallbacks.currentZone.rectBytes &
    ",\"dps\":" & $frame.defaultFallbacks.zoneDps &
    ",\"next\":" & frame.defaultFallbacks.nextZone.rectBytes &
    ",\"phase\":0,\"ticks_to_shrink\":" &
    $frame.defaultFallbacks.ticksToNextShrink & "}}}"

proc frameForSeat(episode: FirstLightEpisode; seatIndex: int):
    Option[FirstLightSeatFrame] =
  when ShellRuntimeAvailable:
    if episode.runtimeState != nil and seatIndex >= 0 and
        seatIndex < episode.runtimeState.frames.len and
        episode.runtimeState.frames[seatIndex].present:
      return some(episode.runtimeState.frames[seatIndex].frame)
  none(FirstLightSeatFrame)

proc defaultViewSource(episode: FirstLightEpisode): ViewSource =
  result = proc(seatIndex: int; tick: uint32): string =
    let frame = episode.frameForSeat(seatIndex)
    if frame.isNone:
      return "{}"
    frame.get.provisionalFirstLightView(tick)

proc initFirstLightEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil,
    liveGunRangePx: int = GunRange): FirstLightEpisode =
  result.brMode = brMode
  result.map = map
  if not season2Shell:
    return
  if map == nil:
    raise newException(ValueError, "FIRST LIGHT requires a BodyMap")
  result.nav = newBodyNavSystem(map, controls.len, liveGunRangePx)
  when ShellRuntimeAvailable:
    result.runtimeState = FirstLightRuntimeState(
      frames: newSeq[FirstLightViewFrameSlot](controls.len),
      selfPositions: newSeq[BodyPoint](controls.len))
  result.viewSource = result.defaultViewSource()
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
    map: BodyMap = nil, liveGunRangePx: int = GunRange) =
  ## Full episode replacement boundary for any server-side sim/config
  ## replacement. Fresh bodies re-run the activation safe install instead of
  ## carrying standing orders, nav state, or map-owned goals across matches.
  episode.closeFirstLightEpisode()
  episode = initFirstLightEpisode(season2Shell, brMode, controls, map,
    liveGunRangePx)

proc safeIntent(reason: string, idleAimCenterBrads: int): FinishedOrder =
  finishDefault(Intent(
    kind: ikHold,
    arriveRadius: 0.0,
    reason: "first_light:safe_" & reason), idleAimCenterBrads)

proc provenanceText(provenance: Provenance): string =
  case provenance.base.kind
  of pbEntry: "entry:" & provenance.base.entryId
  of pbDefault: "default"
  of pbReflex: provenance.base.reflexName

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
    result.seats.add item.getInt()

proc firstLightPlayNode(configJson: string): JsonNode =
  if configJson.len == 0:
    return nil
  let root = parseJson(configJson)
  root{"firstLightPlay"}

when ShellRuntimeAvailable:
  proc noGuardContext(): IntentContext =
    IntentContext(
      resolveNumber: proc(path: string): float =
        discard path
        0.0,
      resolveBool: proc(path: string): bool =
        discard path
        false)

  proc ensureRuntime(episode: var FirstLightEpisode) =
    if episode.engine == nil:
      episode.engine = newRuntimeEngine()
    if episode.compilePlane == nil:
      episode.compilePlane = newCompilePlane(episode.engine,
        episode.runtimeState.frames.len)
    if episode.ladder == nil:
      episode.ladder = newLadderDriver(episode.runtimeState.frames.len,
        DefaultPathRegistry, if episode.brMode: gmBr else: gmCtf,
        episode.map)

  proc addBindingFor(episode: var FirstLightEpisode; bound: BoundModule) =
    for binding in episode.bindings.mitems:
      if binding.manifest.name == bound.manifest.name:
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

  proc callBytes(config: FirstLightPlayConfig): string =
    canonicalJson(parseJson("{\"plays\":[{\"entry_id\":\"" &
      config.playName & "\",\"params\":" & config.paramsBytes &
      ",\"play\":\"" & config.playName & "\"}]}"))

  proc configureFirstLightPlay*(episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): seq[string] =
    ## Binds a configured first-light play through the production admission,
    ## compile, cache, instance, and call-validation seams.
    if not episode.enabled:
      return @["FIRST_LIGHT_PLAY configured=false reason=episode_disabled"]
    if config.seats.len == 0:
      return @["FIRST_LIGHT_PLAY configured=false reason=no_seats"]
    if not fileExists(config.modulePath):
      return @["FIRST_LIGHT_PLAY configured=false reason=module_missing path=" &
        config.modulePath]

    episode.ensureRuntime()
    let moduleBytes = readFile(config.modulePath)
    for index, seat in config.seats:
      let uploadId = config.uploadIdBase + uint64(index)
      let admitted = episode.compilePlane.admitModule(seat, uploadId,
        config.originGeneration, moduleBytes.rawBytes)
      result.add(&"FIRST_LIGHT_PLAY_UPLOAD seat={seat} upload_id={uploadId} " &
        &"accepted={admitted.accepted} status={admitted.statusBytes}")
    if not episode.compilePlane.drainCompileWorkers():
      result.add("FIRST_LIGHT_PLAY_COMPILE drained=false")
      return
    var commits = 0
    while commits < config.seats.len:
      let batch = episode.compilePlane.commitCompileResults()
      if batch.len == 0:
        break
      for commit in batch:
        inc commits
        result.add(&"FIRST_LIGHT_PLAY_COMMIT seat={commit.seat} " &
          &"upload_id={commit.uploadId} terminal={commit.terminal} " &
          &"status={commit.statusBytes}")

    for seat in config.seats:
      let bound = episode.compilePlane.boundModule(seat, config.playName)
      if bound.isNone:
        result.add(&"FIRST_LIGHT_PLAY_CALL seat={seat} accepted=false " &
          "reason=module_not_ready")
        continue
      episode.addBindingFor(bound.get)
      let accepted = episode.ladder.acceptCall(seat,
        config.proposalIdBase + uint64(seat), config.originGeneration, 0,
        config.callBytes, episode.bindings, noGuardContext())
      result.add(&"FIRST_LIGHT_PLAY_CALL seat={seat} accepted={accepted.accepted} " &
        &"epoch={accepted.epoch} reason={accepted.reason} " &
        &"status={accepted.statusBytes}")

else:
  proc configureFirstLightPlay*(episode: var FirstLightEpisode;
      config: FirstLightPlayConfig): seq[string] =
    discard episode
    discard config
    @["FIRST_LIGHT_PLAY configured=false reason=runtime_unavailable " &
      "hint=compile with --threads:on and WASMTIME_C_API"]

proc configureFirstLightDemoPlayFromJson*(episode: var FirstLightEpisode;
    configJson: string; repoRoot = getCurrentDir()): seq[string] =
  let node = firstLightPlayNode(configJson)
  if node == nil:
    return
  try:
    result = episode.configureFirstLightPlay(node.playConfigFromNode(repoRoot))
  except CatchableError as error:
    result = @["FIRST_LIGHT_PLAY configured=false reason=parse_error detail=" &
      error.msg]

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
        inputs[seat] = LadderSeatInput(
          alive: true,
          contextBytes: "{}",
          viewBytes: (if episode.viewSource == nil:
            slot.frame.provisionalFirstLightView(tick)
          else:
            episode.viewSource(seat, tick)),
          guardContext: noGuardContext(),
          defaultIntent: finished.intent,
          defaultGoal: decision.goal)

      let ladderOutput = episode.ladder.tick(inputs, tick, episode.bindings)
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
