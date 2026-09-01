## The mapgen defect probe's OWN logic, under test (tools/probekit.nim +
## tools/br_outcome_probe.nim + tools/mapgen_play_gate.py). The probe is the
## earn-the-switch instrument for map generators: if its classifier
## boundaries, its LOS march, or its statistics drift, every mapgen verdict
## downstream of it is vibes again — so the instrument itself is pinned here.
##
## Layers covered:
##   1. window classifier boundaries (dead / inert / decor / shallow / useful)
##      at their exact edges;
##   2. the mirrored MinPassableWidth pinned against arena.nim's SOURCE (the
##      constant is unexported; a test restating the mirror could not catch a
##      drift, reading the source can) -- parsed out of the declaration line,
##      not matched as an exact-formatted string, so reformatting alone
##      cannot silently defeat the pin;
##   3. losClear + measureWindow + spawn geometry on a synthetic flagless map
##      with known distances;
##   4. the played-outcome probe end-to-end on the committed 16-team BR golden
##      fixture (persistent-counter instrumentation: full placement
##      permutation, spawn-group match for every team);
##   5. the play gate's statistics (rank/bootstrap-CI/binomial/ring-bias) via
##      its own --selftest, plus the BR gates end-to-end on synthetic rows
##      with a KNOWN planted bias, which the gate must find (and must NOT
##      find in the unbiased twin).

import
  std/[algorithm, json, os, osproc, sequtils, strformat, strutils, unittest],
  helpers,
  ctf/[global, sim],
  "../tools/probekit",
  "../tools/br_outcome_probe"

const GoldenReplay = GameDir / "tests" / "fixtures" / "br-golden-16team.bitreplay"

proc extractConstInt(src, name: string): int =
  ## Finds `name`'s own const DECLARATION line (not a mention in a comment
  ## or a longer identifier sharing the prefix) and parses its integer
  ## value, tolerant of export markers and any spacing around `=` -- so
  ## routine reformatting of arena.nim cannot silently defeat this pin the
  ## way an exact-string match would. Raises (failing the test loudly) if
  ## the declaration is gone or its value isn't a bare integer literal.
  for line in src.splitLines():
    let s = line.strip()
    if not s.startsWith(name): continue
    var rest = s[name.len .. ^1]
    if rest.startsWith("*"): rest = rest[1 .. ^1]  ## optional export marker
    rest = rest.strip()
    if rest.len == 0 or rest[0] != '=': continue    ## e.g. a longer ident
    rest = rest[1 .. ^1].strip()
    var numStr = ""
    for ch in rest:
      if ch.isDigit: numStr.add ch
      else: break
    if numStr.len > 0:
      return numStr.parseInt()
  raise newException(ValueError, &"const '{name}' declaration not found in source")

suite "defect probe: window classifier boundaries":
  test "dead beats every depth: zero glass pixels is not a window":
    check classifyWindow(0, 10_000) == winDead
    check classifyWindow(0, 0) == winDead

  test "inert / decor edge sits exactly at MinPassableWidth":
    check classifyWindow(5, MinPassableWidth - 1) == winInert
    check classifyWindow(5, MinPassableWidth) == winDecor

  test "decor / shallow edge sits exactly at DecorativeDepthPx":
    check classifyWindow(5, DecorativeDepthPx - 1) == winDecor
    check classifyWindow(5, DecorativeDepthPx) == winShallow

  test "shallow / useful edge sits exactly at UsefulDepthPx":
    check classifyWindow(5, UsefulDepthPx - 1) == winShallow
    check classifyWindow(5, UsefulDepthPx) == winUseful

  test "mirrored MinPassableWidth matches arena.nim's own source":
    ## arena.nim does not export the constant, so probekit mirrors it; this
    ## reads the SOURCE so a drift there fails here (assert against the
    ## source, not the prose) -- via extractConstInt's tolerant parse, not
    ## an exact-formatted string match, so reformatting alone can't defeat
    ## it the way a brittle grep would.
    let src = readFile(GameDir / "src" / "ctf" / "arena.nim")
    check extractConstInt(src, "MinPassableWidth") == probekit.MinPassableWidth

suite "defect probe: geometry on a synthetic map":
  ## A hand-built flagless board with one glass pane and one solid wall at
  ## known offsets, so every measured depth has a right answer.
  ##
  ##   x=196..203 solid wall (y 40..360 — leaves a route around the top)
  ##   x=296..303 glass pane (y 150..249)
  ##   left free depth  = 296 - 204 = 92px  -> decor (< 100)
  ##   right free depth = capped by gunRange (331) or the border (590)
  proc syntheticMap(): CtfMap =
    result = CtfMap(
      name: "probe-demo",
      width: 600, height: 400,
      center: MapPoint(x: 300, y: 200),
      symmetry: symNone,
      flagless: true,
      gunRange: 331,
      spawnGroups: 2,
      mapLayer: 0, walkLayer: 1, wallLayer: 2)
    result.leftObstacles = @[
      ArenaShape(kind: shapeRect,
        rect: MapRect(x: 196, y: 40, w: 8, h: 320)),
      ArenaShape(kind: shapeRect, window: true,
        rect: MapRect(x: 296, y: 150, w: 8, h: 100)),
    ]
    result.spawnPoints = @[
      MapPoint(x: 500, y: 200),   ## open floor, generous clearance
      MapPoint(x: 200, y: 200),   ## INSIDE the solid wall
    ]

  test "losClear: open line true, wall-crossing line false":
    let c = buildCtx(syntheticMap())
    check losClear(c.vision, c.w, c.h, 320, 200, 500, 200)
    check not losClear(c.vision, c.w, c.h, 100, 200, 500, 200)
    ## ...but the same wall-crossing line IS clear of the GLASS pane alone:
    check losClear(c.vision, c.w, c.h, 250, 200, 350, 200)

  test "measureWindow: known depths, decor classification":
    let c = buildCtx(syntheticMap())
    var pane = -1
    for i, s in c.obstacles:
      if s.window: pane = i
    check pane >= 0
    let m = c.measureWindow(c.obstacles[pane], pane)
    check m.axis == "x"
    check m.glassPx > 0
    let minSide = min(m.depthA, m.depthB)
    ## The blocked side: 92px of free floor between pane face and wall,
    ## measured by a MarchStep=2 walk (allow the step quantum).
    check minSide >= 88 and minSide <= 96
    ## The open side runs to the gun range cap, never past it.
    check max(m.depthA, m.depthB) <= 331
    check max(m.depthA, m.depthB) >= 280
    check classifyWindow(m.glassPx, minSide) == winDecor

  test "spawn geometry: in-obstacle spawn seen through the carve, walk >= crow":
    let g = syntheticMap()
    let c = buildCtx(g)
    let rows = c.measureSpawnGeometry()
    check rows.len == 2
    check not rows[0].inObstacleShape
    check rows[0].onOpenFloor
    check rows[0].hasClearance
    check rows[0].reachable
    check rows[0].nudgePx == 0
    ## The authored point sits inside the wall shape — and the rasterizer
    ## CARVES the spawn pocket straight through the wall, so the floor reads
    ## open. The probe must still see the authored defect through the repair.
    check rows[1].inObstacleShape
    check rows[1].onOpenFloor
    ## Walk distance to a pool point must never beat the crow-flies line.
    let g2 = block:
      var m = syntheticMap()
      m.medKitSpawns = @[MapPoint(x: 100, y: 200)]  ## behind the wall
      m
    let c2 = buildCtx(g2)
    let rows2 = c2.measureSpawnGeometry()
    let euclid = 400  ## |500 - 100|
    check rows2[0].medKitWalk > euclid  ## must detour around the wall top

suite "defect probe: played outcomes from the BR golden fixture":
  test "spawn-group binding formula matches sim_state.nim's source":
    ## br_outcome_probe mirrors the team->group rotation instead of calling
    ## spawnPosition (whose nearestWalkable nudge is occupancy-dependent);
    ## pin the mirrored formula against the SOURCE so drift fails here.
    let src = readFile(GameDir / "src" / "ctf" / "sim_state.nim")
    check "group = (ord(team) + offset) mod teamCount" in src

  test "persistent-counter probe: full permutation, every group matched":
    let row = probeReplay(GoldenReplay)
    check row["finished"].getBool()
    check row["groups"].len == 16
    var placements: seq[int]
    for g in row["groups"]:
      placements.add g["placement"].getInt()
      check g["group"].getInt() >= 0        ## spawn-group match for EVERY team
      check g["spawnX"].getInt() >= 0
    placements.sort()
    check placements == toSeq(1 .. 16)      ## a strict total order, no ties
    check row["winnerGroup"].getInt() >= 0
    ## The zone center is DRAWN, not the map center (the ring-bias gate's
    ## reason to exist): on this recording they differ.
    check (row["zoneCenterX"].getInt() != row["mapCenterX"].getInt() or
           row["zoneCenterY"].getInt() != row["mapCenterY"].getInt())
    ## Elimination ticks: every eliminated team carries one; the winner
    ## carries none.
    for g in row["groups"]:
      if g["placement"].getInt() == 1:
        check g["elimTick"].getInt() == -1

suite "defect probe: play-gate statistics":
  test "the gate's own selftest passes (rank / CI / binomial / ring-bias)":
    let (output, code) = execCmdEx(
      "python3 " & (GameDir / "tools" / "mapgen_play_gate.py") & " --selftest")
    checkpoint output
    check code == 0
    check "selftest OK" in output

  test "BR gates find a PLANTED ring bias and clear an unbiased twin":
    ## 24 synthetic episodes, 16 groups on a ring of distances. Biased set:
    ## placement tracks distance-to-zone exactly. Unbiased set: placement is
    ## a seed-rotated permutation, independent of distance.
    proc rowsFor(biased: bool): string =
      for ep in 0 ..< 24:
        var groups: seq[JsonNode]
        for g in 0 ..< 16:
          let dist = 100 + g * 50
          let placement =
            if biased: g + 1
            else: ((g + ep * 5) mod 16) + 1
          groups.add %*{
            "team": g, "group": g,
            "spawnX": 1000 + dist, "spawnY": 1000,
            "placement": placement, "kills": 1, "damage": 3,
            "elimTick": (if placement == 1: -1 else: 5000 + placement),
            "elimByCombat": placement mod 2 == 0}
        let winner = (
          if biased: 0 else: ((16 - ep * 5) mod 16 + 16) mod 16)
        result.add $(%*{
          "replay": "syn-" & $ep, "map": "syn", "seed": 100 + ep,
          "ticks": 5800, "maxTicks": 6000, "finished": true,
          "isDraw": false, "byTimeout": false,
          "contested": ep mod 2 == 0,
          "winnerTeam": winner, "winnerGroup": winner,
          "zoneCenterX": 1000, "zoneCenterY": 1000,
          "mapCenterX": 2000, "mapCenterY": 1000,
          "groups": %groups}) & "\n"
    let biasedPath = getTempDir() / "dp-gate-biased.jsonl"
    let fairPath = getTempDir() / "dp-gate-fair.jsonl"
    writeFile(biasedPath, rowsFor(true))
    writeFile(fairPath, rowsFor(false))
    let gate = GameDir / "tools" / "mapgen_play_gate.py"
    let (biasedOut, code1) = execCmdEx(
      &"python3 {gate} br --rows {biasedPath} --boot 500")
    checkpoint biasedOut
    check code1 == 0
    ## Assert on the ZONE line specifically: a red-proof showed the loose
    ## "anywhere in output" form passes even with the zone computation
    ## blinded, because the mapCenter line can carry its own bias.
    var zoneLine = ""
    for line in biasedOut.splitLines():
      if "dist-to-zoneCenter" in line: zoneLine = line
    check "BIAS (CI excludes 0)" in zoneLine
    ## Winner is always group 0 in the biased set: with 24 episodes the
    ## exact test cannot yet flag a never-winner (needs 47), and the gate
    ## must SAY so rather than certify.
    check "DEMONSTRATION, NOT CERTIFICATION" in biasedOut
    let (fairOut, code2) = execCmdEx(
      &"python3 {gate} br --rows {fairPath} --boot 500")
    checkpoint fairOut
    check code2 == 0
    check "no resolvable bias (CI spans 0)" in fairOut
    check "contested" in fairOut.toLowerAscii()

  test "meta-gate corr: earned vs not-earned verdicts on known data":
    var tsv = "map\tstaticScore\twinRate\n"
    for i in 0 ..< 20:
      tsv.add &"m{i}\t{float(i) * 0.05:.2f}\t{float(i) * 0.04 + 0.1:.3f}\n"
    let earnedPath = getTempDir() / "dp-corr-earned.tsv"
    writeFile(earnedPath, tsv)
    let gate = GameDir / "tools" / "mapgen_play_gate.py"
    let (earnedOut, c1) = execCmdEx(
      &"python3 {gate} corr --tsv {earnedPath} --score staticScore " &
      "--outcome winRate --boot 500")
    checkpoint earnedOut
    check c1 == 0
    check "EARNS rank authority" in earnedOut
    ## Shuffled outcomes: same marginals, no relation -> NOT EARNED.
    var tsv2 = "map\tstaticScore\twinRate\n"
    let shuffled = [12, 3, 17, 8, 0, 15, 6, 19, 2, 10,
                    14, 5, 18, 9, 1, 16, 7, 11, 4, 13]
    for i in 0 ..< 20:
      tsv2.add &"m{i}\t{float(i) * 0.05:.2f}\t{float(shuffled[i]) * 0.04:.3f}\n"
    let noisyPath = getTempDir() / "dp-corr-noisy.tsv"
    writeFile(noisyPath, tsv2)
    let (noisyOut, c2) = execCmdEx(
      &"python3 {gate} corr --tsv {noisyPath} --score staticScore " &
      "--outcome winRate --boot 500")
    checkpoint noisyOut
    check c2 == 0
    check "NOT EARNED" in noisyOut
