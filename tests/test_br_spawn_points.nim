## BR N-point spawn subsystem (docs/designs/BR_MAPGEN.md §6.1, §4.2): a
## symNone map may author explicit `spawnPoints` (team-major flattened
## seq[MapPoint], perTeam implicit like TeamPickups.barriers) instead of
## relying on the legacy per-team teamAnchor pocket, and a `flagless` map
## arms no flag pedestal / flag state / endzone scoring at all. Suite pins:
##   - the spec JSON round-trips spawnPoints + flagless exactly; absent is
##     byte-identical to the pre-BR default;
##   - the carve: mapProtectedFloorAt opens a pocket around each spawn point,
##     and (independently) drops the flag-ring/approach carve when flagless;
##   - the validator: count-per-team, on-board, pocket-fit, and pairwise
##     non-overlap all reject malformed spawnPoints, and the reachability
##     (wall-overlap) check spawnPoints shares with barriers/shields/cans is
##     necessarily tautological here (a spawn point sits at the center of its
##     OWN carved pocket) — proven directly, not asserted as a rejection;
##   - symNone + spawnPoints RELAXES the legacy 2-team/sides-only gate to
##     whatever teamCount the layout reports: a 4-team (corners layout)
##     symNone map with spawnPoints validates and boots; the SAME map WITHOUT
##     spawnPoints still rejects, exactly as it did before this subsystem;
##   - a full flagless episode on an 8-point, 4-team map seats every player
##     at its authored spec point and steps to a normal (non-capture) finish;
##   - flagless is not just gameplay-inert: the WIRE stream itself carries
##     zero flag/pedestal/heart sprites and zero flag/endzone labels (no
##     pedestal position is even computed — resetFlags skips the
##     teamAnchor/flagHome call entirely), while the same map with flags
##     armed still carries the full, unchanged vocabulary.

import
  helpers,
  std/[json, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[arena, global, labels, sim, sim_config, sim_types]

const
  W = 1235
  H = 659
  SpawnClear = 40

proc fourTeamPickupsNode(boardH = H): JsonNode =
  ## teamPickups.shields/cans need EXACTLY teamCount points on ANY symNone
  ## map (spawnPoints or not) — a fixed, walkable, well-separated quad so
  ## every spec below only has to vary spawnPoints/flagless/layout.
  %*{
    "shields": [[40, 80], [W - 40, 80], [40, boardH - 80], [W - 40, boardH - 80]],
    "cans": [[40, 130], [W - 40, 130], [40, boardH - 130], [W - 40, boardH - 130]],
    "barriers": newJArray()
  }

proc fourTeamSpawnPointsNode(boardH = H): JsonNode =
  ## 8 points, 2 per team in ENUM order (Red, Blue, Green, Yellow) — the
  ## team-major flattening the spec grammar requires. Each same-team pair is
  ## separated by 100px on y (> 2*SpawnClear); cross-team pairs are separated
  ## by hundreds of px on x or y. No two pockets overlap.
  %*[
    [150, 150], [150, 250],                                # Red    (team 0)
    [W - 150, 150], [W - 150, 250],                        # Blue   (team 1)
    [150, boardH - 150], [150, boardH - 250],              # Green  (team 2)
    [W - 150, boardH - 150], [W - 150, boardH - 250],      # Yellow (team 3)
  ]

## Hand-computed expected spawn position per JOIN order (players added
## p0..p7): teamForSlot deals Team(order mod teamCount) round-robin, so join
## order 0..7 seats Red,Blue,Green,Yellow,Red,Blue,Green,Yellow — and
## arrangeHomePositions' per-team occurrence counter picks spawnPoints[0],
## [2], [4], [6] for each team's FIRST seat and [1], [3], [5], [7] for the
## second. Written out by hand (not re-derived from spawnPosition's formula)
## so this is an assertion against the GRAMMAR, not the implementation.
const ExpectedJoinOrderSpawn = [
  (150, 150),           # p0 Red   #1 -> spawnPoints[0]
  (W - 150, 150),        # p1 Blue  #1 -> spawnPoints[2]
  (150, H - 150),        # p2 Green #1 -> spawnPoints[4]
  (W - 150, H - 150),    # p3 Yellow#1 -> spawnPoints[6]
  (150, 250),            # p4 Red   #2 -> spawnPoints[1]
  (W - 150, 250),        # p5 Blue  #2 -> spawnPoints[3]
  (150, H - 250),        # p6 Green #2 -> spawnPoints[5]
  (W - 150, H - 250),    # p7 Yellow#2 -> spawnPoints[7]
]

proc fourTeamSpec(
  spawnPoints = true, flagless = true, layout = "corners", boardH = H
): string =
  ## boardH defaults to the RECTANGULAR BR field height (H, != W): the
  ## flagless case is exactly the combo that needs a non-square corners
  ## board to work at all. A caller that wants flags ARMED on a corners
  ## layout must pass boardH = W (square) — validateMap now REJECTS
  ## symNone+corners/plus with flags armed on a non-square board outright
  ## (teamAnchor's rot90-orbit fallback for non-Red teams needs one, same as
  ## rot90 symmetry itself; see arena.nim's validateMap).
  var node = %*{
    "name": "br-spawn-demo",
    "width": W, "height": boardH,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": SpawnClear, "spawnClearH": SpawnClear,
    "gunRange": GunRange,
    "symmetry": "none",
    "layout": layout,
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "medKitSpawns": [[W div 2, boardH div 3], [W div 2, 2 * boardH div 3]],
    "medKitCandidates": [[W div 2, boardH div 3], [W div 2, 2 * boardH div 3]],
    "leftObstacles": newJArray(),
    "teamPickups": fourTeamPickupsNode(boardH),
  }
  if spawnPoints:
    node["spawnPoints"] = fourTeamSpawnPointsNode(boardH)
  if flagless:
    node["flagless"] = %true
  $node

proc fourTeamMap(
  spawnPoints = true, flagless = true, layout = "corners", boardH = H
): CtfMap =
  mapFromSpecJson(fourTeamSpec(spawnPoints, flagless, layout, boardH))

proc fourTeamGame(flagless: bool, boardH = H): SimServer =
  ## A started, 8-seat (2/team) game on the 4-team spawnPoints map, with or
  ## without flags armed. Flags-armed callers must pass boardH = W — see
  ## fourTeamSpec's doc comment.
  var config = defaultGameConfig()
  config.teams = 4
  config.mapSpec = fourTeamSpec(spawnPoints = true, flagless = flagless, boardH = boardH)
  result = initCtfForTest(config)
  for i in 0 ..< 8:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc collectFlagishLabels(sim: var SimServer): seq[string] =
  ## Every spkSprite label whose text is flag/pedestal/heart/endzone-shaped,
  ## across the board/spectator stream and a living + ghost player stream —
  ## the same streams test_label_contract.nim's collectLabels sweeps, and
  ## the same spkSprite-only scan it uses to prove a label IS in the
  ## vocabulary, used here in both directions (IS for a flagged map, is NOT
  ## for a flagless one). addFlagSprites and addMapMarkers's endzone loop
  ## both run unconditionally at INIT (never lazily), so one fresh snapshot
  ## per stream is the complete surface — no stepping required.
  ## The board/endzone bakes are PROCESS-WIDE and keyed by byte size alone
  ## ("the arena is fixed per process"), so a sibling test module that left a
  ## same-sized map cached would make this sweep read the PREVIOUS map's
  ## pixels — a stale cold bake diffs non-empty everywhere and manufactures
  ## endzone fade bands on a map that has no endzones. Production hits the
  ## same hazard when the serve loop hot-switches replays and answers it the
  ## same way (server.nim's invalidateBoardMapCaches call); this test is a
  ## map switch, so it owes the same courtesy. Without it this test passes or
  ## fails on its shard IMPORT ORDER, which is not a property of flagless.
  invalidateBoardMapCaches()
  var
    gstate = initGlobalViewerState()
    livingState: PlayerViewerState
    ghostState: PlayerViewerState
  proc absorb(into: var seq[string], messages: seq[SpritePacketMessage]) =
    for message in messages:
      if message.kind == spkSprite:
        let label = message.sprite.label
        if "flag" in label or "heart" in label or
            label.startsWith(LabelPrefixEndzone):
          into.add label
  result.absorb(sim.buildGlobalMessages(gstate))
  result.absorb(sim.buildPlayerMessages(0, livingState))
  sim.players[7].alive = false
  result.absorb(sim.buildPlayerMessages(7, ghostState))
  sim.players[7].alive = true

suite "BR N-point spawn subsystem":

  test "spec JSON round-trips spawnPoints + flagless exactly":
    let once = mapSpecJson(fourTeamMap())
    let twice = mapSpecJson(mapFromSpecJson(once))
    check once == twice
    let rebuilt = mapFromSpecJson(once)
    check rebuilt.spawnPoints.len == 8
    check rebuilt.flagless == true
    check rebuilt.spawnPoints[0] == MapPoint(x: 150, y: 150)
    check rebuilt.spawnPoints[7] == MapPoint(x: W - 150, y: H - 250)

  test "absent spawnPoints/flagless parses as empty/false (the pre-BR default)":
    var node = parseJson(fourTeamSpec(layout = "sides"))
    node.delete("spawnPoints")
    node.delete("flagless")
    node["layout"] = %"sides"
    node["teamPickups"]["shields"] = %*[[40, 80], [W - 40, 80]]
    node["teamPickups"]["cans"] = %*[[40, 130], [W - 40, 130]]
    let gm = mapFromSpecJson($node)
    check gm.spawnPoints.len == 0
    check gm.flagless == false
    ## And the round-trip of THAT map echoes neither key at all.
    let spec = parseJson(mapSpecJson(gm))
    check not spec.hasKey("spawnPoints")
    check not spec.hasKey("flagless")

  test "carve: each spawn point's pocket is protected floor, exactly to its edge":
    let gm = fourTeamMap()
    for p in gm.spawnPoints:
      check mapProtectedFloorAt(gm, p.x, p.y)
      check mapProtectedFloorAt(gm, p.x + SpawnClear, p.y)
      check mapProtectedFloorAt(gm, p.x, p.y + SpawnClear)
      check not mapProtectedFloorAt(gm, p.x + SpawnClear + 1, p.y)
      check not mapProtectedFloorAt(gm, p.x, p.y + SpawnClear + 1)

  test "carve: flagless drops the flag-ring/approach carve entirely":
    ## flagArmed needs a SQUARE board (boardH = W) — see fourTeamSpec's doc
    ## comment; flagOff keeps the rectangular BR field (the case that
    ## actually needs the relaxation).
    let flagArmed = fourTeamMap(flagless = false, boardH = W)
    let flagOff = fourTeamMap(flagless = true)
    ## The map center sits inside the flag ring on a flag-armed map (the
    ## classic-endzone flagRing carve is a center disc) and nowhere near any
    ## authored spawn point on either map.
    check mapProtectedFloorAt(flagArmed, flagArmed.center.x, flagArmed.center.y)
    check not mapProtectedFloorAt(flagOff, flagOff.center.x, flagOff.center.y)

  test "carve: an ordinary (non-flagless) map keeps BOTH carves when spawnPoints is set":
    let gm = fourTeamMap(flagless = false, boardH = W)  # square — see above
    ## Spawn-point pocket still carves...
    check mapProtectedFloorAt(gm, gm.spawnPoints[0].x, gm.spawnPoints[0].y)
    ## ...and the flag ring around the map center still carves too — the two
    ## are independent, not mutually exclusive.
    check mapProtectedFloorAt(gm, gm.center.x, gm.center.y)

  test "validator: spawnPoints.len must be a multiple of teamCount":
    var node = parseJson(fourTeamSpec())
    node["spawnPoints"] = %*[[150, 150], [150, 250], [W - 150, 150]]  # 3, not x4
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validator: a spawn point must be on-board":
    var node = parseJson(fourTeamSpec())
    node["spawnPoints"].elems[0] = %*[-5, 150]
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validator: a spawn pocket must fit fully on the board":
    var node = parseJson(fourTeamSpec())
    node["spawnPoints"].elems[0] = %*[10, 150]  # SpawnClear=40 -> pocket runs
                                                  # to x=-30, off-board
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validator: overlapping spawn pockets are rejected":
    var node = parseJson(fourTeamSpec())
    node["spawnPoints"].elems[1] = node["spawnPoints"].elems[0]  # duplicate
    expect CtfError:
      discard mapFromSpecJson($node)

  test "validator: the reachability (wall-overlap) check is real but tautological here":
    ## Unlike teamPickups.shields/cans (plain pickups with no carve of their
    ## own), a spawn point sits at the CENTER of a pocket that
    ## mapProtectedFloorAt carves BECAUSE of that very point — so the
    ## wall-overlap check validateMapWalkability runs on it can never fail:
    ## an obstacle stamped exactly on top of a spawn point is neutralized by
    ## the carve before the obstacle test ever runs. Prove that directly
    ## (a load that would reject a shield/can in the same spot succeeds here)
    ## rather than asserting a rejection that cannot occur.
    var node = parseJson(fourTeamSpec())
    node["leftObstacles"] = %*[{"kind": "disc", "cx": 150, "cy": 150, "r": 34}]
    let gm = mapFromSpecJson($node)   # does NOT raise
    check gm.spawnPoints[0] == MapPoint(x: 150, y: 150)
    ## The same obstacle placed on a teamPickups.shields point (no self-carve)
    ## DOES raise — the contrast that proves the tautology is real, not a
    ## silently-skipped check.
    var shieldNode = parseJson(fourTeamSpec())
    shieldNode["leftObstacles"] = %*[{"kind": "disc", "cx": 40, "cy": 80, "r": 34}]
    expect CtfError:
      discard mapFromSpecJson($shieldNode)

  test "symNone + teams=4 + spawnPoints validates and boots":
    var config = defaultGameConfig()
    config.teams = 4
    config.mapSpec = fourTeamSpec(spawnPoints = true, flagless = true)
    var sim = initCtfForTest(config)
    for i in 0 ..< 8:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    check sim.phase == Playing
    let inputs = sim.none()
    for tick in 0 ..< 50:
      sim.step(inputs, inputs)
    check sim.gameMap.spawnPoints.len == 8

  test "symNone + teams=4 WITHOUT spawnPoints still rejects":
    let node = parseJson(fourTeamSpec(spawnPoints = false, flagless = false))
    expect CtfError:
      discard mapFromSpecJson($node)

  test "flagless: no flag is ever armed, and no pedestal position is ever computed":
    var config = defaultGameConfig()
    config.teams = 4
    config.mapSpec = fourTeamSpec(spawnPoints = true, flagless = true)
    var sim = initCtfForTest(config)
    for i in 0 ..< 8:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    for team in sim.teams():
      ## carrier=-1 + captured=true is the "no flag active" sentinel every
      ## downstream reader treats as inert; x/y stay at the (0,0) default
      ## because resetFlags never calls teamAnchor/flagHome to compute a
      ## pedestal position at all (that's the whole point: nothing is armed,
      ## not even an inert placeholder sitting on the board).
      check sim.flags[team].carrier == -1
      check sim.flags[team].captured
      check sim.flags[team].x == 0
      check sim.flags[team].y == 0
    ## Standing exactly where a pedestal would otherwise be does not steal
    ## anything — pickup is refused outright, before any range check.
    for i in 0 ..< sim.players.len:
      sim.tryPickupFlags(i)
    for team in sim.teams():
      check sim.flags[team].carrier == -1

  test "full headless episode: 8 spawn points, flagless, bots seated at their points":
    var config = defaultGameConfig()
    config.teams = 4
    config.mapSpec = fourTeamSpec(spawnPoints = true, flagless = true)
    var sim = initCtfForTest(config)
    for i in 0 ..< 8:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    ## Dump initial positions and assert each seat landed exactly on its
    ## spec-authored spawn point (CollisionW/H are both 1, so player.x/y IS
    ## the spawn point with no offset arithmetic to get wrong).
    for i in 0 ..< sim.players.len:
      let (ex, ey) = ExpectedJoinOrderSpawn[i]
      check sim.players[i].x == ex
      check sim.players[i].y == ey
    ## Steps a long stretch of the episode uneventfully: no flag can ever be
    ## captured (proven above), so checkWinCondition's capture branch stays
    ## permanently inert, and only the lives/time-limit path remains live to
    ## end this episode eventually. Run enough ticks to prove nothing crashes
    ## or hangs on the capture path that no longer applies; this does not by
    ## itself run the match to completion (idle bots standing at spawn never
    ## trigger a wipe or the full time limit).
    let inputs = sim.none()
    for tick in 0 ..< 300:
      sim.step(inputs, inputs)
    check sim.phase == Playing        ## still a normal, un-crashed episode.
    check sim.lastCaptureTeam == Red  ## default zero-value: never assigned.
    check sim.lastCaptureTick == -1   ## never set — no capture ever fired.

  test "wire: a flagless episode carries zero flag/pedestal/heart sprites and zero flag/endzone labels":
    ## "they don't need hearts and pedestals. this is not ctf. it is battle
    ## royale." — flagless must not just be gameplay-inert, the WIRE stream
    ## itself must never mention a flag. Sweeps the exact same init-snapshot
    ## surface test_label_contract.nim's collectLabels sweeps (board/
    ## spectator stream + a living player view + a ghost/dead player view),
    ## scanning spkSprite defs — the same mechanism that suite uses to prove
    ## a label IS in the vocabulary, used here to prove a whole family is
    ## NOT. addFlagSprites/addMapMarkers's endzone loop are init-time-only
    ## (never lazy), so one snapshot per stream is the complete surface.
    var sim = fourTeamGame(flagless = true)
    let labels = sim.collectFlagishLabels()
    check labels.len == 0

  test "wire: the SAME map with flags armed still carries the full flag/pedestal/heart vocabulary":
    ## The positive control: proves the flagless gates added above are
    ## correctly scoped to `flagless` and not accidentally starving an
    ## ordinary game too — an existing map's wire footprint is unchanged
    ## ("byte-identical to today"), which is also independently proven by
    ## the full CI suite (test_label_contract.nim's manifest diff never
    ## touches `gameMap.flagless`, since it defaults false and no fixture
    ## there sets it). Square board (boardH = W) — see fourTeamSpec's doc
    ## comment: flags-armed symNone corners/plus needs one.
    var sim = fourTeamGame(flagless = false, boardH = W)
    let labels = sim.collectFlagishLabels()
    check labelFlag("red") in labels
    check labelFlag("blue") in labels
    check labelFlagPlanted("red") in labels
    check labelFlagPlanted("blue") in labels
    check labels.anyIt(it.startsWith(LabelPrefixEndzone))
    check labels.anyIt(" flag carrier glow" in it)
