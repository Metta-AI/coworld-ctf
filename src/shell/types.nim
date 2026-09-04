## The play-calling shell's shared contract types and named constants.
##
## This file is the contracts-first commit of
## docs/designs/strategy-play-calling-shell-2026-08-29.md: the types and
## limits all three implementation lanes (body, seat/lobby, runtime) build
## against, landed before any lane starts so the seams are never negotiated
## in flight. Sections cited below are that design's.
##
## `season2Shell` defaults on, but runtime shell behavior remains conjunctive:
## it is reachable only with at least one `control: "play"` seat. An all-input
## roster uses the direct-input path byte-identically; explicit false selects
## a deprecated live mode (§3.2).
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
    handoff*: string           ## §4.1 amendment (owner spec 2026-09-02): the
                               ## STANDING give-item declaration — "" (neutral,
                               ## omitted) or one of HandoffItems. gmBr only
                               ## (a duo fact, rejected elsewhere like duo
                               ## refs). The target is NOT a field: it is
                               ## always THE duo partner, resolved by the
                               ## engine at execution (sim.declareHandoff, the
                               ## consent seam). While the standing order
                               ## carries it the engine keeps the declaration
                               ## current; movement semantics are untouched.

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

  FaultCode* = enum
    ## The stable, policy-facing cause of a play fault or retune refusal.
    ## Guest trap kinds are wasmtime's own trap codes; the rest are the
    ## engine's ABI verdicts. The string is the wire value (`code` in the
    ## status entry) and the ordinal is the replay annotation byte, so
    ## NEVER reorder or renumber: append only.
    fcUnknown = "unknown"                ## legacy records minted before codes
    fcOutOfFuel = "outOfFuel"            ## StepFuel/InitFuel/ManifestFuel spent
    fcEpochDeadline = "epochDeadline"    ## the wall-clock backstop (§7.0)
    fcUnreachable = "unreachable"        ## `unreachable` executed
    fcStackOverflow = "stackOverflow"
    fcMemoryOutOfBounds = "memoryOutOfBounds"
    fcTableOutOfBounds = "tableOutOfBounds"
    fcIndirectCallToNull = "indirectCallToNull"
    fcBadSignature = "badSignature"
    fcIntegerOverflow = "integerOverflow"
    fcIntegerDivisionByZero = "integerDivisionByZero"
    fcBadConversionToInteger = "badConversionToInteger"
    fcHeapMisaligned = "heapMisaligned"
    fcTrap = "trap"                      ## any other wasmtime trap kind
    fcHostError = "hostError"            ## a runtime error that was not a guest trap
    fcReturnedNonzero = "returnedNonzero"  ## play_init / play_step returned nonzero
    fcRefused = "refused"                ## play_retune returned nonzero (§7.2)
    fcAbiViolation = "abiViolation"      ## host import misuse, emit flood, bad alloc, rejected manifest emission
    fcInstantiateFailed = "instantiateFailed"
    fcRetuneAbsent = "retuneAbsent"      ## play_retune export missing

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
      faultCode*: FaultCode
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
      faultCode*: FaultCode
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

  # ── Pre-match vote phase (#319/#322, Maxwell's side): RESERVED ────────
  # Opcodes 0xA4 (BallotCast, client→server) and 0xB3 (VoteState,
  # server→client) plus replay record 0x17 (vote records, hash-coupled
  # like 0x14–0x16, no manifest arm) are claimed by the vote phase and
  # must not be reused. Byte layouts land with that implementation after
  # our byte-exact verification of #322; nothing here defines them yet.
  OpBallotCastReserved* = 0xA4'u8
  OpVoteStateReserved* = 0xB3'u8

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
  RecVoteReserved* = 0x17'u8
    ## RESERVED for the pre-match vote phase (#319/#322): hash-coupled
    ## like 0x14–0x16, no manifest arm. Layout lands with that
    ## implementation; do not reuse the number.

  # ── §4.3: protocol limits (wire constants of the protocol version) ────
  MaxModuleBytes* = 262144            ## raw wasm bytes per module
  MaxModulesPerSeatPerEpisode* = 16   ## admitted uploads; nonrefundable
                                      ## except byte-identical re-uploads
  MaxUploadBytesPerSeatPerEpisode* = 2097152
  MaxUploadsPerSeatPerTick* = 1
  MaxCallsPerSeatPerTick* = 2
  MaxCallBytes* = 4096                ## canonical ladder JSON (Appendix P)
  MaxLadderEntries* = 16
  MaxActiveOverlays* = 2              ## bounds guest steps/seat/tick at 3;
                                      ## P0-retuned 4→2 (the worst tick
                                      ## drops 160→96 guest steps)
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
  HandoffItems* = ["bandage", "gun", "hopper"]
    ## §4.1 amendment: the closed give-item vocabulary of the Intent's
    ## `handoff` field — the exact strings sim.declareHandoff accepts (the
    ## engine seam is the authority; this list mirrors it for validation).

  # The five config fields' defaults and ranges (ViewIntervalTicks*,
  # LobbyChatTicks*, PlaySeatBindTicks*) live in ctf/sim_types.nim beside
  # the GameConfig fields they default, because sim_config validates them
  # and src/ctf never imports src/shell; they are re-exported here.

  # ── §6.1: runtime budgets (constants of ABI version 1) ────────────────
  ShellAbiVersion* = 1
  MaxInstancePages* = 16              ## 64 KiB pages: 1 MiB linear memory
  MaxFunctionsPerModule* = 4096
    ## P0 (new, James 2026-08-30): §6.2 interface-check cap on defined
    ## functions per module, one lever that keeps compiled-cache reservation
    ## honest. Generous for real plays (reference plays are dozens of
    ## functions); provisional until the freeze.
  MaxInstanceTableElements* = MaxFunctionsPerModule
    ## P0 provisional (James, 2026-08-31): a play has no legitimate funcref
    ## table larger than its maximum defined function count, and 4096 table
    ## elements bound table memory trivially.
  MaxInstancesPerSeat* = 16           ## one per ladder entry
  StepFuel* = 50_000
    ## P0-retuned (James, 2026-08-30) from the measured spike: 200k fuel x
    ## 160 steps metered ~32M guest instructions/tick, 8-13x over the
    ## runtime's share. Provisional until the freeze (native x86 + quiet
    ## window runs).
  InitFuel* = 500_000
    ## P0-retuned with StepFuel; provisional until the freeze.
  ManifestFuel* = 1_000_000
    ## P0: provisional, same rule.
  MaxInitsPerSeatPerTick* = 1
  MaxInitsPerTick* = 2                ## server-wide, round-robin by seat;
                                      ## P0-retuned 4→2
  MaxAllocsPerInvocation* = 2
  MaxStepsPerSeatPerTick* = 3         ## MaxActiveOverlays + 1 controller
  MaxEmitsPerStep* = 2                ## P0-retuned 4→2 (emit validation
                                      ## measured ~62 µs/emit; P3 carries a
                                      ## ≤15 µs engineering acceptance)
  MaxEmitBytes* = 4096
  MaxSpatialCallsPerStep* = 2         ## nearest_reachable + nearest_cover;
                                      ## PM freeze ruling (2026-08-31) after
                                      ## lane C measured the real scorer at
                                      ## 19.9-20.2 us/call at the 1536-post
                                      ## cap (linear in the cap, ~13.3 us at
                                      ## the frozen 1024); de-provisioned
                                      ## from P0's 8→4 retune to fit the
                                      ## runtime share.
  MaxCoverRadiusPx* = 331
    ## P0-adjusted (James, 2026-08-30): Battle Royale's derived weapon range
    ## (§4.2's equal-share formula) — cover beyond the range anyone can
    ## shoot from is tactically marginal, and the original 600 was
    ## impossible on the real BR map (2,564 posts in a 600px disc vs the
    ## old 512 cap, verified identical against stencil's own atlas; no
    ## radius ≥ 256 fits 512 there). Still provisional until the full
    ## launch-map census freezes it (§10).
  MaxCoverThreats* = 8
  MaxCoverPostsExamined* = 1024
    ## PM freeze ruling (2026-08-31): atlas posts are minted only on the
    ## 16px candidate grid, and the generator census under thinning fits
    ## below 1024 with headroom. Asserted per map at load in play-seat
    ## configurations; denser maps are rejected rather than spilling host
    ## call work past the frozen cap.
  MaxRouteFieldsPerSeat* = 4          ## §3.1 seat layer
  MaxDuckEntriesPerSeat* = 256
  ReflexCandidateSpacingPx* = 16      ## Appendix R.2 planEscape lattice
  ReflexCandidateRadiusPx* = 256
  MaxReflexCandidates* = 1089         ## (2·16+1)²
  MaxLogCallsPerInvocation* = 4
  MaxLogBytesPerCall* = 256
  MaxBinaryViewFrameBytes* = 8192
    ## PM-ratified binary view split (2026-08-31): the play-readable
    ## fixed-layout binary frame gets its own fuel-derived cap. The
    ## socket/replay JSON copy remains governed by MaxViewFrameBytes.
  MaxBinaryContextBytes* = 8192
    ## Binary play_init context cap for the fixed-layout context frame. The
    ## 60% rule would allow ~150 KB; the actual context frame is ~140 B;
    ## 8,192 is chosen for symmetry with the view cap and bounded-allocation
    ## hygiene, not derived. The socket/replay JSON copy remains governed by
    ## MaxContextBytes.
  MaxViewFrameBytes* = 32768
  MaxContextBytes* = 65536
  ValidatorRadiusPx* = 256            ## stencil's 32 × NavCell; an ENGINE
                                      ## constant, asserted equal (§6.1)
  MaxValidatorTableBytes* = 268435456
    ## P0: provisional until the giant-field validator rasters are measured.
  MaxPendingCompileBytes* = 8388608
  MaxCompileCommitsPerTick* = 8
  MaxCompiledCacheBytes* = 268435456
    ## P0: provisional until compile-expansion measurement.
  MinCompiledReservationBytes* = 524288
    ## P0: provisional floor for compiled-cache admission reservation.
  CompiledBytesPerRawByte* = 16
    ## P0: provisional multiplier for compiled-cache admission reservation.
    ## James ruling (2026-08-31): reserve max(raw_bytes * 16, 512 KiB).
    ##
    ## Measured serialized artifacts:
    ## - x86_64-linux hello_play: raw 6,055, serialized 37,376, ratio 6.17x.
    ## - x86_64-linux edge_ride: raw 28,147, serialized 109,200, ratio 3.88x.
    ## - aarch64-linux hello_play: raw 6,065, serialized 266,752, ratio 43.98x.
    ## - aarch64-linux edge_ride: raw 28,147, serialized 334,480, ratio 11.88x.
    ## - aarch64-macos hello_play: raw 6,065, serialized 86,536, ratio 14.27x.
    ## - aarch64-macos edge_ride: raw 28,226, serialized 154,264, ratio 5.47x.
    ##
    ## The floor is the load-bearing half: small-play artifact overhead is
    ## fixed, not proportional. hello_play is about 6 KiB raw, clears its old
    ## 48 KiB x86 reservation by only 22%, and fails the old reservation
    ## elsewhere. Without a floor, legitimately small plays become a coin flip.
    ##
    ## Admission must not differ by architecture: "works in prod but rejected on
    ## your laptop" and the reverse are both corrosive. Developers, demos, and
    ## CI run on arm64 too, so 16x plus the 512 KiB floor covers the worst arm64
    ## observations rather than only the comfortable x86 numbers.
    ##
    ## Floor sizing evidence: the first-draft 256 KiB floor was contradicted by
    ## aarch64-linux hello_play at 266,752 serialized bytes against a 262,144
    ## byte reservation, a 4,608-byte / 1.76% miss. That is exactly the
    ## small-play coin flip the floor exists to abolish: one compiler bump
    ## should not change whether the reference hello play admits.
    ##
    ## Cost: a maximum-size 256 KiB module now reserves 4 MiB, still hundreds of
    ## modules in a 256 MiB store. Raising the store cap later is cheaper than
    ## debugging split-brain admission semantics.
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

proc compiledReservationBytes*(rawBytes: int): int {.inline.} =
  max(rawBytes * CompiledBytesPerRawByte, MinCompiledReservationBytes)

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
