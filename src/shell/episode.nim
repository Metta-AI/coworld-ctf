## FIRST LIGHT's play-seat episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## Lane A supplies the concrete body, belief-lite, navigation, and seatTick
## actuation. This module owns only the server-side lifecycle,
## default-order installation, mask handoff, annotations, and timing split.

import std/[json, math, monotimes, options, os, sequtils, strformat, strutils, times]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
import body_nav
import reflexes
import replay_records
import types
import standing_order
import body
# `view` needs no runtime (std, sim_types, body, body_map, canonical_fast,
# finisher, types only) and server.nim imports it unconditionally; keeping
# it under the runtime guard once hid PlayContextRosterRow from the stub
# shape (CI run 33597295995).
import view

const ShellRuntimeAvailable* =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0

when ShellRuntimeAvailable:
  import binary_view, call_validation, canonical, compile_plane, emit_validator,
    guards, instance, ladder, runtime

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

  FirstLightNavSummary* = object
    ## Per-tick follower census over active, alive play seats; the server
    ## prints it as FIRST_LIGHT_NAV so plan-budget events can be joined by
    ## tick to what the followers were doing.
    pendingPlans*: int            ## seats whose cold plan is still computing
    stalePathSeats*: seq[uint8]   ## walking an older route while a plan computes
    noPathSeats*: seq[uint8]      ## navigate order, not arrived, no route loaded

  FirstLightCombatSummary* = object
    ## Per-tick weapon-path census over active, alive play seats; the server
    ## prints it as FIRST_LIGHT_COMBAT. The seat lists name the outcomes an
    ## operator most needs to chase: a neutral policy with an enemy in range,
    ## fresh tracks with nothing shootable, and a held target not yet fired on.
    counts*: array[CombatOutcome, int]
    noPolicyEnemyInRangeSeats*: seq[uint8]
    noneShootableSeats*: seq[uint8]
    aligningSeats*: seq[uint8]

  FirstLightHandoff* = object
    ## §4.1 amendment: one seat's STANDING give-item declaration this tick —
    ## the Intent's `handoff` field lifted off the installed standing order
    ## ("" = no declaration wanted). The episode never touches the sim: the
    ## server hook compares this against the sim's declared state and calls
    ## the sim.declareHandoff consent seam (recording exactly what the sim
    ## accepted), the same division of labor as the mask handoff above it.
    seat*: uint8
    playerIndex*: int
    item*: string

  FirstLightTickResult* = object
    masks*: seq[FirstLightMask]
    handoffs*: seq[FirstLightHandoff]
    annotations*: seq[ShellAnnotation]
    installs*: seq[FirstLightInstall]
    moduleStatuses*: seq[FirstLightModuleStatus]
    ladderStatuses*: seq[FirstLightLadderStatus]
    retuned*: seq[FirstLightEntryIdentity]
    planBudget*: seq[PlanBudgetEvent]
    nav*: FirstLightNavSummary
    combat*: FirstLightCombatSummary
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

when ShellRuntimeAvailable:
  proc firstLightPlayViewSource(episode: FirstLightEpisode; seatIndex: int;
                                tick: uint32): Option[PlayViewSource] =
    ## The one fogged per-seat view source. Both encoders below MUST feed
    ## from here so the guest and the socket can never observe different
    ## worlds for one seat at one tick.
    let frame = episode.frameForSeat(seatIndex)
    if frame.isNone:
      return none(PlayViewSource)
    for state in episode.seats:
      if state.active and state.seat.int == seatIndex:
        let fallbacks = frame.get.defaultFallbacks
        return some(playViewSourceFromBody(
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
            dps: fallbacks.zoneDps))))
    none(PlayViewSource)

proc firstLightViewBytes*(episode: FirstLightEpisode; seatIndex: int;
                          tick: uint32): string =
  ## The GUEST's copy: the fixed-layout PV1 binary frame (the 2026-08-31
  ## lane-C ruling — a wasm play reads fields as aligned loads, not JSON).
  when ShellRuntimeAvailable:
    let source = episode.firstLightPlayViewSource(seatIndex, tick)
    if source.isNone:
      return "{}"
    buildBinaryPlayView(source.get)
  else:
    discard episode
    discard seatIndex
    discard tick
    "{}"

proc firstLightSocketViewBytes*(episode: FirstLightEpisode; seatIndex: int;
                                tick: uint32): string =
  ## The SOCKET's copy of the same view: JSON, per the ratified 0xB1 wire
  ## contract ("u8[viewLen] view JSON" — play-calling shell design §3.2 wire
  ## table; play_view.schema.json: "the encoded payload is always valid
  ## JSON") and the binary-frame ruling's own boundary ("the play's copy
  ## ... becomes a fixed-layout binary frame; JSON stays for the socket and
  ## replay copies"). Wiring the PV1 binary frame here instead is what every
  ## conforming policy client (starter_harness/wire.py: json.loads on the
  ## view payload) crashes on at the round's first live view.
  when ShellRuntimeAvailable:
    let source = episode.firstLightPlayViewSource(seatIndex, tick)
    if source.isNone:
      return "{}"
    buildPlayView(source.get)
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
    viewInterval = ViewIntervalTicksDefault,
    names: openArray[string] = []): FirstLightEpisode =
  ## `names` are the seats' display names in seat order (the closed
  ## roster's players[].name); empty means the context carries none.
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
      result.contextRoster = playContextRosterRows(controls, teams, names)
    result.runtimeState = FirstLightRuntimeState(
      frames: newSeq[FirstLightViewFrameSlot](controls.len),
      selfPositions: newSeq[BodyPoint](controls.len),
      reflexStates: newSeq[ReflexSeatState](controls.len))
  for index, control in controls:
    if control == scPlay:
      result.enabled = true
      result.seats.add(FirstLightSeatState(seat: uint8(index)))

proc playContextRoster*(episode: FirstLightEpisode): seq[PlayContextRosterRow] =
  ## The roster every seat's PlayContext carries (seat order), for tests and
  ## diagnostics; empty in the stub shape and until a Season 2 episode with
  ## team facts exists.
  when ShellRuntimeAvailable:
    episode.contextRoster
  else:
    @[]

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
    viewInterval = ViewIntervalTicksDefault,
    names: openArray[string] = []) =
  ## Full episode replacement boundary for any server-side sim/config
  ## replacement. Fresh bodies re-run the activation safe install instead of
  ## carrying standing orders, nav state, or map-owned goals across matches.
  episode.closeFirstLightEpisode()
  episode = initFirstLightEpisode(season2Shell, brMode, controls, map,
    liveGunRangePx, teams, mapName, viewInterval, names)

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
    ## For seats with no body this tick (absent, dead, not playing). Every
    ## path reads 0.0 / false; a live seat gets playGuardContext instead.
    IntentContext(
      resolveNumber: proc(path: string): float =
        discard path
        0.0,
      resolveBool: proc(path: string): bool =
        discard path
        false)

  proc pointDistancePx(a, b: BodyPoint): float =
    let dx = float(a.x - b.x)
    let dy = float(a.y - b.y)
    sqrt(dx * dx + dy * dy)

  proc rectEdgeDistancePx(point: BodyPoint, rect: MapRect): float =
    ## 0 inside the rect; otherwise the straight-line distance to it.
    let dx = max(max(rect.x - point.x, 0), point.x - (rect.x + rect.w - 1))
    let dy = max(max(rect.y - point.y, 0), point.y - (rect.y + rect.h - 1))
    sqrt(float(dx * dx + dy * dy))

  proc playGuardContext*(body: SeatBody, facts: BrDefaultFacts): IntentContext =
    ## The registered guard paths (src/ctf/policy_page.nim DefaultPaths)
    ## resolved from this seat's own fogged body state -- the same facts the
    ## plays read -- so a call's `when` guard evaluates over the live view as
    ## the design promises. Before this, every play seat got noGuardContext()
    ## and a guard like `self.hp_frac < 0.8` was always true.
    ##
    ## Sentinels follow the registry's contract: -1 where "never observed"
    ## (partner.dist, nearest_enemy_dist, weakest_enemy_hp, medkit_dist,
    ## item_dist), 0 for zone_dist when inside. The `intent.*` paths describe
    ## a candidate intent being scored and have no meaning for a ladder
    ## guard; they resolve to 0 / false.
    let selfPos = body.selfState.pos
    var enemyCount = 0
    var nearestEnemy = -1.0
    var weakestEnemy = -1.0
    var partnerInCombat = false
    let partner = facts.partner
    for track in body.tracks:
      if track.isNone:
        continue
      inc enemyCount
      let d = pointDistancePx(selfPos, track.get.pos)
      if nearestEnemy < 0 or d < nearestEnemy:
        nearestEnemy = d
      if track.get.hpKnown.isSome:
        let hp = float(track.get.hpKnown.get)
        if weakestEnemy < 0 or hp < weakestEnemy:
          weakestEnemy = hp
      if partner.isSome and partner.get.alive and
          pointDistancePx(partner.get.pos, track.get.pos) <= 200.0:
        partnerInCombat = true
    var medkitDist = -1.0
    var itemDist = -1.0
    for item in body.items:
      if not item.present:
        continue
      let d = pointDistancePx(selfPos, item.pos)
      if item.kind == bikMedkit:
        if medkitDist < 0 or d < medkitDist:
          medkitDist = d
      elif itemDist < 0 or d < itemDist:
        itemDist = d
    let hasZone = facts.currentZone.w > 0 and facts.currentZone.h > 0
    let zoneDist = if hasZone: rectEdgeDistancePx(selfPos, facts.currentZone)
      else: 0.0
    let inZone = (not hasZone) or zoneDist <= 0.0
    let hpFrac = body.selfState.hpFrac
    let partnerAlive = partner.isSome and partner.get.alive
    let partnerDist = if partner.isSome: pointDistancePx(selfPos, partner.get.pos)
      else: -1.0
    IntentContext(
      resolveNumber: proc(path: string): float =
        case path
        of "self.hp_frac": hpFrac
        of "partner.dist": partnerDist
        of "world.enemy_count": float(enemyCount)
        of "world.nearest_enemy_dist": nearestEnemy
        of "world.weakest_enemy_hp": weakestEnemy
        of "world.zone_dist": zoneDist
        of "world.medkit_dist": medkitDist
        of "world.item_dist": itemDist
        of "intent.target_hp", "intent.target_dist": -1.0
        else: 0.0,
      resolveBool: proc(path: string): bool =
        case path
        of "partner.alive": partnerAlive
        of "partner.in_combat": partnerInCombat
        of "world.in_zone": inZone
        else: false)

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

proc summarizeSeatTick(body: SeatBody, result: var FirstLightTickResult) =
  ## Folds one seat's follower and weapon-path outcomes into the tick census.
  let seat = uint8(body.seatIndex)
  case body.navState
  of bnsStalePath: result.nav.stalePathSeats.add seat
  of bnsNoPath: result.nav.noPathSeats.add seat
  of bnsIdle, bnsFollowing: discard
  inc result.combat.counts[body.combatOutcome]
  case body.combatOutcome
  of coNoPolicyEnemyInRange: result.combat.noPolicyEnemyInRangeSeats.add seat
  of coNoneShootable: result.combat.noneShootableSeats.add seat
  of coAligning: result.combat.aligningSeats.add seat
  of coNoPolicy, coNoEnemy, coVetoed, coFired: discard

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
          guardContext: playGuardContext(state.body, facts),
          defaultIntent: finished.intent,
          defaultGoal: decision.goal,
          nativeBase: reflexDecision.nativeBase)

      let ladderOutput = episode.ladder.tick(inputs, tick, episode.bindings)
      for row in ladderOutput.seats:
        for status in row.statuses:
          result.ladderStatuses.add status.ladderStatus
          if status.status.kind == skPlayFaulted:
            # The fault is minted into the annotation stream so the replay
            # and the server log both say WHY the provenance switched on this
            # tick; the standing-order annotation that follows says to what.
            result.annotations.add(ShellAnnotation(
              tick: tick,
              seat: uint8(row.seat),
              kind: akPlayFault,
              faultAtEpoch: status.status.faultEpoch,
              faultEntryId: status.entryId,
              annotationFaultReason: status.status.faultReason))
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
      summarizeSeatTick(state.body, result)
      # §4.1 amendment: surface the standing order's give-item declaration
      # beside the mask it was resolved with. Upright seats only — a dead
      # seat's declaration dies sim-side with the life that made it, and
      # the consent seam refuses dead/downed seats anyway.
      if state.standing.hasStanding:
        result.handoffs.add(FirstLightHandoff(
          seat: state.seat,
          playerIndex: frame.playerIndex,
          item: state.standing.intent.handoff))
    result.masks.add(FirstLightMask(
      seat: state.seat, playerIndex: frame.playerIndex, input: input))
  episode.nav.rebuildScheduledDanger(tick.int, episode.dangerInputs(tick))
  discard episode.nav.runPlanningTick(tick.int)
  result.planBudget = episode.nav.drainPlanBudgetEvents()
  result.nav.pendingPlans = episode.nav.pendingPlanCount()

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

proc seatDisplayName*(episode: FirstLightEpisode, seat: int): string =
  ## The seat's roster display name, or "" when the episode has none.
  when ShellRuntimeAvailable:
    for row in episode.contextRoster:
      if row.seat == seat:
        return row.name
  ""

proc seatList(seats: seq[uint8]): string =
  "[" & seats.mapIt($it).join(",") & "]"

proc formatPlanBudgetEvent*(event: PlanBudgetEvent): string =
  let outcome =
    case event.outcome
    of pboSuspended: "suspended"
    of pboCompleted: "completed"
    of pboFailed: "failed"
  &"FIRST_LIGHT_PLAN_BUDGET tick={event.tick} seat={event.seat} " &
    &"revision={event.revision} visits={event.visits} units={event.units} " &
    &"outcome={outcome}"

proc formatNavSummary*(tick: uint32, nav: FirstLightNavSummary): string =
  &"FIRST_LIGHT_NAV tick={tick} pending_plans={nav.pendingPlans} " &
    &"stale_path={nav.stalePathSeats.seatList} " &
    &"no_path={nav.noPathSeats.seatList}"

proc formatCombatSummary*(tick: uint32,
                          combat: FirstLightCombatSummary): string =
  &"FIRST_LIGHT_COMBAT tick={tick} fired={combat.counts[coFired]} " &
    &"aligning={combat.counts[coAligning]} " &
    &"none_shootable={combat.counts[coNoneShootable]} " &
    &"vetoed={combat.counts[coVetoed]} no_enemy={combat.counts[coNoEnemy]} " &
    &"no_policy={combat.counts[coNoPolicy]} " &
    &"no_policy_enemy_in_range={combat.counts[coNoPolicyEnemyInRange]} " &
    &"no_policy_enemy_in_range_seats={combat.noPolicyEnemyInRangeSeats.seatList} " &
    &"none_shootable_seats={combat.noneShootableSeats.seatList} " &
    &"aligning_seats={combat.aligningSeats.seatList}"

proc formatLifecycleAnnotation*(annotation: ShellAnnotation,
                                player = ""): string =
  ## `player` is the seat's display name; it is printed only when known.
  let playerField = if player.len > 0: &" player={player.escape}" else: ""
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
    &"FIRST_LIGHT_ANNOTATION tick={annotation.tick} seat={annotation.seat}" &
      &"{playerField} kind=play_fault epoch={annotation.faultAtEpoch} " &
      &"entry={annotation.faultEntryId} " &
      &"reason={annotation.annotationFaultReason.escape}"
