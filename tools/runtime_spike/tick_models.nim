## Deterministic, deliberately conservative host-side cost models for the
## phase-5 runtime-half worst tick. These are benchmark stand-ins, not the
## future shell validator, body, atlas, or control-plane implementation.

import std/[json, strutils]

import ../../src/shell/canonical
import ../../src/shell/types

export MaxAllocsPerInvocation, MaxCallBytes, MaxCallsPerSeatPerTick,
  MaxCompileCommitsPerTick, MaxCoverPostsExamined, MaxCoverThreats,
  MaxEmitBytes, MaxEmitsPerStep, MaxInitsPerTick, MaxInstancesPerSeat,
  MaxLadderEntries, MaxLogBytesPerCall, MaxLogCallsPerInvocation,
  MaxContextBytes, MaxModuleBytes, MaxSpatialCallsPerStep, MaxStepsPerSeatPerTick,
  StatusAckPacketBytes, StatusEntryMaxBytes, StepFuel, InitFuel

const
  GameplaySeats* = 32
  ReachableTieScan* = 64 # intentionally conservative and still unverified
  ReflexCandidates* = MaxReflexCandidates
  ReflexHazards* = MaxCoverThreats
  AllocationBytes* = MaxViewFrameBytes
  ExpectedSteps* = GameplaySeats * MaxStepsPerSeatPerTick
  ExpectedInits* = MaxInitsPerTick
  ExpectedDefaults* = GameplaySeats
  ExpectedReflexPlans* = GameplaySeats
  ExpectedLadders* = GameplaySeats * MaxCallsPerSeatPerTick
  ExpectedAdmissions* = GameplaySeats
  ExpectedCommits* = MaxCompileCommitsPerTick
  ExpectedStatuses* = ExpectedLadders + ExpectedAdmissions + ExpectedCommits
  ExpectedAcks* = GameplaySeats

type
  TickCounters* = object
    allocations*, allocationBytes*: int
    steps*, stepTraps*, stepFuelConsumed*: int
    inits*, initTraps*, initFuelConsumed*: int
    coverCalls*, coverThreatBytes*, coverPostThreatScores*, coverDuckScores*: int
    reachableCalls*, reachableTieScores*: int
    emits*, emitBytes*, emitSchemaBytes*: int
    logs*, logBytes*: int
    defaults*: int
    reflexPlans*, reflexCandidates*, reflexHazardScores*: int
    ladders*, ladderEntries*, ladderBytes*: int
    admissions*, commits*: int
    statuses*, statusBytes*, acks*, ackBytes*: int
    checksum*: uint64

var
  modelRaster: array[65_536, uint32]
  modelRasterReady = false

proc initializeCostModels*() =
  if modelRasterReady:
    return
  var value = 0x9e37_79b9'u32
  for index in 0 ..< modelRaster.len:
    value = value xor (value shl 13)
    value = value xor (value shr 17)
    value = value xor (value shl 5)
    modelRaster[index] = value xor index.uint32
  modelRasterReady = true

proc mix(state: var TickCounters; value: uint64) {.inline.} =
  state.checksum = (state.checksum xor value) * 1_099_511_628_211'u64

proc nearestCover*(state: var TickCounters) =
  var best = high(int64)
  for post in 0 ..< MaxCoverPostsExamined:
    var score = 0'i64
    for threat in 0 ..< MaxCoverThreats:
      let dx = ((post * 37 + threat * 17) and 1023) - 512
      let dy = ((post * 53 - threat * 29) and 1023) - 512
      let raster = modelRaster[(post * 131 + threat * 977) and 0xffff]
      score += (dx * dx + dy * dy + threat * 11).int64 +
        (raster and 0xff).int64
    if score < best:
      best = score
  # Separate cold duck-contrast pass; no memoized entry is reused.
  var duck = 0'i64
  for post in 0 ..< MaxCoverPostsExamined:
    duck += ((post * 97) xor (post shr 2)).int64
  inc state.coverCalls
  state.coverPostThreatScores += MaxCoverPostsExamined * MaxCoverThreats
  state.coverDuckScores += MaxCoverPostsExamined
  state.mix(best.uint64 xor duck.uint64)

proc nearestReachable*(state: var TickCounters) =
  let rasterValue = modelRaster[(state.reachableCalls * 40503) and 0xffff].int
  var best = high(int)
  for tie in 0 ..< ReachableTieScan:
    let candidate = (rasterValue xor (tie * 40_503)) and 0x7fff_ffff
    best = min(best, candidate)
  inc state.reachableCalls
  state.reachableTieScores += ReachableTieScan
  state.mix(best.uint64)

proc schemaWalk(state: var TickCounters; bytes: string) =
  var escaped = false
  var depth = 0
  for character in bytes:
    if escaped:
      escaped = false
    elif character == '\\':
      escaped = true
    elif character in {'{', '['}:
      inc depth
    elif character in {'}', ']'}:
      dec depth
    state.mix((ord(character) + depth * 257).uint64)
  state.emitSchemaBytes += bytes.len

proc validIntentBytes*(): string =
  let node = %*{
    "arriveRadius": 1_000_000.0,
    "clampToEndzone": true,
    "combat": {
      "holdFire": true,
      "noShoot": {"seats": ["seat:0", "seat:31"], "teams": [0, 1, 2, 3]},
      "prefer": ["weakened", "isolated", "revenge", "bounty"],
      "protect": {"seats": ["seat:1", "seat:30"], "teams": [0, 1, 2, 3]}
    },
    "idleAimCenterBrads": 255,
    "kind": "navigateTo",
    "micro": ["peekDuck", "separation", "formationBias", "stealRushExempt"],
    "movingGoal": true,
    "point": {"x": 2147483647, "y": 2147483647},
    "profile": "hunter",
    "reason": repeat("r", 64),
    "suppressFireFreeze": true
  }
  canonicalJson(node)

proc modelEmit*(state: var TickCounters; guestBytes: string;
    validIntent: string) =
  let parsedGuest = parseJson(guestBytes)
  let parsedBytes = canonicalJson(parsedGuest)
  let schemaBytes = if validIntent.len > 0: validIntent else: parsedBytes
  let parsedSchema = parseJson(schemaBytes)
  discard canonicalJson(parsedSchema)
  state.schemaWalk(schemaBytes)
  state.nearestReachable() # the engine's goal-validation lookup
  inc state.emits
  state.emitBytes += guestBytes.len

proc modelLog*(state: var TickCounters; bytes: string) =
  var folded = 0'u64
  for character in bytes:
    folded = folded xor ord(character).uint64
    folded = (folded shl 5) or (folded shr 59)
  inc state.logs
  state.logBytes += bytes.len
  state.mix(folded)

proc defaultPlay*(state: var TickCounters) =
  let node = %*{
    "arriveRadius": 128.0,
    "kind": "hold",
    "profile": "default",
    "reason": "engine-native conservative fallback"
  }
  let bytes = canonicalJson(node)
  state.nearestReachable()
  for character in bytes:
    state.mix(ord(character).uint64)
  inc state.defaults

proc reflexPlanEscape*(state: var TickCounters) =
  var bestScore = low(int64)
  var bestOrdinal = -1
  for candidate in 0 ..< ReflexCandidates:
    var score = 0'i64
    for hazard in 0 ..< ReflexHazards:
      let raster = modelRaster[(candidate * 131 + hazard * 977) and 0xffff]
      let distance = ((raster shr 8) and 0xffff).int64
      let exposure = (raster and 0xff).int64
      score += distance - exposure * 17 - hazard.int64 * 97
    # Force the fallback tie/ordinal path after scoring every candidate.
    if score > bestScore or (score == bestScore and candidate < bestOrdinal):
      bestScore = score
      bestOrdinal = candidate
  inc state.reflexPlans
  state.reflexCandidates += ReflexCandidates
  state.reflexHazardScores += ReflexCandidates * ReflexHazards
  state.mix(bestScore.uint64 xor bestOrdinal.uint64)

proc ladderBytes*(): string =
  var entries = newJArray()
  for entry in 0 ..< MaxLadderEntries:
    entries.add %*{
      "entryId": "entry-" & $entry,
      "guard": {"all": [{"field": "alive", "eq": true}]},
      "module": "module-" & $entry,
      "params": {"profile": "hunter", "radius": 600}
    }
  var paddingLength = 0
  while true:
    let node = %*{"entries": entries, "zzUnknownAtEnd": repeat("z", paddingLength)}
    let encoded = canonicalJson(node)
    if encoded.len == MaxCallBytes:
      return encoded
    if encoded.len > MaxCallBytes:
      raise newException(ValueError, "could not construct exact ladder bytes")
    paddingLength += MaxCallBytes - encoded.len

proc validateLadder*(state: var TickCounters; bytes: string) =
  let node = parseJson(bytes)
  let canonical = canonicalJson(node)
  if canonical.len != MaxCallBytes or node["entries"].len != MaxLadderEntries:
    raise newException(ValueError, "ladder fixture lost its exact cap")
  # The unknown final key models a schema rejection only after every entry,
  # guard, and parameter has been walked.
  for entry in node["entries"]:
    for key, value in entry:
      state.mix((key.len + value.len).uint64)
  state.mix(node["zzUnknownAtEnd"].getStr().len.uint64)
  inc state.ladders
  state.ladderEntries += MaxLadderEntries
  state.ladderBytes += bytes.len

proc admitUpload*(state: var TickCounters; seat: int) =
  let uploadId = (seat + 1).uint64
  let reserved = MaxModuleBytes
  if reserved > MaxModuleBytes:
    raise newException(ValueError, "upload reservation overflow")
  inc state.admissions
  state.mix(uploadId xor reserved.uint64)

proc commitCompile*(state: var TickCounters; ordinal: int) =
  let pendingAfter = MaxModuleBytes * (ExpectedAdmissions - ordinal - 1)
  let nameHash = (ordinal.uint64 shl 32) xor pendingAfter.uint64
  inc state.commits
  state.mix(nameHash)

proc statusAndAcks*(state: var TickCounters) =
  let prefix = "{\"status\":\""
  let suffix = "\"}"
  let entry = prefix & repeat("s",
    StatusEntryMaxBytes - prefix.len - suffix.len) & suffix
  if entry.len != StatusEntryMaxBytes:
    raise newException(ValueError, "status fixture lost its exact cap")
  for statusIndex in 0 ..< ExpectedStatuses:
    for character in entry:
      state.mix(ord(character).uint64 xor statusIndex.uint64)
    inc state.statuses
    state.statusBytes += entry.len
  for seat in 0 ..< ExpectedAcks:
    state.mix((seat.uint64 shl 32) xor ExpectedStatuses.uint64)
    inc state.acks
    state.ackBytes += StatusAckPacketBytes

proc requireExactCounts*(state: TickCounters) =
  template expect(actual, expected: untyped; label: string) =
    if actual != expected:
      raise newException(ValueError, label & " count=" & $actual &
        " expected=" & $expected)
  expect(state.allocations,
    (ExpectedSteps + ExpectedInits) * MaxAllocsPerInvocation,
    "allocations")
  expect(state.allocationBytes,
    ExpectedSteps * MaxAllocsPerInvocation * AllocationBytes +
      ExpectedInits * (MaxCallBytes + MaxContextBytes),
    "allocation bytes")
  expect(state.steps, ExpectedSteps, "steps")
  expect(state.stepTraps, ExpectedSteps, "step traps")
  expect(state.stepFuelConsumed, ExpectedSteps * StepFuel, "step fuel")
  expect(state.inits, ExpectedInits, "inits")
  expect(state.initTraps, ExpectedInits, "init traps")
  expect(state.initFuelConsumed, ExpectedInits * InitFuel, "init fuel")
  expect(state.coverCalls, ExpectedSteps * MaxSpatialCallsPerStep,
    "cover calls")
  expect(state.coverThreatBytes,
    ExpectedSteps * MaxSpatialCallsPerStep * MaxCoverThreats * 8,
    "cover threat bytes")
  expect(state.coverPostThreatScores,
    ExpectedSteps * MaxSpatialCallsPerStep * MaxCoverPostsExamined *
      MaxCoverThreats, "cover post-threat scores")
  expect(state.coverDuckScores,
    ExpectedSteps * MaxSpatialCallsPerStep * MaxCoverPostsExamined,
    "cover duck scores")
  expect(state.emits, ExpectedSteps * MaxEmitsPerStep, "emits")
  expect(state.emitBytes, ExpectedSteps * MaxEmitsPerStep * MaxEmitBytes,
    "emit bytes")
  expect(state.reachableCalls,
    ExpectedSteps * MaxEmitsPerStep + ExpectedDefaults, "reachable calls")
  expect(state.reachableTieScores,
    (ExpectedSteps * MaxEmitsPerStep + ExpectedDefaults) * ReachableTieScan,
    "reachable tie scores")
  expect(state.logs, ExpectedSteps * MaxLogCallsPerInvocation, "logs")
  expect(state.logBytes,
    ExpectedSteps * MaxLogCallsPerInvocation * MaxLogBytesPerCall,
    "log bytes")
  expect(state.defaults, ExpectedDefaults, "defaults")
  expect(state.reflexPlans, ExpectedReflexPlans, "reflex plans")
  expect(state.reflexCandidates,
    ExpectedReflexPlans * ReflexCandidates, "reflex candidates")
  expect(state.reflexHazardScores,
    ExpectedReflexPlans * ReflexCandidates * ReflexHazards,
    "reflex hazard scores")
  expect(state.ladders, ExpectedLadders, "ladders")
  expect(state.ladderEntries, ExpectedLadders * MaxLadderEntries,
    "ladder entries")
  expect(state.ladderBytes, ExpectedLadders * MaxCallBytes, "ladder bytes")
  expect(state.admissions, ExpectedAdmissions, "admissions")
  expect(state.commits, ExpectedCommits, "commits")
  expect(state.statuses, ExpectedStatuses, "statuses")
  expect(state.statusBytes, ExpectedStatuses * StatusEntryMaxBytes,
    "status bytes")
  expect(state.acks, ExpectedAcks, "acks")
  expect(state.ackBytes, ExpectedAcks * StatusAckPacketBytes, "ack bytes")
