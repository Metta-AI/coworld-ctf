## Server-owned FIRST LIGHT belief-lite handoff checks.

import std/unittest

include ../src/ctf/server

suite "shell FIRST LIGHT server seam":
  test "self hp count and fraction are populated from sim truth":
    var sim = initSimServer(defaultGameConfig())
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].hp = 3
    sim.players[playerIndex].shieldHp = 2

    let live = sim.firstLightSelfState(playerIndex)
    check live.hp == 5
    check (live.hp > 0) == (live.hpFrac > 0.0)

    sim.players[playerIndex].hp = 0
    sim.players[playerIndex].shieldHp = 0
    let depleted = sim.firstLightSelfState(playerIndex)
    check depleted.hp == 0
    check (depleted.hp > 0) == (depleted.hpFrac > 0.0)

  test "self combat facts are populated from sim truth":
    var config = defaultGameConfig()
    config.brMode = false
    var sim = initSimServer(config)
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].lives = 2
    sim.players[playerIndex].aimBrads = 37
    sim.players[playerIndex].fireCooldown = 11
    sim.players[playerIndex].fireWindup = 3
    sim.players[playerIndex].windupBrads = 0
    sim.players[playerIndex].hasGrenade = true
    sim.players[playerIndex].hasShield = true
    sim.players[playerIndex].shieldHp = 2
    sim.players[playerIndex].hasSprayPaint = true
    sim.players[playerIndex].arcTicksLeft = 5

    let live = sim.firstLightSelfState(playerIndex)
    check live.lives == some(2)
    check live.aimBrads == 37
    check live.fireCooldown == 11
    check live.fireWindup == 3
    check live.windup == some(0)
    check live.hasGrenade
    check live.hasShield
    check live.shieldHp == 2
    check live.hasSprayPaint
    check live.arcTicksLeft == 5

    sim.players[playerIndex].windupBrads = -1
    sim.players[playerIndex].hasShield = false
    sim.players[playerIndex].shieldHp = 0
    let idle = sim.firstLightSelfState(playerIndex)
    check idle.windup.isNone
    check not idle.hasShield
    check idle.shieldHp == 0

  test "self lives are omitted in battle royale mode":
    var config = defaultGameConfig()
    config.brMode = true
    var sim = initSimServer(config)
    let playerIndex = sim.addPlayer("red0")
    sim.players[playerIndex].lives = 1

    let live = sim.firstLightSelfState(playerIndex)
    check live.lives.isNone

  test "visible track combat facts are populated from sim truth":
    var sim = initSimServer(defaultGameConfig())
    let viewerIndex = sim.addPlayer("red0")
    let targetIndex = sim.addPlayer("blue0")
    sim.players[targetIndex].x = sim.players[viewerIndex].x
    sim.players[targetIndex].y = sim.players[viewerIndex].y
    sim.players[targetIndex].aimBrads = 91
    sim.players[targetIndex].hp = 2
    sim.players[targetIndex].hasShield = true
    sim.players[targetIndex].shieldHp = 1
    sim.players[targetIndex].hasSprayPaint = true
    sim.players[targetIndex].arcTicksLeft = 4
    sim.players[targetIndex].level = AceLevel

    let inputs = sim.firstLightBodyInputs(viewerIndex)
    check inputs.visibleTracks.len == 1
    let track = inputs.visibleTracks[0]
    check track.seat == sim.players[targetIndex].joinOrder
    check track.aimBrads == some(91)
    check track.hpKnown == some(3)
    check track.shielded == sim.players[targetIndex].hasShield
    check track.weapon == some(bwSpray)
    check track.veteranMarker

    sim.players[targetIndex].hasSprayPaint = false
    sim.players[targetIndex].arcTicksLeft = 0
    sim.players[targetIndex].hasGrenade = true
    sim.fovCaches.setLen(0)
    let grenadeInputs = sim.firstLightBodyInputs(viewerIndex)
    check grenadeInputs.visibleTracks[0].weapon == some(bwGrenade)
