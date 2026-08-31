import std/os

let fixtureDir = currentSourcePath().parentDir()

include "../play.nims"

switch("out", fixtureDir.parentDir() / ".build" / "view_probe.wasm")
switch("nimcache", fixtureDir.parentDir() / ".build" / "view-probe-nimcache")
