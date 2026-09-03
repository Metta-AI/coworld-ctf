## The per-seat cosmetic-effects channel (GameConfig.allowCosmeticFx):
## buildCosmeticFxPacket's JSON, asserted against the source contract in
## server.nim -- not this file's own prose. `include`d rather than imported,
## same as test_shot_feedback_wire.nim, since buildCosmeticFxPacket is a
## private (non-exported) proc.
##
## This channel exists to give a human takeover socket the two spectator-only
## effects global.nim's addShotTracers/addPaintStains draw for the broadcast
## board (paint tracers, permanent ground stains), fog-clipped to that seat,
## WITHOUT changing what any policy or mux socket receives. That "byte-
## identical policy stream, gate on or off" claim is the whole point of
## building this as a separate TextMessage rather than folding it into
## global.nim's buildSpriteProtocolPlayerUpdates -- so the suite at the
## bottom demonstrates it directly (calls the real policy-facing builder with
## live shots/stains present and diffs bytes), rather than asserting it from
## reading the call sites.

import std/[unittest, json]

include ../src/ctf/server

proc duoFxSim(allowCosmeticFx: bool): SimServer =
  ## Swap#13 S1/S5: a started, brMode duo game — 4 players, 2 teams of 2
  ## (Red: 0,1; Blue: 2,3) — so partnerIndex/killPlayer's avenge/
  ## partner-down tracking has an actual duo to work with. Same
  ## self-contained init shape as cosmeticFxSim below (initSimServer
  ## directly, since this file `include`s server.nim rather than importing
  ## helpers.nim's initCtfForTest).
  let previousDir = getCurrentDir()
  setCurrentDir(currentSourcePath.parentDir.parentDir)
  try:
    var config = defaultGameConfig()
    config.allowCosmeticFx = allowCosmeticFx
    config.brMode = true
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)
  discard result.addPlayer("red0")
  discard result.addPlayer("red1")
  discard result.addPlayer("blue0")
  discard result.addPlayer("blue1")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Red
  result.players[2].team = Blue
  result.players[3].team = Blue

proc cosmeticFxSim(allowCosmeticFx: bool): SimServer =
  ## Same self-contained init shape as test_shot_feedback_wire.nim's
  ## twoPlayerSim() -- initSimServer directly (not helpers.initCtfForTest),
  ## since this file is an `include`, not an `import`, of server.nim.
  let previousDir = getCurrentDir()
  setCurrentDir(currentSourcePath.parentDir.parentDir)
  try:
    var config = defaultGameConfig()
    config.allowCosmeticFx = allowCosmeticFx
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

suite "buildCosmeticFxPacket: the private cosmetic-effects JSON":
  test "gate off returns empty string even with a live shot and stain in range":
    var sim = cosmeticFxSim(false)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.recentShots.add ShotFx(x0: cx, y0: cy, x1: cx + 40, y1: cy,
      firedTick: sim.tickCount, color: sim.players[0].color, hit: true)
    sim.paintStains.add PaintStain(x: cx, y: cy, color: sim.players[0].color,
      onWall: false, seed: 1)
    discard sim.refreshPlayerFov(0)
    check buildCosmeticFxPacket(sim, 0) == ""

  test "out-of-range viewer index returns empty string, not a crash":
    var sim = cosmeticFxSim(true)
    check buildCosmeticFxPacket(sim, -1) == ""
    check buildCosmeticFxPacket(sim, 99) == ""

  test "a visible tracer serializes kind, pts, age, color, hit":
    var sim = cosmeticFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 64
    # The shot's own muzzle is the shooter's exact position -- inside their
    # vision bubble regardless of aim (test_fov.nim's own "close cells are
    # visible regardless of aim" contract), so this is visible to themselves
    # without needing the beam direction to match the aim cone.
    sim.recentShots.add ShotFx(x0: cx, y0: cy, x1: cx + 100, y1: cy,
      firedTick: sim.tickCount, color: sim.players[0].color, hit: true)
    discard sim.refreshPlayerFov(0)
    let packet = buildCosmeticFxPacket(sim, 0)
    check packet.len > 0
    check packet[0] == '{'  # distinguishable from a sprite frame at byte 0.
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    let entry = parsed["fx"][0]
    check entry["kind"].getStr == "tracer"
    check entry["hit"].getBool == true
    check entry["color"].getStr == playerColorText(sim.players[0].color)
    check entry["age"].getInt == 0
    check entry["pts"].len == CosmeticFxShotSamples
    check entry["pts"][0].kind != JNull  # the muzzle sample: always ours.

  test "a shot behind the viewer, beyond the vision bubble, produces no tracer":
    var sim = cosmeticFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 64  # facing north (test_fov.nim convention).
    # 200px due south of a north-facing viewer: outside the 60-degree cone
    # AND outside the default 90px vision bubble -- same gap shape
    # test_fov.nim's "behind, beyond the bubble" case uses.
    let (bx, by) = (cx, cy + 200)
    sim.recentShots.add ShotFx(x0: bx, y0: by, x1: bx + 40, y1: by,
      firedTick: sim.tickCount, color: sim.players[1].color, hit: false)
    discard sim.refreshPlayerFov(0)
    check not sim.fovVisibleAt(0, bx, by)  # self-validating: prove the fog
                                           # setup itself is doing real work.
    check buildCosmeticFxPacket(sim, 0) == ""

  test "a visible stain serializes kind, x, y, color, onWall":
    var sim = cosmeticFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.paintStains.add PaintStain(x: cx, y: cy,
      color: sim.players[0].color, onWall: true, seed: 7)
    discard sim.refreshPlayerFov(0)
    let packet = buildCosmeticFxPacket(sim, 0)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    check parsed["fx"][0]["kind"].getStr == "stain"
    check parsed["fx"][0]["x"].getInt == cx
    check parsed["fx"][0]["y"].getInt == cy
    check parsed["fx"][0]["onWall"].getBool == true
    check parsed["fx"][0]["color"].getStr == playerColorText(sim.players[0].color)

  test "a stain behind the viewer, beyond the vision bubble, is dropped":
    var sim = cosmeticFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 64
    let (bx, by) = (cx, cy + 200)
    sim.paintStains.add PaintStain(x: bx, y: by,
      color: sim.players[1].color, onWall: false, seed: 1)
    discard sim.refreshPlayerFov(0)
    check not sim.fovVisibleAt(0, bx, by)
    check buildCosmeticFxPacket(sim, 0) == ""

suite "cosmetic fx gate: byte-identical POLICY stream, on vs off (demonstrated, not asserted)":
  test "buildSpriteProtocolPlayerUpdates output is unchanged by the gate, with live shots and stains present":
    ## The actual safety claim this channel rests on: buildCosmeticFxPacket
    ## has exactly one caller (server.nim's takeover send pass), so it never
    ## enters buildSpriteProtocolPlayerUpdates's own call graph -- the wire
    ## every policy/mux socket reads. Proven here by calling the real
    ## policy-facing builder directly, with the same live combat state
    ## either gate value would draw its tracer/stain payload from, and
    ## diffing bytes -- not by reading server.nim and trusting the call count.
    var gateOff = cosmeticFxSim(false)
    var gateOn = cosmeticFxSim(true)
    for sim in [addr gateOff, addr gateOn]:
      let cx = sim[].gameMap.center.x
      let cy = sim[].gameMap.center.y
      sim[].players[0].x = cx
      sim[].players[0].y = cy
      sim[].recentShots.add ShotFx(x0: cx, y0: cy, x1: cx + 60, y1: cy,
        firedTick: sim[].tickCount, color: sim[].players[0].color, hit: true)
      sim[].paintStains.add PaintStain(x: cx, y: cy,
        color: sim[].players[0].color, onWall: false, seed: 3)
      discard sim[].refreshPlayerFov(0)
    var offState, offNext, onState, onNext: PlayerViewerState
    let offPacket =
      gateOff.buildSpriteProtocolPlayerUpdates(0, offState, offNext)
    let onPacket =
      gateOn.buildSpriteProtocolPlayerUpdates(0, onState, onNext)
    check offPacket == onPacket

  test "gameHash is identical whether the cosmetic-fx gate is on or off, given the same combat":
    ## sim.recentShots/sim.paintStains are already excluded from gameHash
    ## (global.nim's own doc comments on both); this proves flipping the new
    ## gate cannot perturb it either, the same shape as
    ## test_shot_feedback.nim's analogous hash-parity test for its gate.
    var gateOff = cosmeticFxSim(false)
    var gateOn = cosmeticFxSim(true)
    check gateOff.gameHash == gateOn.gameHash
    for sim in [addr gateOff, addr gateOn]:
      let cx = sim[].gameMap.center.x
      let cy = sim[].gameMap.center.y
      sim[].recentShots.add ShotFx(x0: cx, y0: cy, x1: cx + 60, y1: cy,
        firedTick: sim[].tickCount, color: sim[].players[0].color, hit: true)
      sim[].paintStains.add PaintStain(x: cx, y: cy,
        color: sim[].players[0].color, onWall: false, seed: 3)
    check gateOff.gameHash == gateOn.gameHash

  test "gameHash and policy stream are unaffected by S1/S5 state (lastKilledBy/partnerDownFx/avengeFx), gate on or off":
    ## The three Swap#13 fields (SimServer.lastKilledBy/partnerDownFx/
    ## avengeFx) live exactly like recentShots/paintStains above -- this
    ## proves the same safety claim extends to them: populated state here
    ## must move neither the policy-facing sprite packet nor gameHash,
    ## regardless of the cosmetic-fx gate.
    var gateOff = duoFxSim(false)
    var gateOn = duoFxSim(true)
    check gateOff.gameHash == gateOn.gameHash
    for sim in [addr gateOff, addr gateOn]:
      sim[].lastKilledBy[0] = 2
      sim[].partnerDownFx.add PartnerDownFx(
        partnerIndex: 1, x: 10, y: 20, color: sim[].players[0].color)
      sim[].avengeFx.add AvengeFx(avengerIndex: 0)
    check gateOff.gameHash == gateOn.gameHash
    var offState, offNext, onState, onNext: PlayerViewerState
    let offPacket =
      gateOff.buildSpriteProtocolPlayerUpdates(0, offState, offNext)
    let onPacket =
      gateOn.buildSpriteProtocolPlayerUpdates(0, onState, onNext)
    check offPacket == onPacket

suite "partnerIndex":
  test "returns the other player on a two-member team":
    var sim = duoFxSim(true)
    check sim.partnerIndex(0) == 1
    check sim.partnerIndex(1) == 0
    check sim.partnerIndex(2) == 3
    check sim.partnerIndex(3) == 2

  test "returns -1 for a team that is not exactly two members, or an out-of-range index":
    var sim = cosmeticFxSim(true) # 2 players, 2 DIFFERENT teams -- solo each.
    check sim.partnerIndex(0) == -1
    check sim.partnerIndex(1) == -1
    check sim.partnerIndex(-1) == -1
    check sim.partnerIndex(99) == -1

suite "killPlayer: S1/S5 avenge/partner-down tracking (Swap#13)":
  test "a non-elimination BR death notifies the fallen player's duo partner":
    var sim = duoFxSim(true)
    sim.players[0].x = 111
    sim.players[0].y = 222
    sim.killPlayer(0, 2)
    check sim.partnerDownFx.len == 1
    check sim.partnerDownFx[0].partnerIndex == 1
    check sim.partnerDownFx[0].x == 111 + CollisionW div 2
    check sim.partnerDownFx[0].y == 222 + CollisionH div 2
    check sim.partnerDownFx[0].color == sim.players[0].color
    # Gap-closing lane: the surviving partner previously had no field
    # naming who to hunt at all (only the dying player's own killcam did) --
    # a real killer must now be named on the notice.
    check sim.partnerDownFx[0].hasKiller
    check sim.partnerDownFx[0].killerColor == sim.players[2].color

  test "a causeless (killerless) BR death still notifies the partner, with no killer to name":
    var sim = duoFxSim(true)
    sim.killPlayer(0, -1, cause = "caught outside the zone")
    check sim.partnerDownFx.len == 1
    check not sim.partnerDownFx[0].hasKiller
    # Never a guessed identity for a causeless death -- killerColor stays
    # at its zero default and buildCosmeticFxPacket must gate on hasKiller,
    # not read this value, to decide whether to name anyone.
    check sim.partnerDownFx[0].killerColor == 0

  test "self-avenge fires when the just-killed cog is your own last killer":
    var sim = duoFxSim(true)
    sim.killPlayer(0, 2) # blue0 kills red0.
    check sim.avengeFx.len == 0 # nothing to avenge yet.
    # Direct state poke to re-engage the dead cog for the return trade --
    # same idiom test_shot_feedback_wire.nim's mutual-trade test uses.
    sim.players[0].alive = true
    sim.killPlayer(2, 0) # red0 kills blue0 back.
    check sim.avengeFx.len == 1
    check sim.avengeFx[0].avengerIndex == 0

  test "partner-avenge fires when you kill your partner's last killer":
    var sim = duoFxSim(true)
    sim.killPlayer(0, 2) # blue0 kills red0 -- red0's partner is red1 (1).
    check sim.avengeFx.len == 0
    sim.killPlayer(2, 1) # red1 kills blue0 back -- avenges the PARTNER's death.
    check sim.avengeFx.len == 1
    check sim.avengeFx[0].avengerIndex == 1

  test "an unrelated kill fires neither avenge relationship":
    var sim = duoFxSim(true)
    sim.killPlayer(0, 2) # blue0 kills red0.
    sim.avengeFx.setLen(0)
    # red1 kills blue1 (3) -- blue1 never killed anyone on red's duo.
    sim.killPlayer(3, 1)
    check sim.avengeFx.len == 0

  test "an elimination death fires neither avenge nor partner-down":
    var sim = duoFxSim(true)
    sim.killPlayer(0, -1, elimination = true)
    check sim.partnerDownFx.len == 0
    check sim.avengeFx.len == 0

  test "a non-brMode game never populates partner-down/avenge, even with a duo-shaped team":
    var sim = duoFxSim(true)
    sim.config.brMode = false
    sim.killPlayer(0, 2)
    check sim.partnerDownFx.len == 0
    check sim.avengeFx.len == 0

suite "zoneTicksToNextEvent (Swap#13 S6)":
  test "no zonePhases configured returns (0, false)":
    var sim = cosmeticFxSim(true)
    let (ticks, shrinking) = sim.zoneTicksToNextEvent()
    check ticks == 0
    check not shrinking

  test "during the initial wait, counts down to the wait's end (shrinking=false)":
    var sim = cosmeticFxSim(true)
    sim.config.zonePhases = @[ZonePhase(zPermille: 500, waitTicks: 100, shrinkTicks: 50, dps: 5)]
    sim.gameStartTick = sim.tickCount # elapsed = 0
    let (ticks, shrinking) = sim.zoneTicksToNextEvent()
    check ticks == 100
    check not shrinking

  test "mid-shrink, counts down to the shrink's end (shrinking=true)":
    var sim = cosmeticFxSim(true)
    sim.config.zonePhases = @[ZonePhase(zPermille: 500, waitTicks: 100, shrinkTicks: 50, dps: 5)]
    sim.gameStartTick = 0
    sim.tickCount = 120 # elapsed = 120 -> 20 ticks into the 50-tick shrink.
    let (ticks, shrinking) = sim.zoneTicksToNextEvent()
    check ticks == 30
    check shrinking

  test "after every phase resolves, holds forever at (0, false)":
    var sim = cosmeticFxSim(true)
    sim.config.zonePhases = @[ZonePhase(zPermille: 500, waitTicks: 100, shrinkTicks: 50, dps: 5)]
    sim.gameStartTick = 0
    sim.tickCount = 500
    let (ticks, shrinking) = sim.zoneTicksToNextEvent()
    check ticks == 0
    check not shrinking

suite "buildCosmeticFxPacket: S1/S4/S5/S6 additive kinds (Swap#13)":
  test "an 'incoming' entry serializes only kind+bearing, never a position":
    var sim = cosmeticFxSim(true)
    let fx = @[ShotFeedbackFx(shooterIndex: 1, targetIndex: 0, kill: false,
      weapon: "gun", distance: 40,
      shooterX: sim.players[0].x + CollisionW div 2 + 100,
      shooterY: sim.players[0].y + CollisionH div 2)]
    let packet = buildCosmeticFxPacket(sim, 0, incoming = fx)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    check parsed["fx"][0]["kind"].getStr == "incoming"
    check parsed["fx"][0].hasKey("bearing")
    check not parsed["fx"][0].hasKey("x")
    check not parsed["fx"][0].hasKey("y")

  test "a 'partner_down' entry serializes x/y/color/killerColor":
    var sim = cosmeticFxSim(true)
    let fx = @[PartnerDownFx(partnerIndex: 0, x: 55, y: 66,
      color: sim.players[1].color, hasKiller: true,
      killerColor: sim.players[0].color)]
    let packet = buildCosmeticFxPacket(sim, 0, partnerDown = fx)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    check parsed["fx"][0]["kind"].getStr == "partner_down"
    check parsed["fx"][0]["x"].getInt == 55
    check parsed["fx"][0]["y"].getInt == 66
    check parsed["fx"][0]["color"].getStr == playerColorText(sim.players[1].color)
    check parsed["fx"][0]["killerColor"].getStr == playerColorText(sim.players[0].color)

  test "a 'partner_down' entry with no killer serializes killerColor as null":
    var sim = cosmeticFxSim(true)
    let fx = @[PartnerDownFx(partnerIndex: 0, x: 55, y: 66,
      color: sim.players[1].color, hasKiller: false)]
    let packet = buildCosmeticFxPacket(sim, 0, partnerDown = fx)
    let parsed = parseJson(packet)
    check parsed["fx"][0]["kind"].getStr == "partner_down"
    check parsed["fx"][0]["killerColor"].kind == JNull

  test "an 'avenge' entry serializes just the kind, one per AvengeFx":
    var sim = cosmeticFxSim(true)
    let fx = @[AvengeFx(avengerIndex: 0), AvengeFx(avengerIndex: 0)]
    let packet = buildCosmeticFxPacket(sim, 0, avenge = fx)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 2
    check parsed["fx"][0]["kind"].getStr == "avenge"
    check parsed["fx"][1]["kind"].getStr == "avenge"

  test "a 'zone_eta' entry appears whenever zonePhases is configured, independent of the other params":
    var sim = cosmeticFxSim(true)
    sim.config.zonePhases = @[ZonePhase(zPermille: 500, waitTicks: 100, shrinkTicks: 50, dps: 5)]
    sim.gameStartTick = sim.tickCount
    let packet = buildCosmeticFxPacket(sim, 0)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    check parsed["fx"][0]["kind"].getStr == "zone_eta"
    check parsed["fx"][0]["ticks"].getInt == 100
    check parsed["fx"][0]["shrinking"].getBool == false

  test "gate on, nothing to say (no shots/stains/incoming/partnerDown/avenge/zonePhases) returns empty string":
    var sim = cosmeticFxSim(true)
    check buildCosmeticFxPacket(sim, 0) == ""

suite "buildCosmeticFxPacket: the 'bearing' kind (Gap-closing lane: CONTACT BEARING, swap14)":
  test "a bearing entry serializes only kind+bearing -- never x/y/distance/identity":
    var sim = cosmeticFxSim(true)
    let packet = buildCosmeticFxPacket(sim, 0, bearing = 37)
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    check parsed["fx"][0]["kind"].getStr == "bearing"
    check parsed["fx"][0]["bearing"].getInt == 37
    check not parsed["fx"][0].hasKey("x")
    check not parsed["fx"][0].hasKey("y")
    check not parsed["fx"][0].hasKey("distance")

  test "bearing=-1 (the 'nothing to say' sentinel) adds no entry":
    var sim = cosmeticFxSim(true)
    check buildCosmeticFxPacket(sim, 0, bearing = -1) == ""

suite "contactBearingFor (Gap-closing lane: CONTACT BEARING, swap14)":
  ## Unit tests on the eligibility/rate-limit decision itself -- separate
  ## from buildCosmeticFxPacket's own suite above, which only covers wire
  ## serialization of an already-decided value. Per this repo's "assert
  ## against the source" rule, these poke sim.tickCount/lastContactTick
  ## directly (same idiom the zoneTicksToNextEvent suite above already
  ## uses) rather than re-deriving the threshold from prose.

  test "gate off returns -1 even long after the quiet threshold would clear":
    var sim = cosmeticFxSim(false)
    sim.tickCount = 10_000
    check sim.contactBearingFor(0) == -1

  test "still within the quiet threshold (recent contact) returns -1":
    var sim = cosmeticFxSim(true)
    sim.tickCount += 100  # well under ContactBearingQuietTicks (TargetFps*10 = 240).
    check sim.contactBearingFor(0) == -1

  test "past the quiet threshold with a living hostile fires a bearing and stamps the emit clock":
    var sim = cosmeticFxSim(true)
    let
      cx = sim.players[0].x + CollisionW div 2
      cy = sim.players[0].y + CollisionH div 2
    sim.players[1].x = cx + 200 - CollisionW div 2
    sim.players[1].y = cy - CollisionH div 2
    sim.tickCount += 1000  # well past ContactBearingQuietTicks.
    check sim.lastBearingEmitTick[0] == -1
    let brads = sim.contactBearingFor(0)
    check brads >= 0
    check sim.lastBearingEmitTick[0] == sim.tickCount

  test "an immediate second call is rate-limited even though the corridor is still quiet":
    var sim = cosmeticFxSim(true)
    sim.players[1].x = sim.players[0].x + 200
    sim.tickCount += 1000
    check sim.contactBearingFor(0) >= 0  # first call fires and stamps the cooldown.
    check sim.contactBearingFor(0) == -1 # same tick, cooldown just stamped.

  test "a dead seat never gets a bearing":
    var sim = cosmeticFxSim(true)
    sim.players[0].alive = false
    sim.tickCount += 1000
    check sim.contactBearingFor(0) == -1

  test "no living hostile anywhere (every enemy dead) returns -1":
    var sim = cosmeticFxSim(true)
    sim.players[1].alive = false
    sim.tickCount += 1000
    check sim.contactBearingFor(0) == -1

  test "points toward the NEAREST living hostile, not a farther one":
    var sim = duoFxSim(true)  # 0/1 = Red duo, 2/3 = Blue duo.
    let
      cx = sim.players[0].x + CollisionW div 2
      cy = sim.players[0].y + CollisionH div 2
    sim.players[2].x = cx + 100 - CollisionW div 2  # blue0: close, due east.
    sim.players[2].y = cy - CollisionH div 2
    sim.players[3].x = cx - 900 - CollisionW div 2  # blue1: far, due west.
    sim.players[3].y = cy - CollisionH div 2
    sim.tickCount += 1000
    check sim.contactBearingFor(0) == bradsOfVector(100, 0)

suite "updateContactBearingClocks (Gap-closing lane: CONTACT BEARING, swap14 -- via real sim.step)":
  ## Engine-level check that the per-tick proximity scan sim.step() runs
  ## (sim.nim) actually drives lastContactTick, independent of the
  ## server.nim decision proc's own unit tests above.
  test "no hostile within config.gunRange: lastContactTick holds at match-start while tickCount advances":
    var sim = cosmeticFxSim(true)
    sim.players[1].x = sim.players[0].x + sim.config.gunRange * 3
    for i in 0 ..< 5:
      sim.step(@[], @[])
    check sim.lastContactTick[0] == 0
    check sim.tickCount == 5

  test "a hostile stepping inside config.gunRange stamps lastContactTick to that tick":
    var sim = cosmeticFxSim(true)
    sim.players[1].x = sim.players[0].x + sim.config.gunRange * 3
    sim.step(@[], @[])
    check sim.lastContactTick[0] == 0  # still nothing in range on tick 1.
    sim.players[1].x = sim.players[0].x + 50  # now well inside config.gunRange.
    sim.step(@[], @[])
    check sim.lastContactTick[0] == sim.tickCount
