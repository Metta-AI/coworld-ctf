## C6 tools-only correctness diagnostic (includes body_nav). Constructs private
## cache state directly, which real maps rarely reach: full words that cross
## kernel-row boundaries at diameter < 64 and at 327, sparse words, mixed
## words, and an all-visible bitmap; the final partial word keeps its padding
## zero. Every raster cell after replayVisibleCells is compared as float bits
## against the per-set-bit reference formula. Build with and without
## the candidate source; both must report zero mismatches, and the
## candidate must report full words actually taken.
include ../src/shell/body_nav
include c10_replay

## Tools-only arm label for JSON metadata (the native runner passes
## -d:DangerReplayArmLabel=parent|candidate); independent of any production
## define so the tool builds against materialized snapshots unchanged.
const DangerReplayArmLabel {.strdefine.} = "unspecified"
import std/[json, bitops]

proc referenceReplay(seat: BodyNavSeat, origin: BodyPoint, base: int,
    into: var seq[float32]) =
  let cache = seat.dangerSourceCache
  let radius = seat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  let gridW = seat.danger.gridW
  for wordIndex in 0 ..< cache.words:
    var word = cache.bits[base + wordIndex]
    while word != 0:
      let k = wordIndex * 64 + countTrailingZeroBits(word)
      let ky = k div diameter
      let kx = k - ky * diameter
      into[(origin.y - radius + ky) * gridW + origin.x - radius + kx] +=
        seat.dangerGeometry.kernel[k]
      word = word and (word - 1)

proc openMap(widthPx, heightPx: int): BodyMap =
  var walkable = newSeq[bool](widthPx * heightPx)
  for y in 1 ..< heightPx - 1:
    for x in 1 ..< widthPx - 1:
      walkable[y * widthPx + x] = true
  newBodyMap(walkable, widthPx, heightPx, 2, @[(16, 16), (widthPx - 17, heightPx - 17)])

proc setBit(cache: DangerSourceCache, base, k: int) =
  cache.bits[base + (k shr 6)] = cache.bits[base + (k shr 6)] or (1'u64 shl (k and 63))

proc runCase(rangePx, widthPx, heightPx: int, label: string,
    fill: proc(cache: DangerSourceCache, base, diameter: int)): JsonNode =
  let map = openMap(widthPx, heightPx)
  let system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
  let seat = system.seats[0]
  let cache = seat.dangerSourceCache
  let radius = seat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  # The production kernel is zero beyond 1050 px, so box-edge cells (where
  # row-straddling full words live) would add 0.0 and hide a wrong index.
  # Diagnostic-only: give every kernel index a distinct nonzero value
  # (exactly representable) so every replayed cell is checked by value.
  for k in 0 ..< seat.dangerGeometry.kernel.len:
    seat.dangerGeometry.kernel[k] = float32(k + 1)
  # Origin at the grid centre so the whole kernel box is in-grid.
  let origin: BodyPoint = (map.gridWidth div 2, map.gridHeight div 2)
  doAssert origin.x - radius >= 0 and origin.y - radius >= 0 and
    origin.x + radius < map.gridWidth and origin.y + radius < map.gridHeight,
    "box must fit the grid for " & label
  let base = 0
  for w in 0 ..< cache.words: cache.bits[base + w] = 0
  fill(cache, base, diameter)
  # Padding invariant: bits at or beyond diameter*diameter must be zero.
  for k in diameter * diameter ..< cache.words * 64:
    doAssert (cache.bits[base + (k shr 6)] and (1'u64 shl (k and 63))) == 0, "padding set"
  var setBits = 0; var fullWords = 0; var crossing = 0
  for w in 0 ..< cache.words:
    let word = cache.bits[base + w]
    setBits += countSetBits(word)
    if word == high(uint64):
      inc fullWords
      if (w * 64) mod diameter + 64 > diameter: inc crossing
  for c in 0 ..< seat.danger.values.len:
    seat.danger.values[c] = if c mod 2 == 0: cast[float32](0x80000000'u32) else: 0
  var reference = newSeq[float32](seat.danger.values.len)
  for c in 0 ..< reference.len: reference[c] = seat.danger.values[c]
  seat.replayFourCellGroups(origin, base, true)
  seat.referenceReplay(origin, base, reference)
  var mismatches = 0; var touched = 0
  for c in 0 ..< reference.len:
    if cast[uint32](reference[c]) != cast[uint32](seat.danger.values[c]): inc mismatches
    if reference[c] != 0: inc touched
  for c in 0 ..< seat.danger.values.len:
    seat.danger.values[c] = if c mod 2 == 0: cast[float32](0x80000000'u32) else: 0
  seat.replayFourCellGroups(origin, base, false)
  for c in 0 ..< reference.len:
    doAssert cast[uint32](reference[c]) == cast[uint32](seat.danger.values[c])
  doAssert touched == setBits, "every set bit must land on its own cell: " & label
  %*{"case": label, "range_px": rangePx, "diameter": diameter, "words": cache.words,
     "set_bits": setBits, "full_words": fullWords, "row_crossing_full_words": crossing,
     "touched_cells": touched, "cell_mismatches": mismatches}

var results = newJArray()
# diameter 27 (range 104 px, radius 13): full words cross rows every word.
results.add runCase(104, 640, 640, "d27_all_visible",
  proc(cache: DangerSourceCache, base, d: int) =
    for k in 0 ..< d * d: cache.setBit(base, k))
results.add runCase(104, 640, 640, "d27_full_words_crossing_rows",
  proc(cache: DangerSourceCache, base, d: int) =
    for k in 64 ..< 64 * 4: cache.setBit(base, k)     # words 1..3 full
    for k in [3, 300, 500, 700, d * d - 1]: cache.setBit(base, k))
# diameter 327 (1300 px): a full word placed to straddle a row boundary, plus
# sparse and mixed words and the last valid bit.
results.add runCase(1300, 2800, 2800, "d327_full_word_straddling_row",
  proc(cache: DangerSourceCache, base, d: int) =
    let start = ((5 * d - 20) div 64) * 64   # word containing row 5's end
    for k in start ..< start + 64: cache.setBit(base, k)
    for k in [0, 1, d - 1, d, 7 * d + 3, d * d - 1]: cache.setBit(base, k)
    for k in 2000 ..< 2064: cache.setBit(base, k)   # not word aligned: two partial words
  )
results.add runCase(1300, 2800, 2800, "d327_mixed_dense_rows",
  proc(cache: DangerSourceCache, base, d: int) =
    for ky in 100 .. 110:
      for kx in 0 ..< d: cache.setBit(base, ky * d + kx)   # 11 full rows
    for k in countup(0, d * d - 1, 97): cache.setBit(base, k))
results.add runCase(1300, 2800, 2800, "d327_all_visible",
  proc(cache: DangerSourceCache, base, d: int) =
    for k in 0 ..< d * d: cache.setBit(base, k))
# Every nibble mask at each map corner and side midpoint, including groups
# whose unset lanes would otherwise read outside the destination allocation.
var borderCases = 0
for rangePx in [104, 1300]:
  let borderMap = openMap(200, 200)
  let borderSystem = newBodyNavSystem(borderMap, 1, rangePx, prepareRouteQueries = false)
  let borderSeat = borderSystem.seats[0]
  let borderCache = borderSeat.dangerSourceCache
  let radius = borderSeat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  for k in 0 ..< borderSeat.dangerGeometry.kernel.len:
    borderSeat.dangerGeometry.kernel[k] = float32(k + 1)
  for origin in [(0, 0), (24, 0), (0, 24), (24, 24),
      (12, 0), (12, 24), (0, 12), (24, 12)]:
    for nibble in 0 ..< 16:
      for word in borderCache.bits.mitems: word = 0
      for k in 0 ..< diameter * diameter:
        let gx = origin[0] - radius + k mod diameter
        let gy = origin[1] - radius + k div diameter
        if gx >= 0 and gx < borderMap.gridWidth and gy >= 0 and gy < borderMap.gridHeight and
            (nibble and (1 shl (k mod 4))) != 0:
          borderCache.setBit(0, k)
      var reference = newSeq[float32](borderSeat.danger.values.len)
      for i in 0 ..< reference.len:
        reference[i] = if i mod 2 == 0: cast[float32](0x80000000'u32) else: float32(i mod 19)
        borderSeat.danger.values[i] = reference[i]
      borderSeat.referenceReplay(origin, 0, reference)
      borderSeat.replayFourCellGroups(origin, 0, true)
      for i in 0 ..< reference.len:
        doAssert cast[uint32](reference[i]) == cast[uint32](borderSeat.danger.values[i])
        borderSeat.danger.values[i] = if i mod 2 == 0: cast[float32](0x80000000'u32) else: float32(i mod 19)
      borderSeat.replayFourCellGroups(origin, 0, false)
      for i in 0 ..< reference.len:
        doAssert cast[uint32](reference[i]) == cast[uint32](borderSeat.danger.values[i])
      inc borderCases
for row in results: doAssert row["cell_mismatches"].getInt == 0
echo %*{"arm": DangerReplayArmLabel, "cases": results, "border_mask_cases": borderCases}

