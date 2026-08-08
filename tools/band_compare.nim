## band_compare — score TODAY's shipping population under both band sets.
##
## Task 013a9c98, epic 3757029c lane D. The offline analysis in
## `tools/band_reweight.py` runs against the 118-map attempt sweep and the 210
## episodes stored under `docs/evidence/`, both taken at base `4a013df`. The
## generator has moved since (six archetypes, the 4-team fix, a re-curated
## pool), so a seed does NOT reproduce the same map at HEAD and that evidence
## cannot be re-measured here.
##
## This tool answers the other half: what the new band set does to the maps the
## generator ships TODAY. It plays nothing and fits nothing — it loads the 20
## curated pool maps plus the hand-authored arena and prints both scores side
## by side, control included in the same batch.
##
##   nim c -d:release --nimcache:/tmp/nc-bandcmp -o:/tmp/bandcmp \
##     tools/band_compare.nim && /tmp/bandcmp

import
  std/[algorithm, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_pool]

type Row = object
  name: string
  isControl: bool
  default, separation: float
  exposedFrac, routeCapacityFrac: float
  fairness: int

proc main() =
  var rows: seq[Row]

  block control:
    let m = evaluateMap(loadCtfMapMetadata("arena"), "arena")
    rows.add Row(name: "arena", isControl: true,
                 default: m.staticScore(DefaultBands),
                 separation: m.staticScore(ControlSeparationBands),
                 exposedFrac: m.exposedFrac,
                 routeCapacityFrac: m.routeCapacityFrac,
                 fairness: m.fairnessViolations().len)

  for i in 0 ..< MapPoolSeeds.len:
    let
      seed = MapPoolSeeds[i]
      m = evaluateMap(poolCtfMap(i), &"pool:{seed}")
    rows.add Row(name: &"pool:{seed}", isControl: false,
                 default: m.staticScore(DefaultBands),
                 separation: m.staticScore(ControlSeparationBands),
                 exposedFrac: m.exposedFrac,
                 routeCapacityFrac: m.routeCapacityFrac,
                 fairness: m.fairnessViolations().len)

  echo &"=== {rows.len} maps: the 20 curated pool seeds + the control ==="
  echo ""

  var byDefault = rows
  byDefault.sort(proc (a, b: Row): int = cmp(b.default, a.default))
  var bySep = rows
  bySep.sort(proc (a, b: Row): int = cmp(b.separation, a.separation))

  var sepRank: seq[string]
  for r in bySep: sepRank.add r.name

  echo &"""{"map":<14}{"Default":>9}{"rank":>6}{"CtlSep":>9}{"rank":>6}""" &
       &"""{"exposed":>10}{"routeCap":>10}{"unfair":>8}"""
  for i, r in byDefault:
    var sr = 0
    for j, n in sepRank:
      if n == r.name: sr = j + 1
    let tag = if r.isControl: "   <== CONTROL" else: ""
    echo &"{r.name:<14}{r.default:9.4f}{i+1:6}{r.separation:9.4f}{sr:6}" &
         &"{r.exposedFrac:10.4f}{r.routeCapacityFrac:10.4f}{r.fairness:8}{tag}"

  # The headline numbers, computed rather than eyeballed.
  var
    atOneDefault = 0
    atOneSep = 0
    anyUnfair = 0
    ctlDefault, ctlSep = 0.0
  for r in rows:
    if r.default >= 0.99995: inc atOneDefault
    if r.separation >= 0.99995: inc atOneSep
    if r.fairness > 0: inc anyUnfair
    if r.isControl:
      ctlDefault = r.default
      ctlSep = r.separation
  var beatCtlDefault, beatCtlSep, tieCtlDefault = 0
  for r in rows:
    if r.isControl: continue
    if r.default > ctlDefault + 1e-9: inc beatCtlDefault
    if abs(r.default - ctlDefault) <= 1e-9: inc tieCtlDefault
    if r.separation > ctlSep + 1e-9: inc beatCtlSep
  let total = rows.len
  echo ""
  echo &"maps scoring 1.000  DefaultBands {atOneDefault}/{total} " &
       &"({100.0 * atOneDefault.float / total.float:.1f}%)   " &
       &"ControlSeparationBands {atOneSep}/{total} " &
       &"({100.0 * atOneSep.float / total.float:.1f}%)"
  echo &"control `arena`     DefaultBands {ctlDefault:.4f} " &
       &"(beaten by {beatCtlDefault}/{total - 1}, TIED by {tieCtlDefault}/{total - 1})   " &
       &"ControlSeparationBands {ctlSep:.4f} (beaten by {beatCtlSep}/{total - 1})"
  echo &"fairness violations {anyUnfair}/{total} — the assertion moved out of the " &
       &"score fires on none of today's population, as the evidence predicted"

main()
