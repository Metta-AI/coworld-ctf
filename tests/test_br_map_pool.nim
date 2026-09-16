## The certified BR map pool accessor (src/ctf/br_map_pool.nim), reading
## data/br_map_pool.json. Pins the doctrine every pool member owes:
##   - every entry is a FULL expanded mapSpec (not a bare seed) shaped
##     exactly like the live BR variant's pinned br-gen-1339 (16
##     spawnGroups, flagless, giant 3211x1713, gunRange 331);
##   - names are unique and self-consistent with genSeed ("br-gen-<seed>");
##   - loadBrMapPool/getBrMap round-trip through arena.mapFromSpecJson
##     without raising, and getBrMap's happy path returns the SAME map
##     loadBrMapPool would at that index;
##   - getBrMap on an unknown name raises — proven directly (red-proof),
##     not just assumed from reading the source;
##   - the pool has enough members to back a "3 different maps" ballot
##     (the whole point of this file existing instead of the single
##     pinned map the live variant carries today).
## This suite does NOT re-run brmapkit's own allPass gate (that happened
## at generation time, out of band — see this module's doc comment and
## the PR that added data/br_map_pool.json for the seeds and per-map gate
## results); it only pins the STORED spec's shape and this accessor's
## contract.

import
  helpers,
  std/[json, os, sets, unittest],
  ctf/br_map_pool

const
  PoolPath = GameDir / "data" / "br_map_pool.json"
  ExpectedWidth = 3211
  ExpectedHeight = 1713
  ExpectedGunRange = 331
  ExpectedSpawnGroups = 16

suite "br map pool":
  test "pool file parses as a JSON array with enough members for a real ballot":
    let raw = loadBrMapPoolRaw(PoolPath)
    check raw.kind == JArray
    ## The whole reason this file exists: a pre-match ballot offering "3
    ## BR options on different maps" needs at least 3 distinct certified
    ## maps to draw from; the live single-map variant proves 1 is not
    ## enough. The pool as landed carries more (see the PR body), but the
    ## structural floor this test pins is the doctrine minimum.
    check raw.len >= 3

  test "every entry is a full expanded giant-BR mapSpec, not a bare seed":
    let raw = loadBrMapPoolRaw(PoolPath)
    for node in raw:
      check node.kind == JObject
      check node["width"].getInt() == ExpectedWidth
      check node["height"].getInt() == ExpectedHeight
      check node["gunRange"].getInt() == ExpectedGunRange
      check node["spawnGroups"].getInt() == ExpectedSpawnGroups
      check node["spawnPoints"].len == ExpectedSpawnGroups
      check node["flagless"].getBool() == true
      ## The doctrine this pool exists to satisfy ("pin the full expanded
      ## mapSpec, never just a seed") is falsifiable: an entry that
      ## regressed to a bare {"genSeed": N} stub would still have SOME
      ## width/height/spawnPoints keys only if it carries real geometry.
      check node["leftObstacles"].len > 0
      check node.hasKey("genSeed")

  test "names are unique and self-consistent with genSeed":
    let raw = loadBrMapPoolRaw(PoolPath)
    var seen = initHashSet[string]()
    for node in raw:
      let name = node["name"].getStr()
      let seed = node["genSeed"].getInt()
      check name == "br-gen-" & $seed
      check name notin seen
      seen.incl name
    check seen.len == raw.len

  test "brMapPoolNames matches the raw file's names, in order":
    let raw = loadBrMapPoolRaw(PoolPath)
    let names = brMapPoolNames(PoolPath)
    check names.len == raw.len
    for i, node in raw.elems:
      check names[i] == node["name"].getStr()

  test "loadBrMapPool round-trips every entry through mapFromSpecJson":
    let maps = loadBrMapPool(PoolPath)
    let names = brMapPoolNames(PoolPath)
    check maps.len == names.len
    for i, m in maps:
      check m.name == names[i]
      check m.width == ExpectedWidth
      check m.height == ExpectedHeight
      check m.gunRange == ExpectedGunRange
      check m.flagless == true
      check m.spawnGroups == ExpectedSpawnGroups
      check m.spawnPoints.len == ExpectedSpawnGroups

  test "getBrMap fetches the named entry, matching loadBrMapPool's own parse":
    let names = brMapPoolNames(PoolPath)
    check names.len > 0
    let pickName = names[names.len div 2]  ## not just element 0 — a linear
                                             ## scan bug that only worked on
                                             ## the first entry must not hide.
    let byName = getBrMap(pickName, PoolPath)
    let all = loadBrMapPool(PoolPath)
    var found = false
    for m in all:
      if m.name == pickName:
        found = true
        check byName.genSeed == m.genSeed
        check byName.leftObstacles.len == m.leftObstacles.len
    check found

  test "getBrMap raises on an unknown name (red-proof: the guard actually fires)":
    expect ValueError:
      discard getBrMap("br-gen-not-a-real-entry-000000", PoolPath)

  test "default BrMapPoolPath resolves relative to the repo root, matching production callers":
    ## Production code (a future ballot generator) will call these procs
    ## with no path argument at all; this pins that the default constant
    ## actually points at the same file the rest of this suite exercises
    ## via the explicit GameDir-qualified path, from the cwd tests already
    ## run from (see helpers.nim: "Tests run from the repo root").
    check BrMapPoolPath == "data/br_map_pool.json"
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      let names = brMapPoolNames()
      check names.len == brMapPoolNames(PoolPath).len
    finally:
      setCurrentDir(previousDir)
