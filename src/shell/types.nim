## The play-calling shell's shared contract types and named constants.
##
## This file is the contracts-first commit of
## docs/designs/strategy-play-calling-shell-2026-08-29.md: the types and
## limits all three implementation lanes (body, seat/lobby, runtime) build
## against, landed before any lane starts so the seams are never negotiated
## in flight. Sections cited below are that design's.
##
## Nothing here is reachable from a non-Season-2 configuration: the whole
## subsystem sits behind the `season2Shell` config gate (default off), and a
## gate-off build plays byte-identically (§3.2, AGENTS.md's house rule).
##
## Constants whose values the design marks provisional carry a `## P0` note:
## P0's measurement (worst tick vs the quarter-tick acceptance, §10) may
## change the VALUE; the mechanism and the name are fixed.

import std/options
import ../ctf/sim_types
export sim_types.ViewIntervalTicksDefault, sim_types.ViewIntervalTicksMin,
  sim_types.ViewIntervalTicksMax, sim_types.LobbyChatTicksDefault,
  sim_types.LobbyChatTicksMax, sim_types.PlaySeatBindTicksDefault,
  sim_types.PlaySeatBindTicksMax

type
  # ── §5.1: the game mode, derived server-side, never declared ──────────
  GameMode* = enum
    gmCtf
    gmKoth
    gmBr

  # ── §4.1: the Intent — the one order type a play can give the body ────
  IntentKind* = enum
    ikNavigateTo
    ikHold

  CostProfile* = enum
    cpDefault
    cpCarrier
    cpHunter

  MicroFlag* = enum
    ## Stencil's micro-permission set (LAB:types.nim), minus the pursuit
    ## flag, which is deleted with the pursuit override (§3.3 ruling 3).
    mfPeekDuck
    mfSeparation
    mfFormationBias
    mfStealRushExempt

  SeatRef* = distinct uint8
    ## A per-seat reference (0 ..< MaxPlayers). Wire spellings are the
    ## prefix-tagged strings of Appendix P.1 ("seat:12", and "duo:<team>"
    ## which names a Battle Royale team); duo references resolve to the two
    ## configured seats of that team at validation (§5.1) so the folded,
    ## engine-side sets hold plain seat indices and team memberships only.

  PreferTag* = enum
    ## §5.2: closed target-preference vocabulary, lexicographic priority in
    ## ladder order, deduplicated keeping the first occurrence.
    ptWeakened
    ptIsolated
    ptRevenge
    ptBounty

  ProtectedSet* = object
    ## §4.1: teams and seats a combat policy protects or refuses to shoot.
    ## Canonical form is sorted + deduplicated; caps are the roster's own
    ## sizes so folding any number of valid policies can never overflow.
    teams*: set[Team]
    seats*: seq[SeatRef]

  CombatPolicy* = object
    ## §4.1/§4.2. Everything empty or false is the neutral value and the
    ## default.
    noShoot*: ProtectedSet     ## never fired on, in every weapon path
    protect*: ProtectedSet     ## wards: bias position + targeting to defend
    prefer*: seq[PreferTag]    ## priority order; at most the 4 distinct tags
    holdFire*: bool            ## do not initiate (return fire allowed, §5.2)

  Intent* = object
    ## Stencil's ten-field contract plus the combat policy (§4.1). The body
    ## executes the standing Intent every tick until a play replaces it.
    kind*: IntentKind
    point*: Option[MapPoint]   ## present exactly when kind is ikNavigateTo;
                               ## validated (and, where stencil's resolver
                               ## would, normalized) by `emit` (§6.1)
    arriveRadius*: float       ## pixels, [0, map diagonal]
    movingGoal*: bool
    profile*: CostProfile
    micro*: set[MicroFlag]
    idleAimCenterBrads*: Option[int]  ## 0..255
    clampToEndzone*: bool      ## meaningful in gmCtf, ignored elsewhere
    suppressFireFreeze*: bool
    reason*: string            ## telemetry only, at most IntentReasonMaxBytes
    combat*: CombatPolicy

  # ── §4.3: play-seat socket lifecycle and instance states ──────────────
  PlaySeatSocketState* = enum
    ## The persistent seat's socket-binding state machine (§4.3). `close`
    ## is episode teardown only, never transport loss.
    pssUnbound   ## before the first registration
    pssBound
    pssLost      ## transport close/error; nothing in the sim changes
    pssClosed    ## episode teardown, the only destructive transition

  PlayInstanceState* = enum
    ## §7.2. A faulted entry's guard is permanently false for the life of
    ## the ladder; a pendingRetune entry contributes nothing until its
    ## retune completes.
    pisAbsent
    pisLive
    pisParked        ## seat dead; guest memory retained
    pisPendingRetune ## adopted with new params, waiting for its quota turn
    pisFaulted

  # ── §4.3: the durable status list ─────────────────────────────────────
  StatusKind* = enum
    skModuleAccepted   ## at admission (uploadId)
    skModuleReady      ## terminal: name bound (uploadId, name, sha256)
    skModuleRejected   ## terminal: named reason (uploadId, reason)
    skCallAccepted     ## proposalId, epoch, tick
    skCallRejected     ## proposalId, reason (with the parameter path)
    skRetuneRefused    ## epoch, entryId, reason
    skPlayFaulted      ## epoch, entryId, reason (autonomous; reserved slots)

  StatusEntry* = object
    ## One ordered entry in the per-seat status list. The complete canonical
    ## serialized JSON value (tag, ordinal, origin generation, ids, reason,
    ## escaping included) is capped at StatusEntryMaxBytes, with reasons and
    ## paths truncated to fit (§4.3).
    ordinal*: uint64           ## server-assigned, monotonic per seat
    originGeneration*: uint64  ## the control generation the operation was
                               ## admitted in (or the autonomous event's)
    case kind*: StatusKind
    of skModuleAccepted:
      acceptedUploadId*: uint64
    of skModuleReady:
      readyUploadId*: uint64
      name*: string
      sha256*: string
    of skModuleRejected:
      rejectedUploadId*: uint64
      moduleReason*: string
    of skCallAccepted:
      acceptedProposalId*: uint64
      epoch*: uint64
      tick*: uint32
    of skCallRejected:
      rejectedProposalId*: uint64
      callReason*: string      ## named error carrying the parameter path
    of skRetuneRefused, skPlayFaulted:
      faultEpoch*: uint64
      entryId*: string
      faultReason*: string

  # ── §4.3: the non-hashed annotation stream (replay record 0x11) ───────
  ProvenanceBaseKind* = enum
    pbEntry    ## a controller entry: entryId + module hash + emit tick
    pbDefault  ## the engine-native default play
    pbReflex   ## an engine-native reflex, named + versioned by GameVersion

  ProvenanceBase* = object
    case kind*: ProvenanceBaseKind
    of pbEntry:
      entryId*: string
      moduleSha256*: string
      emitTick*: uint32
    of pbReflex:
      reflexName*: string      ## "reflex_clear_grenade" | "reflex_clear_spray"
                               ## | "reflex_zone_escape"
    of pbDefault:
      discard

  OverlayContribution* = object
    ## One overlay active on the annotated tick. A retained policy from an
    ## overlay that emitted nothing this tick is attributed to the tick it
    ## was accepted; a byte-identical re-emission keeps its original
    ## accepted tick (§7.4), so provenance is stable while outputs are.
    entryId*: string
    moduleSha256*: string
    acceptedTick*: uint32
    policySha256*: string      ## content hash of the canonical policy bytes

  Provenance* = object
    base*: ProvenanceBase
    overlays*: seq[OverlayContribution]  ## ordered, ladder order

  AnnotationKind* = enum
    akAcceptedIntentChange
    akClearOnDeath
    akInstallSafeIntent
    akPlayFault              ## metadata; never changes the standing order

  ShellAnnotation* = object
    ## §4.3: a new annotation is written whenever the standing order's
    ## canonical bytes, its provenance, OR its effective order epoch
    ## changes. Same-tick ordering is the exact order the server made the
    ## transitions, keyed by (tick, phase, ordinal); no sort is imposed
    ## over the truth.
    tick*: uint32
    seat*: uint8
    case kind*: AnnotationKind
    of akAcceptedIntentChange:
      effectiveEpoch*: uint64  ## the EFFECTIVE order epoch (§4.3), distinct
                               ## from the seat's current declared epoch
      provenance*: Provenance
      intentBytes*: string     ## the canonical Intent encoding that stands
    of akClearOnDeath:
      clearGeneration*: uint64
    of akInstallSafeIntent:
      installGeneration*: uint64
      installReason*: string   ## "activation" | "respawn" | "kicked"
      safeBytes*: string       ## always at the reserved epoch zero
    of akPlayFault:
      faultAtEpoch*: uint64
      faultEntryId*: string
      annotationFaultReason*: string

const
  # ── §4.3: the play-seat packet opcodes ────────────────────────────────
  # Binary WebSocket messages, exactly one packet per message, all integers
  # little-endian, every packet beginning `u8 op, u8 ver` with ver = 1 (any
  # other value rejects the packet) and every reserved byte zero. The legacy
  # Sprite chat packet (0x81) keeps the Sprite codec's own framing and is
  # NOT in this table. Total sizes are exact equations of the length fields,
  # overflow-safe, no trailing bytes (§4.3's packet table).
  ShellProtocolVersion* = 1'u8

  OpModuleUpload* = 0xA0'u8
    ## client→server: u8 op, u8 ver, u64 uploadId, u32 len, u8[len] wasm.
    ## Total = 14 + len; len ≤ MaxModuleBytes.
  OpPlayCall* = 0xA1'u8
    ## client→server: u8 op, u8 ver, u64 proposalId, u32 len,
    ## u8[len] canonical ladder JSON. Total = 14 + len; len ≤ MaxCallBytes.
  OpStatusAck* = 0xA2'u8
    ## client→server: u8 op, u8 ver, u8[6] reserved (zero), u64 mark.
    ## Total = 16, fixed. Mark is a nondecreasing ordinal high-water mark.
  OpLobbyChatSend* = 0xA3'u8
    ## client→server: u8 op, u8 ver, u32 len, u8[len] UTF-8 text.
    ## Total = 6 + len; len ≤ LobbyChatMaxBytes; accepted only during the
    ## lobby chat phase (§9).
  OpPlayContext* = 0xB0'u8
    ## server→client: u8 op, u8 ver, u32 controlLen, u8[controlLen] control
    ## JSON, u32 ctxLen, u8[ctxLen] context JSON.
    ## Total = 10 + controlLen + ctxLen.
  OpPlayView* = 0xB1'u8
    ## server→client: u8 op, u8 ver, u32 tick, u32 controlLen,
    ## u8[controlLen] control JSON, u32 viewLen, u8[viewLen] view JSON.
    ## Total = 14 + controlLen + viewLen. viewLen = 0 is a control-only
    ## frame (pre-activation, or a dead seat).
  OpLobbyChatBroadcast* = 0xB2'u8
    ## server→client: u8 op, u8 ver, u64 ordinal, u32 tick, u8 seat,
    ## u8 team, u32 len, u8[len] UTF-8 text. Total = 20 + len. One message
    ## per packet, broadcast to every play seat, never coalesced.

  # ── §4.3/§9.3: bumped replay format's new record types ────────────────
  # CtfReplayFormatVersion bumps 1 → 2 in P2 (lane B); the block is
  # reserved here so nothing collides. The codec's existing types are
  # 0x01–0x06 (bitworld/replays.nim).
  RecPlayCall* = 0x10'u8
    ## hash-coupled call record: canonical ladder bytes + per-entry code
    ## identity (module hash, or native name + GameVersion) (§7.5)
  RecBehaviorAnnotation* = 0x11'u8
    ## the per-seat, non-hashed ShellAnnotation array (§4.3)
  RecManifest* = 0x12'u8
    ## end-of-episode manifest: per-seat record counts + ordered-chain
    ## hashes, plus the global lobby-transcript arm (§9.3)
  RecLobbyChat* = 0x13'u8
    ## u8 type, u32 replayTimeMs, u64 ordinal, u8 seat, u8 team, u16 len,
    ## u8[len] UTF-8 text (len ≤ LobbyChatMaxBytes); global transcript
    ## array, ordinal order (§9.3)
  RecDisconnect* = 0x14'u8
    ## u8 type, u32 replayTimeMs, u8 seat — reconnectable tombstone (§4.3)
  RecKick* = 0x15'u8
    ## u8 type, u32 replayTimeMs, u8 seat — terminal tombstone (§4.3)
  RecRebind* = 0x16'u8
    ## u8 type, u32 replayTimeMs, u8 seat — clears a reconnectable
    ## tombstone; rejected for play seats, out-of-range seats, backward
    ## time, or a seat not in `reconnectable` (§4.3)

  # ── §4.3: protocol limits (wire constants of the protocol version) ────
  MaxModuleBytes* = 262144            ## raw wasm bytes per module
  MaxModulesPerSeatPerEpisode* = 16   ## admitted uploads; nonrefundable
                                      ## except byte-identical re-uploads
  MaxUploadBytesPerSeatPerEpisode* = 2097152
  MaxUploadsPerSeatPerTick* = 1
  MaxCallsPerSeatPerTick* = 2
  MaxCallBytes* = 4096                ## canonical ladder JSON (Appendix P)
  MaxLadderEntries* = 16
  MaxActiveOverlays* = 4              ## bounds guest steps/seat/tick at 5
  MaxRetainedStatusEntries* = 64      ## of which StatusFaultReserve reserved
  StatusFaultReserve* = 16
  StatusEntryMaxBytes* = 256          ## complete serialized value
  MaxRetainedStatusBytes* = 16384     ## implied: 64 × 256
  MaxControlEnvelopeBytes* = 20480    ## either packet's controlLen
  StatusAckPacketBytes* = 16
  MaxMessagesClassifiedPerSeatPerTick* = 64   ## first past disconnects
  MaxBytesClassifiedPerSeatPerTick* = 524288  ## same disconnect rule
  PlaySeatReceiveLimitBytes* = 262158 ## per-socket, from the frame header,
                                      ## pre-allocation: 14 + MaxModuleBytes
  MaxPendingSocketEvents* = 128       ## transport queue, ping/pong included
  MaxPendingSocketBytes* = 1048576
  MaxOutboundEvents* = 256            ## §9.2 outbound queue
  MaxOutboundBytes* = 2097152
  ReplayPumpBatch* = 64               ## 0xB2 packets enqueued per tick from
                                      ## a rebinding socket's cursor (§9.2)
  LobbyChatMaxBytes* = 512            ## raw UTF-8 payload, measured first
  LobbyChatMaxPerSeatPerPhase* = 16
  LobbyChatMinSpacingTicks* = 24
  IntentReasonMaxBytes* = 64

  # The five config fields' defaults and ranges (ViewIntervalTicks*,
  # LobbyChatTicks*, PlaySeatBindTicks*) live in ctf/sim_types.nim beside
  # the GameConfig fields they default, because sim_config validates them
  # and src/ctf never imports src/shell; they are re-exported here.

  # ── §6.1: runtime budgets (constants of ABI version 1) ────────────────
  ShellAbiVersion* = 1
  MaxInstancePages* = 16              ## 64 KiB pages: 1 MiB linear memory
  MaxInstancesPerSeat* = 16           ## one per ladder entry
  StepFuel* = 200_000
    ## P0: provisional until the worst-tick measurement (§10) confirms 32
    ## seats at full budget fit the quarter-tick acceptance.
  InitFuel* = 1_000_000
    ## P0: provisional, same rule.
  ManifestFuel* = 1_000_000
    ## P0: provisional, same rule.
  MaxInitsPerSeatPerTick* = 1
  MaxInitsPerTick* = 4                ## server-wide, round-robin by seat
  MaxAllocsPerInvocation* = 2
  MaxStepsPerSeatPerTick* = 5         ## MaxActiveOverlays + 1 controller
  MaxEmitsPerStep* = 4
  MaxEmitBytes* = 4096
  MaxSpatialCallsPerStep* = 8         ## nearest_reachable + nearest_cover
  MaxCoverRadiusPx* = 600
    ## P0: provisional — may come down if the density assertion cannot hold
    ## on the launch map set (§10).
  MaxCoverThreats* = 8
  MaxCoverPostsExamined* = 512
    ## P0: provisional until frozen against the launch map inventory (§10);
    ## asserted per map at load in play-seat configurations.
  MaxRouteFieldsPerSeat* = 4          ## §3.1 seat layer
  MaxDuckEntriesPerSeat* = 256
  ReflexCandidateSpacingPx* = 16      ## Appendix R.2 planEscape lattice
  ReflexCandidateRadiusPx* = 256
  MaxReflexCandidates* = 1089         ## (2·16+1)²
  MaxLogCallsPerInvocation* = 4
  MaxLogBytesPerCall* = 256
  MaxViewFrameBytes* = 32768
  MaxContextBytes* = 65536
  ValidatorRadiusPx* = 256            ## stencil's 32 × NavCell; an ENGINE
                                      ## constant, asserted equal (§6.1)
  MaxValidatorTableBytes* = 268435456
    ## P0: provisional until the giant-field distance rasters are measured.
  MaxPendingCompileBytes* = 8388608
  MaxCompileCommitsPerTick* = 8
  MaxCompiledCacheBytes* = 268435456
    ## P0: provisional until compile-expansion measurement.
  CompiledBytesPerRawByte* = 8
    ## P0: provisional reservation bound until adversarial shapes measure.
  EpochTickerMs* = 5                  ## wall-clock backstop on GUEST code
  EpochDeadlineTicks* = 4             ## deadline, in ticker epochs
  GuestStackBytes* = 262144           ## max_wasm_stack; overflow traps

  # §6.2 manifest schema caps.
  ManifestNamePattern* = "[a-z][a-z0-9_]{0,31}"
  ManifestDocMaxBytes* = 256
  ManifestReservedNames* = ["default"]  ## plus the "reflex_" prefix
  ReflexNamePrefix* = "reflex_"

  # Appendix P.1 canonical-encoding caps (calls and parameters).
  ParamNestingMax* = 4
  ParamListMax* = 32
  ParamStringMaxBytes* = 64
  MaxParamsPerSchema* = 16
  GuardDepthMax* = 4
  GuardNodeMax* = 64

proc `==`*(a, b: SeatRef): bool {.borrow.}
proc `$`*(s: SeatRef): string = "seat:" & $int(uint8(s))

static:
  # The packet block and the record block must never collide with the
  # Sprite v1 client set (0x81–0x86) or the codec's existing record types
  # (0x01–0x06).
  doAssert OpModuleUpload > 0x86'u8
  doAssert RecPlayCall > 0x06'u8 and RecRebind < 0x81'u8
  doAssert MaxRetainedStatusEntries * StatusEntryMaxBytes ==
    MaxRetainedStatusBytes
  doAssert PlaySeatReceiveLimitBytes == 14 + MaxModuleBytes
  doAssert MaxStepsPerSeatPerTick == MaxActiveOverlays + 1
  doAssert MaxReflexCandidates ==
    (2 * (ReflexCandidateRadiusPx div ReflexCandidateSpacingPx) + 1) *
    (2 * (ReflexCandidateRadiusPx div ReflexCandidateSpacingPx) + 1)
