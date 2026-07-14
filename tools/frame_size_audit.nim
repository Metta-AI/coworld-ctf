import std/[algorithm, os, tables], supersnappy, bitworld/spriteprotocol,
  ../src/ctf/[sim, global]

# Builds the global init + first update for a full 16-player game and prints
# each sprite's compressed wire size, largest first.

setCurrentDir(currentSourcePath().parentDir().parentDir())
var config = defaultGameConfig()
var game = initSimServer(config)
game.gameEventLoggingEnabled = false
for i in 0 ..< 16:
  discard game.addPlayer("player" & $(i + 1))
game.startGame()
var noInput = newSeq[InputState](game.players.len)
for _ in 0 ..< 30:
  game.step(noInput, noInput)

var state = initGlobalViewerState()
var next: GlobalViewerState
let packet = game.buildSpriteProtocolUpdates(state, next)

var sizes: seq[(int, int, string)]  # bytes, spriteId, label
var total = 0
for message in parseSpritePacket(packet):
  if message.kind == spkSprite:
    let s = message.sprite
    let bytes = blobFromBytes(s.compressedPixels).len
    total += bytes
    sizes.add((bytes, s.id, s.label))
sizes.sort()
sizes.reverse()
echo "packet bytes: ", packet.len, "  sprite payload: ", total
for i in 0 ..< min(sizes.len, 25):
  let (bytes, id, label) = sizes[i]
  echo bytes, "\t", id, "\t", label
