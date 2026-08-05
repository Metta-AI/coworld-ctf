## The map BIOME art layer: which floor texture a map's skin resolves to, the
## luminance contract every one of those textures owes the endzone ember glow,
## and the three ways a biome ships broken —
##   1. the texture is missing from the commit (.gitignore opens with `*`, so a
##      freshly generated PNG is silently untracked). In CI this suite runs on
##      a clean checkout, so `fileExists` here IS the tracked-in-git check.
##   2. the texture's luminance breaks the contract, and the endzone either
##      floods with flat team color or shows no ember at all.
##   3. the biome quietly changes the map's collision skeleton. A biome must
##      change the LOOK and nothing else.
import
  helpers,
  std/[os, strutils, unittest],
  pixie,
  ctf/sim

const
  # The five biome names the map generator uses, plus the default skin. This
  # list is the API contract with the layout half: it picks a biome by these
  # names, and each one indexes a texture through biomeFloorPath.
  BiomeNames = ["arena", "caves", "forest", "desert", "city", "plains"]
  # Share of texels allowed inside the ember band (luminance < 66). Mirrors
  # GLOW_PCT_MIN/MAX in scripts/art/build_floor.py, which enforces the same
  # window at bake time; this is the gate on what actually reaches data/.
  GlowPctMin = 0.30
  GlowPctMax = 6.00

proc lumProfile(tex: Image): tuple[glowPct, fullPct: float, lo, hi: int] =
  ## The endzone glow's own view of a floor texture, measured through
  ## floorLuminance — the same proc emberThroughCracks gates on, so this can
  ## never drift from the renderer.
  var
    glow = 0
    full = 0
    lo = 255
    hi = 0
  for y in 0 ..< tex.height:
    for x in 0 ..< tex.width:
      let l = floorLuminance(tex.unsafe[x, y].rgba)
      if l < EndzoneFaceLevel: inc glow
      if l <= EndzoneCrackLevel: inc full
      lo = min(lo, l)
      hi = max(hi, l)
  let total = float(tex.width * tex.height)
  (glow.float * 100.0 / total, full.float * 100.0 / total, lo, hi)

suite "map biomes: the floor-texture resolution path":
  test "the biome names are exactly the set the map generator may pick":
    var names: seq[string]
    for biome in MapBiome:
      names.add $biome
    check names == @BiomeNames

  test "each biome resolves to its own texture; the default keeps its path":
    check biomeFloorPath(biomeArena) == "data/arena_floor.png"
    for biome in MapBiome:
      if biome == biomeArena:
        continue
      check biomeFloorPath(biome) == "data/arena_floor_" & $biome & ".png"
    # No two biomes may share a tile — that would silently ship one skin twice.
    var paths: seq[string]
    for biome in MapBiome:
      check biomeFloorPath(biome) notin paths
      paths.add biomeFloorPath(biome)

  test "an empty or unknown biome name FALLS BACK to the default floor":
    for name in ["", "   ", "swamp", "Tundra", "arena_floor"]:
      check biomeFromName(name) == biomeArena
      check biomeFloorPath(biomeFromName(name)) == "data/arena_floor.png"

  test "biome names parse case- and whitespace-insensitively":
    check biomeFromName("caves") == biomeCaves
    check biomeFromName("CAVES") == biomeCaves
    check biomeFromName("  Desert ") == biomeDesert
    for biome in MapBiome:
      check biomeFromName($biome) == biome

suite "map biomes: the texture set":
  test "every biome floor is present in data/ (i.e. committed) and 256x256":
    for biome in MapBiome:
      let path = GameDir / biomeFloorPath(biome)
      check fileExists(path)
      let tex = loadBiomeFloor(biome, GameDir)
      check tex.width == 256
      check tex.height == 256

  test "every biome floor honors the endzone LUMINANCE CONTRACT":
    # Polished faces at/above EndzoneFaceLevel take no glow; only crack bottoms
    # at/below EndzoneCrackLevel glow fully. Too few dark texels and the
    # endzone shows nothing; too many and it reads as a flat team wash.
    for biome in MapBiome:
      let
        tex = loadBiomeFloor(biome, GameDir)
        profile = lumProfile(tex)
      checkpoint($biome & " glow%=" & $profile.glowPct & " full%=" &
        $profile.fullPct & " lum " & $profile.lo & ".." & $profile.hi)
      # There ARE cracks, and they bottom out dark enough to glow at full
      # strength.
      check profile.lo <= EndzoneCrackLevel
      # The surface is overwhelmingly clean face, and the ember band is a
      # crack network rather than a wash.
      check profile.glowPct >= GlowPctMin
      check profile.glowPct <= GlowPctMax
      check profile.hi >= EndzoneFaceLevel

suite "map biomes: failure modes":
  test "a MISSING texture raises a NAMED, actionable error, not a pixie raise":
    let empty = getTempDir() / "ctf-biome-missing"
    removeDir(empty)
    createDir(empty)
    defer: removeDir(empty)
    for biome in MapBiome:
      var raised = false
      try:
        discard loadBiomeFloor(biome, empty)
      except CtfError as error:
        raised = true
        # Names the biome, the exact path it looked for, and the fix.
        check $biome in error.msg
        check (empty / biomeFloorPath(biome)) in error.msg
        check "build_floor.py" in error.msg
        check "git add -f" in error.msg
      check raised

  test "the map spec round-trips a biome, and omits the key for arena":
    ## Replays PIN mapSpec, so a biome that does not survive the round-trip
    ## silently replays as concrete. The key is emitted only for a non-arena
    ## biome so every classic map's spec stays byte-identical — that is what
    ## keeps the 402-row validation baseline and dump_map_specs pinned.
    let classic = generateCtfMap(1001)
    check classic.biome == biomeArena
    let classicSpec = mapSpecJson(classic)
    check "\"biome\"" notin classicSpec
    check mapFromSpecJson(classicSpec).biome == biomeArena

    var skinned = generateCtfMap(1001)
    skinned.biome = biomeDesert
    let skinnedSpec = mapSpecJson(skinned)
    check "\"biome\":\"desert\"" in skinnedSpec
    check mapFromSpecJson(skinnedSpec).biome == biomeDesert

  test "an unknown spec biome raises rather than falling back":
    ## Matches symmetry/layout/endzone: a MISSING key is an old spec and
    ## defaults, but an unknown NON-EMPTY value is a typo or a spec from the
    ## future, and silently reinterpreting one defeats the point of pinning.
    ## `biomeFromName` is tolerant BY DESIGN for the CLI/generator boundary
    ## and must never be used at this boundary.
    var skinned = generateCtfMap(1001)
    skinned.biome = biomeCity
    let bad = mapSpecJson(skinned).replace("\"city\"", "\"tundra\"")
    var raised = false
    try:
      discard mapFromSpecJson(bad)
    except CtfError as error:
      raised = true
      check "tundra" in error.msg
    check raised

  test "a biome changes the LOOK and never the collision skeleton":
    let previous = getCurrentDir()
    setCurrentDir(GameDir)
    try:
      var gameMap = loadCtfMap("arena")
      check gameMap.biome == biomeArena   # zero value: today's concrete
      let base = loadMapLayers(gameMap)
      gameMap.biome = biomeDesert
      let skinned = loadMapLayers(gameMap)
      # Same walkable/wall geometry, to the byte...
      check skinned.walkImage.data == base.walkImage.data
      check skinned.wallImage.data == base.wallImage.data
      # ...and a genuinely different picture.
      check skinned.mapImage.data != base.mapImage.data
    finally:
      setCurrentDir(previous)
