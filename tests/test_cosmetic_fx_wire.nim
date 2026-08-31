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
