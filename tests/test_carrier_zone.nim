## The positive control for tools/map_playtest's carrier-in-zone sampler.
##
## THE TRAP THIS EXISTS TO CLOSE. `carrierInZoneTicks` reported 0 on every
## episode ever measured — 15 four-team episodes across 5 generated boards,
## 3 two-team arena episodes, and both committed fixtures that CAPTURE. A
## number that is 0 on a positive case is unreadable on its own: a blind
## detector and a correct detector over an empty population print exactly the
## same thing, and map_playtest.py's "steals converted to ZERO captures" flag
## was telling readers to distinguish "never reached the zone" from "reached
## it and could not score" BY READING IT. `tests/test_map_eval.nim`'s
## `doorwayMap` closes the same trap for the chokepoint detector.
##
## So the suites below drive `tools/carrier_zone` — the same code the tool
## runs, not a re-implementation — against states whose answer is known:
## a PLANTED carrier standing in its own zone (the detector must fire), and
## the real episodes (it must not). Both halves have to hold, or the number
## means nothing.

import
  helpers,
  std/[os, unittest],
  ctf/[replays, sim],
  ../tools/carrier_zone

const
  CaptureFixture = GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"
    ## A committed 2-team arena episode that ENDS ON A CAPTURE. Deterministic
    ## and permanent, unlike the /tmp episodes the anomaly was first seen on.
  FourTeamFixture = GameDir / "tests" / "fixtures" / "gen-colossal-4team.bitreplay"
    ## The 4-team case the bug report suspected of being special. It is not,
    ## and this is what says so.

proc zonesOf(sim: SimServer): seq[CaptureZone] =
  ## The tool's own zone table: one zone per active team, indexed by `ord`.
  ## Teams are always the prefix `Red .. Team(teamCount - 1)`, which is what
  ## makes the ord indexing safe.
  for team in sim.gameMap.teams():
    result.add sim.gameMap.captureZone(team)

proc openFixture(path: string): (SimServer, ReplayPlayer) =
  ## Same setup as `tools/toolutil.openReplay`, without dragging pixie into a
  ## test binary: fresh sim from the recorded config, non-looping, hash-checked.
  let
    previousDir = getCurrentDir()
    data = loadReplay(path)
  setCurrentDir(GameDir)
  try:
    var config = defaultGameConfig()
    config.update(data.configJson)
    var sim = initSimServer(config)
    sim.collectEvents = true
    sim.gameEventLoggingEnabled = false
    var replay = initReplayPlayer(data)
    replay.looping = false
    result = (sim, replay)
  finally:
    setCurrentDir(previousDir)

# ---------------------------------------------------------------------------
# Positive control: the detector fires on a planted carrier
# ---------------------------------------------------------------------------

suite "carrier-in-zone sampler: positive control":
  test "a carrier planted in its own zone is seen":
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      anchor = sim.gameMap.teamAnchor(Red)
    check sim.carriersInOwnZone(zones) == 0
    # Red's player 0 carries the Blue heart and stands on Red's own base —
    # the exact state the metric claims to count.
    sim.players[0].placeAtCenter(anchor.x, anchor.y)
    sim.players[0].carryingFlag = true
    sim.flags[Blue].carrier = 0
    check sim.carriersInOwnZone(zones) == 1

  test "the same carrier standing in the ENEMY zone is not seen":
    # The negative half. Without it, a sampler that ignored the zone entirely
    # and counted every carrier would pass the test above.
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      enemyAnchor = sim.gameMap.teamAnchor(Blue)
    sim.players[0].placeAtCenter(enemyAnchor.x, enemyAnchor.y)
    sim.players[0].carryingFlag = true
    sim.flags[Blue].carrier = 0
    check sim.carriersInOwnZone(zones) == 0

  test "a dead carrier in its own zone is not seen":
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      anchor = sim.gameMap.teamAnchor(Red)
    sim.players[0].placeAtCenter(anchor.x, anchor.y)
    sim.players[0].carryingFlag = true
    sim.players[0].alive = false
    sim.flags[Blue].carrier = 0
    check sim.carriersInOwnZone(zones) == 0

  test "the sampler reads the CARRIER's zone, not the stolen heart's":
    # A Red carrier holding the Blue heart scores at RED's base. Indexing the
    # zone table by the flag's team instead of the holder's would invert this
    # and report a capture-ready carrier as being nowhere near home.
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      redAnchor = sim.gameMap.teamAnchor(Red)
    sim.players[0].placeAtCenter(redAnchor.x, redAnchor.y)
    sim.players[0].carryingFlag = true
    sim.flags[Blue].carrier = 0
    check zones[ord(Red)].inCaptureZone(redAnchor.x, redAnchor.y)
    check not zones[ord(Blue)].inCaptureZone(redAnchor.x, redAnchor.y)
    check sim.carriersInOwnZone(zones) == 1

# ---------------------------------------------------------------------------
# approachPx — the measurement that replaces the always-zero count
# ---------------------------------------------------------------------------

suite "carrier approach distance":
  test "a point inside the zone is 0 px away and the anchor is inside":
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      anchor = sim.gameMap.teamAnchor(Red)
    check zones[ord(Red)].inCaptureZone(anchor.x, anchor.y)
    check zones[ord(Red)].approachPx(
      anchor.x, anchor.y, anchor.x, anchor.y) == 0

  test "the reported distance IS the crossing: one px less is still outside":
    # Shape-agnostic, so it holds for column, disc, square, arm and diagonal
    # zones alike: walk exactly `approachPx` px at the anchor and you are in;
    # stop one px short and you are out. That is the definition, checked
    # rather than assumed.
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      zone = zones[ord(Red)]
      anchor = sim.gameMap.teamAnchor(Red)
      enemy = sim.gameMap.teamAnchor(Blue)
      d = zone.approachPx(enemy.x, enemy.y, anchor.x, anchor.y)
    check d > 0
    let
      atCrossing = homeRayPoint(enemy.x, enemy.y, anchor.x, anchor.y, d)
      oneShort = homeRayPoint(enemy.x, enemy.y, anchor.x, anchor.y, d - 1)
    check zone.inCaptureZone(atCrossing.x, atCrossing.y)
    check not zone.inCaptureZone(oneShort.x, oneShort.y)

  test "a carrier further from home has further to go":
    var sim = twoTeamGame()
    let
      zones = sim.zonesOf()
      zone = zones[ord(Red)]
      anchor = sim.gameMap.teamAnchor(Red)
      enemy = sim.gameMap.teamAnchor(Blue)
      midX = (anchor.x + enemy.x) div 2
      midY = (anchor.y + enemy.y) div 2
      far = zone.approachPx(enemy.x, enemy.y, anchor.x, anchor.y)
      near = zone.approachPx(midX, midY, anchor.x, anchor.y)
    check near > 0
    check far > near

  test "a 4-team board's DIAGONAL corner zones measure too":
    # The zone shape the bug report suspected. A corner team's zone is an L1
    # ball round the map corner, not a column, and `approachPx` asks
    # `inCaptureZone` precisely so a shape it has never seen still answers.
    let gameMap = cachedCtfMap(1010, teams = 4)
    check gameMap.teamCount() == 4
    for team in gameMap.teams():
      let
        zone = gameMap.captureZone(team)
        anchor = gameMap.teamAnchor(team)
        center = gameMap.center
      check zone.inCaptureZone(anchor.x, anchor.y)
      check zone.approachPx(anchor.x, anchor.y, anchor.x, anchor.y) == 0
      # Midfield is outside every team's zone and a real distance from it.
      check zone.approachPx(center.x, center.y, anchor.x, anchor.y) > 0

# ---------------------------------------------------------------------------
# The real episodes: the population really is empty
# ---------------------------------------------------------------------------

suite "carrier-in-zone on real episodes":
  test "an episode that CAPTURES never samples a carrier in its own zone":
    # The whole finding, locked. The engine's `checkWinCondition` runs at the
    # end of every step and captures the instant the sampler's own predicate
    # turns true for a live carrier, clearing `flags[].carrier` in that same
    # tick — so between steps, the only vantage a replay tool has, the state
    # cannot exist. The capture below proves a carrier really did reach the
    # zone; the 0 beside it proves the sample can never catch it.
    var (sim, replay) = openFixture(CaptureFixture)
    let zones = sim.zonesOf()
    var
      captures = 0
      inZoneSamples = 0
      capturePointInZone = 0
      bestApproach = -1
    while replay.playing:
      replay.stepReplay(sim)
      for event in sim.events:
        if event.kind != Capture: continue
        inc captures
        # THE POSITIVE CONTROL ON REAL DATA: the same predicate, handed the
        # credited scorer's real position on the capture tick, DOES fire.
        let scorer = sim.playerIndexForSlot(event.source)
        if scorer >= 0 and zones[ord(sim.players[scorer].team)].inCaptureZone(
            sim.players[scorer].x, sim.players[scorer].y):
          inc capturePointInZone
      sim.events.setLen(0)
      inZoneSamples += sim.carriersInOwnZone(zones)
      let approach = sim.carrierApproach(zones)
      if approach >= 0 and (bestApproach < 0 or approach < bestApproach):
        bestApproach = approach
    check captures >= 1
    check capturePointInZone == captures   # the predicate is not blind
    check inZoneSamples == 0               # yet the between-steps sample is 0
    # A carry happened and got measurably close without ever sampling inside.
    check bestApproach > 0

  test "a 4-team episode behaves the same way":
    var (sim, replay) = openFixture(FourTeamFixture)
    let zones = sim.zonesOf()
    check zones.len == 4
    var
      inZoneSamples = 0
      bestApproach = -1
    while replay.playing:
      replay.stepReplay(sim)
      sim.events.setLen(0)
      inZoneSamples += sim.carriersInOwnZone(zones)
      let approach = sim.carrierApproach(zones)
      if approach >= 0 and (bestApproach < 0 or approach < bestApproach):
        bestApproach = approach
    check inZoneSamples == 0
    # 8 steals on this board, so somebody carried: the replacement metric has
    # something to say where the count it replaces says only "0".
    check bestApproach > 0
