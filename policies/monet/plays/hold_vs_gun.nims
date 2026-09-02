import std/os

let playsDir = currentSourcePath().parentDir()

## MONET custom plays reuse the SDK's example dir on the path (panicoverride
## shim resolution, same as play_sdk/reference/*.nims).
switch("path", playsDir.parentDir().parentDir().parentDir() / "play_sdk" /
  "examples")

## Same ruling as the reference plays: the host Wasm sandbox is the security
## boundary; guest-side Nim bounds/overflow checks add fuel cost without
## protecting the engine.
switch("define", "danger")
include "../../../play_sdk/play.nims"

switch("out", playsDir / ".build" / "hold_vs_gun.wasm")
switch("nimcache", playsDir / ".build" / "hold_vs_gun-nimcache")
