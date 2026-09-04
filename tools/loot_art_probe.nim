## Renders the three LOOT(s2) ground-art additions (item-completeness epic
## 1ef4f9d6, T2: bandage/gun-crate/hopper-crate) to PNGs without a server or
## a replay -- same probe pattern as tools/spray_probe.nim: pose the sim by
## hand (three pickups placed directly, bypassing the brMode/lootStart config
## fence the same way tests/test_perception_loadout_sdk.nim does for the SDK
## perception half of this feature), build REAL global sprite packets via
## buildSpriteProtocolUpdates, composite the map layer, and crop each pickup.
## Also PRINTS the emitted sprite labels, so the wire contract is verified in
## the same run as the pixels.
##
## Usage (from the repo root): nim r tools/loot_art_probe.nim [outDir]
import
  std/[os, strutils, tables],
  pixie,
  ../src/ctf/[global, sim],
  toolutil

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "/tmp"
  chdirGameDir()

  var sim = initSimServer(defaultGameConfig())
  sim.gameEventLoggingEnabled = false
  let
    red = sim.addPlayer("red0")
    blue = sim.addPlayer("blue0")
  sim.startGame()
  sim.players[red].team = Red
  sim.players[blue].team = Blue

  proc placeAt(index, x, y: int) =
    sim.players[index].x = x - CollisionW div 2
    sim.players[index].y = y - CollisionH div 2

  # Open floor, far from both players so the crates render undisturbed and
  # unpicked-up.
  let midY = MapHeight div 2
  placeAt(red, 300, midY - 200)
  placeAt(blue, 300, midY + 200)

  # Three pickups placed directly (the same shortcut
  # tests/test_perception_loadout_sdk.nim uses for the SDK-perception half of
  # this feature): this proves the RENDER path independent of the
  # lootStart/bandagePickups config gate and the crate-placement mechanism
  # (T3's territory, not this probe's).
  let
    bandageXY = (x: 500, y: midY - 60)
    gunXY = (x: 700, y: midY - 60)
    hopperXY = (x: 900, y: midY - 60)
  sim.bandageSpawns = @[PickupSpawn(x: bandageXY.x, y: bandageXY.y, present: true)]
  sim.weaponSpawns = @[PickupSpawn(x: gunXY.x, y: gunXY.y, present: true)]
  sim.hopperSpawns = @[PickupSpawn(x: hopperXY.x, y: hopperXY.y, present: true)]

  var
    state = initGlobalViewerState()
    next: GlobalViewerState
    world = initSpriteWorld()

  proc renderBoard(): Image =
    world.apply(sim.buildSpriteProtocolUpdates(state, next).parseSpritePacket())
    state = next
    world.renderBoard()

  proc cropOf(board: Image, cx, cy, w, h: int): Image =
    let
      x0 = clamp(cx * RenderScale - w div 2, 0, MapWidth * RenderScale - w)
      y0 = clamp(cy * RenderScale - h div 2, 0, MapHeight * RenderScale - h)
    board.subImage(x0, y0, w, h)

  let board = renderBoard()
  cropOf(board, bandageXY.x, bandageXY.y, 80, 80)
    .resize(80 * 3, 80 * 3).writeFile(outDir / "loot-art-bandage.png")
  cropOf(board, gunXY.x, gunXY.y, 90, 90)
    .resize(90 * 3, 90 * 3).writeFile(outDir / "loot-art-gun-crate.png")
  cropOf(board, hopperXY.x, hopperXY.y, 90, 90)
    .resize(90 * 3, 90 * 3).writeFile(outDir / "loot-art-hopper-crate.png")
  # One wide shot with all three in frame, for a single at-a-glance proof.
  cropOf(board, 700, midY - 60, 620, 160)
    .resize(620 * 2, 160 * 2).writeFile(outDir / "loot-art-all-three.png")

  echo "wrote loot-art-bandage.png, loot-art-gun-crate.png, ",
    "loot-art-hopper-crate.png, loot-art-all-three.png to ", outDir

  echo "--- loot-art sprite labels on the wire ---"
  for id, label in world.labels:
    if "bandage" in label or "gun crate" in label or "hopper crate" in label:
      echo "  sprite ", id, "  \"", label, "\""

main()
