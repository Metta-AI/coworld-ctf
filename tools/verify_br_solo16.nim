## verify_br_solo16 — the pre-flip gate for PKG-C (16-solo battle-royale-s2).
##
## Builds a REAL sim straight from `coworld_manifest_paintbot.json`'s
## `battle-royale-s2` game_config (the exact config a hosted episode would
## get) and asserts the four properties the PKG-B+C convergence must hold
## before the S2 league is ever flipped onto this variant:
##   1. the arena's own teamCount() agrees with the manifest's `teams: 16`
##      (the engine's own hard-fail, arena.nim:3972 -- if the manifest and
##      the map disagree this never gets past config.update, so this tool
##      surfaces that as a clean, named failure instead of a raw exception);
##   2. the seated roster carries 16 DISTINCT team colors (rosterColorCount);
##   3. the 16 endcard identities (`sim.cogAlias`) are exactly the 16
##      expected "COLOR-alpha" strings, RED-alpha .. PEACH-alpha -- every
##      solo team is its own team's rank-0 member, so IdentityNames[0]
##      ("alpha") is the only identity that can ever appear;
##   4. a full solo-elimination sweep (killing 15 of the 16 one-seat teams,
##      finisher included) mints ZERO `dDuoDown` deeds -- the sim.nim guard
##      this PR adds (a team must seat >= 2 before dDuoDown is even
##      considered) is what keeps a 1-seat team's ONLY kill from wrongly
##      reading as "finished off a duo".
##
## Usage:
##   nim r tools/verify_br_solo16.nim
##   nim r tools/verify_br_solo16.nim --map-path NAME     # override mapPath
##   nim r tools/verify_br_solo16.nim --map-spec FILE     # override with a full mapSpec JSON
##
## The override flags exist so this tool can validate a CANDIDATE pool
## before it is ever wired into the manifest (the PKG-B convergence step):
## point it at the new pool's mapPath/mapSpec directly, confirm PASS, THEN
## replace the manifest's TODO placeholder. Run with no flags, against the
## manifest as shipped, this is the literal post-land gate.
##
## Exit 0 = every gate passes. Exit 1 = a gate failed, or the manifest still
## carries the TODO placeholder (the expected state until PKG-B lands).

import
  std/[algorithm, json, os, sets, strutils],
  ../src/ctf/[sim, arena],
  toolutil

const
  ManifestPath = GameDir / "coworld_manifest_paintbot.json"
  VariantId = "battle-royale-s2"
  ExpectedColors = ["red", "blue", "green", "yellow", "black", "silver",
    "ivory", "pink", "umber", "rust", "orange", "plum", "lime", "navy",
    "azure", "peach"]
  ExpectedTeams = 16

proc findVariantGameConfig(manifest: JsonNode): JsonNode =
  for variant in manifest["variants"]:
    if variant["id"].getStr() == VariantId:
      return variant["game_config"]
  quit(ManifestPath & " has no " & VariantId & " variant", 1)

proc parseArgs(): tuple[mapPath: string, mapSpecFile: string] =
  var i = 1
  while i <= paramCount():
    case paramStr(i)
    of "--map-path":
      inc i
      result.mapPath = paramStr(i)
    of "--map-spec":
      inc i
      result.mapSpecFile = paramStr(i)
    else:
      quit("unknown argument: " & paramStr(i), 1)
    inc i

proc main() =
  chdirGameDir()
  let (mapPathOverride, mapSpecFile) = parseArgs()
  var gc = findVariantGameConfig(parseFile(ManifestPath))

  if mapSpecFile.len > 0:
    gc["mapSpec"] = parseFile(mapSpecFile)
    gc.delete("mapPath")
  elif mapPathOverride.len > 0:
    gc["mapPath"] = %mapPathOverride

  let currentMapPath =
    if gc.hasKey("mapPath"): gc["mapPath"].getStr() else: ""
  if mapSpecFile.len == 0 and mapPathOverride.len == 0 and
      "TODO" in currentMapPath.toUpperAscii():
    echo "GATE: BLOCKED -- manifest mapPath is still a placeholder (\"",
      currentMapPath, "\"). This is the expected state until PKG-B's pool " &
      "lands; re-run with --map-path/--map-spec to dry-run a candidate, " &
      "or wait for the manifest fill-in."
    quit(1)

  var config = defaultGameConfig()
  try:
    config.update($gc)
  except CatchableError as e:
    echo "GATE: FAIL -- config.update raised: ", e.msg
    quit(1)

  var failures: seq[string]

  var sim = initSimServer(config)
  let seats = gc["players"].len
  for i in 0 ..< seats:
    discard sim.addPlayer("Player" & $(i + 1))
  sim.startGame()

  # 1. Arena teamCount agrees with the manifest's teams knob. (If it did
  #    not, config.update above would already have raised -- this is the
  #    positive assertion that we are actually testing the 16-team shape,
  #    not some other one config.update happened to accept.)
  if sim.gameMap.teamCount() != ExpectedTeams:
    failures.add "teamCount() == " & $sim.gameMap.teamCount() &
      ", expected " & $ExpectedTeams
  if config.teams != ExpectedTeams:
    failures.add "config.teams == " & $config.teams & ", expected " &
      $ExpectedTeams

  # 2. rosterColorCount: 16 distinct team colors seated.
  var colors: HashSet[string]
  for player in sim.players:
    colors.incl teamText(player.team)
  if colors.len != ExpectedTeams:
    failures.add "rosterColorCount() == " & $colors.len & ", expected " &
      $ExpectedTeams
  for color in ExpectedColors:
    if color notin colors:
      failures.add "missing expected team color: " & color

  # 3. Endcard identities: exactly 16 unique "COLOR-alpha" strings. A solo
  #    team's one seat is always identity rank 0 (alpha) -- beta/gamma/...
  #    can never appear on a 1-seat team, so this also indirectly proves
  #    every team seats exactly one player.
  var identities: seq[string]
  for i in 0 ..< sim.players.len:
    identities.add sim.cogAlias(i)
  var expectedIdentities: seq[string]
  for color in ExpectedColors:
    expectedIdentities.add color.toUpperAscii() & "-alpha"
  var sortedIdentities = identities
  var sortedExpected = expectedIdentities
  sort(sortedIdentities)
  sort(sortedExpected)
  if sortedIdentities != sortedExpected:
    failures.add "endcard identities mismatch:\n  got:      " &
      $sortedIdentities & "\n  expected: " & $sortedExpected
  if toHashSet(identities).len != seats:
    failures.add "endcard identities are not all unique: " & $identities

  # 4. Zero dDuoDown mints across a full solo-elimination sweep. downedMode
  #    is armed on this variant, so killPlayer's first hit on an upright
  #    cog DOWNS it and a second completes the kill (same two-call pattern
  #    test_pb_br_variant.nim's own wipe test uses) -- but with only ONE
  #    seat per team, there is never a still-alive partner to distinguish
  #    an ordinary elimination from "finished off the last of a duo", which
  #    is exactly the shape the sim.nim guard exists to protect.
  for i in 1 ..< seats:
    sim.killPlayer(i, 0)
    sim.killPlayer(i, 0)
  if sim.deedCounts[dDuoDown] != 0:
    failures.add "deedCounts[dDuoDown] == " & $sim.deedCounts[dDuoDown] &
      " after a full solo-elimination sweep, expected 0"

  sim.checkWinCondition()
  if sim.phase != GameOver:
    failures.add "sim.phase == " & $sim.phase & " after wiping 15/16 solo teams, expected GameOver"
  elif sim.winner != sim.players[0].team:
    failures.add "sim.winner == " & teamText(sim.winner) &
      ", expected the lone survivor " & teamText(sim.players[0].team)

  echo "── PKG-C 16-solo BR pre-flip gate ──"
  echo "  mapPath:  ", currentMapPath
  echo "  teams:    ", config.teams
  echo "  seats:    ", seats
  echo "  identities: ", sortedIdentities
  if failures.len == 0:
    echo "GATE: PASS -- all four properties hold."
  else:
    echo "GATE: FAIL (", failures.len, " issue(s)):"
    for f in failures:
      echo "  - ", f
    quit(1)

main()
