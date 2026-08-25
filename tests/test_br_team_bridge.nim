## The BR team-count bridge: `spawnGroups`.
##
## `CtfMap.teamCount()` used to derive from `TeamLayout`, which only knows 2
## (sides) and 4 (corners/plus). A battle-royale map is symNone full-board
## with 16 spawn groups and no sides at all, so a 16-team config could not
## boot: resolveCtfMapMetadata rejected every draw with "map seats 2 teams"
## no matter how many spawn points it authored.
##
## The bridge is one authored field on the map, `spawnGroups`, which
## overrides teamCount when set. These tests pin the three properties that
## make it safe to put a number that load-bearing on the map:
##
##   1. a 16-team config on a 16-group map boots, and every count-derived
##      consumer (roster round-robin, seat placement, active-team slice)
##      agrees with it;
##   2. every way of DISAGREEING is rejected, with an error that says what
##      is wrong rather than a downstream doAssert crash;
##   3. maps that do not author it are completely unaffected — the pre-BR
##      world, byte-identical, including their spec echo.

import
  helpers,
  std/[json, sequtils, strutils, unittest],
  ctf/[arena, global, sim, sim_config, sim_types]

const
  W = 1235
  H = 659
  SpawnClear = 40
  Groups = 16
  SeatsPerGroup = 2

proc gridSpawnPointsNode(count = Groups): JsonNode =
  ## `count` points on a 4x4 jittered-free grid across the whole board
  ## (BR_MAPGEN.md §4.2's shape, without the jitter — a test wants fixed
  ## coordinates). Team-major flattening: with 16 groups and 16 points,
  ## point i IS group i's single landing spot.
  ##
  ## Spacing is checked by hand against SpawnClear: columns are 308px apart
  ## and rows 165px, both comfortably over the 80px two-pocket minimum, and
  ## the outermost pockets clear every board edge.
  result = newJArray()
  for i in 0 ..< count:
    let
      col = i mod 4
      row = i div 4
    result.add %*[154 + 308 * col, 82 + 165 * row]

proc brSpec(
  spawnGroups = Groups,
  spawnPoints = Groups,
  flagless = true,
  pinGroups = true
): string =
  ## A minimal BR-shaped map spec: symNone, sides layout (a BR board has no
  ## sides — the layout is simply the default), flagless, no per-team
  ## pickups, N spawn points.
  var node = %*{
    "name": "br-bridge-demo",
    "width": W, "height": H,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": SpawnClear, "spawnClearH": SpawnClear,
    "gunRange": 331,
    "symmetry": "none",
    "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "medKitSpawns": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "medKitCandidates": [[W div 2, H div 3], [W div 2, 2 * H div 3]],
    "leftObstacles": newJArray(),
  }
  node["spawnPoints"] = gridSpawnPointsNode(spawnPoints)
  if flagless:
    node["flagless"] = %true
  if pinGroups:
    node["spawnGroups"] = %spawnGroups
  $node

proc brGame(seats = Groups * SeatsPerGroup): SimServer =
  ## A started BR game: 16 groups x 2 seats = 32 players.
  var config = defaultGameConfig()
  config.teams = Groups
  config.mapSpec = brSpec()
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  ## Process-global board/endzone bakes are keyed on byte size alone, so a
  ## same-sized map from a sibling test would otherwise be served to this
  ## sim. Production does the same on a replay hot-switch.
  invalidateBoardMapCaches()

proc errorFor(spec: string, teams: int): string =
  ## The CtfError message a config/map pair produces, or "" if it loads.
  var config = defaultGameConfig()
  config.teams = teams
  config.mapSpec = spec
  try:
    discard resolveCtfMapMetadata(config)
    ""
  except CtfError as e:
    e.msg

suite "BR team-count bridge (spawnGroups)":

  test "a 16-team config on a 16-group map boots":
    var config = defaultGameConfig()
    config.teams = Groups
    config.mapSpec = brSpec()
    let gameMap = resolveCtfMapMetadata(config)
    check gameMap.teamCount() == Groups
    check gameMap.spawnGroups == Groups
    check gameMap.spawnPoints.len == Groups
    ## The active-team slice is the whole enum, not a 2- or 4-team prefix.
    check gameMap.teams() == Red .. Peach
    check toSeq(gameMap.teams()).len == Groups

  test "the roster round-robin and seat placement read the SAME source":
    ## This is the actual point of the bridge: teamCount is one number and
    ## everything downstream follows it. teamForSlot deals
    ## Team(order mod teamCount), and spawnPosition indexes
    ## spawnPoints[ord(team) * perTeam + order mod perTeam] with
    ## perTeam = spawnPoints.len div teamCount. If those two disagreed about
    ## the count, seats would land on other groups' points.
    var sim = brGame()
    check sim.players.len == Groups * SeatsPerGroup
    var seen: seq[Team]
    for i, player in sim.players:
      ## Round-robin over all 16, so join order 0..31 deals every team twice.
      check player.team == Team(i mod Groups)
      if player.team notin seen:
        seen.add player.team
    check seen.len == Groups        ## all 16 identities actually fielded.

    ## Seats per group is 1 (16 points / 16 groups), so BOTH members of a duo
    ## land on their group's single point — the duo pocket of BR_MAPGEN.md
    ## §4.2, which is sized for two bodies.
    let
      points = gridSpawnPointsNode()
      offset = sim.spawnGroupOffset()
    for i, player in sim.players:
      ## Team k seats on group (k + offset) mod 16 — the per-episode
      ## rotation, so no team owns a grid cell across episodes.
      let expected = points[(i + offset) mod Groups]
      check player.x == expected[0].getInt()
      check player.y == expected[1].getInt()

  test "a count MISMATCH is rejected, naming both counts":
    let msg = errorFor(brSpec(), teams = 4)
    check "16" in msg
    check "4" in msg
    check "seats" in msg

  test "spawnPoints without spawnGroups fails with an ACTIONABLE message":
    ## The confusing case: the map has 16 landing spots but never declared
    ## how they group, so teamCount silently falls back to the layout's 2.
    ## The error has to say that, or the next person re-derives the whole
    ## bridge from a message that reads like the map is simply too small.
    let msg = errorFor(brSpec(pinGroups = false), teams = Groups)
    check "spawnGroups" in msg
    check "16 spawnPoints" in msg

  test "an indivisible spawnPoints/spawnGroups pair is rejected":
    ## 20 points over 16 groups would seat four groups twice and twelve once.
    let msg = errorFor(
      brSpec(spawnGroups = Groups, spawnPoints = 20), teams = Groups)
    check "divide evenly" in msg

  test "an out-of-range spawnGroups is a map error, not a crash":
    ## activeTeams doAsserts on a count outside [2, 4, 16]; a doAssert is a
    ## crash, and a bad map should never be able to cause one.
    let msg = errorFor(brSpec(spawnGroups = 5, spawnPoints = 20), teams = 5)
    check "spawnGroups must be 2, 4 or 16" in msg

  test "spawnGroups without any spawnPoints is rejected":
    var node = parseJson(brSpec())
    node.delete("spawnPoints")
    let msg = errorFor($node, teams = Groups)
    check "authors no spawnPoints" in msg

  test "2- and 4-team maps are untouched, spec echo included":
    ## The whole pre-BR world: teamCount still comes from the layout, and a
    ## map that never authors spawnGroups never mentions it in its spec —
    ## so every pinned spec ever recorded round-trips byte-identically.
    var classicConfig = defaultGameConfig()
    classicConfig.teams = 2
    let classic = resolveCtfMapMetadata(classicConfig)
    check classic.spawnGroups == 0
    check classic.teamCount() == 2
    check "spawnGroups" notin classic.mapSpecJson()

    ## Same for a map that authors spawnPoints but no groups: it keeps the
    ## layout's count, which is what every pre-bridge spawnPoints map did.
    let unpinned = mapFromSpecJson(brSpec(pinGroups = false))
    check unpinned.spawnGroups == 0
    check unpinned.teamCount() == 2
    check "spawnGroups" notin unpinned.mapSpecJson()

  test "spawnGroups round-trips through the spec exactly":
    let once = mapFromSpecJson(brSpec()).mapSpecJson()
    let twice = mapFromSpecJson(once).mapSpecJson()
    check once == twice
    check mapFromSpecJson(once).spawnGroups == Groups
    check "\"spawnGroups\":16" in once.replace(" ", "")

  test "the spawn assignment ROTATES per episode, and is fixed per seed":
    ## A fixed team -> spawn-group binding would hand one team the same grid
    ## cell in every episode ever played on the map, so any advantage that
    ## cell carries becomes a permanent team advantage and per-spawn
    ## fairness stops being measurable separately from team skill.
    ##
    ## Determinism is the other half: the offset is a pure function of the
    ## seed, so a replay of one seed seats exactly as its recording did.
    proc offsetForSeed(seed: int): int =
      var config = defaultGameConfig()
      config.teams = Groups
      config.seed = seed
      config.mapSpec = brSpec()
      var sim = initCtfForTest(config)
      discard sim.addPlayer("p0")
      sim.startGame()
      result = sim.spawnGroupOffset()
      invalidateBoardMapCaches()

    ## Same seed, twice: identical.
    check offsetForSeed(4201) == offsetForSeed(4201)
    ## Across a spread of seeds the assignment actually moves — if every
    ## seed produced the same offset the rotation would be decorative.
    var seen: seq[int] = @[]
    for seed in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]:
      let o = offsetForSeed(seed)
      check o >= 0
      check o < Groups
      if o notin seen:
        seen.add o
    check seen.len > 1
