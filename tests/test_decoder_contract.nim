## `tools/dump_map_mask.nim` is an EXTERNAL contract, and until now nothing in
## this repo held it to one.
##
## `.github/workflows/build-decoder.yml` publishes it as a release binary
## `decoder-gv<N>-<sha>`, and `cogames/ctf/team/bin/fetch-decoder.sh` in
## daveey/cogamer PINS a build. So the consumers of this output are parsing a
## binary they chose, on their own schedule, against a schema they read once.
## Nothing here fails when that schema moves — a deleted key just stops
## appearing, and on the far side of the contract a field silently reads as
## absent, which in every consumer language is some flavour of null rather than
## an error. That is the same shape as this repo's label contract, and the
## label contract has a test.
##
## Two things are pinned:
##
##   * `--raw`'s SHAPE. Its documentation says "length IS the shape contract":
##     `width * height` bytes, row-major, one per pixel. The hexagon did not
##     change the length — the array is still the full bounding box — but it
##     changed what a large minority of the bytes MEAN, so the length holding
##     is a fact worth asserting rather than assuming.
##   * `--geom`'s KEYS, per `DecoderFormatVersion`. Removing or renaming one is
##     a breaking change for a pinned consumer and must bump the version; this
##     test is what makes that a decision rather than an accident.
import
  std/[json, sets, unittest],
  ctf/[arena, sim, sim_types],
  ../tools/dump_map_mask

const RequiredGeomKeys = [
  "formatVersion", "gameVersion", "name", "path", "width", "height", "center",
  "border", "boardShape", "hullOrientation", "hullVertices", "circumradius",
  "apothem", "symmetry", "layout", "genSeed", "flagRing", "captureClear",
  "consts", "teams", "pickups"]

const RequiredZoneKeys = [
  "xLo", "xHi", "yLo", "yHi", "disc", "anchorX", "anchorY", "radius"]

const RetiredZoneKeys = ["diag", "cornerX", "cornerY", "diagLimit"]
  ## The C4-era corner-zone vocabulary. No hex capture zone can produce the
  ## shape these described, so their RETURN would mean someone reintroduced a
  ## zone shape the arena cannot seat.

proc boards(): seq[CtfMap] =
  ## Both hand-authored arenas, both 4-team boards, and a generated seed —
  ## named and generated maps export through the same code, and a contract
  ## that only ever saw `arena` would not notice a generated map losing a key.
  @[loadCtfMapMetadata("arena"), loadCtfMapMetadata("arena-large"),
    loadCtfMapMetadata("arena-hex4"), loadCtfMapMetadata("arena-hex4-giant"),
    loadCtfMapMetadata("gen:4242")]

suite "decoder release contract (tools/dump_map_mask)":
  test "--raw is exactly width*height bytes, row-major":
    ## The whole shape contract, on the smallest board that has one. Colossal
    ## is left out on purpose: this asserts an identity, not a size.
    for gameMap in [loadCtfMapMetadata("arena"),
                    loadCtfMapMetadata("arena-hex4")]:
      let raw = rawMask(gameMap)
      check raw.len == gameMap.width * gameMap.height

  test "--raw classes are 0 floor / 1 stone / 2 glass, and nothing else":
    ## A fourth byte value would be an unannounced schema change: every
    ## consumer's classifier is a lookup over these three.
    var seen: HashSet[int]
    for c in rawMask(loadCtfMapMetadata("arena")):
      seen.incl int(c)
    check seen <= toHashSet([0, 1, 2])
    check 0 in seen
    check 1 in seen

  test "the six hull corners are stone in --raw":
    ## The property the rectangular era did not have, and the one a consumer
    ## most needs to be told: the array is the BOX, the playfield is the hull,
    ## and the difference is reported as stone rather than as a hole.
    for gameMap in boards():
      let
        raw = rawMask(gameMap)
        w = gameMap.width
        h = gameMap.height
      for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        check raw[y * w + x] == char(1)

  test "--geom carries every key this format version promises":
    for gameMap in boards():
      let geom = geometryJson(gameMap)
      for key in RequiredGeomKeys:
        checkpoint gameMap.name & " is missing --geom key " & key
        check geom.hasKey(key)
      check geom["formatVersion"].getInt() == DecoderFormatVersion
      check geom["boardShape"].getStr() == "hexagon"
      ## Not "pointy-top". The key read that for a while against a hull that
      ## has always been the other one, and a consumer that believed it would
      ## rebuild the hexagon rotated 30 degrees.
      check geom["hullOrientation"].getStr() == "flat-top"
      check geom["hullVertices"].len == 6

  test "the published hull vertices are ON the hull":
    ## Anything can be written into a JSON array. These have to agree with the
    ## boundary predicate the sim collides against, or the contract is a
    ## plausible-looking lie — which is worse than an absent key, because a
    ## consumer cannot detect it.
    for gameMap in boards():
      let
        geom = geometryJson(gameMap)
        board = gameMap.mapBoard()
      for vertex in geom["hullVertices"]:
        let
          x = vertex["x"].getInt()
          y = vertex["y"].getInt()
        check x >= 0 and x < gameMap.width
        check y >= 0 and y < gameMap.height
        ## A vertex sits ON the boundary: inside the hull to within a pixel of
        ## rounding, and never deep inside it.
        check board.hexEdgeDist(x, y) < 2.0

  test "every capture zone is a disc, and the C4 corner keys are gone":
    for gameMap in boards():
      let geom = geometryJson(gameMap)
      check geom["teams"].len == gameMap.teamCount()
      for team in geom["teams"]:
        let zone = team["captureZone"]
        for key in RequiredZoneKeys:
          check zone.hasKey(key)
        for key in RetiredZoneKeys:
          checkpoint "the retired C4 zone key " & key & " is back"
          check not zone.hasKey(key)
        check zone["disc"].getBool()
        check zone["radius"].getInt() > 0
