## The Season 2 rotating BR map pool (br_map_pool.nim's s2 section,
## data/br_s2_map_pool.json) and its per-episode selection hook
## (sim_config.update's "brpool" branch). What this suite pins:
##   - every ledger entry is certified (gates.all — the full brmapkit
##     validateBr allPass — recorded true at generation time) and its
##     embedded spec loads through arena.mapFromSpecJson as the exact
##     8-duo shape the battle-royale-s2 variant seats (spawnGroups 8,
##     teamCount 8, half-area 2271x1212 field, derived gunRange 331);
##   - selection is DETERMINISTIC per episode seed (same seed, same map;
##     brPoolIndex is pure integer math) and COVERS the whole pool across
##     episode seeds (no unreachable member, no hot slot);
##   - different episode seeds land different maps (the freshness the pool
##     exists to provide — the pinned-single-map variant had none);
##   - a config that already CARRIES a mapSpec never consults the pool,
##     even with mapPath="brpool" and a seed that would select some other
##     member. That precedence is the exact mechanism that keeps a
##     recorded episode's replay valid FOREVER: playback re-parses the
##     replay's own config (mapSpec embedded at record time), so a map
##     that later rotates OUT of the pool keeps replaying byte-identically.
## The gate re-run itself happened at generation time, out of band
## (tools/rotate_br_pool.sh re-asserts it for every rotation candidate);
## like test_br_map_pool, this suite pins the STORED shape and the
## selection contract, not the generator.

import
  helpers,
  std/[json, os, sets, strutils, unittest],
  ctf/[br_map_pool, sim, sim_config]

const
  PoolPath = GameDir / "data" / "br_s2_map_pool.json"
  ManifestPath = GameDir / "coworld_manifest_paintbot.json"
  VariantId = "battle-royale-s2"
  ExpectedWidth = 2271
  ExpectedHeight = 1212
  ExpectedGunRange = 331
  ExpectedGroups = 8

proc variantGameConfig(): JsonNode =
  let manifest = parseJson(readFile(ManifestPath))
  for variant in manifest["variants"]:
    if variant["id"].getStr() == VariantId:
      return variant["game_config"]
  doAssert false, ManifestPath & " has no " & VariantId & " variant"

suite "br s2 map pool: the certified ledger":
  let pool = loadBrS2PoolRaw(PoolPath)

  test "64 entries, every one 18/18 certified, names unique and seed-consistent":
    check pool.len == 64
    var names: HashSet[string]
    for entry in pool:
      let name = entry["name"].getStr()
      check name == "br-gen-" & $entry["seed"].getInt()
      check entry["certifiedAt"].getStr().len > 0
      ## The recorded gate ledger: the folded allPass verdict plus every
      ## named gate validateBr FOLDS INTO allPass. interiorConnectivity is
      ## recorded for the ledger but deliberately NOT asserted true: brmapkit
      ## dropped it from the allPass gate by doctrine (superseded by the
      ## fullAccess zero-unreachable-cells check), and br-gen-8024 itself was
      ## certified on exactly this allPass standard (#354). A rotation that
      ## tried to ship a non-certified candidate would have to falsify this
      ## record to get past CI.
      check entry["gates"]["all"].getBool() == true
      for gate, verdict in entry["gates"]:
        if gate != "interiorConnectivity":
          check verdict.getBool() == true
      check entry["gates"].len >= 18
      names.incl name
    check names.card == pool.len

  test "every entry's spec loads as the real 8-duo battle-royale shape":
    for entry in pool:
      let gameMap = mapFromSpecJson($entry["spec"])
      check gameMap.name == entry["name"].getStr()
      check gameMap.width == ExpectedWidth
      check gameMap.height == ExpectedHeight
      check gameMap.gunRange == ExpectedGunRange
      check gameMap.spawnGroups == ExpectedGroups
      check gameMap.spawnPoints.len == ExpectedGroups
      check gameMap.teamCount() == ExpectedGroups
      check gameMap.flagless

suite "br s2 map pool: deterministic per-episode selection":
  let pool = loadBrS2PoolRaw(PoolPath)

  test "same episode seed, same member — twice, through the real picker":
    for seed in [0, 1, 679961, 0x7FFF_FFFF]:
      check pickBrS2SpecJson(seed, PoolPath) == pickBrS2SpecJson(seed, PoolPath)
      check brPoolIndex(seed, pool.len) == brPoolIndex(seed, pool.len)

  test "selection covers the ENTIRE pool across episode seeds":
    ## 4096 sequential seeds through the splitmix64 spread must touch all
    ## 64 slots — an unreachable member would be dead cargo the certify
    ## effort paid for and no episode can ever play.
    var seen: HashSet[int]
    for seed in 0 ..< 4096:
      seen.incl brPoolIndex(seed, pool.len)
    check seen.card == pool.len

  test "different episode seeds get different maps (freshness)":
    ## Two different episode ids on the same round should not funnel into
    ## one map. Not every pair differs (64 slots), so pin a nearby pair
    ## that provably does, plus the aggregate: 16 consecutive seeds must
    ## spread over at least 8 distinct members.
    var other = -1
    for candidate in 1 .. 64:
      if brPoolIndex(candidate, pool.len) != brPoolIndex(0, pool.len):
        other = candidate
        break
    check other != -1
    check pickBrS2SpecJson(0, PoolPath) != pickBrS2SpecJson(other, PoolPath)
    var distinct16: HashSet[int]
    for seed in 100 ..< 116:
      distinct16.incl brPoolIndex(seed, pool.len)
    check distinct16.card >= 8

  test "a missing pool file raises instead of silently substituting":
    expect CatchableError:
      discard pickBrS2SpecJson(1, GameDir / "data" / "no-such-pool.json")

suite "br s2 map pool: the variant hook and replay validity":
  ## These run through the REAL config path (sim_config.update on the
  ## shipped variant's game_config), from the repo root like a real
  ## process, because BrS2MapPoolPath is repo-root-relative.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)

  let gc = variantGameConfig()

  test "the shipped variant selects a pool member and pins it as mapSpec":
    check gc["mapPath"].getStr() == BrPoolMapName
    check not gc.hasKey("mapSpec")
    var config = defaultGameConfig()
    config.update($gc)
    check config.mapSpec.len > 0
    let picked = parseJson(config.mapSpec)
    let pool = loadBrS2PoolRaw(PoolPath)
    let expected = pool[brPoolIndex(gc["seed"].getInt(), pool.len)]
    check picked["name"].getStr() == expected["name"].getStr()
    check picked == expected["spec"]

  test "selection through the full config path is deterministic per seed":
    var gcA = variantGameConfig()
    gcA["seed"] = %12345
    var configA = defaultGameConfig()
    configA.update($gcA)
    var configB = defaultGameConfig()
    configB.update($gcA)
    check configA.mapSpec == configB.mapSpec
    check parseJson(configA.mapSpec)["name"].getStr().startsWith("br-gen-")

  test "two different episode seeds play different maps through the full config path":
    let pool = loadBrS2PoolRaw(PoolPath)
    var seedB = -1
    for candidate in 12346 .. 12409:
      if brPoolIndex(candidate, pool.len) != brPoolIndex(12345, pool.len):
        seedB = candidate
        break
    check seedB != -1
    var gcA = variantGameConfig()
    gcA["seed"] = %12345
    var gcB = variantGameConfig()
    gcB["seed"] = %seedB
    var configA = defaultGameConfig()
    configA.update($gcA)
    var configB = defaultGameConfig()
    configB.update($gcB)
    check configA.mapSpec != configB.mapSpec

  test "the echoed (replay) config carries the pinned spec and reloads it, pool unconsulted":
    var gcA = variantGameConfig()
    gcA["seed"] = %424242
    var recorded = defaultGameConfig()
    recorded.update($gcA)
    ## What a replay stores: configJson's echo — mapPath "brpool" AND the
    ## fully expanded mapSpec that was pinned at record time.
    let echoed = parseJson(recorded.configJson())
    check echoed["mapPath"].getStr() == BrPoolMapName
    check echoed.hasKey("mapSpec")
    check $echoed["mapSpec"] == recorded.mapSpec
    ## Playback: re-parse the echoed config. The explicit mapSpec wins;
    ## the seed-driven pool pick never runs.
    var playback = defaultGameConfig()
    playback.update($echoed)
    check playback.mapSpec == recorded.mapSpec

  test "an embedded mapSpec BEATS the pool pick — the rotation-out guarantee (red-proof)":
    ## Forge a replay-shaped config whose embedded spec is a DIFFERENT
    ## pool member than its seed selects. If the hook ever re-consulted
    ## the pool on playback, this would load the seed's pick and the
    ## check would go red — which is exactly what would break a replay
    ## whose map rotated out of the pool.
    let pool = loadBrS2PoolRaw(PoolPath)
    let seedIdx = brPoolIndex(424242, pool.len)
    let otherIdx = (seedIdx + 1) mod pool.len
    var forged = variantGameConfig()
    forged["seed"] = %424242
    forged["mapSpec"] = pool[otherIdx]["spec"]
    var config = defaultGameConfig()
    config.update($forged)
    check parseJson(config.mapSpec)["name"].getStr() ==
      pool[otherIdx]["name"].getStr()

  setCurrentDir(previousDir)
