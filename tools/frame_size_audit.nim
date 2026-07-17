import std/[algorithm, os, json, strformat], supersnappy, bitworld/spriteprotocol,
  ../src/ctf/[sim, global, broadcast]

# Reproduces the hosted first WS frame and reports whether ANY single frame
# exceeds the hosted 1 MiB WebSocket limit (a frame over 1048576 bytes makes the
# viewer close with 1009 → "produced no frame" → the replay never loads).
#
# The board packet (map sprite + sprite atlas) rides the binary channel; the
# broadcast chrome (JSON w/ the full lives-lead series on frame 1) is smuggled as
# sprite BroadcastChromeSpriteId's label. This audit measures the board packet,
# the chrome packet, and their sum so we can see the split vs the 1 MiB cap.

const WsLimit = 1048576

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

const ChunkCap = 900_000  ## must match MaxWsFrameBytes in server.nim

proc report(tag: string, boardPacket: seq[uint8], chrome: string) =
  # Assemble the real outbound packet exactly as the server does (board + chrome
  # smuggled as sprite 4090's label), then chunk it the way the WS send does.
  var outPacket = boardPacket
  outPacket.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], chrome)
  let chunks = chunkSpritePacket(outPacket, ChunkCap)
  var maxChunk = 0
  for c in chunks:
    if c.len > maxChunk: maxChunk = c.len
  # Reassemble to prove chunking preserves every byte (no message cut).
  var rejoined: seq[uint8]
  for c in chunks: rejoined.add(c)
  echo "== ", tag, " =="
  echo &"  full packet:    {outPacket.len:>9} bytes  (label {chrome.len} chars)"
  echo &"  ws chunks:      {chunks.len:>9}  largest {maxChunk} bytes  " &
    (if maxChunk > WsLimit: "OVER 1MiB ✗" else: "ok, under cap")
  echo &"  lossless:       {(if rejoined == outPacket: \"chunks rejoin byte-identical ✓\" else: \"MISMATCH ✗\")}"

# --- Frame 1: cold start, both hearts home (map + atlas), full lead series ---
var state = initGlobalViewerState()
var next: GlobalViewerState
let firstPacket = game.buildSpriteProtocolUpdates(
  state, next, replayTick = 0, replayEnabled = true, replayMaxTick = 2432)
# Simulate a long-match lead series (change point per tick worst case).
var lead: seq[array[2, int]]
for t in 0 ..< 2432:
  lead.add([t, (t mod 7) - 3])
let firstChrome = game.buildStateJson(newJArray(), true, 1, 2432, false, true, -1,
  -1, lead, 0)
report("FRAME 1 (map + atlas + full lead series)", firstPacket, firstChrome)

# --- Per-sprite breakdown of the board packet (largest first) ---
var sizes: seq[(int, int, string)]
var total = 0
for message in parseSpritePacket(firstPacket):
  if message.kind == spkSprite:
    let s = message.sprite
    let bytes = blobFromBytes(s.compressedPixels).len
    total += bytes
    sizes.add((bytes, s.id, s.label))
sizes.sort()
sizes.reverse()
echo "-- board sprite payload: ", total, " across ", sizes.len, " sprites --"
for i in 0 ..< min(sizes.len, 12):
  let (bytes, id, label) = sizes[i]
  echo &"  {bytes:>9}\t#{id}\t{label}"

# --- A later frame with a glow strip active (heart taken) ---
game.flags[Red].carrier = 0
state = next
for _ in 0 ..< (GlowFadeStages + 2):
  next = state
  let p = game.buildSpriteProtocolUpdates(
    state, next, replayTick = 100, replayEnabled = true, replayMaxTick = 2432)
  state = next
let glowChrome = game.buildStateJson(newJArray(), true, 1, 2432, false, true, -1, -1, @[], 0)
# rebuild one more so the strip pixels are in-packet at full stage
next = state
let glowPacket = game.buildSpriteProtocolUpdates(
  state, next, replayTick = 100, replayEnabled = true, replayMaxTick = 2432)
report("GLOW-ACTIVE FRAME (Red heart taken, no map re-send)", glowPacket, glowChrome)
