## siege_reach_probe — is siege/rush ABSENT FROM THE VOCABULARY, or merely
## DE-SELECTED by best-of-K?
##
## The sweep showed `generateCtfMap` (best-of-K) never reaches chokeCount>=8
## (siege) nor choke<=1 AND route<=2 (rush) across 2000+ seeds. Best-of-K
## picks the highest `staticScore`, and staticScore's chokeCount band soft-caps
## at hi=6 — so a pinch-heavy candidate is penalised and loses selection. This
## probe looks at EVERY raw attempt (`generateMapAttempt`, pre-selection) to
## see whether the generator's vocabulary can even EMIT a siege/rush shape that
## selection then discards, or whether it never draws one at all.
##
## For each seed it walks all attempts 0..<MapGenMaxAttempts, records the max
## chokeCount and min routeCountMin seen among VALID raw attempts, and whether
## the SELECTED (shipped) map differs — i.e. selection threw away a more
## pinch-heavy valid candidate.
##
## Usage: nim c -d:release -r tools/siege_reach_probe.nim [lo] [hi]
## Run from repo root.

import std/[os, strformat, strutils]
import ../src/ctf/[arena, sim, map_metrics, map_rules, map_taxonomy]

when isMainModule:
  setCurrentDir(currentSourcePath().parentDir().parentDir())
  let
    lo = if paramCount() >= 1: parseInt(paramStr(1)) else: 3000
    hi = if paramCount() >= 2: parseInt(paramStr(2)) else: 3050
    ov = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)

  var
    anyRawSiege = 0        ## seeds with >=1 valid raw attempt at choke>=8
    anyRawRush = 0         ## seeds with >=1 valid raw attempt rush-shaped
    selectedSiege = 0
    selectedRush = 0
    globalMaxRawChoke = 0
    seedsScanned = 0

  for seed in lo ..< hi:
    inc seedsScanned
    var
      maxRawChoke = 0
      minRawRoute = 9999
      rawSiegeHere = false
      rawRushHere = false
    let attempts = generateMapAttempt(seed, ov, 2, 0).selectionK()
    for attempt in 0 ..< attempts:
      let raw = generateMapAttempt(seed, ov, 2, attempt)
      if validateGeneratedMap(raw).len != 0: continue   # only valid candidates
      let m = evaluateMap(raw, "raw")
      if m.chokeCount > maxRawChoke: maxRawChoke = m.chokeCount
      if m.routeCountMin < minRawRoute: minRawRoute = m.routeCountMin
      if m.chokeCount >= SiegeChokeCount: rawSiegeHere = true
      if m.chokeCount <= RushChokeMax and m.routeCountMin <= RushRouteMax:
        rawRushHere = true
    if maxRawChoke > globalMaxRawChoke: globalMaxRawChoke = maxRawChoke
    if rawSiegeHere: inc anyRawSiege
    if rawRushHere: inc anyRawRush

    # what selection actually shipped (one selection, reused)
    try:
      let shipped = generateCtfMap(seed, ov, teams = 2)
      let sel = evaluateMap(shipped, "sel")
      let selRules = mapRules(shipped.mapSizeClass(), 2)
      let pt = playtypeLabel(sel, selRules)
      if pt == "siege": inc selectedSiege
      if pt == "rush": inc selectedRush
      if rawSiegeHere and pt != "siege":
        stderr.writeLine(&"seed {seed}: RAW had siege (maxChoke={maxRawChoke}) " &
          &"but SELECTED shipped {pt} (choke={sel.chokeCount}) — de-selected")
      if rawRushHere and pt != "rush":
        stderr.writeLine(&"seed {seed}: RAW had rush (minRoute={minRawRoute}) " &
          &"but SELECTED shipped {pt} — de-selected")
    except CtfError:
      discard

  echo &"== siege/rush reachability, raw vs selected, seeds [{lo},{hi}) =="
  echo &"seeds scanned: {seedsScanned}"
  echo &"global max chokeCount over ALL valid RAW attempts: {globalMaxRawChoke} " &
    &"(siege needs >= {SiegeChokeCount})"
  echo &"seeds with a valid RAW siege candidate: {anyRawSiege}"
  echo &"seeds whose SELECTED map is siege: {selectedSiege}"
  echo &"seeds with a valid RAW rush candidate: {anyRawRush}"
  echo &"seeds whose SELECTED map is rush: {selectedRush}"
