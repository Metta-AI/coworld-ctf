## Converts a `brmapkit` draw into a CtfMap `mapSpec` the engine can boot.
##
## brmapkit is a FORK, not a patch (BR_MAPGEN.md §1): it authors full-board
## asymmetric BR maps and emits its OWN JSON grammar, tagged `"mode": "br"`,
## carrying concepts the CTF spec has no field for (POIs, keystone family,
## loot tiers, group/seat counts, the zone's final z). `mapFromSpecJson`
## cannot read it — the two grammars agree on geometry and disagree on
## everything else — so a BR draw could be generated and rendered but never
## PLAYED. This is the weld between them.
##
## The conversion is deliberately dumb and total. Geometry transfers
## verbatim, because both grammars spell obstacles the same way (rect /
## disc / diagonal / polygon with identical key names — the fork inherited
## them). Everything else is either a fixed CTF-side constant that a
## flagless map never reads, or a field this tool must DECIDE. The decisions
## are listed at each site.
##
## Self-verifying: the output is loaded back through `mapFromSpecJson`
## before it is written, so this tool cannot emit a spec the engine would
## reject. A converter that emits an unloadable map is worse than no
## converter, because the failure surfaces later, inside a match recipe.
##
## Usage:
##   nim c -d:release -o:/tmp/br2ctf tools/br_spec_to_ctf.nim
##   /tmp/br2ctf <draw.json> [-o out.json]

import
  std/[json, os, strformat, strutils],
  ../src/ctf/[arena, sim_types]

const
  ## A flagless map never places a pedestal, never carves a flag ring and
  ## never scores an endzone (CtfMap.flagless gates every one of those code
  ## paths), but the spec grammar still requires the keys. These are the
  ## stock arena values, present so the spec parses and inert by
  ## construction — NOT tuning.
  InertFlagRing = 70
  InertCaptureClear = 210

proc convert(br: JsonNode): JsonNode =
  ## The BR draw as a CtfMap spec node.
  if br{"mode"}.getStr("") != "br":
    raise newException(ValueError,
      "not a brmapkit draw: expected \"mode\": \"br\", got " &
      br{"mode"}.getStr("<absent>"))

  let
    groups = br{"groups"}.getInt(0)
    spawnPoints = br{"spawnPoints"}
  if groups <= 0:
    raise newException(ValueError, "draw declares no group count")
  if spawnPoints.isNil or spawnPoints.kind != JArray:
    raise newException(ValueError, "draw authors no spawnPoints")

  result = %*{
    "name": br{"name"}.getStr("br-map"),
    "genSeed": br{"genSeed"}.getInt(0),
    "width": br["width"].getInt(),
    "height": br["height"].getInt(),
    # Inert on a flagless map — see the consts above.
    "flagRing": InertFlagRing,
    "captureClear": InertCaptureClear,
    # The duo pocket (§4.2): the tiny floor two bodies occupy, NOT a
    # placement exclusion zone. Carried across as authored.
    "spawnClearW": br{"spawnClearW"}.getInt(70),
    "spawnClearH": br{"spawnClearH"}.getInt(70),
    # DERIVED by the generator from the field and the group count
    # (§4.1: G = sqrt(W*H/(N*pi))), never picked here. Carrying it is the
    # whole reason the mode has a landing phase.
    "gunRange": br["gunRange"].getInt(),
    # A BR map carries no symmetry group at all (§2.5): fairness is a
    # MEASURED per-spawn floor, not a geometric guarantee.
    "symmetry": "none",
    # The layout is vestigial here. A BR board has no sides, no corners and
    # no plus; "sides" is simply the default arm, and `spawnGroups` below
    # is what teamCount() actually reads, so the layout never gets a vote.
    "layout": "sides",
    # No endzone geometry exists on a flagless map.
    "endzone": "column",
    "endzoneRadius": 0,
    "homeDepth": 0,
    "medKitSpawns": br{"medKitSpawns"},
    "medKitCandidates": br{"medKitCandidates"},
    # Verbatim: identical shape grammar on both sides.
    "leftObstacles": br{"leftObstacles"},
    # brmapkit draws no trenches (they are a 2-team lever; BR_MAPGEN.md
    # keeps trenches off 4-team boards already).
    "trenches": newJArray(),
    "spawnPoints": spawnPoints,
    # THE BRIDGE. Without this the map would report its LAYOUT's team count
    # (2) and a 16-team config would be rejected outright.
    "spawnGroups": groups,
    "flagless": true,
  }
  if result["medKitSpawns"].isNil or result["medKitSpawns"].kind != JArray:
    result["medKitSpawns"] = newJArray()
  if result["medKitCandidates"].isNil or
      result["medKitCandidates"].kind != JArray:
    result["medKitCandidates"] = newJArray()
  # shieldSpawns/spraySpawns (brmapkit round 13, §4.9): mapFromSpecJson
  # treats an ABSENT key as "no pool, fall back to the classic per-team
  # endzone formula" (arena.nim's pointsFromNode(node{"shieldSpawns"})), so
  # unlike medKitSpawns/medKitCandidates above this is only added when the
  # draw actually authored a non-empty pool — an empty key and an absent
  # key mean the same thing to the loader, so there is nothing to gain by
  # forcing the key to exist. grenadeSpawns is NOT forwarded: the engine
  # side (CtfMap.grenadeSpawns / sim.nim's resetGrenades) is still a fixed
  # array[4, PickupSpawn], not the seq[MapPoint] neutral-pool shape
  # shieldSpawns/spraySpawns/medKitSpawns share, so there is no ingest path
  # for a drawn grenade pool yet — that is a real engine change (the array
  # is sized 4 everywhere it's touched, including the wire/replay format),
  # not a bridge-tool one, and out of scope here. Grenades still place via
  # grenadeSpawnPoints()'s 4-corner formula on a BR map, same as before
  # this round.
  let shieldSpawns = br{"shieldSpawns"}
  if not shieldSpawns.isNil and shieldSpawns.kind == JArray and
      shieldSpawns.len > 0:
    result["shieldSpawns"] = shieldSpawns
  let spraySpawns = br{"spraySpawns"}
  if not spraySpawns.isNil and spraySpawns.kind == JArray and
      spraySpawns.len > 0:
    result["spraySpawns"] = spraySpawns

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    quit("usage: br_spec_to_ctf <draw.json> [-o out.json]", 1)
  var
    inPath = ""
    outPath = ""
    i = 0
  while i < args.len:
    case args[i]
    of "-o", "--out":
      inc i
      if i >= args.len: quit("-o needs a path", 1)
      outPath = args[i]
    else:
      if inPath.len == 0: inPath = args[i]
    inc i

  let br = parseJson(readFile(inPath))
  let spec = convert(br)
  let text = $spec

  ## Self-check: boot the result through the real loader (which runs
  ## validateMap + validateMapWalkability internally) before writing it.
  let gameMap = mapFromSpecJson(text)
  echo &"loaded: {gameMap.name}  {gameMap.width}x{gameMap.height}  " &
    &"gunRange={gameMap.gunRange}  spawnPoints={gameMap.spawnPoints.len}  " &
    &"spawnGroups={gameMap.spawnGroups}  teamCount={gameMap.teamCount()}  " &
    &"flagless={gameMap.flagless}  obstacles={gameMap.leftObstacles.len}  " &
    &"medkits={gameMap.medKitSpawns.len}  shields={gameMap.shieldSpawns.len}  " &
    &"sprays={gameMap.spraySpawns.len}  (grenades: still the 4-corner " &
    &"formula, not drawn — see the shieldSpawns/spraySpawns comment above)"
  if br{"keystone"}.getStr("").len > 0:
    echo "keystone: ", br["keystone"].getStr()

  if outPath.len > 0:
    writeFile(outPath, text)
    echo "wrote ", outPath, " (", text.len, " bytes)"
  else:
    echo text
