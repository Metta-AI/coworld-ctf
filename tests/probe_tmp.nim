import std/random
import ctf/[sim, mapgen_vocab]
proc asym(shapes: seq[ArenaShape]): (int,int) =
  var base = generateMapAttempt(5, MapGenOverrides(
    size: "standard", symmetry: "mirror", windows: 0, pits: 0, pitDensity: -1))
  base.leftObstacles = shapes
  let obs = buildArenaObstacles(base)
  var bad = 0; var wall = 0
  for y in 12 ..< base.height-12:
    for x in 12 ..< base.width-12:
      let a = mapWallAt(base, obs, x, y)
      if a: inc wall
      if a != mapWallAt(base, obs, base.width-1-x, y): inc bad
  (wall, bad)
let p = vocabParams("standard", 2)
# barrier orientation: vertical columns
for item in [viMassif, viCave]:
  var tw = 0; var tb = 0; var mv = 0
  for seed in 1..4:
    var r = initRand(seed)
    var sh: seq[ArenaShape]
    for k in 0..2:
      sh.add emitVocab(item, r, MapRect(x:60+k*180, y:20, w:170, h:610), p)
    for s in sh:
      if s.kind == shapePolygon: mv = max(mv, s.points.len)
    let (w,b) = asym(sh); tw += w; tb += b
  echo vocabName(item), " VERTICAL: wall=", tw, " asym=", tb, " maxverts=", mv
# lane-divider orientation: horizontal bands
for item in [viMassif, viCave]:
  var tw = 0; var tb = 0
  for seed in 1..4:
    var r = initRand(seed)
    var sh: seq[ArenaShape]
    for k in 0..2:
      sh.add emitVocab(item, r, MapRect(x:60, y:20+k*200, w:520, h:190), p)
    let (w,b) = asym(sh); tw += w; tb += b
  echo vocabName(item), " HORIZONTAL: wall=", tw, " asym=", tb
