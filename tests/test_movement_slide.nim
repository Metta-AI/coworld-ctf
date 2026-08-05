## Movement mechanics against a SYNTHETIC walk mask: every test here wipes the
## real terrain (`blockAll`) and opens its own floor, so the arena's obstacles
## never enter. The floor is anchored at `TestFieldX0`/`TestFieldY0` because the
## hexagonal board has no floor in the corners of its bounding box.
import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/sim

const
  FieldX0 = TestFieldX0
  FieldY0 = TestFieldY0
  FieldX1 = FieldX0 + 200
  FieldY1 = FieldY0 + 200
  StartX = FieldX0 + 60
  StartY = FieldY0 + 60
  WallX = FieldX0 + 110    ## first stone column of the blocking wall.

suite "movement footprint":
  test "moves across open floor toward input":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("mover")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, FieldX1, FieldY1)
    sim.placeStill(p, StartX, StartY)
    for _ in 0 .. 20:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > StartX       # accelerated to the right
    check sim.players[p].y == StartY      # no vertical drift

  test "solid footprint cannot overlap a wall":
    var sim = initCtfForTest(defaultGameConfig())
    let p = sim.addPlayer("bumper")
    sim.blockAll()
    sim.openField(FieldX0, FieldY0, FieldX1, FieldY1)
    # Wall column starting at x = WallX.
    for y in FieldY0 .. FieldY1:
      for x in WallX .. FieldX1:
        sim.walkMask[mapIndex(x, y)] = false
    sim.placeStill(p, StartX, StartY)
    for _ in 0 .. 80:
      sim.applyInput(p, InputState(right: true))
    check sim.players[p].x > StartX                 # advanced toward the wall
    check sim.players[p].x + PlayerHalf < WallX     # but never entered it
