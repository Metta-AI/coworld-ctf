import std/os

let fixtureDir = currentSourcePath().parentDir()

include "../play.nims"

when defined(danger):
  switch("out", fixtureDir.parentDir() / ".build" / "view_floor_danger.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "view-floor-danger-nimcache")
else:
  switch("out", fixtureDir.parentDir() / ".build" / "view_floor.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "view-floor-nimcache")
