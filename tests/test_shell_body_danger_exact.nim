## The optimized rebuild must preserve the previous runtime's float bits.
import std/unittest
import ../src/shell/[body_map, body_nav]
import body_danger_reference

proc dangerTestMap(width, height: int): BodyMap =
  var pixels = newSeq[bool](width * height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      pixels[y * width + x] = x > 0 and y > 0 and
        x < width - 1 and y < height - 1 and
        not (x mod 8 == 4 and y mod 8 == 4 and
          ((x div 8 + 2 * (y div 8)) mod 5 == 0))
  newBodyMap(pixels, width, height, 1, @[(24, 24)])

proc checkRebuilds(map: BodyMap, rangePx, rebuilds: int) =
  let system = newBodyNavSystem(map, 2, rangePx)
  let oracle = newDangerOracle(map, rangePx)
  for tick in 0 ..< rebuilds:
    # Vary origins so stale stamps from a previous generation cannot pass.
    var input = DangerInput(selfXy: (24, 24))
    for source in 0 ..< (if tick mod 11 == 0: 0 else: 8):
      input.candidates.add(DangerCandidate(seatIndex: source,
        pos: ((tick * 17 + source * 31) mod (map.width + 16) - 8,
              (tick * 29 + source * 13) mod (map.height + 16) - 8)))
    system.seats[0].rebuildDanger(map, input, tick)
    var sources: seq[BodyPoint]
    for candidate in system.seats[0].selectedDangerSources:
      sources.add(candidate.pos)
    oracle.rebuildReference(map, sources, tick)
    let actual = system.seats[0].dangerSnapshot
    check actual.len == oracle.danger.values.len
    for index in 0 ..< actual.len:
      check cast[uint32](actual[index]) ==
        cast[uint32](oracle.danger.values[index])
    check cast[uint32](system.seats[0].danger.maximum) ==
      cast[uint32](oracle.danger.maximum)
    # The shared immutable geometry must not share writable seat state.
    for value in system.seats[1].dangerSnapshot:
      check value == 0'f32

suite "danger rebuild exactness":
  test "ranges, partial cells, walls and off-map sources preserve float bits":
    for dimensions in [(64, 64), (73, 85), (128, 96)]:
      let map = dangerTestMap(dimensions[0], dimensions[1])
      for rangePx in [1, 15, 64, 190, 331, 1050, 1300]:
        checkRebuilds(map, rangePx, 7)

  test "varying sources remain exact through repeated byte-stamp rollovers":
    checkRebuilds(dangerTestMap(96, 104), 64, 160)
