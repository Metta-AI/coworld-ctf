## Shell play ABI constants, phase legality, counters, and checked buffers.
##
## This module is intentionally free of Wasmtime handles. It is the small,
## testable contract layer used by the production instance wrapper.

import std/options

import types

type
  AbiPhase* = enum
    apIdle
    apAlloc
    apManifest
    apInit
    apStep
    apRetune

  AbiHostCall* = enum
    ahEmit
    ahLog
    ahNearestReachable
    ahNearestCover

  AbiBuffer* = object
    offset*: int32
    length*: int32

  AbiCounters* = object
    allocations*: int
    emits*: int
    logs*: int
    spatialCalls*: int

  AbiInvocation* = object
    phase*: AbiPhase
    counters*: AbiCounters
    buffers*: seq[AbiBuffer]
    fuelInstalledBeforeAlloc*: bool
    faultReason*: string
    faultCode*: FaultCode

const
  AbiOk* = int32(0)
  AbiNormalized* = int32(1)
  AbiSchemaViolation* = int32(-1)
  AbiRangeViolation* = int32(-2)
  AbiUnreachableGoal* = int32(-3)
  AbiUnknownReference* = int32(-4)
  AbiClassMismatch* = int32(-5)
  AbiTooLarge* = int32(-6)

proc beginInvocation*(phase: AbiPhase): AbiInvocation =
  assert phase in {apManifest, apInit, apStep, apRetune}
  AbiInvocation(phase: phase)

proc installFuelAndDeadline*(invocation: var AbiInvocation) =
  invocation.fuelInstalledBeforeAlloc = true

proc fault*(invocation: var AbiInvocation; code: FaultCode;
            reason: string) =
  ## The first fault wins; later ones in the same invocation are noise.
  if invocation.faultReason.len == 0:
    invocation.faultReason = reason
    invocation.faultCode = code

proc fault*(invocation: var AbiInvocation; reason: string) =
  ## Host-side ABI verdicts (import misuse, emit flood, bad allocations).
  invocation.fault(fcAbiViolation, reason)

proc faulted*(invocation: AbiInvocation): bool {.inline.} =
  invocation.faultReason.len > 0

proc finish*(invocation: var AbiInvocation) =
  invocation.phase = apIdle
  invocation.buffers.setLen(0)

proc hostCallAllowed*(phase: AbiPhase, inAllocator: bool,
                      call: AbiHostCall): bool =
  if inAllocator:
    return false
  case phase
  of apManifest:
    call in {ahEmit, ahLog}
  of apInit, apRetune:
    call == ahLog
  of apStep:
    call in {ahEmit, ahLog, ahNearestReachable, ahNearestCover}
  else:
    false

proc noteAllocation*(invocation: var AbiInvocation): bool =
  if invocation.counters.allocations >= MaxAllocsPerInvocation:
    invocation.fault("play_alloc call limit exceeded")
    return false
  inc invocation.counters.allocations
  true

proc noteEmit*(invocation: var AbiInvocation): bool =
  if not hostCallAllowed(invocation.phase, false, ahEmit):
    invocation.fault("emit outside its legal phase")
    return false
  if invocation.phase == apStep and invocation.counters.emits >= MaxEmitsPerStep:
    invocation.fault("emit call limit exceeded")
    return false
  inc invocation.counters.emits
  true

proc noteLog*(invocation: var AbiInvocation): bool =
  if not hostCallAllowed(invocation.phase, false, ahLog):
    invocation.fault("log outside its legal phase")
    return false
  inc invocation.counters.logs
  invocation.counters.logs <= MaxLogCallsPerInvocation

proc noteSpatial*(invocation: var AbiInvocation): int32 =
  if not hostCallAllowed(invocation.phase, false, ahNearestReachable):
    invocation.fault("spatial import outside play_step")
    return AbiSchemaViolation
  if invocation.counters.spatialCalls >= MaxSpatialCallsPerStep:
    return AbiRangeViolation
  inc invocation.counters.spatialCalls
  AbiOk

proc checkedRange*(memoryBytes: int, offset, length: int32): Option[AbiBuffer] =
  if memoryBytes < 0 or offset < 0 or length < 0:
    return none(AbiBuffer)
  let start = int64(offset)
  let byteLen = int64(length)
  let stop = start + byteLen
  if stop < start or stop > int64(memoryBytes):
    return none(AbiBuffer)
  some(AbiBuffer(offset: offset, length: length))

proc overlaps*(a, b: AbiBuffer): bool =
  let a0 = int64(a.offset)
  let a1 = a0 + int64(a.length)
  let b0 = int64(b.offset)
  let b1 = b0 + int64(b.length)
  a0 < b1 and b0 < a1

proc acceptAllocatedBuffer*(invocation: var AbiInvocation, memoryBytes: int,
                            offset, length: int32): Option[AbiBuffer] =
  if offset == 0:
    invocation.fault("play_alloc returned zero")
    return none(AbiBuffer)
  let checked = checkedRange(memoryBytes, offset, length)
  if checked.isNone:
    invocation.fault("play_alloc returned an out-of-range buffer")
    return none(AbiBuffer)
  for previous in invocation.buffers:
    if previous.overlaps(checked.get):
      invocation.fault("play_alloc returned overlapping buffers")
      return none(AbiBuffer)
  invocation.buffers.add(checked.get)
  checked
