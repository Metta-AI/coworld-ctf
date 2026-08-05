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
  ## The pool is curated BY SCORE now, so the review page has to show the
  ## score — otherwise the reader has no way to tell a curated pool from the
  ## first twenty valid seeds, which is exactly what the pool used to be.
  ## Measured against the arena, in the same run, per meta-rule 1.
  let control = controlMetrics()
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
    let metrics = computeMapMetrics(
      gameMap, withChokepoints = false, withValidation = false)
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
      "score": metrics.scoreMap(control).score,
      "interiorFrac": metrics.interiorFrac,
      "controlInteriorFrac": control.interiorFrac,
      "wallFrac": metrics.wallFrac,
      "p95ClearancePx": metrics.p95ClearancePx,
    }
    echo &"rendered {name}  score=" &
      &"{metrics.scoreMap(control).score * 100:.1f} " &
      &"interior={metrics.interiorFrac * 100:.1f}% " &
      &"(control {control.interiorFrac * 100:.1f}%)"
  writeFile(outDir / "manifest.json", pretty(manifest))
  echo "wrote ", outDir / "manifest.json"
