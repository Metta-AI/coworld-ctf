## Puts the repo's `src/` on the search path so this bot can import the SHARED
## sprite-label vocabulary (`ctf/labels`) that the engine emits against —
## mirrors `players/baseline/config.nims` exactly (same nesting depth: this
## file lives at players/onepage/config.nims, three parentDir() calls up is
## the repo root).
##
## ALSO puts `players/baseline/baseline/` on the path so this bot can import
## `protocols` (the wire-decode layer: ProtocolClient, spriteObjectsWithLabel,
## applyFrame, ...) WITHOUT duplicating it. That module is generic protocol
## plumbing, not CTF-specific tactics — see onepage.nim's header comment for
## the reuse boundary (protocols.nim: reused as-is; the tactics tree above it
## in baseline.nim: NOT reused, replaced by the intent resolver here).
import std/os

let repoRoot = currentSourcePath().parentDir().parentDir().parentDir()
switch("path", repoRoot / "src")
switch("path", repoRoot / "players" / "baseline" / "baseline")
