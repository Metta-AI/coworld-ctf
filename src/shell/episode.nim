## FIRST LIGHT's gate-on episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## Lane A FL-B supplies the concrete body, belief-lite, navigation, and
## movement-only seatTick. This module owns only the server-side lifecycle,
## default-order installation, mask handoff, annotations, and timing split.

import std/[monotimes, options, strformat, strutils, times]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
import body_nav
import types
import standing_order

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

proc firstLightInventory*(): FirstLightInventory =
  ## FIRST LIGHT is intentionally the zero-guest special case.
  FirstLightInventory()

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
  for index, control in controls:
    if control == scPlay:
      result.enabled = true
      result.seats.add(FirstLightSeatState(seat: uint8(index)))

proc resetFirstLightEpisode*(episode: var FirstLightEpisode,
    season2Shell, brMode: bool, controls: openArray[SlotControl],
    map: BodyMap = nil, liveGunRangePx: int = GunRange) =
  ## Full episode replacement boundary for any server-side sim/config
  ## replacement. Fresh bodies re-run the activation safe install instead of
  ## carrying standing orders, nav state, or map-owned goals across matches.
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
      output.installs.add(annotation.installRecord(
        $state.standing.lastDefaultRule,
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
    if state.active and frame.playing and frame.alive:
      state.body.updateBelief(frame.bodyInputs, tick)
      state.standing.stepFirstLightDefault(state.body, tick,
        frame.defaultFallbacks)
      state.appendStandingChanges(result)
    result.runtimeNanoseconds += (getMonoTime() - runtimeStarted).inNanoseconds

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
