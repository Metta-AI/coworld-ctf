## Fixed-layout binary play_view/play_context encoder.
##
## This is the play-readable engine-to-guest copy. The socket/replay copy stays
## canonical JSON; both encoders consume the same selected `PlayViewModel`, so
## row selection, fog, ordering, and element caps cannot diverge by encoding.
## Guest-to-engine emissions deliberately stay canonical JSON.

import std/[algorithm, options]

import ../ctf/sim_types
import types
import view

type
  BinaryViewProducer* = ref object
    scratch: string

  BinaryContextProducer* = ref object
    scratch: string

  BinarySection = object
    kind: uint16
    recordCount: uint16
    recordStride: uint16
    offset: uint32
    payload: string

const
  BinaryViewMagic = "PV1\0"
  BinaryFrameVersion = 1'u16
  BinaryFrameHeaderBytes* = 32
  BinarySectionEntryBytes* = 12

  BvSelf* = 1'u16
  BvWorld* = 2'u16
  BvZone* = 3'u16
  BvTracks* = 4'u16
  BvAggressors* = 5'u16
  BvKillFeed* = 6'u16
  BvItems* = 7'u16
  BvShouts* = 8'u16
  BvHazardGrenades* = 9'u16
  BvHazardBlastCues* = 10'u16
  BvHazardSprays* = 11'u16
  BvOwnThrow* = 12'u16
  BvStandingIntent* = 13'u16
  BvContextRoster* = 101'u16
  BvContextSelf* = 102'u16
  BvContextModeMap* = 103'u16

  SelfRecordStride* = 32'u16
  WorldRecordStride* = 272'u16
  ZoneRecordStride* = 48'u16
  TrackRecordStride* = 32'u16
  AggressorRecordStride* = 20'u16
  KillFeedRecordStride* = 12'u16
  ItemRecordStride* = 24'u16
  ShoutRecordStride* = 28'u16
  GrenadeRecordStride* = 20'u16
  BlastCueRecordStride* = 12'u16
  SprayRecordStride* = 48'u16
  OwnThrowRecordStride* = 16'u16
  StandingIntentRecordStride* = 200'u16
  ContextRosterRecordStride* = 12'u16
  ContextSelfRecordStride* = 16'u16
  ContextModeMapRecordStride* = 24'u16

  SelfAliveFlag* = 1'u32
  SelfLivesPresentFlag* = 2'u32
  SelfCarryingFlag* = 4'u32
  SelfDownedFlag* = 8'u32
  ObjectivePosPresentFlag* = 1'u32
  ZoneNextPresentFlag* = 1'u32
  ZoneDpsPresentFlag* = 2'u32
  TrackAimPresentFlag* = 1'u32
  TrackHpPresentFlag* = 2'u32
  TrackBountyFlag* = 4'u32
  TrackDownedFlag* = 8'u32
  TrackHasGunFlag* = 16'u32
    ## PERCEPTION(glory-2 §17): appended bit in the SAME reserved flags
    ## word every track row already carries -- no stride change, so this
    ## is ABI-additive: an old-compiled policy's reader simply never tests
    ## this bit and ignores it, same as any other unrecognized flag.
  TrackHasHopperFlag* = 32'u32
  ItemPresentFieldFlag* = 1'u32
  ItemPresentValueFlag* = 2'u32
  AggressorSeatPresentFlag* = 1'u32
  SprayCoversSelfFlag* = 1'u32
  ContextDuoPresentFlag* = 1'u32
  IntentPointPresentFlag* = 1'u32
  IntentMovingGoalFlag* = 2'u32
  IntentIdleAimPresentFlag* = 4'u32
  IntentClampToEndzoneFlag* = 8'u32
  IntentSuppressFireFreezeFlag* = 16'u32
  IntentHoldFireFlag* = 32'u32

proc newBinaryViewProducer*(): BinaryViewProducer =
  BinaryViewProducer(scratch: newStringOfCap(MaxBinaryViewFrameBytes))

proc newBinaryContextProducer*(): BinaryContextProducer =
  BinaryContextProducer(scratch: newStringOfCap(MaxBinaryContextBytes))

proc addByte(bytes: var string, value: int) {.inline.} =
  assert value in 0 .. 255
  bytes.add(char(value))

proc putU8(bytes: var string, value: int) {.inline.} =
  bytes.addByte(value)

proc putU16(bytes: var string, value: uint16) =
  bytes.addByte(int(value and 0xff'u16))
  bytes.addByte(int((value shr 8) and 0xff'u16))

proc putU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.addByte(int((value shr shift) and 0xff'u32))

proc putU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.addByte(int((value shr shift) and 0xff'u64))

proc putI32(bytes: var string, value: int) =
  assert value >= low(int32).int and value <= high(int32).int
  bytes.putU32(cast[uint32](int32(value)))

proc putF64(bytes: var string, value: float) =
  var bits: uint64
  copyMem(addr bits, unsafeAddr value, 8)
  bytes.putU64(bits)

proc align4(bytes: var string) =
  while bytes.len mod 4 != 0:
    bytes.add('\0')

proc modeId(mode: GameMode): int {.inline.} =
  case mode
  of gmCtf: 0
  of gmKoth: 1
  of gmBr: 2

proc teamId(team: Team): int {.inline.} =
  ord(team)

proc objectiveId(state: ObjectiveState): int {.inline.} =
  case state
  of osHome: 0
  of osTaken: 1
  of osCaptured: 2

proc itemId(kind: PlayItemKind): int {.inline.} =
  case kind
  of pikGrenade: 0
  of pikMedkit: 1
  of pikShield: 2
  of pikSpray: 3
  of pikBarrier: 4
  of pikGun: 5
  of pikHopper: 6

proc sprayKindId(kind: PlaySprayHazardKind): int {.inline.} =
  case kind
  of pshVisibleCone: 0
  of pshAnonymousImpact: 1

proc intentKindId(kind: IntentKind): int {.inline.} =
  case kind
  of ikNavigateTo: 0
  of ikHold: 1

proc profileId(profile: CostProfile): int {.inline.} =
  case profile
  of cpDefault: 0
  of cpCarrier: 1
  of cpHunter: 2

proc preferId(tag: PreferTag): int {.inline.} =
  case tag
  of ptWeakened: 0
  of ptIsolated: 1
  of ptRevenge: 2
  of ptBounty: 3

proc microMask(flags: set[MicroFlag]): uint32 =
  for flag in flags:
    result = result or (1'u32 shl ord(flag))

proc teamMask(teams: set[Team]): uint32 =
  for team in teams:
    result = result or (1'u32 shl ord(team))

proc sortedSeats(seats: openArray[SeatRef]): seq[uint8] =
  var names: seq[tuple[name: string, seat: uint8]]
  for seat in seats:
    names.add(($seat, uint8(seat)))
  names.sort(proc(a, b: tuple[name: string, seat: uint8]): int =
    cmp(a.name, b.name))
  for index, item in names:
    if index == 0 or item.name != names[index - 1].name:
      result.add(item.seat)

proc payloadSection(kind, count, stride: uint16, payload: string): BinarySection =
  assert stride > 0
  assert payload.len mod 4 == 0
  BinarySection(kind: kind, recordCount: count, recordStride: stride,
    payload: payload)

proc selfPayload(value: PlaySelf): string =
  var flags = 0'u32
  if value.alive: flags = flags or SelfAliveFlag
  if value.lives.isSome: flags = flags or SelfLivesPresentFlag
  if value.carrying: flags = flags or SelfCarryingFlag
  if value.downed: flags = flags or SelfDownedFlag
  result.putU32(flags)
  result.putI32(value.pos.x)
  result.putI32(value.pos.y)
  result.putI32(value.hp)
  result.putF64(value.hpFrac)
  result.putU32(uint32(value.aimBrads))
  result.putI32(if value.lives.isSome: value.lives.get else: 0)

proc worldPayload(model: PlayViewModel): string =
  result.putU32(0)
  result.putU32(uint32(model.aliveTeams))
  result.putU32(uint32(model.objectives.len))
  result.putU32(0)
  for index in 0 ..< 16:
    if index < model.objectives.len:
      let objective = model.objectives[index]
      result.putU32(if objective.pos.isSome: ObjectivePosPresentFlag else: 0'u32)
      result.putU8(objective.team.teamId)
      result.putU8(objective.state.objectiveId)
      result.putU16(0)
      result.putI32(if objective.pos.isSome: objective.pos.get.x else: 0)
      result.putI32(if objective.pos.isSome: objective.pos.get.y else: 0)
    else:
      for _ in 0 ..< 16:
        result.putU8(0)

proc zonePayload(zone: PlayZone): string =
  var flags = 0'u32
  if zone.next.isSome: flags = flags or ZoneNextPresentFlag
  if zone.dps != 0: flags = flags or ZoneDpsPresentFlag
  result.putU32(flags)
  result.putI32(zone.phase)
  result.putI32(zone.ticksToShrink)
  result.putI32(zone.dps)
  result.putI32(zone.current.x)
  result.putI32(zone.current.y)
  result.putI32(zone.current.w)
  result.putI32(zone.current.h)
  let next = if zone.next.isSome: zone.next.get else: PlayRect()
  result.putI32(next.x)
  result.putI32(next.y)
  result.putI32(next.w)
  result.putI32(next.h)

proc tracksPayload(rows: openArray[PlayTrack]): string =
  for row in rows:
    var flags = 0'u32
    if row.aimBrads.isSome: flags = flags or TrackAimPresentFlag
    if row.hp.isSome: flags = flags or TrackHpPresentFlag
    if row.bounty: flags = flags or TrackBountyFlag
    if row.downed: flags = flags or TrackDownedFlag
    if row.hasGun: flags = flags or TrackHasGunFlag
    if row.hasHopper: flags = flags or TrackHasHopperFlag
    result.putU32(flags)
    result.putU32(uint32(row.seat))
    result.putU32(uint32(row.team.teamId))
    result.putI32(row.pos.x)
    result.putI32(row.pos.y)
    result.putU32(row.freshTick)
    result.putI32(if row.aimBrads.isSome: row.aimBrads.get else: 0)
    result.putI32(if row.hp.isSome: row.hp.get else: 0)

proc aggressorsPayload(rows: openArray[PlayAggressor]): string =
  for row in rows:
    result.putU32(if row.seat.isSome: AggressorSeatPresentFlag else: 0'u32)
    result.putU32(row.tick)
    result.putU32(uint32(row.dirBrads))
    result.putU32(if row.seat.isSome: uint32(row.seat.get) else: 0'u32)
    result.putU32(0)

proc killFeedPayload(rows: openArray[PlayKillFeedRow]): string =
  for row in rows:
    result.putU32(row.tick)
    result.putU32(uint32(row.killerTeam.teamId))
    result.putU32(uint32(row.victimSeat))

proc itemsPayload(rows: openArray[PlayItem]): string =
  for row in rows:
    var flags = 0'u32
    if row.present.isSome:
      flags = flags or ItemPresentFieldFlag
      if row.present.get:
        flags = flags or ItemPresentValueFlag
    result.putU32(flags)
    result.putU32(uint32(row.kind.itemId))
    result.putI32(row.pos.x)
    result.putI32(row.pos.y)
    result.putU32(row.freshTick)
    result.putU32(0)

proc shoutsPayload(rows: openArray[PlayShout], sectionOffset: int): string =
  let textBase = sectionOffset + rows.len * int(ShoutRecordStride)
  var textBlob = newStringOfCap(rows.len * 10)
  for row in rows:
    let textOffset = textBase + textBlob.len
    result.putU32(uint32(row.team.teamId))
    result.putU32(if row.slotLetter.len == 0: 0'u32 else: uint32(ord(row.slotLetter[0])))
    result.putU32(uint32(textOffset))
    result.putU32(uint32(row.text.len))
    result.putI32(row.pos.x)
    result.putI32(row.pos.y)
    result.putU32(row.tick)
    textBlob.add(row.text)
  result.add(textBlob)
  result.align4()

proc grenadePayload(rows: openArray[PlayGrenadeHazard]): string =
  for row in rows:
    result.putI32(row.pos.x)
    result.putI32(row.pos.y)
    result.putI32(row.predictedBlastPos.x)
    result.putI32(row.predictedBlastPos.y)
    result.putI32(row.ticksToBlast)

proc blastCuePayload(rows: openArray[PlayBlastCue]): string =
  for row in rows:
    result.putI32(row.pos.x)
    result.putI32(row.pos.y)
    result.putU32(row.tick)

proc spraysPayload(rows: openArray[PlaySprayHazard]): string =
  for row in rows:
    result.putU32(if row.kind == pshVisibleCone and row.coversSelf:
      SprayCoversSelfFlag else: 0'u32)
    result.putU32(uint32(row.kind.sprayKindId))
    result.putU32(row.tick)
    case row.kind
    of pshVisibleCone:
      result.putU32(uint32(row.attackerSeat))
      result.putI32(row.origin.x)
      result.putI32(row.origin.y)
      result.putU32(uint32(row.aimBrads))
      result.putI32(row.reachPx)
      result.putI32(row.maxWidthPx)
      result.putI32(0)
      result.putI32(0)
      result.putU32(0)
    of pshAnonymousImpact:
      result.putU32(0)
      result.putI32(0)
      result.putI32(0)
      result.putU32(0)
      result.putI32(0)
      result.putI32(0)
      result.putI32(row.impactPos.x)
      result.putI32(row.impactPos.y)
      result.putU32(uint32(row.incomingDirBrads))

proc ownThrowPayload(row: PlayOwnThrow): string =
  result.putI32(row.target.x)
  result.putI32(row.target.y)
  result.putU32(row.releaseTick)
  result.putI32(row.blastRadius)

proc intentPayload(intent: Intent): string =
  if intent.reason.len > IntentReasonMaxBytes:
    raise newException(ValueError, "binary standing intent reason exceeds cap")
  if intent.combat.noShoot.seats.len > MaxPlayers or
      intent.combat.protect.seats.len > MaxPlayers:
    raise newException(ValueError, "binary standing intent has too many seats")
  if intent.combat.prefer.len > 4:
    raise newException(ValueError, "binary standing intent has too many prefer tags")
  var flags = 0'u32
  if intent.point.isSome: flags = flags or IntentPointPresentFlag
  if intent.movingGoal: flags = flags or IntentMovingGoalFlag
  if intent.idleAimCenterBrads.isSome: flags = flags or IntentIdleAimPresentFlag
  if intent.clampToEndzone: flags = flags or IntentClampToEndzoneFlag
  if intent.suppressFireFreeze: flags = flags or IntentSuppressFireFreezeFlag
  if intent.combat.holdFire: flags = flags or IntentHoldFireFlag
  result.putU32(flags)
  result.putU32(uint32(intent.kind.intentKindId))
  result.putU32(uint32(intent.profile.profileId))
  result.putU32(0)
  result.putF64(intent.arriveRadius)
  let point = if intent.point.isSome: intent.point.get else: MapPoint()
  result.putI32(point.x)
  result.putI32(point.y)
  result.putI32(if intent.idleAimCenterBrads.isSome:
    intent.idleAimCenterBrads.get else: 0)
  result.putU32(intent.micro.microMask)
  result.putU32(intent.combat.noShoot.teams.teamMask)
  result.putU32(intent.combat.protect.teams.teamMask)
  let noShootSeats = intent.combat.noShoot.seats.sortedSeats
  let protectSeats = intent.combat.protect.seats.sortedSeats
  result.putU32(uint32(noShootSeats.len))
  result.putU32(uint32(protectSeats.len))
  result.putU32(uint32(intent.combat.prefer.len))
  result.putU32(0)
  for index in 0 ..< 32:
    result.putU8(if index < noShootSeats.len: int(noShootSeats[index]) else: 0)
  for index in 0 ..< 32:
    result.putU8(if index < protectSeats.len: int(protectSeats[index]) else: 0)
  for index in 0 ..< 4:
    result.putU8(if index < intent.combat.prefer.len:
      intent.combat.prefer[index].preferId else: 0)
  result.putU32(uint32(intent.reason.len))
  result.add(intent.reason)
  for _ in intent.reason.len ..< 64:
    result.putU8(0)
  assert result.len == int(StandingIntentRecordStride)

proc layoutSections(sections: var seq[BinarySection], headerBytes: int) =
  var offset = headerBytes + sections.len * BinarySectionEntryBytes
  for section in sections.mitems:
    section.offset = uint32(offset)
    offset += section.payload.len

proc buildFrame(mode: GameMode, tick: uint32, epoch: uint64,
                sections: var seq[BinarySection], cap: int): string =
  if sections.len > 255:
    raise newException(ValueError, "binary frame has too many sections")
  sections.layoutSections(BinaryFrameHeaderBytes)
  let frameBytes = if sections.len == 0: BinaryFrameHeaderBytes
    else: int(sections[^1].offset) + sections[^1].payload.len
  if frameBytes > cap:
    raise newException(ValueError, "binary frame exceeds byte cap")

  result = newStringOfCap(frameBytes)
  result.add(BinaryViewMagic)
  result.putU16(BinaryFrameVersion)
  result.putU8(mode.modeId)
  result.putU8(sections.len)
  result.putU32(tick)
  result.putU32(0)
  result.putU64(epoch)
  result.putU32(uint32(frameBytes))
  result.putU32(0)

  for section in sections:
    result.putU16(section.kind)
    result.putU16(section.recordCount)
    result.putU16(section.recordStride)
    result.putU16(0)
    result.putU32(section.offset)
  for section in sections:
    assert result.len == int(section.offset)
    result.add(section.payload)
  assert result.len == frameBytes

proc playViewSections(model: PlayViewModel): seq[BinarySection] =
  result.add(payloadSection(BvSelf, 1, SelfRecordStride,
    model.self.selfPayload))
  result.add(payloadSection(BvWorld, 1, WorldRecordStride,
    model.worldPayload))
  if model.zone.isSome:
    result.add(payloadSection(BvZone, 1, ZoneRecordStride,
      model.zone.get.zonePayload))
  if model.tracks.len > 0:
    result.add(payloadSection(BvTracks, uint16(model.tracks.len),
      TrackRecordStride, model.tracks.tracksPayload))
  if model.aggressors.len > 0:
    result.add(payloadSection(BvAggressors, uint16(model.aggressors.len),
      AggressorRecordStride, model.aggressors.aggressorsPayload))
  if model.killFeed.len > 0:
    result.add(payloadSection(BvKillFeed, uint16(model.killFeed.len),
      KillFeedRecordStride, model.killFeed.killFeedPayload))
  if model.items.len > 0:
    result.add(payloadSection(BvItems, uint16(model.items.len),
      ItemRecordStride, model.items.itemsPayload))
  if model.shouts.len > 0:
    result.add(payloadSection(BvShouts, uint16(model.shouts.len),
      ShoutRecordStride, ""))
  if model.hazards.grenades.len > 0:
    result.add(payloadSection(BvHazardGrenades,
      uint16(model.hazards.grenades.len), GrenadeRecordStride,
      model.hazards.grenades.grenadePayload))
  if model.hazards.blastCues.len > 0:
    result.add(payloadSection(BvHazardBlastCues,
      uint16(model.hazards.blastCues.len), BlastCueRecordStride,
      model.hazards.blastCues.blastCuePayload))
  if model.hazards.sprays.len > 0:
    result.add(payloadSection(BvHazardSprays,
      uint16(model.hazards.sprays.len), SprayRecordStride,
      model.hazards.sprays.spraysPayload))
  if model.hazards.ownThrow.isSome:
    result.add(payloadSection(BvOwnThrow, 1, OwnThrowRecordStride,
      model.hazards.ownThrow.get.ownThrowPayload))
  if model.intent.isSome:
    result.add(payloadSection(BvStandingIntent, 1, StandingIntentRecordStride,
      model.intent.get.intentPayload))

  result.layoutSections(BinaryFrameHeaderBytes)
  for section in result.mitems:
    if section.kind == BvShouts:
      section.payload = model.shouts.shoutsPayload(int(section.offset))

proc encodeBinaryPlayView*(model: PlayViewModel): string =
  var sections = model.playViewSections
  buildFrame(model.mode, model.tick, model.epoch, sections,
    MaxBinaryViewFrameBytes)

proc encodeBinaryPlayView*(source: PlayViewSource): string =
  encodeBinaryPlayView(selectPlayView(source, MaxViewFrameBytes))

proc buildBinaryPlayView*(producer: BinaryViewProducer,
                          model: PlayViewModel): string =
  producer.scratch.setLen(0)
  producer.scratch.add(model.encodeBinaryPlayView)
  result = producer.scratch

proc buildBinaryPlayView*(producer: BinaryViewProducer,
                          source: PlayViewSource): string =
  producer.buildBinaryPlayView(selectPlayView(source, MaxViewFrameBytes))

proc buildBinaryPlayView*(model: PlayViewModel): string =
  newBinaryViewProducer().buildBinaryPlayView(model)

proc buildBinaryPlayView*(source: PlayViewSource): string =
  newBinaryViewProducer().buildBinaryPlayView(source)

proc contextRosterPayload(rows: openArray[PlayContextRosterRow]): string =
  for row in rows:
    result.putU32(uint32(row.seat))
    result.putU32(uint32(row.team.teamId))
    result.putU32(if row.control == pccPlay: 1'u32 else: 0'u32)

proc contextSelfPayload(source: PlayContextSource): string =
  result.putU32(if source.duoPartner.isSome: ContextDuoPresentFlag else: 0'u32)
  result.putU32(uint32(source.selfSeat))
  result.putU32(uint32(source.selfTeam.teamId))
  result.putI32(if source.duoPartner.isSome: source.duoPartner.get else: 0)

proc contextModeMapPayload(source: PlayContextSource, sectionOffset: int): string =
  let nameOffset = sectionOffset + int(ContextModeMapRecordStride)
  result.putI32(source.mapWidth)
  result.putI32(source.mapHeight)
  result.putI32(source.gunRange)
  result.putI32(source.viewInterval)
  result.putU32(uint32(nameOffset))
  result.putU32(uint32(source.mapName.len))
  result.add(source.mapName)
  result.align4()

proc validateContextSource(source: PlayContextSource) =
  if source.roster.len < 2 or source.roster.len > MaxPlayers:
    raise newException(ValueError, "binary play_context roster must have 2..32 rows")
  # 2026-09-05 solo-BR (16x1) support: duo_partner is optional in br mode now
  # (solo BR seats have no partner); duo behavior unchanged. The old invariant
  # required duo_partner whenever mode == br, which was duo-era and does not
  # hold for one-seat BR teams. contextSelfPayload above already tolerates
  # duoPartner.isNone (flag 0, partner value 0), so no change needed there.
  if source.duoPartner.isSome and source.mode != gmBr:
    raise newException(ValueError,
      "binary play_context duo_partner is only valid in br mode")

proc contextSections(source: PlayContextSource): seq[BinarySection] =
  source.validateContextSource()
  result.add(payloadSection(BvContextRoster, uint16(source.roster.len),
    ContextRosterRecordStride, source.roster.contextRosterPayload))
  result.add(payloadSection(BvContextSelf, 1, ContextSelfRecordStride,
    source.contextSelfPayload))
  result.add(payloadSection(BvContextModeMap, 1, ContextModeMapRecordStride, ""))
  result.layoutSections(BinaryFrameHeaderBytes)
  for section in result.mitems:
    if section.kind == BvContextModeMap:
      section.payload = source.contextModeMapPayload(int(section.offset))

proc encodeBinaryPlayContext*(source: PlayContextSource): string =
  var sections = source.contextSections
  buildFrame(source.mode, 0'u32, 0'u64, sections, MaxBinaryContextBytes)

proc buildBinaryPlayContext*(producer: BinaryContextProducer,
                             source: PlayContextSource): string =
  producer.scratch.setLen(0)
  producer.scratch.add(source.encodeBinaryPlayContext)
  result = producer.scratch

proc buildBinaryPlayContext*(source: PlayContextSource): string =
  newBinaryContextProducer().buildBinaryPlayContext(source)
