## FIRST LIGHT's gate-on episode owner: lifecycle, standing-order handoff,
## ordinary InputState masks, annotations, and split body/runtime timings.
##
## Lane A FL-B is not landed. This module deliberately runs only through the
## PM-frozen ADOPT-ON-RELAY operations in standing_order. In particular it has
## no movement, pathfinding, or Intent-to-mask translation; today's seatTick
## returns the no-op/hold mask supplied by BodyTickInputs.

import std/[monotimes, options, strformat, strutils, times]
import bitworld/spriteprotocol
import ../ctf/sim_types
import body_map
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
    ## One coherent tick-boundary handoff. The placeholder snapshot and
    ## partner value are replaced by lane A's owner reads on FL-B relay.
    seat*: uint8
    playerIndex*: int
    present*: bool
    playing*: bool
    alive*: bool
    snapshot*: LaneABrSnapshot
    partner*: PartnerTelemetry
    bodyInputs*: BodyTickInputs

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
    seats*: seq[FirstLightSeatState]

proc firstLightInventory*(): FirstLightInventory =
  ## FIRST LIGHT is intentionally the zero-guest special case.
  FirstLightInventory()

proc initFirstLightEpisode*(season2Shell, brMode: bool,
    controls: openArray[SlotControl],
    map: BodyMap = nil): FirstLightEpisode =
  result.brMode = brMode
  result.map = map
  if not season2Shell:
    return
  for index, control in controls:
    if control == scPlay:
      result.enabled = true
      result.seats.add(FirstLightSeatState(seat: uint8(index)))

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
    annotations: var seq[ShellAnnotation]) =
  annotations.add(ShellAnnotation(
    tick: tick,
    seat: state.seat,
    kind: akClearOnDeath,
    clearGeneration: 0))
  state.active = false
  state.standing = StandingOrderState()
  # Lane A's park/clear lifecycle body replaces this direct reset on FL-A.
  # This is not a new seam and carries no executor behavior.
  state.body = activateSeatBody(state.body.map, state.seat)

proc activate(state: var FirstLightSeatState, frame: FirstLightSeatFrame,
    tick: uint32, reason: string, map: BodyMap,
    output: var FirstLightTickResult) =
  state.body = activateSeatBody(map, state.seat)
  state.body.brSnapshot = frame.snapshot
  state.body.partner = frame.partner
  let safe = safeIntent(reason, frame.snapshot.idleAimCenterBrads)
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
      state.resetAfterDeath(tick, result.annotations)
      if episode.brMode:
        state.eliminated = true
    if frame.playing and frame.alive and not state.active and
        not state.eliminated:
      state.activate(frame, tick,
        if state.everActivated: "respawn" else: "activation",
        episode.map, result)
    if state.active and frame.playing and frame.alive:
      state.body.brSnapshot = frame.snapshot
      state.body.partner = frame.partner
      state.standing.stepFirstLightDefault(state.body, tick)
      state.appendStandingChanges(result)
    result.runtimeNanoseconds += (getMonoTime() - runtimeStarted).inNanoseconds

    # Every present play seat hands one mask to the caller each tick. With the
    # phase-14 placeholder seatTick this is deliberately the all-zero hold.
    var input = frame.bodyInputs.input
    if state.active and frame.playing and frame.alive:
      let bodyStarted = getMonoTime()
      input = seatTick(state.body, frame.bodyInputs, tick)
      result.bodyNanoseconds += (getMonoTime() - bodyStarted).inNanoseconds
    result.masks.add(FirstLightMask(
      seat: state.seat, playerIndex: frame.playerIndex, input: input))

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
        state.resetAfterDeath(tick, result)
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
