## FOUR DIGITS lane (W1), one-off: dumps the exact `mapSpec` JSON object
## recorded in a real hosted replay's own config header, byte-exact.
##
## `replays.loadReplay`/`parseReplayBytes` refuse this: our checked-out
## source's `ReplayCompatibleGameVersions = ["52"]` (src/ctf/sim_types.nim)
## is stale against the platform's current GV63 (every engine bump breaks
## the decoder, per house doctrine) -- but the header FRAME this tool needs
## (magic, u16 formatVersion, gameName string, gameVersion string, u64,
## configJson string; src/ctf/replay_codec.nim readHeader ~465-489) has not
## itself changed shape across that span, only the gameVersion STRING value
## the strict decoder gates on. This tool re-reads that same fixed prefix
## by hand (byte-for-byte identical field order to readHeader) and
## DELIBERATELY skips the version-compatibility assertion, since it only
## ever touches the header's configJson string, never simulates a tick.
## Not wired into any harness; scratch tool for pulling one EVAL_MAPSPEC
## from an r5721-r5733 replay per plan-4digits.md's lever-2 instrument.
##
## Usage: nim r --hints:off tools/w1_dump_replay_mapspec.nim <replay-path> <out.json>
import std/[json, os, strformat]
import ../src/ctf/replays  # for CtfReplayMagic/CtfReplaySpec.gameName only

proc readU16(bytes: string, offset: var int): uint16 =
  result = uint16(bytes[offset].uint8) or (uint16(bytes[offset + 1].uint8) shl 8)
  offset += 2

proc readReplayString(bytes: string, offset: var int): string =
  let length = int(bytes.readU16(offset))
  result = bytes[offset ..< offset + length]
  offset += length

let path = paramStr(1)
let outPath = paramStr(2)
let bytes = readFile(path)
var offset = 0
doAssert bytes[0 ..< CtfReplayMagic.len] == CtfReplayMagic, "bad magic"
offset = CtfReplayMagic.len
let formatVersion = bytes.readU16(offset)
doAssert formatVersion in [1'u16, 2'u16], "unsupported format version"
let gameName = bytes.readReplayString(offset)
doAssert gameName == CtfReplaySpec.gameName, "game name mismatch"
let gameVersion = bytes.readReplayString(offset)
offset += 8  # discard u64 (recorded-tick-count / openedAtMs per readHeader)
let configJson = bytes.readReplayString(offset)

stderr.writeLine &"replay gameVersion={gameVersion} (our source only " &
  "resimulates GV52 -- this tool never resimulates, header-only read)"
let config = parseJson(configJson)
if not config.hasKey("mapSpec"):
  stderr.writeLine "no mapSpec key in this replay's configJson"
  quit 1
writeFile(outPath, $config["mapSpec"])
stderr.writeLine "wrote " & outPath & " (mapSpec.name=" &
  config["mapSpec"]{"name"}.getStr("?") & ")"
