## PERCEPTION (glory-2 §17), parts 2/3 of the frame-loadout-flags increment.
##
## Part 2 — SDK item perception: sikGun/pikGun/bikGun (+ hopper twins),
## mirrored onto the existing five kinds exactly (ids/ordinals APPENDED,
## never inserted). Ground-item visibility is gated like every other item
## family: weaponSpawns/hopperSpawns are themselves empty whenever
## lootStart is dark (resetLootCrates's own contract), so a dark game
## sights nothing here, with no separate gate of its own.
##
## Part 3 — own-duo held-state: a play can see its PARTNER's
## hasGun/hasHopper (required for an intelligent HANDOFF call: perceive
## the crate AND the partner's gap), gated by the SAME `frameLoadoutFlags`
## flag as part 1. Enemy held-state is deliberately out of scope — an
## ordinary fogged track never carries it, by construction (the
## enemy-track path never even reads the field).

import
  std/[json, options, os, unittest],
  ../src/ctf/sim_types,
  ../src/shell/[body, body_map, view]

include ../src/ctf/server

proc p(x, y: int): PlayPoint = (x, y)

suite "PERCEPTION (glory-2 §17) part 2/3 -- ground gun/hopper crate visibility":
  test "gun and hopper crates are sighted like every other item family":
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    let viewer = sim.players[viewerIndex]
    sim.grenadeSpawns.setLen(0)
    sim.medKitSpawns.setLen(0)
    sim.shieldSpawns.setLen(0)
    sim.sprayPaintSpawns.setLen(0)
    sim.barrierSpawns.setLen(0)
    sim.weaponSpawns = @[PickupSpawn(x: viewer.x, y: viewer.y, present: true)]
    sim.hopperSpawns = @[PickupSpawn(x: viewer.x + 1, y: viewer.y,
      present: false, respawnAt: 999)]

    let inputs = sim.firstLightBodyInputs(viewerIndex)
    check inputs.sightedItems.len == 2
    var kinds: seq[BodyItemKind]
    for sighting in inputs.sightedItems:
      kinds.add sighting.kind
      check sighting.tick == uint32(sim.tickCount + 1)
    check bikGun in kinds
    check bikHopper in kinds
    for sighting in inputs.sightedItems:
      if sighting.kind == bikHopper:
        check not sighting.present    # a taken crate is still a sighting
        check sighting.pos == (viewer.x + 1, viewer.y)
      else:
        check sighting.present

  test "a dark game (no lootStart) sights neither -- the spawn families are empty":
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    check sim.weaponSpawns.len == 0
    check sim.hopperSpawns.len == 0
    let inputs = sim.firstLightBodyInputs(viewerIndex)
    for sighting in inputs.sightedItems:
      check sighting.kind notin [bikGun, bikHopper]

suite "PERCEPTION (glory-2 §17) part 3/3 -- own-duo held-state, gated":
  test "the partner grant carries hasGun/hasHopper only when frameLoadoutFlags is armed":
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    let partnerIndex = sim.addPlayer("red1")
    sim.players[viewerIndex].team = Red
    sim.players[partnerIndex].team = Red
    sim.players[partnerIndex].hasGun = true
    sim.players[partnerIndex].hasHopper = true

    let dark = sim.firstLightPartner(viewerIndex)
    check dark.isSome
    check not dark.get.hasGun
    check not dark.get.hasHopper

    sim.config.frameLoadoutFlags = true
    let armed = sim.firstLightPartner(viewerIndex)
    check armed.isSome
    check armed.get.hasGun
    check armed.get.hasHopper

  test "an enemy is never granted partner-style held-state":
    var config = defaultGameConfig()
    config.frameLoadoutFlags = true
    var sim = initSimServer(config)
    let viewerIndex = sim.addPlayer("red0")
    let enemyIndex = sim.addPlayer("blue0")
    sim.players[viewerIndex].team = Red
    sim.players[enemyIndex].team = Blue
    sim.players[enemyIndex].hasGun = true
    sim.players[enemyIndex].hasHopper = true
    # duoPartnerIndex only ever considers a SAME-team seat; a cross-team
    # pair has no path into firstLightPartner at all.
    check sim.firstLightPartner(viewerIndex).isNone

proc openBodyMap(): BodyMap =
  const Width = 128
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(16, 16), (Width - 17, 16)])

suite "PERCEPTION (glory-2 §17) part 3/3 -- the partner row on the play's own view":
  test "the duo-partner PlayTrack carries hasGun/hasHopper; an ordinary enemy track never does":
    let seatBody = activateSeatBody(openBodyMap(), 0, 331)
    seatBody.updateBelief(BodyTickInputs(
      self: BodySelfState(pos: (16, 16), hp: 5, hpFrac: 1.0, aimBrads: 0,
        alive: true),
      visibleTracks: @[BodyTrackUpdate(seat: 5, pos: (80, 40), team: Blue,
        aimBrads: some(0), hpKnown: some(3), tick: 9'u32)],
      partner: some(PartnerSample(seat: 1, team: Red, pos: (70, 30),
        aimBrads: 12, alive: true, hasGun: true, hasHopper: true))), 9'u32)

    let source = playViewSourceFromBody(seatBody, 9'u32, gmBr, 2,
      includeStandingIntent = false)
    var sawEnemy, sawPartner = false
    for t in source.tracks:
      if t.seat == 5:
        sawEnemy = true
        check not t.hasGun
        check not t.hasHopper
      if t.seat == 1:
        sawPartner = true
        check t.hasGun
        check t.hasHopper
    check sawEnemy
    check sawPartner

    # And on the wire (canonical JSON): the partner row carries has_gun/
    # has_hopper, omit-when-false everywhere else -- never a third
    # "armed" field, per the increment's own contract.
    let node = parseJson(buildPlayView(source))
    var sawPartnerJson, sawEnemyJson = false
    for t in node["tracks"]:
      if t["seat"].getInt == 1:
        sawPartnerJson = true
        check t["has_gun"].getBool == true
        check t["has_hopper"].getBool == true
        check not t.hasKey("armed")
      if t["seat"].getInt == 5:
        sawEnemyJson = true
        check not t.hasKey("has_gun")
        check not t.hasKey("has_hopper")
    check sawPartnerJson
    check sawEnemyJson

  test "hasGun/hasHopper are omitted from the wire when false":
    var source = PlayViewSource(
      tick: 1'u32, mode: gmBr, epoch: 1'u64,
      self: PlaySelf(pos: p(0, 0), hp: 1, hpFrac: 1.0, aimBrads: 0,
        alive: true),
      aliveTeams: 2)
    source.tracks = @[PlayTrack(seat: 1, team: Red, pos: p(0, 0),
      freshTick: 0)]
    let node = parseJson(buildPlayView(source))
    check not node["tracks"][0].hasKey("has_gun")
    check not node["tracks"][0].hasKey("has_hopper")

suite "PERCEPTION (glory-2 §17) schema: gun/hopper item kind + has_gun/has_hopper tracks":
  test "play_view.schema.json documents the additive item kinds and track fields":
    let schema = parseJson(readFile(
      "src" / "shell" / "schemas" / "play_view.schema.json"))
    var kinds: seq[string]
    for k in schema["properties"]["items"]["items"]["properties"]["kind"]["enum"]:
      kinds.add k.getStr
    check "gun" in kinds
    check "hopper" in kinds
    check "grenade" in kinds       # the mirrored, pre-existing kinds stay
    let trackProps = schema["properties"]["tracks"]["items"]["properties"]
    check trackProps.hasKey("has_gun")
    check trackProps.hasKey("has_hopper")
