## Bounded tick-boundary ingress for play-seat uploads and calls.
##
## This module owns transport-era identity, count/byte budgets, idempotency,
## and status-capacity reservations. Payload validation and content hashing
## belong to the runtime consumer on the other side of the server seam.

import std/tables

import ./[packets, seats, types]

type
  PlayIngressCounters* = object
    droppedUploads*: uint32
    droppedCalls*: uint32
    backpressure*: uint32
    feedbackErrors*: uint32

  PlayIngressMessageKind* = enum
    pimUpload
    pimCall

  PlayIngressMessage*[Socket] = object
    socket*: Socket
    generation*: uint64
    case kind*: PlayIngressMessageKind
    of pimUpload:
      upload*: ModuleUploadPacket
    of pimCall:
      call*: PlayCallPacket

  PlayIngressInspectResult* = enum
    piiAllowed
    piiStale
    piiDisconnect

  PlayIngressQueueResult* = enum
    piqQueued
    piqDropped

  PlayIngressFeedback* = object
    ## Lane C reports only outcomes whose retained status entries have been
    ## retired. Proposal ids name calls whose complete outcome set is gone;
    ## still-in-flight calls must not appear here.
    statusSlotsRetired*: int
    retiredProposalIds*: seq[uint64]

  PlayIngressAck*[Socket] = object
    present*: bool
    socket*: Socket
    generation*: uint64
    packet*: StatusAckPacket

  PlayIngressSeat*[Socket] = object
    binding*: PlaySeatBinding[Socket]
    playerIndex*: int
    counters*: PlayIngressCounters
    admittedModules*: int
    admittedUploadBytes*: uint64
    reservedStatusSlots*: int
    hasUploadIdFloor*: bool
    uploadIdFloor*: uint64
    hasProposalIdFloor*: bool
    proposalIdFloor*: uint64
    pending: seq[PlayIngressMessage[Socket]]
    queuedUploads: int
    queuedCalls: int
    classifiedMessages: int
    classifiedBytes: uint64
    pendingAck: PlayIngressAck[Socket]
    uploadPayloads: Table[uint64, string]
    callPayloads: Table[uint64, string]

  PlayIngressDrain*[Socket] = object
    admitted*: seq[PlayIngressMessage[Socket]]
    rejected*: int

const
  RegularStatusCapacity = MaxRetainedStatusEntries - StatusFaultReserve
  UploadStatusReservation = 2
  CallStatusReservation = 1 + MaxLadderEntries

proc saturatingInc(value: var uint32) =
  if value < high(uint32):
    inc value

proc initPlayIngressSeat*[Socket](): PlayIngressSeat[Socket] =
  result.binding = initPlaySeatBinding[Socket]()
  result.playerIndex = -1
  result.uploadPayloads = initTable[uint64, string]()
  result.callPayloads = initTable[uint64, string]()

proc inspectPlayMessage*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  byteCount: int,
): PlayIngressInspectResult =
  if not seat.binding.admits(socket, generation):
    return piiStale
  if byteCount < 0 or
      seat.classifiedMessages >= MaxMessagesClassifiedPerSeatPerTick or
      uint64(byteCount) > uint64(MaxBytesClassifiedPerSeatPerTick) -
        seat.classifiedBytes:
    seat.pending.setLen(0)
    seat.queuedUploads = 0
    seat.queuedCalls = 0
    discard seat.binding.lose(socket)
    return piiDisconnect
  inc seat.classifiedMessages
  seat.classifiedBytes += uint64(byteCount)
  piiAllowed

proc queueUpload*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: sink ModuleUploadPacket,
): PlayIngressQueueResult =
  if seat.queuedUploads >= MaxUploadsPerSeatPerTick:
    seat.counters.droppedUploads.saturatingInc()
    return piqDropped
  inc seat.queuedUploads
  seat.pending.add(PlayIngressMessage[Socket](
    kind: pimUpload,
    socket: socket,
    generation: generation,
    upload: move(packet)))
  piqQueued

proc queueCall*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: sink PlayCallPacket,
): PlayIngressQueueResult =
  if seat.queuedCalls >= MaxCallsPerSeatPerTick:
    seat.counters.droppedCalls.saturatingInc()
    return piqDropped
  inc seat.queuedCalls
  seat.pending.add(PlayIngressMessage[Socket](
    kind: pimCall,
    socket: socket,
    generation: generation,
    call: move(packet)))
  piqQueued

proc queueStatusAck*[Socket](
  seat: var PlayIngressSeat[Socket],
  socket: Socket,
  generation: uint64,
  packet: StatusAckPacket,
) =
  ## StatusAck owns one coalescing slot inside the total classification
  ## budget. The greatest well-formed mark is sufficient because marks are
  ## cumulative high-water acknowledgements.
  if not seat.pendingAck.present or packet.mark > seat.pendingAck.packet.mark:
    seat.pendingAck = PlayIngressAck[Socket](
      present: true,
      socket: socket,
      generation: generation,
      packet: packet)

proc takeStatusAck*[Socket](
  seat: var PlayIngressSeat[Socket],
): PlayIngressAck[Socket] =
  result = seat.pendingAck
  seat.pendingAck.present = false
  if result.present and
      not seat.binding.admits(result.socket, result.generation):
    result.present = false

proc applyPlayIngressFeedbackStrict*[Socket](
  seat: var PlayIngressSeat[Socket],
  feedback: PlayIngressFeedback,
) =
  if feedback.statusSlotsRetired < 0 or
      feedback.statusSlotsRetired > seat.reservedStatusSlots:
    raise newException(ValueError,
      "play ingress feedback retires unreserved status capacity")
  for proposalId in feedback.retiredProposalIds:
    if proposalId notin seat.callPayloads:
      raise newException(ValueError,
        "play ingress feedback retires an unknown proposal")
  seat.reservedStatusSlots -= feedback.statusSlotsRetired
  for proposalId in feedback.retiredProposalIds:
    seat.callPayloads.del(proposalId)

proc applyPlayIngressFeedback*[Socket](
  seat: var PlayIngressSeat[Socket],
  feedback: PlayIngressFeedback,
): int =
  ## Production feedback is fail-safe: bad retirement accounting must reduce
  ## capacity to honest backpressure, never terminate the tick/runtime thread.
  var retired = feedback.statusSlotsRetired
  if retired < 0:
    retired = 0
    inc result
  elif retired > seat.reservedStatusSlots:
    retired = seat.reservedStatusSlots
    inc result
  seat.reservedStatusSlots -= retired
  for proposalId in feedback.retiredProposalIds:
    if proposalId in seat.callPayloads:
      seat.callPayloads.del(proposalId)
    else:
      inc result
  for _ in 0 ..< result:
    seat.counters.feedbackErrors.saturatingInc()

proc hasCallPayload*[Socket](
  seat: PlayIngressSeat[Socket],
  proposalId: uint64,
): bool =
  proposalId in seat.callPayloads

proc reserve[Socket](seat: var PlayIngressSeat[Socket], count: int): bool =
  if count > RegularStatusCapacity - seat.reservedStatusSlots:
    seat.counters.backpressure.saturatingInc()
    return false
  seat.reservedStatusSlots += count
  true

proc admitUpload[Socket](
  seat: var PlayIngressSeat[Socket],
  message: sink PlayIngressMessage[Socket],
  drain: var PlayIngressDrain[Socket],
) =
  let packet = message.upload
  if packet.uploadId in seat.uploadPayloads:
    if seat.uploadPayloads[packet.uploadId] != packet.wasm:
      inc drain.rejected
    return
  if seat.hasUploadIdFloor and packet.uploadId <= seat.uploadIdFloor:
    inc drain.rejected
    return
  if seat.admittedModules >= MaxModulesPerSeatPerEpisode or
      uint64(packet.wasm.len) >
        uint64(MaxUploadBytesPerSeatPerEpisode) - seat.admittedUploadBytes:
    inc drain.rejected
    return
  if not seat.reserve(UploadStatusReservation):
    return
  inc seat.admittedModules
  seat.admittedUploadBytes += uint64(packet.wasm.len)
  seat.hasUploadIdFloor = true
  seat.uploadIdFloor = packet.uploadId
  seat.uploadPayloads[packet.uploadId] = packet.wasm
  drain.admitted.add(move(message))

proc admitCall[Socket](
  seat: var PlayIngressSeat[Socket],
  message: sink PlayIngressMessage[Socket],
  drain: var PlayIngressDrain[Socket],
) =
  let packet = message.call
  if packet.proposalId in seat.callPayloads:
    if seat.callPayloads[packet.proposalId] != packet.callBytes:
      inc drain.rejected
    return
  if seat.hasProposalIdFloor and packet.proposalId <= seat.proposalIdFloor:
    inc drain.rejected
    return
  if not seat.reserve(CallStatusReservation):
    return
  seat.hasProposalIdFloor = true
  seat.proposalIdFloor = packet.proposalId
  seat.callPayloads[packet.proposalId] = packet.callBytes
  drain.admitted.add(move(message))

proc drainPlayIngress*[Socket](
  seat: var PlayIngressSeat[Socket],
): PlayIngressDrain[Socket] =
  let pending = move(seat.pending)
  seat.pending = @[]
  seat.queuedUploads = 0
  seat.queuedCalls = 0
  seat.classifiedMessages = 0
  seat.classifiedBytes = 0
  for message in pending:
    if not seat.binding.admits(message.socket, message.generation):
      continue
    case message.kind
    of pimUpload:
      seat.admitUpload(message, result)
    of pimCall:
      seat.admitCall(message, result)

proc pendingCount*[Socket](seat: PlayIngressSeat[Socket]): int =
  seat.pending.len
