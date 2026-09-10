## C6 count screen (read-only include of the frozen C2 cache source): replay a
## recorded NAVSRC trace through the selected-source seam and, for every
## source replayed, scan its visibility bitmap: count words, full words
## (all 64 bits), set bits, and set bits inside full words. Hits and misses
## are counted separately (the full-word arm only affects hits).
include "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/shell/body_nav"
import std/[os, strutils, json, bitops, tables]
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/ctf/br_map_pool"
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/ctf/sim_types"

type Tally = object
  sources, words, fullWords, setBits, fullWordBits: int
  rowSpans: int   # contiguous spans a full word splits into at row boundaries
  maxSetBits, minSetBits: int

proc scanSlot(cache: DangerSourceCache, slot: int, diameter: int, t: var Tally) =
  inc t.sources
  var thisBits = 0
  for w in 0 ..< cache.words:
    thisBits += countSetBits(cache.bits[slot * cache.words + w])
  t.maxSetBits = max(t.maxSetBits, thisBits)
  t.minSetBits = (if t.sources == 1: thisBits else: min(t.minSetBits, thisBits))
  for w in 0 ..< cache.words:
    let word = cache.bits[slot * cache.words + w]
    inc t.words
    let bits = countSetBits(word)
    t.setBits += bits
    if word == high(uint64):
      inc t.fullWords
      t.fullWordBits += 64
      var k = w * 64
      var remaining = 64
      while remaining > 0:
        let kx = k mod diameter
        let n = min(remaining, diameter - kx)
        inc t.rowSpans
        k += n; remaining -= n

proc replayTrace(path, mapName: string, seats, rangePx: int): JsonNode =
  let map = newBodyMap(getBrMap(mapName))
  let system = newBodyNavSystem(map, seats, rangePx, prepareRouteQueries = false)
  let diameter = system.seats[0].dangerGeometry.radius * 2 + 1
  var hitT, missT: Tally
  for raw in lines(path):
    if not raw.startsWith("NAVSRC sched "): continue
    var kv = initTable[string, string]()
    for token in raw[13 .. ^1].split(' '):
      let eq = token.find('=')
      if eq > 0: kv[token[0 ..< eq]] = token[eq + 1 .. ^1]
    if kv["changed"] != "1": continue
    let seat = parseInt(kv["seat"]); let count = parseInt(kv["n"])
    var points: seq[BodyPoint]
    if count > 0:
      for item in kv["pts"].split(','):
        let p = item.split(':'); points.add((x: parseInt(p[0]), y: parseInt(p[1])))
    let target = system.seats[seat]
    let cache = target.dangerSourceCache
    # classify hit/miss BEFORE the rebuild (same key rule as production)
    var wasHit: seq[bool]
    for p in points:
      let o = map.cellOf(p)
      wasHit.add cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x)) >= 0
    for i, p in points:
      target.selectedDangerPoints[i] = p; target.selectedDangerSeats[i] = -1
    target.selectedDangerCount = points.len
    target.rebuildSelectedDanger(map, parseInt(kv["tick"]))
    for i, p in points:
      let o = map.cellOf(p)
      let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
      doAssert slot >= 0
      if wasHit[i]: cache.scanSlot(slot, diameter, hitT) else: cache.scanSlot(slot, diameter, missT)
  proc j(t: Tally): JsonNode =
    %*{"sources": t.sources, "words": t.words, "full_words": t.fullWords,
       "set_bits": t.setBits, "full_word_bits": t.fullWordBits,
       "full_word_bit_share": (if t.setBits > 0: t.fullWordBits.float / t.setBits.float else: 0.0),
       "row_spans_per_full_word": (if t.fullWords > 0: t.rowSpans.float / t.fullWords.float else: 0.0),
       "max_set_bits_per_source": t.maxSetBits, "min_set_bits_per_source": t.minSetBits}
  %*{"trace": path.extractFilename, "map": map.name, "diameter": diameter,
     "words_per_entry": system.seats[0].dangerSourceCache.words,
     "hits": j(hitT), "misses": j(missT)}

proc sampleMap(mapName: string, rangePx, stride: int): JsonNode =
  ## Configured-map screen without a trace: one cold rebuild per sampled
  ## standable 8 px cell centre (every `stride`-th cell), miss path only.
  let map = newBodyMap(getBrMap(mapName))
  let system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
  let diameter = system.seats[0].dangerGeometry.radius * 2 + 1
  let seat = system.seats[0]; let cache = seat.dangerSourceCache
  var t: Tally; var n = 0
  for cy in 0 ..< map.gridHeight:
    for cx in 0 ..< map.gridWidth:
      inc n
      if n mod stride != 0: continue
      let center = cellCenter((cx, cy))
      if not map.canStand(center): continue
      seat.selectedDangerPoints[0] = center; seat.selectedDangerCount = 1
      seat.rebuildSelectedDanger(map, 0)
      let slot = cache.sourceCacheSlot(int32(cy * map.gridWidth + cx))
      cache.scanSlot(slot, diameter, t)
  %*{"map": map.name, "diameter": diameter, "stride": stride, "sources": t.sources,
     "words": t.words, "full_words": t.fullWords, "set_bits": t.setBits,
     "full_word_bits": t.fullWordBits,
     "full_word_bit_share": (if t.setBits > 0: t.fullWordBits.float / t.setBits.float else: 0.0),
     "row_spans_per_full_word": (if t.fullWords > 0: t.rowSpans.float / t.fullWords.float else: 0.0),
     "max_set_bits_per_source": t.maxSetBits, "min_set_bits_per_source": t.minSetBits}

when isMainModule:
  var results = newJArray()
  if paramStr(1) == "--map":
    results.add sampleMap(paramStr(2), parseInt(paramStr(3)), parseInt(paramStr(4)))
  else:
    var i = 1
    while i + 2 <= paramCount():
      results.add replayTrace(paramStr(i), paramStr(i + 1), parseInt(paramStr(i + 2)), 1300)
      i += 3
  echo results.pretty
