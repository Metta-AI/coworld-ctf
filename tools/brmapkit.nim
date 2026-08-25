## brmapkit — a CLI for authoring battle-royale (BR) maps.
##
## FORK, not a patch (Maxwell's ruling, 2026-08-24; docs/designs/BR_MAPGEN.md).
## The CTF generator (tools/mapkit.nim, src/ctf/arena.nim's
## generateMapAttempt/validateGeneratedMap/mapFromSpecJson/validateMap) is
## UNTOUCHED by this file. BR needs full-board asymmetric authoring with NO
## symmetry group, no flags/endzones/homes/teams, and a 16-spawn
## last-group-standing validator suite instead of a 2-team capture-the-flag
## one — none of which fit `CtfMap`'s invariants (`validateMap` hard-codes a
## symNone spec to exactly 2 teams, `mapProtectedFloorAt`/`renderMap` walk
## `gameMap.teams()`/`flagHome()`, capped at 4). So this tool defines its own
## light `BrMap` and its own render/validate/metrics pipeline, while reusing
## the actual GOOD PARTS verbatim rather than re-deriving them:
##   - `mapgen_styles.generateShapes` / `genCaves` — welded organic terrain,
##     the exact CA + blob-polygon generator CTF uses, unmodified.
##   - `sim`'s pure shape geometry — `ArenaShape`/`MapRect`/`MapPoint`,
##     `inShape`, `shapeBounds`, `pointInPolygon` — none of it touches
##     `CtfMap`/teams, so it transfers with zero adaptation.
##   - `map_render`'s rasterization STRATEGY (paint each shape only over its
##     own bounding box, never area x shapes) and its warm-stone/floor
##     palette, duplicated here since its per-pixel helpers are private to
##     that module and its `renderMap` is wired to CTF's team/flag globals.
##   - the mapkit CLI shape: generate / render / validate / metrics, one spec
##     JSON as the working document.
##
## Claude's loop:
##   brmapkit generate --seed 7 -o m.json
##   brmapkit render   m.json -o m.png            # then LOOK at the PNG
##   brmapkit validate m.json                     # BR gates? (exit code)
##   brmapkit metrics  m.json                     # walkable/mass/ring/zone stats
##   brmapkit contactsheet a.png b.png ... -o sheet.png
##
## See docs/designs/BR_MAPGEN.md for the doctrine this tool draws for: the
## giant (2.6x) 3211x1713 field, derived gunRange, the 16-point k=0.85 ring,
## the z=0.173 rectangular final zone, and the four BR static validators.

import std/[os, math, random, strformat, strutils, tables, json, algorithm, sequtils]
import pixie
import ../src/ctf/sim, ../src/ctf/mapgen_styles

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

# --- argument parsing (duplicated from mapkit.nim's tiny parser) ------------

type Args = object
  positionals: seq[string]
  flags: Table[string, string]
  params: Table[string, string]
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
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--") and
          not (argv[i + 1].startsWith("-") and argv[i + 1].len == 2):
        ## The mapkit.nim precedent this parser is duplicated from only
        ## excludes "--"-prefixed lookahead, so a bool flag directly
        ## followed by a short flag (e.g. `--json -o out.json`) swallowed
        ## "-o" as ITS OWN value instead of reading as a bare bool — fixed
        ## here by also excluding 2-char short-flag tokens from "looks like
        ## a value".
        result.flags[body] = argv[i + 1]
        inc i
      else:
        result.bools[body] = true
    elif a.startsWith("-") and a.len == 2:
      let key = if a == "-o": "out" else: a[1 .. ^1]
      inc i
      if i >= argv.len: fail("flag " & a & " needs a value")
      result.flags[key] = argv[i]
    else:
      result.positionals.add a
    inc i

proc flag(a: Args, key, default: string): string = a.flags.getOrDefault(key, default)
proc intFlag(a: Args, key: string, default: int): int =
  if key in a.flags: a.flags[key].parseInt else: default
proc floatFlag(a: Args, key: string, default: float): float =
  if key in a.flags: a.flags[key].parseFloat else: default

proc applyParams(p: var StyleParams, params: Table[string, string]) =
  ## Duplicated verbatim from mapkit.nim's applyParams — the style knob
  ## surface is identical, BR just draws from a smaller family (caves only,
  ## in practice).
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

# --- BR map model -------------------------------------------------------------

type
  SpawnEdge = enum seTop, seRight, seBottom, seLeft

  BrSpawn = object
    p: MapPoint
    edge: SpawnEdge

  ## ROUND 3 (Maxwell's rejection, 2026-08-24): "no rooms, no alleys, no
  ## items, no intention" — CA-blob terrain alone cannot BE a battle-royale
  ## map. POIs are the composition unit; caves fill demotes to organic
  ## texture between them. Each archetype is chosen to be nameable at a
  ## glance (a caster's callout), per Maxwell's bar.
  PoiArchetype = enum
    poiCompound   ## major: two buildings (2 rooms each) split by an alley
    poiOutpost    ## mid: one building, 2 rooms
    poiYard       ## mid: walled yard + colonnade, open-air
    poiRuins      ## minor: broken/partial walls, no full enclosure
    ## ROUND 6 (Maxwell's ruling, doctrine §2.4): "how is the intent and
    ## keystone working... looks like a bunch of random rectangle rooms."
    ## Three archetypes the keystone families actually need — a few LARGER
    ## organizing structures rising out of the uniform field, not more of
    ## the same four boxes:
    poiAnchor     ## zone-edge-holding: bigger walled courtyard, exactly
                  ## 2-3 controlled exits (defensible, not sealed), a
                  ## couple of interior cover blocks
    poiCauseway   ## rotation-timing: a LONG broken-wall causeway/wall-run
                  ## — modeled as an elongated linear POI (halfExtent is
                  ## HALF-LENGTH along a drawn axis, not a square footprint)
    poiWarren     ## cqc-warren / third-party: a tight cluster of small
                  ## interconnected rooms, many approaches, no sealed
                  ## perimeter

  KeystoneFamily = enum
    ## ROUND 6: doctrine §2.4's keystone discipline, ported into the BR
    ## tool for the first time — "every map declares its keystone ability
    ## at draw." The keystone decides WHAT goes and HOW it relates; uniform
    ## density (round 5, kept) still decides WHERE.
    ksLandingSelection  ## steep loot/size gradient between sites
    ksRotationTiming    ## long causeways + open seams between clusters
    ksZoneEdgeHolding   ## a handful of spread anchor compounds
    ksThirdParty        ## open interiors, 3+ approaches, no sealed compounds
    ksCqcWarren         ## interior-share dial, HIGH pole
    ksOpenSteppe        ## interior-share dial, LOW pole

  PoiSite = object
    center: MapPoint
    archetype: PoiArchetype
    halfExtent: int   ## rough footprint half-size, for spacing/labels
                       ## (poiCauseway: HALF-LENGTH along its own axis)
    lootTier: int      ## 0 = richest (major), 1 = mid, 2 = minor
    ## ROUND 9 (Maxwell: "why are there no multi-room buildings... every
    ## interior is one room with a doorway"): the floor plan carved into
    ## this site's shell, in world coordinates. Populated by stampPoi via
    ## generateBrMap's caller (stampPoi itself is pure/rng-only and
    ## returns the rooms alongside its shapes; the site's own copy is
    ## written back after stamping). Empty for archetypes with no interior
    ## subdivision (poiRuins, poiCauseway) — poiYard gets exactly one
    ## room (its open interior), so it still counts as a room-count data
    ## point without being force-partitioned.
    rooms: seq[MapRect]

  BrMap = object
    name: string
    genSeed: int
    style: MapStyle
    width, height: int
    gunRange: int              ## derived, §4.1: G = sqrt(W*H / (groups*pi))
    spawnClearW, spawnClearH: int  ## CtfMap.spawnClearW/H semantics, reused
    groups: int                 ## 16 duos
    seatsPerGroup: int          ## 2
    zoneZ: float                ## 0.173, §4.3 final-zone scale
    keystone: KeystoneFamily    ## round 6, doctrine §2.4: declared at draw
    obstacles: seq[ArenaShape]  ## FULL board, no symmetry (BR is symNone-only)
    spawns: seq[BrSpawn]
    pois: seq[PoiSite]           ## round 3: the composition/intention layer
    structureCount: int         ## obstacles[0..<structureCount] are AUTHORED
      ## (POI walls + connectors) — never confetti-pruned, since a broken
      ## ruin's individual wall segment can be legitimately smaller than the
      ## floor. obstacles[structureCount..^1] is the demoted caves fill,
      ## which IS subject to the prune.
    ## Round-3 items — doctrine §4.4, the PRIMARY BR balance lever, absent
    ## from rounds 1-2 entirely. medKitSpawns/medKitCandidates mirror
    ## CtfMap's own fields verbatim: plain seq[MapPoint], NEUTRAL (no team
    ## keying at all), so they transfer to a 16-group draw with zero
    ## adaptation — confirmed by reading src/ctf/sim_types.nim directly.
    ## grenadeSpawns is BR's own analogue of CtfMap.grenadeSpawnPoints()
    ## (also neutral there, just a fixed array[4,..] keyed off map layout,
    ## which BR has none of) sized to the POI count instead of a fixed 4.
    ## teamPickups (shields/cans/barriers) are DELIBERATELY ABSENT: see the
    ## final report for why they cannot express a 16-group-fair pool under
    ## the current engine.
    medKitSpawns: seq[MapPoint]
    medKitCandidates: seq[MapPoint]
    grenadeSpawns: seq[MapPoint]

const
  StandardW = 1235   ## the CTF "standard" field width scaledGenShell derives from
  StandardH = 659
  GiantScale = 2.6    ## doctrine §4.1: giant field, half colossal's traverse time
  ZoneZ = 0.173
  Groups = 16
  SeatsPerGroup = 2
  ArenaBorderPx = 10   ## perimeter wall thickness, matches CTF's ArenaBorder
  styleSalt = 0x9E3779B1
  ## ROUND 8: keep every Nth vertex of a genCaves blob polygon before it
  ## enters the spec — see decimatePolygon's own comment for why.
  CaveFillVertDecimate = 2
  ## ROUND 8: caves fill runs as independent per-patch CA passes (see
  ## caveFillPatches), not one field-wide pass — tiles the placement
  ## region into a grid roughly matched to the field's own ~1.83 aspect.
  CaveFillPatchCols = 5
  CaveFillPatchRows = 3

proc fieldSize(scale: float): tuple[w, h: int] =
  (int(round(float(StandardW) * scale)), int(round(float(StandardH) * scale)))

proc deriveGunRange(w, h, groups: int): int =
  ## §4.1, alpha = 1: G = radius of one group's equal-share territory disc.
  int(round(sqrt(float(w) * float(h) / (float(groups) * PI))))

proc spawnClearance(scale: float): tuple[w, h: int] =
  ## ROUND 5 (coordinator correction, 2026-08-24): the old body returned
  ## s(70), s(130) at GiantScale = 182x338 — CtfMap.spawnClearW/H semantics,
  ## sized to hold a full CTF TEAM (8+ players) and deliberately SCALING
  ## with the field. A BR pocket holds exactly one DUO (SeatsPerGroup=2).
  ## Verified against the engine's actual spawn stagger before touching
  ## this (sim_state.spawnPosition: PlayerHalf=6, stagger spread=36) — a
  ## 2-seat group's real footprint is two 12x12 boxes ~24px apart at most,
  ## nowhere near even one scale step of the old formula. A duo pocket must
  ## NOT scale with the field (that's exactly how 338px of radial reach ate
  ## 66% of a giant field's short axis — round 4's mid-band finding).
  ## `scale` is accepted but unused: kept in the signature so callers don't
  ## need to change, but the return value is now a flat, unscaled duo
  ## pocket (70px half-extent both axes — about 3x the ~24px a 2-seat
  ## stagger actually needs, margin without reintroducing a
  ## CTF-team-sized exclusion zone).
  discard scale
  (70, 70)

# --- ring spawns (§4.2) -------------------------------------------------------

proc nearestFieldEdge(p: MapPoint, width, height: int): SpawnEdge =
  ## ROUND 5: `.edge` is now purely a cosmetic/debug tag — pocketRect's
  ## case-split on edge is a no-op once clearW == clearH (a duo pocket is
  ## isotropic; see spawnClearance), and every other consumer only prints
  ## it in a stderr diagnostic. Classify by which field border the point is
  ## proportionally closest to, so it stays meaningful (and jitter-proof,
  ## and round-trip-safe) even though spawns no longer sit on a ring.
  let dTop = float(p.y) / float(height)
  let dBottom = float(height - p.y) / float(height)
  let dLeft = float(p.x) / float(width)
  let dRight = float(width - p.x) / float(width)
  let m = min([dTop, dBottom, dLeft, dRight])
  if m == dTop: seTop
  elif m == dBottom: seBottom
  elif m == dLeft: seLeft
  else: seRight

proc gridSpawns(rng: var Rand, width, height, n: int): seq[BrSpawn] =
  ## ROUND 5 (Maxwell's ruling, doctrine §4.2 rewrite): "the spawns dont
  ## need to be all in a circle. they can be in a grid" — supersedes the
  ## ring-spawn derivation entirely. "The ring was solving rotational
  ## fairness geometrically; fairness is measured per spawn, so the
  ## geometry constraint buys nothing and starves the field edges of
  ## structure" (doctrine). 16 groups -> a 4x4 grid spanning the WHOLE
  ## field (not inset), jittered within each cell, with a defensive
  ## minimum-separation retry — cells are ~800x428px at giant scale, far
  ## bigger than gunRange (~331px), so two spawns landing close enough to
  ## matter essentially never happens; the retry exists so it CAN'T happen
  ## rather than because it's expected to.
  const GridCols = 4
  const GridRows = 4
  doAssert GridCols * GridRows == n,
    "gridSpawns is authored for a 4x4 grid; group count changed"
  let cellW = float(width) / float(GridCols)
  let cellH = float(height) / float(GridRows)
  let edgeMargin = ArenaBorderPx + 70 + 20 ## keep the duo pocket off the border wall
  let minSep = 200
  const JitterFrac = 0.32 ## keep jittered spawns inside their own cell
  for row in 0 ..< GridRows:
    for col in 0 ..< GridCols:
      let baseX = (float(col) + 0.5) * cellW
      let baseY = (float(row) + 0.5) * cellH
      let jitterW = int(cellW * JitterFrac)
      let jitterH = int(cellH * JitterFrac)
      var placed = false
      for attempt in 0 ..< 40:
        let x = clamp(int(baseX) + rng.rand(-jitterW .. jitterW),
          edgeMargin, width - edgeMargin)
        let y = clamp(int(baseY) + rng.rand(-jitterH .. jitterH),
          edgeMargin, height - edgeMargin)
        let p = MapPoint(x: x, y: y)
        var tooClose = false
        for s in result:
          let dx = p.x - s.p.x
          let dy = p.y - s.p.y
          if dx * dx + dy * dy < minSep * minSep:
            tooClose = true
            break
        if not tooClose:
          result.add BrSpawn(p: p, edge: nearestFieldEdge(p, width, height))
          placed = true
          break
      if not placed:
        ## Falls back to the exact (unjittered) cell center, which is
        ## guaranteed >= minSep from every other cell center given
        ## cellW/cellH >> minSep — this path should never actually fire.
        let p = MapPoint(x: clamp(int(baseX), edgeMargin, width - edgeMargin),
                          y: clamp(int(baseY), edgeMargin, height - edgeMargin))
        result.add BrSpawn(p: p, edge: nearestFieldEdge(p, width, height))

proc pocketRect(s: BrSpawn, clearW, clearH: int): MapRect =
  ## Oriented spawn-pocket clearance — kept general (clearW tangential,
  ## clearH radial per the original CTF-derived convention) even though
  ## round 5 made the duo pocket isotropic (clearW == clearH == 70), so
  ## the shape stays correct if a future round ever re-introduces an
  ## anisotropic pocket.
  case s.edge
  of seTop, seBottom:
    MapRect(x: s.p.x - clearW, y: s.p.y - clearH, w: 2 * clearW, h: 2 * clearH)
  of seLeft, seRight:
    MapRect(x: s.p.x - clearH, y: s.p.y - clearW, w: 2 * clearH, h: 2 * clearW)

# --- terrain generation --------------------------------------------------------

proc placementRegion(width, height: int): MapRect =
  ## Full-board region inset only off the perimeter wall — no symmetry seam
  ## exists to dodge (BR is symNone-only), matching mapkit.placementRegion's
  ## own symNone branch.
  const hMargin = 40
  const vMargin = 2
  MapRect(x: hMargin, y: vMargin,
    w: max(1, width - 2 * hMargin), h: max(1, height - 2 * vMargin))

proc rectShapeBr(x, y, w, h: int): ArenaShape =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: w, h: h))

proc clipRectMinusPockets(r: MapRect, pockets: seq[MapRect], buffer: int): seq[MapRect] =
  ## `r` minus the buffer-expanded footprint of every pocket it actually
  ## overlaps, as axis-aligned sub-rects — the standard rect-minus-rect
  ## decomposition (up to 4 remaining strips: above/below get the full
  ## width, left/right get just the overlap's own band, so corners are
  ## never double-counted). Iterates pockets one at a time; fine here
  ## since a single wall run touching 2+ pockets at once is rare on a
  ## 16-spawn jittered grid.
  result = @[r]
  for pocket in pockets:
    let bx0 = pocket.x - buffer
    let by0 = pocket.y - buffer
    let bx1 = pocket.x + pocket.w + buffer
    let by1 = pocket.y + pocket.h + buffer
    var next: seq[MapRect]
    for piece in result:
      let px1 = piece.x + piece.w
      let py1 = piece.y + piece.h
      let ox0 = max(piece.x, bx0)
      let oy0 = max(piece.y, by0)
      let ox1 = min(px1, bx1)
      let oy1 = min(py1, by1)
      if ox0 >= ox1 or oy0 >= oy1:
        next.add piece  ## no overlap with this pocket
        continue
      if oy0 > piece.y: next.add MapRect(x: piece.x, y: piece.y, w: piece.w, h: oy0 - piece.y)
      if oy1 < py1: next.add MapRect(x: piece.x, y: oy1, w: piece.w, h: py1 - oy1)
      if ox0 > piece.x: next.add MapRect(x: piece.x, y: oy0, w: ox0 - piece.x, h: oy1 - oy0)
      if ox1 < px1: next.add MapRect(x: ox1, y: oy0, w: px1 - ox1, h: oy1 - oy0)
    result = next

proc dropShapesNearSpawns(
  obstacles: seq[ArenaShape], pockets: seq[MapRect]
): seq[ArenaShape] =
  ## Drop (not clip) any NON-rect shape whose bounding box crowds a spawn
  ## pocket — same policy as mapkit.keepFeatureClearance: dropping the
  ## whole seed shape keeps ORGANIC terrain (cave-fill polygons, diagonal
  ## causeway segments) reading as authored rock, never a shape with a
  ## bite taken out of it.
  ## ROUND 9 FIX: rect shapes now CLIP instead of drop, regardless of
  ## size. Found chasing landing-selection's confetti ceiling: a room's
  ## small partition-door stub depends on the LARGE piece it's welded to
  ## (a shell side, a bigger partition run) staying present — dropping
  ## that big piece wholesale because it merely grazes a spawn's buffer
  ## doesn't just lose its own area, it strands every small stub that was
  ## welded to it, which is exactly what the confetti gate then catches.
  ## (Tried gating this by the TOUCHED shape's own size first — clip only
  ## small pieces, keep dropping large ones — reasoning that a big piece
  ## was never at risk of BECOMING confetti itself. Backwards: confetti
  ## count measures the FINAL obstacle set, and a piece that's fully
  ## DROPPED can't be counted as its own small component at all — it's
  ## gone. A piece that's CLIPPED down small NEVER increases confetti
  ## versus dropping it outright. The size gate reintroduced the exact
  ## orphaned-stub failure for every family with big shell sides —
  ## measured confettiFail back up to 6-11/18 on a sweep that was 0/18
  ## under unconditional clip — so it's gone; see the mass/cover
  ## consequence handled separately via archetype-size recalibration,
  ## the doctrinally sanctioned lever, not this policy.)
  const Buffer = 70
  for shape in obstacles:
    let b = shapeBounds(shape)
    var collides = false
    for pocket in pockets:
      if b.x0 - Buffer <= pocket.x + pocket.w and
          b.x1 + Buffer >= pocket.x and
          b.y0 - Buffer <= pocket.y + pocket.h and
          b.y1 + Buffer >= pocket.y:
        collides = true
        break
    if not collides:
      result.add shape
    elif shape.kind == shapeRect:
      const MinSliver = 6  ## drop remainder strips too thin to read as wall
      for piece in clipRectMinusPockets(shape.rect, pockets, Buffer):
        if piece.w >= MinSliver and piece.h >= MinSliver:
          result.add rectShapeBr(piece.x, piece.y, piece.w, piece.h)

# --- POI structures (round 3) -------------------------------------------------
## "bsp-lite applied as discrete local stamps" (coordinator, round 3): each
## POI is a small, self-contained rect-wall compound, built the same way
## mapgen_styles.genBsp builds rooms (walls inset from a leaf rect, a door
## gap centered on each open side) but authored directly here instead of
## via a global BSP split — global BSP is what the sibling br-demo lane
## found gets eaten by the carve at giant scale; a local stamp has no carve
## to dodge in the first place.


type RoomSide = enum rsTop, rsRight, rsBottom, rsLeft

## ROUND 7 (Maxwell's verdict, doctrine anti-confetti directive): stampRoom,
## stampRuinRoom, and stampColonnade — round 3-6's THIN-WALLED, sometimes
## fully-open-sided room stampers — are RETIRED, not orphaned-and-forgotten.
## They are the diagnosed root cause of "still confetti maps... on a larger
## scale": a fully open side leaves its remaining walls disconnected from
## each other, so no arrangement of them ever welds into one mass. Replaced
## by stampShellRing (below) — a closed ring, every side always present,
## gated instead of open, thick by construction.

proc chooseGatePos(loBound, hiBound, gateW: int, avoid: seq[(int, int)]): int =
  ## ROUND 9: the gate's start position along a side, in ABSOLUTE
  ## coordinates (same space as the side's own extent [loBound,hiBound)).
  ## Centered by default (matches the pre-round-9 formula exactly when
  ## `avoid` is empty — every existing stampShellRing call is unaffected).
  ## `avoid` is a list of intervals the gate must not overlap: an interior
  ## partition wall's own endpoint touching THIS side. Found via a
  ## confetti-fragment chase (round 9): a BSP split line is chosen with no
  ## knowledge of where that side's gate will land, so a partition's
  ## endpoint can coincide with the gate's gap — the partition "touches
  ## the shell" at a spot where the shell has no wall at all, leaving an
  ## isolated stub with nothing to weld to. Walks outward from center in
  ## gateW/2 steps looking for a clear spot; if the side is too crowded to
  ## find one, falls back to centered (residual risk, better than a side
  ## that never gates at all).
  let centered = loBound + (hiBound - loBound - gateW) div 2
  proc overlaps(pos: int): bool =
    for (lo, hi) in avoid:
      if pos < hi and pos + gateW > lo: return true
    false
  if not overlaps(centered): return centered
  let maxPos = hiBound - gateW
  let step = max(8, gateW div 2)
  var offset = step
  while offset <= (hiBound - loBound):
    let right = centered + offset
    let left = centered - offset
    if right <= maxPos and not overlaps(right): return right
    if left >= loBound and not overlaps(left): return left
    offset += step
  centered  ## give up; accept the residual coincidence risk

proc stampShellRing(
  rect: MapRect, shellThick: int, gateSides: set[RoomSide], gateW: int,
  avoidTop, avoidBottom, avoidLeft, avoidRight: seq[(int, int)] = @[]
): seq[ArenaShape] =
  ## ROUND 7 (Maxwell's verdict, doctrine anti-confetti directive): "these
  ## are still confetti maps... on a larger scale with rooms and whatnot."
  ## Root cause was architectural: stampRoom's walls were THIN (12-16px)
  ## and archetypes routinely left 2 of 4 sides FULLY OPEN (no wall at
  ## all) for exit-rule variety — opposite/non-adjacent sides then never
  ## touch, so each surviving wall becomes its OWN small disconnected
  ## mass, no matter how the rest of the map is arranged. This is the
  ## SUBTRACTIVE fix: a closed rectangular ring where all FOUR sides are
  ## ALWAYS present (never fully missing) at a THICK shell (24-48px,
  ## caller's choice) — only a GATE GAP is ever cut into a side, and every
  ## strip overlaps generously into its corners, so the ring stays ONE
  ## topologically connected mass regardless of how many sides are gated.
  ## The interior "void" (room/courtyard) is never drawn — it's just
  ## whatever floor is left uncovered once the ring is stamped, which is
  ## exactly subtraction without needing a subtraction primitive.
  # top / bottom
  for (side, wy, avoid) in [(rsTop, rect.y, avoidTop), (rsBottom, rect.y + rect.h - shellThick, avoidBottom)]:
    if side in gateSides:
      let gapX = chooseGatePos(rect.x, rect.x + rect.w, gateW, avoid)
      if gapX > rect.x:
        result.add rectShapeBr(rect.x, wy, gapX - rect.x, shellThick)
      if gapX + gateW < rect.x + rect.w:
        result.add rectShapeBr(gapX + gateW, wy, rect.x + rect.w - (gapX + gateW), shellThick)
    else:
      result.add rectShapeBr(rect.x, wy, rect.w, shellThick)
  # left / right
  for (side, wx, avoid) in [(rsLeft, rect.x, avoidLeft), (rsRight, rect.x + rect.w - shellThick, avoidRight)]:
    if side in gateSides:
      let gapY = chooseGatePos(rect.y, rect.y + rect.h, gateW, avoid)
      if gapY > rect.y:
        result.add rectShapeBr(wx, rect.y, shellThick, gapY - rect.y)
      if gapY + gateW < rect.y + rect.h:
        result.add rectShapeBr(wx, gapY + gateW, shellThick, rect.y + rect.h - (gapY + gateW))
    else:
      result.add rectShapeBr(wx, rect.y, shellThick, rect.h)

proc stampPartitionWall(
  x0, y0, x1, y1, thick, gateW: int
): seq[ArenaShape] =
  ## A single thick internal partition (axis-aligned, horizontal or
  ## vertical) with ONE gate gap near its middle — used to carve a big
  ## shell-ring mass into two or more interior cells (the warren grammar)
  ## while the partition still physically touches (and so stays connected
  ## to) the outer ring at both of its ends.
  if abs(x1 - x0) >= abs(y1 - y0):
    let y = y0
    let gapX = x0 + (x1 - x0 - gateW) div 2
    if gapX > x0: result.add rectShapeBr(x0, y, gapX - x0, thick)
    if gapX + gateW < x1: result.add rectShapeBr(gapX + gateW, y, x1 - (gapX + gateW), thick)
  else:
    let x = x0
    let gapY = y0 + (y1 - y0 - gateW) div 2
    if gapY > y0: result.add rectShapeBr(x, y0, thick, gapY - y0)
    if gapY + gateW < y1: result.add rectShapeBr(x, gapY + gateW, thick, y1 - (gapY + gateW))

# Union-Find for connected-component labeling — moved above the round-9
# floor-plan section (originally lived down with the other geometry/grid
# validators) since buildDoorGraph's spanning tree needs it too.
type DSU = object
  parent: seq[int]
  size: seq[int]

proc initDSU(n: int): DSU =
  result.parent = newSeq[int](n)
  result.size = newSeq[int](n)
  for i in 0 ..< n:
    result.parent[i] = i
    result.size[i] = 1

proc find(d: var DSU, x: int): int =
  var x = x
  while d.parent[x] != x:
    d.parent[x] = d.parent[d.parent[x]]
    x = d.parent[x]
  x

proc union(d: var DSU, a, b: int) =
  let ra = d.find(a)
  let rb = d.find(b)
  if ra == rb: return
  if d.size[ra] < d.size[rb]:
    d.parent[ra] = rb
    d.size[rb] += d.size[ra]
  else:
    d.parent[rb] = ra
    d.size[ra] += d.size[rb]

# --- floor plans (round 9) -----------------------------------------------------
## Maxwell, on round 8's density sheet: "why are there no multi-room
## buildings?/interiors. every interior is one room with a doorway. can we
## fix this generator to have a wide array of possible interiors and room
## counts (connected in one structure)." Round 7-8's stampShellRing left the
## carved interior as bare uncarved floor (correct for the ANTI-CONFETTI
## mass, wrong for what's actually playable inside). This section subdivides
## that same interior with a BSP-lite room split, wires the rooms into a
## doorway graph (spanning tree + a couple of loop doors), and returns the
## room list so callers can report room counts and place loot per room.

type
  RoomAdjacency = tuple[i, j, x0, y0, x1, y1: int]
    ## Two room indices plus the shared boundary SEGMENT (a straight run,
    ## either x0==x1 [vertical boundary] or y0==y1 [horizontal boundary])
    ## — enough to draw the exact partition wall between them.

proc bspRoomSplit(
  rng: var Rand, rect: MapRect, minRoomSize, targetCount, maxDepth: int
): seq[MapRect] =
  ## Recursive random axis-aligned splits — the same technique
  ## mapgen_styles.bspSplit uses for terrain, applied here to ROOM
  ## interiors. Always splits the LONGER axis (keeps rooms from going
  ## needle-thin). Stops — deliberately BEFORE `targetCount` is reached,
  ## per doctrine item 1's "stop probabilistically so room counts VARY" —
  ## on any of: target satisfied, depth exhausted, the rect too small for
  ## another cut, or (only when the remaining target is already down to
  ## "maybe 1 more room") a flat early-stop roll. This is what makes two
  ## same-archetype buildings on the same map land on different room
  ## counts instead of always maxing out.
  const EarlyStopProb = 0.15
  if targetCount <= 1: return @[rect]
  if maxDepth <= 0 or rect.w < 2 * minRoomSize or rect.h < 2 * minRoomSize:
    return @[rect]
  if targetCount <= 2 and rng.rand(1.0) < EarlyStopProb:
    return @[rect]
  let splitVertical = rect.w >= rect.h
  let leftCount = max(1, targetCount div 2)
  let rightCount = max(1, targetCount - leftCount)
  if splitVertical:
    let minX = rect.x + minRoomSize
    let maxX = rect.x + rect.w - minRoomSize
    if maxX <= minX: return @[rect]
    let splitX = minX + rng.rand(maxX - minX)
    let a = MapRect(x: rect.x, y: rect.y, w: splitX - rect.x, h: rect.h)
    let b = MapRect(x: splitX, y: rect.y, w: rect.x + rect.w - splitX, h: rect.h)
    result = bspRoomSplit(rng, a, minRoomSize, leftCount, maxDepth - 1) &
             bspRoomSplit(rng, b, minRoomSize, rightCount, maxDepth - 1)
  else:
    let minY = rect.y + minRoomSize
    let maxY = rect.y + rect.h - minRoomSize
    if maxY <= minY: return @[rect]
    let splitY = minY + rng.rand(maxY - minY)
    let a = MapRect(x: rect.x, y: rect.y, w: rect.w, h: splitY - rect.y)
    let b = MapRect(x: rect.x, y: splitY, w: rect.w, h: rect.y + rect.h - splitY)
    result = bspRoomSplit(rng, a, minRoomSize, leftCount, maxDepth - 1) &
             bspRoomSplit(rng, b, minRoomSize, rightCount, maxDepth - 1)

proc computeRoomAdjacency(rooms: seq[MapRect]): seq[RoomAdjacency] =
  ## Two rooms are adjacent if they share a border run of at least
  ## MinOverlap px. Every pair of SIBLING leaves from the same BSP split
  ## always qualifies (they share the FULL split line by construction);
  ## this also catches adjacency ACROSS different branches of the tree
  ## (two leaves from different subtrees that happen to touch), which is
  ## what turns a pure tree into a real graph with loop candidates.
  const MinOverlap = 20
  const Tol = 2 ## px slack for split-coordinate rounding
  for i in 0 ..< rooms.len:
    for j in (i + 1) ..< rooms.len:
      let a = rooms[i]
      let b = rooms[j]
      if abs((a.x + a.w) - b.x) <= Tol or abs((b.x + b.w) - a.x) <= Tol:
        let y0 = max(a.y, b.y)
        let y1 = min(a.y + a.h, b.y + b.h)
        if y1 - y0 >= MinOverlap:
          let wallX = if abs((a.x + a.w) - b.x) <= Tol: a.x + a.w else: b.x + b.w
          result.add (i, j, wallX, y0, wallX, y1)
          continue
      if abs((a.y + a.h) - b.y) <= Tol or abs((b.y + b.h) - a.y) <= Tol:
        let x0 = max(a.x, b.x)
        let x1 = min(a.x + a.w, b.x + b.w)
        if x1 - x0 >= MinOverlap:
          let wallY = if abs((a.y + a.h) - b.y) <= Tol: a.y + a.h else: b.y + b.h
          result.add (i, j, x0, wallY, x1, wallY)

proc buildDoorGraph(
  rng: var Rand, n: int, adjacency: seq[RoomAdjacency], extraLoops: int
): seq[(int, int)] =
  ## Doctrine item 3: "build a spanning tree over the room adjacency
  ## graph (every room reachable), then add 0-2 extra doors for loops."
  ## Shuffled-Kruskal via the same DSU the mass validators already use —
  ## every accepted edge connects two previously-separate components, so
  ## the result is a genuine spanning tree (every room reachable from
  ## every other) as long as the adjacency graph itself is connected,
  ## which a BSP tiling always is by construction.
  if n <= 1 or adjacency.len == 0: return
  var edges = adjacency
  rng.shuffle(edges)
  var dsu = initDSU(n)
  var remaining: seq[(int, int)]
  for e in edges:
    if dsu.find(e.i) != dsu.find(e.j):
      dsu.union(e.i, e.j)
      result.add (e.i, e.j)
    else:
      remaining.add (e.i, e.j)
  rng.shuffle(remaining)
  for k in 0 ..< min(extraLoops, remaining.len):
    result.add remaining[k]

proc stampFloorPlan(
  rng: var Rand, footprint: MapRect, shellThick: int, gateSides: set[RoomSide],
  gateW, targetRoomCount, minRoomSize, partitionThick, doorW: int
): tuple[shapes: seq[ArenaShape], rooms: seq[MapRect]] =
  ## The round-9 floor-plan generator: shell (unchanged from round 7) +
  ## a BSP-lite room split of the carved interior (item 1) + a doorway
  ## graph over room adjacency (item 3). Every partition wall is drawn
  ## EXACTLY on a BSP split line, so it always spans the full boundary
  ## between two cells and therefore always touches two existing walls
  ## (the shell or an earlier partition) at both ends *whenever that end
  ## lands on a REAL wall* — which the shell alone doesn't guarantee: a
  ## split line chosen with no knowledge of the shell's own gate can end
  ## at a point the gate leaves open. Rooms/adjacency are computed BEFORE
  ## the shell now (reordered from the original round-9 draft) so their
  ## shell-touching endpoints can be fed to stampShellRing as gate
  ## exclusion zones (chooseGatePos) — see that proc's comment for the
  ## confetti fragment this fixes.
  let interior = MapRect(
    x: footprint.x + shellThick, y: footprint.y + shellThick,
    w: footprint.w - 2 * shellThick, h: footprint.h - 2 * shellThick)
  if interior.w < minRoomSize or interior.h < minRoomSize or targetRoomCount <= 1:
    return (stampShellRing(footprint, shellThick, gateSides, gateW), @[interior])
  let rooms = bspRoomSplit(rng, interior, minRoomSize, targetRoomCount, 4)
  if rooms.len <= 1:
    return (stampShellRing(footprint, shellThick, gateSides, gateW), rooms)
  let adjacency = computeRoomAdjacency(rooms)
  let extraLoops = rng.rand(2) ## 0-2, doctrine item 3
  let doors = buildDoorGraph(rng, rooms.len, adjacency, extraLoops)
  ## Margin past the partition's own thickness so the gate clears it with
  ## room to spare, not just a bare non-overlap.
  const TouchMargin = 8
  var avoidTop, avoidBottom, avoidLeft, avoidRight: seq[(int, int)]
  for adj in adjacency:
    if adj.x0 == adj.x1:
      let wx = adj.x0 - partitionThick div 2
      let lo = wx - TouchMargin
      let hi = wx + partitionThick + TouchMargin
      if adj.y0 == interior.y: avoidTop.add (lo, hi)
      if adj.y1 == interior.y + interior.h: avoidBottom.add (lo, hi)
    else:
      let wy = adj.y0 - partitionThick div 2
      let lo = wy - TouchMargin
      let hi = wy + partitionThick + TouchMargin
      if adj.x0 == interior.x: avoidLeft.add (lo, hi)
      if adj.x1 == interior.x + interior.w: avoidRight.add (lo, hi)
  var shapes = stampShellRing(footprint, shellThick, gateSides, gateW,
    avoidTop, avoidBottom, avoidLeft, avoidRight)
  for adj in adjacency:
    let hasDoor = (adj.i, adj.j) in doors
    if adj.x0 == adj.x1:
      ## Vertical shared boundary: centre a `partitionThick`-wide wall on
      ## the split line (matches the existing warren partition's own
      ## `midX = cx - partThick div 2` centring convention).
      let wx = adj.x0 - partitionThick div 2
      if hasDoor:
        shapes.add stampPartitionWall(wx, adj.y0, wx, adj.y1, partitionThick, doorW)
      else:
        shapes.add rectShapeBr(wx, adj.y0, partitionThick, adj.y1 - adj.y0)
    else:
      let wy = adj.y0 - partitionThick div 2
      if hasDoor:
        shapes.add stampPartitionWall(adj.x0, wy, adj.x1, wy, partitionThick, doorW)
      else:
        shapes.add rectShapeBr(adj.x0, wy, adj.x1 - adj.x0, partitionThick)
  (shapes, rooms)

proc stampPoi(
  rng: var Rand, site: PoiSite, roomHint: int = 0
): tuple[shapes: seq[ArenaShape], rooms: seq[MapRect]] =
  ## `roomHint` (round 9, doctrine item 6's room-count-variety gate): 0
  ## means "pick a target room count the old random way"; >0 means "use
  ## exactly this many, clamped to this archetype's own valid range."
  ## Measured that leaving every structure's target purely to chance
  ## under-delivered: with only ~4-5 room-having structures per map and
  ## each one independently rolling from a 2-4-value range, the odds that
  ## >=3 DISTINCT values actually show up by luck alone were under 50%
  ## (a small-sample coupon-collector problem, not a bug in any one
  ## archetype's own spread). generateBrMap pre-assigns a shuffled,
  ## ascending sequence of hints across every room-eligible POI so the
  ## draw is diverse BY CONSTRUCTION, while bspRoomSplit's own probabilistic
  ## early-stop/min-size logic still gets the final say on what actually
  ## gets built — the hint raises the odds, it doesn't override the
  ## "stop probabilistically" requirement.
  ##
  ## Dispatch by archetype. ROUND 7 (Maxwell's verdict, zoomed in on the
  ## round-6 sheet): "these are still confetti maps. confetti on a larger
  ## scale with rooms and whatnot." Root cause: additive thin-walled line
  ## art can never weld the way a caves blob does, because open (missing)
  ## sides leave disconnected wall fragments no matter the arrangement.
  ## THE SUBTRACTIVE REFRAME: every archetype below is now ONE solid shell
  ## RING (stampShellRing — all 4 sides always present, gated not open,
  ## 28-44px thick) with interior floor left as uncarved negative space —
  ## the same visual species as a caves blob (chunky, welded, real area),
  ## never thin line art. A compound is now structurally ONE connected
  ## mass regardless of gate count.
  let cx = site.center.x
  let cy = site.center.y
  let he = site.halfExtent
  var shapes: seq[ArenaShape]
  var rooms: seq[MapRect]
  case site.archetype
  of poiCompound:
    ## ROUND 9 (doctrine item 1/2): the shell is unchanged (still ONE
    ## mass, still 2 gates), but the interior is now a real floor plan —
    ## 2-4 rooms via BSP-lite split, doorway graph, doors gated per the
    ## spanning tree. Compound's own "one interior cover slab" is DROPPED
    ## (a BSP room already reads as a place; a bare cover slab inside a
    ## carved room would look like clutter, not a courtyard feature).
    let shellThick = max(40, he * 2 div 5)
    const GateW = 56
    let footprint = MapRect(x: cx - he, y: cy - he * 4 div 5, w: 2 * he, h: he * 8 div 5)
    var sides = @[rsTop, rsRight, rsBottom, rsLeft]
    rng.shuffle(sides)
    let targetRooms = if roomHint > 0: clamp(roomHint, 2, 4) else: 2 + rng.rand(2) ## 2-4, doctrine item 2
    let plan = stampFloorPlan(rng, footprint, shellThick, {sides[0], sides[1]}, GateW,
      targetRooms, 70, 26, 50)
    shapes.add plan.shapes
    rooms = plan.rooms
  of poiOutpost:
    ## ROUND 9: 1-3 rooms (doctrine calls for "1-2"; widened to 1-3 —
    ## outpost is the ONE archetype every keystone family places multiple
    ## of, including families with no compound/anchor/warren at all like
    ## rotation-timing/open-steppe, so its OWN room-count spread is what
    ## keeps room-count-variety [item 6] achievable for those families).
    let shellThick = max(34, he * 2 div 5)
    const GateW = 50
    let footprint = MapRect(x: cx - he, y: cy - he * 3 div 4, w: 2 * he, h: he * 3 div 2)
    var sides = @[rsTop, rsRight, rsBottom, rsLeft]
    rng.shuffle(sides)
    let targetRooms = if roomHint > 0: clamp(roomHint, 1, 3) else: 1 + rng.rand(2) ## 1-3
    ## minRoomSize=38 (not the compound/anchor/warren-scale 48-100): an
    ## outpost's own interior can be as small as ~80x136px at the smallest
    ## halfExtent any pool uses (0.34G) — measured that minRoomSize=60
    ## made almost every outpost fail the "2x minRoomSize" split-eligible
    ## check and land on 1 room regardless of targetRooms, which is what
    ## was capping room-count-variety for keystones with no compound/
    ## anchor/warren at all.
    let plan = stampFloorPlan(rng, footprint, shellThick, {sides[0], sides[1]}, GateW,
      targetRooms, 38, 20, 42)
    shapes.add plan.shapes
    rooms = plan.rooms
  of poiYard:
    ## Left as an open-air courtyard (doctrine's own framing: "walled
    ## yard... open-air", not a building) — no BSP interior. Recorded as
    ## exactly ONE room (its own interior) so it still contributes a data
    ## point to room-count reporting/variety without being force-carved.
    let shellThick = max(34, he * 2 div 5)
    const GateW = 60
    let footprint = MapRect(x: cx - he, y: cy - he * 3 div 4, w: 2 * he, h: he * 3 div 2)
    shapes.add stampShellRing(footprint, shellThick, {rsTop, rsBottom}, GateW)
    ## Cover blocks must each individually clear the confetti floor
    ## (3000px^2, i.e. >=55x55) since they don't touch the ring — a smaller
    ## block reads fine at thumbnail scale but registers as its own tiny
    ## isolated mass.
    let blockW = max(60, he div 3)
    shapes.add rectShapeBr(cx - he div 2 - blockW div 2, cy - blockW div 2, blockW, blockW)
    shapes.add rectShapeBr(cx + he div 2 - blockW div 2, cy - blockW div 2, blockW, blockW)
    rooms = @[MapRect(x: footprint.x + shellThick, y: footprint.y + shellThick,
      w: footprint.w - 2 * shellThick, h: footprint.h - 2 * shellThick)]
  of poiRuins:
    ## A SMALL solid shell ring, not a scatter of disconnected L-brackets
    ## (the old design — exactly the "isolated small mass" doctrine now
    ## bans). Still the cheapest, smallest archetype, no interior plan
    ## (thematically "broken/partial walls, no full enclosure" — a real
    ## floor plan would contradict its own archetype description).
    let shellThick = max(28, he * 2 div 5)
    const GateW = 46
    let footprint = MapRect(x: cx - he, y: cy - he, w: 2 * he, h: 2 * he)
    let side = [rsTop, rsRight, rsBottom, rsLeft][rng.rand(3)]
    shapes.add stampShellRing(footprint, shellThick, {side}, GateW)
  of poiAnchor:
    ## ROUND 9: 3-5 rooms + courtyard (doctrine item 2). "Courtyard" is
    ## approximated rather than ring-modelled (a true perimeter-rooms-
    ## around-a-void ring split was scoped out for time — see the round-9
    ## report): a LARGER minRoomSize than the other archetypes biases the
    ## BSP split toward fewer, BIGGER cells, so at least one leaf usually
    ## reads as a big open hall; the two existing interior cover slabs are
    ## kept (now landing inside whichever room they fall in) as the
    ## courtyard's own furniture rather than being replaced.
    let shellThick = max(48, he * 2 div 5)
    const GateW = 50
    let footprint = MapRect(
      x: cx - he, y: cy - he * 4 div 5, w: 2 * he, h: he * 8 div 5)
    var sideOrder = @[rsTop, rsRight, rsBottom, rsLeft]
    rng.shuffle(sideOrder)
    let gateSet: set[RoomSide] = {sideOrder[0], sideOrder[1]}
    let targetRooms = if roomHint > 0: clamp(roomHint, 3, 5) else: 3 + rng.rand(2) ## 3-5
    ## ROUND 9 FIX: minRoomSize was 100, tuned against the ORIGINAL
    ## anchorHalf=1.05G (interior height ~279px, 2x100 fits easily). The
    ## zone-edge-holding cover-permille recalibration (see git log) cut
    ## anchorHalf to 0.70G, shrinking interior height to ~185px —
    ## bspRoomSplit's own "won't split an axis under 2x minRoomSize"
    ## guard then refused EVERY anchor split (measured: 159/159 anchors
    ## across a 30-seed sweep landed on exactly 1 room, a silent
    ## room-count-variety regression). 75 clears 2x75=150 <= 185 with
    ## margin and still stays the largest minRoomSize of any archetype.
    let plan = stampFloorPlan(rng, footprint, shellThick, gateSet, GateW,
      targetRooms, 62, 26, 48)
    shapes.add plan.shapes
    rooms = plan.rooms
    let coverW = max(32, he * 2 div 5)
    shapes.add rectShapeBr(cx - he div 2 - coverW div 2, cy - coverW div 2, coverW, coverW)
    shapes.add rectShapeBr(cx + he div 2 - coverW div 2, cy - coverW div 2, coverW, coverW)
  of poiCauseway:
    ## Rotation-timing: ONE LONG mass with 1-2 GATE gaps — not a dash
    ## train. `he` is HALF-LENGTH along a drawn axis (0/45/90/135deg).
    ## Built as 2-3 long shapeDiagonal segments (thick, 30px) separated by
    ## 1-2 real gaps, each segment individually well above the confetti
    ## floor, so the whole causeway still reads (and validates) as one
    ## deliberate barrier with a couple of crossing points, never scatter.
    ## No interior — a linear barrier, not a building.
    const Thick = 30
    let angles = [0.0, PI / 4.0, PI / 2.0, 3.0 * PI / 4.0]
    let theta = angles[rng.rand(angles.len - 1)]
    let ux = cos(theta)
    let uy = sin(theta)
    let totalLen = 2.0 * float(he)
    let gateCount = 1 + rng.rand(1)  ## 1 or 2 gates
    let gateW = 70.0 + float(rng.rand(30))
    let pieceLen = (totalLen - float(gateCount) * gateW) / float(gateCount + 1)
    var t = -float(he)
    for i in 0 ..< gateCount + 1:
      let segStart = t
      let segEnd = t + pieceLen
      let p0x = float(cx) + ux * segStart
      let p0y = float(cy) + uy * segStart
      let p1x = float(cx) + ux * segEnd
      let p1y = float(cy) + uy * segEnd
      shapes.add ArenaShape(
        kind: shapeDiagonal, x0: int(p0x), y0: int(p0y), x1: int(p1x), y1: int(p1y),
        thickness: Thick)
      t = segEnd + gateW
  of poiWarren:
    ## ROUND 9: "many small rooms" (doctrine item 2: "5-8 small rooms")
    ## replaces round 7's flat 2-cell split — the SAME shell/gate setup,
    ## but a real BSP floor plan with a small minRoomSize so it actually
    ## carves into several small cells instead of one central divider.
    let shellThick = max(32, he * 2 div 5)
    const GateW = 56
    let footprint = MapRect(x: cx - he, y: cy - he, w: 2 * he, h: 2 * he)
    var sideOrder = @[rsTop, rsRight, rsBottom, rsLeft]
    rng.shuffle(sideOrder)
    let targetRooms = if roomHint > 0: clamp(roomHint, 5, 8) else: 5 + rng.rand(4) ## 5-8
    let plan = stampFloorPlan(rng, footprint, shellThick, {sideOrder[0], sideOrder[1]}, GateW,
      targetRooms, 48, 24, 42)
    shapes.add plan.shapes
    rooms = plan.rooms
  (shapes, rooms)

proc tooCloseToAny(p: MapPoint, sites: seq[PoiSite], minDist: int): bool =
  for s in sites:
    let dx = p.x - s.center.x
    let dy = p.y - s.center.y
    if dx * dx + dy * dy < minDist * minDist:
      return true

proc tooCloseToAnySized(
  p: MapPoint, candArchetype: PoiArchetype, halfExtent: int,
  sites: seq[PoiSite], minDist: int
): bool =
  ## ROUND 8 FIX: `minDist` alone is a flat distance between CENTERS —
  ## fine when every archetype in a pool is roughly the same size, but
  ## landing-selection/zone-edge-holding mix HUGE archetypes (compound/
  ## anchor, half-extent 350-430px, footprint 700-860px wide) with tiny
  ## ones (ruins, ~53px) under one shared minSepFrac. Two big archetypes
  ## could legitimately land with centers only `minDist` apart (a value
  ## sized for the pool's SMALL end) while their footprints overlapped by
  ## a hundred-plus px — measured as the root cause of "cover too high,
  ## mass count too low" (a few giant fused blobs instead of many
  ## distinct ones). Requires BOTH the caller's flat minDist (the
  ## "spacing IS a grammar knob" semantic other callers rely on) AND
  ## enough room for both footprints plus a real gap to never touch.
  ##
  ## poiCauseway is EXCLUDED from the footprint term on whichever side it
  ## appears: its halfExtent is a LENGTH along an arbitrary drawn axis,
  ## not a radius (the same "square footprint" category error the
  ## caves-clash filter had — see that fix's own comment). Treating it as
  ## an isotropic radius here made the very first sweep after this fix
  ## fail rotation-timing's OWN causeway placement almost every time
  ## (caught immediately: 0/18 pass on the next sweep). Causeway-involved
  ## pairs fall back to the flat minDist, same as before this fix.
  const FootprintGapPx = 40
  let candHalf = if candArchetype == poiCauseway: 0 else: halfExtent
  for s in sites:
    let dx = p.x - s.center.x
    let dy = p.y - s.center.y
    let d2 = dx * dx + dy * dy
    let siteHalf = if s.archetype == poiCauseway: 0 else: s.halfExtent
    let required = max(minDist, candHalf + siteHalf + FootprintGapPx)
    if d2 < required * required:
      return true
  false

## tooCloseToAnyPocket (spawn-keep-away for PLACEMENT) is GONE as of round 5
## — "we banned that" — it lived here through round 4. dropShapesNearSpawns
## is the only remaining pocket-aware step: a post-hoc carve, not a
## placement exclusion.

proc placeUniformPoi(
  rng: var Rand, sites: var seq[PoiSite], width, height, minSep: int,
  archetype: PoiArchetype, halfExtent, lootTier: int
): bool =
  ## TRUE uniform rejection sampling over the WHOLE playable field. ROUND 5
  ## (Maxwell's ruling, doctrine §4.2/§4.7): no pocket-avoidance at all —
  ## "we banned that" — a structure landing next to a spawn is a landing
  ## site, not a violation; only OTHER sites' minimum separation applies.
  ## Returns whether it found a spot, so callers can track how many of a
  ## target count actually landed.
  const MaxAttempts = 400
  let margin = halfExtent + 60
  let xLo = margin
  let xHi = width - margin
  let yLo = margin
  let yHi = height - margin
  if yHi <= yLo or xHi <= xLo:
    return false
  for attempt in 0 ..< MaxAttempts:
    let x = xLo + rng.rand(xHi - xLo)
    let y = yLo + rng.rand(yHi - yLo)
    let p = MapPoint(x: x, y: y)
    if tooCloseToAnySized(p, archetype, halfExtent, sites, minSep): continue
    sites.add PoiSite(center: p, archetype: archetype, halfExtent: halfExtent, lootTier: lootTier)
    when defined(brDebugExit):
      stderr.writeLine(&"  POI placed {archetype} at ({p.x},{p.y}) halfExtent={halfExtent} attempt={attempt}")
    return true
  when defined(brDebugExit):
    stderr.writeLine(&"  POI FAILED entirely: archetype={archetype}")
  false

type ArchSpec = tuple[arch: PoiArchetype, halfFrac: float, lootTier: int]

proc placeWeightedPool(
  rng: var Rand, sites: var seq[PoiSite], width, height, gunRange: int,
  pool: seq[ArchSpec], minSepFrac: float, count: int
) =
  let minSep = int(minSepFrac * float(gunRange))
  for i in 0 ..< count:
    let spec = pool[rng.rand(pool.len - 1)]
    let halfExtent = int(spec.halfFrac * float(gunRange))
    discard placeUniformPoi(rng, sites, width, height, minSep,
      spec.arch, halfExtent, spec.lootTier)

# --- stratified placement (round 8) -------------------------------------------
## Doctrine round 8, item 4: "K regions, one POI per region first, extras
## after — fixes round 7's left/top clustering simultaneously." Round 5's
## `placeUniformPoi` is true rejection sampling over the WHOLE field, which
## is unbiased in expectation but has no per-draw guarantee against
## clustering — a run of unlucky rolls can (and, on the round-7 sheet, did)
## land several sites in the same quadrant while another sits empty. This
## doesn't replace uniform sampling's minSep discipline (every call below
## still runs through placeUniformPoi's or its rect-scoped twin's own
## rejection test against every already-placed site); it just seeds one
## deliberate placement per region FIRST, so no region can come up empty
## by chance the way round 7's could.

proc placeUniformPoiInRect(
  rng: var Rand, sites: var seq[PoiSite], rect: MapRect, fieldW, fieldH, minSep: int,
  archetype: PoiArchetype, halfExtent, lootTier: int
): bool =
  ## Same rejection-sampling contract as placeUniformPoi, but the candidate
  ## is drawn from ONE region's rect (still clamped to the field-margin
  ## every POI already respects) instead of the whole field. minSep is
  ## still checked against every OTHER already-placed site globally, so
  ## two adjacent regions can never place sites closer than minSep to each
  ## other just because they're in different rects.
  const MaxAttempts = 200
  let margin = halfExtent + 60
  let xLo = max(margin, rect.x)
  let xHi = min(fieldW - margin, rect.x + rect.w)
  let yLo = max(margin, rect.y)
  let yHi = min(fieldH - margin, rect.y + rect.h)
  if xHi <= xLo or yHi <= yLo:
    return false
  for attempt in 0 ..< MaxAttempts:
    let x = xLo + rng.rand(xHi - xLo)
    let y = yLo + rng.rand(yHi - yLo)
    let p = MapPoint(x: x, y: y)
    if tooCloseToAnySized(p, archetype, halfExtent, sites, minSep): continue
    sites.add PoiSite(center: p, archetype: archetype, halfExtent: halfExtent, lootTier: lootTier)
    return true
  false

proc regionGrid(n, width, height: int): tuple[cols, rows: int] =
  ## Smallest cols x rows grid (matched to the field's own aspect, so
  ## regions read roughly square-ish rather than tall slivers) with
  ## cols*rows >= n, so the first `n` POIs can each get their own region.
  if n <= 1: return (1, 1)
  let aspect = float(width) / float(height)
  var rows = max(1, int(round(sqrt(float(n) / aspect))))
  var cols = (n + rows - 1) div rows
  while cols * rows < n:
    inc rows
    cols = (n + rows - 1) div rows
  (cols, rows)

proc regionRects(width, height, cols, rows: int): seq[MapRect] =
  let cw = width div cols
  let ch = height div rows
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let x = c * cw
      let y = r * ch
      let w = if c == cols - 1: width - x else: cw
      let h = if r == rows - 1: height - y else: ch
      result.add MapRect(x: x, y: y, w: w, h: h)

proc placeStratifiedPool(
  rng: var Rand, sites: var seq[PoiSite], width, height, gunRange: int,
  pool: seq[ArchSpec], minSepFrac: float, count: int
) =
  ## Phase 1: one placement attempt per region (shuffled order, so which
  ## region gets skipped when its own attempt fails isn't corner-biased).
  ## Phase 2: whatever's left of `count` falls back to whole-field uniform
  ## sampling (round 7's method) — a region can legitimately fail (already
  ## crowded by a neighbour's minSep), so the fallback is what makes
  ## `count` a real target rather than an aspiration.
  let minSep = int(minSepFrac * float(gunRange))
  let (cols, rows) = regionGrid(count, width, height)
  var regions = regionRects(width, height, cols, rows)
  rng.shuffle(regions)
  var placed = 0
  for rect in regions:
    if placed >= count: break
    let spec = pool[rng.rand(pool.len - 1)]
    let halfExtent = int(spec.halfFrac * float(gunRange))
    if placeUniformPoiInRect(rng, sites, rect, width, height, minSep,
        spec.arch, halfExtent, spec.lootTier):
      inc placed
  while placed < count:
    let spec = pool[rng.rand(pool.len - 1)]
    let halfExtent = int(spec.halfFrac * float(gunRange))
    if placeUniformPoi(rng, sites, width, height, minSep, spec.arch, halfExtent, spec.lootTier):
      inc placed
    else:
      break  ## field genuinely has no room left; stop rather than spin

proc placePois(
  rng: var Rand, width, height, gunRange: int, keystone: KeystoneFamily
): seq[PoiSite] =
  ## ROUND 5 (Maxwell's ruling, doctrine §4.7): "the room and obstacle
  ## density needs to be roughly uniform across the entire map, not
  ## focused in the center." Every POI is placed by uniform rejection
  ## sampling over the whole field with a minimum-separation disc, no
  ## pocket-avoidance — that discipline is UNCHANGED and applies to every
  ## family below (density-uniformity stays a binding gate regardless of
  ## keystone).
  ##
  ## ROUND 6 (Maxwell's ruling, doctrine §2.4): uniform density answers
  ## WHERE; the keystone answers WHAT and HOW. Each family below picks a
  ## different archetype pool, size-variance profile, minimum-separation
  ## (spacing IS a grammar knob — tight packing reads as CQC, wide spacing
  ## reads as open ground), and in two cases a placement STRATEGY (spread-
  ## anchors, cluster-and-gap) rather than pure uniform sampling. This is
  ## what answers "a bunch of random rectangle rooms": a keystone map has
  ## a FEW LARGER organizing structures (anchors, causeways, clusters)
  ## rising out of the uniform field, not just more of the same four boxes.
  ## ROUND 7 (Maxwell's verdict): "still confetti maps... on a larger
  ## scale." A full-field side-by-side against Maxwell's reference
  ## (/tmp/br-maps/caves_404_thick.png) showed the real problem AFTER the
  ## subtractive rework — each mass reads solid now, but a giant 3211x1713
  ## field with 10-22 of them still looks like scatter from an overview.
  ## ROUND 8 (Maxwell's verdict on round 7's sheet: "THESE MAPS ARE STILL
  ## farrrrrrrrr too barren" — bold masses, far too few). Round 7's own
  ## <=12-18 target was undershot in practice (6-13 actually shipped) and,
  ## worse, wasn't even the right ceiling — the CTF program's own reference
  ## (caves_404, 150‰) runs at 3x round 7's measured cover. POI counts
  ## below are bumped back to the 12-18 doctrine actually asked for, EVERY
  ## family now places via `placeStratifiedPool`/rect-scoped placement
  ## (round-8 item 4: "K regions, one POI per region first, extras after"),
  ## and every non-rotation-timing family gets a small top-up of
  ## connective causeways (below, after the case) — "more/longer thick
  ## causeway runs" isn't scoped to one keystone. open-steppe is the
  ## deliberate exception: its identity IS fewer structures, so its count
  ## stays modest and it leans on the (also round-8-restored) heavy caves
  ## fill to reach the same cover/mass bands as everyone else — organic
  ## terrain standing in for authored structure is exactly what "open
  ## steppe" should look like.
  case keystone
  of ksLandingSelection:
    ## Steep loot/size gradient BETWEEN sites: a few rich, LARGE anchors
    ## (tier 0) against many poor, SMALL ruins (tier 2), almost nothing in
    ## between. ROUND 8 recalibration: measured mass count averaged 20.1
    ## (need 25+) at the round-8-launch pool/count — the fix is MORE
    ## ruins (cheap, small, doesn't dilute the size gradient the keystone
    ## detector measures) plus a higher total count and a tighter minSep
    ## (1.15G -> 1.0G, since 6 ruins packing at the old spacing was itself
    ## limiting how many could land), not bigger anchors.
    let pool: seq[ArchSpec] = @[
      (poiCompound, 1.30, 0),
      (poiAnchor, 1.15, 0),
      (poiOutpost, 0.50, 1),
      (poiOutpost, 0.50, 1),
      (poiRuins, 0.16, 2),
      (poiRuins, 0.16, 2),
      (poiRuins, 0.16, 2),
      (poiRuins, 0.16, 2),
      (poiRuins, 0.16, 2),
      (poiRuins, 0.16, 2),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, pool, 1.0, 18 + rng.rand(5))
  of ksRotationTiming:
    ## Long causeways + clusters separated by open seams: crossing timing
    ## is the skill. Clusters first (STRATIFIED across regions so they
    ## can't all land in one corner — round 8 item 4), then TWO satellites
    ## per cluster (round-8 recalibration: measured mass count averaged
    ## 21.5 at one satellite; a keystone whose grammar IS "open seams
    ## between clusters" can't just inflate cluster SIZE without fighting
    ## its own identity, so the fix is more small satellites, not bigger
    ## clusters), then a bigger handful of longer causeways (half-extent
    ## > gunRange, so length > 2G) — round 8 item 3c's flagship family.
    let clusterCount = 3 + rng.rand(3)
    let clusterMinSep = int(1.6 * float(gunRange))
    let clusterHalf = int(0.55 * float(gunRange))
    let (ccols, crows) = regionGrid(clusterCount, width, height)
    var clusterRegions = regionRects(width, height, ccols, crows)
    rng.shuffle(clusterRegions)
    var clusterAnchors: seq[MapPoint]
    for i in 0 ..< clusterCount:
      if i >= clusterRegions.len: break
      let before = result.len
      discard placeUniformPoiInRect(rng, result, clusterRegions[i], width, height,
        clusterMinSep, poiOutpost, clusterHalf, 1)
      if result.len > before:
        clusterAnchors.add result[^1].center
    for anchor in clusterAnchors:
      for satNum in 0 ..< 2:
        for attempt in 0 ..< 20:
          let ang = rng.rand(2.0 * PI)
          let dist = float(clusterHalf) + 50.0 + float(rng.rand(140))
          let px = clamp(anchor.x + int(cos(ang) * dist),
            clusterHalf + 60, width - clusterHalf - 60)
          let py = clamp(anchor.y + int(sin(ang) * dist),
            clusterHalf + 60, height - clusterHalf - 60)
          let p = MapPoint(x: px, y: py)
          let localMinSep = int(0.32 * float(gunRange))
          ## ROUND 9 FIX (found chasing an interiorConn failure): this used
          ## to call the SIZE-BLIND `tooCloseToAny` with a flat 106px
          ## (0.32G) threshold — fine as a floor for the satellite's OWN
          ## distance from its parent anchor (enforced separately by the
          ## dist= formula above), but it's also the ONLY check against
          ## every OTHER already-placed site (a different cluster's
          ## anchor, an earlier satellite, a genFiller item), and 106px
          ## is far smaller than two real footprints need — a poiOutpost
          ## cluster anchor (he=182) and a poiYard satellite (he=132) can
          ## legitimately need ~350px of separation, so a satellite could
          ## land with its footprint fully INSIDE an unrelated anchor's
          ## shell, sealing that anchor's gates from outside. Measured:
          ## rotation-timing seed 103 had exactly this — a poiYard
          ## satellite's footprint swallowed an unrelated outpost's gates,
          ## stranding all 3 of that outpost's rooms (and the yard's own
          ## room) from the map's dominant walkable component. Compute
          ## arch/he FIRST and use `tooCloseToAnySized` — same fix as the
          ## round-8 note on this exact function, just never applied here.
          let arch = if rng.rand(1) == 0: poiRuins else: poiYard
          let he = int((if arch == poiRuins: 0.30 else: 0.40) * float(gunRange))
          if tooCloseToAnySized(p, arch, he, result, localMinSep): continue
          result.add PoiSite(center: p, archetype: arch, halfExtent: he,
            lootTier: (if arch == poiRuins: 2 else: 1))
          break
    let causewayCount = 6 + rng.rand(4)  ## round 8: 3-6 -> 6-9, the keystone's own signature
    let causewayHalf = int(1.5 * float(gunRange))  ## > G, so length > 3.0G
    let causewayMinSep = int(0.7 * float(gunRange))
    for i in 0 ..< causewayCount:
      discard placeUniformPoi(rng, result, width, height, causewayMinSep,
        poiCauseway, causewayHalf, 1)
    ## ROUND 8 recalibration #2: rotation-timing measured the WORST
    ## combined pass rate of the three delivery families (mass/cover/
    ## distToCover all lagging) — clusters+causeways alone leave real gaps
    ## since the keystone's whole identity is "open seams between
    ## clusters." A light general-purpose ruins filler patches the worst
    ## gaps (small, cheap, doesn't compete with the causeway-count
    ## detector since poiRuins never counts toward it) without fighting
    ## the "open seams" grammar the way more/bigger clusters would.
    let genFillerPool: seq[ArchSpec] = @[
      (poiRuins, 0.22, 2), (poiRuins, 0.22, 2), (poiYard, 0.30, 1),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, genFillerPool, 0.9, 5 + rng.rand(4))
  of ksZoneEdgeHolding:
    ## A handful of ANCHOR compounds, STRATIFIED across regions (so no two
    ## end up sharing a corner even before the mutual minSep is checked) —
    ## still spread with a LARGE mutual minSep so no two are ever close
    ## enough to trade one holder for another. Filler on top, bumped
    ## substantially (round 8) so the map isn't just a few anchors on bare
    ## ground between them.
    ## ROUND 8 recalibration #2: anchorHalf trimmed 1.25G -> 1.05G — the
    ## bigger anchors were routinely fusing with nearby filler/caves into
    ## a few sprawling components (measured cover up to 185‰, MASS COUNT
    ## as low as 17 on the same seed — cover and count moving opposite
    ## directions is the "few giant blobs" failure mode, not "fat and
    ## numerous"). Still the biggest single archetype on the map; still
    ## comfortably above every other family's own anchor floor.
    ## ROUND 9 note: dropShapesNearSpawns' clip-vs-drop change (see that
    ## proc's comment) is now SIZE-GATED — only pieces under ~2x the
    ## confetti floor clip; a full anchor shell side is well above that,
    ## so it still drops exactly as round 8 calibrated. anchorHalf stays
    ## at round 8's own 1.05G.
    let anchorHalf = int(0.62 * float(gunRange))
    let anchorMinSep = int(1.9 * float(gunRange))
    let anchorCount = 4 + rng.rand(3)
    let (acols, arows) = regionGrid(anchorCount, width, height)
    var anchorRegions = regionRects(width, height, acols, arows)
    rng.shuffle(anchorRegions)
    for i in 0 ..< anchorCount:
      if i >= anchorRegions.len: break
      discard placeUniformPoiInRect(rng, result, anchorRegions[i], width, height,
        anchorMinSep, poiAnchor, anchorHalf, 0)
    ## ROUND 8 recalibration: measured mass count averaged 21.5, cover
    ## often already 150-179 (near/over ceiling) — the anchors alone
    ## already carry plenty of AREA; what's short is COUNT. More filler,
    ## weighted smaller (more ruins) and tighter-packed (0.85G), adds mass
    ## count without pushing cover further past the ceiling.
    let fillerPool: seq[ArchSpec] = @[
      (poiOutpost, 0.38, 1), (poiYard, 0.38, 1),
      (poiRuins, 0.22, 2), (poiRuins, 0.22, 2), (poiRuins, 0.22, 2),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, fillerPool, 0.85, 9 + rng.rand(4))
  of ksThirdParty:
    ## Open interiors only — NO sealed compounds (poiCompound/poiAnchor
    ## excluded from the pool entirely), warren-heavy so most sites have
    ## 3+ approaches. Tighter spacing than the baseline so fights happen
    ## close enough together to interrupt each other.
    let pool: seq[ArchSpec] = @[
      (poiWarren, 0.60, 1), (poiWarren, 0.60, 1), (poiWarren, 0.60, 1),
      (poiYard, 0.55, 1), (poiYard, 0.55, 1),
      (poiOutpost, 0.48, 1),
      (poiRuins, 0.28, 2), (poiRuins, 0.28, 2),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, pool, 1.0, 13 + rng.rand(5))
  of ksCqcWarren:
    ## Interior-share dial, HIGH pole: warren-heavy pool, TIGHT minimum
    ## separation — packing is itself the grammar knob that reads as
    ## close-quarters.
    let pool: seq[ArchSpec] = @[
      (poiWarren, 0.58, 1), (poiWarren, 0.58, 1), (poiWarren, 0.58, 1),
      (poiWarren, 0.58, 1), (poiWarren, 0.58, 1),
      (poiOutpost, 0.48, 1),
      (poiRuins, 0.26, 2), (poiRuins, 0.26, 2),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, pool, 0.85, 15 + rng.rand(4))
  of ksOpenSteppe:
    ## Interior-share dial, LOW pole: sparse pool (mostly small ruins),
    ## few sites, WIDE minimum separation — open ground between cover is
    ## the grammar knob that reads as steppe. Deliberately NOT bumped as
    ## hard as the other five families (round 8): more structures here
    ## would fight the keystone's own low-footprint-share identity. The
    ## restored heavy caves fill (generateBrMap) is what carries this
    ## family into the cover-permille/total-mass bands instead — organic
    ## terrain, not authored buildings, is the correct texture for
    ## "steppe."
    let pool: seq[ArchSpec] = @[
      (poiRuins, 0.22, 2), (poiRuins, 0.22, 2), (poiRuins, 0.22, 2),
      (poiYard, 0.34, 1),
      (poiOutpost, 0.34, 1),
    ]
    placeStratifiedPool(rng, result, width, height, gunRange, pool, 1.5, 6 + rng.rand(3))

  ## ROUND 8, item 3c: "more/longer thick causeway runs" — every family
  ## except rotation-timing (which already places a bigger, keystone-
  ## defining set above) gets a small top-up of connective causeways.
  ## Long thick linear mass is cheap, welds naturally at both ends against
  ## whatever it crosses near, and doctrine's causeway push isn't scoped
  ## to one keystone — multi-scale mass (POI + causeway + caves) should be
  ## present everywhere.
  if keystone != ksRotationTiming:
    let extraCausewayCount = 2 + rng.rand(2)  ## 2-3
    let extraCausewayHalf = int(1.1 * float(gunRange))
    let extraCausewayMinSep = int(0.7 * float(gunRange))
    for i in 0 ..< extraCausewayCount:
      discard placeUniformPoi(rng, result, width, height, extraCausewayMinSep,
        poiCauseway, extraCausewayHalf, 1)

proc poiFootprintRect(site: PoiSite): MapRect =
  MapRect(x: site.center.x - site.halfExtent, y: site.center.y - site.halfExtent,
    w: 2 * site.halfExtent, h: 2 * site.halfExtent)

proc rectsOverlap(a, b: MapRect, pad: int): bool =
  not (a.x + a.w + pad < b.x or b.x + b.w + pad < a.x or
    a.y + a.h + pad < b.y or b.y + b.h + pad < a.y)

proc pointNearAnyPoi(p: MapPoint, pois: seq[PoiSite], pad: int): bool =
  for site in pois:
    let f = poiFootprintRect(site)
    if p.x >= f.x - pad and p.x <= f.x + f.w + pad and
        p.y >= f.y - pad and p.y <= f.y + f.h + pad:
      return true
  false

proc decimatePolygon(shape: ArenaShape, keepEvery: int): ArenaShape =
  ## ROUND 8 (spec-byte budget): keep every `keepEvery`-th vertex of a
  ## polygon shape. mapgen_styles.blobPolygon's wobble is two low-frequency
  ## sinusoids, so uniform decimation still traces the same silhouette at
  ## a coarser sample rate — at this tool's render scale (giant field
  ## downscaled to a 1600px thumbnail) a 7-vertex blob and a 14-vertex one
  ## are visually indistinguishable, but the spec-JSON cost is halved.
  ## Never decimates below blobPolygon's own 6-vertex floor.
  if shape.kind != shapePolygon or keepEvery <= 1 or shape.points.len <= 6:
    return shape
  var pts: seq[MapPoint]
  var i = 0
  while i < shape.points.len:
    pts.add shape.points[i]
    i += keepEvery
  if pts.len < 6: return shape
  ArenaShape(kind: shapePolygon, window: shape.window, points: pts)

proc linearConnectors(
  rng: var Rand, pois: seq[PoiSite]
): seq[ArenaShape] =
  ## "Continuous linear features" between POIs (coordinator, round 3) —
  ## screens for the rotation AND grain for the field. ROUND 7 (Maxwell's
  ## verdict): "continuous thick walls with 1-2 deliberate gate gaps —
  ## never dash runs." The old design (46px segments, ~38% dropped every
  ## 85px) was EXACTLY a dash run — a direct confetti source, each
  ## surviving segment (598px^2) individually far under the 3000px^2
  ## floor and disconnected from its neighbours by the deliberate gaps.
  ## Rebuilt on the SAME construction as poiCauseway: one run split into
  ## 1-2 pieces by 1-2 real gate gaps, each piece thick (26px) and long
  ## enough to individually clear the confetti floor on its own.
  ## Connects each POI to its nearest neighbour (a cheap near-MST: not
  ## every pair, so the field doesn't turn into a lattice).
  const Thick = 26
  var connected: seq[(int, int)]
  for i in 0 ..< pois.len:
    var bestJ = -1
    var bestD = high(int)
    for j in 0 ..< pois.len:
      if i == j: continue
      let dx = pois[i].center.x - pois[j].center.x
      let dy = pois[i].center.y - pois[j].center.y
      let d = dx * dx + dy * dy
      if d < bestD:
        bestD = d
        bestJ = j
    if bestJ >= 0:
      let key = if i < bestJ: (i, bestJ) else: (bestJ, i)
      if key notin connected:
        connected.add key
  for (i, j) in connected:
    let a = pois[i].center
    let b = pois[j].center
    let dx = float(b.x - a.x)
    let dy = float(b.y - a.y)
    let fullLength = sqrt(dx * dx + dy * dy)
    if fullLength < 1.0: continue
    let ux = dx / fullLength
    let uy = dy / fullLength
    ## Run only spans the gap BETWEEN the two POI footprints, not center
    ## to center — same margin the old dash run used.
    let runStart = float(pois[i].halfExtent) + 40.0
    let runEnd = fullLength - float(pois[j].halfExtent) - 40.0
    let runLen = runEnd - runStart
    ## Each piece doesn't touch the POI shells (there's a deliberate 40px
    ## gap so it never overlaps a POI's own footprint), so it must clear
    ## the confetti floor ON ITS OWN: at Thick=26, that's >=116px long.
    ## Skip the whole connector rather than emit a piece that can't.
    const MinPieceLen = 120.0
    if runLen < MinPieceLen: continue
    let gateCount = if runLen > 2.0 * MinPieceLen + 150.0: 1 + rng.rand(1) else: 0
    let gateW = if gateCount == 0: 0.0 else: 60.0 + float(rng.rand(30))
    let pieceLen = (runLen - float(gateCount) * gateW) / float(gateCount + 1)
    if pieceLen < MinPieceLen: continue
    var t = runStart
    for k in 0 ..< gateCount + 1:
      let segStart = t
      let segEnd = t + pieceLen
      let p0x = a.x.float + ux * segStart
      let p0y = a.y.float + uy * segStart
      let p1x = a.x.float + ux * segEnd
      let p1y = a.y.float + uy * segEnd
      ## ROUND 5: no pocket-avoidance at placement time (Maxwell's ruling
      ## — "we banned that"). dropShapesNearSpawns still carves the tiny
      ## duo pocket clear afterward, same as every other wall shape.
      result.add ArenaShape(
        kind: shapeDiagonal, x0: int(p0x), y0: int(p0y), x1: int(p1x), y1: int(p1y),
        thickness: Thick)
      t = segEnd + gateW

proc caveFillPatches(
  style: MapStyle, styleSeed: int, region: MapRect, patchCols, patchRows: int,
  baseParams: StyleParams
): seq[ArenaShape] =
  ## ROUND 8 (doctrine items 3b + 4): one independent CA pass PER REGION
  ## instead of one pass over the whole field. Measured: a single field-
  ## wide CA run near its own percolation threshold reliably fuses into
  ## one or two GIANT sprawling components (a single ~180,000px^2 blob
  ## eating most of the cover budget while every other mass stayed
  ## POI-sized) — "fat and numerous" needs MANY separate fat masses, not
  ## one huge one wearing a numerous shape-count. Patching the caves
  ## generator the same way POI placement is stratified (item 4) buys
  ## both properties at once: each patch's CA run is self-contained (so
  ## it welds into its OWN blob, capped by its own patch size, never the
  ## whole field's), and patches tile the field uniformly (so caves fill
  ## inherits the same anti-clustering guarantee POIs get — no seed can
  ## dump every cave into one corner).
  let rawPatches = regionRects(region.w, region.h, patchCols, patchRows)
  const Inset = 24  ## keeps adjacent patches' terrain from touching pixel-
                     ## for-pixel and reading as a grid seam
  for i, rp in rawPatches:
    let patch = MapRect(x: region.x + rp.x, y: region.y + rp.y, w: rp.w, h: rp.h)
    if patch.w <= 2 * Inset or patch.h <= 2 * Inset: continue
    let sub = MapRect(x: patch.x + Inset, y: patch.y + Inset,
      w: patch.w - 2 * Inset, h: patch.h - 2 * Inset)
    let patchSeed = styleSeed xor (0x1000_0000 + i * 0x9E37_79B1)
    result.add generateShapes(style, patchSeed, sub, baseParams)

proc generateBrMap(
  seed: int, style: MapStyle, paramsIn: StyleParams, keystone: KeystoneFamily
): BrMap =
  let (w, h) = fieldSize(GiantScale)
  result.name = "br-gen-" & $seed
  result.genSeed = seed
  result.style = style
  result.width = w
  result.height = h
  result.groups = Groups
  result.seatsPerGroup = SeatsPerGroup
  result.zoneZ = ZoneZ
  result.keystone = keystone
  result.gunRange = deriveGunRange(w, h, Groups)
  let (cw, ch) = spawnClearance(GiantScale)
  result.spawnClearW = cw
  result.spawnClearH = ch
  var spawnRng = initRand(seed xor 0x1A2B_3C4D)
  result.spawns = gridSpawns(spawnRng, w, h, Groups)
  ## `pockets` is now used ONLY as the post-hoc CARVE (dropShapesNearSpawns,
  ## ensurePerSpawnCover, the exit-rule ring, zone-viability) — never as a
  ## placement exclusion. Round 5 (Maxwell's ruling): "we banned that."
  let pockets = result.spawns.mapIt(pocketRect(it, cw, ch))

  ## ROUND 3 (Maxwell's rejection, 2026-08-24): "no rooms, no alleys, no
  ## items, no intention — the generator is clearly not working here." CA
  ## blobs alone cannot BE a battle-royale map. POIs are drawn FIRST — the
  ## layout grammar / intention — and everything else (connectors, caves
  ## fill) composes around them instead of the other way around.
  var poiRng = initRand(seed xor 0x7F4A_2C11)
  result.pois = placePois(poiRng, w, h, result.gunRange, keystone)

  ## ROUND 9 (doctrine item 6's room-count-variety gate): pre-assign a
  ## shuffled, ascending sequence of room-count HINTS across every
  ## room-eligible POI before stamping any of them — see stampPoi's own
  ## comment for why this replaced "let each structure roll its own
  ## target independently."
  var roomEligibleIdx: seq[int]
  for i in 0 ..< result.pois.len:
    if result.pois[i].archetype in {poiCompound, poiOutpost, poiAnchor, poiWarren}:
      roomEligibleIdx.add i
  var diversityRng = initRand(seed xor 0x5A11_9902)
  diversityRng.shuffle(roomEligibleIdx)
  var roomHints = newSeq[int](result.pois.len)
  const DiversityTargets = [1, 2, 3, 4, 5, 6, 7, 8]
  for k, idx in roomEligibleIdx:
    if k < DiversityTargets.len:
      roomHints[idx] = DiversityTargets[k]

  var structures: seq[ArenaShape]
  for i in 0 ..< result.pois.len:
    let site = result.pois[i]
    var stampRng = initRand(seed xor 0x9B1E_44D7 xor (site.center.x * 131071 + site.center.y))
    ## ROUND 9: stampPoi now also returns the site's floor plan (the room
    ## list) — written back into result.pois[i] so item placement
    ## (per-room, doctrine item 5) and metrics (per-structure room
    ## counts, item 2) can read it later.
    let plan = stampPoi(stampRng, site, roomHints[i])
    structures.add plan.shapes
    result.pois[i].rooms = plan.rooms

  var connectorRng = initRand(seed xor 0x2E9D_7731)
  let connectors = linearConnectors(connectorRng, result.pois)

  ## ROUND 3: caves DEMOTED to organic fill between structures — kept, but
  ## ROUND 8 (Maxwell's verdict on round 7's sheet: "THESE MAPS ARE STILL
  ## farrrrrrrrr too barren"; doctrine item 3b: "RESTORE the organic caves
  ## masses as heavy between-places fill — fat and numerous... they're the
  ## cheapest legitimate mass") un-demotes it back toward a PRIMARY mass
  ## contributor, not a light dusting. Round 3-7's clamps (fillProb<=0.16,
  ## blobScale<=0.75) are what starved the field between POIs; both are
  ## raised substantially below. Still dropped wherever it would overlap a
  ## POI footprint or a connector run (a blob eating a doorway reads as a
  ## bug, not terrain).
  let region = placementRegion(w, h)
  var params = paramsIn
  params.noAnchors = true
  ## ROUND 8: measured 0.50 as the safe ceiling under the per-patch B4/D3
  ## rule (0.55 already over-covers on several families — see the round-8
  ## commit message's sweep). 1.0 blobScale keeps each cell's blob nearly
  ## cell-sized (the "fat" half of "fat and numerous").
  params.fillProb = min(params.fillProb, 0.50)
  params.blobScale = min(params.blobScale, 1.0)
  ## ROUND 8: PATCHED, not one field-wide CA pass — see caveFillPatches'
  ## own comment. CaveFillPatchCols/Rows tile the placement region into
  ## ~15 roughly-square cells matched to the field's own aspect.
  let caveRaw = caveFillPatches(style, seed xor styleSalt, region,
    CaveFillPatchCols, CaveFillPatchRows, params)
  ## ROUND 8 FIX: the clash test used to check each cave shape against
  ## `poiFootprintRect(site)` — a SQUARE of side 2*halfExtent. That's a
  ## reasonable stand-in for a compound/anchor/outpost/yard/ruins/warren
  ## (all roughly square), but poiCauseway's halfExtent is a HALF-LENGTH
  ## along an arbitrary drawn axis, not a radius — the square estimate for
  ## a causeway with halfExtent ~1.5G was a ~992x992px block (~984,000px^2)
  ## standing in for a shape whose REAL footprint (a few 30px-thick
  ## diagonal segments) is under 30,000px^2. With round 8's causeway count
  ## bumped up across every family, that overestimate was excluding most
  ## of the field from caves placement and silently zeroing out caveFill
  ## entirely on several seeds. Fixed by testing against the ACTUAL
  ## stamped shapes' own bounding boxes (structures + connectors, both
  ## already built above) instead of a per-archetype guess.
  let authoredSoFar = structures & connectors
  when defined(brDebugCaves):
    stderr.writeLine(&"DEBUG caveRaw={caveRaw.len} authoredSoFar={authoredSoFar.len} region=({region.x},{region.y},{region.w},{region.h}) fillProb={params.fillProb} blobScale={params.blobScale} cell={params.cell}")
  var caveFill: seq[ArenaShape]
  for shape in caveRaw:
    let b = shapeBounds(shape)
    var clash = false
    for astruct in authoredSoFar:
      let ab = shapeBounds(astruct)
      if rectsOverlap(MapRect(x: b.x0, y: b.y0, w: b.x1 - b.x0, h: b.y1 - b.y0),
          MapRect(x: ab.x0, y: ab.y0, w: ab.x1 - ab.x0, h: ab.y1 - ab.y0), 24):
        clash = true
        break
    if not clash:
      ## ROUND 8 (spec-byte budget: "coarser perimeter polygons where
      ## needed" — at 3x the mass, hundreds of genCaves' own fixed-14-vert
      ## blobs would blow well past the 58KB spec budget on their own;
      ## mapgen_styles.genCaves stays UNMODIFIED per this file's own reuse
      ## contract, so the cut happens here instead).
      caveFill.add decimatePolygon(shape, CaveFillVertDecimate)

  ## Kept as two separately-dropped groups (not one merged list) so the
  ## authored/fill split survives dropShapesNearSpawns' filtering intact —
  ## structureCount has to describe the FINAL obstacles list, after pockets
  ## have already removed whatever they're going to remove from each half.
  let structuresKept = dropShapesNearSpawns(structures & connectors, pockets)
  let caveFillKept = dropShapesNearSpawns(caveFill, pockets)
  when defined(brDebugCaves):
    stderr.writeLine(&"DEBUG2 caveRaw={caveRaw.len} caveFillPostClash={caveFill.len} caveFillKept={caveFillKept.len}")
  result.structureCount = structuresKept.len
  result.obstacles = structuresKept & caveFillKept

# --- spec JSON (own schema; shape grammar matches arena.nim's wire format so
# it stays engine-compatible once the BR spawn/flagless lanes land) ----------

proc shapeSpecNode(shape: ArenaShape): JsonNode =
  result = newJObject()
  case shape.kind
  of shapeRect:
    result["kind"] = %"rect"
    result["x"] = %shape.rect.x
    result["y"] = %shape.rect.y
    result["w"] = %shape.rect.w
    result["h"] = %shape.rect.h
  of shapeDisc, shapeDiamond:
    result["kind"] = %(if shape.kind == shapeDisc: "disc" else: "diamond")
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["r"] = %shape.radius
  of shapeDiagonal:
    result["kind"] = %"diagonal"
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["t"] = %shape.thickness
  of shapePolygon:
    result["kind"] = %"polygon"
    var pts = newJArray()
    for p in shape.points: pts.add %*[p.x, p.y]
    result["points"] = pts
  if shape.window: result["window"] = %true

proc shapeFromSpecNode(node: JsonNode): ArenaShape =
  let window = node{"window"}.getBool(false)
  case node["kind"].getStr()
  of "rect":
    ArenaShape(kind: shapeRect, window: window, rect: MapRect(
      x: node["x"].getInt(), y: node["y"].getInt(),
      w: node["w"].getInt(), h: node["h"].getInt()))
  of "disc":
    ArenaShape(kind: shapeDisc, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(), radius: node["r"].getInt())
  of "diamond":
    ArenaShape(kind: shapeDiamond, window: window,
      cx: node["cx"].getInt(), cy: node["cy"].getInt(), radius: node["r"].getInt())
  of "diagonal":
    ArenaShape(kind: shapeDiagonal, window: window,
      x0: node["x0"].getInt(), y0: node["y0"].getInt(),
      x1: node["x1"].getInt(), y1: node["y1"].getInt(), thickness: node["t"].getInt())
  of "polygon":
    var pts: seq[MapPoint]
    for pt in node["points"]: pts.add MapPoint(x: pt[0].getInt(), y: pt[1].getInt())
    ArenaShape(kind: shapePolygon, window: window, points: pts)
  else:
    raise newException(CtfError, "Unknown BR spec shape: " & node["kind"].getStr())

proc pointsNode(points: seq[MapPoint]): JsonNode =
  result = newJArray()
  for p in points: result.add %*[p.x, p.y]

proc pointsFromNode(node: JsonNode): seq[MapPoint] =
  if node.isNil or node.kind != JArray: return
  for item in node: result.add MapPoint(x: item[0].getInt(), y: item[1].getInt())

proc styleToStr(s: MapStyle): string =
  case s
  of styleBsp: "bsp"
  of styleCaves: "caves"
  of styleMaze: "maze"
  of styleScatter: "scatter"

proc keystoneToStr(k: KeystoneFamily): string =
  case k
  of ksLandingSelection: "landing-selection"
  of ksRotationTiming: "rotation-timing"
  of ksZoneEdgeHolding: "zone-edge-holding"
  of ksThirdParty: "third-party"
  of ksCqcWarren: "cqc-warren"
  of ksOpenSteppe: "open-steppe"

proc keystoneFromStr(s: string): KeystoneFamily =
  case s
  of "landing-selection": ksLandingSelection
  of "rotation-timing": ksRotationTiming
  of "zone-edge-holding": ksZoneEdgeHolding
  of "third-party": ksThirdParty
  of "cqc-warren": ksCqcWarren
  of "open-steppe": ksOpenSteppe
  else: raise newException(CtfError, "Unknown BR keystone family: " & s)

proc keystoneFromSeed(seed: int): KeystoneFamily =
  ## Deterministic default when --keystone isn't given: every draw MUST
  ## declare a keystone (doctrine §2.4 — "every map declares its keystone
  ## ability at draw"), never an implicit/undeclared one.
  let n = ord(high(KeystoneFamily)) + 1
  KeystoneFamily(((seed mod n) + n) mod n)

proc brMapSpecJson(m: BrMap): string =
  ## spawnPoints grammar confirmed with the spawn-points lane (branch
  ## maxwell/br-spawn, 2026-08-24): top-level "spawnPoints" key, team-major
  ## flattened seq[MapPoint] encoded like pointsNode(), perTeam = len div
  ## teamCount. Here teamCount = groups = 16, perTeam = 1 -> 16 points in
  ## ring order.
  var shapes = newJArray()
  for shape in m.obstacles: shapes.add shape.shapeSpecNode()
  var spawnPts = newJArray()
  for s in m.spawns: spawnPts.add %*[s.p.x, s.p.y]
  var poiNodes = newJArray()
  for site in m.pois:
    var roomNodes = newJArray()
    for r in site.rooms: roomNodes.add %*[r.x, r.y, r.w, r.h]
    poiNodes.add %*{
      "x": site.center.x, "y": site.center.y,
      "archetype": $site.archetype, "halfExtent": site.halfExtent,
      "lootTier": site.lootTier,
      "rooms": roomNodes,  ## round 9: the floor plan, [x,y,w,h] per room
    }
  let spec = %*{
    "name": m.name,
    "genSeed": m.genSeed,
    "mode": "br",                    ## marks this a BR spec, not a CtfMap one
    "style": styleToStr(m.style),
    "width": m.width,
    "height": m.height,
    "symmetry": "none",              ## full-board, #280-style, no lift
    "flagless": true,
    "gunRange": m.gunRange,
    "spawnClearW": m.spawnClearW,
    "spawnClearH": m.spawnClearH,
    "groups": m.groups,
    "seatsPerGroup": m.seatsPerGroup,
    "zoneZ": m.zoneZ,
    "keystone": keystoneToStr(m.keystone),  ## round 6, doctrine §2.4
    "spawnPoints": spawnPts,          ## confirmed grammar, see comment above
    "leftObstacles": shapes,          ## full authored set; symNone = verbatim
    "structureCount": m.structureCount,
    "pois": poiNodes,                 ## round-3 layout grammar; art-only, the
                                       ## sim reads leftObstacles/items instead
    ## round-3 items — medKitSpawns/medKitCandidates mirror CtfMap's own
    ## (NEUTRAL, not team-keyed) field names verbatim. teamPickups is
    ## deliberately absent; see the final report.
    "medKitSpawns": pointsNode(m.medKitSpawns),
    "medKitCandidates": pointsNode(m.medKitCandidates),
    "grenadeSpawns": pointsNode(m.grenadeSpawns),
  }
  $spec

proc brMapFromSpecJson(text: string): BrMap =
  let node = parseJson(text)
  result.name = node["name"].getStr()
  result.genSeed = node{"genSeed"}.getInt(0)
  result.style =
    case node{"style"}.getStr("caves")
    of "bsp": styleBsp
    of "caves": styleCaves
    of "maze": styleMaze
    of "scatter": styleScatter
    else: styleCaves
  result.width = node["width"].getInt()
  result.height = node["height"].getInt()
  result.gunRange = node["gunRange"].getInt()
  result.spawnClearW = node["spawnClearW"].getInt()
  result.spawnClearH = node["spawnClearH"].getInt()
  result.groups = node{"groups"}.getInt(Groups)
  result.seatsPerGroup = node{"seatsPerGroup"}.getInt(SeatsPerGroup)
  result.zoneZ = node{"zoneZ"}.getFloat(ZoneZ)
  result.keystone = keystoneFromStr(node{"keystone"}.getStr("landing-selection"))
  for item in node["leftObstacles"]:
    result.obstacles.add item.shapeFromSpecNode()
  ## Re-derive edge tags from position directly (round 5: spawns are a
  ## jittered grid, not a deterministic ring walk, so there's no formula to
  ## replay from width/height/groups alone — nearestFieldEdge is a pure
  ## function of the loaded point, so it round-trips exactly regardless of
  ## how the spawn was originally placed).
  let pts = pointsFromNode(node["spawnPoints"])
  for p in pts:
    result.spawns.add BrSpawn(p: p, edge: nearestFieldEdge(p, result.width, result.height))
  result.structureCount = node{"structureCount"}.getInt(0)
  let poiNode = node{"pois"}
  if not poiNode.isNil and poiNode.kind == JArray:
    for pn in poiNode:
      let archetype =
        case pn{"archetype"}.getStr("poiOutpost")
        of "poiCompound": poiCompound
        of "poiOutpost": poiOutpost
        of "poiYard": poiYard
        of "poiRuins": poiRuins
        of "poiAnchor": poiAnchor
        of "poiCauseway": poiCauseway
        of "poiWarren": poiWarren
        else: poiOutpost
      var rooms: seq[MapRect]
      let roomsNode = pn{"rooms"}
      if not roomsNode.isNil and roomsNode.kind == JArray:
        for rn in roomsNode:
          rooms.add MapRect(x: rn[0].getInt(), y: rn[1].getInt(),
            w: rn[2].getInt(), h: rn[3].getInt())
      result.pois.add PoiSite(
        center: MapPoint(x: pn["x"].getInt(), y: pn["y"].getInt()),
        archetype: archetype,
        halfExtent: pn{"halfExtent"}.getInt(150),
        lootTier: pn{"lootTier"}.getInt(1),
        rooms: rooms)
  result.medKitSpawns = pointsFromNode(node{"medKitSpawns"})
  result.medKitCandidates = pointsFromNode(node{"medKitCandidates"})
  result.grenadeSpawns = pointsFromNode(node{"grenadeSpawns"})

# --- geometry / grid helpers for validators + render -------------------------

const GridStride = 4  ## px per grid cell for connectivity/mass/zone analysis
const NoEnclosureExits = 99
  ## exit count returned when a pocket/rect boundary sample ring is 100%
  ## walkable: nothing encloses it at all, which is the OPPOSITE of a
  ## single-exit trap, so it must clear MinPocketExits/ZoneMinExits trivially
  ## rather than reading as "one exit" (a fully-open ring and a one-door room
  ## are not the same failure mode).

proc gridDims(width, height: int): tuple[cols, rows: int] =
  (width div GridStride + 1, height div GridStride + 1)

proc measuredShapeArea(shape: ArenaShape): int =
  ## The ACTUAL area one isolated shape will register as once rasterized —
  ## same grid-corner-sampling method buildWallGrid uses below, applied to
  ## just this one shape's own bounding box. Round 5 fix: a polygon's
  ## shoelace/formula area can badly overstate its true even-odd fill once
  ## blobPolygon's wobble makes it non-convex (see ScreenBlobRadius's
  ## comment) — this measures what will actually land in the wall grid, so
  ## a repair candidate can be self-verified before being committed.
  let b = shapeBounds(shape)
  let gx0 = b.x0 div GridStride
  let gy0 = b.y0 div GridStride
  let gx1 = b.x1 div GridStride
  let gy1 = b.y1 div GridStride
  var count = 0
  for gy in gy0 .. gy1:
    let y = gy * GridStride
    for gx in gx0 .. gx1:
      let x = gx * GridStride
      if inShape(x, y, shape):
        inc count
  count * GridStride * GridStride

proc buildWallGrid(m: BrMap): seq[bool] =
  ## True = solid (wall or off-playable-border), sampled at grid-cell centers.
  ## Painted shape-by-shape over each shape's own bounding box only, matching
  ## map_render's rasterization strategy (area + sum-of-boxes, never
  ## area x shapes) — the giant board has ~340k grid cells and can carry
  ## 1000+ blob polygons.
  let (cols, rows) = gridDims(m.width, m.height)
  result = newSeq[bool](cols * rows)
  for gy in 0 ..< rows:
    let y = gy * GridStride
    for gx in 0 ..< cols:
      let x = gx * GridStride
      if x < ArenaBorderPx or y < ArenaBorderPx or
          x >= m.width - ArenaBorderPx or y >= m.height - ArenaBorderPx:
        result[gy * cols + gx] = true
  for shape in m.obstacles:
    let b = shapeBounds(shape)
    let gx0 = max(0, b.x0 div GridStride)
    let gy0 = max(0, b.y0 div GridStride)
    let gx1 = min(cols - 1, b.x1 div GridStride)
    let gy1 = min(rows - 1, b.y1 div GridStride)
    for gy in gy0 .. gy1:
      let y = gy * GridStride
      for gx in gx0 .. gx1:
        let x = gx * GridStride
        if inShape(x, y, shape):
          result[gy * cols + gx] = true

proc components(
  mask: seq[bool], cols, rows: int, want: bool, diag: bool
): tuple[labels: seq[int], sizes: Table[int, int]] =
  ## Connected components of cells where mask[i] == want. `diag` selects
  ## 8-connectivity (used for WALL masses, so diagonal-touching blobs still
  ## read as one weld) vs 4-connectivity (used for WALKABLE floor, so a
  ## diagonal pixel-gap never counts as a real path).
  var dsu = initDSU(cols * rows)
  for gy in 0 ..< rows:
    for gx in 0 ..< cols:
      let i = gy * cols + gx
      if mask[i] != want: continue
      if gx + 1 < cols and mask[i + 1] == want: dsu.union(i, i + 1)
      if gy + 1 < rows and mask[i + cols] == want: dsu.union(i, i + cols)
      if diag:
        if gx + 1 < cols and gy + 1 < rows and mask[i + cols + 1] == want:
          dsu.union(i, i + cols + 1)
        if gx > 0 and gy + 1 < rows and mask[i + cols - 1] == want:
          dsu.union(i, i + cols - 1)
  result.labels = newSeq[int](cols * rows)
  result.sizes = initTable[int, int]()
  for gy in 0 ..< rows:
    for gx in 0 ..< cols:
      let i = gy * cols + gx
      if mask[i] != want:
        result.labels[i] = -1
        continue
      let r = dsu.find(i)
      result.labels[i] = r
      result.sizes[r] = result.sizes.getOrDefault(r, 0) + 1

proc toGrid(x, y: int): tuple[gx, gy: int] = (x div GridStride, y div GridStride)

# --- distance-to-cover (round 8) ----------------------------------------------

proc chamferDistancePx(wall: seq[bool], cols, rows: int): seq[float] =
  ## Two-pass chamfer (3-4) distance transform: PX distance from every grid
  ## cell to the nearest wall cell, approximating true Euclidean distance
  ## to within a few percent (the standard 3-4 chamfer weights) at O(n) —
  ## cheap enough to run on all ~344k giant-field grid cells per validate
  ## call. Replaces round 5's fixed 8x4 empty-cell macro-grid (doctrine
  ## §2.1's round-8 strengthening): this measures the thing that actually
  ## matters at combat scale — how far a duo standing anywhere on walkable
  ## ground has to run before it can reach cover — instead of a coarse
  ## proxy grid that couldn't discriminate finer than one macro-cell.
  const Ortho = 3
  const Diag = 4
  const Big = 1_000_000_000
  var d = newSeq[int](cols * rows)
  for i in 0 ..< wall.len:
    d[i] = if wall[i]: 0 else: Big
  for gy in 0 ..< rows:
    for gx in 0 ..< cols:
      let i = gy * cols + gx
      if d[i] == 0: continue
      var best = d[i]
      if gx > 0: best = min(best, d[i - 1] + Ortho)
      if gy > 0: best = min(best, d[i - cols] + Ortho)
      if gx > 0 and gy > 0: best = min(best, d[i - cols - 1] + Diag)
      if gx < cols - 1 and gy > 0: best = min(best, d[i - cols + 1] + Diag)
      d[i] = best
  for gy in countdown(rows - 1, 0):
    for gx in countdown(cols - 1, 0):
      let i = gy * cols + gx
      if d[i] == 0: continue
      var best = d[i]
      if gx < cols - 1: best = min(best, d[i + 1] + Ortho)
      if gy < rows - 1: best = min(best, d[i + cols] + Ortho)
      if gx < cols - 1 and gy < rows - 1: best = min(best, d[i + cols + 1] + Diag)
      if gx > 0 and gy < rows - 1: best = min(best, d[i + cols - 1] + Diag)
      d[i] = best
  result = newSeq[float](cols * rows)
  for i in 0 ..< d.len:
    result[i] = float(d[i]) / float(Ortho) * float(GridStride)

# --- exit / choke counting ----------------------------------------------------

proc countExits(
  wall: seq[bool], cols, rows: int, cx, cy, radius: int
): int =
  ## Samples a circle of the given radius (map px) around (cx, cy) and counts
  ## CONTIGUOUS walkable arcs — the static approximation of "how many
  ## distinct exits does this pocket have" (doc §4.5). A single arc, however
  ## wide, is one exit: the whole ring being open counts as ONE, not merged
  ## into "no chokepoint" — we want independent breaks in the wall, so two
  ## arcs separated by ANY solid span both count, and the wraparound is
  ## stitched (arc 0 and the last arc merge if both walkable and adjacent).
  const Samples = 96
  var open = newSeq[bool](Samples)
  for i in 0 ..< Samples:
    let theta = 2.0 * PI * float(i) / float(Samples)
    let x = cx + int(round(float(radius) * cos(theta)))
    let y = cy + int(round(float(radius) * sin(theta)))
    let (gx, gy) = toGrid(clamp(x, 0, cols * GridStride - 1),
                           clamp(y, 0, rows * GridStride - 1))
    if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
      open[i] = not wall[gy * cols + gx]
  if not anyIt(open, it): return 0
  if allIt(open, it): return NoEnclosureExits  # no wall nearby at all: trivially safe
  var runs = 0
  for i in 0 ..< Samples:
    let prev = open[(i + Samples - 1) mod Samples]
    if open[i] and not prev: inc runs
  runs

proc countBoundaryExits(
  wall: seq[bool], cols, rows, width, height: int, rect: MapRect,
  extraBlockers: seq[ArenaShape] = @[]
): int =
  ## Same contiguous-arc count as countExits, walked around a RECTANGLE'S
  ## perimeter instead of a circle — used both for the zone-center viability
  ## sweep (§4.3) and for the spawn-pocket exit rule (§4.5).
  ##
  ## A pocket near the map edge can have a ring that pokes OFF the field
  ## (negative x/y, or past width/height): clamping those samples onto the
  ## nearest in-field pixel lands them on the perimeter wall (always solid),
  ## which reads as a permanent one-sided "chokepoint" that has nothing to do
  ## with the drawn terrain — every seed failed the exit rule on exactly this
  ## before the fix. Off-field samples are dropped entirely instead: the
  ## circular run-count then naturally bridges the gap they leave, judging
  ## only the boundary that is actually part of the playable map.
  ##
  ## `extraBlockers` (round 2): shapes not yet baked into `wall`, tested live
  ## at each sample — lets a repair-blob CANDIDATE be checked against "would
  ## this choke the ring" directly, instead of via an approximate safety
  ## margin. Margins turned out to be unreliable here: blobPolygon's organic
  ## wobble can push its silhouette up to ~1.7x its nominal radius in one
  ## lobe (a2+a3 amplitude up to 0.42+0.28), which quietly ate every fixed
  ## margin tried and kept re-choking rings the arithmetic said were clear.
  var pts: seq[tuple[x, y: int]]
  const Step = GridStride
  ## Margin rounded UP to a full grid cell: a raw pixel just past ArenaBorderPx
  ## (e.g. x=10) can still floor-divide (toGrid) onto a grid cell whose OWN
  ## sample point (gx*GridStride, e.g. 8) is < ArenaBorderPx and so was marked
  ## permanently solid by buildWallGrid's border rule — a single such
  ## mismatched sample amid an otherwise open ring reads as a false 1-pixel
  ## "wall", which the run-counter then reports as exactly one exit. Padding
  ## the margin to the next grid cell guarantees every kept sample's OWN grid
  ## cell is unambiguously past the border rule.
  const FieldMargin = ArenaBorderPx + GridStride
  proc inField(x, y: int): bool =
    x >= FieldMargin and y >= FieldMargin and
      x < width - FieldMargin and y < height - FieldMargin
  var x = rect.x
  while x <= rect.x + rect.w:
    if inField(x, rect.y): pts.add (x, rect.y)
    x += Step
  var y = rect.y
  while y <= rect.y + rect.h:
    if inField(rect.x + rect.w, y): pts.add (rect.x + rect.w, y)
    y += Step
  x = rect.x + rect.w
  while x >= rect.x:
    if inField(x, rect.y + rect.h): pts.add (x, rect.y + rect.h)
    x -= Step
  y = rect.y + rect.h
  while y >= rect.y:
    if inField(rect.x, y): pts.add (rect.x, y)
    y -= Step
  if pts.len == 0: return 0
  var open = newSeq[bool](pts.len)
  for i, p in pts:
    let (gx, gy) = toGrid(p.x, p.y)
    if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
      open[i] = not wall[gy * cols + gx]
      if open[i] and extraBlockers.len > 0:
        ## Test at the GRID-ALIGNED point (gx*GridStride, gy*GridStride), not
        ## the raw perimeter-walk pixel `p` — `wall` itself was populated by
        ## buildWallGrid sampling shapes at grid-aligned points, so testing
        ## extraBlockers at the unaligned pixel occasionally disagreed with
        ## what the FINAL validate pass (which bakes candidates into a fresh
        ## buildWallGrid, all grid-aligned) would find once a candidate was
        ## accepted — a ring the trim sweep called safe still failed the real
        ## exit-rule check afterward. Matching the sample point removes the
        ## discrepancy: this call now predicts buildWallGrid exactly.
        let sx = gx * GridStride
        let sy = gy * GridStride
        for shape in extraBlockers:
          if inShape(sx, sy, shape):
            open[i] = false
            break
  if not anyIt(open, it): return 0
  if allIt(open, it): return NoEnclosureExits  # no wall nearby at all: trivially safe
  var runs = 0
  for i in 0 ..< pts.len:
    let prev = open[(i + pts.len - 1) mod pts.len]
    if open[i] and not prev: inc runs
  runs

# --- zone geometry (§4.3) ------------------------------------------------------

proc zoneRect(width, height: int, z: float, cx, cy: int): MapRect =
  let
    w = int(round(z * float(width)))
    h = int(round(z * float(height)))
  result = MapRect(x: cx - w div 2, y: cy - h div 2, w: w, h: h)

# --- BR validators -------------------------------------------------------------

type
  ZoneCandidate = object
    cx, cy: int
    walkableFrac: float
    massCount: int
    exits: int
    pass: bool

  BrValidation = object
    ## One bool + a reason string per gate, plus the artifacts each needed.
    connectivityPass: bool
    connectivityReason: string
    componentCount: int
    dominantFrac: float

    exitPass: bool
    exitReason: string
    minPocketExits: int
    pocketExits: seq[int]

    antiConfettiPass: bool
    antiConfettiReason: string
    massCount: int
    confettiCount: int
    largestMassPx2: int

    zoneCandidates: seq[ZoneCandidate]
    zoneViableFrac: float
    zonePass: bool
    zoneReason: string

    specSizePass: bool
    specSizeReason: string
    specSizeBytes: int

    ## ROUND 2 (coordinator review, 2026-08-24): the round-1 gates all
    ## passed on "empty pan with islands" draws because none of them
    ## measured DISTRIBUTION. These three close that gap.
    placeCountPass: bool
    placeCountReason: string
    bigMassCount: int            ## masses strictly above the confetti floor

    perSpawnCoverPass: bool
    perSpawnCoverReason: string
    uncoveredSpawns: int

    ## ROUND 8 (Maxwell's verdict on round 7's sheet: "THESE MAPS ARE STILL
    ## farrrrrrrrr too barren" — bold masses, far too few). Replaces round
    ## 5's empty-cell density-uniformity gate outright (doctrine §2.1's
    ## round-8 strengthening: "mass quality (subtractive, welded) and mass
    ## quantity (the permille band) are separate gates"). The two gates
    ## below subsume the old one at COMBAT SCALE: an empty 8x4 macro-cell
    ## was only ever a proxy for "can a duo standing here reach cover
    ## before getting shot," and distance-to-cover measures that directly
    ## instead of guessing at it via a coarse fixed grid.
    coverPermille: int            ## measured total obstacle coverage, permille
    coverPermillePass: bool
    coverPermilleReason: string

    distToCoverP95Px: float       ## p95 walkable-cell distance to nearest cover
    distToCoverMaxPx: float       ## max walkable-cell distance to nearest cover
    distToCoverPass: bool
    distToCoverReason: string
    # ROUND 3 (Maxwell's rejection, 2026-08-24): "items, intention" is the
    # doctrine's PRIMARY BR lever (doc 4.4), absent from rounds 1-2 entirely.
    itemCoveragePass: bool
    itemCoverageReason: string
    uncoveredSpawnsItems: int

    poiLootPass: bool
    poiLootReason: string
    poisWithoutLoot: int

    ## ROUND 6 (Maxwell's ruling, doctrine §2.4): "keystone is measured, not
    ## just named." One detector per declared family; a declared keystone
    ## the detector can't find fails the draw.
    keystoneLabel: string      ## human-readable name of the detector metric
    keystoneValue: float       ## the raw detector reading
    keystoneFloor: float       ## the calibrated pass threshold
    keystonePass: bool
    keystoneReason: string

    ## ROUND 9 (doctrine item 6): "add interior-connectivity (flood fill
    ## per structure) + room-count-variety."
    interiorConnPass: bool
    interiorConnReason: string
    strandedRooms: int          ## rooms whose center isn't in the map's
                                  ## dominant walkable component
    roomCountVarietyPass: bool
    roomCountVarietyReason: string
    distinctRoomCounts: int      ## how many distinct room-count values
                                  ## appear across the draw's structures
    roomCountsByArchetype: seq[(string, int)]  ## per-structure, for the log

    allPass: bool

const
  ConfettiFloorPx2 = 3000     ## below this, a wall mass counts as confetti
  ## ROUND 5: retuned with evidence, same as round 4's DistMaxEmptyCells.
  ## The round-2 ceiling (40) was tuned against a K=6-9-POI corpus; doctrine
  ## §4.7's uniform-density composition now draws K=10-16 POIs, and each
  ## authored ruin/connector is DELIBERATELY fragmented (protected from the
  ## confetti prune — see structureCount), so more POIs mechanically means
  ## more small legitimate fragments, not more clutter. Measured on 40 seeds
  ## (11001-11040, post repair-radius fix): confetti count range [28,60],
  ## mean 42.9, p80=51. 52 keeps ~80% of the corpus passing (matching the
  ## historical ~75-85% honest-pass bar) without being a rubber stamp.
  ## ROUND 6: re-measured across all 6 keystone families (15 seeds each).
  ## Four families (landing-selection, rotation-timing, zone-edge-holding,
  ## open-steppe) sit in the SAME range round 5 was tuned against. Two
  ## (third-party, cqc-warren) are structurally denser BY DESIGN — a
  ## warren cluster's disconnected small-room walls are individually
  ## confetti-sized, and cqc-warren specifically draws far more warrens
  ## than any other family (mean 13.9 vs third-party's 5.4). Cut warren
  ## room count 2-4 -> fixed 2 (halved third-party's mean 69.5 -> 52.2;
  ## cqc-warren barely moved, 67.9 -> 67.9, since its sheer WARREN COUNT
  ## compensates) before retuning. 60 keeps the four unaffected families
  ## at ~100%, brings third-party to ~85%, but cqc-warren only reaches
  ## ~40% (6/15) even here — an HONEST, reported limitation: cqc-warren's
  ## whole design intent is maximum interior density, which is in direct
  ## tension with a global confetti ceiling built for the other five
  ## families. Flagged for round 7 (a family-aware ceiling, or welding
  ## adjacent warren-room walls into fewer, larger connected masses).
  ## ROUND 7 (Maxwell's verdict): "THE ANTI-CONFETTI GATE DRIFTED... the
  ## gate was tuned to fit the generator instead of the standard... reset
  ## it as a STANDARD." The round-5/6 ceiling (52, then 60) was raised to
  ## accommodate whatever the thin-walled generator happened to produce —
  ## the classic backwards ratchet. The round-7 subtractive rework (welded
  ## shell-ring masses, thick gated connectors, no more dash runs) makes
  ## near-zero confetti the STRUCTURAL default rather than something to
  ## tolerate: measured on the 3 priority families post-rework (15 seeds
  ## each, 40001-40015) — confetti count [0,5], mean 0.2-1.1, essentially
  ## always 0-2. 8 is a principled standard (comfortable margin over the
  ## worst observed case, not curve-fit to a loose distribution) — a
  ## genuinely welded map should clear it almost every time; a map that
  ## doesn't is telling you something broke, not that the standard is
  ## wrong.
  ConfettiCeiling = 8         ## max confetti masses tolerated on the whole board
  MinPocketExits = 2          ## doc §4.5: no single-exit pocket
  ZoneWalkableFloor = 0.55
  ZoneMinMasses = 2
  ZoneMinExits = 2
  ZoneStepPx = 180
  ## The replay wire format caps one embedded string at 65535 bytes
  ## (bitworld/replays.nim:108-112, per the br-demo lane's 2026-08-24 giant
  ## symNone build, which hit this at 73KB). Budget well under the hard cap.
  SpecSizeBudgetBytes = 58000
  ## ROUND 8 (Maxwell's verdict: "THESE MAPS ARE STILL farrrrrrrrr too
  ## barren" — bold masses, far too few). round-7 draws ran 12-18 welded
  ## masses (18-26 counting connectors as separate components) at ~40-60
  ## permille cover; the CTF program's own validated band is [40,170] with
  ## caves_404 (an accepted reference) at 150. §2.1's round-8 strengthening
  ## targets the UPPER half of that band plus ~3x the mass count. PlaceCount
  ## is now a BAND, not just a floor: >=25 welded (non-confetti) masses
  ## (up from round-2's floor of 6, now clearly too low for the doctrine's
  ## own reference density) and <=60 (a map that is ALL mass has no open
  ## ground to fight across, and the confetti/spec-size gates would choke
  ## first anyway — the ceiling exists so a bug that goes the other
  ## direction, e.g. caves fill running away to near-solid, fails loudly
  ## here instead of silently in the spec-size gate).
  PlaceCountFloor = 25
  PlaceCountCeiling = 60
  PerSpawnCoverGR = 1.5       ## round-2 §2.3: rotation cover within 1.5 G
  PocketExitMargin = 24       ## shared with ensurePerSpawnCover so a screen
                               ## blob can never be placed ON its own spawn's
                               ## exit-check ring (round-2 regression: it was
                               ## using the raw pocket's radius, not the
                               ## ring's, and choked 6 spawns down to 1 exit)
  ## ROUND 8: cover-permille and distance-to-cover REPLACE round 5's
  ## empty-cell density-uniformity gate (doctrine §2.1's round-8
  ## strengthening: "mass quality... and mass quantity... are separate
  ## gates; three generator rounds conflated them"). coverPermille ports
  ## the CTF program's own metric verbatim (arena.nim:2770 — wall pixels /
  ## interior pixels * 1000, sampled here at grid resolution instead of
  ## per-pixel), banked to the UPPER half of CTF's own validated
  ## [40,170] band: caves_404, a reference Maxwell accepted, sits at 150.
  CoverPermilleMinBr = 110
  CoverPermilleMaxBr = 170
  ## Distance-to-nearest-cover over walkable ground, at COMBAT scale
  ## (fractions of gunRange, ~331px on giant): p95 must clear inside
  ## 0.75G (~248px) — the typical duo should never be more than a
  ## three-quarter-range dash from the nearest wall — and NO walkable cell
  ## may sit past 1.25G (~414px), the hard "you are dead in the open"
  ## ceiling. This is the principled replacement for the old empty-cell
  ## grid: it measures the thing that actually matters (can you reach
  ## cover before you take a bullet) instead of a fixed macro-cell proxy.
  DistToCoverP95FracG = 0.75
  DistToCoverMaxFracG = 1.25

  ## ROUND 6 keystone detector floors, RECALIBRATED round 8 (doctrine:
  ## "recalibrate on the denser corpus, same cross-family method" — the
  ## POI counts/sizes changed enough across every family that the round-6
  ## numbers needed re-measuring, not just porting). Same method as round
  ## 6: 30 seeds x 6 families (sweeps at seeds 1001-1015 and 2001-2015,
  ## post round-8's mass-quantity rework), every OTHER family's draws
  ## scored against each formula for comparison.
  KsLandingVarianceFloor = 22000.0 ## own [16363,303761], p20=68082; clears
                                     ## cqc-warren (max 20897), rotation-
                                     ## timing (max 15056), open-steppe
                                     ## (max 5776), third-party (max 21047)
                                     ## cleanly (29/30 own pass). Overlaps
                                     ## zone-edge-holding (min 118268, own
                                     ## range CONTAINED inside it) —
                                     ## reported, same as round 6.
  KsCausewayCountFloor = 5.0        ## own min 6; every other family's max
                                     ## is 4 (round 8's universal causeway
                                     ## top-up, item 3c, means every family
                                     ## now places SOME causeways — floor
                                     ## moved up from round 6's 3 to stay
                                     ## clear of that new baseline).
  KsAnchorHalfExtentFloor = 0.45    ## fraction of gunRange
  KsAnchorCountFloor = 4.0          ## own min 4; every other family's max
                                     ## is 3 (landing-selection, whose big
                                     ## compound/anchor draws occasionally
                                     ## qualify) — clean separation.
  KsAnchorSpreadFloor = 1.8         ## fraction of gunRange; own spreadFails
                                     ## 0/30 at this floor.
  KsThirdPartyOpenFloor = 0.85      ## combined with warren-count below;
                                     ## unchanged — own openFrac stays 1.00.
  KsThirdPartyMinWarrens = 1.0      ## own min 2; excludes rotation-timing,
                                     ## open-steppe, landing-selection,
                                     ## zone-edge-holding (all 0 always).
                                     ## cqc-warren overlaps (min 5, both
                                     ## families favor warrens) — reported.
  KsCqcWarrenShareFloor = 0.15      ## own min 0.199; excludes rotation-
                                     ## timing (max 0.280 — NOW OVERLAPS,
                                     ## reported) and open-steppe (max
                                     ## 0.066) cleanly. Overlaps landing-
                                     ## selection (max 0.839) and zone-edge
                                     ## (max 0.869)'s high end even harder
                                     ## than round 6 — round 8's density
                                     ## bump raised every family's ceiling,
                                     ## this floor still separates on the
                                     ## LOW end (own min comfortably clears
                                     ## it) which is what the gate needs.
  KsOpenSteppeShareCeiling = 0.09   ## own max 0.066 (round 8's caves-fill
                                     ## bump raised this from round 6's
                                     ## 0.051 and briefly broke the family's
                                     ## OWN pass rate at the old 0.06
                                     ## ceiling — this is the fix); every
                                     ## other family's minimum is 0.121+
                                     ## (rotation-timing). Clean, no overlap.

proc validateBr(m: BrMap): BrValidation =
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)

  # 1. Global connectivity ----------------------------------------------------
  var walkable = newSeq[bool](wall.len)
  for i in 0 ..< wall.len: walkable[i] = not wall[i]
  let walkComp = components(walkable, cols, rows, true, false)
  ## The single LARGEST walkable component — used by the round-9 interior-
  ## connectivity check below regardless of whether spawns all share it
  ## (that's connectivityPass's own job); this is just "the map's main
  ## playable area."
  var dominantWalkLabel = -1
  var dominantWalkSize = -1
  for lbl, sz in walkComp.sizes:
    if sz > dominantWalkSize:
      dominantWalkSize = sz
      dominantWalkLabel = lbl
  var labelOf: seq[int]
  for s in m.spawns:
    let (gx, gy) = toGrid(clamp(s.p.x, 0, cols * GridStride - 1),
                           clamp(s.p.y, 0, rows * GridStride - 1))
    labelOf.add walkComp.labels[gy * cols + gx]
  var totalWalkable = 0
  for _, sz in walkComp.sizes: totalWalkable += sz
  let uniqueLabels = labelOf.deduplicate()
  result.componentCount = walkComp.sizes.len
  if -1 in labelOf:
    result.connectivityPass = false
    result.connectivityReason = "a spawn point sampled onto a wall cell"
  elif uniqueLabels.len != 1:
    result.connectivityPass = false
    result.connectivityReason =
      &"spawns split across {uniqueLabels.len} components (need 1)"
  else:
    let dominant = walkComp.sizes[uniqueLabels[0]]
    result.dominantFrac = float(dominant) / float(max(1, totalWalkable))
    result.connectivityPass = result.dominantFrac >= 0.90
    result.connectivityReason =
      if result.connectivityPass: ""
      else: &"shared spawn component is only {result.dominantFrac*100:.1f}% of walkable area"

  # 2. Exit rule around every spawn pocket ------------------------------------
  var minExits = high(int)
  for s in m.spawns:
    ## Walk the boundary of the pocket's OWN oriented rect (expanded by a
    ## small margin), not a uniform circle: the pocket clearance itself is
    ## anisotropic (§ pocketRect), and a circle at a fixed radius pokes well
    ## outside the guaranteed-clear zone on the tangential (narrow) sides,
    ## which reads real terrain there as a "choke" even when the pocket's
    ## own clear zone was never promised to extend that far.
    let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
    let ring = MapRect(
      x: pocket.x - PocketExitMargin, y: pocket.y - PocketExitMargin,
      w: pocket.w + 2 * PocketExitMargin, h: pocket.h + 2 * PocketExitMargin)
    let n = countBoundaryExits(wall, cols, rows, m.width, m.height, ring)
    when defined(brDebugExit):
      stderr.writeLine(&"spawn edge={s.edge} p=({s.p.x},{s.p.y}) ring=({ring.x},{ring.y},{ring.w},{ring.h}) exits={n}")
    result.pocketExits.add n
    minExits = min(minExits, n)
  result.minPocketExits = minExits
  result.exitPass = minExits >= MinPocketExits
  result.exitReason =
    if result.exitPass: ""
    else: &"a spawn pocket has only {minExits} exit(s), need >= {MinPocketExits}"

  # 3. Anti-confetti proxy ------------------------------------------------------
  let wallComp = components(wall, cols, rows, true, true)
  ## Cell (0,0) is always inside the border ring (buildWallGrid marks the
  ## whole perimeter solid regardless of any drawn terrain), so its label
  ## identifies the border's own component — the border is the map boundary,
  ## not a welded TERRAIN mass, and must not count toward "distinct places"
  ## or inflate the largest-mass stat.
  let borderLabel = wallComp.labels[0]
  var confetti = 0
  var largest = 0
  when defined(brDebugConfetti):
    var compBounds = initTable[int, tuple[x0,y0,x1,y1: int]]()
    for gy in 0 ..< rows:
      for gx in 0 ..< cols:
        let lbl = wallComp.labels[gy * cols + gx]
        if lbl == borderLabel: continue
        if wall[gy * cols + gx]:
          if lbl in compBounds:
            let b = compBounds[lbl]
            compBounds[lbl] = (min(b.x0, gx), min(b.y0, gy), max(b.x1, gx), max(b.y1, gy))
          else:
            compBounds[lbl] = (gx, gy, gx, gy)
  for lbl, sz in wallComp.sizes:
    if lbl == borderLabel: continue
    let px2 = sz * GridStride * GridStride
    if px2 < ConfettiFloorPx2:
      inc confetti
      when defined(brDebugConfetti):
        let b = compBounds[lbl]
        stderr.writeLine(&"CONFETTI lbl={lbl} px2={px2} bbox=({b.x0*GridStride},{b.y0*GridStride})-({b.x1*GridStride},{b.y1*GridStride})")
    largest = max(largest, px2)
  result.massCount = wallComp.sizes.len - 1  ## excludes the border component
  result.confettiCount = confetti
  result.largestMassPx2 = largest
  result.antiConfettiPass = confetti <= ConfettiCeiling
  result.antiConfettiReason =
    if result.antiConfettiPass: ""
    else: &"{confetti} confetti-sized masses (< {ConfettiFloorPx2}px^2), ceiling {ConfettiCeiling}"
  result.bigMassCount = result.massCount - confetti

  # 3b. Place-count BAND (round 2 floor, round 8 adds a ceiling) ----------------
  result.placeCountPass =
    result.bigMassCount >= PlaceCountFloor and result.bigMassCount <= PlaceCountCeiling
  result.placeCountReason =
    if result.placeCountPass: ""
    elif result.bigMassCount < PlaceCountFloor:
      &"{result.bigMassCount} welded masses, need >= {PlaceCountFloor} " &
        "(\"empty pan with islands\" if this stays low)"
    else:
      &"{result.bigMassCount} welded masses, ceiling is {PlaceCountCeiling} " &
        "(no open ground left to fight across)"

  # 3c. Per-spawn cover (round 2, doc §2.3 sharpened) ---------------------------
  block perSpawnCover:
    let radius = int(PerSpawnCoverGR * float(m.gunRange))
    const ScanStride = GridStride * 3
    var uncovered = 0
    for s in m.spawns:
      var covered = false
      var dy = -radius
      while dy <= radius and not covered:
        var dx = -radius
        while dx <= radius and not covered:
          if dx * dx + dy * dy <= radius * radius:
            let x = s.p.x + dx
            let y = s.p.y + dy
            if x >= 0 and x < m.width and y >= 0 and y < m.height:
              let (gx, gy) = toGrid(x, y)
              if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
                let i = gy * cols + gx
                if wall[i]:
                  let lbl = wallComp.labels[i]
                  if lbl >= 0 and lbl != borderLabel and
                      wallComp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
                    covered = true
          dx += ScanStride
        dy += ScanStride
      if not covered: inc uncovered
      when defined(brDebugExit):
        stderr.writeLine(&"perSpawnCover spawn edge={s.edge} p=({s.p.x},{s.p.y}) covered={covered}")
    result.uncoveredSpawns = uncovered
    result.perSpawnCoverPass = uncovered == 0
    result.perSpawnCoverReason =
      if result.perSpawnCoverPass: ""
      else: &"{uncovered}/{m.spawns.len} spawns have no welded mass within " &
        &"{PerSpawnCoverGR}G ({radius}px) — unscreened rotation"

  # 3d. Cover-permille + distance-to-cover (round 8, REPLACES round 5's
  # density-uniformity empty-cell grid) ------------------------------------------
  block coverPermille:
    ## Ports the CTF program's own coverPermille metric verbatim (see
    ## arena.nim:2770 — wall pixels / interior pixels * 1000), sampled here
    ## at grid resolution rather than per-pixel (consistent with every
    ## other BR gate). "Interior" excludes the perimeter border strip, same
    ## as CTF's definition, so the gate measures drawn mass, not the
    ## map-edge wall every draw carries for free.
    var interiorCells = 0
    var wallCells = 0
    for gy in 0 ..< rows:
      let y = gy * GridStride
      for gx in 0 ..< cols:
        let x = gx * GridStride
        if x < ArenaBorderPx or y < ArenaBorderPx or
            x >= m.width - ArenaBorderPx or y >= m.height - ArenaBorderPx:
          continue
        inc interiorCells
        if wall[gy * cols + gx]: inc wallCells
    let permille = wallCells * 1000 div max(1, interiorCells)
    result.coverPermille = permille
    result.coverPermillePass =
      permille >= CoverPermilleMinBr and permille <= CoverPermilleMaxBr
    result.coverPermilleReason =
      if result.coverPermillePass: ""
      elif permille < CoverPermilleMinBr:
        &"{permille}‰ cover, floor is {CoverPermilleMinBr}‰ — too barren"
      else:
        &"{permille}‰ cover, ceiling is {CoverPermilleMaxBr}‰ — too clogged"

  block distanceToCover:
    ## The principled barren detector (doctrine §2.1, round 8): how far
    ## does a duo standing anywhere on walkable ground have to run before
    ## it reaches cover, measured at COMBAT scale (fractions of gunRange)
    ## instead of a fixed macro-cell. Subsumes round 5's empty-cell density
    ## gate outright — an empty macro-cell was only ever a coarse proxy for
    ## exactly this question.
    let distPx = chamferDistancePx(wall, cols, rows)
    var samples: seq[float]
    for i in 0 ..< wall.len:
      if not wall[i]: samples.add distPx[i]
    samples.sort()
    let p95 =
      if samples.len > 0: samples[min(samples.len - 1, int(0.95 * float(samples.len)))]
      else: 0.0
    let maxD = if samples.len > 0: samples[^1] else: 0.0
    result.distToCoverP95Px = p95
    result.distToCoverMaxPx = maxD
    let p95Floor = DistToCoverP95FracG * float(m.gunRange)
    let maxFloor = DistToCoverMaxFracG * float(m.gunRange)
    result.distToCoverPass = p95 <= p95Floor and maxD <= maxFloor
    result.distToCoverReason =
      if result.distToCoverPass: ""
      elif p95 > p95Floor:
        &"p95 distance-to-cover {p95:.0f}px > {p95Floor:.0f}px ({DistToCoverP95FracG}G) — too much open ground"
      else:
        &"max distance-to-cover {maxD:.0f}px > {maxFloor:.0f}px ({DistToCoverMaxFracG}G) — a walkable cell is stranded in the open"

  # 4. Zone-center viability sweep ----------------------------------------------
  let margin = max(zoneRect(m.width, m.height, m.zoneZ, 0, 0).w,
                    zoneRect(m.width, m.height, m.zoneZ, 0, 0).h) div 2 + ArenaBorderPx + 20
  var y = margin
  while y <= m.height - margin:
    var x = margin
    while x <= m.width - margin:
      let rect = zoneRect(m.width, m.height, m.zoneZ, x, y)
      var walkCells = 0
      var totalCells = 0
      var massesInside = initTable[int, bool]()
      let gx0 = max(0, rect.x div GridStride)
      let gy0 = max(0, rect.y div GridStride)
      let gx1 = min(cols - 1, (rect.x + rect.w) div GridStride)
      let gy1 = min(rows - 1, (rect.y + rect.h) div GridStride)
      for gy in gy0 .. gy1:
        for gx in gx0 .. gx1:
          let i = gy * cols + gx
          inc totalCells
          if not wall[i]:
            inc walkCells
          else:
            let lbl = wallComp.labels[i]
            if lbl >= 0 and lbl != borderLabel and
                wallComp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
              massesInside[lbl] = true
      let frac = float(walkCells) / float(max(1, totalCells))
      let exits = countBoundaryExits(wall, cols, rows, m.width, m.height, rect)
      var cand = ZoneCandidate(
        cx: x, cy: y, walkableFrac: frac, massCount: massesInside.len, exits: exits)
      cand.pass = frac >= ZoneWalkableFloor and
        massesInside.len >= ZoneMinMasses and exits >= ZoneMinExits
      result.zoneCandidates.add cand
      x += ZoneStepPx
    y += ZoneStepPx
  var viable = 0
  for c in result.zoneCandidates:
    if c.pass: inc viable
  result.zoneViableFrac =
    float(viable) / float(max(1, result.zoneCandidates.len))
  result.zonePass = viable >= 1
  result.zoneReason =
    if result.zonePass: ""
    else: "no candidate zone center passed the viability sweep"

  # 5. Spec-size budget ----------------------------------------------------------
  ## Serialize with the SAME emitter cmdGenerate/render use, so this is the
  ## exact byte count a pinned replay spec would carry.
  result.specSizeBytes = brMapSpecJson(m).len
  result.specSizePass = result.specSizeBytes <= SpecSizeBudgetBytes
  result.specSizeReason =
    if result.specSizePass: ""
    else: &"spec is {result.specSizeBytes}B, budget {SpecSizeBudgetBytes}B " &
      &"(replay wire cap is 65535B) — prune more or thin blob density"

  # 6. Item coverage (round 3, doctrine §4.4) ------------------------------------
  ## Every spawn's nearest item within ~1.5 gun-ranges of its ring position.
  block itemCoverage:
    let radius = int(PerSpawnCoverGR * float(m.gunRange))
    let allItems = m.medKitCandidates & m.grenadeSpawns
    var uncovered = 0
    for s in m.spawns:
      var best = high(int)
      for it in allItems:
        let dx = s.p.x - it.x
        let dy = s.p.y - it.y
        let d2 = dx * dx + dy * dy
        if d2 < best: best = d2
      let dist = if best == high(int): high(int) else: int(sqrt(float(best)))
      if dist > radius: inc uncovered
    result.uncoveredSpawnsItems = uncovered
    result.itemCoveragePass = uncovered == 0
    result.itemCoverageReason =
      if result.itemCoveragePass: ""
      else: &"{uncovered}/{m.spawns.len} spawns have no item within " &
        &"{PerSpawnCoverGR}G ({radius}px)"

  # 7. Every POI has a reason to visit (round 3) ----------------------------------
  block poiLoot:
    var missing = 0
    for site in m.pois:
      var hasLoot = false
      let checkR = site.halfExtent + 60
      for it in m.medKitCandidates:
        if abs(it.x - site.center.x) <= checkR and abs(it.y - site.center.y) <= checkR:
          hasLoot = true
          break
      if not hasLoot:
        for it in m.grenadeSpawns:
          if abs(it.x - site.center.x) <= checkR and abs(it.y - site.center.y) <= checkR:
            hasLoot = true
            break
      if not hasLoot: inc missing
    result.poisWithoutLoot = missing
    result.poiLootPass = missing == 0
    result.poiLootReason =
      if result.poiLootPass: ""
      else: &"{missing}/{m.pois.len} POIs have no item nearby — a place with no reason to visit"

  # 8. Keystone detector (round 6, doctrine §2.4) --------------------------------
  ## "keystone is measured, not just named" — a declared keystone the
  ## detector can't find fails the draw. Each family gets a detector metric
  ## computed purely from m.pois (archetype/halfExtent/lootTier/center) plus
  ## the wall grid already built above; floors are calibrated against a
  ## cross-family corpus (see the round-6 commit message for the sweep).
  block keystoneCheck:
    case m.keystone
    of ksLandingSelection:
      ## Steep loot/size gradient BETWEEN sites: population variance of a
      ## per-POI "value" (richer tier + bigger footprint = higher value).
      ## poiCauseway is EXCLUDED — it's a terrain feature, not a landing
      ## site with loot value, and including it was the single biggest
      ## calibration miss (see the round-6 commit): a causeway's large
      ## halfExtent inflated variance enough that rotation-timing draws
      ## (which also place causeways) scored HIGHER than landing-selection
      ## itself. Excluding it drops rotation-timing's range from
      ## [68594,90930] to [4608,8342] — clean separation.
      result.keystoneLabel = "loot-value variance (excl. causeways)"
      var vals: seq[float]
      for p in m.pois:
        if p.archetype != poiCauseway:
          vals.add float(3 - p.lootTier) * float(p.halfExtent)
      if vals.len < 2:
        result.keystoneValue = 0.0
      else:
        let meanV = vals.foldl(a + b, 0.0) / float(vals.len)
        var varV = 0.0
        for v in vals: varV += (v - meanV) * (v - meanV)
        result.keystoneValue = varV / float(vals.len)
      result.keystoneFloor = KsLandingVarianceFloor
      result.keystonePass = result.keystoneValue >= result.keystoneFloor
      result.keystoneReason =
        if result.keystonePass: ""
        else: &"loot-value variance {result.keystoneValue:.0f} < floor {result.keystoneFloor:.0f} — sites read too similar"
    of ksRotationTiming:
      ## Count of causeways whose LENGTH (2*halfExtent) exceeds 2 gun-ranges
      ## — long enough that crossing one is a real timing decision.
      var count = 0
      for p in m.pois:
        if p.archetype == poiCauseway and 2 * p.halfExtent > 2 * m.gunRange:
          inc count
      result.keystoneLabel = "long-causeway count (length > 2G)"
      result.keystoneValue = float(count)
      result.keystoneFloor = KsCausewayCountFloor
      result.keystonePass = result.keystoneValue >= result.keystoneFloor
      result.keystoneReason =
        if result.keystonePass: ""
        else: &"{count} causeways clear length>2G, floor is {int(result.keystoneFloor)}"
    of ksZoneEdgeHolding:
      ## Count of qualifying anchors (footprint above a floor) AND their
      ## pairwise spread — both matter: holding the edge needs several real
      ## anchors that are actually far apart, not clustered together.
      var anchorPts: seq[MapPoint]
      for p in m.pois:
        if p.archetype == poiAnchor and float(p.halfExtent) > KsAnchorHalfExtentFloor * float(m.gunRange):
          anchorPts.add p.center
      var minPairDist = Inf
      for i in 0 ..< anchorPts.len:
        for j in i + 1 ..< anchorPts.len:
          let dx = float(anchorPts[i].x - anchorPts[j].x)
          let dy = float(anchorPts[i].y - anchorPts[j].y)
          minPairDist = min(minPairDist, sqrt(dx * dx + dy * dy))
      result.keystoneLabel = "anchor count (footprint>" & $KsAnchorHalfExtentFloor & "G)"
      result.keystoneValue = float(anchorPts.len)
      result.keystoneFloor = KsAnchorCountFloor
      let spreadOk = anchorPts.len < 2 or minPairDist >= KsAnchorSpreadFloor * float(m.gunRange)
      result.keystonePass = result.keystoneValue >= result.keystoneFloor and spreadOk
      result.keystoneReason =
        if result.keystonePass: ""
        elif result.keystoneValue < result.keystoneFloor:
          &"{anchorPts.len} qualifying anchors, floor is {int(result.keystoneFloor)}"
        else:
          &"anchors too close together (min pairwise {minPairDist:.0f}px, " &
            &"floor {KsAnchorSpreadFloor * float(m.gunRange):.0f}px)"
    of ksThirdParty:
      ## Fraction of POIs that are OPEN (not a sealed compound/anchor) PLUS
      ## a minimum warren count. openFraction alone doesn't discriminate:
      ## measured that rotation-timing, cqc-warren, and open-steppe ALSO
      ## score 1.00 (their pools avoid sealed compounds too, for unrelated
      ## reasons) — warren count is what actually separates third-party
      ## from the families that just happen to avoid compounds: rotation-
      ## timing and open-steppe never place a warren at all (measured
      ## count=0 across 15 seeds each), so requiring >=1 excludes both
      ## cleanly. cqc-warren is warren-heavy TOO (an honest, expected
      ## overlap — both families favor many-approach interiors, reported
      ## rather than hidden) and remains only partially separated.
      var sealed = 0
      var warrens = 0
      for p in m.pois:
        if p.archetype in {poiCompound, poiAnchor}: inc sealed
        if p.archetype == poiWarren: inc warrens
      let openFrac = if m.pois.len > 0: 1.0 - float(sealed) / float(m.pois.len) else: 0.0
      result.keystoneLabel = "open-site fraction (not compound/anchor)"
      result.keystoneValue = openFrac
      result.keystoneFloor = KsThirdPartyOpenFloor
      let warrenOk = float(warrens) >= KsThirdPartyMinWarrens
      result.keystonePass = result.keystoneValue >= result.keystoneFloor and warrenOk
      result.keystoneReason =
        if result.keystonePass: ""
        elif result.keystoneValue < result.keystoneFloor:
          &"only {openFrac*100:.0f}% of sites are open, floor is {KsThirdPartyOpenFloor*100:.0f}%"
        else:
          &"only {warrens} warrens, floor is {int(KsThirdPartyMinWarrens)} — not enough multi-approach interiors"
    of ksCqcWarren, ksOpenSteppe:
      ## Interior-share dial. FIRST attempt used the wall-grid's own
      ## non-border wall fraction — measured (see round-6 commit) that it
      ## barely varies across ANY family (0.93-0.96 walkable everywhere):
      ## wall LINE pixels are a tiny fraction of a 5.5M-px^2 field
      ## regardless of room count, so it was a rubber stamp. Switched to
      ## POI FOOTPRINT-AREA share (sum of each site's own (2*halfExtent)^2
      ## bounding box, excluding causeways which are linear not areal,
      ## divided by field area) — this scales directly with both count and
      ## size, which is what packing/spacing actually changes. Measured:
      ## open-steppe [0.026,0.051], every other family's MINIMUM is
      ## 0.065+ — clean separation on the low pole. cqc-warren
      ## [0.170,0.280]; landing-selection/zone-edge-holding/third-party
      ## can also reach into that range at their own high end (an honest,
      ## reported overlap — a rich landing-selection or third-party draw
      ## can coincidentally pack as densely as a cqc-warren one), but
      ## rotation-timing (max 0.133) and open-steppe (max 0.051) never do.
      var area = 0.0
      for p in m.pois:
        if p.archetype != poiCauseway:
          area += float(2 * p.halfExtent) * float(2 * p.halfExtent)
      let footprintShare = area / (float(m.width) * float(m.height))
      result.keystoneLabel = "POI footprint-area share (excl. causeways)"
      result.keystoneValue = footprintShare
      if m.keystone == ksCqcWarren:
        result.keystoneFloor = KsCqcWarrenShareFloor
        result.keystonePass = footprintShare >= result.keystoneFloor
        result.keystoneReason =
          if result.keystonePass: ""
          else: &"footprint share {footprintShare*100:.1f}% < floor {KsCqcWarrenShareFloor*100:.1f}%"
      else:
        result.keystoneFloor = KsOpenSteppeShareCeiling
        result.keystonePass = footprintShare <= result.keystoneFloor
        result.keystoneReason =
          if result.keystonePass: ""
          else: &"footprint share {footprintShare*100:.1f}% > ceiling {KsOpenSteppeShareCeiling*100:.1f}%"

  # 9. Interior connectivity (round 9, doctrine item 6) --------------------------
  block interiorConnectivity:
    ## Every ROOM (from every structure's floor plan) should sit in the
    ## SAME dominant walkable component as the rest of the map — if NO
    ## sample point inside a room reads as that component, its
    ## structure's doorway graph didn't actually connect it to the
    ## outside. Samples FIVE points per room (center + 4 quarter-offset
    ## points), not just the exact centroid: measured that a room's own
    ## geometric center can coincide with a decorative furniture block
    ## (e.g. poiAnchor's courtyard cover slabs, placed at a fixed offset
    ## from the SITE's center rather than the BSP room's own center) even
    ## though the room is otherwise fully walkable and properly doored —
    ## a probe-point false positive, not a real stranding. A room only
    ## counts as stranded if ALL five samples miss the dominant component.
    var stranded = 0
    var totalRooms = 0
    for site in m.pois:
      for r in site.rooms:
        inc totalRooms
        var connected = false
        let samples = [
          (r.x + r.w div 2, r.y + r.h div 2),
          (r.x + r.w div 4, r.y + r.h div 4),
          (r.x + r.w * 3 div 4, r.y + r.h div 4),
          (r.x + r.w div 4, r.y + r.h * 3 div 4),
          (r.x + r.w * 3 div 4, r.y + r.h * 3 div 4),
        ]
        for (sx, sy) in samples:
          let px = clamp(sx, 0, m.width - 1)
          let py = clamp(sy, 0, m.height - 1)
          let (gx, gy) = toGrid(px, py)
          if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
            if walkComp.labels[gy * cols + gx] == dominantWalkLabel:
              connected = true
              break
        if not connected:
          inc stranded
          when defined(brDebugRooms):
            stderr.writeLine(&"STRANDED room archetype={site.archetype} center=({site.center.x},{site.center.y}) room=({r.x},{r.y},{r.w},{r.h})")
    result.strandedRooms = stranded
    result.interiorConnPass = stranded == 0
    result.interiorConnReason =
      if result.interiorConnPass: ""
      else: &"{stranded}/{totalRooms} room centers are NOT in the map's dominant walkable component"

  # 10. Room-count variety (round 9, doctrine item 6) -----------------------------
  block roomCountVariety:
    ## "A draw's structures must span >=3 distinct room counts" — the
    ## measured proof that "wide array of possible interiors and room
    ## counts" (Maxwell's ask) actually happened, not just that SOME
    ## buildings got subdivided.
    var counts: seq[int]
    var byArch: seq[(string, int)]
    for site in m.pois:
      if site.rooms.len >= 1:
        counts.add site.rooms.len
        byArch.add ($site.archetype, site.rooms.len)
    let distinctCounts = counts.deduplicate().len
    result.distinctRoomCounts = distinctCounts
    result.roomCountsByArchetype = byArch
    result.roomCountVarietyPass = distinctCounts >= 3
    result.roomCountVarietyReason =
      if result.roomCountVarietyPass: ""
      else: &"only {distinctCounts} distinct room count(s) across {counts.len} structures, need >= 3"

  result.allPass = result.connectivityPass and result.exitPass and
    result.antiConfettiPass and result.zonePass and result.specSizePass and
    result.placeCountPass and result.perSpawnCoverPass and
    result.interiorConnPass and result.roomCountVarietyPass and
    result.coverPermillePass and result.distToCoverPass and
    result.itemCoveragePass and result.poiLootPass and result.keystonePass

proc bestZoneCandidate(v: BrValidation, width, height: int): ZoneCandidate =
  ## Pick the passing candidate closest to the field's geometric center (a
  ## centered final zone reads best on the example render); fall back to the
  ## highest-scoring candidate if none pass, so render still has something.
  let cx0 = width div 2
  let cy0 = height div 2
  var bestPass = false
  var bestScore = -1.0
  var best: ZoneCandidate
  var any = false
  for c in v.zoneCandidates:
    let d = sqrt(float((c.cx - cx0) * (c.cx - cx0) + (c.cy - cy0) * (c.cy - cy0)))
    if c.pass:
      if not bestPass or -d > bestScore:
        bestPass = true
        bestScore = -d
        best = c
        any = true
    elif not bestPass:
      let score = c.walkableFrac + float(c.massCount) * 0.1 + float(c.exits) * 0.1
      if not any or score > bestScore:
        bestScore = score
        best = c
        any = true
  best

proc pruneConfetti(
  obstacles: seq[ArenaShape], width, height: int, floorPx2: int
): seq[ArenaShape] =
  ## Anti-confetti is a HARD gate (doc §2.1), so it is enforced at DRAW time,
  ## not just measured after the fact: drop any shape whose 8-connected wall
  ## mass (the mass it welds into, sharing an edge or corner with a
  ## neighbour) is smaller than the confetti floor. A shape with no welded
  ## neighbours at all is its own 1-cell mass and is always dropped. Sampling
  ## each shape's CENTROID against the mass grid (rather than re-deriving
  ## membership analytically) keeps this consistent with validateBr's own
  ## mass measurement by construction.
  let (cols, rows) = gridDims(width, height)
  var wall = newSeq[bool](cols * rows)
  for shape in obstacles:
    let b = shapeBounds(shape)
    let gx0 = max(0, b.x0 div GridStride)
    let gy0 = max(0, b.y0 div GridStride)
    let gx1 = min(cols - 1, b.x1 div GridStride)
    let gy1 = min(rows - 1, b.y1 div GridStride)
    for gy in gy0 .. gy1:
      let y = gy * GridStride
      for gx in gx0 .. gx1:
        let x = gx * GridStride
        if inShape(x, y, shape):
          wall[gy * cols + gx] = true
  let comp = components(wall, cols, rows, true, true)
  for shape in obstacles:
    let b = shapeBounds(shape)
    let ccx = clamp((b.x0 + b.x1) div 2, 0, width - 1)
    let ccy = clamp((b.y0 + b.y1) div 2, 0, height - 1)
    let (gx, gy) = toGrid(ccx, ccy)
    if gx < 0 or gx >= cols or gy < 0 or gy >= rows: continue
    let lbl = comp.labels[gy * cols + gx]
    if lbl >= 0 and comp.sizes[lbl] * GridStride * GridStride >= floorPx2:
      result.add shape

proc pocketRadialHalf(s: BrSpawn, clearW, clearH: int): int =
  clearH  ## pocketRect always puts the LARGER (radial) extent in clearH,
          ## regardless of which edge the spawn sits on.

proc pointInAnyPocket(
  x, y: int, spawns: seq[BrSpawn], clearW, clearH, buffer: int
): bool =
  for s in spawns:
    let p = pocketRect(s, clearW, clearH)
    if x >= p.x - buffer and x <= p.x + p.w + buffer and
        y >= p.y - buffer and y <= p.y + p.h + buffer:
      return true
  false

# --- items (round 3, doctrine §4.4) -------------------------------------------
## Items are BR's PRIMARY balance lever per doctrine — absent from rounds 1
## and 2 entirely. Read against the actual engine (src/ctf/sim.nim,
## sim_types.nim): CtfMap.medKitSpawns/medKitCandidates are plain
## seq[MapPoint], NOT team-keyed at all, so they transfer to a 16-group
## draw with zero adaptation — this is BR's primary loot channel.
## teamPickups (shields/cans/barriers) are deliberately NOT emitted: see
## the final report for why (validateMap hard-codes symNone's teamCount to
## 2; barrierSpawnPoints derives its count from TeamLayout.teamCount(),
## which only knows 2 or 4 — neither expresses a 16-group-fair pool today).

proc walkableNear(
  obstacles: seq[ArenaShape], cx, cy, radius: int, rng: var Rand
): MapPoint =
  ## Best-effort: a handful of random offsets within `radius`, first one not
  ## inside any obstacle wins. Correct regardless of which POI archetype
  ## placed the geometry — no need to hand-derive "the doorway is here" per
  ## archetype when we can just test the real obstacle list directly.
  for attempt in 0 ..< 24:
    let x = cx + (if radius > 0: rng.rand(-radius .. radius) else: 0)
    let y = cy + (if radius > 0: rng.rand(-radius .. radius) else: 0)
    var blocked = false
    for shape in obstacles:
      if inShape(x, y, shape):
        blocked = true
        break
    if not blocked:
      return MapPoint(x: x, y: y)
  MapPoint(x: cx, y: cy)  ## fall back to the POI center; rare in practice

proc placeItems(m: var BrMap, rng: var Rand) =
  ## The loot gradient (doctrine §4.4): the richest kit sits at the most
  ## exposed/central POI (tier 0, the compound), less at mid POIs (tier 1),
  ## a minor find at outer ruins (tier 2) — "no POI without a reason to
  ## visit" is satisfied by construction: every site gets >= 1 item.
  ## ROUND 9 (doctrine item 5): "loot uses the plan" — sites with a real
  ## floor plan (>=2 rooms) place loot PER ROOM instead of near the site's
  ## center, and the room closest to the site's own centroid (a cheap
  ## proxy for "graph-deepest room" that doesn't need the door graph
  ## re-threaded through to item placement) gets the extra item — inner
  ## rooms richer, real risk/reward depth instead of one loot pile by the
  ## front door.
  for site in m.pois:
    if site.rooms.len >= 2:
      var ranked: seq[tuple[idx: int, d: float]]
      for i, r in site.rooms:
        let rcx = r.x + r.w div 2
        let rcy = r.y + r.h div 2
        let dx = float(rcx - site.center.x)
        let dy = float(rcy - site.center.y)
        ranked.add (i, sqrt(dx * dx + dy * dy))
      ranked.sort(proc(a, b: tuple[idx: int, d: float]): int = cmp(a.d, b.d))
      let baseN = case site.lootTier
        of 0: 2
        of 1: 1
        else: 1
      for rank, entry in ranked:
        let r = site.rooms[entry.idx]
        let rcx = r.x + r.w div 2
        let rcy = r.y + r.h div 2
        let searchR = max(15, min(r.w, r.h) div 2 - 10)
        let n = if rank == 0: baseN + 1 else: baseN ## innermost room richest
        for k in 0 ..< n:
          let p = walkableNear(m.obstacles, rcx, rcy, searchR, rng)
          m.medKitCandidates.add p
        if rank == 0 and site.lootTier <= 1:
          let p = walkableNear(m.obstacles, rcx, rcy, searchR, rng)
          m.grenadeSpawns.add p
    else:
      ## No real floor plan (ruins, causeway, or a single-room roll) —
      ## the original per-site placement, unchanged.
      let n = case site.lootTier
        of 0: 3
        of 1: 2
        else: 1
      for k in 0 ..< n:
        let searchR = max(20, site.halfExtent - 30)
        let p = walkableNear(m.obstacles, site.center.x, site.center.y, searchR, rng)
        m.medKitCandidates.add p
      if site.lootTier <= 1:
        let p = walkableNear(m.obstacles, site.center.x, site.center.y,
          max(20, site.halfExtent - 40), rng)
        m.grenadeSpawns.add p
  m.medKitSpawns = m.medKitCandidates  ## BR is flagless: no candidate-pool
    ## narrowing step exists (that's a CTF pre-game mechanic), so every
    ## drawn point is "active" — kept as a separate field only to mirror
    ## CtfMap's shape for a future engine-side consumer.

proc nearestItemDist(p: MapPoint, items: seq[MapPoint]): int =
  result = high(int)
  for it in items:
    let dx = p.x - it.x
    let dy = p.y - it.y
    let d2 = dx * dx + dy * dy
    if d2 < result: result = d2
  if result == high(int): return high(int)
  result = int(sqrt(float(result)))

proc ensureItemCoverage(m: var BrMap, coverGR: float, rng: var Rand) =
  ## Round-3 gate: every spawn's nearest item within ~1.5 gun-ranges of its
  ## ring position. Items are pure POINTS (no collision), so — unlike the
  ## round-2 terrain screen-blob repair — this repair can never choke an
  ## exit ring; it just adds a supplementary medkit at the spawn's own
  ## pocket (always walkable by construction) when nothing organic is close
  ## enough.
  let radius = int(coverGR * float(m.gunRange))
  let allItems = m.medKitCandidates & m.grenadeSpawns
  for s in m.spawns:
    if nearestItemDist(s.p, allItems) > radius:
      let p = walkableNear(m.obstacles, s.p.x, s.p.y, m.spawnClearW div 2, rng)
      m.medKitCandidates.add p
      m.medKitSpawns.add p

proc ensurePerSpawnCover(m: BrMap, coverGR: float): seq[ArenaShape] =
  ## ROUND 2 (coordinator review, 2026-08-24): "every rotation from spawn is
  ## unscreened" — doctrine §2.3 (cover on the rotation) needs a welded mass
  ## within ~coverGR gun-ranges of EVERY spawn, and organic terrain density
  ## is not reliable enough to promise that on its own (that is exactly what
  ## the round-1 draws got called out for). A hard per-spawn gate needs a
  ## CONSTRUCTION, not a hope: measure each spawn against the terrain
  ## AFTER the confetti prune (call this post-prune), and for any spawn with
  ## no qualifying mass in range, author one small screen blob just past its
  ## pocket, on the field-INWARD side (never toward the map edge, and never
  ## inside another spawn's own pocket).
  const
    ScanStride = GridStride * 3   ## coarse disc scan: cheap, ~16px granularity
    ScreenBlobRadius = 65          ## ROUND 5 fix: the round-2 sizing (36,
                                    ## nominal area pi*36^2~=4072 > floor)
                                    ## assumed the NOMINAL wobbled-circle
                                    ## formula, not the actual rasterized
                                    ## yield. Traced a live per-spawn-cover
                                    ## failure to a repair blob that WAS
                                    ## placed, well within radius, with no
                                    ## exit-trim — but its own connected-
                                    ## component measured only 1952px^2 after
                                    ## rasterization (blobPolygon's wobble
                                    ## can make the shape non-convex /
                                    ## borderline self-intersecting at n=12
                                    ## verts, and pointInPolygon's even-odd
                                    ## fill doesn't preserve the shoelace
                                    ## area for that case) — under the 3000
                                    ## floor despite a comfortable 4072
                                    ## nominal area. 65 targets ~2x margin
                                    ## even at the same ~48% observed yield.
    PocketBuffer = 70              ## matches dropShapesNearSpawns' halo
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  let comp = components(wall, cols, rows, true, true)
  let borderLabel = comp.labels[0]
  let radius = int(coverGR * float(m.gunRange))
  var rng = initRand(m.genSeed xor 0x4B72_9E11)

  proc hasQualifyingMassNear(cx, cy: int): bool =
    var dy = -radius
    while dy <= radius:
      var dx = -radius
      while dx <= radius:
        if dx * dx + dy * dy <= radius * radius:
          let x = cx + dx
          let y = cy + dy
          if x >= 0 and x < m.width and y >= 0 and y < m.height:
            let (gx, gy) = toGrid(x, y)
            if gx >= 0 and gx < cols and gy >= 0 and gy < rows:
              let i = gy * cols + gx
              if wall[i]:
                let lbl = comp.labels[i]
                if lbl >= 0 and lbl != borderLabel and
                    comp.sizes[lbl] * GridStride * GridStride >= ConfettiFloorPx2:
                  return true
        dx += ScanStride
      dy += ScanStride
    false

  proc touchesAnyRing(shape: ArenaShape): bool =
    ## Cheap bbox-only pre-filter, factored out so both the placement
    ## search AND the round-5 quality-retry (below) can reject a candidate
    ## whose bounding box overlaps ANY spawn's exit ring outright — the
    ## quality retry regenerates the SHAPE (not just re-measures it), so it
    ## must re-run this check too, or a bigger reroll can choke a ring that
    ## the original (smaller) roll cleared, and phase 2 trims it away with
    ## nothing to fall back on (measured: this was a real regression — a
    ## repair with a comfortably large measured area still left its spawn
    ## uncovered because the reroll it won on was never safety-checked).
    let cb = shapeBounds(shape)
    for s2 in m.spawns:
      let p2 = pocketRect(s2, m.spawnClearW, m.spawnClearH)
      let r2x0 = p2.x - PocketExitMargin
      let r2y0 = p2.y - PocketExitMargin
      let r2x1 = p2.x + p2.w + PocketExitMargin
      let r2y1 = p2.y + p2.h + PocketExitMargin
      if not (cb.x1 < r2x0 - 4 or cb.x0 > r2x1 + 4 or
          cb.y1 < r2y0 - 4 or cb.y0 > r2y1 + 4):
        return true
    false

  ## TWO-PHASE, round-2 fix #6 (replaces three earlier attempts at an
  ## incremental "accept only if provably safe" placement search — each
  ## closed one failure mode and opened another, because blobPolygon's
  ## organic wobble made every fixed safety margin unreliable and even a
  ## per-candidate simulation missed cross-candidate interactions depending
  ## on iteration order). This is simpler and provably correct instead:
  ##   1. Place a best-effort candidate for every uncovered spawn, using only
  ##      a cheap "don't land inside a pocket" filter — no ring-safety logic
  ##      at all yet.
  ##   2. Sweep to a fixpoint: recompute EVERY ring's exit count with ALL
  ##      surviving candidates as blockers (the exact same countBoundaryExits
  ##      the real exit-rule validator calls), and if any ring would drop
  ##      below MinPocketExits, drop ONE overlapping candidate and re-sweep.
  ## Step 2 can only ever REMOVE candidates, so it can never introduce a
  ## choke — the worst case is an honest per-spawn-cover gap, which is
  ## exactly the number the validator should report.
  var candidates: seq[ArenaShape]
  for s in m.spawns:
    let alreadyCovered = hasQualifyingMassNear(s.p.x, s.p.y)
    when defined(brDebugExit):
      stderr.writeLine(&"ensurePerSpawnCover spawn edge={s.edge} p=({s.p.x},{s.p.y}) alreadyCovered={alreadyCovered} radius={radius}")
    if alreadyCovered:
      continue
    let minCenterDist = pocketRadialHalf(s, m.spawnClearW, m.spawnClearH) + 10
    let maxCenterDist = radius - 5
    var placed = false
    if maxCenterDist >= minCenterDist:
      const ScanStep = 28
      ## ROUND 5 fix: this used to `break` on the FIRST valid slot found in
      ## raster (top-to-bottom, left-to-right) order — not the CLOSEST one.
      ## With grid spawns (spread across the whole field, not just a
      ## perimeter ring) the "touches another spawn's ring" filter below
      ## rejects far more of the annulus than it used to (many more nearby
      ## spawns to avoid), so raster order was landing candidates right at
      ## the outer edge of maxCenterDist — close enough to `radius` that
      ## blobPolygon's organic wobble could push the rendered shape's
      ## qualifying mass just outside the coverage disc the validator scans
      ## (measured: a spawn with an active repair still failed per-spawn
      ## cover). Now scans the WHOLE annulus and keeps the CLOSEST valid
      ## candidate, so a repair blob always lands with real margin inside
      ## the radius it's meant to satisfy.
      var bestD2 = high(int)
      var bestCandidate: ArenaShape
      var bestCx, bestCy: int
      var found = false
      var dy = -maxCenterDist
      while dy <= maxCenterDist:
        var dx = -maxCenterDist
        while dx <= maxCenterDist:
          let d2 = dx * dx + dy * dy
          if d2 >= minCenterDist * minCenterDist and d2 <= maxCenterDist * maxCenterDist and
              d2 < bestD2:
            let cx = s.p.x + dx
            let cy = s.p.y + dy
            if cx >= ArenaBorderPx + 20 and cy >= ArenaBorderPx + 20 and
                cx < m.width - ArenaBorderPx - 20 and cy < m.height - ArenaBorderPx - 20 and
                not pointInAnyPocket(cx, cy, m.spawns, m.spawnClearW, m.spawnClearH, 15):
              let candidate = blobPolygon(
                rng, MapRect(x: 0, y: 0, w: m.width, h: m.height),
                cx, cy, ScreenBlobRadius, 12)
              ## Bbox-only pre-filter: reject any candidate whose bounding
              ## box overlaps ANY spawn's ring outright, so phase 2 (the
              ## expensive, authoritative trim) mostly only has to catch
              ## multi-candidate interactions instead of individually
              ## doomed placements — most of round 2's "too much trimming"
              ## was candidates that were never going to survive anyway.
              if not touchesAnyRing(candidate):
                bestD2 = d2
                bestCandidate = candidate
                bestCx = cx
                bestCy = cy
                found = true
                when defined(brDebugExit):
                  stderr.writeLine(&"  candidate screen blob at ({cx},{cy}) dist={sqrt(float(d2)):.0f} radius={radius}")
          dx += ScanStep
        dy += ScanStep
      if found:
        ## ROUND 5 quality retry: the CLOSEST safe position is fixed now,
        ## but blobPolygon's wobble is random per call — regenerate a few
        ## more candidates at that EXACT position and keep whichever one's
        ## ACTUALLY-RASTERIZED area (measuredShapeArea, not the shoelace/
        ## formula area) is largest, so a marginal/near-self-intersecting
        ## roll doesn't ship when a better one was one reroll away. MUST
        ## re-run touchesAnyRing per retry too (regression, caught and
        ## fixed): a bigger reroll can choke a ring the original smaller
        ## roll cleared, and phase 2 would trim it with nothing to fall
        ## back on — a comfortably-measured repair that still left its
        ## spawn uncovered, because the winning reroll was never safety-
        ## checked.
        var bestArea = measuredShapeArea(bestCandidate)
        for retry in 0 ..< 5:
          let alt = blobPolygon(
            rng, MapRect(x: 0, y: 0, w: m.width, h: m.height),
            bestCx, bestCy, ScreenBlobRadius, 12)
          if touchesAnyRing(alt): continue
          let altArea = measuredShapeArea(alt)
          if altArea > bestArea:
            bestArea = altArea
            bestCandidate = alt
        when defined(brDebugExit):
          stderr.writeLine(&"  final screen blob at ({bestCx},{bestCy}) measuredArea={bestArea} floor={ConfettiFloorPx2}")
        candidates.add bestCandidate
        placed = true
    when defined(brDebugExit):
      if not placed:
        stderr.writeLine(&"WARNING: no candidate slot for spawn edge={s.edge} p=({s.p.x},{s.p.y}) minCenterDist={minCenterDist} maxCenterDist={maxCenterDist}")

  # Phase 2: trim to a fixpoint against the REAL exit check.
  var stable = false
  while not stable and candidates.len > 0:
    stable = true
    block sweep:
      for s in m.spawns:
        let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
        let ring = MapRect(
          x: pocket.x - PocketExitMargin, y: pocket.y - PocketExitMargin,
          w: pocket.w + 2 * PocketExitMargin, h: pocket.h + 2 * PocketExitMargin)
        if countBoundaryExits(wall, cols, rows, m.width, m.height, ring, candidates) <
            MinPocketExits:
          for i, c in candidates:
            let cb = shapeBounds(c)
            if not (cb.x1 < ring.x - 8 or cb.x0 > ring.x + ring.w + 8 or
                cb.y1 < ring.y - 8 or cb.y0 > ring.y + ring.h + 8):
              when defined(brDebugExit):
                stderr.writeLine(&"  trimming candidate {i} — it chokes ring for spawn edge={s.edge} p=({s.p.x},{s.p.y})")
              candidates.delete(i)
              stable = false
              break sweep
  result = candidates

proc ensureInteriorConnectivity(m: var BrMap): int =
  ## Round 9 repair pass, same verify-then-repair shape as
  ## ensurePerSpawnCover/ensureItemCoverage above. A room can end up
  ## stranded from the map's dominant walkable component by an unlucky
  ## coincidence between an independently-randomized exterior gate or a
  ## spawn's no-keep-away clearance buffer and a BSP partition's own
  ## touch point (two concrete instances chased and fixed at the source
  ## in this same round — see chooseGatePos and dropShapesNearSpawns'
  ## clip-not-drop fix). Both were real, fixable geometry bugs, and both
  ## are now less frequent, but a third-order coincidence between the two
  ## (or a family/geometry combination not covered by the fixed sweep)
  ## can still slip through. Rather than chase every possible
  ## coincidence individually, this guarantees the OUTCOME: flood-fill
  ## the exact grid the interiorConn validator uses, and for any room
  ## whose samples all miss the dominant component, carve a thin
  ## corridor to the nearest cell that's in it. Returns the number of
  ## rooms repaired, for the gen-log line.
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  var walkable = newSeq[bool](wall.len)
  for i in 0 ..< wall.len: walkable[i] = not wall[i]
  let walkComp = components(walkable, cols, rows, true, false)
  var dominantLabel = -1
  var dominantSize = -1
  for lbl, sz in walkComp.sizes:
    if sz > dominantSize:
      dominantSize = sz
      dominantLabel = lbl
  if dominantLabel < 0: return 0
  var corridors: seq[MapRect]
  for site in m.pois:
    for r in site.rooms:
      let cx = clamp(r.x + r.w div 2, 0, m.width - 1)
      let cy = clamp(r.y + r.h div 2, 0, m.height - 1)
      let (gx0, gy0) = toGrid(cx, cy)
      if gx0 < 0 or gx0 >= cols or gy0 < 0 or gy0 >= rows: continue
      if walkComp.labels[gy0 * cols + gx0] == dominantLabel: continue
      var foundX = -1
      var foundY = -1
      block search:
        for radius in 1 .. max(cols, rows):
          let tx0 = max(0, gx0 - radius); let tx1 = min(cols - 1, gx0 + radius)
          let ty0 = max(0, gy0 - radius); let ty1 = min(rows - 1, gy0 + radius)
          for ty in ty0 .. ty1:
            for tx in tx0 .. tx1:
              if walkComp.labels[ty * cols + tx] == dominantLabel:
                foundX = tx * GridStride
                foundY = ty * GridStride
                break search
      if foundX < 0: continue
      const Strip = 24  ## half-width of the carved corridor, px
      corridors.add MapRect(x: min(cx, foundX) - Strip, y: cy - Strip,
        w: abs(foundX - cx) + 2 * Strip, h: 2 * Strip)
      corridors.add MapRect(x: foundX - Strip, y: min(cy, foundY) - Strip,
        w: 2 * Strip, h: abs(foundY - cy) + 2 * Strip)
      when defined(brDebugRooms):
        stderr.writeLine(&"REPAIR stranded room archetype={site.archetype} " &
          &"center=({r.x + r.w div 2},{r.y + r.h div 2}) -> nearest dominant cell ({foundX},{foundY})")
  if corridors.len == 0: return 0
  var kept: seq[ArenaShape]
  for shape in m.obstacles:
    if shape.kind == shapeRect:
      for piece in clipRectMinusPockets(shape.rect, corridors, 0):
        if piece.w >= 6 and piece.h >= 6:
          kept.add rectShapeBr(piece.x, piece.y, piece.w, piece.h)
    else:
      ## Non-rect (diagonal causeway segments, cave-fill polygons): left
      ## untouched — corridors are thin and rare enough that an organic
      ## shape merely brushing one is an acceptable round-9 approximation
      ## (matches dropShapesNearSpawns' own scope: only rects clip).
      kept.add shape
  m.obstacles = kept
  result = corridors.len div 2  ## 2 corridor segments per repaired room

# --- metrics -------------------------------------------------------------------

proc printMetrics(m: BrMap) =
  echo &"keystone:        {keystoneToStr(m.keystone)}"
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  var walkableCells = 0
  for w in wall:
    if not w: inc walkableCells
  let totalCells = cols * rows
  let wallComp = components(wall, cols, rows, true, true)
  let borderLabel = wallComp.labels[0]  ## cell (0,0): always the border ring
  var sizesPx2: seq[int]
  for lbl, sz in wallComp.sizes:
    if lbl != borderLabel: sizesPx2.add sz * GridStride * GridStride
  sizesPx2.sort(Descending)

  echo &"size:            {m.width}x{m.height}  style={styleToStr(m.style)}  seed={m.genSeed}"
  echo &"gunRange G:      {m.gunRange} px  (field is {float(m.width)/float(m.gunRange):.2f} x {float(m.height)/float(m.gunRange):.2f} G)"
  echo &"walkable frac:   {float(walkableCells)/float(totalCells)*100:.1f}%  ({walkableCells}/{totalCells} grid cells @ {GridStride}px)"
  echo &"wall masses:     {sizesPx2.len}  (8-connected)"
  if sizesPx2.len > 0:
    let top = sizesPx2[0 ..< min(8, sizesPx2.len)]
    echo &"  largest 8 (px^2): {top}"
    let confetti = sizesPx2.filterIt(it < ConfettiFloorPx2).len
    echo &"  confetti (<{ConfettiFloorPx2}px^2): {confetti}"

  echo "spawn grid (4x4, jittered — round 5, supersedes the ring):"
  var nearestDists: seq[float]
  for i in 0 ..< m.spawns.len:
    var best = Inf
    for j in 0 ..< m.spawns.len:
      if i == j: continue
      let a = m.spawns[i].p
      let b = m.spawns[j].p
      let d = sqrt(float((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)))
      if d < best: best = d
    nearestDists.add best
  let meanD = nearestDists.foldl(a + b, 0.0) / float(max(1, nearestDists.len))
  echo &"  nearest-neighbour spacing: mean={meanD:.1f}px ({meanD/float(m.gunRange):.2f}G)  min={nearestDists.min():.1f}px  max={nearestDists.max():.1f}px"

  let v = validateBr(m)
  echo &"cover permille:  {v.coverPermille}‰  (band=[{CoverPermilleMinBr},{CoverPermilleMaxBr}]‰)"
  echo &"dist-to-cover:   p95={v.distToCoverP95Px:.0f}px  max={v.distToCoverMaxPx:.0f}px  (floors=[{DistToCoverP95FracG}G,{DistToCoverMaxFracG}G])"
  echo "zone-center sweep (z=" & $m.zoneZ & "):"
  echo &"  candidates sampled: {v.zoneCandidates.len}  viable: {(v.zoneViableFrac*100):.1f}%"

proc metricsJson(m: BrMap, v: BrValidation): JsonNode =
  let (cols, rows) = gridDims(m.width, m.height)
  let wall = buildWallGrid(m)
  var walkableCells = 0
  for w in wall:
    if not w: inc walkableCells
  %*{
    "seed": m.genSeed,
    "style": styleToStr(m.style),
    "keystone": keystoneToStr(m.keystone),
    "keystoneLabel": v.keystoneLabel,
    "keystoneValue": v.keystoneValue,
    "keystoneFloor": v.keystoneFloor,
    "keystonePass": v.keystonePass,
    "width": m.width,
    "height": m.height,
    "gunRange": m.gunRange,
    "walkableFrac": float(walkableCells) / float(cols * rows),
    "massCount": v.massCount,
    "confettiCount": v.confettiCount,
    "largestMassPx2": v.largestMassPx2,
    "componentCount": v.componentCount,
    "dominantWalkableFrac": v.dominantFrac,
    "minPocketExits": v.minPocketExits,
    "pocketExits": v.pocketExits,
    "zoneCandidateCount": v.zoneCandidates.len,
    "zoneViableFrac": v.zoneViableFrac,
    "bigMassCount": v.bigMassCount,
    "uncoveredSpawns": v.uncoveredSpawns,
    "coverPermille": v.coverPermille,
    "distToCoverP95Px": v.distToCoverP95Px,
    "distToCoverMaxPx": v.distToCoverMaxPx,
    "specSizeBytes": v.specSizeBytes,
    "specSizeHeadroomBytes": SpecSizeBudgetBytes - v.specSizeBytes,
    "poiCount": m.pois.len,
    "medKitCount": m.medKitCandidates.len,
    "grenadeCount": m.grenadeSpawns.len,
    "uncoveredSpawnsItems": v.uncoveredSpawnsItems,
    "poisWithoutLoot": v.poisWithoutLoot,
    # ROUND 9: per-structure room counts (doctrine item 2: "print
    # per-structure room counts in the gen log and metrics") + the two
    # new floor-plan validators.
    "roomCountsByArchetype": %*(v.roomCountsByArchetype.mapIt(%*[it[0], it[1]])),
    "distinctRoomCounts": v.distinctRoomCounts,
    "strandedRooms": v.strandedRooms,
    "pass": %*{
      "connectivity": v.connectivityPass,
      "exitRule": v.exitPass,
      "antiConfetti": v.antiConfettiPass,
      "zoneViability": v.zonePass,
      "specSize": v.specSizePass,
      "placeCount": v.placeCountPass,
      "perSpawnCover": v.perSpawnCoverPass,
      "coverPermille": v.coverPermillePass,
      "distToCover": v.distToCoverPass,
      "itemCoverage": v.itemCoveragePass,
      "poiLoot": v.poiLootPass,
      "keystone": v.keystonePass,
      "interiorConnectivity": v.interiorConnPass,
      "roomCountVariety": v.roomCountVarietyPass,
      "all": v.allPass,
    },
  }

# --- render --------------------------------------------------------------------
# Own top-to-bottom raster loop (map_render's per-pixel helpers are private to
# that module, and its shared `renderMap` is wired to CTF's teams()/flagHome()
# globals, which BR has none of) — but the STRATEGY (paint each shape only
# over its own bounding box) and the warm floor/stone palette are the exact
# ones map_render.nim uses, duplicated here on purpose.

const
  FloorColor = rgba(214, 189, 150, 255)
  StoneColor = rgba(64, 48, 34, 255)
  BorderColor = rgba(44, 34, 25, 255)
  SpawnColor = rgba(235, 145, 35, 255)
  SpawnRingColor = rgba(235, 145, 35, 90)
  ZoneColor = rgba(230, 45, 45, 220)
  ZoneFillColor = rgba(230, 45, 45, 40)
  MedKitColor = rgba(60, 200, 90, 255)     ## round 3: the loot gradient, drawn
  GrenadeColor = rgba(235, 200, 40, 255)   ## round 3: minor supplementary pickup

proc fillDiscPx(image: Image, cx, cy, radius: int, color: ColorRGBA) =
  for y in max(0, cy - radius) .. min(image.height - 1, cy + radius):
    for x in max(0, cx - radius) .. min(image.width - 1, cx + radius):
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius:
        image.unsafe[x, y] = color

proc drawCrossPx(image: Image, cx, cy, radius: int, color: ColorRGBA) =
  for d in -radius .. radius:
    for t in -1 .. 1:
      if cx + d >= 0 and cx + d < image.width and cy + t >= 0 and cy + t < image.height:
        image.unsafe[cx + d, cy + t] = color
      if cx + t >= 0 and cx + t < image.width and cy + d >= 0 and cy + d < image.height:
        image.unsafe[cx + t, cy + d] = color

proc drawRectOutlinePx(image: Image, x0, y0, x1, y1: int, color: ColorRGBA, thick = 1) =
  let
    cx0 = clamp(x0, 0, image.width - 1)
    cy0 = clamp(y0, 0, image.height - 1)
    cx1 = clamp(x1, 0, image.width - 1)
    cy1 = clamp(y1, 0, image.height - 1)
  for t in 0 ..< thick:
    for x in cx0 .. cx1:
      if cy0 + t < image.height: image.unsafe[x, cy0 + t] = color
      if cy1 - t >= 0: image.unsafe[x, cy1 - t] = color
    for y in cy0 .. cy1:
      if cx0 + t < image.width: image.unsafe[cx0 + t, y] = color
      if cx1 - t >= 0: image.unsafe[cx1 - t, y] = color

proc renderBrMap(
  m: BrMap, maxDim: int, zoneRectOpt: MapRect, drawZone: bool
): Image =
  let scale =
    if maxDim <= 0: 1.0
    else: min(1.0, float(maxDim) / float(max(m.width, m.height)))
  let ow = int(ceil(float(m.width) * scale))
  let oh = int(ceil(float(m.height) * scale))
  result = newImage(ow, oh)

  proc toOut(v: int): int = int(round(float(v) * scale))
  proc toLogical(px: int): float = (float(px) + 0.5) / scale - 0.5

  var wall = newSeq[bool](ow * oh)
  for y in 0 ..< oh:
    let fy = toLogical(y)
    for x in 0 ..< ow:
      let fx = toLogical(x)
      let index = y * ow + x
      if fx < float(ArenaBorderPx) or fy < float(ArenaBorderPx) or
          fx >= float(m.width - ArenaBorderPx) or fy >= float(m.height - ArenaBorderPx):
        wall[index] = true

  for shape in m.obstacles:
    let b = shapeBounds(shape)
    let x0 = max(0, toOut(b.x0) - 1)
    let y0 = max(0, toOut(b.y0) - 1)
    let x1 = min(ow - 1, toOut(b.x1) + 1)
    let y1 = min(oh - 1, toOut(b.y1) + 1)
    for y in y0 .. y1:
      let fy = toLogical(y)
      for x in x0 .. x1:
        let fx = toLogical(x)
        if inShapeF(fx, fy, shape):
          wall[y * ow + x] = true

  for y in 0 ..< oh:
    for x in 0 ..< ow:
      let index = y * ow + x
      result.unsafe[x, y] = if wall[index]: StoneColor else: FloorColor

  # Spawn pockets: faint clearance ring, then a bright marker on the point.
  for s in m.spawns:
    let pocket = pocketRect(s, m.spawnClearW, m.spawnClearH)
    result.drawRectOutlinePx(
      toOut(pocket.x), toOut(pocket.y),
      toOut(pocket.x + pocket.w), toOut(pocket.y + pocket.h),
      SpawnRingColor)
  for s in m.spawns:
    result.fillDiscPx(toOut(s.p.x), toOut(s.p.y), max(2, toOut(10)), SpawnColor)
    result.drawCrossPx(toOut(s.p.x), toOut(s.p.y), max(3, toOut(16)), BorderColor)

  # Round-3 items — the loot gradient made visible: medkits (green cross)
  # denser at the major/mid POIs, grenades (yellow disc) as the minor extra.
  for p in m.medKitCandidates:
    result.fillDiscPx(toOut(p.x), toOut(p.y), max(2, toOut(7)), MedKitColor)
    result.drawCrossPx(toOut(p.x), toOut(p.y), max(2, toOut(10)), BorderColor)
  for p in m.grenadeSpawns:
    result.fillDiscPx(toOut(p.x), toOut(p.y), max(2, toOut(6)), GrenadeColor)

  # One example final-zone rect (§4.3), a thing to look at, not just a line.
  if drawZone:
    result.drawRectOutlinePx(
      toOut(zoneRectOpt.x), toOut(zoneRectOpt.y),
      toOut(zoneRectOpt.x + zoneRectOpt.w), toOut(zoneRectOpt.y + zoneRectOpt.h),
      ZoneColor, thick = max(1, toOut(4)))

proc renderZoneHeatmap(m: BrMap, v: BrValidation, maxDim: int): Image =
  ## The BR-specific THIRD view (doc §5.4): which drawn zone centers pass the
  ## viability sweep and which don't, composited as translucent squares over
  ## the real terrain render — never a bare gray heatmap.
  result = renderBrMap(m, maxDim, MapRect(), false)
  let scale =
    if maxDim <= 0: 1.0
    else: min(1.0, float(maxDim) / float(max(m.width, m.height)))
  proc toOut(v: int): int = int(round(float(v) * scale))
  let half = ZoneStepPx div 2
  for c in v.zoneCandidates:
    let color =
      if c.pass: rgba(60, 200, 90, 130)
      else: rgba(210, 40, 40, 110)
    let x0 = toOut(c.cx - half)
    let y0 = toOut(c.cy - half)
    let x1 = toOut(c.cx + half)
    let y1 = toOut(c.cy + half)
    for y in max(0, y0) .. min(result.height - 1, y1):
      for x in max(0, x0) .. min(result.width - 1, x1):
        let bg = result.unsafe[x, y].rgba
        let a = int(color.a)
        result.unsafe[x, y] = rgba(
          uint8((int(color.r) * a + int(bg.r) * (255 - a)) div 255),
          uint8((int(color.g) * a + int(bg.g) * (255 - a)) div 255),
          uint8((int(color.b) * a + int(bg.b) * (255 - a)) div 255),
          255)

# --- commands ------------------------------------------------------------------

proc readSpec(path: string): BrMap =
  if not fileExists(path): fail("no such spec file: " & path)
  brMapFromSpecJson(readFile(path))

proc brDefaultParams(style: MapStyle): StyleParams =
  ## mapgen_styles.defaultParams is tuned for a HALF-board about to be
  ## mirrored; fed BR's full 3211x1713 board directly it reads as thin
  ## scattered marks. Round-3 (Maxwell's "no rooms, no intention" rejection)
  ## demoted caves from BR's PRIMARY content to organic fill BETWEEN
  ## authored POI structures; ROUND 8 (doctrine item 3b: "RESTORE the
  ## organic caves masses as heavy between-places fill — fat and numerous")
  ## un-demotes it partway back. `cell` is bumped (55 -> 85): a BIGGER CA
  ## cell means FEWER, LARGER blobs for the same field area — "fat", and
  ## it caps the raw shape count genCaves emits (each on-cell is one
  ## polygon in the spec), which is what keeps the 3x mass increase inside
  ## the 58KB spec budget without decimating vertices harder than
  ## CaveFillVertDecimate already does.
  ##
  ## birth/death changed 5/4 -> 4/3 and fillProb 0.34 -> 0.42 together,
  ## MEASURED, not guessed: a field-wide B5/D4 CA sits on a knife-edge
  ## percolation threshold (9 raw shapes at fillProb=0.34, 565 at 0.60 —
  ## a 60x swing across 0.26 of fillProb) AND, once caves moved to
  ## per-patch generation (caveFillPatches, below — see its own comment
  ## for why patching replaced one field-wide pass), B5/D4's threshold
  ## shifts even further under the smaller per-patch grid's stronger edge
  ## effects (genCaves counts off-grid neighbours as open, so a small
  ## patch dies out faster). B4/D3 is a gentler rule that scales smoothly
  ## with fillProb instead of snapping between "empty" and "solid" — at
  ## 0.42 it reliably produces several separate, individually fat,
  ## well-welded clusters per patch (measured on the 6-family probe below)
  ## instead of 0 or a field-eating monolith.
  result = defaultParams(style)
  if style == styleCaves:
    result.cell = 85
    result.fillProb = 0.42
    result.steps = 5
    result.birth = 4
    result.death = 3
    result.blobScale = 0.92

proc cmdGenerate(a: Args) =
  let
    seed = a.intFlag("seed", 1)
    style = parseStyle(a.flag("style", "caves"))
    keystoneFlag = a.flag("keystone", "")
    keystone = if keystoneFlag.len > 0: keystoneFromStr(keystoneFlag) else: keystoneFromSeed(seed)
  var params = brDefaultParams(style)
  applyParams(params, a.params)
  var m = generateBrMap(seed, style, params, keystone)
  let rawCount = m.obstacles.len
  if not a.bools.getOrDefault("noPrune", false):
    ## Only the DEMOTED CAVES FILL (obstacles[structureCount..^1]) is
    ## subject to the anti-confetti prune — POI structures are authored,
    ## not organic, and a broken ruin's lone wall segment can legitimately
    ## sit below the confetti floor without being scatter.
    let protectedShapes = m.obstacles[0 ..< m.structureCount]
    let fillShapes = m.obstacles[m.structureCount .. ^1]
    let prunedFill = pruneConfetti(fillShapes, m.width, m.height, ConfettiFloorPx2)
    m.obstacles = protectedShapes & prunedFill
  var repaired = 0
  var roomsRepaired = 0
  if not a.bools.getOrDefault("noRepair", false):
    let screens = ensurePerSpawnCover(m, PerSpawnCoverGR)
    repaired = screens.len
    m.obstacles.add screens
    roomsRepaired = ensureInteriorConnectivity(m)
  var itemRng = initRand(seed xor 0x6C5D_E812)
  if not a.bools.getOrDefault("noItems", false):
    placeItems(m, itemRng)
    ensureItemCoverage(m, PerSpawnCoverGR, itemRng)
  let spec = brMapSpecJson(m)
  let outPath = a.flag("out", "")
  if outPath.len == 0:
    echo spec
  else:
    writeFile(outPath, spec)
    ## ROUND 8 (deliverable #1: "Print measured permille in every gen log +
    ## metrics"): a full validateBr call here is the cheapest way to get
    ## coverPermille/bigMassCount/specSizeBytes without duplicating the
    ## measurement code — it's a single extra pass over one map at draw
    ## time, not a hot loop.
    let v = validateBr(m)
    stderr.writeLine(
      &"generated br {styleToStr(style)} seed={seed} keystone={keystoneToStr(m.keystone)} " &
      &"{m.width}x{m.height} " &
      &"gunRange={m.gunRange} spawns={m.spawns.len} pois={m.pois.len} " &
      &"obstacles={m.obstacles.len} (structures={m.structureCount})" &
      &" (pruned {rawCount - (m.obstacles.len - repaired)} confetti of {rawCount}," &
      &" {repaired} spawn-cover repairs, medkits={m.medKitCandidates.len}" &
      &" grenades={m.grenadeSpawns.len}) -> {outPath}")
    stderr.writeLine(
      &"  cover={v.coverPermille}‰ (band [{CoverPermilleMinBr},{CoverPermilleMaxBr}])" &
      &" masses={v.bigMassCount} (band [{PlaceCountFloor},{PlaceCountCeiling}], confetti={v.confettiCount}/{ConfettiCeiling})" &
      &" distToCover p95={v.distToCoverP95Px:.0f}px max={v.distToCoverMaxPx:.0f}px" &
      &" specSize={v.specSizeBytes}B headroom={SpecSizeBudgetBytes - v.specSizeBytes}B" &
      &" allPass={v.allPass}")
    ## ROUND 9 (doctrine item 2: "print per-structure room counts in the
    ## gen log and metrics").
    stderr.writeLine(
      &"  rooms: distinct-counts={v.distinctRoomCounts} (floor 3, variety={v.roomCountVarietyPass})" &
      &" stranded={v.strandedRooms} (interiorConn={v.interiorConnPass}, repaired={roomsRepaired})" &
      &" by-structure={v.roomCountsByArchetype}")

proc cmdRender(a: Args) =
  if a.positionals.len == 0: fail("render needs a spec path")
  let m = readSpec(a.positionals[0])
  let outPath = a.flag("out", a.positionals[0].changeFileExt("png"))
  let maxDim = a.intFlag("max", 1600)
  let v = validateBr(m)
  let zc = bestZoneCandidate(v, m.width, m.height)
  let rect = zoneRect(m.width, m.height, m.zoneZ, zc.cx, zc.cy)
  renderBrMap(m, maxDim, rect, true).writeFile(outPath)
  stderr.writeLine(&"rendered {a.positionals[0]} -> {outPath}")
  if a.bools.getOrDefault("heatmap", false):
    let heatPath = outPath.changeFileExt("") & ".zoneheat.png"
    renderZoneHeatmap(m, v, maxDim).writeFile(heatPath)
    stderr.writeLine(&"rendered zone-coverage heatmap -> {heatPath}")

proc printValidation(v: BrValidation) =
  echo &"connectivity:  {(if v.connectivityPass: \"PASS\" else: \"FAIL: \" & v.connectivityReason)}  (components={v.componentCount}, dominant={v.dominantFrac*100:.1f}%)"
  echo &"exit rule:     {(if v.exitPass: \"PASS\" else: \"FAIL: \" & v.exitReason)}  (min pocket exits={v.minPocketExits})"
  echo &"anti-confetti: {(if v.antiConfettiPass: \"PASS\" else: \"FAIL: \" & v.antiConfettiReason)}  (masses={v.massCount}, confetti={v.confettiCount}, largest={v.largestMassPx2}px^2)"
  echo &"zone-viable:   {(if v.zonePass: \"PASS\" else: \"FAIL: \" & v.zoneReason)}  (viable={v.zoneViableFrac*100:.1f}% of {v.zoneCandidates.len} candidates)"
  echo &"spec size:     {(if v.specSizePass: \"PASS\" else: \"FAIL: \" & v.specSizeReason)}  ({v.specSizeBytes}B / {SpecSizeBudgetBytes}B budget)"
  echo &"place count:   {(if v.placeCountPass: \"PASS\" else: \"FAIL: \" & v.placeCountReason)}  (bigMasses={v.bigMassCount}, band=[{PlaceCountFloor},{PlaceCountCeiling}])"
  echo &"per-spawn cvr: {(if v.perSpawnCoverPass: \"PASS\" else: \"FAIL: \" & v.perSpawnCoverReason)}  (uncovered={v.uncoveredSpawns}/16 within {PerSpawnCoverGR}G)"
  echo &"cover permille:{(if v.coverPermillePass: \"PASS\" else: \"FAIL: \" & v.coverPermilleReason)}  ({v.coverPermille}‰, band=[{CoverPermilleMinBr},{CoverPermilleMaxBr}]‰)"
  echo &"dist-to-cover: {(if v.distToCoverPass: \"PASS\" else: \"FAIL: \" & v.distToCoverReason)}  (p95={v.distToCoverP95Px:.0f}px, max={v.distToCoverMaxPx:.0f}px, floors=[{DistToCoverP95FracG}G,{DistToCoverMaxFracG}G])"
  echo &"item coverage: {(if v.itemCoveragePass: \"PASS\" else: \"FAIL: \" & v.itemCoverageReason)}  (uncovered={v.uncoveredSpawnsItems}/16 within {PerSpawnCoverGR}G)"
  echo &"POI has loot:  {(if v.poiLootPass: \"PASS\" else: \"FAIL: \" & v.poiLootReason)}  (missing={v.poisWithoutLoot} POIs)"
  echo &"keystone:      {(if v.keystonePass: \"PASS\" else: \"FAIL: \" & v.keystoneReason)}  ({v.keystoneLabel}={v.keystoneValue:.2f}, floor={v.keystoneFloor:.2f})"
  echo &"interior conn: {(if v.interiorConnPass: \"PASS\" else: \"FAIL: \" & v.interiorConnReason)}  (stranded rooms={v.strandedRooms})"
  echo &"room variety:  {(if v.roomCountVarietyPass: \"PASS\" else: \"FAIL: \" & v.roomCountVarietyReason)}  (distinct counts={v.distinctRoomCounts}, floor=3)"
  echo &"  room counts by structure: {v.roomCountsByArchetype}"

proc cmdValidate(a: Args) =
  if a.positionals.len == 0: fail("validate needs a spec path")
  let m = readSpec(a.positionals[0])
  printMetrics(m)
  let v = validateBr(m)
  printValidation(v)
  if v.allPass:
    echo "PASS"
    quit(0)
  else:
    echo "FAIL"
    quit(1)

proc cmdMetrics(a: Args) =
  if a.positionals.len == 0: fail("metrics needs a spec path")
  let m = readSpec(a.positionals[0])
  printMetrics(m)
  if a.bools.getOrDefault("json", false):
    let v = validateBr(m)
    let outPath = a.flag("out", "")
    let js = $metricsJson(m, v)
    if outPath.len == 0: echo js
    else: writeFile(outPath, js)

proc cmdContactSheet(a: Args) =
  if a.positionals.len == 0: fail("contactsheet needs one or more PNG paths")
  var images: seq[Image]
  for p in a.positionals:
    images.add readImage(p)
  let cols = a.intFlag("cols", 3)
  let rows = (images.len + cols - 1) div cols
  let cellW = a.intFlag("cellw", 480)
  var maxAspect = 0.5
  for img in images: maxAspect = max(maxAspect, float(img.height) / float(img.width))
  let cellH = int(float(cellW) * maxAspect)
  let pad = 8
  let sheet = newImage(cols * (cellW + pad) + pad, rows * (cellH + pad) + pad)
  for y in 0 ..< sheet.height:
    for x in 0 ..< sheet.width:
      sheet.unsafe[x, y] = rgba(28, 24, 20, 255)
  for i, img in images:
    let col = i mod cols
    let row = i div cols
    let scale = min(float(cellW) / float(img.width), float(cellH) / float(img.height))
    let dw = max(1, int(float(img.width) * scale))
    let dh = max(1, int(float(img.height) * scale))
    let ox = pad + col * (cellW + pad) + (cellW - dw) div 2
    let oy = pad + row * (cellH + pad) + (cellH - dh) div 2
    for y in 0 ..< dh:
      let sy = clamp(int(float(y) / scale), 0, img.height - 1)
      for x in 0 ..< dw:
        let sx = clamp(int(float(x) / scale), 0, img.width - 1)
        let px = ox + x
        let py = oy + y
        if px >= 0 and px < sheet.width and py >= 0 and py < sheet.height:
          sheet.unsafe[px, py] = img.unsafe[sx, sy]
  let outPath = a.flag("out", "contactsheet.png")
  sheet.writeFile(outPath)
  stderr.writeLine(&"contact sheet: {images.len} images -> {outPath}")

const usage = """
brmapkit — author battle-royale maps (fork of tools/mapkit.nim; see
docs/designs/BR_MAPGEN.md)

  brmapkit generate [--style caves] [--seed N] [--param k=v ...] [-o spec.json]
                    (caves is the only doctrine-validated style; bsp/maze/
                    scatter are wired for experimentation but unproven at
                    giant scale)
  brmapkit render   spec.json [-o out.png] [--max N] [--heatmap]
                    (--heatmap also writes <out>.zoneheat.png, the §5.4
                    circle-center-coverage view)
  brmapkit validate spec.json          # BR gates: PASS/FAIL, exit code
  brmapkit metrics  spec.json [--json] [-o out.json]
  brmapkit contactsheet a.png b.png ... [-o sheet.png] [--cols N] [--cellw N]
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
    of "contactsheet": cmdContactSheet(a)
    else:
      stderr.writeLine("unknown command: " & argv[0])
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine("brmapkit: " & e.msg)
    quit(2)
  except CtfError as e:
    stderr.writeLine("brmapkit: " & e.msg)
    quit(1)
