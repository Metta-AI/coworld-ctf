## The 16-team BR golden: a REAL end-to-end 16-duo episode — elimination
## ruleset, the shrink zone, and all four authored neutral item pools,
## together, on a real brmapkit-drawn map — ticked to completion. This is
## the launch-readiness audit's #1 gap: nothing in CI had ever stepped a
## 16-team sim before this suite.
##
## Deliberately a REAL bot-played recording, not synthetic scripted inputs:
## a scripted-input test exercises the ENGINE's BR mechanics but never the
## POLICY's own perception of a wide roster, which is exactly where the two
## defects this fixture would have caught actually lived —
##   - the endgame stall (17c39f0): the hunt override had nothing to steer
##     at because enemy perception was capped at the 4 primary colors.
##   - the perception cap this lane fixed (players/baseline/baseline.nim):
##     a bot's OWN color guess was capped at the same 4 colors, so any seat
##     past yellow could never confirm itself alive and sent zero input for
##     the whole match — the "all 16 teams active" suite below is the
##     permanent, machine-checked guard against that regressing silently.
##
## Fixture: tests/fixtures/br-golden-16team.bitreplay — 32 seats (16 duos),
## recorded with the real players/baseline/baseline.out bot via
## tools/record_br_match.sh against tests/fixtures/br-golden-map.json (a
## real brmapkit draw — see its own `genSeed`), brMode on, the doc's
## 5-phase shrink-zone schedule (BR_MAPGEN.md §4.3), all four neutral item
## pools authored. Re-record recipe: tools/record_br_golden.sh (records,
## verifies the properties below independently, and is the ONLY supported
## way to refresh this fixture — see its own header for the load-rule
## caution: record on an idle machine or risk baking in a degenerate
## episode as the permanent golden).
##
## The two numeric floors below (MinDisplacementPx, MinTeamsFiring) are
## read off THIS fixture's own recorded numbers with margin, not invented:
## the recording's least-active team moved ~1737px and every one of the 16
## fired at least 2 shots. The contract is "the bug this lane fixed cannot
## silently come back", not an arbitrary tuning target — re-derive both
## honestly from whatever a re-record actually produces.

import
  helpers,
  std/[json, math, os, sequtils, tables, unittest],
  ctf/[replays, sim],
  "../tools/extract_events"

const
  FixturePath = GameDir / "tests" / "fixtures" / "br-golden-16team.bitreplay"
  MapSpecPath = GameDir / "tests" / "fixtures" / "br-golden-map.json"
  Teams = 16
  MinDisplacementPx = 500.0
    ## floor: the recording's quietest team still moved ~1737px; 500 leaves
    ## wide margin while still catching a team that never left its pocket.
  MinTeamsFiring = 12
    ## floor: all 16 fired in the recording; 12 leaves margin for a
    ## legitimately quiet duo (eliminated early) without masking the
    ## perception-cap regression this suite exists to catch.
  BrRosterColors = [
    "red", "blue", "green", "yellow", "black", "silver", "ivory", "pink",
    "umber", "rust", "orange", "plum", "lime", "navy", "azure", "peach",
  ]

proc aliveFlag(fs: FrameSeat): bool =
  (fs.flags and 1) != 0

suite "16-team BR golden: end-to-end":
  test "the committed map spec is a real brmapkit draw with elimination-BR shape":
    let specNode = parseJson(readFile(MapSpecPath))
    check specNode.hasKey("genSeed")   ## a generator draw, not hand-authored.
    check specNode["spawnGroups"].getInt() == Teams
    check specNode["flagless"].getBool()
    check specNode["spawnPoints"].len > 0
    check specNode["spawnPoints"].len mod Teams == 0   ## an even per-group split.
    check specNode["medKitSpawns"].len > 0
    check specNode["shieldSpawns"].len > 0
    check specNode["spraySpawns"].len > 0
    check specNode["grenadeSpawns"].len > 0

  test "the fixture's own config carries the full BR mode contract":
    let data = loadReplay(FixturePath)
    let cfg = parseJson(data.configJson)
    check cfg["teams"].getInt() == Teams
    check cfg["brMode"].getBool()
    check cfg["zonePhases"].len > 0
    check cfg["lives"].getInt() == 1
    check cfg["slots"].len == Teams * 2

  test "a real 16-duo episode ticks to completion, hash-exact, with a winner or a documented draw":
    ## extractEvents re-simulates with the recorded hash stream validated
    ## every step and RAISES on any mismatch (see its own doc comment) —
    ## reaching the checks below at all IS the "hashes match / re-simulates
    ## hash-exact from disk" proof, the same guarantee test_replay.nim's
    ## "hashes match" pins for the five classic fixtures.
    let extraction = extractEvents(loadReplay(FixturePath))
    check extraction.finished
    check extraction.winner.len > 0 or extraction.isDraw
    if not extraction.isDraw:
      check extraction.winner in BrRosterColors

  test "eliminations are monotone: once a team has zero living players, it never has one again":
    let extraction = extractEvents(loadReplay(FixturePath), captureFrames = true)
    check extraction.slotTeam.len == extraction.frameSlots
    let teams = extraction.slotTeam.deduplicate()
    var everEliminated = initTable[string, bool]()
    for idx in 0 ..< extraction.frameCount:
      var aliveByTeam = initTable[string, int]()
      for seat in 0 ..< extraction.frameSlots:
        if extraction.frameSeat(idx, seat).aliveFlag():
          let team = extraction.slotTeam[seat]
          aliveByTeam[team] = aliveByTeam.getOrDefault(team, 0) + 1
      for team in teams:
        let alive = aliveByTeam.getOrDefault(team, 0)
        if everEliminated.getOrDefault(team, false):
          check alive == 0             ## an eliminated team never comes back.
        elif alive == 0:
          everEliminated[team] = true
    ## The episode actually eliminated someone — otherwise the monotonicity
    ## check above is vacuously true and proves nothing.
    check everEliminated.len > 0

  test "zone damage fired at least once":
    let extraction = extractEvents(loadReplay(FixturePath))
    check extraction.events.anyIt(it.kind == Damage and it.weapon == "zone")

  test "item pickups occurred from all four authored neutral pools":
    let extraction = extractEvents(loadReplay(FixturePath))
    var seenItems: seq[string]
    for event in extraction.events:
      if event.kind == Pickup and event.item notin seenItems:
        seenItems.add event.item
    for want in ["grenade", "med_kit", "shield", "spray_can"]:
      check want in seenItems

  test "all 16 teams displace beyond a floor, and at least 12 fire (the perception-cap regression guard)":
    let extraction = extractEvents(loadReplay(FixturePath), captureFrames = true)
    let teams = extraction.slotTeam.deduplicate()
    check teams.len == Teams
    var
      dispByTeam = initTable[string, float]()
      shotsByTeam = initTable[string, int]()
      lastPos = initTable[int, tuple[x, y: int]]()
    for seat in 0 ..< extraction.slotTeam.len:
      let team = extraction.slotTeam[seat]
      shotsByTeam[team] = shotsByTeam.getOrDefault(team, 0) +
        extraction.slotShotsFired[seat]
    for idx in 0 ..< extraction.frameCount:
      for seat in 0 ..< extraction.frameSlots:
        let fs = extraction.frameSeat(idx, seat)
        let team = extraction.slotTeam[seat]
        if fs.aliveFlag():
          if seat in lastPos:
            let (lx, ly) = lastPos[seat]
            let d = sqrt(
              float((fs.x - lx) * (fs.x - lx) + (fs.y - ly) * (fs.y - ly)))
            dispByTeam[team] = dispByTeam.getOrDefault(team, 0.0) + d
          lastPos[seat] = (fs.x, fs.y)
        else:
          lastPos.del(seat)
    for team in teams:
      checkpoint team & " displaced " & $dispByTeam.getOrDefault(team, 0.0) & "px"
      check dispByTeam.getOrDefault(team, 0.0) >= MinDisplacementPx
    var firingTeams = 0
    for team in teams:
      if shotsByTeam.getOrDefault(team, 0) > 0:
        inc firingTeams
    checkpoint $firingTeams & " of " & $teams.len & " teams fired at least one shot"
    check firingTeams >= MinTeamsFiring
