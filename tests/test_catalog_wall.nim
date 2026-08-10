## test_catalog_wall — the GUARD that ties the published coverage wall
## (`docs/evidence/catalog-coverage.html`) to `MapPoolSeeds` (tasks#59).
##
## `tests/test_map_cards.nim` already turns cards↔pool drift into a failing
## test, but there was no equivalent guard for the WALL, so the seed-hunt
## additions (tasks#49) could land in the pool while the published wall still
## rendered the 20 originals and no test went red. tasks#59 is exactly that
## class of silent drift. This module closes it: the wall must embed one render
## per `MapPoolSeeds` entry, every pool seed must be labelled on the wall, and
## the wall must carry no seed label that is not in the pool.
##
## Pure filesystem + string scanning — no map generation, no graphics — so it
## is cheap and lives in the fast shard next to test_map_cards. It reads the
## committed artifact as data; it does not regenerate it (regeneration is the
## tool's job: `tools/map_catalog.nim` + `tools/render_map_pool.nim` +
## `tools/build_catalog_html.py`).

import
  std/[os, re, sets, strutils, strformat, unittest],
  ctf/map_pool

const WallPath = currentSourcePath.parentDir.parentDir / "docs" / "evidence" /
  "catalog-coverage.html"

proc readWall(): string =
  doAssert fileExists(WallPath),
    "published coverage wall missing: " & WallPath
  readFile(WallPath)

suite "catalog wall tracks the pool (tasks#59 guard)":
  test "wall embeds exactly one render per MapPoolSeeds entry":
    let html = readWall()
    # Each pool map's render is inlined as a base64 PNG data URI by
    # tools/build_catalog_html.py; count them.
    let imgs = html.findAll(re"data:image/png;base64,[A-Za-z0-9+/=]+")
    check imgs.len == MapPoolSeeds.len
    if imgs.len != MapPoolSeeds.len:
      checkpoint &"wall embeds {imgs.len} renders but MapPoolSeeds has " &
        &"{MapPoolSeeds.len} (regenerate: tools/map_catalog.nim + " &
        "tools/render_map_pool.nim + tools/build_catalog_html.py)"

  test "every MapPoolSeeds entry is labelled on the wall":
    let html = readWall()
    var labelled: HashSet[int]
    for m in html.findAll(re"seed (\d+)"):
      labelled.incl parseInt(m.replace("seed ", "").strip())
    var missing: seq[int]
    for seed in MapPoolSeeds:
      if seed notin labelled: missing.add seed
    check missing.len == 0
    if missing.len > 0:
      checkpoint "pool seeds absent from the wall (republish it): " &
        missing.join(", ")

  test "no orphan wall labels — every wall seed is a current pool seed":
    let html = readWall()
    var poolSeeds: HashSet[int]
    for seed in MapPoolSeeds: poolSeeds.incl seed
    var orphans: seq[int]
    for m in html.findAll(re"seed (\d+)"):
      let seed = parseInt(m.replace("seed ", "").strip())
      if seed notin poolSeeds and seed notin orphans:
        orphans.add seed
    check orphans.len == 0
    if orphans.len > 0:
      checkpoint "wall labels with no matching pool seed (stale wall): " &
        orphans.join(", ")
