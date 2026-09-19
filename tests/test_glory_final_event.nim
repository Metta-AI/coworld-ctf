## GLORY FINAL — the Observatory Logs "Glory" tab substrate.
##
## Three facts the tier-2 stream was missing before this suite's own PR
## (see that PR's description for the full field list):
##   * the WIN FACTOR applied at game over (previously log-line only —
##     "win factor xN", sim.nim `finishGame`);
##   * the FINAL glory product per team, pre-cap and capped, plus whether
##     the cap bound (previously only `sim.gloryProduct`, an in-process
##     field never on the wire);
##   * the per-deed heat multiplier / ally-stack tier (previously only
##     reachable behind the `gloryS6AttrInstrument` compile-time define).
##
## This suite drives a short, real BR episode (a minimal 4-group solo map,
## same self-contained-JSON-spec idiom `test_glory_recut.nim`'s
## `br16Spec`/`br16SoloGame` use, just fewer groups) with `collectEvents`
## on, mints two real `dLongshotKill` deeds directly through `awardDeed`
## (a real production proc, called the same way `test_glory_s4b_modes.nim`
## drives `awardDeed`/`claimAchievement` directly), then calls `finishGame`
## and reads the drained `sim.events` back — exactly what the Observatory
## extractor does, just in-process instead of over a replay file.

import
  helpers,
  std/[json, strutils, unittest],
  ctf/[global, sim, events]

const
  FinalEventGroups = 4
  FinalEventW = 800
  FinalEventH = 500

proc finalEventSpawnPoints(count = FinalEventGroups): JsonNode =
  result = newJArray()
  for i in 0 ..< count:
    result.add %*[120 + 160 * i, 120 + 80 * i]

proc finalEventMapSpec(): string =
  ## A minimal solo-BR-shaped map spec (symNone, flagless, all four neutral
  ## item pools authored so validateMap accepts it) — the same minimal
  ## shape `test_glory_recut.nim`'s `br16Spec` uses, sized down to
  ## `FinalEventGroups` teams so this suite stays short.
  var node = %*{
    "name": "glory-final-event-test-map",
    "width": FinalEventW, "height": FinalEventH,
    "flagRing": 70, "captureClear": 210,
    "spawnClearW": 40, "spawnClearH": 40,
    "gunRange": 331,
    "symmetry": "none",
    "layout": "sides",
    "endzone": "column", "endzoneRadius": 0, "homeDepth": 0,
    "medKitSpawns": [[FinalEventW div 2, FinalEventH div 3],
                     [FinalEventW div 2, 2 * FinalEventH div 3]],
    "medKitCandidates": [[FinalEventW div 2, FinalEventH div 3],
                         [FinalEventW div 2, 2 * FinalEventH div 3]],
    "leftObstacles": newJArray(),
    "flagless": true,
  }
  node["spawnPoints"] = finalEventSpawnPoints()
  node["shieldSpawns"] = finalEventSpawnPoints()
  node["spraySpawns"] = finalEventSpawnPoints()
  node["grenadeSpawns"] = finalEventSpawnPoints()
  node["spawnGroups"] = %FinalEventGroups
  $node

proc briefBrGame(): SimServer =
  ## A started FinalEventGroups-team SOLO BR game (one seat per team), the
  ## full GV57 economy armed (recut + winAsMultiplier) — the shape
  ## `recutWinFactor(true, 1)` (`RecutWinFactorBRSolo` = ×8) prices.
  var config = defaultGameConfig()
  config.teams = FinalEventGroups
  config.mapSpec = finalEventMapSpec()
  config.brMode = true
  config.gloryMultiplierRecut = true
  config.winAsMultiplier = true
  result = initCtfForTest(config)
  for i in 0 ..< FinalEventGroups:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true
  invalidateBoardMapCaches()

suite "GloryFinal tier-2 event (Observatory Logs 'Glory' tab substrate)":

  test "one glory_final event per team at game over; the winner carries the real win factor and product":
    var sim = briefBrGame()
    let winner = sim.players[0].team
    sim.finishGame(winner)
    check sim.phase == GameOver

    var finalEvents: seq[SimEvent]
    for event in sim.events:
      if event.kind == GloryFinal:
        finalEvents.add event
    check finalEvents.len == FinalEventGroups   # one row per seated team

    var sawWinner = false
    for row in finalEvents:
      check row.target >= 0
      if row.target == sim.eventSlot(ord(winner)):
        sawWinner = true
        # solo team (1 seat): RecutWinFactorBRSolo = x8 (recutWinFactor).
        check row.winFactor == recutWinFactor(true, 1)
        check row.winFactor == 8
        check row.productPreCap.len > 0
        check row.productCapped.len > 0
        # The win-factor fold is a x8 multiply on the seeded product (no
        # deed mints happened first in this short episode) and nowhere
        # near RecutProductCapArmed (2^31) or RecutProductCap (2^62), so
        # this fold could not have saturated.
        check row.capBound == false
        check parseBiggestInt(row.productCapped) ==
          parseBiggestInt(row.productPreCap) * 8
      else:
        # every non-winner reads the "no finalize fold" defaults.
        check row.winFactor == 1
        check row.capBound == false
        check row.productPreCap == row.productCapped
      check row.ffHalvings == 0   # no dTeamKill incidents in this episode

    check sawWinner

    # The JSONL row this event serializes to — the exact shape the
    # Observatory extractor reads (ctf/events `jsonRow`).
    var sample: JsonNode
    for row in finalEvents:
      if row.target == sim.eventSlot(ord(winner)):
        sample = row.jsonRow()
    check sample != nil
    check sample["kind"].getStr == "glory_final"
    check sample["win_factor"].getInt == 8
    check sample["product_capped"].kind == JString

  test "GloryDeed events carry the new heatMult/stackTier fields at mint time":
    var sim = briefBrGame()
    let winner = sim.players[0].team
    let x = sim.players[0].x
    let y = sim.players[0].y
    # dLongshotKill pays heat (DeedDramaTable > 0); mint it twice with a
    # real ally-stack context (stackK = 3) so both fields carry a real,
    # non-neutral value rather than their 1/1 defaults.
    sim.awardDeed(winner, dLongshotKill, x, y, byIndex = 0, stackK = 3)
    let embersAfterFirst = sim.heatEmbers[winner]
    sim.awardDeed(winner, dLongshotKill, x, y, byIndex = 0, stackK = 3)
    let embersAfterSecond = sim.heatEmbers[winner]
    check embersAfterSecond > embersAfterFirst   # heat is really climbing

    var deedEvents: seq[SimEvent]
    for event in sim.events:
      if event.kind == GloryDeed and event.weapon == "dLongshotKill":
        deedEvents.add event
    check deedEvents.len == 2

    # Same read timing as the mint's own heat-embers increment (a few
    # lines above the emit in awardDeed): the reported heatMult is
    # `heatMult` evaluated against the POST-increment ember count.
    check deedEvents[0].heatMult == heatMult(embersAfterFirst)
    check deedEvents[1].heatMult == heatMult(embersAfterSecond)
    for row in deedEvents:
      check row.stackTier == recutStackMult(3)
      check row.stackTier == 3   # RecutStackLadder[2]

    let sample = deedEvents[0].jsonRow()
    check sample["kind"].getStr == "glory_deed"
    check sample["heat_mult"].getInt == deedEvents[0].heatMult
    check sample["stack_tier"].getInt == 3

  test "dark economy (gloryMultiplierRecut off): stackTier stays neutral, no glory_final win factor":
    var config = defaultGameConfig()
    config.teams = FinalEventGroups
    config.mapSpec = finalEventMapSpec()
    config.brMode = true
    # gloryMultiplierRecut / winAsMultiplier both default false: the dark
    # v12 additive ledger, byte-identical path.
    var sim = initCtfForTest(config)
    for i in 0 ..< FinalEventGroups:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    sim.collectEvents = true
    invalidateBoardMapCaches()
    let winner = sim.players[0].team
    sim.awardDeed(winner, dLongshotKill, sim.players[0].x, sim.players[0].y,
                 byIndex = 0)   # stackK defaults to 1, the dark-path shape
    sim.finishGame(winner)

    for event in sim.events:
      if event.kind == GloryDeed and event.weapon == "dLongshotKill":
        check event.stackTier == 1
      elif event.kind == GloryFinal:
        check event.winFactor == 1
        check event.capBound == false
        check event.productPreCap == event.productCapped
