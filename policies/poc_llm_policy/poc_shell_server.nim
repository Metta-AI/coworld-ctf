## PoC play-seat WIRE server: the real CTF server plus the four receive
## consumers and the server→client arm that production has not registered yet.
##
## WHY THIS FILE EXISTS. `src/ctf/server.nim` already owns the whole receive
## path for the Season 2 play-seat packets: the `/player` upgrade with the
## play-seat transport limits, the leading-byte dispatch
## (`classifyPlaySeatMessage`), the bounded per-seat ingress queue, and the
## tick-boundary drain. What it does NOT have is:
##
##   1. any registration of `registerPlayModuleUploadConsumer`,
##      `registerPlayCallConsumer`, `registerPlayStatusAckConsumer`, or
##      `registerPlayLobbyChatConsumer` — so every admitted 0xA0/0xA1/0xA2 is
##      counted into `playProtocolRejected` and dropped; and
##   2. any caller of `trySendPlaySocket` — so 0xB0/0xB1/0xB2 are never sent.
##
## A wire policy therefore cannot get `module_ready`, `call_accepted`, or a
## chat broadcast out of a stock build. This binary supplies exactly that
## missing glue and nothing else: it registers the four consumers, drives the
## PRODUCTION compile plane / module cache / ladder / call validator as the
## oracle, encodes the replies with the PRODUCTION `packets.nim` codec, and
## then hands off to the stock `runServerLoop`.
##
## DELIBERATE PoC LIMITS (see README.md):
##   - Accepted calls are validated and epoch-advanced by the real
##     `LadderDriver`, but the resulting ladder is NOT stepped into the
##     episode's seat bodies; `src/shell/episode.nim` owns that and binds its
##     own config-file play. The wire seat proves admission, not actuation.
##   - `LadderBinding.makeGuest` is nil: `acceptCall` only needs the manifest
##     and content hash, and this server never runs `LadderDriver.tick`.
##   - The 0xB0 control_context is a snapshot built at first contact, and the
##     0xB1 frames are control-only (viewLen = 0) status carriers. No live
##     play_view frames are pumped.
##   - Lobby-chat phase gating, per-phase rate caps, and the transcript
##     replay-on-rebind (§9.2) are not enforced.

import std/[json, locks, options, os, strutils]

import mummy
import bitworld/runtime

import ctf/sim
import ctf/sim_types
import ctf/server

import shell/compile_plane
import shell/guards
import shell/ingress
import shell/ladder
import shell/packets
import shell/transport
import shell/types
import shell/view
import shell/runtime as shell_runtime

const PocGeneration = 1'u64
  ## This PoC never replaces a socket mid-episode, so the seat's control
  ## generation is pinned at its registration value.

type
  SeatWire = object
    present: bool
    greeted: bool
    socket: WebSocket

var
  pocLock: Lock
  seatWires: array[MaxPlayers, SeatWire]
  chatOrdinal: uint64
  pocTick: uint32
  pocConfig: GameConfig
  engine: RuntimeEngine
  plane: CompilePlane
  ladderDriver: LadderDriver
  bindings: seq[LadderBinding]

proc noGuardContext(): IntentContext =
  ## The call validator only compiles guards at accept time; it never needs a
  ## live resolution. A total, constant context keeps validation honest without
  ## importing sim state into this file.
  IntentContext(
    resolveNumber: proc(path: string): float =
      discard path
      0.0,
    resolveBool: proc(path: string): bool =
      discard path
      false)

proc rawBytes(bytes: string): seq[byte] =
  result = newSeq[byte](bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

proc rememberSocket(seat: int, socket: WebSocket) =
  if seat < 0 or seat >= MaxPlayers:
    return
  withLock pocLock:
    seatWires[seat].present = true
    seatWires[seat].socket = socket

proc sendToSeat(seat: int, payload: sink string) =
  ## One packet per WebSocket message, binary, best effort. `false` from the
  ## transport is the protocol's backpressure signal; a PoC just logs it.
  var socket: WebSocket
  var present = false
  withLock pocLock:
    if seat >= 0 and seat < MaxPlayers and seatWires[seat].present:
      socket = seatWires[seat].socket
      present = true
  if not present:
    return
  if not socket.trySendPlaySocket(payload):
    echo "POC_WIRE_BACKPRESSURE seat=", seat

proc controlViewEnvelope(statuses: openArray[string]): string =
  ## The control-only PlayView envelope (`control_view.schema.json`) with the
  ## status entries the production writers already canonicalized for us.
  ## Canonical key order is byte-ascending: counters, gen, schema, statuses, v.
  result = "{\"counters\":{\"backpressure\":0,\"dropped_calls\":0," &
    "\"dropped_chat\":0,\"dropped_uploads\":0,\"faults_dropped\":0}," &
    "\"gen\":\"" & $PocGeneration & "\",\"schema\":\"control_view\""
  if statuses.len > 0:
    result.add(",\"statuses\":[")
    for index, entry in statuses:
      if index > 0:
        result.add(",")
      result.add(entry)
    result.add("]")
  result.add(",\"v\":1}")

proc sendStatuses(seat: int, statuses: varargs[string]) =
  ## Statuses ride a control-only 0xB1 frame (viewLen = 0), which §4.3 defines
  ## as the pre-activation / dead-seat shape.
  let packet = PlayViewPacket(
    tick: pocTick,
    control: controlViewEnvelope(statuses),
    view: "")
  sendToSeat(seat, encodePacket(packet))
  for entry in statuses:
    echo "POC_WIRE_STATUS seat=", seat, " ", entry

proc playbookJson(seat: int): string =
  ## `control_context.playbook`: every name this seat has bound, with its
  ## content hash. Names are emitted in the order the PoC uploads them; the
  ## schema does not require a sort.
  var rows: seq[string]
  for name in ["edge_ride", "pact"]:
    let bound = plane.boundModule(seat, name)
    if bound.isSome:
      rows.add("{\"name\":\"" & name & "\",\"sha256\":\"" & bound.get.hash &
        "\",\"state\":\"ready\"}")
  if rows.len == 0:
    return ""
  result = "["
  for index, row in rows:
    if index > 0:
      result.add(",")
    result.add(row)
  result.add("]")

proc controlContextEnvelope(seat: int): string =
  ## `control_context.schema.json` in canonical key order: ack_mark, budgets,
  ## epoch, floors, gen, lobby_transcript_mark, playbook, schema, v.
  let epoch = ladderDriver.seatEpoch(seat)
  let playbook = playbookJson(seat)
  result = "{\"ack_mark\":\"0\",\"budgets\":{\"modules_left\":" &
    $MaxModulesPerSeatPerEpisode & ",\"upload_bytes_left\":" &
    $MaxUploadBytesPerSeatPerEpisode & "},\"epoch\":\"" & $epoch &
    "\",\"floors\":{\"proposal_id\":\"0\",\"upload_id\":\"0\"},\"gen\":\"" &
    $PocGeneration & "\",\"lobby_transcript_mark\":\"" & $chatOrdinal & "\""
  if playbook.len > 0:
    result.add(",\"playbook\":" & playbook)
  result.add(",\"schema\":\"control_context\",\"v\":1}")

proc mapField(spec: JsonNode, key: string, fallback: int): int =
  if spec == nil or spec.kind != JObject or key notin spec:
    return fallback
  spec[key].getInt(fallback)

proc playContextEnvelope(seat: int): string =
  ## Built with the production `view.nim` writer so the bytes a real policy
  ## sees here are the bytes the real producer would emit.
  var spec: JsonNode = nil
  if pocConfig.mapSpec.len > 0:
    try:
      spec = parseJson(pocConfig.mapSpec)
    except CatchableError:
      spec = nil
  var source = PlayContextSource(
    mode: if pocConfig.brMode: gmBr else: gmCtf,
    mapName: (if spec != nil and "name" in spec: spec["name"].getStr()
              else: pocConfig.mapPath),
    mapWidth: spec.mapField("width", 1024),
    mapHeight: spec.mapField("height", 1024),
    selfSeat: seat,
    selfTeam: pocConfig.slots[seat].team,
    gunRange: pocConfig.gunRange,
    viewInterval: pocConfig.viewIntervalTicks)
  if pocConfig.brMode:
    # Duos are seat pairs in the BR roster; the PoC reads the partner off the
    # pairing rather than the sim, which does not expose it on this seam.
    source.duoPartner = some(seat xor 1)
  for index, slot in pocConfig.slots:
    source.roster.add(PlayContextRosterRow(
      seat: index,
      team: slot.team,
      control: if slot.control == scPlay: pccPlay else: pccInput))
  buildPlayContext(source)

proc greet(seat: int) =
  var needsGreeting = false
  withLock pocLock:
    if seat >= 0 and seat < MaxPlayers and seatWires[seat].present and
        not seatWires[seat].greeted:
      seatWires[seat].greeted = true
      needsGreeting = true
  if not needsGreeting:
    return
  let packet = PlayContextPacket(
    control: controlContextEnvelope(seat),
    context: playContextEnvelope(seat))
  sendToSeat(seat, encodePacket(packet))
  echo "POC_WIRE_CONTEXT seat=", seat, " bytes=", packet.context.len

proc bindReadyModule(seat: int, name: string) =
  ## Publishes a committed module as a ladder binding so `acceptCall` can
  ## resolve the play name to its manifest and content hash. `makeGuest` stays
  ## nil: this server validates and epoch-advances calls, it does not step
  ## them (see the file header).
  let bound = plane.boundModule(seat, name)
  if bound.isNone:
    return
  for binding in bindings:
    if binding.manifest.name == name:
      return
  bindings.add(LadderBinding(
    manifest: bound.get.manifest,
    hash: bound.get.hash,
    ready: true,
    makeGuest: nil))
  echo "POC_WIRE_BOUND name=", name, " sha256=", bound.get.hash

proc onModuleUpload(socket: WebSocket, seat: int,
                    packet: ModuleUploadPacket) {.gcsafe.} =
  {.cast(gcsafe).}:
    rememberSocket(seat, socket)
    let admitted = plane.admitModule(seat, packet.uploadId, PocGeneration,
      packet.wasm.rawBytes)
    echo "POC_WIRE_UPLOAD seat=", seat, " upload_id=", packet.uploadId,
      " bytes=", packet.wasm.len, " accepted=", admitted.accepted
    if admitted.statusBytes.len > 0:
      sendStatuses(seat, admitted.statusBytes)
    if not admitted.accepted:
      return
    # The compile plane is worker-backed; a PoC drains it synchronously so the
    # module_ready status rides the same tick as the upload.
    if not plane.drainCompileWorkers():
      echo "POC_WIRE_COMPILE drained=false"
      return
    for commit in plane.commitCompileResults():
      echo "POC_WIRE_COMMIT seat=", commit.seat, " upload_id=", commit.uploadId,
        " terminal=", commit.terminal
      if commit.statusBytes.len > 0:
        sendStatuses(commit.seat, commit.statusBytes)
    for name in ["edge_ride", "pact"]:
      bindReadyModule(seat, name)

proc onPlayCall(socket: WebSocket, seat: int,
                packet: PlayCallPacket) {.gcsafe.} =
  {.cast(gcsafe).}:
    rememberSocket(seat, socket)
    let accepted = ladderDriver.acceptCall(seat, packet.proposalId,
      PocGeneration, pocTick, packet.callBytes, bindings, noGuardContext())
    echo "POC_WIRE_CALL seat=", seat, " proposal_id=", packet.proposalId,
      " accepted=", accepted.accepted, " epoch=", accepted.epoch,
      " reason=", accepted.reason, " path=", accepted.path
    if accepted.statusBytes.len > 0:
      sendStatuses(seat, accepted.statusBytes)

proc onStatusAck(socket: WebSocket, seat: int,
                 packet: StatusAckPacket): PlayIngressFeedback {.gcsafe.} =
  ## The ack doubles as this PoC's per-tick pump: it opens the compile plane's
  ## tick window and delivers the one-shot 0xB0 on first contact. Production
  ## would open that window from the tick loop itself.
  {.cast(gcsafe).}:
    rememberSocket(seat, socket)
    inc pocTick
    plane.beginTick()
    greet(seat)
    discard packet
    PlayIngressFeedback()

proc onLobbyChat(socket: WebSocket, seat: int,
                 packet: LobbyChatSendPacket) {.gcsafe.} =
  ## Runs on Mummy's handler thread, so it touches only the lock-guarded
  ## socket registry and the ordinal counter.
  {.cast(gcsafe).}:
    rememberSocket(seat, socket)
    var ordinal: uint64
    var targets: seq[int]
    withLock pocLock:
      inc chatOrdinal
      ordinal = chatOrdinal
      for index in 0 ..< MaxPlayers:
        if seatWires[index].present:
          targets.add(index)
    let broadcast = LobbyChatBroadcastPacket(
      ordinal: ordinal,
      tick: pocTick,
      seat: uint8(seat),
      team: uint8(ord(pocConfig.slots[seat].team)),
      text: packet.text)
    let payload = encodePacket(broadcast)
    for target in targets:
      sendToSeat(target, payload)
    echo "POC_WIRE_CHAT ordinal=", ordinal, " seat=", seat,
      " targets=", targets.len, " text=", packet.text

proc installPocWire(config: GameConfig) =
  initLock(pocLock)
  pocConfig = config
  engine = newRuntimeEngine()
  plane = newCompilePlane(engine, config.slots.len)
  ladderDriver = newLadderDriver(config.slots.len, DefaultPathRegistry,
    if config.brMode: gmBr else: gmCtf, nil)
  registerPlayModuleUploadConsumer(onModuleUpload)
  registerPlayCallConsumer(onPlayCall)
  registerPlayStatusAckConsumer(onStatusAck)
  registerPlayLobbyChatConsumer(onLobbyChat)
  echo "POC_WIRE_READY seats=", config.slots.len,
    " season2Shell=", config.season2Shell

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  config.update(runtimeConfig.config)
  if not config.season2Shell:
    quit("poc_shell_server requires a season2Shell config (gate on)", 1)
  installPocWire(config)
  echo "poc shell server on ", runtimeConfig.host, ":", runtimeConfig.port
  runServerLoop(runtimeConfig.host, runtimeConfig.port, config, "", "", "",
    runtimeConfig)
