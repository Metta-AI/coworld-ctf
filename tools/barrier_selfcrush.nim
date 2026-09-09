## Does the PLACER flatten its own barrier by walking forward?
## The flat side sits one apothem (~21px) down the placer's aim, and the
## baseline bot places "across its current combat aim" then advances on the
## threat -- so this asks the sim directly.
import
  std/[strformat, strutils],
  ../src/ctf/[global, sim],
  ../tests/helpers,
  toolutil

proc main() =
  chdirGameDir()
  var config = defaultGameConfig()
  config.update("""{"barrierPickups": 2}""")
  var sim = initCtfForTest(config)
  discard sim.addPlayer("red0")
  discard sim.addPlayer("blue0")
  sim.startGame()
  sim.players[0].team = Red
  sim.players[1].team = Blue

  let kit = sim.medKitSpawns[0]
  # Park the other cog far away so ONLY the placer can touch the band.
  sim.placeStill(1, 40, 40)

  # Place aiming east, then hold RIGHT (east) -- straight into the flat side.
  sim.placeStill(0, kit.x - CollisionW div 2, kit.y - CollisionH div 2)
  sim.players[0].aimBrads = 0
  sim.players[0].hasBarrier = true
  var held = sim.none()
  held[0].c = true
  sim.step(held, sim.none())
  sim.step(sim.none(), held)
  doAssert sim.placedBarriers.len == 1
  echo &"placed at ({sim.placedBarriers[0].x},{sim.placedBarriers[0].y}) hp={sim.placedBarriers[0].hp}"

  # Standing still is safe (David's own test). Confirm, then walk forward.
  let none = sim.none()
  for _ in 0 ..< 5: sim.step(none, none)
  echo &"after 5 ticks standing still: standing={sim.placedBarriers.len}"

  var fwd = sim.none()
  fwd[0].right = true
  var crushedAt = -1
  for t in 1 .. 40:
    sim.step(fwd, fwd)
    if sim.placedBarriers.len == 0:
      crushedAt = t
      break
  if crushedAt >= 0:
    let secs = formatFloat(float(crushedAt) / 24.0, ffDecimal, 2)
    echo "SELF-CRUSHED after " & $crushedAt & " ticks of walking forward (" &
      secs & "s), hp was still 10/10"
  else:
    echo "survived 40 ticks of the placer walking forward"

  # Now the opposite: place and RETREAT (away from the aim / behind the arc).
  sim.players[0].hasBarrier = true
  sim.placeStill(0, kit.x - CollisionW div 2, kit.y - CollisionH div 2)
  sim.players[0].aimBrads = 0
  held = sim.none()
  held[0].c = true
  sim.step(held, sim.none())
  sim.step(sim.none(), held)
  doAssert sim.placedBarriers.len == 1
  var back = sim.none()
  back[0].left = true
  var backCrush = -1
  for t in 1 .. 40:
    sim.step(back, back)
    if sim.placedBarriers.len == 0:
      backCrush = t
      break
  if backCrush >= 0:
    echo "RETREAT also crushed it after " & $backCrush & " ticks"
  else:
    echo "RETREATING is SAFE: barrier still standing after 40 ticks, hp=" &
      $sim.placedBarriers[0].hp

main()
