## Barrier demo: drives an ARMED (`barrierPickups`) game through the real
## input path a human uses -- button C, the same bit the browser client's
## Space maps to -- and writes one zoomed PNG per state:
##   1-pickup 2-carried 3-placed 4-soaked 5-shredded 6-flattened
## Not part of the server. Run from the repo root.
import
  std/[os, strformat],
  pixie,
  ../src/ctf/[global, sim],
  ../tests/helpers,
  toolutil

const
  CropW = 150
  CropH = 150
  Zoom = 6

proc shot(sim: var SimServer, cx, cy: int, tag: string) =
  ## Renders the live board and writes a zoomed crop centered on map point
  ## (cx, cy). The spectator wire emits at RenderScale, and compositeBoard
  ## finds the map layer by matching that width -- so render at the DEFAULT
  ## scale and convert the crop into rendered space.
  var canvas = sim.renderBoardFrame()
  let
    w = CropW * RenderScale
    h = CropH * RenderScale
    x0 = clamp(cx * RenderScale - w div 2, 0, canvas.width - w)
    y0 = clamp(cy * RenderScale - h div 2, 0, canvas.height - h)
  var sub = canvas.subImage(x0, y0, w, h)
  var big = sub.resize(w * Zoom div RenderScale, h * Zoom div RenderScale)
  let path = &"/tmp/barr/demo-{tag}.png"
  big.writeFile(path)
  echo &"wrote {path}"

proc main() =
  chdirGameDir()
  # ARMED THROUGH CONFIG -- never a container ENV (the banked rule).
  var config = defaultGameConfig()
  config.update("""{"barrierPickups": 2}""")
  var sim = initCtfForTest(config)
  discard sim.addPlayer("red0")
  discard sim.addPlayer("blue0")
  sim.startGame()
  sim.players[0].team = Red
  sim.players[1].team = Blue
  sim.gameEventLoggingEnabled = true
  echo &"armed: barrierSpawns={sim.barrierSpawns.len} (per team 2)"
  doAssert sim.barrierSpawns.len == 4

  let none = sim.none()

  # --- 1. the folded sheet on its spawn, a cog walking onto it -------------
  let sp = sim.barrierSpawns[0]
  sim.placeStill(0, sp.x - CollisionW div 2 - 26, sp.y - CollisionH div 2)
  sim.step(none, none)
  sim.shot(sp.x, sp.y, "1-pickup")

  # --- 2. picked up by touch: the carry marker rides the cog ---------------
  sim.placeStill(0, sp.x - CollisionW div 2, sp.y - CollisionH div 2)
  sim.tryPickupBarriers(0)
  doAssert sim.players[0].hasBarrier, "touch pickup failed"
  doAssert not sim.barrierSpawns[0].present
  sim.step(none, none)
  sim.shot(sp.x, sp.y, "2-carried")

  # --- 3. press C (== the client's Space) -> a standing half-hex -----------
  # Open floor NEAR the kit spawn -- off the kit itself so the half-hex
  # silhouette reads alone in frame.
  let kitSpawn = sim.medKitSpawns[0]
  var kit = (x: kitSpawn.x, y: kitSpawn.y)
  for dy in [-70, 70, -110, 110]:
    let cy = kitSpawn.y + dy
    if sim.canOccupy(kitSpawn.x, cy) and sim.canOccupy(kitSpawn.x + 40, cy) and
        sim.canOccupy(kitSpawn.x - 40, cy) and sim.canOccupy(kitSpawn.x + 75, cy):
      kit = (x: kitSpawn.x, y: cy)
      break
  echo &"demo spot: ({kit.x},{kit.y})  kit at ({kitSpawn.x},{kitSpawn.y})"
  sim.placeStill(0, kit.x - CollisionW div 2, kit.y - CollisionH div 2)
  sim.players[0].aimBrads = 0              # aim EAST: flat side faces east
  var held = sim.none()
  held[0].c = true
  sim.step(held, sim.none())               # press edge
  sim.step(sim.none(), held)               # release
  doAssert sim.placedBarriers.len == 1, "C press did not place"
  doAssert not sim.players[0].hasBarrier
  let b = sim.placedBarriers[0]
  echo &"placed: center=({b.x},{b.y}) facing={b.facingBrads} hp={b.hp}"
  doAssert b.hp == BarrierHp
  # Blocking is real: paint is stopped, sight is NOT.
  doAssert not sim.paintPathClear(kit.x + 40, kit.y, kit.x, kit.y)
  doAssert sim.lineOfSightClear(kit.x + 40, kit.y, kit.x, kit.y)
  echo "verified: paint BLOCKED, sight CLEAR"
  # Step the placer clear so the half-hex reads unobstructed.
  sim.placeStill(0, kit.x - 60 - CollisionW div 2, kit.y - CollisionH div 2)
  sim.step(none, none)
  sim.shot(kit.x, kit.y, "3-placed")

  # --- 4. shots splat and chip it: 5 hits, 5 dents -------------------------
  # Shooter east of the flat side, firing WEST into the cardboard.
  sim.placeStill(1, kit.x + 70 - CollisionW div 2, kit.y - CollisionH div 2)
  sim.players[1].aimBrads = 128            # west
  for hit in 1 .. 5:
    sim.armToFire(1)
    sim.tryFire(1)
    doAssert sim.placedBarriers[0].hp == BarrierHp - hit,
      &"hit {hit}: hp={sim.placedBarriers[0].hp}"
  echo &"soaked 5: hp={sim.placedBarriers[0].hp}/{BarrierHp}"
  sim.step(none, none)
  sim.shot(kit.x, kit.y, "4-soaked")

  # --- 5. the tenth hit shreds it -----------------------------------------
  for hit in 6 .. BarrierHp:
    sim.armToFire(1)
    sim.tryFire(1)
  doAssert sim.placedBarriers.len == 0, "10 hits did not shred"
  echo "shredded at 10 hits"
  sim.step(none, none)
  sim.shot(kit.x, kit.y, "5-shredded")

  # --- 6. a cog drives through a fresh one and flattens it ----------------
  sim.players[0].hasBarrier = true
  sim.placeStill(0, kit.x - CollisionW div 2, kit.y - CollisionH div 2)
  sim.players[0].aimBrads = 0
  held = sim.none()
  held[0].c = true
  sim.step(held, sim.none())
  sim.step(sim.none(), held)
  doAssert sim.placedBarriers.len == 1, "replant failed"
  echo &"replanted: hp={sim.placedBarriers[0].hp}"
  sim.placeStill(0, kit.x - 60 - CollisionW div 2, kit.y - CollisionH div 2)
  sim.placeStill(1, kit.x + 70 - CollisionW div 2, kit.y - CollisionH div 2)
  sim.step(none, none)
  sim.shot(kit.x, kit.y, "6a-replanted")
  # The OTHER cog drives onto the flat side.
  sim.placeStill(1, kit.x + 21 - CollisionW div 2, kit.y - CollisionH div 2)
  sim.step(none, none)
  doAssert sim.placedBarriers.len == 0, "drive-through did not flatten"
  echo "flattened by drive-through"
  sim.shot(kit.x, kit.y, "6b-flattened")


main()
