import std/os

let playsDir = currentSourcePath().parentDir()

## Same recipe shape as hold_vs_gun.nims (see play_sdk/reference/*.nims).
switch("path", playsDir.parentDir().parentDir().parentDir() / "play_sdk" /
  "examples")
switch("define", "danger")
include "../../../play_sdk/play.nims"

switch("out", playsDir / ".build" / "fire_superiority.wasm")
switch("nimcache", playsDir / ".build" / "fire_superiority-nimcache")
