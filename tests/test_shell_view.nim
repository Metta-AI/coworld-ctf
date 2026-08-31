## Production play_view/play_context producer tests.
##
## Selection assertions target the typed model. Encoding assertions target
## canonical JSON bytes. This keeps the future binary play-view encoder from
## inheriting JSON-specific row selection behavior.

import std/[algorithm, json, options, sequtils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[body, body_map, canonical, canonical_fast, types, view]

proc p(x, y: int): PlayPoint = (x, y)

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

proc smallBodyMap(): BodyMap =
  const
    Width = 128
    Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(16, 16), (Width - 17, 16)])

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

proc encodedRow[T](row: T): string =
  var w = initCanonicalWriter()
  w.writeJson(row)
  w.take()

proc checkIncreasingStrings(node: JsonNode) =
  var previous = ""
  for child in node:
    let value = child.getStr()
    check value > previous
    previous = value

proc assertViewConformant(bytes: string): JsonNode =
  validateCanonical("" & bytes)
  result = parseJson(bytes)
  check canonicalJson(result) == bytes
  if result.hasKey("intent"):
    let intent = result["intent"]
    if intent.hasKey("micro"):
      checkIncreasingStrings(intent["micro"])
    if intent.hasKey("combat"):
      let combat = intent["combat"]
      for setName in ["no_shoot", "protect"]:
        if combat.hasKey(setName):
          for field in ["seats", "teams"]:
            if combat[setName].hasKey(field):
              checkIncreasingStrings(combat[setName][field])

proc seatOrder(rows: openArray[PlayTrack]): seq[int] =
  for row in rows:
    result.add(row.seat)

suite "shell play view producer":
  test "row cost model equals canonical row encoders for every row kind":
    let source = richSource()
    for row in source.tracks:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.items:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.aggressors:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.killFeed:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.shouts:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.hazards.grenades:
      check row.jsonEncodedSize == row.encodedRow.len
    for row in source.hazards.blastCues:
      check row.jsonEncodedSize == row.encodedRow.len
    check source.hazards.ownThrow.get.jsonEncodedSize ==
      source.hazards.ownThrow.get.encodedRow.len
    for row in source.hazards.sprays:
      check row.jsonEncodedSize == row.encodedRow.len

  test "incremental model size equals real encoded length":
    let source = richSource()
    for cap in [selectPlayView(baseSource(), 100_000).jsonEncodedSize,
                512, 1024, MaxViewFrameBytes, 100_000]:
      var capSource = source
      if cap < MaxViewFrameBytes:
        capSource.intent = none(Intent)
      let selected = selectPlayViewWithSize(capSource, cap)
      check selected.encodedSize == selected.model.jsonEncodedSize
      check selected.encodedSize <= cap

  test "selection model is deterministic and applies per-list priority goldens":
    let model = selectPlayView(richSource(), 100_000)
    check model.tracks.seatOrder == @[2, 7, 5]
    check model.items.mapIt(it.eventId) == @[20'u64, 10'u64, 30'u64]
    check model.aggressors.mapIt(it.eventId) == @[4'u64, 5'u64]
    check model.killFeed.mapIt(it.eventId) == @[8'u64, 9'u64]
    check model.shouts.mapIt(it.eventId) == @[1'u64, 2'u64, 3'u64]
    check model.hazards.grenades.mapIt(it.eventId) == @[2'u64, 1'u64, 3'u64]
    check model.hazards.blastCues.mapIt(it.eventId) == @[1'u64, 2'u64]
    check model.hazards.sprays.mapIt(it.eventId) == @[12'u64, 11'u64, 10'u64]

  test "byte cap trims the typed model before encoding":
    var source = baseSource()
    source.tracks = richSource().tracks
    var twoTracks = selectPlayView(source, 100_000)
    twoTracks.tracks.setLen(2)
    let cap = twoTracks.jsonEncodedSize
    let selected = selectPlayView(source, cap)
    let bytes = newPlayViewProducer().buildPlayView(source, cap)
    check selected.tracks.seatOrder == @[2, 7]
    check bytes.len <= cap
    check assertViewConformant(bytes)["tracks"].len == 2

  test "byte cap truncation is a priority prefix, not best-fit packing":
    var source = baseSource()
    let largeFirst = PlayTrack(seat: 0, team: Blue, pos: p(101, 100),
      aimBrads: some(32), hp: some(10), freshTick: 1400, bounty: true)
    let smallSecond = PlayTrack(seat: 1, team: Blue, pos: p(300, 100),
      freshTick: 1400)
    source.tracks = @[largeFirst, smallSecond]
    var lowerPriorityOnly = selectPlayView(baseSource(), 100_000)
    lowerPriorityOnly.tracks = @[smallSecond]
    let cap = lowerPriorityOnly.jsonEncodedSize
    let selected = selectPlayView(source, cap)
    check selected.tracks.len == 0

  test "tiny legal cap keeps only the required skeleton":
    let base = selectPlayView(baseSource(), 100_000)
    let cap = base.jsonEncodedSize
    var source = richSource()
    source.intent = none(Intent)
    let selected = selectPlayView(source, cap)
    let node = assertViewConformant(newPlayViewProducer().buildPlayView(source, cap))
    check selected.tracks.len == 0
    check selected.hazards.grenades.len == 0
    check not node.hasKey("tracks")
    check not node.hasKey("hazards")

  test "every produced frame is canonical and under each requested cap":
    var source = richSource()
    source.intent = none(Intent)
    for cap in [selectPlayView(baseSource(), 100_000).jsonEncodedSize,
                512, 1024, MaxViewFrameBytes]:
      let bytes = newPlayViewProducer().buildPlayView(source, cap)
      check bytes.len <= cap
      discard assertViewConformant(bytes)
    let withIntent = buildPlayView(richSource(), MaxViewFrameBytes)
    check withIntent.len <= MaxViewFrameBytes
    discard assertViewConformant(withIntent)

  test "standing intent sets are normalized and duplicate prefer is rejected":
    let node = assertViewConformant(buildPlayView(richSource(), MaxViewFrameBytes))
    let combat = node["intent"]["combat"]
    check combat["no_shoot"]["seats"] == %*["seat:10", "seat:12", "seat:4"]
    check combat["no_shoot"]["teams"] == %*["blue", "red"]
    check node["intent"]["micro"] == %*["formation_bias", "peek_duck"]
    check combat["prefer"] == %*["bounty", "weakened"]

    var bad = richSource()
    bad.intent.get.combat.prefer = @[ptBounty, ptBounty]
    expect ValueError:
      discard buildPlayView(bad)

  test "omit-when rules are honored and present forms encode":
    var source = baseSource()
    source.zone.get.next = none(PlayRect)
    source.zone.get.dps = 0
    source.tracks = @[PlayTrack(seat: 3, team: Yellow, pos: p(120, 120),
      freshTick: 1400)]
    source.aggressors = @[PlayAggressor(eventId: 1, tick: 1410, dirBrads: 9)]
    let omitted = assertViewConformant(buildPlayView(source))
    check not omitted.hasKey("intent")
    check not omitted["self"].hasKey("carrying")
    check not omitted["self"].hasKey("lives")
    check not omitted["tracks"][0].hasKey("aim_brads")
    check not omitted["tracks"][0].hasKey("hp")
    check not omitted["tracks"][0].hasKey("bounty")
    check not omitted["aggressors"][0].hasKey("seat")
    check not omitted["world"]["zone"].hasKey("next")
    check not omitted["world"]["zone"].hasKey("dps")

    source.mode = gmCtf
    source.zone = none(PlayZone)
    source.self.lives = some(2)
    source.self.carrying = true
    source.tracks[0].aimBrads = some(42)
    source.tracks[0].hp = some(6)
    source.tracks[0].bounty = true
    source.aggressors[0].seat = some(8)
    source.objectives = @[PlayObjective(team: Blue, state: osTaken,
      pos: some(p(500, 200)))]
    let present = assertViewConformant(buildPlayView(source))
    check present["self"]["carrying"].getBool()
    check present["self"]["lives"].getInt() == 2
    check present["tracks"][0]["aim_brads"].getInt() == 42
    check present["tracks"][0]["hp"].getInt() == 6
    check present["tracks"][0]["bounty"].getBool()
    check present["aggressors"][0]["seat"].getInt() == 8
    check present["world"]["objectives"][0]["state"].getStr() == "taken"

  test "spray hazard variant emits only the selected arm's fields":
    let node = assertViewConformant(buildPlayView(richSource()))
    let anonymous = node["hazards"]["sprays"][0]
    let visible = node["hazards"]["sprays"][1]
    check anonymous["kind"].getStr() == "anonymous_impact"
    check anonymous.hasKey("impact_pos")
    check anonymous.hasKey("incoming_dir_brads")
    check not anonymous.hasKey("attacker_seat")
    check not anonymous.hasKey("origin")
    check visible["kind"].getStr() == "visible_cone"
    check visible.hasKey("attacker_seat")
    check visible.hasKey("origin")
    check not visible.hasKey("impact_pos")
    check not visible.hasKey("incoming_dir_brads")

  test "writer bytes equal canonicalJson of the equivalent tree":
    var source = baseSource()
    source.epoch = high(uint64)
    source.zone = none(PlayZone)
    let bytes = buildPlayView(source)
    let expected = %*{
      "epoch": $high(uint64),
      "schema": "play_view",
      "self": {"aim_brads": 64, "alive": true, "hp": 7,
        "hp_frac": 0.7, "pos": [100, 100]},
      "tick": 1441,
      "v": 1,
      "world": {"alive_teams": 5}
    }
    check bytes == canonicalJson(expected)
    discard assertViewConformant(bytes)

  test "same belief emits identical bytes across source row permutations":
    var a = richSource()
    var b = richSource()
    b.tracks.reverse()
    b.items.reverse()
    b.aggressors.reverse()
    b.killFeed.reverse()
    b.shouts.reverse()
    b.hazards.grenades.reverse()
    b.hazards.blastCues.reverse()
    b.hazards.sprays.reverse()
    check buildPlayView(a, 2048) == buildPlayView(b, 2048)

  test "warmed 32-seat pass is stable with one producer instance":
    let source = richSource()
    let producer = newPlayViewProducer()
    var first: seq[string]
    var second: seq[string]
    for seat in 0 ..< 32:
      var row = source
      row.self.pos = p(100 + seat, 100)
      first.add(producer.buildPlayView(row, MaxViewFrameBytes))
    for seat in 0 ..< 32:
      var row = source
      row.self.pos = p(100 + seat, 100)
      second.add(producer.buildPlayView(row, MaxViewFrameBytes))
    check first == second
    for bytes in second:
      discard assertViewConformant(bytes)

  test "SeatBody adapter carries self hp, standing intent, epoch, and tracks":
    let map = smallBodyMap()
    let body = activateSeatBody(map, 0, 331)
    body.updateBelief(BodyTickInputs(
      self: BodySelfState(pos: p(16, 16), hp: 5, hpFrac: 0.5,
        aimBrads: 32, alive: true),
      visibleTracks: @[BodyTrackUpdate(seat: 1, pos: p(64, 16),
        team: Blue, aimBrads: 96, hpKnown: some(4), tick: 7'u32)]), 7'u32)
    setStandingIntent(body, Intent(kind: ikHold, arriveRadius: 0.0,
      reason: "hold"), none(ValidatedGoal), 42'u64)
    let source = playViewSourceFromBody(body, 7'u32, gmBr, 2,
      includeStandingIntent = true)
    let node = assertViewConformant(buildPlayView(source))
    check node["epoch"].getStr() == "42"
    check node["self"]["hp"].getInt() == 5
    check node["intent"]["kind"].getStr() == "hold"
    check node["tracks"][0]["seat"].getInt() == 1
    check node["tracks"][0]["hp"].getInt() == 4

suite "shell play context producer":
  test "context emits canonical bytes and omits input controls":
    let context = PlayContextSource(mode: gmBr, mapName: "gen:14005",
      mapWidth: 3200, mapHeight: 1800,
      roster: @[
        PlayContextRosterRow(seat: 0, team: Red, control: pccInput),
        PlayContextRosterRow(seat: 1, team: Red, control: pccPlay)],
      selfSeat: 1, selfTeam: Red, duoPartner: some(0),
      gunRange: 331, viewInterval: 6)
    let bytes = newPlayContextProducer().buildPlayContext(context)
    validateCanonical("" & bytes)
    check canonicalJson(parseJson(bytes)) == bytes
    let node = parseJson(bytes)
    check node["schema"].getStr() == "play_context"
    check not node["roster"][0].hasKey("control")
    check node["roster"][1]["control"].getStr() == "play"
    check node["self"]["duo_partner"].getInt() == 0

  test "context enforces br duo presence and byte cap":
    let context = PlayContextSource(mode: gmCtf, mapName: "arena",
      mapWidth: 1235, mapHeight: 659,
      roster: @[
        PlayContextRosterRow(seat: 0, team: Red, control: pccPlay),
        PlayContextRosterRow(seat: 1, team: Blue, control: pccInput)],
      selfSeat: 0, selfTeam: Red, duoPartner: none(int),
      gunRange: 331, viewInterval: 6)
    check buildPlayContext(context).len <= MaxContextBytes

    var bad = context
    bad.duoPartner = some(1)
    expect ValueError:
      discard buildPlayContext(bad)
    expect ValueError:
      discard buildPlayContext(context, 8)
