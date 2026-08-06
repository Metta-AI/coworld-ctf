## Are `VocabParams.symmetryIsReflection` and `.mirrorIsVertical` still needed?
## Both are fairness WORKAROUNDS: they make `massif`/`cave`/`beam` give up their
## traced polygon outline (for round discs and capsules) whenever the downstream
## symmetry would rasterize that outline unfairly. The cost is visible — a
## 4-team massif ships as beads on a string instead of an organic silhouette.
##
## This measures the RAW OBSTACLE UNION against its own symmetry image, every
## pixel, with each workaround forced OFF. It deliberately does NOT go through
## `mapWallAt`: the protected-floor carve is a different surface with its own
## regression test (`test_mapgen_vocab`, "the protected floor is its own
## symmetry image"), and folding it in would blame one for the other.
##
## MEASURED 2026-08-05, all 8 items x 3 size classes x 3 RNG seeds x
## {mirror, rot180, rot90}, >100M wall px: **0 asymmetric pixels with BOTH
## workarounds forced off.** They are removable — but NOT because of the GV40
## protected-floor fixes: the identical run on the pre-GV40 tree (8caaf9e)
## gives byte-identical numbers. What retired them is `fd3bb22`, the
## `pointInPolygon` strict-straddle fix, which is the exact condition the
## flags' own doc comments name ("revisit when arena.pointInPolygon moves to
## the half-open rule"). Removal is the vocabulary owner's call, not this
## probe's.
import std/[strformat, random]
import ../src/ctf/[sim, map_rules, mapgen_vocab]

proc sweep(item: VocabItem, sizeName, symmetry: string, teams: int,
           p: VocabParams, rngSeed = 90210): tuple[wall, bad: int] =
  var base = generateMapAttempt(5, MapGenOverrides(
    size: sizeName, symmetry: symmetry, windows: 0, pits: 0, pitDensity: -1),
    teams)
  var shapes: seq[ArenaShape]
  var r = initRand(rngSeed)
  let (fw, fh) = vocabFootprint(item, p)
  let
    yLimit = (if symmetry == "rot90": base.height div 2 else: base.height) - 20
    xLimit = base.width div 2 - 20
  var y = 20
  while y + fh <= yLimit:
    var x = (if symmetry == "rot90": 20 else: 60)
    while x + fw <= xLimit:
      shapes.add emitVocab(item, r, MapRect(x: x, y: y, w: fw, h: fh), p)
      x += fw
    y += fh
  if shapes.len == 0: return
  base.leftObstacles = shapes
  let
    w = base.width
    h = base.height
  var mask = newSeq[bool](w * h)
  for s in buildArenaObstacles(base):
    let (x0, y0, x1, y1) = shapeBounds(s)
    for yy in max(0, y0) .. min(h - 1, y1):
      for xx in max(0, x0) .. min(w - 1, x1):
        if not mask[yy * w + xx] and inShape(xx, yy, s):
          mask[yy * w + xx] = true
  for yy in 0 ..< h:
    for xx in 0 ..< w:
      if not mask[yy * w + xx]: continue
      inc result.wall
      let image =
        case symmetry
        of "rot180": (h - 1 - yy) * w + (w - 1 - xx)
        of "rot90": xx * w + (w - 1 - yy)
        else: yy * w + (w - 1 - xx)
      if image < 0 or image >= mask.len or not mask[image]: inc result.bad

const AllItems = [viDorito, viCan, viSnake, viBeam, viTemple, viBunker,
                  viMassif, viCave]

echo "A) symmetryIsReflection FORCED ON for 4 teams (traced outlines on rot90)"
echo "item      size      shipped bad/wall        forced bad/wall"
for sizeName in ["standard", "large", "giant"]:
  for item in AllItems:
    var sa, sw, fa, fw = 0
    for rngSeed in [90210, 7, 31337]:
      let
        shipped = vocabParams(sizeName, 4)
        forced = block:
          var q = shipped
          q.symmetryIsReflection = true
          q
        a = sweep(item, sizeName, "rot90", 4, shipped, rngSeed)
        b = sweep(item, sizeName, "rot90", 4, forced, rngSeed)
      sa += a.bad; sw += a.wall; fa += b.bad; fw += b.wall
    if sw == 0 and fw == 0: continue
    echo &"{vocabName(item):<9} {sizeName:<9} {sa:>7}/{sw:<12} {fa:>7}/{fw}"

echo ""
echo "B) mirrorIsVertical FORCED OFF for 2 teams (ridge runs parallel to axis)"
echo "item      size      sym     shipped bad/wall        forced bad/wall"
for sizeName in ["standard", "giant"]:
  for symmetry in ["mirror", "rot180"]:
    for item in AllItems:
      var sa, sw, fa, fw = 0
      for rngSeed in [90210, 7, 31337]:
        let
          shipped = vocabParams(sizeName, 2)
          forced = block:
            var q = shipped
            q.mirrorIsVertical = false
            q
          a = sweep(item, sizeName, symmetry, 2, shipped, rngSeed)
          b = sweep(item, sizeName, symmetry, 2, forced, rngSeed)
        sa += a.bad; sw += a.wall; fa += b.bad; fw += b.wall
      if sw == 0 and fw == 0: continue
      echo &"{vocabName(item):<9} {sizeName:<9} {symmetry:<7} " &
        &"{sa:>7}/{sw:<12} {fa:>7}/{fw}"
