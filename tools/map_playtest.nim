## map_playtest — turns one recorded episode into the spatial evidence a map
## verdict needs: where players actually went, where they died, where the flag
## travelled, and whether the objective ever converted.
##
## It rides `toolutil.openReplay` + `stepReplay`, the same hash-validated
## re-simulation `tools/extract_events.nim` walks, so the numbers below are
## ground truth rather than a reconstruction, and a clean run also proves the
## recording re-simulates deterministically. Reading the live `sim` on each
## tick — rather than post-processing the frame stream — is what lets the
## capture check below evaluate the engine's OWN predicate.
##
## CAPTURES ARE COUNTED TWICE, ON PURPOSE. An earlier pass at this reported 0
## captures on every map INCLUDING the arena, because it inferred a capture
## from the flag's `carrier -> -1` edge, and that edge never arrives: the game
## ENDS on the capture tick, so the field is already cleared by the time a
## post-step loop looks at it. Here `captures` is the engine's own Capture
## event, and `capturesInZone` independently re-evaluates the engine's own
## `inCaptureZone` predicate against the credited scorer's position ON THAT
## TICK. Equal counts mean the geometry model and the engine agree; a gap is a
## harness bug and prints as one.
##
## "REACHED THE ZONE BUT NEVER CONVERTED" IS AN EMPTY CATEGORY, and finding
## that out is what `carrierApproachPx` is here for. `carrierInZoneTicks` used
## to be the signal for it and read 0 on all 18 episodes ever measured,
## including both that captured. It is not blind — `tests/test_carrier_zone.nim`
## fires the same predicate on a planted carrier and on the real capture-tick
## position of a real scorer — the state simply cannot be sampled: the engine
## captures the instant a live carrier's point is inside its own zone, with no
## precondition, and clears the carrier in that same tick. So a carrier can
## never be caught standing on its own line, and a map cannot be blamed for a
## conversion failure that the rules make impossible. What CAN be measured, and
## is the number that actually separates "never got near" from "died on the
## doorstep", is HOW CLOSE the best carry run got: `carrierApproachPx`.
##
## Usage:
##   nim c -d:release -o:/tmp/mapplaytest tools/map_playtest.nim
##   /tmp/mapplaytest ep0.bitreplay --name gen:1003 --out /tmp/pt0.json
##   python3 tools/map_playtest.py /tmp/pt0.json /tmp/pt1.json /tmp/pt2.json

import
  std/[json, math, os, strutils],
  ../src/ctf/[map_metrics, sim],
  carrier_zone, toolutil

const
  EvidenceCellPx = 10
    ## Occupancy grid resolution. Matches the grid the heatmap draws on, so the
    ## visited-floor evidence and the picture are the same measurement.
  CloseRangePx = GunRange div 4
    ## The radius that actually separates maps.
    ##
    ## `fightTicks` below counts an enemy inside GunRange, and GunRange is
    ## 1050px — WIDER THAN THE BOARD on every map this harness measures (the
    ## arena is 1235x659, the small generated class 1050x560). Measured, it
    ## reads 99-100% on the arena and on all three generated 2-team maps
    ## alike, so its `< 0.15` flag is unfirable and the number is not evidence
    ## of anything. It is kept because it IS the engine's own shooting range,
    ## and a map big enough to break that saturation should still be caught;
    ## `closeTicks` is the one that discriminates at these sizes.

type MapPlaytestError = object of CatchableError

proc fail(message: string) {.noreturn.} =
  raise newException(MapPlaytestError, message)

proc parseArgs(): tuple[replay, name, outPath: string, tickCap: int] =
  var params = commandLineParams()
  var i = 0
  result.tickCap = 0
  while i < params.len:
    let arg = params[i]
    if arg in ["--name", "--out", "--ticks"]:
      if i + 1 >= params.len: fail(arg & " requires a value")
      inc i
      case arg
      of "--name": result.name = params[i]
      of "--out": result.outPath = params[i]
      else: result.tickCap = params[i].parseInt
    elif arg in ["-h", "--help"]:
      echo "Usage: map_playtest <replay> [--name NAME] [--out out.json] " &
        "[--ticks N]\n" &
        "  --ticks N  stop accumulating evidence after N ticks, so maps whose\n" &
        "             episodes ended at different lengths are measured over\n" &
        "             the same window. A capture ENDS the episode, so without\n" &
        "             this the map that got decided fast reads as more dead\n" &
        "             floor purely because it was watched for less time."
      quit(0)
    elif arg.startsWith("--"):
      fail("unknown flag: " & arg)
    else:
      result.replay = arg
    inc i
  if result.replay.len == 0: fail("need a .bitreplay path")
  if result.name.len == 0: result.name = result.replay.extractFilename()

proc main() =
  let args = parseArgs()
  if not fileExists(args.replay): fail("no such replay: " & args.replay)
  var (sim, replay) = openReplay(parseReplayBytes(readFile(args.replay)))
  sim.collectEvents = true

  let
    gameMap = sim.gameMap
    w = gameMap.width
    h = gameMap.height
    teamCount = gameMap.teamCount()
    gw = (w + EvidenceCellPx - 1) div EvidenceCellPx
    gh = (h + EvidenceCellPx - 1) div EvidenceCellPx
  var zones: seq[CaptureZone]
  for team in gameMap.teams():
    zones.add gameMap.captureZone(team)

  var
    occupancy = newSeq[int](gw * gh)
    occTeam = newSeq[seq[int]](teamCount)
    kills = newSeq[int](teamCount)
    deaths = newJArray()
    carries = newJArray()
    steals, captures, capturesInZone, carrierInZoneTicks = 0
    aliveTicks, fightTicks, closeTicks = 0
    carrierTicks = 0
      ## Ticks with at least one live carrier — the DENOMINATOR the approach
      ## minimum needs. A 40px best approach off 3000 carry-ticks and one off
      ## 12 are not the same map result, and the bare minimum cannot tell them
      ## apart.
    carrierApproachPx = -1
      ## Closest any live carrier came to its own zone, in px along the run
      ## home. -1 means NOBODY EVER CARRIED, which is a different result from
      ## 0 and must not be folded into one.
    measuredTicks = 0
    capturesAll = 0
      ## Captures over the WHOLE episode, never truncated by --ticks. The
      ## outcome classification below reads this one: an episode decided by a
      ## capture at 4153t is still an episode decided by a capture when the
      ## measurement window closed at 1890t, and calling it an elimination
      ## because the window missed it would be a lie about the result.
  for t in 0 ..< teamCount:
    occTeam[t] = newSeq[int](gw * gh)

  proc cellOf(x, y: int): int =
    let
      cx = clamp(x div EvidenceCellPx, 0, gw - 1)
      cy = clamp(y div EvidenceCellPx, 0, gh - 1)
    cy * gw + cx

  while replay.playing:
    replay.stepReplay(sim)
    # The measurement window closes, but the re-simulation does NOT: stepping
    # to the end is what validates the recording's hashes, and a run that
    # stopped early would silently stop proving determinism — the one thing
    # riding this loop that is free.
    if args.tickCap > 0 and sim.tickCount > args.tickCap:
      for event in sim.events:
        if event.kind == Capture: inc capturesAll
      sim.events.setLen(0)
      continue
    measuredTicks = sim.tickCount
    for event in sim.events:
      case event.kind
      of Death:
        let victim = sim.playerIndexForSlot(event.source)
        if victim >= 0:
          deaths.add %*{
            "x": sim.players[victim].x, "y": sim.players[victim].y,
            "team": ord(sim.players[victim].team)}
      of Kill:
        let killer = sim.playerIndexForSlot(event.source)
        if killer >= 0:
          inc kills[ord(sim.players[killer].team)]
      of FlagSteal: inc steals
      of Capture:
        inc captures
        inc capturesAll
        # The geometry cross-check, evaluated on the SAME state the engine
        # scored from: was the credited scorer inside their own capture zone
        # on the capture tick? Checking the flag's `carrier` field instead
        # reads 0 on every map including the arena, because the capture ends
        # the game and the carrier is already cleared by the time this loop
        # sees the tick. That is the exact bug that once reported "0 captures
        # everywhere"; the fix is the predicate, not the edge.
        let scorer = sim.playerIndexForSlot(event.source)
        if scorer >= 0 and
            zones[ord(sim.players[scorer].team)].inCaptureZone(
              sim.players[scorer].x, sim.players[scorer].y):
          inc capturesInZone
      else: discard
    sim.events.setLen(0)

    for index, player in sim.players:
      if not player.alive: continue
      inc aliveTicks
      let cell = cellOf(player.x, player.y)
      inc occupancy[cell]
      inc occTeam[ord(player.team)][cell]
      if player.carryingFlag:
        carries.add %*{"x": player.x, "y": player.y,
                       "team": ord(player.team)}
      # Contact time at TWO radii. A map that keeps the teams apart reads as
      # pace without contact, which is a map defect the kill count alone
      # cannot show — but only the close radius can see it here, because
      # GunRange spans the whole board (see CloseRangePx).
      var nearest = high(int)
      for other in sim.players:
        if not other.alive or other.team == player.team: continue
        let
          dx = other.x - player.x
          dy = other.y - player.y
        nearest = min(nearest, dx * dx + dy * dy)
      if nearest <= GunRange * GunRange: inc fightTicks
      if nearest <= CloseRangePx * CloseRangePx: inc closeTicks

    # The TRIPWIRE, not a measurement (see the module header and
    # carrier_zone.carriersInOwnZone): this is 0 on every episode by
    # construction. It is still counted because the day the engine grows a
    # precondition on capture — own heart home, a channel timer, a contested
    # zone — a carrier CAN start standing on its own line, this goes non-zero,
    # and the approach numbers below stop being the whole story.
    carrierInZoneTicks += sim.carriersInOwnZone(zones)

    # THE MEASUREMENT. How much further the closest live carrier still had to
    # run at its own base before the engine would have scored it. The episode
    # MINIMUM is the number a map is judged on: it separates a board where
    # carriers never got out of midfield from one where a carrier died on the
    # doorstep, which is the distinction the "steals converted to zero
    # captures" flag needs and could never get from a count that is always 0.
    let approach = sim.carrierApproach(zones)
    if approach >= 0:
      inc carrierTicks
      if carrierApproachPx < 0 or approach < carrierApproachPx:
        carrierApproachPx = approach

  var wall = newJArray()
  block:
    let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
    for cy in 0 ..< gh:
      for cx in 0 ..< gw:
        let
          px = min(w - 1, cx * EvidenceCellPx + EvidenceCellPx div 2)
          py = min(h - 1, cy * EvidenceCellPx + EvidenceCellPx div 2)
        wall.add %(if diag.maxWall[py * w + px]: 1 else: 0)

  var homes, spawns = newJArray()
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      half = gameMap.spawnPocketHalf(team)
    homes.add %*{"x": anchor.x, "y": anchor.y}
    spawns.add %*{"x": anchor.x - half.w, "y": anchor.y - half.h,
                  "w": 2 * half.w, "h": 2 * half.h}

  var occTeamJson = newJArray()
  for t in 0 ..< teamCount:
    occTeamJson.add %occTeam[t]

  # The single-episode MapPlay, so the Nim-side dynamic type is grounded in a
  # real producer rather than being a schema nobody fills. Merging across
  # episodes (rule 3) and the heatmap stay in map_playtest.py, which is where
  # numpy/PIL already live.
  var deadOpen, deadVisited = 0
  for i in 0 ..< gw * gh:
    if wall[i].getInt() == 1: continue
    inc deadOpen
    if occupancy[i] > 0: inc deadVisited
  # HOW THE EPISODE ENDED, off the engine's own end state rather than guessed
  # from the tick count. Without this the length column is unreadable: a 1940t
  # episode and a 5120t episode are not "short" and "long", they are a game
  # somebody WON and a game nobody won, and averaging them is meaningless. The
  # tick-count guess ("under the cap = decided") is what this replaces — the
  # cap is not in the replay at a fixed value and overshoots it by the game-over
  # ceremony, so the guess is wrong at exactly the boundary that matters.
  let outcome =
    if sim.phase != GameOver: "unfinished"
    elif sim.timeLimitReached: "timeLimit"
    elif capturesAll > 0: "capture"
    else: "elimination"

  # Rates divide by the MEASURED window, outcomes report the real episode
  # length. Under --ticks those differ, and dividing a windowed kill count by
  # the full episode length would understate pace by exactly the truncation.
  let rateTicks = max(1, if args.tickCap > 0: measuredTicks else: sim.tickCount)
  let play = MapPlay(
    episodes: 1,
    ticks: @[sim.tickCount],
    captures: @[captures],
    balanceEntropy: balanceEntropy(kills, teamCount),
    pace: 1000.0 * float(sum(kills)) / float(rateTicks),
    fightTimeFrac: float(fightTicks) / float(max(1, aliveTicks)),
    deadFloorFrac: 1.0 - float(deadVisited) / float(max(1, deadOpen)))

  let evidence = %*{
    "map": args.name,
    "replay": args.replay.extractFilename(),
    "ticks": sim.tickCount,
    "cell": EvidenceCellPx,
    "gw": gw, "gh": gh, "width": w, "height": h,
    "teams": teamCount,
    "wall": wall,
    "occupancy": %occupancy,
    "occTeam": occTeamJson,
    "deaths": deaths,
    "carries": carries,
    "kills": %kills,
    "steals": steals,
    "captures": captures,
    "capturesInZone": capturesInZone,
    "carrierInZoneTicks": carrierInZoneTicks,
    "carrierApproachPx": carrierApproachPx,
    "carrierTicks": carrierTicks,
    "aliveTicks": aliveTicks,
    "fightTicks": fightTicks,
    "closeTicks": closeTicks,
    "closeRangePx": CloseRangePx,
    "measuredTicks": measuredTicks,
    "tickCap": args.tickCap,
    "outcome": outcome,
    "capturesAll": capturesAll,
    "isDraw": sim.isDraw,
    "winner": (if sim.phase == GameOver and not sim.isDraw: ord(sim.winner)
               else: -1),
    "homes": homes,
    "spawns": spawns,
    "captureRadius": gameMap.endzoneRadius,
    "flagRing": gameMap.flagRing,
    "play": {
      "episodes": play.episodes,
      "balanceEntropy": play.balanceEntropy,
      "pace": play.pace,
      "fightTimeFrac": play.fightTimeFrac,
      "deadFloorFrac": play.deadFloorFrac,
    },
  }
  if args.outPath.len > 0:
    writeFile(args.outPath, $evidence)
    stderr.writeLine "map_playtest: " & args.name & " " & $sim.tickCount &
      "t " & outcome & "  steals=" & $steals & " captures=" & $captures &
      " (of those, " & $capturesInZone & " verified inside the engine's own " &
      "capture zone; closest carrier approach " &
      (if carrierApproachPx < 0: "n/a, nobody carried"
       else: $carrierApproachPx & "px over " & $carrierTicks & " carry-ticks") &
      ") -> " & args.outPath
  else:
    echo evidence

when isMainModule:
  try:
    main()
  except MapPlaytestError as e:
    stderr.writeLine "map_playtest: " & e.msg
    quit(2)
  except ReplayError as e:
    stderr.writeLine "map_playtest replay error: " & e.msg
    quit(1)
  except CtfError as e:
    stderr.writeLine "map_playtest sim error: " & e.msg
    quit(1)
