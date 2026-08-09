## pin_new_pool_hashes — render the NEWLY ADDED pool entries with the EXACT
## options the golden test uses (`test_map_editor_core.poolRenderOptions`),
## write each to a PNG so a human can LOOK at it before pinning (the test's
## standing discipline: a hash nobody looked at makes a bad map the baseline),
## and print the CRC32 to append to `PoolRenderHashes`.
##
## Usage: nim c -d:release -r tools/pin_new_pool_hashes.nim [firstNewIndex] outDir
## Default firstNewIndex = 20 (the three tasks#49 seeds), outDir = /tmp/newpool
import std/[os, strformat, strutils]
import crunchy/crc32, pixie, pixie/fileformats/png
import ../src/ctf/[arena, sim, map_metrics, map_rules, map_pool, map_taxonomy]
import ../tools/map_render

proc poolRenderOptions(maxDimension = 0): MapRenderOptions =
  ## Byte-identical to tests/test_map_editor_core.nim's local proc.
  MapRenderOptions(
    maxDimension: maxDimension,
    overlays: {overlayProtected, overlayPickups},
    pickupKinds: {pickupMedKitActive, pickupMedKitCandidate},
  )

when isMainModule:
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  let
    firstNew = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
    outDir = if paramCount() >= 2: paramStr(2) else: "/tmp/newpool"
  createDir(outDir)
  for index in firstNew ..< MapPoolSeeds.len:
    let
      seed = MapPoolSeeds[index]
      gm = generateCtfMap(seed)   # exactly poolMap/cachedPoolMap resolves to
      m = evaluateMap(gm, "pin")
      r = mapRules(gm.mapSizeClass(), 2)
      rendered = renderMap(gm, poolRenderOptions())
      png = rendered.image.encodePng()
      h = crc32(png)
    let path = outDir / &"pool-{index:02}-seed-{seed}.png"
    writeFile(path, png)
    echo &"index {index} seed {seed}: {gm.mapSizeClass().sizeName()}/" &
      &"{mapArchetypeFor(seed,2)}/{playtypeLabel(m,r)} " &
      &"{gm.width}x{gm.height} sym={gm.symmetry} endzone={gm.endzone} " &
      &"choke={m.chokeCount} routeMin={m.routeCountMin} score={m.staticScore():.4f} " &
      &"cover={m.coverPermille}pm  ->  hash=0x{h.toHex(8).toLowerAscii()}'u32  " &
      &"({path})"
