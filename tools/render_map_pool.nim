## Renders every curated-pool map to an annotated PNG plus a JSON manifest
## for the pool-review page: floor/stone/glass like dump_map_mask, with the
## protected zones tinted, pedestal positions dotted, and the med-kit
## candidate/active points marked.
## Usage: nim c -r tools/render_map_pool.nim outDir
## Demo/curation tooling; not part of the server.
import
  std/[json, os, strformat],
  pixie,
  ../src/ctf/[map_pool, sim],
  map_render

when isMainModule:
  let outDir = if paramCount() >= 1: paramStr(1) else: "pool-preview"
  createDir(outDir)
  var manifest = newJArray()
  for i, seed in MapPoolSeeds:
    let
      gameMap = loadCtfMapMetadata("gen:" & $seed)
      renderOptions = MapRenderOptions(
        maxDimension: 0,
        overlays: {overlayProtected, overlayPickups},
        pickupKinds: {pickupMedKitActive, pickupMedKitCandidate},
      )
    doAssert gameMap.genSeed == seed, "pool seed rolled forward: " & $seed
    let img = renderMap(gameMap, renderOptions).image
    ## The manifest reports the map's own SPEC tokens rather than a second
    ## hand-written vocabulary. `mapSpecJson` is the one place the wire names
    ## live ("mirrorHex" / "rot180" / ..., "hex2".."hex6", "disc"), so the
    ## review page can never label a map with a token the sim retired.
    let spec = parseJson(gameMap.mapSpecJson())
    let name = &"pool-{i:02}-seed-{seed}.png"
    img.writeFile(outDir / name)
    var kits = newJArray()
    for p in gameMap.medKitSpawns:
      kits.add %*[p.x, p.y]
    var candidates = newJArray()
    for p in gameMap.medKitCandidates:
      candidates.add %*[p.x, p.y]
    manifest.add %*{
      "index": i,
      "seed": seed,
      "file": name,
      "width": gameMap.width,
      "height": gameMap.height,
      "boardShape": "hexagon",
      "symmetry": spec["symmetry"].getStr(),
      "layout": spec["layout"].getStr(),
      "endzone": spec["endzone"].getStr(),
      "endzoneRadius": gameMap.endzoneRadius,
      "homeDepth": spec["homeDepth"].getInt(),
      "homeX": gameMap.teamHomeX(Red),
      "obstacles": gameMap.leftObstacles.len,
      "trenches": gameMap.trenches.len,
      "medKitSpawns": kits,
      "medKitCandidates": candidates,
    }
    echo "rendered ", name
  writeFile(outDir / "manifest.json", pretty(manifest))
  echo "wrote ", outDir / "manifest.json"
