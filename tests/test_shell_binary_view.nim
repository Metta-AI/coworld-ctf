## Fixed-layout binary play_view/play_context frame tests.

import std/[json, options, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[binary_view, types, view]

proc p(x, y: int): PlayPoint = (x, y)

type
  SectionInfo = object
    kind, recordCount, recordStride: int
    offset: int

proc readU8(bytes: string, offset: int): int =
  ord(bytes[offset])

proc readU16(bytes: string, offset: int): int =
  ord(bytes[offset]) or (ord(bytes[offset + 1]) shl 8)

proc readU32(bytes: string, offset: int): uint32 =
  for shift in countup(0, 24, 8):
    result = result or (uint32(ord(bytes[offset + shift div 8])) shl shift)

proc readI32(bytes: string, offset: int): int =
  int(cast[int32](bytes.readU32(offset)))

proc readU64(bytes: string, offset: int): uint64 =
  for shift in countup(0, 56, 8):
    result = result or (uint64(ord(bytes[offset + shift div 8])) shl shift)

proc sections(bytes: string): seq[SectionInfo] =
  let count = bytes.readU8(7)
  for index in 0 ..< count:
    let offset = BinaryFrameHeaderBytes + index * BinarySectionEntryBytes
    result.add(SectionInfo(kind: bytes.readU16(offset),
      recordCount: bytes.readU16(offset + 2),
      recordStride: bytes.readU16(offset + 4),
      offset: int(bytes.readU32(offset + 8))))

proc section(bytes: string, kind: uint16): Option[SectionInfo] =
  for item in bytes.sections:
    if item.kind == int(kind):
      return some(item)
  none(SectionInfo)

proc hex(bytes: string): string =
  const Digits = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for c in bytes:
    let value = ord(c)
    result.add(Digits[value shr 4])
    result.add(Digits[value and 0xf])

proc fixtureHex(path: string): string =
  readFile(path).splitWhitespace().join("")

proc assertHeaderAndTable(bytes: string, mode: GameMode, tick: uint32,
                          epoch: uint64) =
  check bytes[0 .. 3] == "PV1\0"
  check bytes.readU16(4) == 1
  check bytes.readU8(6) == ord(mode)
  check bytes.readU32(8) == tick
  check bytes.readU32(12) == 0'u32
  check bytes.readU64(16) == epoch
  check int(bytes.readU32(24)) == bytes.len
  check bytes.readU32(28) == 0'u32
  var previousOffset = BinaryFrameHeaderBytes + bytes.readU8(7) *
    BinarySectionEntryBytes
  for item in bytes.sections:
    check item.recordStride > 0
    check item.recordStride mod 4 == 0
    check item.offset mod 4 == 0
    check item.offset >= previousOffset
    check item.offset + item.recordCount * item.recordStride <= bytes.len
    previousOffset = item.offset + item.recordCount * item.recordStride

proc baseSource(): PlayViewSource =
  PlayViewSource(
    tick: 1441'u32,
    mode: gmBr,
    epoch: 99'u64,
    self: PlaySelf(pos: p(100, 100), hp: 7, hpFrac: 0.7,
      aimBrads: 64, alive: true),
    aliveTeams: 5,
    zone: some(PlayZone(phase: 2, current: PlayRect(x: 0, y: 0, w: 500, h: 500),
      ticksToShrink: 120, dps: 1)))

proc richSource(): PlayViewSource =
  result = baseSource()
  result.intent = some(Intent(kind: ikNavigateTo,
    point: some(MapPoint(x: 200, y: 180)),
    arriveRadius: 24.0,
    movingGoal: true,
    profile: cpCarrier,
    micro: {mfPeekDuck, mfFormationBias},
    idleAimCenterBrads: some(128),
    combat: CombatPolicy(
      noShoot: ProtectedSet(teams: {Blue, Red},
        seats: @[SeatRef(4'u8), SeatRef(12'u8), SeatRef(10'u8),
                 SeatRef(4'u8)]),
      protect: ProtectedSet(seats: @[SeatRef(2'u8)]),
      prefer: @[ptBounty, ptWeakened],
      holdFire: true)))
  result.tracks = @[
    PlayTrack(seat: 5, team: Blue, pos: p(160, 100),
      aimBrads: some(9), hp: some(3), freshTick: 1200),
    PlayTrack(seat: 7, team: Green, pos: p(100, 140), freshTick: 1201),
    PlayTrack(seat: 2, team: Red, pos: p(140, 100),
      aimBrads: some(32), hp: some(9), freshTick: 1202, bounty: true)]
  result.items = @[
    PlayItem(eventId: 30, kind: pikMedkit, pos: p(400, 400),
      present: some(true), freshTick: 20),
    PlayItem(eventId: 20, kind: pikGrenade, pos: p(120, 100),
      present: some(false), freshTick: 22),
    PlayItem(eventId: 10, kind: pikShield, pos: p(130, 100),
      freshTick: 22)]
  result.aggressors = @[
    PlayAggressor(eventId: 5, tick: 100, dirBrads: 64),
    PlayAggressor(eventId: 4, tick: 120, dirBrads: 32, seat: some(3))]
  result.killFeed = @[
    PlayKillFeedRow(eventId: 9, tick: 91, killerTeam: Red, victimSeat: 7),
    PlayKillFeedRow(eventId: 8, tick: 99, killerTeam: Blue, victimSeat: 2)]
  result.shouts = @[
    PlayShout(eventId: 3, team: Blue, slotLetter: "B", text: "hold",
      pos: p(108, 100), tick: 88),
    PlayShout(eventId: 2, team: Red, slotLetter: "A", text: "go",
      pos: p(104, 100), tick: 88),
    PlayShout(eventId: 1, team: Blue, slotLetter: "C", text: "east",
      pos: p(101, 101), tick: 90)]
  result.hazards.grenades = @[
    PlayGrenadeHazard(eventId: 3, coversSelf: false, pos: p(300, 300),
      predictedBlastPos: p(300, 300), ticksToBlast: 1),
    PlayGrenadeHazard(eventId: 1, coversSelf: true, pos: p(200, 200),
      predictedBlastPos: p(200, 200), ticksToBlast: 9),
    PlayGrenadeHazard(eventId: 2, coversSelf: true, pos: p(150, 150),
      predictedBlastPos: p(150, 150), ticksToBlast: 3)]
  result.hazards.blastCues = @[
    PlayBlastCue(eventId: 2, coversSelf: false, pos: p(190, 190), tick: 40),
    PlayBlastCue(eventId: 1, coversSelf: true, pos: p(500, 500), tick: 10)]
  result.hazards.ownThrow = some(PlayOwnThrow(target: p(240, 260),
    releaseTick: 1450, blastRadius: 96))
  result.hazards.sprays = @[
    PlaySprayHazard(kind: pshAnonymousImpact, eventId: 12, coversSelf: true,
      tick: 80, impactPos: p(102, 100), incomingDirBrads: 192),
    PlaySprayHazard(kind: pshVisibleCone, eventId: 11, coversSelf: true,
      tick: 70, attackerSeat: 8, origin: p(120, 120), aimBrads: 33,
      reachPx: 331, maxWidthPx: 96),
    PlaySprayHazard(kind: pshVisibleCone, eventId: 10, coversSelf: false,
      tick: 100, attackerSeat: 9, origin: p(130, 130), aimBrads: 40,
      reachPx: 331, maxWidthPx: 96)]

proc maxSource(): PlayViewSource =
  result = baseSource()
  result.tick = 12345'u32
  result.intent = richSource().intent
  for seat in 0 ..< 32:
    result.tracks.add(PlayTrack(seat: seat, team: Team(seat mod 16),
      pos: p(100 + seat * 3, 200 + seat), aimBrads: some(seat mod 256),
      hp: some(seat), freshTick: uint32(5000 - seat), bounty: seat mod 3 == 0))
    result.items.add(PlayItem(eventId: uint64(seat),
      kind: PlayItemKind(seat mod 5), pos: p(300 + seat, 400 - seat),
      present: some(seat mod 2 == 0), freshTick: uint32(6000 - seat)))
    result.killFeed.add(PlayKillFeedRow(eventId: uint64(seat),
      tick: uint32(7000 - seat), killerTeam: Team(seat mod 16),
      victimSeat: 31 - seat))
    result.shouts.add(PlayShout(eventId: uint64(seat), team: Team(seat mod 16),
      slotLetter: $char(ord('A') + seat mod 26), text: "contact",
      pos: p(500 + seat, 700 - seat), tick: uint32(8000 - seat)))
  for index in 0 ..< 16:
    result.aggressors.add(PlayAggressor(eventId: uint64(index),
      tick: uint32(9000 - index), dirBrads: index * 7,
      seat: if index mod 2 == 0: some(index) else: none(int)))
  for index in 0 ..< 8:
    result.hazards.grenades.add(PlayGrenadeHazard(eventId: uint64(index),
      coversSelf: index == 0, pos: p(800 + index, 820 + index),
      predictedBlastPos: p(810 + index, 830 + index),
      ticksToBlast: 20 - index))
    result.hazards.sprays.add(if index mod 2 == 0:
      PlaySprayHazard(kind: pshVisibleCone, eventId: uint64(index),
        coversSelf: index == 0, tick: uint32(9100 - index),
        attackerSeat: index, origin: p(700 + index, 600 + index),
        aimBrads: index * 8, reachPx: 331, maxWidthPx: 96)
    else:
      PlaySprayHazard(kind: pshAnonymousImpact, eventId: uint64(index),
        coversSelf: false, tick: uint32(9100 - index),
        impactPos: p(700 + index, 600 + index),
        incomingDirBrads: index * 8))
  for index in 0 ..< 4:
    result.hazards.blastCues.add(PlayBlastCue(eventId: uint64(index),
      coversSelf: index == 0, pos: p(1000 + index, 500 + index),
      tick: uint32(9200 - index)))
  result.hazards.ownThrow = some(PlayOwnThrow(target: p(1700, 900),
    releaseTick: 9300, blastRadius: 96))

proc assertRowsEquivalent(jsonBytes, binaryBytes: string) =
  let node = parseJson(jsonBytes)
  check binaryBytes.section(BvTracks).get.recordCount == node["tracks"].len
  check binaryBytes.section(BvItems).get.recordCount == node["items"].len
  check binaryBytes.section(BvAggressors).get.recordCount == node["aggressors"].len
  check binaryBytes.section(BvKillFeed).get.recordCount == node["kill_feed"].len
  check binaryBytes.section(BvShouts).get.recordCount == node["shouts"].len
  check binaryBytes.section(BvHazardGrenades).get.recordCount ==
    node["hazards"]["grenades"].len
  check binaryBytes.section(BvHazardBlastCues).get.recordCount ==
    node["hazards"]["blast_cues"].len
  check binaryBytes.section(BvHazardSprays).get.recordCount ==
    node["hazards"]["sprays"].len

proc checkPoint(bytes: string, offset: int, node: JsonNode) =
  check bytes.readI32(offset) == node[0].getInt
  check bytes.readI32(offset + 4) == node[1].getInt

proc checkRect(bytes: string, offset: int, node: JsonNode) =
  ## Contract anchor for the lane-C failure class: rects are `[x, y, w, h]`,
  ## never corner pairs.
  check bytes.readI32(offset) == node[0].getInt
  check bytes.readI32(offset + 4) == node[1].getInt
  check bytes.readI32(offset + 8) == node[2].getInt
  check bytes.readI32(offset + 12) == node[3].getInt

proc teamFromId(id: uint32): string =
  teamText(Team(id))

proc itemFromId(id: uint32): string =
  case PlayItemKind(id)
  of pikGrenade: "grenade"
  of pikMedkit: "medkit"
  of pikShield: "shield"
  of pikSpray: "spray"
  of pikBarrier: "barrier"
  of pikGun: "gun"
  of pikHopper: "hopper"

proc sprayKindFromId(id: uint32): string =
  case PlaySprayHazardKind(id)
  of pshVisibleCone: "visible_cone"
  of pshAnonymousImpact: "anonymous_impact"

proc assertBinaryRowsMatchJson(jsonBytes, binaryBytes: string) =
  let node = parseJson(jsonBytes)
  check binaryBytes.readU32(8) == uint32(node["tick"].getInt)
  check $binaryBytes.readU64(16) == node["epoch"].getStr

  let selfJson = node["self"]
  let self = binaryBytes.section(BvSelf).get
  check binaryBytes.readI32(self.offset + 4) == selfJson["pos"][0].getInt
  check binaryBytes.readI32(self.offset + 8) == selfJson["pos"][1].getInt
  check binaryBytes.readI32(self.offset + 12) == selfJson["hp"].getInt
  check binaryBytes.readU32(self.offset + 24) ==
    uint32(selfJson["aim_brads"].getInt)
  check ((binaryBytes.readU32(self.offset) and SelfAliveFlag) != 0) ==
    selfJson["alive"].getBool

  let worldJson = node["world"]
  let world = binaryBytes.section(BvWorld).get
  check binaryBytes.readU32(world.offset + 4) ==
    uint32(worldJson["alive_teams"].getInt)

  let zoneJson = worldJson["zone"]
  let zone = binaryBytes.section(BvZone).get
  check binaryBytes.readI32(zone.offset + 4) == zoneJson["phase"].getInt
  check binaryBytes.readI32(zone.offset + 8) ==
    zoneJson["ticks_to_shrink"].getInt
  check binaryBytes.readI32(zone.offset + 12) == zoneJson["dps"].getInt
  binaryBytes.checkRect(zone.offset + 16, zoneJson["current"])
  check ((binaryBytes.readU32(zone.offset) and ZoneNextPresentFlag) != 0) ==
    zoneJson.hasKey("next")
  if zoneJson.hasKey("next"):
    binaryBytes.checkRect(zone.offset + 32, zoneJson["next"])

  let tracks = binaryBytes.section(BvTracks).get
  check tracks.recordCount == node["tracks"].len
  for index in 0 ..< node["tracks"].len:
    let row = node["tracks"][index]
    let base = tracks.offset + index * tracks.recordStride
    let flags = binaryBytes.readU32(base)
    check binaryBytes.readU32(base + 4) == uint32(row["seat"].getInt)
    check teamFromId(binaryBytes.readU32(base + 8)) == row["team"].getStr
    binaryBytes.checkPoint(base + 12, row["pos"])
    check binaryBytes.readU32(base + 20) == uint32(row["fresh_tick"].getInt)
    check ((flags and TrackAimPresentFlag) != 0) == row.hasKey("aim_brads")
    if row.hasKey("aim_brads"):
      check binaryBytes.readI32(base + 24) == row["aim_brads"].getInt
    check ((flags and TrackHpPresentFlag) != 0) == row.hasKey("hp")
    if row.hasKey("hp"):
      check binaryBytes.readI32(base + 28) == row["hp"].getInt
    check ((flags and TrackBountyFlag) != 0) ==
      (row.hasKey("bounty") and row["bounty"].getBool)

  let aggressors = binaryBytes.section(BvAggressors).get
  check aggressors.recordCount == node["aggressors"].len
  for index in 0 ..< node["aggressors"].len:
    let row = node["aggressors"][index]
    let base = aggressors.offset + index * aggressors.recordStride
    let flags = binaryBytes.readU32(base)
    check binaryBytes.readU32(base + 4) == uint32(row["tick"].getInt)
    check binaryBytes.readU32(base + 8) == uint32(row["dir_brads"].getInt)
    check ((flags and AggressorSeatPresentFlag) != 0) == row.hasKey("seat")
    if row.hasKey("seat"):
      check binaryBytes.readU32(base + 12) == uint32(row["seat"].getInt)

  let killFeed = binaryBytes.section(BvKillFeed).get
  check killFeed.recordCount == node["kill_feed"].len
  for index in 0 ..< node["kill_feed"].len:
    let row = node["kill_feed"][index]
    let base = killFeed.offset + index * killFeed.recordStride
    check binaryBytes.readU32(base) == uint32(row["tick"].getInt)
    check teamFromId(binaryBytes.readU32(base + 4)) ==
      row["killer_team"].getStr
    check binaryBytes.readU32(base + 8) == uint32(row["victim_seat"].getInt)

  let items = binaryBytes.section(BvItems).get
  check items.recordCount == node["items"].len
  for index in 0 ..< node["items"].len:
    let row = node["items"][index]
    let base = items.offset + index * items.recordStride
    let flags = binaryBytes.readU32(base)
    check itemFromId(binaryBytes.readU32(base + 4)) == row["kind"].getStr
    binaryBytes.checkPoint(base + 8, row["pos"])
    check binaryBytes.readU32(base + 16) == uint32(row["fresh_tick"].getInt)
    check ((flags and ItemPresentFieldFlag) != 0) == row.hasKey("present")
    if row.hasKey("present"):
      check ((flags and ItemPresentValueFlag) != 0) == row["present"].getBool

  let shouts = binaryBytes.section(BvShouts).get
  check shouts.recordCount == node["shouts"].len
  for index in 0 ..< node["shouts"].len:
    let row = node["shouts"][index]
    let base = shouts.offset + index * shouts.recordStride
    check teamFromId(binaryBytes.readU32(base)) == row["team"].getStr
    check char(binaryBytes.readU32(base + 4)) == row["slot_letter"].getStr[0]
    let textOffset = int(binaryBytes.readU32(base + 8))
    let textLen = int(binaryBytes.readU32(base + 12))
    check binaryBytes[textOffset ..< textOffset + textLen] ==
      row["text"].getStr
    binaryBytes.checkPoint(base + 16, row["pos"])
    check binaryBytes.readU32(base + 24) == uint32(row["tick"].getInt)

  let hazards = node["hazards"]
  let grenades = binaryBytes.section(BvHazardGrenades).get
  check grenades.recordCount == hazards["grenades"].len
  for index in 0 ..< hazards["grenades"].len:
    let row = hazards["grenades"][index]
    let base = grenades.offset + index * grenades.recordStride
    binaryBytes.checkPoint(base, row["pos"])
    binaryBytes.checkPoint(base + 8, row["predicted_blast_pos"])
    check binaryBytes.readI32(base + 16) == row["ticks_to_blast"].getInt

  let blastCues = binaryBytes.section(BvHazardBlastCues).get
  check blastCues.recordCount == hazards["blast_cues"].len
  for index in 0 ..< hazards["blast_cues"].len:
    let row = hazards["blast_cues"][index]
    let base = blastCues.offset + index * blastCues.recordStride
    binaryBytes.checkPoint(base, row["pos"])
    check binaryBytes.readU32(base + 8) == uint32(row["tick"].getInt)

  let sprays = binaryBytes.section(BvHazardSprays).get
  check sprays.recordCount == hazards["sprays"].len
  for index in 0 ..< hazards["sprays"].len:
    let row = hazards["sprays"][index]
    let base = sprays.offset + index * sprays.recordStride
    check sprayKindFromId(binaryBytes.readU32(base + 4)) == row["kind"].getStr
    check binaryBytes.readU32(base + 8) == uint32(row["tick"].getInt)
    if row["kind"].getStr == "visible_cone":
      check ((binaryBytes.readU32(base) and SprayCoversSelfFlag) != 0) ==
        row["covers_self"].getBool
      check binaryBytes.readU32(base + 12) ==
        uint32(row["attacker_seat"].getInt)
      binaryBytes.checkPoint(base + 16, row["origin"])
      check binaryBytes.readU32(base + 24) == uint32(row["aim_brads"].getInt)
      check binaryBytes.readI32(base + 28) == row["reach_px"].getInt
      check binaryBytes.readI32(base + 32) == row["max_width_px"].getInt
    else:
      binaryBytes.checkPoint(base + 36, row["impact_pos"])
      check binaryBytes.readU32(base + 44) ==
        uint32(row["incoming_dir_brads"].getInt)

  let ownThrow = binaryBytes.section(BvOwnThrow).get
  let own = hazards["own_throw"]
  binaryBytes.checkPoint(ownThrow.offset, own["target"])
  check binaryBytes.readU32(ownThrow.offset + 8) ==
    uint32(own["release_tick"].getInt)
  check binaryBytes.readI32(ownThrow.offset + 12) ==
    own["blast_radius"].getInt

proc assertBinaryMatchesModel(model: PlayViewModel, bytes: string) =
  assertHeaderAndTable(bytes, model.mode, model.tick, model.epoch)

  let self = bytes.section(BvSelf).get
  var selfFlags = 0'u32
  if model.self.alive: selfFlags = selfFlags or SelfAliveFlag
  if model.self.lives.isSome: selfFlags = selfFlags or SelfLivesPresentFlag
  if model.self.carrying: selfFlags = selfFlags or SelfCarryingFlag
  check bytes.readU32(self.offset) == selfFlags
  check bytes.readI32(self.offset + 4) == model.self.pos.x
  check bytes.readI32(self.offset + 8) == model.self.pos.y
  check bytes.readI32(self.offset + 12) == model.self.hp
  check bytes.readU32(self.offset + 24) == uint32(model.self.aimBrads)
  check bytes.readI32(self.offset + 28) ==
    (if model.self.lives.isSome: model.self.lives.get else: 0)

  let world = bytes.section(BvWorld).get
  check bytes.readU32(world.offset + 4) == uint32(model.aliveTeams)
  check bytes.readU32(world.offset + 8) == uint32(model.objectives.len)
  for index, objective in model.objectives:
    let base = world.offset + 16 + index * 16
    check bytes.readU32(base) ==
      (if objective.pos.isSome: ObjectivePosPresentFlag else: 0'u32)
    check bytes.readU8(base + 4) == ord(objective.team)
    check bytes.readU8(base + 5) == ord(objective.state)
    if objective.pos.isSome:
      check bytes.readI32(base + 8) == objective.pos.get.x
      check bytes.readI32(base + 12) == objective.pos.get.y

  if model.zone.isSome:
    let zone = bytes.section(BvZone).get
    let value = model.zone.get
    var zoneFlags = 0'u32
    if value.next.isSome: zoneFlags = zoneFlags or ZoneNextPresentFlag
    if value.dps != 0: zoneFlags = zoneFlags or ZoneDpsPresentFlag
    check bytes.readU32(zone.offset) == zoneFlags
    check bytes.readI32(zone.offset + 4) == value.phase
    check bytes.readI32(zone.offset + 8) == value.ticksToShrink
    check bytes.readI32(zone.offset + 12) == value.dps
    check bytes.readI32(zone.offset + 16) == value.current.x
    check bytes.readI32(zone.offset + 20) == value.current.y
    check bytes.readI32(zone.offset + 24) == value.current.w
    check bytes.readI32(zone.offset + 28) == value.current.h

  let tracks = bytes.section(BvTracks).get
  check tracks.recordCount == model.tracks.len
  for index, row in model.tracks:
    let base = tracks.offset + index * tracks.recordStride
    var flags = 0'u32
    if row.aimBrads.isSome: flags = flags or TrackAimPresentFlag
    if row.hp.isSome: flags = flags or TrackHpPresentFlag
    if row.bounty: flags = flags or TrackBountyFlag
    check bytes.readU32(base) == flags
    check bytes.readU32(base + 4) == uint32(row.seat)
    check bytes.readU32(base + 8) == uint32(ord(row.team))
    check bytes.readI32(base + 12) == row.pos.x
    check bytes.readI32(base + 16) == row.pos.y
    check bytes.readU32(base + 20) == row.freshTick
    check bytes.readI32(base + 24) ==
      (if row.aimBrads.isSome: row.aimBrads.get else: 0)
    check bytes.readI32(base + 28) ==
      (if row.hp.isSome: row.hp.get else: 0)

  let shouts = bytes.section(BvShouts).get
  check shouts.recordCount == model.shouts.len
  for index, row in model.shouts:
    let base = shouts.offset + index * shouts.recordStride
    check bytes.readU32(base) == uint32(ord(row.team))
    check bytes.readU32(base + 4) == uint32(ord(row.slotLetter[0]))
    let textOffset = int(bytes.readU32(base + 8))
    let textLen = int(bytes.readU32(base + 12))
    check bytes[textOffset ..< textOffset + textLen] == row.text
    check bytes.readI32(base + 16) == row.pos.x
    check bytes.readI32(base + 20) == row.pos.y
    check bytes.readU32(base + 24) == row.tick

  let items = bytes.section(BvItems).get
  check items.recordCount == model.items.len
  for index, row in model.items:
    let base = items.offset + index * items.recordStride
    var flags = 0'u32
    if row.present.isSome:
      flags = flags or ItemPresentFieldFlag
      if row.present.get: flags = flags or ItemPresentValueFlag
    check bytes.readU32(base) == flags
    check bytes.readU32(base + 4) == uint32(ord(row.kind))
    check bytes.readI32(base + 8) == row.pos.x
    check bytes.readI32(base + 12) == row.pos.y
    check bytes.readU32(base + 16) == row.freshTick

  let aggressors = bytes.section(BvAggressors).get
  check aggressors.recordCount == model.aggressors.len
  for index, row in model.aggressors:
    let base = aggressors.offset + index * aggressors.recordStride
    check bytes.readU32(base) ==
      (if row.seat.isSome: AggressorSeatPresentFlag else: 0'u32)
    check bytes.readU32(base + 4) == row.tick
    check bytes.readU32(base + 8) == uint32(row.dirBrads)
    check bytes.readU32(base + 12) ==
      (if row.seat.isSome: uint32(row.seat.get) else: 0'u32)

  let killFeed = bytes.section(BvKillFeed).get
  check killFeed.recordCount == model.killFeed.len
  for index, row in model.killFeed:
    let base = killFeed.offset + index * killFeed.recordStride
    check bytes.readU32(base) == row.tick
    check bytes.readU32(base + 4) == uint32(ord(row.killerTeam))
    check bytes.readU32(base + 8) == uint32(row.victimSeat)

  let grenades = bytes.section(BvHazardGrenades).get
  check grenades.recordCount == model.hazards.grenades.len
  for index, row in model.hazards.grenades:
    let base = grenades.offset + index * grenades.recordStride
    check bytes.readI32(base) == row.pos.x
    check bytes.readI32(base + 4) == row.pos.y
    check bytes.readI32(base + 8) == row.predictedBlastPos.x
    check bytes.readI32(base + 12) == row.predictedBlastPos.y
    check bytes.readI32(base + 16) == row.ticksToBlast

  let blastCues = bytes.section(BvHazardBlastCues).get
  check blastCues.recordCount == model.hazards.blastCues.len
  for index, row in model.hazards.blastCues:
    let base = blastCues.offset + index * blastCues.recordStride
    check bytes.readI32(base) == row.pos.x
    check bytes.readI32(base + 4) == row.pos.y
    check bytes.readU32(base + 8) == row.tick

  let sprays = bytes.section(BvHazardSprays).get
  check sprays.recordCount == model.hazards.sprays.len
  for index, row in model.hazards.sprays:
    let base = sprays.offset + index * sprays.recordStride
    check bytes.readU32(base) ==
      (if row.kind == pshVisibleCone and row.coversSelf:
        SprayCoversSelfFlag else: 0'u32)
    check bytes.readU32(base + 4) == uint32(ord(row.kind))
    check bytes.readU32(base + 8) == row.tick
    case row.kind
    of pshVisibleCone:
      check bytes.readU32(base + 12) == uint32(row.attackerSeat)
      check bytes.readI32(base + 16) == row.origin.x
      check bytes.readI32(base + 20) == row.origin.y
      check bytes.readU32(base + 24) == uint32(row.aimBrads)
      check bytes.readI32(base + 28) == row.reachPx
      check bytes.readI32(base + 32) == row.maxWidthPx
    of pshAnonymousImpact:
      check bytes.readI32(base + 36) == row.impactPos.x
      check bytes.readI32(base + 40) == row.impactPos.y
      check bytes.readU32(base + 44) == uint32(row.incomingDirBrads)

  let ownThrow = bytes.section(BvOwnThrow).get
  check model.hazards.ownThrow.isSome
  let own = model.hazards.ownThrow.get
  check bytes.readI32(ownThrow.offset) == own.target.x
  check bytes.readI32(ownThrow.offset + 4) == own.target.y
  check bytes.readU32(ownThrow.offset + 8) == own.releaseTick
  check bytes.readI32(ownThrow.offset + 12) == own.blastRadius

  let intent = bytes.section(BvStandingIntent).get
  check model.intent.isSome
  let standing = model.intent.get
  var intentFlags = 0'u32
  if standing.point.isSome: intentFlags = intentFlags or IntentPointPresentFlag
  if standing.movingGoal: intentFlags = intentFlags or IntentMovingGoalFlag
  if standing.idleAimCenterBrads.isSome:
    intentFlags = intentFlags or IntentIdleAimPresentFlag
  if standing.clampToEndzone: intentFlags = intentFlags or IntentClampToEndzoneFlag
  if standing.suppressFireFreeze:
    intentFlags = intentFlags or IntentSuppressFireFreezeFlag
  if standing.combat.holdFire: intentFlags = intentFlags or IntentHoldFireFlag
  check bytes.readU32(intent.offset) == intentFlags
  check bytes.readU32(intent.offset + 4) == uint32(ord(standing.kind))
  check bytes.readU32(intent.offset + 8) == uint32(ord(standing.profile))
  let point = standing.point.get
  check bytes.readI32(intent.offset + 24) == point.x
  check bytes.readI32(intent.offset + 28) == point.y
  check bytes.readI32(intent.offset + 32) == standing.idleAimCenterBrads.get
  check bytes.readU32(intent.offset + 36) != 0'u32
  check bytes.readU32(intent.offset + 40) != 0'u32
  check bytes.readU32(intent.offset + 48) == 3'u32
  check bytes.readU32(intent.offset + 52) == 1'u32
  check bytes.readU32(intent.offset + 56) == 2'u32
  check bytes.readU32(intent.offset + 132) == uint32(standing.reason.len)

suite "shell binary play view":
  test "thin and real-max frames match byte fixtures":
    # Thin fixture arithmetic, derived from the amended spec:
    # header 32 + 3 table entries * 12 = first payload offset 68.
    # self offset 68, stride 32; world offset 100, stride 272;
    # zone offset 372, stride 48; frame_bytes = 372 + 48 = 420.
    let thin = buildBinaryPlayView(selectPlayView(baseSource(), MaxViewFrameBytes))
    let realMax = buildBinaryPlayView(selectPlayView(maxSource(), MaxViewFrameBytes))
    check thin.hex == fixtureHex("tests/fixtures/shell/binary-view/thin.hex")
    # Real-max fixture arithmetic: header 32 + 13 table entries * 12 = first
    # payload offset 188. Offsets are then the cumulative record areas:
    # 188, 220, 492, 540, 1564, 1884, 2268, 3036, 4156, 4316, 4364,
    # 4748, 4764. The last record is standing_intent, 1 * 200 bytes, so
    # frame_bytes = 4764 + 200 = 4964.
    check realMax.hex == fixtureHex(
      "tests/fixtures/shell/binary-view/real-max.hex")

  test "header section table alignment and cap":
    let model = selectPlayView(maxSource(), MaxViewFrameBytes)
    let bytes = buildBinaryPlayView(model)
    assertHeaderAndTable(bytes, gmBr, model.tick, model.epoch)
    check bytes.len <= MaxBinaryViewFrameBytes
    check bytes.len == 4964
    check MaxBinaryViewFrameBytes - bytes.len == 3228
    for expected in [BvSelf, BvWorld, BvZone, BvTracks, BvAggressors,
                     BvKillFeed, BvItems, BvShouts, BvHazardGrenades,
                     BvHazardBlastCues, BvHazardSprays, BvOwnThrow,
                     BvStandingIntent]:
      check bytes.section(expected).isSome

  test "binary rows are equivalent to JSON-selected rows":
    let source = maxSource()
    let model = selectPlayView(source, MaxViewFrameBytes)
    let jsonBytes = buildPlayView(source)
    let binaryBytes = buildBinaryPlayView(model)
    assertRowsEquivalent(jsonBytes, binaryBytes)
    assertBinaryRowsMatchJson(jsonBytes, binaryBytes)

  test "presence bits distinguish absent from legitimate zero":
    var source = baseSource()
    source.self.lives = some(0)
    source.tracks = @[
      PlayTrack(seat: 0, team: Red, pos: p(0, 0), aimBrads: some(0),
        hp: some(0), freshTick: 0),
      PlayTrack(seat: 1, team: Blue, pos: p(0, 0), freshTick: 0)]
    source.items = @[
      PlayItem(eventId: 1, kind: pikGrenade, pos: p(0, 0),
        present: some(false), freshTick: 0),
      PlayItem(eventId: 2, kind: pikMedkit, pos: p(0, 0), freshTick: 0)]
    source.aggressors = @[
      PlayAggressor(eventId: 1, tick: 0, dirBrads: 0, seat: some(0)),
      PlayAggressor(eventId: 2, tick: 0, dirBrads: 0)]
    source.intent = some(Intent(kind: ikNavigateTo, point: some(MapPoint(x: 0, y: 0)),
      arriveRadius: 0.0, idleAimCenterBrads: some(0)))
    let bytes = buildBinaryPlayView(selectPlayView(source, MaxViewFrameBytes))

    let self = bytes.section(BvSelf).get
    check (bytes.readU32(self.offset) and SelfLivesPresentFlag) != 0
    check bytes.readI32(self.offset + 28) == 0

    let tracks = bytes.section(BvTracks).get
    check (bytes.readU32(tracks.offset) and
      (TrackAimPresentFlag or TrackHpPresentFlag)) ==
        (TrackAimPresentFlag or TrackHpPresentFlag)
    check bytes.readI32(tracks.offset + 24) == 0
    check bytes.readI32(tracks.offset + 28) == 0
    check (bytes.readU32(tracks.offset + tracks.recordStride) and
      (TrackAimPresentFlag or TrackHpPresentFlag)) == 0'u32

    let items = bytes.section(BvItems).get
    check (bytes.readU32(items.offset) and ItemPresentFieldFlag) != 0
    check (bytes.readU32(items.offset) and ItemPresentValueFlag) == 0
    check (bytes.readU32(items.offset + items.recordStride) and
      ItemPresentFieldFlag) == 0

    let aggressors = bytes.section(BvAggressors).get
    check (bytes.readU32(aggressors.offset) and AggressorSeatPresentFlag) != 0
    check bytes.readU32(aggressors.offset + 12) == 0'u32
    check (bytes.readU32(aggressors.offset + aggressors.recordStride) and
      AggressorSeatPresentFlag) == 0

    let intent = bytes.section(BvStandingIntent).get
    check (bytes.readU32(intent.offset) and
      (IntentPointPresentFlag or IntentIdleAimPresentFlag)) ==
        (IntentPointPresentFlag or IntentIdleAimPresentFlag)
    check bytes.readI32(intent.offset + 24) == 0
    check bytes.readI32(intent.offset + 28) == 0
    check bytes.readI32(intent.offset + 32) == 0

  test "deterministic bytes across repeats":
    let model = selectPlayView(maxSource(), MaxViewFrameBytes)
    check buildBinaryPlayView(model) == buildBinaryPlayView(model)

  test "PERCEPTION (glory-2 §17): track hasGun/hasHopper ride the SAME reserved flags word":
    # ABI-additive proof: the two new bits sit inside the existing 4-byte
    # flags field every track row already carried (the record stride below
    # is unchanged), so an old-compiled policy that only ever tests the
    # four original bits (aim/hp/bounty/downed) keeps decoding correctly —
    # it simply never asks about the two it doesn't know.
    var source = baseSource()
    source.tracks = @[
      PlayTrack(seat: 2, team: Blue, pos: p(0, 0), freshTick: 0,
        hasGun: true, hasHopper: true),
      PlayTrack(seat: 3, team: Red, pos: p(0, 0), freshTick: 0)]
    let bytes = buildBinaryPlayView(selectPlayView(source, MaxViewFrameBytes))
    let tracks = bytes.section(BvTracks).get
    check tracks.recordStride == 32                    # stride unchanged
    let armedFlags = bytes.readU32(tracks.offset)
    check (armedFlags and TrackHasGunFlag) != 0
    check (armedFlags and TrackHasHopperFlag) != 0
    # An old reader's own four bits are untouched by the two new ones.
    check (armedFlags and (TrackAimPresentFlag or TrackHpPresentFlag or
      TrackBountyFlag or TrackDownedFlag)) == 0'u32
    # Pre-existing fields sit at their SAME offsets, unmoved by the new bits.
    check bytes.readU32(tracks.offset + 4) == 2'u32
    let darkFlags = bytes.readU32(tracks.offset + tracks.recordStride)
    check (darkFlags and (TrackHasGunFlag or TrackHasHopperFlag)) == 0'u32

  test "PERCEPTION (glory-2 §17): gun/hopper item kind ids are additive (5, 6)":
    var source = baseSource()
    source.items = @[
      # Distinct freshTicks (sortedItems' primary sort key, descending) pin
      # the row order explicitly -- the tiebreaker beneath it (kind ordinal
      # ascending) would otherwise put barrier(4) first, unrelated to what
      # this test is proving.
      PlayItem(eventId: 1, kind: pikGun, pos: p(0, 0), freshTick: 3),
      PlayItem(eventId: 2, kind: pikHopper, pos: p(0, 0), freshTick: 2),
      PlayItem(eventId: 3, kind: pikBarrier, pos: p(0, 0), freshTick: 1)]
    let bytes = buildBinaryPlayView(selectPlayView(source, MaxViewFrameBytes))
    let items = bytes.section(BvItems).get
    check bytes.readU32(items.offset + 4) == 5'u32
    check bytes.readU32(items.offset + items.recordStride + 4) == 6'u32
    check bytes.readU32(items.offset + items.recordStride * 2 + 4) == 4'u32 # barrier unmoved

suite "shell binary play context":
  test "context header sections and fields":
    let context = PlayContextSource(mode: gmBr, mapName: "gen:14005",
      mapWidth: 3200, mapHeight: 1800,
      roster: @[
        PlayContextRosterRow(seat: 0, team: Red, control: pccInput),
        PlayContextRosterRow(seat: 1, team: Red, control: pccPlay)],
      selfSeat: 1, selfTeam: Red, duoPartner: some(0),
      gunRange: 331, viewInterval: 6)
    let bytes = buildBinaryPlayContext(context)
    # Context fixture arithmetic, derived from the amended spec:
    # header 32 + 3 table entries * 12 = first payload offset 68.
    # roster offset 68, count 2, stride 12 => self offset 92.
    # self offset 92, count 1, stride 16 => mode/map offset 108.
    # mode/map fixed record 24 bytes + 9-byte map name + 3-byte padding
    # gives frame_bytes = 108 + 24 + 9 + 3 = 144.
    check bytes.hex == fixtureHex("tests/fixtures/shell/binary-view/context.hex")
    assertHeaderAndTable(bytes, gmBr, 0'u32, 0'u64)
    check bytes.len <= MaxBinaryContextBytes
    let roster = bytes.section(BvContextRoster).get
    check roster.recordCount == 2
    check roster.recordStride == int(ContextRosterRecordStride)
    check bytes.readU32(roster.offset) == 0'u32
    check bytes.readU32(roster.offset + 8) == 0'u32
    check bytes.readU32(roster.offset + roster.recordStride) == 1'u32
    check bytes.readU32(roster.offset + roster.recordStride + 8) == 1'u32
    let self = bytes.section(BvContextSelf).get
    check (bytes.readU32(self.offset) and ContextDuoPresentFlag) != 0
    check bytes.readU32(self.offset + 4) == 1'u32
    check bytes.readU32(self.offset + 12) == 0'u32
    let modeMap = bytes.section(BvContextModeMap).get
    check bytes.readI32(modeMap.offset) == 3200
    check bytes.readI32(modeMap.offset + 4) == 1800
    check bytes.readI32(modeMap.offset + 8) == 331
    check bytes.readI32(modeMap.offset + 12) == 6
    let nameOffset = int(bytes.readU32(modeMap.offset + 16))
    let nameLen = int(bytes.readU32(modeMap.offset + 20))
    check bytes[nameOffset ..< nameOffset + nameLen] == "gen:14005"
