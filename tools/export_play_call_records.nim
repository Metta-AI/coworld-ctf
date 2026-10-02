## Export the hash-verified Season 2 play calls from a private local replay.
## Usage: nim r tools/export_play_call_records.nim /path/to/replay.bitreplay

import std/[json, os]
import ../src/ctf/replays
import ../src/shell/replay_records

when isMainModule:
  if paramCount() != 1:
    quit("usage: export_play_call_records <replay.bitreplay>", 1)
  let replayBytes = readFile(paramStr(1))
  let data = parseCtfReplayBytesFull(replayBytes)
  if not data.shell.manifestVerified:
    quit("Season 2 replay manifest did not verify", 1)
  var calls = newJArray()
  for call in data.shell.calls:
    var entries = newJArray()
    for entry in call.entries:
      var code: JsonNode
      case entry.code.kind
      of cikModule:
        code = %*{"kind": "module", "sha256": entry.code.moduleSha256}
      of cikNative:
        code = %*{"kind": "native", "name": entry.code.nativeName,
                   "game_version": entry.code.nativeGameVersion}
      entries.add(%*{"entry_id": entry.entryId, "code": code})
    calls.add(%*{
      "replay_time_ms": call.replayTimeMs,
      "seat": call.seat,
      "call_number": call.callNumber,
      "ladder_json": call.ladderBytes,
      "record_sha256": call.contentSha256,
      "entries": entries,
    })
  echo $(%*{"game_version": data.replay.gameVersion,
            "replay_sha256": sha256Hex(replayBytes),
            "manifest_verified": true, "calls": calls})
