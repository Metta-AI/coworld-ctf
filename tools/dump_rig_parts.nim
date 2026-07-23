## Standalone bake check: render the rig part sprites (chassis/legs/wheels/arms)
## directly from the sim.nim bake procs to PNGs, no emission. Confirms the bakes
## before wiring FK. Throwaway. Writes /tmp/rigview/nimpart_*.png.
import pixie, ../src/ctf/sim

proc toImg(px: seq[uint8], n: int): Image =
  result = newImage(n, n)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let i = (y * n + x) * 4
      result[x, y] = rgba(px[i], px[i+1], px[i+2], px[i+3])

let n = RigCanvas
# chassis (hub disc) facing north (rot 4 of 16 = 90deg = north? rot0=east)
toImg(rigChassisPixels(Red, 4), n).writeFile("/tmp/rigview/nimpart_chassis.png")
# assemble a rest pose: 3 legs at their rest step (turnAmt 0), north heading
proc legStep(leg: RigLeg): int = rigLegStepFor(leg, 64, 0)
for (leg, name) in [(rigFrontRight,"fr"),(rigFrontLeft,"fl"),(rigRear,"rear")]:
  toImg(rigLegPixels(Red, leg, legStep(leg)), n).writeFile("/tmp/rigview/nimpart_leg_" & name & ".png")
toImg(rigWheelPixels(8), n).writeFile("/tmp/rigview/nimpart_wheel.png")
toImg(rigArmsPixels(Red, 4), n).writeFile("/tmp/rigview/nimpart_arms.png")

# composite rest pose: chassis + 3 legs + wheels at their feet, all north heading, turnAmt 0
proc composite(turnAmt: int, fname: string) =
  var cv = newImage(n, n)
  let bh = 64  # north
  # wheels first (bottom)
  for leg in [rigFrontRight, rigFrontLeft, rigRear]:
    let f = rigLegFootScreen(leg, bh, turnAmt)
    var w = toImg(rigWheelPixels(0), n)  # yaw north placeholder
    cv.draw(w, translate(vec2(float32(f.dx), float32(f.dy))))
  for leg in [rigRear, rigFrontLeft, rigFrontRight]:
    let h = rigLegHipScreen(leg, bh)
    var l = toImg(rigLegPixels(Red, leg, rigLegStepFor(leg, bh, turnAmt)), n)
    cv.draw(l, translate(vec2(float32(h.dx), float32(h.dy))))
  cv.draw(toImg(rigChassisPixels(Red, 4), n), translate(vec2(0, 0)))
  cv.writeFile(fname)
composite(0, "/tmp/rigview/nimcomp_rest.png")
composite(1000, "/tmp/rigview/nimcomp_left.png")
composite(-1000, "/tmp/rigview/nimcomp_right.png")
echo "wrote rig part + composite PNGs"
