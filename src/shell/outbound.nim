## Bounded server-to-policy state for one Season 2 play seat.
##
## This module owns no socket I/O. The CTF adapter asks it for canonical
## control envelopes and advances its context/transcript cursors only after
## `trySendPlaySocket` accepts the corresponding packet. That keeps Mummy's
## bounded pipeline as the single outbound queue.

import std/options

import ./[canonical_fast, module_cache, types]

type
  PlayControlCounters* = object
    droppedUploads*: uint32
    droppedCalls*: uint32
    droppedChat*: uint32
    faultsDropped*: uint32
    backpressure*: uint32

  PlayContextAcceptedCall* = object
    proposalId*: uint64
    bytes*: string

  PlayContextReadyModule* = object
    name*: string
    sha256*: string

  PlayContextRecovery* = object
    generation*: uint64
    epoch*: uint64
    uploadIdFloor*: uint64
    proposalIdFloor*: uint64
    modulesLeft*: int
    uploadBytesLeft*: int
    ackMark*: uint64
    lobbyTranscriptMark*: uint64
    call*: Option[PlayContextAcceptedCall]
    playbook*: seq[PlayContextReadyModule]

  RetainedPlayStatus = object
    entry: StatusEntry
    bytes: string
    reservationSlots: int
    proposalId: Option[uint64]
    spontaneous: bool

  PlayOutboundSeat*[Socket] = object
    bound: bool
    socket: Socket
    generation*: uint64
    contextPending*: bool
    lobbyTranscriptMark*: uint64
    transcriptCursor*: uint64
    lastViewTick*: uint32
    hasSentView*: bool
    statusDirty*: bool
    nextStatusOrdinal*: uint64
    ackMark*: uint64
    retained: seq[RetainedPlayStatus]
    spontaneousStatuses: int
    counters*: PlayControlCounters

proc saturatingInc(value: var uint32) =
  if value < high(uint32):
    inc value

proc saturatingAdd(value: var uint32; amount: uint32) =
  let room = high(uint32) - value
  value += min(amount, room)

proc bindOutbound*[Socket](seat: var PlayOutboundSeat[Socket]; socket: Socket;
                           generation, transcriptMark: uint64) =
  seat.bound = true
  seat.socket = socket
  seat.generation = generation
  seat.contextPending = true
  seat.lobbyTranscriptMark = transcriptMark
  seat.transcriptCursor = 0
  seat.hasSentView = false
  seat.statusDirty = true

proc loseOutbound*[Socket](seat: var PlayOutboundSeat[Socket]; socket: Socket) =
  if seat.bound and seat.socket == socket:
    seat.bound = false
    seat.contextPending = false

proc currentSocket*[Socket](seat: PlayOutboundSeat[Socket]): Option[Socket] =
  if seat.bound:
    some(seat.socket)
  else:
    none(Socket)

proc noteSendRefused*[Socket](seat: var PlayOutboundSeat[Socket]) =
  ## A refused Mummy admission is visible in the next control envelope. No
  ## packet bytes are copied into an application retry queue.
  seat.counters.backpressure.saturatingInc()
  seat.statusDirty = true

proc noteDroppedChat*[Socket](seat: var PlayOutboundSeat[Socket]) =
  seat.counters.droppedChat.saturatingInc()

proc fitStatus(entry: var StatusEntry) =
  case entry.kind
  of skModuleRejected:
    while entry.moduleReason.len > 0 and
        encodeStatusEntry(entry).len > StatusEntryMaxBytes:
      entry.moduleReason.setLen(entry.moduleReason.len - 1)
  of skCallRejected:
    while entry.callReason.len > 0 and
        encodeStatusEntry(entry).len > StatusEntryMaxBytes:
      entry.callReason.setLen(entry.callReason.len - 1)
  of skRetuneRefused, skPlayFaulted:
    while entry.faultReason.len > 0 and
        encodeStatusEntry(entry).len > StatusEntryMaxBytes:
      entry.faultReason.setLen(entry.faultReason.len - 1)
  else:
    discard

proc retainStatus*[Socket](seat: var PlayOutboundSeat[Socket];
    entry: sink StatusEntry; reservationSlots: int;
    proposalId = none(uint64); spontaneous = false): bool =
  ## Reserved admissions are guaranteed physical space by ingress. Refusals
  ## that occur before reservation use only the 16 autonomous/fault slots.
  if seat.nextStatusOrdinal == high(uint64):
    seat.counters.faultsDropped.saturatingInc()
    return false
  if spontaneous and seat.spontaneousStatuses >= StatusFaultReserve:
    seat.counters.faultsDropped.saturatingInc()
    return false
  if seat.retained.len >= MaxRetainedStatusEntries:
    seat.counters.faultsDropped.saturatingInc()
    return false
  inc seat.nextStatusOrdinal
  entry.ordinal = seat.nextStatusOrdinal
  entry.fitStatus()
  let bytes = encodeStatusEntry(entry)
  if bytes.len > StatusEntryMaxBytes:
    seat.counters.faultsDropped.saturatingInc()
    return false
  seat.retained.add(RetainedPlayStatus(
    entry: move(entry), bytes: bytes,
    reservationSlots: max(0, reservationSlots),
    proposalId: proposalId, spontaneous: spontaneous))
  if spontaneous:
    inc seat.spontaneousStatuses
  seat.statusDirty = true
  true

proc retainModuleRefusal*[Socket](seat: var PlayOutboundSeat[Socket];
    generation, uploadId: uint64; reason: string; spontaneous = true;
    reservationSlots = 0): bool =
  seat.retainStatus(StatusEntry(
    kind: skModuleRejected, originGeneration: generation,
    rejectedUploadId: uploadId, moduleReason: reason),
    reservationSlots, spontaneous = spontaneous)

proc retainCallRefusal*[Socket](seat: var PlayOutboundSeat[Socket];
    generation, proposalId: uint64; reason: string; spontaneous = true;
    reservationSlots = 0): bool =
  let retiredProposal =
    if reservationSlots > 0: some(proposalId)
    else: none(uint64)
  seat.retainStatus(StatusEntry(
    kind: skCallRejected, originGeneration: generation,
    rejectedProposalId: proposalId, callReason: reason),
    reservationSlots, retiredProposal, spontaneous)

proc acknowledge*[Socket](seat: var PlayOutboundSeat[Socket]; mark: uint64):
    tuple[valid: bool, statusSlotsRetired: int,
          retiredProposalIds: seq[uint64]] =
  if mark < seat.ackMark or mark > seat.nextStatusOrdinal:
    return
  result.valid = true
  seat.ackMark = mark
  var kept: seq[RetainedPlayStatus]
  for retained in seat.retained:
    if retained.entry.ordinal <= mark:
      result.statusSlotsRetired += retained.reservationSlots
      if retained.proposalId.isSome:
        result.retiredProposalIds.add(retained.proposalId.get)
      if retained.spontaneous:
        dec seat.spontaneousStatuses
    else:
      kept.add(retained)
  seat.retained = move(kept)

proc retainedStatusCount*[Socket](seat: PlayOutboundSeat[Socket]): int =
  seat.retained.len

proc statusBytes*[Socket](seat: PlayOutboundSeat[Socket]): seq[string] =
  for retained in seat.retained:
    result.add(retained.bytes)

proc absorbIngressCounters*[Socket](seat: var PlayOutboundSeat[Socket];
    droppedUploads, droppedCalls, backpressure: uint32) =
  seat.counters.droppedUploads.saturatingAdd(droppedUploads)
  seat.counters.droppedCalls.saturatingAdd(droppedCalls)
  seat.counters.backpressure.saturatingAdd(backpressure)

proc controlViewEnvelope*[Socket](seat: PlayOutboundSeat[Socket];
    ingress: PlayControlCounters = PlayControlCounters()): string =
  ## Canonical byte order: counters, gen, schema, statuses, v.
  var c = seat.counters
  c.droppedUploads.saturatingAdd(ingress.droppedUploads)
  c.droppedCalls.saturatingAdd(ingress.droppedCalls)
  c.droppedChat.saturatingAdd(ingress.droppedChat)
  c.faultsDropped.saturatingAdd(ingress.faultsDropped)
  c.backpressure.saturatingAdd(ingress.backpressure)
  result = "{\"counters\":{\"backpressure\":" & $c.backpressure &
    ",\"dropped_calls\":" & $c.droppedCalls &
    ",\"dropped_chat\":" & $c.droppedChat &
    ",\"dropped_uploads\":" & $c.droppedUploads &
    ",\"faults_dropped\":" & $c.faultsDropped & "},\"gen\":\"" &
    $seat.generation & "\",\"schema\":\"control_view\""
  if seat.retained.len > 0:
    result.add(",\"statuses\":[")
    for index, retained in seat.retained:
      if index > 0:
        result.add(',')
      result.add(retained.bytes)
    result.add(']')
  result.add(",\"v\":1}")

proc controlContextEnvelope*(recovery: PlayContextRecovery): string =
  var writer = initCanonicalWriter()
  writer.beginObject()
  writer.fieldUint64("ack_mark", recovery.ackMark)
  writer.key("budgets")
  writer.beginObject()
  writer.field("modules_left", recovery.modulesLeft.int64)
  writer.field("upload_bytes_left", recovery.uploadBytesLeft.int64)
  writer.endObject()
  if recovery.call.isSome:
    let call = recovery.call.get
    writer.key("call")
    writer.beginObject()
    writer.field("bytes", call.bytes)
    writer.fieldUint64("proposal_id", call.proposalId)
    writer.endObject()
  writer.fieldUint64("epoch", recovery.epoch)
  writer.key("floors")
  writer.beginObject()
  writer.fieldUint64("proposal_id", recovery.proposalIdFloor)
  writer.fieldUint64("upload_id", recovery.uploadIdFloor)
  writer.endObject()
  writer.fieldUint64("gen", recovery.generation)
  writer.fieldUint64("lobby_transcript_mark", recovery.lobbyTranscriptMark)
  if recovery.playbook.len > 0:
    writer.key("playbook")
    writer.beginArray()
    for module in recovery.playbook:
      writer.beginObject()
      writer.field("name", module.name)
      writer.field("sha256", module.sha256)
      writer.field("state", "ready")
      writer.endObject()
    writer.endArray()
  writer.field("schema", "control_context")
  writer.field("v", 1'i64)
  writer.endObject()
  writer.take()

proc shouldSendView*[Socket](seat: PlayOutboundSeat[Socket]; tick: uint32;
                             interval: int): bool =
  seat.bound and not seat.contextPending and
    (seat.statusDirty or not seat.hasSentView or
      uint64(tick) >= uint64(seat.lastViewTick) + uint64(max(1, interval)))

proc markContextSent*[Socket](seat: var PlayOutboundSeat[Socket]) =
  seat.contextPending = false

proc markViewSent*[Socket](seat: var PlayOutboundSeat[Socket]; tick: uint32) =
  seat.lastViewTick = tick
  seat.hasSentView = true
  seat.statusDirty = false

proc hasTranscriptPending*[Socket](seat: PlayOutboundSeat[Socket];
                                   transcriptLength: int): bool =
  seat.transcriptCursor < uint64(max(0, transcriptLength))

proc advanceTranscript*[Socket](seat: var PlayOutboundSeat[Socket]) =
  inc seat.transcriptCursor
