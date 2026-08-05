## mapkit — a CLI for authoring interesting-but-fair CTF maps.
##
## A peer to `tools/map_editor.nim`: it never reimplements geometry, it drives
## the same sim procs (generateMapAttempt, mapSpecJson/mapFromSpecJson,
## validateGeneratedMap, mapDiagnostics, buildArenaObstacles) plus the shared
## `map_render` rasterizer. The working document is a `mapSpec` JSON file.
##
## Claude's loop:
##   mapkit generate --style caves --seed 7 -o m.json
##   mapkit render   m.json -o m.png            # then LOOK at the PNG
##   mapkit validate m.json                     # fair + connected? (exit code)
##   mapkit metrics  m.json                     # interesting? (cover, sightlines)
##   $EDITOR m.json                             # nudge leftObstacles by hand
##   ...repeat until it looks good AND validates.
##
## Fairness is entirely the sim's job: generators emit a one-half/quadrant seed
## set, the sim mirrors it, carves protected floor, and validates. See
## docs/ENV_VARIATION.md and docs/MAPKIT.md.

import
  std/[os, random, strformat, strutils, tables],
  pixie,
  ../src/ctf/[sim, mapgen_styles],
  map_render

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

# --- argument parsing --------------------------------------------------------

type Args = object
  positionals: seq[string]
  flags: Table[string, string]
  params: Table[string, string]  ## repeated --param k=v
  bools: Table[string, bool]

proc parseArgs(argv: seq[string]): Args =
  result.flags = initTable[string, string]()
  result.params = initTable[string, string]()
  result.bools = initTable[string, bool]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--param":
      inc i
      if i >= argv.len: fail("--param needs k=v")
      let kv = argv[i].split('=', 1)
      if kv.len != 2: fail("--param expects k=v, got: " & argv[i])
      result.params[kv[0]] = kv[1]
    elif a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags[kv[0]] = kv[1]
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--"):
        result.flags[body] = argv[i + 1]
        inc i
      else:
        result.bools[body] = true
    elif a.startsWith("-") and a.len == 2:
      # short flag: -o value
      let key = if a == "-o": "out" else: a[1 .. ^1]
      inc i
      if i >= argv.len: fail("flag " & a & " needs a value")
      result.flags[key] = argv[i]
    else:
      result.positionals.add a
    inc i

proc flag(a: Args, key, default: string): string =
  a.flags.getOrDefault(key, default)

proc reqFlag(a: Args, key: string): string =
  if key notin a.flags: fail("missing required --" & key)
  a.flags[key]

proc intFlag(a: Args, key: string, default: int): int =
  if key in a.flags: a.flags[key].parseInt else: default

# --- param application -------------------------------------------------------

proc applyParams(p: var StyleParams, params: Table[string, string]) =
  for key, raw in params:
    template asInt: int = raw.parseInt
    template asFloat: float = raw.parseFloat
    case key
    of "period": p.period = asInt
    of "prob": p.prob = asFloat
    of "clusterMin": p.clusterMin = asInt
    of "clusterMax": p.clusterMax = asInt
    of "radMin": p.radMin = asInt
    of "radMax": p.radMax = asInt
    of "jitter": p.jitter = asInt
    of "cell": p.cell = asInt
    of "fillProb": p.fillProb = asFloat
    of "steps": p.steps = asInt
    of "birth": p.birth = asInt
    of "death": p.death = asInt
    of "blobScale": p.blobScale = asFloat
    of "wallThick": p.wallThick = asInt
    of "braid": p.braid = asFloat
    else: fail("unknown --param: " & key)

# --- placement region --------------------------------------------------------

proc placementRegion(base: CtfMap): MapRect =
  ## The seed region, inset only enough to clear the perimeter wall, keep a
  ## touch off the home border, and stop short of the symmetry seam. It spans
  ## nearly the full HEIGHT on purpose: the validator rejects any unbroken
  ## horizontal sightline, so cover must reach top and bottom. Bases need no
  ## wide margin here — the sim carves protected floor out of any shape that
  ## overlaps a flag ring, spawn pocket, or capture lane.
  let
    sr = mapSeedRegion(base)
    vMargin = 2    ## flush to the perimeter wall so cover reaches the edge rows
    hMargin = 40   ## a little off the home border (carve still protects bases)
    seam = 20      ## short of the center seam (where a shape meets its image)
  case base.symmetry
  of symMirror, symRot180:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - 2 * vMargin))
  of symRot90:
    # rot90: the quadrant's right AND bottom edges are the map's center lines.
    # Keep the x-side seam (anchors stay off the central flag ring), but let the
    # region reach nearly to the center ROW so the vertical anchors chain all the
    # way down — their identity+rot180 images then tile every horizontal row with
    # no center-band gap (and the rot90/rot270 images cover the columns).
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - vMargin))
  of symQuadMirror:
    # quad-mirror: reflections never rotate a shape into cross-coverage, so
    # the quadrant itself must cover the border COLUMNS as well as the edge
    # rows — the validator scans vertical sightlines on these maps. Flush to
    # the perimeter on the left exactly like the top (the protected-floor
    # carve still guards the corner/arm bases); keep both center seams.
    MapRect(x: sr.x + vMargin, y: sr.y + vMargin,
            w: max(1, sr.w - vMargin - seam), h: max(1, sr.h - vMargin))

const styleSalt = 0x9E3779B1  ## decorrelate the style stream from the map seed.

proc quadColumnAnchors(base: CtfMap, region: MapRect, seed: int):
    seq[ArenaShape] =
  ## Quad-mirror boards must break VERTICAL sightlines too (the sim
  ## validator scans columns on them; reflections never rotate a style's
  ## row anchors into column cover the way rot90 does). The styles ship
  ## `verticalAnchors` for rows; this is its transpose, authored here as
  ## tool policy: one thin horizontal bar per column band, bars overlapping
  ## in x so their union (plus the mirrorX images) covers every column, each
  ## bar's y drawn INSIDE the validator's scan band so every bar counts.
  var r = initRand(seed xor 0x51D3_BA22)
  const
    Period = 150
    Thick = 12
  let
    barW = Period + 24
    loY = max(region.y, base.sightlineLoY)
    hiY = min(region.y + region.h - Thick, base.sightlineHiY - Thick)
  if hiY <= loY:
    return
  ## The bars run all the way to the CENTER seam (past the style region's
  ## seam margin): the mirrorX fold covers the right half, so the seed bars
  ## must reach x = width/2 or the seam-gap columns stay open. A bar
  ## overhanging the seam just overlaps its own image — harmless.
  ##
  ## Each bar's y is chosen carve-aware: the protected-floor carve (spawn
  ## pockets, the flag ring at the seam, plus-arm approaches) erases any
  ## bar segment it covers, so of a handful of candidate rows the bar takes
  ## the one whose span keeps the most wall. A span that is protected at
  ## EVERY candidate is left bare — those columns are exempt in the
  ## validator for exactly the same reason.
  var gx = region.x
  while gx <= base.width div 2:
    let x = max(region.x, gx - 12)
    var
      bestY = -1
      bestKept = 0
    for _ in 0 ..< 8:
      let y = r.rand(loY .. hiY)
      var kept = 0
      var sx = x
      while sx < x + barW:
        if not mapProtectedFloorAt(base, sx, y + Thick div 2):
          inc kept
        sx += 4
      if kept > bestKept:
        bestKept = kept
        bestY = y
    if bestY >= 0:
      result.add rectShape(MapRect(x: x, y: bestY, w: barW, h: Thick))
    gx += Period

# --- commands ----------------------------------------------------------------

proc readSpec(path: string): CtfMap =
  if not fileExists(path): fail("no such spec file: " & path)
  mapFromSpecJson(readFile(path))

proc cmdGenerate(a: Args) =
  let
    style = parseStyle(a.reqFlag("style"))
    seed = a.intFlag("seed", 1)
    trenches = a.bools.getOrDefault("trenches", false)
    symmetry = a.flag("symmetry", "")
    teams =
      if "teams" in a.flags: a.intFlag("teams", 2)
      elif symmetry in ["rot90", "quadmirror"]: 4
      else: 2
  var overrides = MapGenOverrides(
    size: a.flag("size", ""),
    symmetry: symmetry,
    layout: a.flag("layout", ""),
    endzone: a.flag("endzone", ""),
    windows: -1,
    pits: (if trenches: -1 else: 0),
    pitDensity: -1,
  )
  var base = generateMapAttempt(seed, overrides, teams)
  let region = placementRegion(base)
  var params = defaultParams(style)
  if base.symmetry == symQuadMirror:
    ## Quad boards replicate every seed FOUR ways (vs the 2-team mirror's
    ## two) and spend part of the cover ceiling on the column anchors below,
    ## so the organic fill is thinned to keep the validated budget. Explicit
    ## --param overrides still win (applied after).
    case style
    of styleScatter: params.prob = params.prob * 0.62
    of styleCaves: params.fillProb = params.fillProb * 0.9
    of styleMaze: params.wallThick = 12; params.braid = 0.5
    of styleBsp: params.wallThick = 12; params.cell = 340
  applyParams(params, a.params)
  base.leftObstacles = generateShapes(style, seed xor styleSalt, region, params)
  if base.symmetry == symQuadMirror:
    base.leftObstacles.add quadColumnAnchors(base, region, seed)
  let spec = mapSpecJson(base)
  let outPath = a.flag("out", "")
  if outPath.len == 0:
    echo spec
  else:
    writeFile(outPath, spec)
    stderr.writeLine(
      &"generated {style} seed={seed} {base.width}x{base.height} " &
      &"{base.symmetry} shapes={base.leftObstacles.len} -> {outPath}")

proc cmdRender(a: Args) =
  if a.positionals.len == 0: fail("render needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    outPath = a.flag("out", a.positionals[0].changeFileExt("png"))
    diagnostics = a.bools.getOrDefault("diagnostics", false)
  var overlays = {overlayProtected, overlayPickups}
  if diagnostics:
    overlays.incl {overlaySightlines, overlayReachability, overlaySeedRegion}
  let options = MapRenderOptions(
    maxDimension: a.intFlag("max", 0),
    overlays: overlays,
    pickupKinds: {pickupMedKitActive, pickupMedKitCandidate})
  renderMap(gameMap, options).image.writeFile(outPath)
  stderr.writeLine(&"rendered {a.positionals[0]} -> {outPath}")

proc printMetrics(gameMap: CtfMap) =
  let diag = mapDiagnostics(gameMap, {})
  echo &"size:          {gameMap.width}x{gameMap.height} {gameMap.symmetry}"
  echo &"endzone:       {gameMap.endzone} radius={gameMap.endzoneRadius}"
  echo &"seed obstacles:{gameMap.leftObstacles.len}"
  echo &"full obstacles:{buildArenaObstacles(gameMap).len}"
  echo &"trenches:      {gameMap.trenches.len}"
  echo &"cover permille:{diag.coverPermille} (min {diag.minCoverPermille})"
  echo &"open sightlines:{diag.openSightlineRows.len} scanned rows"
  echo &"center reachable:{diag.centerReachable}"
  echo &"unreachable teams:{diag.unreachableTeams}"
  echo &"red home on open floor:{diag.redHomeOnOpenFloor}"

proc cmdValidate(a: Args) =
  if a.positionals.len == 0: fail("validate needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    reason = validateGeneratedMap(gameMap)
  printMetrics(gameMap)
  if reason.len == 0:
    echo "PASS"
    quit(0)
  else:
    echo "FAIL: " & reason
    quit(1)

proc cmdMetrics(a: Args) =
  if a.positionals.len == 0: fail("metrics needs a spec path")
  printMetrics(readSpec(a.positionals[0]))

proc cmdMirror(a: Args) =
  if a.positionals.len == 0: fail("mirror needs a spec path")
  let
    gameMap = readSpec(a.positionals[0])
    full = buildArenaObstacles(gameMap)
  echo &"seed set: {gameMap.leftObstacles.len} shapes"
  echo &"expanded: {full.len} shapes (symmetry {gameMap.symmetry})"

const usage = """
mapkit — author interesting-but-fair CTF maps

  mapkit generate --style bsp|caves|maze|scatter [--seed N] [--size ...]
                  [--symmetry mirror|rot180|rot90|quadmirror]
                  [--endzone column|disc|square]
                  [--teams 2|4] [--trenches] [--param k=v ...] [-o spec.json]
                  (rot90/quadmirror imply --teams 4; quadmirror boards are
                  rectangular)
  mapkit render   spec.json [-o out.png] [--diagnostics] [--max N]
  mapkit validate spec.json      # metrics + PASS/FAIL, non-zero exit on FAIL
  mapkit metrics  spec.json      # cover / sightlines / reachability
  mapkit mirror   spec.json      # seed-set vs expanded obstacle counts
"""

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help", "help"]:
    echo usage
    quit(0)
  let a = parseArgs(argv[1 .. ^1])
  try:
    case argv[0]
    of "generate": cmdGenerate(a)
    of "render": cmdRender(a)
    of "validate": cmdValidate(a)
    of "metrics": cmdMetrics(a)
    of "mirror": cmdMirror(a)
    else:
      stderr.writeLine("unknown command: " & argv[0])
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine("mapkit: " & e.msg)
    quit(2)
  except CtfError as e:
    stderr.writeLine("mapkit: " & e.msg)
    quit(1)
