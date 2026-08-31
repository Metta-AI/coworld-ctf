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
