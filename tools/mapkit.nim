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
  std/[os, strformat, strutils, tables],
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
  ## The seed region, inset only enough to keep a touch off the home border and
  ## stop short of the symmetry seam. It spans nearly the full HEIGHT on
  ## purpose: the validator rejects any unbroken lane, so cover must reach the
  ## top and bottom of the field. Bases need no wide margin here — the sim
  ## carves protected floor out of any shape that overlaps a flag ring, spawn
  ## pocket, or capture lane.
  ##
  ## The band is still a RECTANGLE while the board is a HEXAGON, so its four
  ## outer corners sit in the hull's permanent void. Shapes landing there are
  ## carved away by the border predicate — harmless, but it means a style's
  ## effective cover density inside the playfield runs below its nominal
  ## setting. Filling a hexagon with hexagonal structure is the Stage 2b
  ## generator epic, not this band.
  let
    sr = mapSeedRegion(base)
    vMargin = 2    ## the hull, not a straight edge, is what bounds the field
    hMargin = 40   ## a little off the home border (carve still protects bases)
    seam = 20      ## short of the center seam (where a shape meets its image)
  case base.symmetry
  of symMirrorHex, symRot180:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - 2 * vMargin))
  of symKlein4:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - vMargin - seam))
  of symRot120, symRot60:
    ## Unreachable: mapSeedRegion already raised for these.
    raise newException(
      CtfError, "Symmetry " & $base.symmetry & " has no rectangular seed band.")

const styleSalt = 0x9E3779B1  ## decorrelate the style stream from the map seed.

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
    ## The team count no longer follows from the symmetry name: `rot90` is
    ## gone (C4 is not a subgroup of D6) and the two 2-team hex groups are
    ## `mirrorHex` and `rot180`. Anything but 2 is refused by
    ## `generateMapAttempt` itself, with the reason, so ask it rather than
    ## guessing here.
    teams = a.intFlag("teams", 2)
  var overrides = MapGenOverrides(
    size: a.flag("size", ""),
    symmetry: symmetry,
    endzone: a.flag("endzone", ""),
    windows: -1,
    pits: (if trenches: -1 else: 0),
    pitDensity: -1,
  )
  var base = generateMapAttempt(seed, overrides, teams)
  let region = placementRegion(base)
  var params = defaultParams(style)
  applyParams(params, a.params)
  base.leftObstacles = generateShapes(style, seed xor styleSalt, region, params)
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
  ## The validator scans all THREE hexagon axes (0 / 60 / 120 deg); only the
  ## horizontal family is indexable by a row, so that is all this count can
  ## show. A slanted lane shows up in `reason` and nowhere else — printing this
  ## number as "open sightlines" would call a failing map clean.
  echo &"open lanes (0 deg rows):{diag.openSightlineRows.len} " &
    &"of {gameMap.sightlineMinSpan()}px min span"
  echo &"center reachable:{diag.centerReachable}"
  echo &"unreachable teams:{diag.unreachableTeams}"
  echo &"red home on open floor:{diag.redHomeOnOpenFloor}"
  if diag.reason.len > 0:
    echo &"first failure:{diag.reason}"

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

  mapkit generate --style bsp|caves|maze|scatter [--seed N]
                  [--size small|standard|large|huge|giant|colossal]
                  [--symmetry mirrorHex|rot180] [--endzone disc]
                  [--teams 2] [--trenches] [--param k=v ...] [-o spec.json]
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
