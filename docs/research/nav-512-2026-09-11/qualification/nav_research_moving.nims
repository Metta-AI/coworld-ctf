import std/os

let
  qualificationDir = currentSourcePath().parentDir()
  repoRoot = qualificationDir.parentDir().parentDir().parentDir().parentDir()
  playSdkDir = repoRoot / "play_sdk"

switch("path", playSdkDir / "examples")

## Same guest build shape as the reference plays: the host sandbox is the
## security boundary, guest-side checks only cost fuel.
switch("define", "danger")
include "../../../../play_sdk/play.nims"

switch("out", qualificationDir / ".build" / "nav_research_moving.wasm")
switch("nimcache", qualificationDir / ".build" / "nav-research-moving-nimcache")
