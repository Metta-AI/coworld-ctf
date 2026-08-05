import std/[monotimes, os, strformat, strutils, times], ../src/ctf/[sim, map_metrics]
const Unlocked = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
when isMainModule:
  let mode = paramStr(1)
  case mode
  of "spin":
    # 2-team seeds whose SHIPPED map is rot180 and selects spinning diamonds.
    for seed in 1 .. 400:
      let m = generateCtfMap(seed, Unlocked)
      if m.symmetry == symRot180:
        let chosen = buildAnimatedDiamonds(m, buildArenaObstacles(m))
        if chosen.len > 0:
          echo &"seed={seed} size={m.mapSizeClassName()} {m.width}x{m.height} diamonds={chosen.len}"
          if m.mapSizeClassName() in ["small", "standard"]: quit(0)
  of "spin4":
    for seed in 1 .. 300:
      let m = generateCtfMap(seed, Unlocked, 4)
      let chosen = buildAnimatedDiamonds(m, buildArenaObstacles(m))
      if chosen.len > 0:
        echo &"seed4={seed} size={m.mapSizeClassName()} {m.width}x{m.height} diamonds={chosen.len}"
        if m.mapSizeClassName() in ["small", "standard"]: quit(0)
  of "sight":
    # first 2-team seed whose ATTEMPT-0 map fails with an open sightline
    for seed in 1000 .. 1200:
      let m = generateMapAttempt(seed, Unlocked, 2)
      let r = validateGeneratedMap(m)
      if r.startsWith("open horizontal sightline"):
        echo &"seed={seed} {r}"
        quit(0)
  of "exhaust":
    # locked combos that never validate in 100 attempts
    for size in ["small", "standard"]:
      for cols in [3, 4]:
        for feat in ["walls", "ring", "bracket"]:
          var ok = 0
          for a in 0 ..< 100:
            let m = generateMapAttempt(1001, MapGenOverrides(windows: 0, pits: 0,
              pitDensity: -1, size: size, columns: cols, centerFeature: feat), 2, a)
            if validateGeneratedMap(m).len == 0: inc ok
          echo &"size={size} cols={cols} feat={feat} valid={ok}/100"
  of "cost":
    # per-candidate cost by size class: generate+validate, and evaluateMap
    var seen: array[MapSizeClass, int]
    for seed in 1000 .. 1400:
      let m0 = generateMapAttempt(seed, Unlocked, 2, 0)
      let c = m0.mapSizeClass()
      if seen[c] > 0: continue
      seen[c] = 1
      var genMs, scoreMs = 0
      for a in 0 ..< 4:
        var t = getMonoTime()
        let m = generateMapAttempt(seed, Unlocked, 2, a)
        let ok = validateGeneratedMap(m).len == 0
        genMs += int((getMonoTime() - t).inMilliseconds)
        t = getMonoTime()
        discard evaluateMap(m).staticScore()
        scoreMs += int((getMonoTime() - t).inMilliseconds)
        discard ok
      echo &"{c.sizeName():<10} {m0.width}x{m0.height} gen+validate={genMs div 4}ms score={scoreMs div 4}ms total={(genMs + scoreMs) div 4}ms/candidate"
  of "pits":
    for seed in [4242, 1001, 1002, 1010, 2024, 777, 999, 31337]:
      var line = &"seed={seed}: "
      var allOk = true
      for count in [0, 1, 4, 7, 12]:
        let m = generateCtfMap(seed, MapGenOverrides(windows: -1, pits: count, pitDensity: -1))
        line.add &"{count}->{m.trenches.len} "
        if m.trenches.len != count: allOk = false
      echo line & (if allOk: "  OK" else: "")
  of "diag":
    # first failing seed per reason family, plus its full-diagnostics rows
    var seenKind: seq[string]
    for teams in [2, 4]:
      for seed in 1000 .. 1200:
        let m = generateMapAttempt(seed, Unlocked, teams)
        let r = validateGeneratedMap(m)
        if r.len == 0: continue
        let kind = r.split('=')[0]
        if (($teams) & kind) in seenKind: continue
        seenKind.add (($teams) & kind)
        let d = mapDiagnostics(m)
        let firstRow = if d.openSightlineRows.len > 0: $d.openSightlineRows[0] else: "-"
        echo "teams=" & $teams & " seed=" & $seed & " reason=" & r &
          " | full=" & d.reason & " rows=" & $d.openSightlineRows.len &
          " first=" & firstRow
  else: discard
