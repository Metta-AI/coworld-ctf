## The "glory" kind riding the private per-seat cosmetic-effects channel
## (GameConfig.allowCosmeticFx): GloryDeedFx's push at the source
## (recordKill/recordCapture's callers) and buildCosmeticFxPacket's
## serialization of it, asserted against the source contract in
## sim.nim/server.nim -- not this file's own prose. `include`d rather than
## imported, same as test_cosmetic_fx_wire.nim beside it, since
## buildCosmeticFxPacket is a private (non-exported) proc.
##
## This lineage predates the real glory/awardDeed system -- see
## GloryDeedFx's own doc comment (sim_types.nim) for that delta. The only
## mint points it has are recordKill/recordCapture (roster.nim), called from
## applyFire, resolveActiveArcCones and the capture-zone loop with a
## concrete SEAT index already in hand, not just a team -- so this channel
## ships seat-grain (the wire's `self` field) even though `color`/`team`
## alone would read as duo-grain (a duo's two seats share one color by
## default; see buildCosmeticFxPacket's doc comment). The suite below proves
## both self=true (the viewer's own deed), self=false/same team (a
## teammate's), and self=false/other team (an enemy's) all serialize
## correctly.
##
## Two halves in one file (mirrors test_shot_feedback.nim +
## test_shot_feedback_wire.nim's split, collapsed to keep this lane's diff
## tight): SOURCE (recordKill/recordCapture's callers actually push to
## sim.gloryDeeds, gated) and WIRE (buildCosmeticFxPacket serializes and
## fog-clips it, and the byte-identical-policy-stream claim holds with it
## present).

import std/[unittest, json]

include ../src/ctf/server

proc gloryFxSim(allowCosmeticFx: bool): SimServer =
  ## Same self-contained init shape as test_cosmetic_fx_wire.nim's
  ## cosmeticFxSim() -- initSimServer directly (not helpers.initCtfForTest),
  ## since this file is an `include`, not an `import`, of server.nim. Three
  ## seats: two on Red (a "duo") and one on Blue, so self-vs-teammate-vs-
  ## enemy is all reachable from one rig.
  let previousDir = getCurrentDir()
  setCurrentDir(currentSourcePath.parentDir.parentDir)
  try:
    var config = defaultGameConfig()
    config.allowCosmeticFx = allowCosmeticFx
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)
  discard result.addPlayer("red0")
  discard result.addPlayer("red1")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Red
  result.players[2].team = Blue

proc lineUpShot(sim: var SimServer, shooter, target: int, gap: int) =
  ## Same rig test_shot_feedback.nim's lineUpShot uses (inlined here since
  ## this file `include`s server.nim rather than importing tests/helpers.nim):
  ## shooter aims due east at a target `gap` px to the right, cleared to fire
  ## this tick.
  sim.players[shooter].x = sim.gameMap.center.x
  sim.players[shooter].y = sim.gameMap.center.y
  sim.players[shooter].aimBrads = 0
  sim.players[shooter].windupBrads = -1
  sim.players[shooter].fireCooldown = 0
  sim.players[target].x = sim.gameMap.center.x + gap
  sim.players[target].y = sim.gameMap.center.y

suite "glory-toast source: recordKill/recordCapture's callers push GloryDeedFx only when the gate is on":
  test "gate off: a landed kill pushes nothing to sim.gloryDeeds":
    var sim = gloryFxSim(false)
    sim.lineUpShot(shooter = 0, target = 2, gap = 40)
    sim.players[2].hp = 1
    sim.tryFire(0)
    check not sim.players[2].alive
    check sim.gloryDeeds.len == 0

  test "gate on: a gun kill pushes word=kill, amount=1, actorIndex=shooter, at the victim's position":
    var sim = gloryFxSim(true)
    sim.lineUpShot(shooter = 0, target = 2, gap = 40)
    sim.players[2].hp = 1
    sim.tryFire(0)
    check not sim.players[2].alive
    check sim.gloryDeeds.len == 1
    let deed = sim.gloryDeeds[0]
    check deed.word == "kill"
    check deed.amount == 1
    check deed.actorIndex == 0
    check deed.team == Red  # captured at MINT time, not re-read later
    check deed.x == sim.players[2].x + CollisionW div 2
    check deed.y == sim.players[2].y + CollisionH div 2

  test "gameHash is identical whether the gate is on or off, given the same kill":
    var gateOff = gloryFxSim(false)
    var gateOn = gloryFxSim(true)
    gateOff.lineUpShot(0, 2, 40)
    gateOn.lineUpShot(0, 2, 40)
    gateOff.players[2].hp = 1
    gateOn.players[2].hp = 1
    check gateOff.gameHash == gateOn.gameHash
    gateOff.tryFire(0)
    gateOn.tryFire(0)
    check gateOn.gloryDeeds.len == 1
    check gateOff.gloryDeeds.len == 0
    check gateOff.gameHash == gateOn.gameHash

suite "buildCosmeticFxPacket: the glory kind":
  test "gate off returns empty string even with a live glory deed in range":
    var sim = gloryFxSim(false)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    discard sim.refreshPlayerFov(0)
    let deeds = @[GloryDeedFx(tick: sim.tickCount, word: "kill", amount: 1,
      actorIndex: 0, x: cx, y: cy)]
    check buildCosmeticFxPacket(sim, 0, deeds) == ""

  test "out-of-range viewer index returns empty string, not a crash":
    var sim = gloryFxSim(true)
    let deeds = @[GloryDeedFx(tick: 0, word: "kill", amount: 1,
      actorIndex: 0, x: 0, y: 0)]
    check buildCosmeticFxPacket(sim, -1, deeds) == ""
    check buildCosmeticFxPacket(sim, 99, deeds) == ""

  test "a visible SELF kill serializes kind, tick, word, amount, team, self, x, y":
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    discard sim.refreshPlayerFov(0)
    let deeds = @[GloryDeedFx(tick: 7, word: "kill", amount: 1,
      actorIndex: 0, team: Red, x: cx, y: cy)]
    let packet = buildCosmeticFxPacket(sim, 0, deeds)
    check packet.len > 0
    let parsed = parseJson(packet)
    check parsed["fx"].len == 1
    let entry = parsed["fx"][0]
    check entry["kind"].getStr == "glory"
    check entry["tick"].getInt == 7
    check entry["word"].getStr == "kill"
    check entry["amount"].getInt == 1
    check entry["team"].getStr == teamText(Red)
    check entry["self"].getBool == true
    check entry["x"].getInt == cx
    check entry["y"].getInt == cy

  test "a teammate's capture (different seat, same team) serializes self=false":
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    discard sim.refreshPlayerFov(0)
    # actorIndex 1 is red1 -- the viewer's DUO partner, not the viewer.
    let deeds = @[GloryDeedFx(tick: 3, word: "capture", amount: 1,
      actorIndex: 1, team: Red, x: cx, y: cy)]
    let packet = buildCosmeticFxPacket(sim, 0, deeds)
    let parsed = parseJson(packet)
    let entry = parsed["fx"][0]
    check entry["word"].getStr == "capture"
    check entry["self"].getBool == false
    check entry["team"].getStr == teamText(Red)

  test "an enemy's kill (different team) serializes self=false, team=enemy":
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    discard sim.refreshPlayerFov(0)
    let deeds = @[GloryDeedFx(tick: 5, word: "kill", amount: 1,
      actorIndex: 2, team: Blue, x: cx, y: cy)]
    let packet = buildCosmeticFxPacket(sim, 0, deeds)
    let parsed = parseJson(packet)
    let entry = parsed["fx"][0]
    check entry["self"].getBool == false
    check entry["team"].getStr == teamText(Blue)

  test "a glory deed beyond the vision bubble is dropped (fog-clipped like a stain)":
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 64
    let (bx, by) = (cx, cy + 200)
    discard sim.refreshPlayerFov(0)
    check not sim.fovVisibleAt(0, bx, by)
    let deeds = @[GloryDeedFx(tick: 1, word: "kill", amount: 1,
      actorIndex: 2, x: bx, y: by)]
    check buildCosmeticFxPacket(sim, 0, deeds) == ""

  test "an out-of-range actorIndex is skipped defensively, not a crash":
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[0].x = cx
    sim.players[0].y = cy
    discard sim.refreshPlayerFov(0)
    let deeds = @[GloryDeedFx(tick: 1, word: "kill", amount: 1,
      actorIndex: 99, x: cx, y: cy)]
    check buildCosmeticFxPacket(sim, 0, deeds) == ""

suite "glory kind: per-recipient properties, two simultaneous takeover viewers, same frame":
  test "self differs by viewer, and fog differs by viewer, for the SAME gloryDeeds seq":
    ## The property this channel rests on beyond the single-viewer suite
    ## above: buildCosmeticFxPacket is called once PER takeover socket, all
    ## against the identical frame-scoped `frameGloryDeeds` (see server.nim's
    ## takeover send pass) -- so two simultaneous viewers must each get their
    ## OWN self/fog read of the SAME underlying deeds, not a shared one.
    var sim = gloryFxSim(true)
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    # Viewer A (seat 0, Red) and viewer B (seat 1, Red teammate) share one
    # spot but face opposite ways -- same rig test_fov.nim's cone tests use
    # (64 = north, 192 = south; aimVector's own doc comment).
    sim.players[0].x = cx
    sim.players[0].y = cy
    sim.players[0].aimBrads = 64
    sim.players[1].x = cx
    sim.players[1].y = cy
    sim.players[1].aimBrads = 192
    discard sim.refreshPlayerFov(0)
    discard sim.refreshPlayerFov(1)
    # deed1: minted by seat 0 (viewer A itself), sitting on the shared spot --
    # visible to BOTH viewers regardless of aim (their own square), same
    # "close cells are visible regardless of aim" contract test_fov.nim
    # documents. This is the (a) case: same deed, self should differ by who
    # is asking.
    let deed1 = GloryDeedFx(tick: 10, word: "kill", amount: 1,
      actorIndex: 0, team: Red, x: cx, y: cy)
    # deed2: 150px north of the shared spot -- ahead of north-facing A
    # (VisionBubble=90 < 150, well inside the ~1050px gun-range cone), but
    # BEHIND south-facing B and beyond B's bubble, so fogged for B only.
    # This is the (b) case: one deed, visible to A, invisible to B.
    let deed2 = GloryDeedFx(tick: 11, word: "capture", amount: 1,
      actorIndex: 2, team: Blue, x: cx, y: cy - 150)
    let deeds = @[deed1, deed2]

    let packetA = buildCosmeticFxPacket(sim, 0, deeds)
    let packetB = buildCosmeticFxPacket(sim, 1, deeds)

    check packetA.len > 0
    let parsedA = parseJson(packetA)
    check parsedA["fx"].len == 2  # both deeds visible to A
    check parsedA["fx"][0]["word"].getStr == "kill"
    check parsedA["fx"][0]["self"].getBool == true   # (a): A IS the actor
    check parsedA["fx"][1]["word"].getStr == "capture"

    check packetB.len > 0
    let parsedB = parseJson(packetB)
    # (b): deed2 (north, behind B) is dropped -- only deed1 survives B's fog.
    check parsedB["fx"].len == 1
    check parsedB["fx"][0]["word"].getStr == "kill"
    check parsedB["fx"][0]["self"].getBool == false  # (a): B is NOT the actor

suite "glory kind: byte-identical POLICY stream, on vs off (demonstrated, not asserted)":
  test "buildSpriteProtocolPlayerUpdates output is unchanged by the gate, with a real glory deed populated":
    ## The actual safety claim this channel rests on (same as
    ## test_cosmetic_fx_wire.nim's analogous test): buildCosmeticFxPacket has
    ## exactly one caller (server.nim's takeover send pass), and sim.gloryDeeds
    ## is never read by buildSpriteProtocolPlayerUpdates at all -- proven here
    ## with a REAL populated deed (from an actual kill), not just an empty seq.
    var gateOff = gloryFxSim(false)
    var gateOn = gloryFxSim(true)
    gateOff.lineUpShot(0, 2, 40)
    gateOn.lineUpShot(0, 2, 40)
    gateOff.players[2].hp = 1
    gateOn.players[2].hp = 1
    gateOff.tryFire(0)
    gateOn.tryFire(0)
    check gateOn.gloryDeeds.len == 1
    check gateOff.gloryDeeds.len == 0
    discard gateOff.refreshPlayerFov(0)
    discard gateOn.refreshPlayerFov(0)
    var offState, offNext, onState, onNext: PlayerViewerState
    let offPacket =
      gateOff.buildSpriteProtocolPlayerUpdates(0, offState, offNext)
    let onPacket =
      gateOn.buildSpriteProtocolPlayerUpdates(0, onState, onNext)
    check offPacket == onPacket
