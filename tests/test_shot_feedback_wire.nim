## The server-side delivery half of the private shooter/victim combat-outcome
## channel (GameConfig.allowShotFeedback): buildShotFeedbackPacket's JSON,
## asserted against the source contract in server.nim, not this file's own
## prose. `include`d rather than imported, same as test_seat_takeover.nim,
## since buildShotFeedbackPacket is a private (non-exported) proc.
##
## The sim-side population (ShotFeedbackFx fields, gameHash exclusion, BUG A)
## is asserted separately in test_shot_feedback.nim.
##
## Killcam contract (asserted below): a hitsTaken entry with "kill": true —
## and ONLY such an entry — additionally carries "killerX"/"killerY" (the
## killer's center at the fatal impact, from ShotFeedbackFx.shooterX/Y) and
## "killerAlive" (the killer's alive state read at delivery, i.e. on the
## victim's death tick). Non-fatal hitsTaken entries and ALL shotsLanded
## entries never carry these keys: a shooter position delivered to a
## still-living player would be a wallhack, while the dead victim of the
## fatal hit cannot act on it (ShotFeedbackFx's fog-exception doc).

import std/unittest

include ../src/ctf/server

proc twoPlayerSim(): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(currentSourcePath.parentDir.parentDir)
  try:
    result = initSimServer(defaultGameConfig())
  finally:
    setCurrentDir(previousDir)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

suite "buildShotFeedbackPacket: the private combat-outcome JSON":
  test "no feedback touching this cog returns an empty string":
    let sim = twoPlayerSim()
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      weapon: "gun", distance: 40)]
    # Neither role in this entry is cog 5 (out of roster entirely) -- the
    # caller in server.nim's takeover pass already filters to entries that
    # touch this cog, but the proc itself must still no-op defensively.
    check buildShotFeedbackPacket(sim, fx, 5) == ""

  test "empty feedback returns an empty string":
    let sim = twoPlayerSim()
    check buildShotFeedbackPacket(sim, @[], 0) == ""

  test "the shooter's own cog gets a shotsLanded entry, not hitsTaken":
    let sim = twoPlayerSim()
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      friendlyFire: false, weapon: "gun", distance: 40)]
    let packet = buildShotFeedbackPacket(sim, fx, 0)
    check packet.len > 0
    check packet[0] == '{'    # trivially distinguishable from a sprite frame
                              # at the first byte, independent of frame type.
    let parsed = parseJson(packet)
    check parsed["hitsTaken"].len == 0
    check parsed["shotsLanded"].len == 1
    let hit = parsed["shotsLanded"][0]
    check hit["kill"].getBool == true
    check hit["friendlyFire"].getBool == false
    check hit["weapon"].getStr == "gun"
    check hit["distance"].getInt == 40
    check hit["victimTeam"].getStr == teamText(Blue)
    check hit.hasKey("victimColor")

  test "the victim's own cog gets a hitsTaken entry, not shotsLanded":
    let sim = twoPlayerSim()
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: false,
      friendlyFire: false, weapon: "spray", distance: 12)]
    let packet = buildShotFeedbackPacket(sim, fx, 1)
    let parsed = parseJson(packet)
    check parsed["shotsLanded"].len == 0
    check parsed["hitsTaken"].len == 1
    let taken = parsed["hitsTaken"][0]
    check taken["kill"].getBool == false
    check taken["weapon"].getStr == "spray"
    check taken["distance"].getInt == 12
    check taken["killerTeam"].getStr == teamText(Red)
    check taken.hasKey("killerColor")
    # Killcam narrowing: a NON-fatal hitsTaken entry must NOT reveal the
    # shooter's position — the victim is still alive and could act on it.
    check not taken.hasKey("killerX")
    check not taken.hasKey("killerY")
    check not taken.hasKey("killerAlive")

  test "a FATAL hitsTaken entry carries killerX/killerY/killerAlive (killcam)":
    let sim = twoPlayerSim()
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      friendlyFire: false, weapon: "gun", distance: 40,
      shooterX: 321, shooterY: 654)]
    let packet = buildShotFeedbackPacket(sim, fx, 1)
    let parsed = parseJson(packet)
    check parsed["hitsTaken"].len == 1
    let taken = parsed["hitsTaken"][0]
    check taken["kill"].getBool == true
    # The impact-moment capture from the populate site, verbatim.
    check taken["killerX"].getInt == 321
    check taken["killerY"].getInt == 654
    # Alive state is read at DELIVERY (the victim's death tick): this killer
    # still stands, so the camera has a live target to pan to.
    check taken["killerAlive"].getBool == true

  test "killerAlive reads false when the killer died by delivery (mutual trade)":
    var sim = twoPlayerSim()
    sim.players[0].alive = false
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      weapon: "gun", distance: 40, shooterX: 100, shooterY: 200)]
    let parsed = parseJson(buildShotFeedbackPacket(sim, fx, 1))
    let taken = parsed["hitsTaken"][0]
    check taken["killerX"].getInt == 100
    check taken["killerY"].getInt == 200
    check taken["killerAlive"].getBool == false

  test "shotsLanded entries NEVER carry killer position keys, fatal or not":
    # The shooter needs no camera pointed at themselves; more importantly the
    # killcam exception is scoped to the DEAD participant only.
    let sim = twoPlayerSim()
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      weapon: "gun", distance: 40, shooterX: 321, shooterY: 654)]
    let parsed = parseJson(buildShotFeedbackPacket(sim, fx, 0))
    check parsed["shotsLanded"].len == 1
    let landed = parsed["shotsLanded"][0]
    check landed["kill"].getBool == true
    check not landed.hasKey("killerX")
    check not landed.hasKey("killerY")
    check not landed.hasKey("killerAlive")
    check not landed.hasKey("shooterX")

  test "delivered UNFOGGED: identity is present even if the participant never rendered the other side":
    # No fovVisibleAt call anywhere in this path -- confirmed by there being
    # no such call in buildShotFeedbackPacket's body at all. This test pins
    # that behaviorally: identity is present regardless of position.
    var sim = twoPlayerSim()
    sim.players[0].x = 0
    sim.players[0].y = 0
    sim.players[1].x = MapWidth - 1
    sim.players[1].y = MapHeight - 1
    let fx = @[ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
      weapon: "grenade", distance: 999)]
    let packet = buildShotFeedbackPacket(sim, fx, 0)
    let parsed = parseJson(packet)
    check parsed["shotsLanded"][0].hasKey("victimTeam")
    check parsed["shotsLanded"][0].hasKey("victimColor")

  test "a mutual trade in the same tick populates both arrays for the involved cogs":
    let sim = twoPlayerSim()
    let fx = @[
      ShotFeedbackFx(shooterIndex: 0, targetIndex: 1, kill: true,
        weapon: "gun", distance: 40),
      ShotFeedbackFx(shooterIndex: 1, targetIndex: 0, kill: false,
        weapon: "gun", distance: 40)
    ]
    let packetForZero = buildShotFeedbackPacket(sim, fx, 0)
    let parsedZero = parseJson(packetForZero)
    check parsedZero["shotsLanded"].len == 1   # cog 0 shot cog 1
    check parsedZero["hitsTaken"].len == 1     # cog 0 was ALSO shot by cog 1
