## pinch_probe — what the LENGTH-AWARE corridor rule says about real boards,
## measured BEFORE it is allowed anywhere near the validator.
##
## `arena.MinCorridorWidth` is 68 px, and the 68 px floor cannot be a flat
## minimum: a deliberate 30-45 px chokepoint would fail it, and the
## lane gates this generator builds ARE 30-45 px. `map_lanes.maxPinchRunPx`
## resolves that by length — a sub-corridor stretch is legal while its unbroken
## SIGHTLINE stays under what a player can clear alive at that width.
##
## This probe prints, per map, the numbers that decided whether wiring
## `corridorPinchFailures` into `collectMapDiagnostics` rejects anything it
## should not — and re-run, whether it still does not:
##
##   routeW    `routeWidthPx` — the widest sustained corridor the board
##             actually delivers. READ THIS FIRST: a board at 26 does not have
##             a chokepoint problem, it has no corridors.
##   gates     every gate found across the independent routes, with the subset
##             that is MANDATORY (sealing it costs a whole kill to detour) and
##             the subset sitting in the 30-45 px design band.
##   worst     the mandatory gate with the largest `exposedPx - allowedPx`.
##             Positive is a kill box and is the ONLY thing that fails a map.
##
## RULE 1: both hand-authored maps are controls and are always prepended. A
## rule that flags `arena` is wrong — it ships, it plays well, and its widest
## route is 36 px.
## RULE 7: no count without its fraction.
##
##   nim c -d:release --nimcache:/tmp/nc-pinch -r tools/pinch_probe.nim [lo] [hi]
import std/[os, strformat, strutils]
import ../src/ctf/[sim, map_lanes, sim_types]

const Controls = ["arena", "arena-large"]

proc anchorsOf(gameMap: CtfMap): seq[MapPoint] =
  for team in gameMap.teams():
    result.add gameMap.flagHome(team)

type BandTally = object
  ## What the 30-45 px DESIGN BAND actually does under the rule. The whole
  ## claim being tested is "a deliberate chokepoint passes because it is
  ## SHORT", and that claim is about this band specifically — so it is counted
  ## separately from every other gate rather than inferred from the map verdict.
  gates, inBand, inBandMandatory, inBandRejecting: int
  bandExposedPx, bandAllowedPx: int   ## summed, for a mean
  maps, mapsOk: int

proc note(t: var BandTally, r: PinchRun) =
  inc t.gates
  if not r.inDesignBand: return
  inc t.inBand
  t.bandExposedPx += r.exposedPx
  t.bandAllowedPx += r.allowedPx
  if r.mandatory:
    inc t.inBandMandatory
    if r.excessPx > 0: inc t.inBandRejecting

proc summarise(name: string, t: BandTally) =
  if t.inBand == 0:
    echo &"  {name}: no gate landed in the 30-45px design band " &
      &"(0/{t.gates} gates)"
    return
  echo &"  {name}: maps ok {t.mapsOk}/{t.maps}; " &
    &"design-band gates {t.inBand}/{t.gates}, of which " &
    &"{t.inBand - t.inBandRejecting}/{t.inBand} PASS " &
    &"({100.0 * float(t.inBand - t.inBandRejecting) / float(t.inBand):.1f}%); " &
    &"{t.inBandMandatory}/{t.inBand} are mandatory cuts and " &
    &"{t.inBandRejecting}/{max(1, t.inBandMandatory)} of THOSE overrun; " &
    &"mean band exposure {t.bandExposedPx div t.inBand}px " &
    &"vs {t.bandAllowedPx div t.inBand}px allowed"

proc report(label: string, gameMap: CtfMap, corridorMinPx: int, verbose: bool,
            tally: var BandTally, quiet = false) =
  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  var (maxWall, minWall) = rasterizeWallMasks(gameMap, obstacles)
  minWall.setLen(0)
  let
    anchors = anchorsOf(gameMap)
    audit = auditCorridorPinches(maxWall, w, h, anchors, corridorMinPx)
  var
    mandatory, inBand, bandFail, overrun = 0
    worst = low(int)
    worstDesc = "none"
  inc tally.maps
  if audit.ok: inc tally.mapsOk
  for r in audit.gates:
    tally.note r
    if r.mandatory: inc mandatory
    if r.inDesignBand: inc inBand
    if r.mandatory and r.excessPx > 0:
      inc overrun
      if r.inDesignBand: inc bandFail
    if r.mandatory and r.excessPx > worst:
      worst = r.excessPx
      worstDesc = &"({r.x},{r.y}) {r.minWidthPx}px wide, exposed {r.exposedPx}" &
        &"/{r.allowedPx} allowed"
  let g = audit.gates.len
  if quiet: return
  echo &"{label:<22} routeW={audit.routeWidthPx:>4} passes={audit.routePasses} " &
    &"gates={g:>3} mandatory={mandatory}/{g} inBand30-45={inBand}/{g} " &
    &"overrun={overrun}/{max(1, mandatory)} " &
    &"worstExcess={(if worst == low(int): 0 else: worst):>5} " &
    &"ok={audit.ok}"
  if verbose or not audit.ok:
    echo &"    worst mandatory gate: {worstDesc}"
    if bandFail > 0:
      echo &"    !! {bandFail}/{inBand} design-band (30-45px) gates OVERRUN"
    if not audit.ok:
      echo "    REASON: " & audit.reason
  if verbose:
    for i, r in audit.gates:
      if i >= 8: break
      echo &"      gate pass={r.pass} w={r.minWidthPx} arc={r.arcLenPx} " &
        &"exposed={r.exposedPx} allowed={r.allowedPx} " &
        &"excess={r.excessPx} mandatory={r.mandatory} band={r.inDesignBand}"

when isMainModule:
  let
    lo = if paramCount() >= 1: paramStr(1).parseInt else: 1000
    hi = if paramCount() >= 2: paramStr(2).parseInt else: 1019
    corridorMinPx =
      if paramCount() >= 3: paramStr(3).parseInt else: RecommendedCorridorWidthPx
    verbose = existsEnv("PINCH_VERBOSE")
    quiet = existsEnv("PINCH_QUIET")
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  echo &"corridorMinPx={corridorMinPx}  " &
    &"maxPinchRunPx: 30px->{maxPinchRunPx(30)} 45px->{maxPinchRunPx(45)} " &
    &"68px->{maxPinchRunPx(68)}"
  echo "--- CONTROLS (hand-authored, must never fail) ---"
  var controlTally: BandTally
  for name in Controls:
    report(name, loadCtfMapMetadata(name), corridorMinPx, verbose, controlTally)
  summarise("controls", controlTally)
  for teams in [2, 4]:
    echo &"--- generated, {teams} teams, seeds {lo}..{hi} ---"
    var
      tally: BandTally
      noCorridor = 0
    for seed in lo .. hi:
      let gameMap = generateMapAttempt(seed, overrides, teams)
      var one: BandTally
      report(&"gen:{seed}/{teams}t", gameMap, corridorMinPx, verbose, one, quiet)
      let (mw, _) = rasterizeWallMasks(gameMap, buildArenaObstacles(gameMap))
      if auditCorridorPinches(mw, gameMap.width, gameMap.height,
          anchorsOf(gameMap), corridorMinPx).routeWidthPx < corridorMinPx:
        inc noCorridor
      tally.gates += one.gates
      tally.inBand += one.inBand
      tally.inBandMandatory += one.inBandMandatory
      tally.inBandRejecting += one.inBandRejecting
      tally.bandExposedPx += one.bandExposedPx
      tally.bandAllowedPx += one.bandAllowedPx
      tally.maps += one.maps
      tally.mapsOk += one.mapsOk
    echo &"  {teams} teams: RAW first-draw pinch-rule pass " &
      &"{tally.mapsOk}/{tally.maps} " &
      &"({100.0 * float(tally.mapsOk) / float(tally.maps):.1f}%), " &
      &"routeWidth below the {corridorMinPx}px floor on {noCorridor}/{tally.maps}"
    summarise(&"{teams} teams", tally)
