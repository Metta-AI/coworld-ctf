## The >16-viewer sim wedge (`dedupObjectPlacements`, `global.nim`).
##
## Root cause: `bitworld/spriteprotocol`'s `readU16`/`readU32` openArray
## overloads call `toPacketString()`, which copies the ENTIRE packet into a
## fresh string on EVERY read. `dedupObjectPlacements` calls one of these per
## sprite-definition message it walks past, so a packet with many sprite defs
## makes the walk quadratic in packet size: one call over a real multi-
## megabyte player-init packet measured ~3.2 SECONDS (see global.nim's
## `packetU16` doc comment). The server pays this once per connected viewer
## every tick — fine at a handful of viewers, a multi-second single-frame
## wedge (during which NO socket receives a byte, including a fresh human
## takeover join) once enough are connected at once. `packetU16`/`packetU32`
## are zero-copy replacements for the same bytes.
##
## This is a WALL-CLOCK regression guard, not a golden hash: it fails loudly
## (many seconds instead of milliseconds) if the quadratic reads ever come
## back, without needing to actually open 17 websockets to prove it.
import std/[monotimes, times, unittest]
import bitworld/spriteprotocol
import ctf/global

const
  SpriteCount = 1000
    ## Sprite-definition messages in the synthetic packet. Each one costs the
    ## walker two length reads (`clen`, then `llen`); with the pre-fix
    ## `readU16`/`readU32` those reads are what go quadratic.
  SpriteWidth = 32
  SpriteHeight = 32
  WedgeBudgetMs = 1000
    ## Generous ceiling for the zero-copy walk: measured under 5 ms on this
    ## suite's hardware. The pre-fix (`readU16`/`readU32`) walk of the same
    ## packet measured several SECONDS — comfortably over this budget even
    ## accounting for slower CI hardware.

proc buildFrame(): seq[uint8] =
  ## One synthetic "player init"-shaped frame: SpriteCount sprite defs, each
  ## immediately followed by an object placement referencing it -- the same
  ## shape `buildSpriteProtocolPlayerInit` ships (definitions, then
  ## placements), just without needing a running sim to produce it.
  result = @[]
  var pixels = newSeq[uint8](SpriteWidth * SpriteHeight * 4)
  for i in 0 ..< pixels.len:
    pixels[i] = uint8(i mod 256)
  for i in 0 ..< SpriteCount:
    result.addSprite(i, SpriteWidth, SpriteHeight, pixels, "wedge-sprite " & $i)
    result.addObject(i, i, i, 0, 0, i)

suite "dedupObjectPlacements wedge":
  test "walking a many-sprite frame stays comfortably under budget":
    let frame = buildFrame()
    echo "synthetic frame bytes: ", frame.len
    var sentPlacements: seq[array[12, uint8]] = @[]
    let started = getMonoTime()
    let wire = dedupObjectPlacements(frame, sentPlacements)
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "dedupObjectPlacements elapsed ms: ", elapsed
    check elapsed < WedgeBudgetMs
    # Nothing was previously sent, so the first pass keeps every byte.
    check wire.len == frame.len

  test "a repeated identical frame drops every already-sent placement":
    ## Guards the ACTUAL dedup semantics, independent of the timing test
    ## above: a "fix" that made the walk fast by no longer comparing against
    ## `sentPlacements` (always passing everything through) would pass the
    ## budget test but silently stop deduping. Object messages (0x02, 12
    ## bytes each incl. the type byte) repeated byte-for-byte must vanish on
    ## the second pass; the interleaved sprite-definition bytes are NOT this
    ## proc's concern (an upstream cache dedupes those) and are kept as-is.
    let frame = buildFrame()
    var sentPlacements: seq[array[12, uint8]] = @[]
    discard dedupObjectPlacements(frame, sentPlacements)
    let secondPass = dedupObjectPlacements(frame, sentPlacements)
    let dropped = frame.len - secondPass.len
    echo "bytes dropped on repeat: ", dropped, " (expect >= ", SpriteCount * 12, ")"
    check dropped >= SpriteCount * 12
