## LOOT PLACEMENT PROBE — the structural half of the hopper site-class
## acceptance criterion (spec: 2026-09-03 hopper-siteclass, amended).
##
## The acceptance criterion itself is a FIELD ratio: hopper per-crate pickup
## over marker per-crate pickup, both measured in the SAME post-fix rounds
## (pre-fix 8.4% / 17.7% = 0.47). That ratio cannot be measured locally --
## it needs live episodes. What CAN be measured locally, and is what this
## probe reports, is the two structural terms that ratio is made of:
##
##   1. DEAD SUPPLY — crates minus DISTINCT pixels. A crate stacked on
##      another crate of its own family is never a second pickup
##      (pickupByTouch takes the first present spawn in range and returns,
##      and the taker's own carry gate then walks it over the twin), so it
##      is pure denominator: it drags per-crate pickup down for free. The
##      hopper fallback used to concatenate medKitSpawns and
##      medKitCandidates -- the SAME points on every live map -- so a large
##      share of every hopper site carried an uncollectable twin while the
##      marker fallback (one list, sim.grenadeSpawns) carried none. That
##      asymmetry alone accounts for most of the measured 0.47.
##   2. SITE CLASS — how many fallback hoppers sit OFF the retreat class
##      (the med-kit points) once hopperSiteTrafficPermille re-sites them
##      onto the traffic class the markers already use.
##
## Run it against the live variant's own game_config over many seeds (each
## seed draws a different certified map from the S2 pool), so the numbers
## are the ones the ladder actually plays:
##   nim c -d:release --path:src -o:/tmp/loot_placement_probe \
##     tools/loot_placement_probe.nim && /tmp/loot_placement_probe
import std/[json, strformat]
import ctf/[sim, sim_types, sim_config]

const
  VariantId = "battle-royale-s2"
  ManifestPath = "coworld_manifest_paintbot.json"
  Seeds = 24

proc distinctPixels(spawns: seq[PickupSpawn]): int =
  var seen: seq[tuple[x, y: int]]
  for spawn in spawns:
    if (spawn.x, spawn.y) notin seen:
      seen.add (spawn.x, spawn.y)
  seen.len

proc sharedPixels(a, b: seq[PickupSpawn]): int =
  var bs: seq[tuple[x, y: int]]
  for spawn in b:
    bs.add (spawn.x, spawn.y)
  for spawn in a:
    if (spawn.x, spawn.y) in bs:
      inc result

proc run(gameConfig: JsonNode, seed, permille: int): SimServer =
  var overrides = gameConfig.copy()
  overrides["seed"] = %seed
  overrides["hopperSiteTrafficPermille"] = %permille
  var config = defaultGameConfig()
  config.update($overrides)
  result = initSimServer(config)
  for i in 0 ..< config.num_agents:
    discard result.addPlayer("Player" & $(i + 1))
  result.startGame()

proc main() =
  let manifest = parseJson(readFile(ManifestPath))
  var gameConfig: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr() == VariantId:
      gameConfig = variant["game_config"]
  doAssert gameConfig != nil, ManifestPath & " has no " & VariantId
  let armedPermille = gameConfig{"hopperSiteTrafficPermille"}.getInt
  var
    gunCrates, gunSites, hopCrates, hopSites: int
    darkHopCrates, darkHopSites: int
    offRetreat, hopOnGun, darkHopOnGun, bandages, bandageSites: int
  for t in 0 ..< Seeds:
    let seed = 1000 + t * 104729
    var armed = run(gameConfig, seed, armedPermille)
    var dark = run(gameConfig, seed, 0)
    var kitPixels: seq[tuple[x, y: int]]
    for point in armed.gameMap.medKitSpawns & armed.gameMap.medKitCandidates:
      let spot = armed.nearestWalkable(point.x, point.y)
      if spot notin kitPixels:
        kitPixels.add spot
    for spawn in armed.hopperSpawns:
      if (spawn.x, spawn.y) notin kitPixels:
        inc offRetreat
    gunCrates += armed.weaponSpawns.len
    gunSites += distinctPixels(armed.weaponSpawns)
    hopCrates += armed.hopperSpawns.len
    hopSites += distinctPixels(armed.hopperSpawns)
    darkHopCrates += dark.hopperSpawns.len
    darkHopSites += distinctPixels(dark.hopperSpawns)
    hopOnGun += sharedPixels(armed.hopperSpawns, armed.weaponSpawns)
    darkHopOnGun += sharedPixels(dark.hopperSpawns, dark.weaponSpawns)
    bandages += armed.bandageSpawns.len
    bandageSites += distinctPixels(armed.bandageSpawns)
    doAssert armed.weaponSpawns.len <= NeutralPickupPoolWidth
    doAssert armed.hopperSpawns.len <= NeutralPickupPoolWidth
    doAssert armed.bandageSpawns.len <= NeutralPickupPoolWidth
    doAssert armed.medKitSpawns.len <= NeutralPickupPoolWidth
    doAssert armed.sprayPaintSpawns.len <= NeutralPickupPoolWidth
  echo &"{VariantId}, {Seeds} seeds, hopperSiteTrafficPermille={armedPermille}"
  echo &"  marker crates {gunCrates} over {gunSites} distinct pixels"
  echo &"  hopper crates {hopCrates} over {hopSites} distinct pixels"
  echo &"  hopper crates at permille 0: {darkHopCrates} over {darkHopSites}" &
    " distinct pixels (same COUNT: the site class moves crates, never adds)"
  echo &"  hoppers off the retreat class: {offRetreat}/{hopCrates}"
  echo &"  hopper/marker pixel collisions: {hopOnGun} (permille 0: {darkHopOnGun})"
  echo &"  bandage crates {bandages} over {bandageSites} distinct pixels"

main()
