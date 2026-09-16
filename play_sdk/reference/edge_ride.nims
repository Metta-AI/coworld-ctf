import std/os

let referenceDir = currentSourcePath().parentDir()

switch("path", referenceDir.parentDir() / "examples")

## Reference plays are author examples as well as tests. The host Wasm sandbox
## is the security boundary; guest-side Nim bounds/overflow checks add fuel cost
## without protecting the engine.
switch("define", "danger")
include "../play.nims"

switch("out", referenceDir.parentDir() / ".build" / "edge_ride.wasm")
switch("nimcache", referenceDir.parentDir() / ".build" / "edge-ride-nimcache")
