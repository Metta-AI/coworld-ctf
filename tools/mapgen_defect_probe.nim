## mapgen_defect_probe — measures whether each feature a map generator PLACES
## actually does its job, and how much of what it finds the SHIPPING
## validators never look at.
##
## REBUILT 2026-08-31 against current main from the dead maxwell/mapgen-audit
## branch (whose probe read generator internals that no longer exist — see
## tools/probekit.nim's DROPPED CHECKS block for what could not be honestly
## re-derived). All measurement lives in probekit; this file is sweep + report.
##
## THE EARN-THE-SWITCH RULE this instrument exists to enforce: no candidate
## generator's maps replace the incumbent's on static claims alone. The static
## probe (this file) finds defects and validator blind spots; the played half
## (tools/br_outcome_probe.nim + tools/mapgen_play_gate.py) decides whether
## any static score even TRACKS play before that score is allowed to select
## maps. Two sibling branches proved a static score can silently fail to rank
## play (rho ~ +0.11, CI crossing zero); that meta-gate is part of the
## instrument, not an optional extra.
##
## CONTROL-ANCHORED, NO STORED NUMBERS: controls are measured under the
## identical protocol on every run — `arena` + `arena-large` for the CTF
## class, and for the BR class the shipping baked incumbent (pass its spec
## with --spec; the paintbot manifests carry br-gen-1339 inline). Nothing
## here compares against a saved number from a previous engine build.
##
## VALIDATOR BLIND-SPOT ACCOUNTING measures the probe's findings against TWO
## shipping validators:
##   * the CTF validator (arena.nim collectMapDiagnostics): cover permille
##     floor/ceiling, minWall sightline rows, flag-home stand + reachability,
##     center reachability, compact-endzone gates. NOTHING else.
##   * brmapkit's BR suite (tools/brmapkit.nim validateBr): connectivity,
##     per-spawn cover, cover permille, distance-to-cover, item coverage /
##     gradient / walk-distance fairness, poi loot, keystone, terrain/theme,
##     interior connectivity, room variety, full accessibility, burrow
##     (thin/dangling/enclosure/mass-unity), gate-mouth significance.
##   A probe finding family is BLIND to a validator when no check in that
##   validator's list can flag it even in principle. The blind-spot % is
##   (findings in blind families) / (all findings), per validator.
##
## Usage:
##   nim r -d:release tools/mapgen_defect_probe.nim --seeds 1000-1099
##   ... --teams 4                 4-team generated sweep
##   ... --spec /tmp/br-gen-1339.mapspec.json   probe a baked spec (BR class)
##   ... --rows w.tsv --maps m.tsv  per-row TSV dumps
##   ... --worst 12                 print the worst windows
##   ... --counterfactual           measure solid obstacles as if glass (3x)

import
  std/[algorithm, os, strformat, strutils, tables],
  ../src/ctf/sim,
  probekit

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

type Args = object
  flags: Table[string, string]
  multi: Table[string, seq[string]]
  bools: seq[string]

proc parseArgs(argv: seq[string]): Args =
  result.flags = initTable[string, string]()
  result.multi = initTable[string, seq[string]]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags[kv[0]] = kv[1]
        result.multi.mgetOrPut(kv[0], @[]).add kv[1]
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--"):
        result.flags[body] = argv[i + 1]
        result.multi.mgetOrPut(body, @[]).add argv[i + 1]
        inc i
      else:
        result.bools.add body
    inc i

proc flag(a: Args, key, default: string): string =
  a.flags.getOrDefault(key, default)

# ---------------------------------------------------------------------------
# Validator blind-spot accounting
# ---------------------------------------------------------------------------

type FindingFamily = enum
  ## Each family notes which shipping validator could flag it AT ALL.
  famWindowQuality    ## CTF: BLIND (scans minWall: glass = wall, quality
                      ## never judged). brmapkit: BLIND (places no glass).
  famGlassOpenedRow   ## a sightline row only glass holds shut. CTF: BLIND —
                      ## this family measures ITS OWN scan's mask error.
                      ## brmapkit: n/a (no sightline invariant, no glass).
  famTrenchPlacement  ## CTF: BLIND. brmapkit: BLIND (no trench checks).
  famPickupPlacement  ## CTF: BLIND. brmapkit: CHECKED (item coverage +
                      ## gradient + walk-distance fairness).
  famRespawnGeometry  ## CTF: BLIND (validates gates, never the region's
                      ## defensive geometry). brmapkit: n/a (flagless).
  famSpawnClearance   ## BR spawn point stone/clearance/unreachable.
                      ## CTF: BLIND (never reads spawnPoints). brmapkit:
                      ## CHECKED (full accessibility + per-spawn cover).
  famSpawnEquity      ## BR per-spawn item-walk spread. CTF: BLIND.
                      ## brmapkit: CHECKED (item fairness gate).

const
  CtfValidatorSees: array[FindingFamily, bool] = [
    false, false, false, false, false, false, false]
  BrmapkitSees: array[FindingFamily, bool] = [
    false, false, false, true, false, true, true]

type Finding = object
  family: FindingFamily
  mapName: string
  detail: string

proc collectFindings(m: MapRow): seq[Finding] =
  ## One finding per concrete defect instance the probe flagged. Families
  ## with graded output (window classes) count only the classes that mean
  ## "this feature cannot do its job" — dead, inert, decor.
  template add(fam: FindingFamily, d: string) =
    result.add Finding(family: fam, mapName: m.name, detail: d)
  for _ in 0 ..< m.winDeadN: add(famWindowQuality, "dead pane")
  for _ in 0 ..< m.winInertN: add(famWindowQuality, "inert pane")
  for _ in 0 ..< m.winDecorN: add(famWindowQuality, "decor pane")
  for _ in 0 ..< m.glassOnlyRows: add(famGlassOpenedRow, "glass-only row")
  for _ in 0 ..< m.trenchInEndzone: add(famTrenchPlacement, "trench in endzone")
  for _ in 0 ..< m.grenadeBroken: add(famPickupPlacement, "grenade in stone")
  for _ in 0 ..< m.grenadeUnreachable:
    add(famPickupPlacement, "grenade unreachable")
  ## NOTE map_eval Rule 1 in action: "one stance covers both med-kits" was a
  ## candidate finding, but the hand-authored CONTROL exhibits it on 2/2 maps
  ## (measured 2026-08-31) — a measurement that flags the control is wrong, so
  ## it stays a descriptive stat in the PICKUPS block and is NOT a defect.
  for s in m.spawnRows:
    if s.inObstacleShape:
      add(famSpawnClearance, "spawn authored inside an obstacle (carve repairs it)")
    if not s.onOpenFloor: add(famSpawnClearance, "spawn point in stone")
    elif not s.hasClearance: add(famSpawnClearance, "spawn point cramped")
    if not s.reachable: add(famSpawnClearance, "spawn point unreachable")
  if m.spawnRows.len > 1:
    ## Equity findings: a spawn whose walk to any pool is > 2x the median
    ## spawn's walk. The 2x bar is relative to THIS map's own distribution
    ## (control-anchored: no absolute stored number).
    for (name, get) in [
        ("shield", proc(s: SpawnPointRow): int = s.shieldWalk),
        ("spray", proc(s: SpawnPointRow): int = s.sprayWalk),
        ("grenade", proc(s: SpawnPointRow): int = s.grenadeWalk),
        ("medkit", proc(s: SpawnPointRow): int = s.medKitWalk)]:
      var ds: seq[int]
      for s in m.spawnRows:
        if get(s) >= 0: ds.add get(s)
      if ds.len < m.spawnRows.len div 2: continue
      let med = medianOf(ds)
      if med <= 0: continue
      for s in m.spawnRows:
        if get(s) > 2 * med:
          add(famSpawnEquity, name & " walk > 2x median for spawn " & $s.idx)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

proc report(rows: seq[MapRow], wins: seq[WindowRow], title: string) =
  if rows.len == 0: return
  echo ""
  echo "=== ", title, "  (", rows.len, " maps, ", wins.len, " windows) ==="
  var tw, td, ti, tdec, tsh, tu = 0
  var minSides: seq[float]
  for r in wins:
    inc tw
    case r.cls
    of winDead: inc td
    of winInert: inc ti
    of winDecor: inc tdec
    of winShallow: inc tsh
    of winUseful: inc tu
    minSides.add float(r.minSide)
  if tw > 0:
    echo &"WINDOWS  n={tw}"
    echo &"  dead   (0 glass px)      {td:>5}  {pct(td, tw)}"
    echo &"  inert  (<{StandDepthPx}px a side)    {ti:>5}  {pct(ti, tw)}"
    echo &"  decor  (<{DecorativeDepthPx}px a side)   {tdec:>5}  {pct(tdec, tw)}"
    echo &"  shallow(<{UsefulDepthPx}px a side)   {tsh:>5}  {pct(tsh, tw)}"
    echo &"  USEFUL (>={UsefulDepthPx}px both)    {tu:>5}  {pct(tu, tw)}"
    echo &"  min-side depth px  p10={percentile(minSides, 0.1):.0f} " &
      &"p50={percentile(minSides, 0.5):.0f} " &
      &"p90={percentile(minSides, 0.9):.0f} mean={meanOf(minSides):.0f}"
    var fg, unreach, bord = 0
    for r in wins:
      if r.facesGlass: inc fg
      if not (r.reachA and r.reachB): inc unreach
      if r.borderFlush: inc bord
    echo &"  faces another pane       {fg:>5}  {pct(fg, tw)}"
    echo &"  a side is UNREACHABLE    {unreach:>5}  {pct(unreach, tw)}"
    echo &"  flush to the border      {bord:>5}  {pct(bord, tw)}"
  else:
    echo "WINDOWS  n=0 (this class places no glass)"

  var scanRows, valOpen, visOpen, glassRows, mapsWithGlassHole = 0
  var soleTot = 0
  var trMaps, trTotal, trEz, trCol = 0
  var trNear, trRun: seq[float]
  var kitPair: seq[float]
  var kitCover, kitLos, kitMaps = 0
  var grenMaps, grenBroken, grenPoints, grenUnreach = 0
  var shieldNudge, sprayNudge, kitNudge: seq[float]
  var respFrac, respMean, capFrac, lattice: seq[float]
  var invalidMaps = 0
  for m in rows:
    if not m.valid: inc invalidMaps
    scanRows += m.scanRows
    valOpen += m.validatorOpenRows
    visOpen += m.visionOpenRows
    glassRows += m.glassOnlyRows
    if m.glassOnlyRows > 0: inc mapsWithGlassHole
    soleTot += m.soleBlockerShapes
    if m.trenches > 0: inc trMaps
    trTotal += m.trenches
    trEz += m.trenchInEndzone
    trCol += m.trenchOnColumnX
    for v in m.trenchNearObstaclePx: trNear.add float(v)
    for v in m.trenchOpenRunPx: trRun.add float(v)
    if m.medKits == 2:
      inc kitMaps
      kitPair.add float(m.medKitPairPx)
      if m.medKitOneCovers: inc kitCover
      if m.medKitPairLos: inc kitLos
    for v in m.medKitNudgePx: kitNudge.add float(v)
    grenPoints += m.grenadePoints
    grenBroken += m.grenadeBroken
    grenUnreach += m.grenadeUnreachable
    if m.grenadeBroken > 0 or m.grenadeUnreachable > 0: inc grenMaps
    for v in m.shieldNudgePx: shieldNudge.add float(v)
    for v in m.sprayNudgePx: sprayNudge.add float(v)
    if m.respawnAreaPx > 0:
      respFrac.add float(m.respawnWithin150) / float(m.respawnAreaPx)
      respMean.add m.respawnMeanDistPx
      capFrac.add m.captureAreaFrac
    lattice.add m.latticeFrac

  echo &"MAPS the shipping validator rejects  {invalidMaps:>5}  " &
    pct(invalidMaps, rows.len)
  if scanRows > 0:
    echo ""
    echo &"SIGHTLINE ROWS (validator's own 4px scan)  n={scanRows}"
    echo &"  open to the VALIDATOR (minWall)  {valOpen:>5}  {pct(valOpen, scanRows)}"
    echo &"  open to VISION (glass see-thru)  {visOpen:>5}  {pct(visOpen, scanRows)}"
    echo &"  rows the glass silently opens    {glassRows:>5}  {pct(glassRows, scanRows)}"
    echo &"  maps with >=1 such row           {mapsWithGlassHole:>5}  " &
      pct(mapsWithGlassHole, rows.len)
    echo &"  obstacles SOLELY holding a row   {soleTot:>5}  " &
      "(phase attribution dropped: provenance anchors gone on main)"

  echo ""
  echo &"TRENCHES  maps with >=1: {trMaps}/{rows.len} ({pct(trMaps, rows.len)})" &
    &"  total {trTotal}"
  if trNear.len > 0:
    echo &"  px to nearest wall  p10={percentile(trNear, 0.1):.0f} " &
      &"p50={percentile(trNear, 0.5):.0f} p90={percentile(trNear, 0.9):.0f}"
    echo &"  horizontal open run p10={percentile(trRun, 0.1):.0f} " &
      &"p50={percentile(trRun, 0.5):.0f} p90={percentile(trRun, 0.9):.0f}"
    echo &"  inside protected endzone floor  {trEz}  {pct(trEz, trTotal)}"
    echo &"  on an obstacle's own x line     {trCol}  {pct(trCol, trTotal)}"

  echo ""
  echo &"PICKUPS"
  if kitMaps > 0:
    echo &"  med-kit pair separation px  p10={percentile(kitPair, 0.1):.0f} " &
      &"p50={percentile(kitPair, 0.5):.0f} p90={percentile(kitPair, 0.9):.0f}"
    echo &"  one stance sees & covers BOTH    {kitCover:>5}  {pct(kitCover, kitMaps)}"
    echo &"  the two kits see each other      {kitLos:>5}  {pct(kitLos, kitMaps)}"
  echo &"  grenade points broken/unreachable {grenBroken}/{grenPoints} " &
    &"({pct(grenBroken, grenPoints)}) broken, {grenUnreach} unreachable; " &
    &"maps affected {grenMaps}/{rows.len} ({pct(grenMaps, rows.len)})"
  if shieldNudge.len > 0:
    echo &"  shield nudge px  p50={percentile(shieldNudge, 0.5):.0f} " &
      &"p90={percentile(shieldNudge, 0.9):.0f} max={percentile(shieldNudge, 1.0):.0f}"
  if sprayNudge.len > 0:
    echo &"  spray  nudge px  p50={percentile(sprayNudge, 0.5):.0f} " &
      &"p90={percentile(sprayNudge, 0.9):.0f} max={percentile(sprayNudge, 1.0):.0f}"
  if kitNudge.len > 0:
    echo &"  medkit nudge px  p50={percentile(kitNudge, 0.5):.0f} " &
      &"p90={percentile(kitNudge, 0.9):.0f} max={percentile(kitNudge, 1.0):.0f}"

  if respMean.len > 0:
    echo ""
    echo &"RESPAWN REGION vs THE STAND IT DEFENDS"
    echo &"  respawn area as map fraction p50={percentile(capFrac, 0.5) * 100:.2f}%"
    echo &"  share within 150px of the stand " &
      &"p50={percentile(respFrac, 0.5) * 100:.1f}% " &
      &"p90={percentile(respFrac, 0.9) * 100:.1f}%"
    echo &"  mean respawn distance to the stand px " &
      &"p50={percentile(respMean, 0.5):.0f}"

  var cand, candUse = 0
  for m in rows:
    cand += m.candidates
    candUse += m.candidatesUseful
  if cand > 0:
    echo ""
    echo &"COUNTERFACTUAL: could a smarter pane selector have done better?"
    echo &"  solid obstacles measured as if glass   {cand}"
    echo &"  ...that would clear the useful bar     {candUse}  " &
      pct(candUse, cand) & "  <- lattice ceiling (candidate set is ALL solid"
    echo "     shapes; phase provenance dropped, so this reads slightly HIGH)"

  echo ""
  echo &"ARCHITECTURE"
  echo &"  lattice frac (1 - distinct obstacle x / obstacles) " &
    &"p10={percentile(lattice, 0.1):.2f} p50={percentile(lattice, 0.5):.2f} " &
    &"p90={percentile(lattice, 0.9):.2f}"

  # --- BR spawn geometry ---------------------------------------------------
  var spawnMaps = 0
  var stone, cramped, unreach2, totalSpawns = 0
  var nn, cdist: seq[float]
  for m in rows:
    if m.spawnRows.len == 0: continue
    inc spawnMaps
    for s in m.spawnRows:
      inc totalSpawns
      if s.inObstacleShape: inc stone
      elif not s.hasClearance: inc cramped
      if not s.reachable: inc unreach2
      nn.add float(s.nnDistPx)
      cdist.add float(s.centerDistPx)
  if spawnMaps > 0:
    echo ""
    echo &"BR SPAWN GEOMETRY  ({spawnMaps}/{rows.len} maps author spawnPoints; " &
      &"{totalSpawns} points)"
    echo &"  authored inside an obstacle {stone:>2}  {pct(stone, totalSpawns)}" &
      "  <- the rasterizer carves a pocket through it: silent repair"
    echo &"  cramped (<{MinCorridorWidth}px box)     {cramped:>5}  {pct(cramped, totalSpawns)}"
    echo &"  unreachable              {unreach2:>5}  {pct(unreach2, totalSpawns)}"
    echo &"  nearest-neighbour px  p10={percentile(nn, 0.1):.0f} " &
      &"p50={percentile(nn, 0.5):.0f} p90={percentile(nn, 0.9):.0f}"
    echo &"  dist-to-map-center px p10={percentile(cdist, 0.1):.0f} " &
      &"p50={percentile(cdist, 0.5):.0f} p90={percentile(cdist, 0.9):.0f}" &
      "   <- static half of ring bias; the played half needs episodes"
    for m in rows:
      if m.spawnRows.len == 0: continue
      for (nm, get) in [
          ("shield", proc(s: SpawnPointRow): int = s.shieldWalk),
          ("spray", proc(s: SpawnPointRow): int = s.sprayWalk),
          ("grenade", proc(s: SpawnPointRow): int = s.grenadeWalk),
          ("medkit", proc(s: SpawnPointRow): int = s.medKitWalk)]:
        var ds: seq[float]
        for s in m.spawnRows:
          if get(s) >= 0: ds.add float(get(s))
        if ds.len == 0: continue
        echo &"  {m.name} {nm:<8} walk-to-nearest p10={percentile(ds, 0.1):.0f} " &
          &"p50={percentile(ds, 0.5):.0f} p90={percentile(ds, 0.9):.0f} " &
          &"max={percentile(ds, 1.0):.0f}  (n={ds.len} spawns)"

  # --- validator blind spots ----------------------------------------------
  var all: seq[Finding]
  for m in rows:
    all.add collectFindings(m)
  if all.len > 0:
    var ctfBlind, brBlind = 0
    var byFam = initCountTable[FindingFamily]()
    for f in all:
      byFam.inc f.family
      if not CtfValidatorSees[f.family]: inc ctfBlind
      if not BrmapkitSees[f.family]: inc brBlind
    echo ""
    echo &"VALIDATOR BLIND SPOTS  ({all.len} probe findings in this class)"
    for fam in FindingFamily:
      if byFam.getOrDefault(fam) == 0: continue
      let mark =
        (if CtfValidatorSees[fam]: "ctf:seen " else: "ctf:BLIND ") &
        (if BrmapkitSees[fam]: "brmapkit:seen" else: "brmapkit:BLIND")
      echo &"  {fam:<20} {byFam.getOrDefault(fam):>5}  {mark}"
    echo &"  blind to the CTF validator       {ctfBlind:>5}  {pct(ctfBlind, all.len)}"
    echo &"  blind to brmapkit's BR suite     {brBlind:>5}  {pct(brBlind, all.len)}"
    echo "  (a family is 'seen' when ANY check in that validator could flag"
    echo "   it in principle, the most conservative blind-spot reading)"

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

proc main() =
  let a = parseArgs(commandLineParams())
  let teams = a.flag("teams", "2").parseInt
  let seedSpec = a.flag("seeds", "")
  let counterfactual = "counterfactual" in a.bools
  let specs = a.multi.getOrDefault("spec", @[])

  var mapRows: seq[MapRow]
  var winRows: seq[WindowRow]

  ## Rule 1: the CONTROL is prepended, never optional. CTF class controls
  ## are the hand-authored maps; the BR class control is the shipping baked
  ## incumbent, passed FIRST via --spec.
  if seedSpec.len > 0:
    for ctrl in ["arena", "arena-large"]:
      let g = loadCtfMapMetadata(ctrl)
      let ctx = buildCtx(g)
      mapRows.add measureMap(g, ctrl, -1, counterfactual)
      winRows.add ctx.windowRows(ctrl, -1)

  for specPath in specs:
    let g = mapFromSpecJson(readFile(specPath))
    let label = if g.name.len > 0: g.name else: specPath.extractFilename
    let ctx = buildCtx(g)
    mapRows.add measureMap(g, label, g.genSeed, counterfactual)
    winRows.add ctx.windowRows(label, g.genSeed)
    stderr.writeLine(&"  spec {label} measured")

  if seedSpec.len > 0:
    var lo, hi: int
    if seedSpec.contains('-'):
      let parts = seedSpec.split('-', 1)
      lo = parts[0].parseInt
      hi = parts[1].parseInt
    else:
      lo = seedSpec.parseInt
      hi = lo
    var overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
    if a.flag("size", "").len > 0: overrides.size = a.flag("size", "")
    var generated = 0
    for seed in lo .. hi:
      var g: CtfMap
      try:
        g = generateCtfMap(seed, overrides, teams)
      except CatchableError as e:
        stderr.writeLine(&"seed {seed}: {e.msg}")
        continue
      inc generated
      let label = &"gen:{seed}"
      let ctx = buildCtx(g)
      mapRows.add measureMap(g, label, seed, counterfactual)
      winRows.add ctx.windowRows(label, seed)
      if generated mod 25 == 0:
        stderr.writeLine(&"  ... {generated} maps")

  # --- optional TSV dumps --------------------------------------------------
  if a.flag("rows", "").len > 0:
    var s = "map\tseed\tteams\tsize\tsym\tkind\tglassPx\taxis\tdepthA\t" &
      "depthB\tminSide\tthrough\treachA\treachB\tborder\tfacesGlass\t" &
      "class\tcx\tcy\n"
    for r in winRows:
      s.add &"{r.mapName}\t{r.seed}\t{r.teams}\t{r.size}\t{r.sym}\t{r.kind}\t" &
        &"{r.glassPx}\t{r.axis}\t{r.depthA}\t{r.depthB}\t{r.minSide}\t" &
        &"{r.through}\t{r.reachA}\t{r.reachB}\t{r.borderFlush}\t" &
        &"{r.facesGlass}\t{r.cls}\t{r.cx}\t{r.cy}\n"
    writeFile(a.flag("rows", ""), s)
  if a.flag("maps", "").len > 0:
    var s = "map\tseed\tteams\tsize\tsym\tlayout\tw\th\tvalid\treason\t" &
      "windows\tdead\tinert\tdecor\tshallow\tuseful\tminSideMed\t" &
      "scanRows\tvalOpen\tvisOpen\tglassOnly\tsoleBlockers\t" &
      "trenches\ttrenchInEz\tmedKitPairPx\tmedKitLos\tmedKitOneCovers\t" &
      "grenadePts\tgrenadeBroken\tgrenadeUnreach\trespawnAreaPx\t" &
      "respawnNear150\trespawnMeanDist\tobstacles\tdistinctXs\tlatticeFrac\t" &
      "candidates\tcandUseful\tspawnPts\tspawnStone\tspawnCramped\t" &
      "spawnUnreach\n"
    for m in mapRows:
      var spStone, spCramped, spUnreach = 0
      for sp in m.spawnRows:
        if not sp.onOpenFloor: inc spStone
        elif not sp.hasClearance: inc spCramped
        if not sp.reachable: inc spUnreach
      s.add &"{m.name}\t{m.seed}\t{m.teams}\t{m.size}\t{m.sym}\t{m.layout}\t" &
        &"{m.w}\t{m.h}\t{m.valid}\t{m.validReason}\t{m.windows}\t" &
        &"{m.winDeadN}\t{m.winInertN}\t{m.winDecorN}\t{m.winShallowN}\t" &
        &"{m.winUsefulN}\t{m.winMinSideMedian}\t{m.scanRows}\t" &
        &"{m.validatorOpenRows}\t{m.visionOpenRows}\t{m.glassOnlyRows}\t" &
        &"{m.soleBlockerShapes}\t{m.trenches}\t{m.trenchInEndzone}\t" &
        &"{m.medKitPairPx}\t{m.medKitPairLos}\t{m.medKitOneCovers}\t" &
        &"{m.grenadePoints}\t{m.grenadeBroken}\t{m.grenadeUnreachable}\t" &
        &"{m.respawnAreaPx}\t{m.respawnWithin150}\t" &
        &"{m.respawnMeanDistPx:.0f}\t{m.obstacleCount}\t" &
        &"{m.distinctColumnXs}\t{m.latticeFrac:.3f}\t{m.candidates}\t" &
        &"{m.candidatesUseful}\t{m.spawnRows.len}\t{spStone}\t{spCramped}\t" &
        &"{spUnreach}\n"
    writeFile(a.flag("maps", ""), s)

  # --- report --------------------------------------------------------------
  var ctrlRows, genRows: seq[MapRow]
  var ctrlWins, genWins: seq[WindowRow]
  var specRows: seq[MapRow]
  var specWins: seq[WindowRow]
  for m in mapRows:
    if m.seed < 0: ctrlRows.add m
    elif m.name.startsWith("gen:"): genRows.add m
    else: specRows.add m
  for r in winRows:
    if r.seed < 0: ctrlWins.add r
    elif r.mapName.startsWith("gen:"): genWins.add r
    else: specWins.add r
  report(ctrlRows, ctrlWins, "CONTROL: hand-authored arena + arena-large")
  report(specRows, specWins, "BAKED SPECS (first spec = the incumbent control)")
  if genRows.len > 0:
    report(genRows, genWins, &"GENERATED: seeds {seedSpec}, teams={teams}")

  let worst = a.flag("worst", "0").parseInt
  if worst > 0 and genWins.len > 0:
    var sorted = genWins
    sorted.sort(proc (x, y: WindowRow): int = cmp(x.minSide, y.minSide))
    echo ""
    echo "=== worst windows (lowest free depth on a side) ==="
    for i in 0 ..< min(worst, sorted.len):
      let r = sorted[i]
      echo &"  {r.mapName:<12} {r.size:<9} {r.kind:<13} at ({r.cx},{r.cy}) " &
        &"axis={r.axis} depths {r.depthA}/{r.depthB} glassPx={r.glassPx} {r.cls}"

when isMainModule:
  main()
