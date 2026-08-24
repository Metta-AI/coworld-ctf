## One-off smoke probe for the team16-widen lane (BR_MAPGEN.md §6.2): can a
## 16-team, 32-seat (16x2) config even BOOT and step a few ticks? This is
## NOT wired into CI — it exists to answer the lane's verification question
## by running the real init/step path, and to pin down exactly where a
## 16-team draw currently fails (the map-generator/layout shape for 16
## teams is out of this lane's scope; see BR_MAPGEN.md §6.5 items 3-5).
##
## Run from the repository root:
##   nim r tools/team16_smoke_probe.nim

import std/[os, strutils], bitworld/spriteprotocol, ../src/ctf/sim

const GameDir = currentSourcePath.parentDir.parentDir

proc probeConfig(): GameConfig =
  result = defaultGameConfig()
  result.teams = 16
  result.mapPath = "gen"
  result.mapSeed = 42

when isMainModule:
  echo "activeTeams(16): ", activeTeams(16)
  echo "Team.high: ", Team.high, " (", Team.high.ord + 1, " members)"

  # Dispatch coverage: every Team member resolves through teamText/
  # teamColor/teamEndzoneColor without hitting a raiseAssert catch-all
  # (those only guard the 4-team-only layoutCorners/Plus orbit switches,
  # which activeTeams(16)'s members never reach).
  for team in Team:
    let c = teamEndzoneColor(team)
    echo "  ", teamText(team), " palette=", teamColor(team),
      " endzone=(", c.r, ",", c.g, ",", c.b, ")"

  # JSON config parsing: readSlotTeam's enum loop must recognize a BR-only
  # name like "azure" (index 14), not just red/blue/green/yellow. A 2-team
  # config can't SEAT azure, so this still raises via validate()'s slot
  # check — but a working parser raises "slot is azure but seats 2", proving
  # the name parsed, where the old hardcoded parser would instead have
  # raised "must be red, blue, green, or yellow" (never recognizing it).
  block jsonParsing:
    var config = defaultGameConfig()
    try:
      config.update("""{"slots": [{"team": "azure"}]}""")  # teams stays 2.
      doAssert false, "expected a slot/team-count mismatch to raise"
    except CtfError as e:
      doAssert "azure" in e.msg, "parser did not recognize \"azure\": " & e.msg
      echo "JSON slot team \"azure\" parsed correctly: ", e.msg

  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    let config = probeConfig()
    echo "config.teams = ", config.teams

    var sim: SimServer
    try:
      sim = initSimServer(config)
      echo "initSimServer OK: map=", sim.gameMap.name,
        " teamCount=", sim.gameMap.teamCount()
    except CatchableError as e:
      echo "initSimServer FAILED (", e.name, "): ", e.msg
      echo "EXPECTED: no 16-team map SHAPE exists yet in generateMapAttempt " &
        "(falls through to the 2-team shell) — that generator is out of " &
        "this lane's scope (BR_MAPGEN.md §6.5 items 3-5, sibling lanes " &
        "br-mapgen/spawn-anchor-scope/spawn-points). This lane's own scope " &
        "(enum, gates, switches, JSON parsers above) is unaffected by this."
      quit(0)

    for i in 0 ..< 32:
      discard sim.addPlayer("p" & $i)
    echo "addPlayer x32 OK, players=", sim.players.len

    try:
      sim.startGame()
      echo "startGame OK, phase=", sim.phase
    except CatchableError as e:
      echo "startGame FAILED (", e.name, "): ", e.msg
      quit(0)

    let idle = newSeq[InputState](sim.players.len)
    for tick in 0 ..< 30:
      sim.step(idle, idle)
    echo "stepped 30 ticks OK, tickCount=", sim.tickCount,
      " gameHash=", sim.gameHash()
  finally:
    setCurrentDir(previousDir)
