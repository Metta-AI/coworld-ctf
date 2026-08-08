## T3: prints pool render CRC32 exactly as tests/test_map_editor_core.nim pins
## them (poolMap == poolCtfMap best-of-K; same poolRenderOptions), so
## PoolRenderHashes can be re-pinned from a looked-at render.
import std/[strformat], pixie, pixie/fileformats/png, crunchy/crc32,
  ../src/ctf/[map_pool, sim], map_render

proc poolRenderOptions(): MapRenderOptions =
  MapRenderOptions(
    maxDimension: 0,
    overlays: {overlayProtected, overlayPickups},
    pickupKinds: {pickupMedKitActive, pickupMedKitCandidate})

when isMainModule:
  for index in 0 ..< MapPoolSeeds.len:
    let
      rendered = renderMap(poolCtfMap(index), poolRenderOptions())
      h = crc32(rendered.image.encodePng())
    echo &"{index} 0x{h:08x}'u32"
