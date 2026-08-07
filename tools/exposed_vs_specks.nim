## exposed_vs_specks — is `exposedFrac` measuring COVER, or measuring SPECKS?
##
## Task 013a9c98, epic 3757029c lane D. This exists because of one number the
## epic owner measured on `maxwell/mapgen-rebuild` @ cd495cc and one constant
## in this repo, and they do not sit comfortably together.
##
##   the measurement  74.5% (2 teams) and 88.4% (4 teams) of every generated
##                    shape is SUB-BODY, under 34 px — below one drawn cog, so
##                    it cannot hide a player. The hand-authored arena has 35
##                    shapes, 98.2% of its footprint in a single 34-68 px
##                    bucket and nothing at all above 68 px.
##
##   the constant     `EnclosureReachPx = 120`. `exposedFrac` counts, per open
##                    pixel, how many of 8 directions are blocked by wall
##                    WITHIN 120 px. A 4 px speck 100 px away blocks its
##                    direction exactly as hard as a 60 px one-body shape does.
##
## So the band cannot distinguish cover you can stand behind from grit that
## merely interrupts a ray, and the population it grades is mostly grit. That
## is a hypothesis about a metric, and this tool is the test: score today's 20
## curated pool maps on `exposedFrac` and on their sub-body content in the same
## batch, control included, and rank-correlate the two.
##
## If exposedFrac tracks SPECK COUNT, then cutting the band at the control (as
## `ControlSeparationBands` does) buys discrimination over the wrong variable
## and the re-weight is measuring grit. Printed either way.
##
##   nim c -d:release --nimcache:/tmp/nc-specks -o:/tmp/specks \
##     tools/exposed_vs_specks.nim && /tmp/specks

import
  std/[algorithm, math, strformat],
  ../src/ctf/[sim, arena, map_metrics, map_pool]

const
  SubBodyPx = 34
    ## One drawn cog body. Below this a shape cannot hide anyone — the same
    ## edge the owner's `pebble_probe` uses, kept identical on purpose so the
    ## two tables can be read against each other.

type Row = object
  label: string
  isControl: bool
  exposedFrac: float
  shapes, specks: int
  speckArea, totalArea: int

proc profile(gameMap: CtfMap, label: string, isControl: bool): Row =
  result.label = label
  result.isControl = isControl
  for shape in gameMap.leftObstacles:
    let
      box = shapeAsRect(shape)
      area = box.w * box.h
    inc result.shapes
    result.totalArea += area
    if max(box.w, box.h) < SubBodyPx:
      inc result.specks
      result.speckArea += area
  result.exposedFrac = evaluateMap(gameMap, label).exposedFrac

proc spearman(a, b: seq[float]): float =
  ## Rank correlation, average ranks on ties. Small n, so this is written out
  ## rather than pulled in.
  proc ranks(v: seq[float]): seq[float] =
    var idx = newSeq[int](v.len)
    for i in 0 ..< v.len: idx[i] = i
    idx.sort(proc (x, y: int): int = cmp(v[x], v[y]))
    result = newSeq[float](v.len)
    var i = 0
    while i < idx.len:
      var j = i
      while j + 1 < idx.len and v[idx[j + 1]] == v[idx[i]]: inc j
      let avg = (i + j).float / 2.0 + 1.0
      for k in i .. j: result[idx[k]] = avg
      i = j + 1
  let
    ra = ranks(a)
    rb = ranks(b)
    n = a.len.float
  var ma, mb = 0.0
  for x in ra: ma += x
  for x in rb: mb += x
  ma /= n
  mb /= n
  var num, da, db = 0.0
  for i in 0 ..< a.len:
    num += (ra[i] - ma) * (rb[i] - mb)
    da += (ra[i] - ma) * (ra[i] - ma)
    db += (rb[i] - mb) * (rb[i] - mb)
  if da <= 0.0 or db <= 0.0: return 0.0
  num / sqrt(da * db)

proc main() =
  var rows = @[profile(loadCtfMapMetadata("arena"), "arena", true)]
  for i in 0 ..< MapPoolSeeds.len:
    rows.add profile(poolCtfMap(i), &"pool:{MapPoolSeeds[i]}", false)

  echo &"=== exposedFrac vs sub-body content, {rows.len} maps, control in batch ==="
  echo ""
  echo &"{\"map\":<14}{\"exposed\":>9}{\"shapes\":>8}{\"specks\":>8}" &
    &"{\"speck %ct\":>10}{\"speck %ft\":>10}"
  var byExposed = rows
  byExposed.sort(proc (a, b: Row): int = cmp(a.exposedFrac, b.exposedFrac))
  for r in byExposed:
    # Never a count without its fraction: the count share is what the eye sees,
    # the footprint share is what spends the fill budget, and they disagree.
    let
      cShare = if r.shapes > 0: 100.0 * r.specks.float / r.shapes.float else: 0.0
      aShare = if r.totalArea > 0: 100.0 * r.speckArea.float / r.totalArea.float
               else: 0.0
    echo &"{r.label:<14}{r.exposedFrac:>9.4f}{r.shapes:>8}{r.specks:>8}" &
      &"{cShare:>9.1f}%{aShare:>9.1f}%" &
      (if r.isControl: "   <== CONTROL" else: "")

  # The test. Generated maps only: the control is one point and cannot join a
  # correlation, and including it would let a single hand-authored outlier
  # manufacture the result.
  var ex, sp, spa: seq[float]
  for r in rows:
    if r.isControl: continue
    ex.add r.exposedFrac
    sp.add r.specks.float
    spa.add (if r.totalArea > 0: r.speckArea.float / r.totalArea.float else: 0.0)

  echo ""
  echo &"n = {ex.len} generated maps (the control is excluded — one point " &
    "cannot join a correlation)"
  echo &"  rho(exposedFrac, speck COUNT)     = {spearman(ex, sp):+.3f}"
  echo &"  rho(exposedFrac, speck FOOTPRINT) = {spearman(ex, spa):+.3f}"
  echo ""
  echo "Read the SIGN. exposedFrac is a cap — LOWER is scored better. A " &
    "NEGATIVE rho"
  echo "means more specks buys a better exposedFrac, i.e. the band pays for " &
    "grit."

main()
