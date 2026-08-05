## Player-vs-player collision against a SYNTHETIC walk mask: every test wipes
## the real terrain (`blockAll`) and opens its own floor, anchored at
## `TestFieldX0`/`TestFieldY0` — the hexagonal board has no floor in the corners
## of its bounding box, so the old top-left rectangles named permanent void.
import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

const
  FieldX0 = TestFieldX0
  FieldY0 = TestFieldY0
  ShortX1 = FieldX0 + 300  ## the one test that only needs a short runway.
  LongX1 = FieldX0 + 600
  FieldY1 = FieldY0 + 200
  LaneY = FieldY0 + 100    ## the lane both bodies drive along.
  StartX = FieldX0 + 60

proc bodyGap(sim: SimServer, a, b: int): int =
  ## Chebyshev distance between two player centers; footprints overlap
  ## when this is <= PlayerSolidSpan.
  max(
    abs(sim.players[a].x - sim.players[b].x),
    abs(sim.players[a].y - sim.players[b].y)
  )

suite "player body collisions":
  test "a mover cannot drive over a standing player":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      wall = sim.addPlayer("wall")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, ShortX1, FieldY1)
    sim.placeStill(mover, StartX, LaneY)
    sim.placeStill(wall, StartX + 60, LaneY)
    for _ in 0 .. 120:
      sim.applyInput(mover, InputState(right: true))
      # The standing player idles (friction only) but still resolves input.
      sim.applyInput(wall, InputState())
      check sim.bodyGap(mover, wall) > PlayerSolidSpan  # never overlapping
    check sim.players[mover].x > StartX                 # advanced into contact

  test "ramming shoves the standing player forward":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      target = sim.addPlayer("target")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, LongX1, FieldY1)
    sim.placeStill(mover, StartX, LaneY)
    sim.placeStill(target, StartX + 40, LaneY)
    for _ in 0 .. 60:
      sim.applyInput(mover, InputState(right: true))
      sim.applyInput(target, InputState())
    check sim.players[target].x > StartX + 40           # got pushed along
    check sim.players[target].velX >= 0

  test "head-on collision bounces both movers back":
    var sim = initCtfForTest(defaultGameConfig())
    let
      left = sim.addPlayer("left")
      right = sim.addPlayer("right")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, LongX1, FieldY1)
    sim.placeStill(left, StartX, LaneY)
    sim.placeStill(right, StartX + 100, LaneY)
    var bounced = false
    for _ in 0 .. 40:
      # Drive both toward each other until the frame after first contact.
      sim.applyInput(left, InputState(right: true))
      sim.applyInput(right, InputState(left: true))
      check sim.bodyGap(left, right) > PlayerSolidSpan
      if sim.players[left].velX < 0 and sim.players[right].velX > 0:
        bounced = true
        break
    check bounced                                       # both rebounded

  test "dead players never block movement":
    var sim = initCtfForTest(defaultGameConfig())
    let
      mover = sim.addPlayer("mover")
      corpse = sim.addPlayer("corpse")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, LongX1, FieldY1)
    sim.placeStill(mover, StartX, LaneY)
    sim.placeStill(corpse, StartX + 60, LaneY)
    sim.players[corpse].alive = false
    for _ in 0 .. 60:
      sim.applyInput(mover, InputState(right: true))
    # drove straight past
    check sim.players[mover].x > StartX + 60 + PlayerSolidSpan

  test "overlapping players can move apart but not further in":
    var sim = initCtfForTest(defaultGameConfig())
    let
      a = sim.addPlayer("a")
      b = sim.addPlayer("b")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, LongX1, FieldY1)
    # Force an overlapped start (a respawn onto an occupied home).
    sim.placeStill(a, StartX + 60, LaneY)
    sim.placeStill(b, StartX + 66, LaneY)
    let startGap = sim.bodyGap(a, b)
    for _ in 0 .. 30:
      sim.applyInput(a, InputState(left: true))
      sim.applyInput(b, InputState())
      check sim.bodyGap(a, b) >= startGap               # never deeper in
    check sim.bodyGap(a, b) > PlayerSolidSpan           # escaped the overlap
