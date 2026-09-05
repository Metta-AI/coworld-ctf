## S2 simplification, PKG-B: the 16-group map pool for the 16-solo-team
## shape (one entrant per group, not the 8-duo pool's two-per-group) and
## its per-episode selection hook (sim_config.update's "brpool16" branch,
## br_map_pool.nim's "Season 2 solo pool" section).
##
## This does NOT add a new pool: it wires the ORIGINAL certified 16-group
## pool (data/br_map_pool.json, commit 6d14563c) — the pre-#355 pool the
## live classic `battle-royale` variant's single pinned map (br-gen-1339)
## was itself drawn from — behind a seed-deterministic picker, mirroring
## the 8-duo s2 pool's "brpool" hook exactly (pickBrS2SpecJson /
## BrPoolMapName / data/br_s2_map_pool.json) but over 16-`spawnGroups`
## giant maps instead of 8. No shipped variant sets mapPath "brpool16"
## yet — that is a mapPath-only manifest change for whoever lands the
## 16-solo-team variant — so the hook tests below build a synthetic
## game_config (starting from the real `battle-royale` variant's config,
## which already carries teams:16/brMode:true, with its pinned mapSpec
## swapped for mapPath:"brpool16") instead of reading a live variant.
##
## Like test_br_map_pool.nim and test_br_s2_map_pool.nim, this suite does
## NOT re-run brmapkit's own allPass gate (that happened at generation
## time, out of band, for the ORIGINAL pool this reuses); it pins the
## stored shape and the new selection contract only. This file is
## additive and does not modify test_br_map_pool.nim or
## test_br_s2_map_pool.nim.

import
  helpers,
  std/[json, os, sets, strutils, unittest],
  ctf/[br_map_pool, sim, sim_config]

const
  PoolPath = GameDir / "data" / "br_map_pool.json"
  ManifestPath = GameDir / "coworld_manifest_paintbot.json"
  ClassicVariantId = "battle-royale"
    ## Borrowed only as a source of a real, already-16-team/brMode config
    ## shape to overlay mapPath:"brpool16" onto — see the header comment.
  ExpectedWidth = 3211
  ExpectedHeight = 1713
  ExpectedGunRange = 331
  ExpectedGroups = 16
  ExpectedPoolSize = 11
    ## The file's shipped size today (test_br_map_pool.nim only pins a
    ## ">= 3" floor since that suite is about the accessor contract in
    ## general; this suite pins the exact current shape as a falsifiable
    ## anchor for the solo-pool wiring specifically).

proc soloHookGameConfig(): JsonNode =
  ## The real classic `battle-royale` variant's config (teams:16,
  ## brMode:true, num_agents:32 — the right shape for a 16-spawnGroups
  ## map) with its pinned single mapSpec removed and mapPath set to
  ## "brpool16", so config.update exercises the new hook exactly the way
  ## a future 16-solo-team variant's game_config would.
  let manifest = parseJson(readFile(ManifestPath))
  for variant in manifest["variants"]:
    if variant["id"].getStr() == ClassicVariantId:
      result = copy(variant["game_config"])
      result.delete("mapSpec")
      result["mapPath"] = %BrPoolMapName16
      return
  doAssert false, ManifestPath & " has no " & ClassicVariantId & " variant"

suite "br s2 solo map pool: the reused 16-group pool":
  let pool = loadBrMapPoolRaw(PoolPath)

  test "current shipped shape: 11 entries, giant 16-group maps":
    check pool.len == ExpectedPoolSize
    var names: HashSet[string]
    for entry in pool:
      check entry["width"].getInt() == ExpectedWidth
      check entry["height"].getInt() == ExpectedHeight
      check entry["gunRange"].getInt() == ExpectedGunRange
      check entry["spawnGroups"].getInt() == ExpectedGroups
      check entry["spawnPoints"].len == ExpectedGroups
      check entry["flagless"].getBool() == true
      names.incl entry["name"].getStr()
    check names.card == pool.len

  test "every entry's spec loads as the real 16-group battle-royale shape":
    for entry in pool:
      let gameMap = mapFromSpecJson($entry)
      check gameMap.name == entry["name"].getStr()
      check gameMap.width == ExpectedWidth
      check gameMap.height == ExpectedHeight
      check gameMap.gunRange == ExpectedGunRange
      check gameMap.spawnGroups == ExpectedGroups
      check gameMap.spawnPoints.len == ExpectedGroups
      check gameMap.teamCount() == ExpectedGroups
      check gameMap.flagless

suite "br s2 solo map pool: deterministic per-episode selection":
  let pool = loadBrMapPoolRaw(PoolPath)

  test "same episode seed, same member — twice, through the real picker":
    for seed in [0, 1, 679961, 0x7FFF_FFFF]:
      check pickBrPoolSpecJson(seed, PoolPath) == pickBrPoolSpecJson(seed, PoolPath)
      check brPoolIndex(seed, pool.len) == brPoolIndex(seed, pool.len)

  test "selection covers the ENTIRE pool across episode seeds":
    var seen: HashSet[int]
    for seed in 0 ..< 4096:
      seen.incl brPoolIndex(seed, pool.len)
    check seen.card == pool.len

  test "different episode seeds get different maps (freshness)":
    var other = -1
    for candidate in 1 .. pool.len:
      if brPoolIndex(candidate, pool.len) != brPoolIndex(0, pool.len):
        other = candidate
        break
    check other != -1
    check pickBrPoolSpecJson(0, PoolPath) != pickBrPoolSpecJson(other, PoolPath)

  test "BrS2SoloMapPoolPath is the same file as the classic pool's BrMapPoolPath":
    check BrS2SoloMapPoolPath == BrMapPoolPath
    check BrS2SoloMapPoolPath == "data/br_map_pool.json"

  test "a missing pool file raises instead of silently substituting":
    expect CatchableError:
      discard pickBrPoolSpecJson(1, GameDir / "data" / "no-such-pool.json")

suite "br s2 solo map pool: the mapPath hook (config.update), synthetic 16-solo config":
  ## Runs through the REAL config path (sim_config.update), from the repo
  ## root like a real process, because BrS2SoloMapPoolPath is
  ## repo-root-relative. No shipped variant sets mapPath "brpool16" yet
  ## (see header comment) so these build a synthetic game_config rather
  ## than reading one off a live variant.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)

  let gc = soloHookGameConfig()

  test "the synthetic config selects a pool member and pins it as mapSpec":
    check gc["mapPath"].getStr() == BrPoolMapName16
    check not gc.hasKey("mapSpec")
    var config = defaultGameConfig()
    config.update($gc)
    check config.mapSpec.len > 0
    let picked = parseJson(config.mapSpec)
    let pool = loadBrMapPoolRaw(PoolPath)
    let expected = pool[brPoolIndex(gc["seed"].getInt(), pool.len)]
    check picked["name"].getStr() == expected["name"].getStr()
    check picked == expected

  test "selection through the full config path is deterministic per seed":
    var gcA = soloHookGameConfig()
    gcA["seed"] = %12345
    var configA = defaultGameConfig()
    configA.update($gcA)
    var configB = defaultGameConfig()
    configB.update($gcA)
    check configA.mapSpec == configB.mapSpec
    check parseJson(configA.mapSpec)["name"].getStr().startsWith("br-gen-")

  test "an embedded mapSpec BEATS the pool pick — the rotation-out guarantee (red-proof)":
    ## Forge a replay-shaped config whose embedded spec is a DIFFERENT
    ## pool member than its seed selects. If the hook ever re-consulted
    ## the pool on playback, this would load the seed's pick instead and
    ## the check would go red.
    let pool = loadBrMapPoolRaw(PoolPath)
    let seedIdx = brPoolIndex(424242, pool.len)
    let otherIdx = (seedIdx + 1) mod pool.len
    var forged = soloHookGameConfig()
    forged["seed"] = %424242
    forged["mapSpec"] = pool[otherIdx]
    var config = defaultGameConfig()
    config.update($forged)
    check parseJson(config.mapSpec)["name"].getStr() ==
      pool[otherIdx]["name"].getStr()

  test "the echoed (replay) config carries the pinned spec and reloads it, pool unconsulted":
    var gcA = soloHookGameConfig()
    gcA["seed"] = %898989
    var recorded = defaultGameConfig()
    recorded.update($gcA)
    let echoed = parseJson(recorded.configJson())
    check echoed["mapPath"].getStr() == BrPoolMapName16
    check echoed.hasKey("mapSpec")
    check $echoed["mapSpec"] == recorded.mapSpec
    var playback = defaultGameConfig()
    playback.update($echoed)
    check playback.mapSpec == recorded.mapSpec

  setCurrentDir(previousDir)
