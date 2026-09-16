import std/os

let fixtureDir = currentSourcePath().parentDir()

include "../play.nims"

when defined(danger):
  switch("out", fixtureDir.parentDir() / ".build" / "view_meter_danger.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "view-meter-danger-nimcache")
else:
  switch("out", fixtureDir.parentDir() / ".build" / "view_meter.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "view-meter-nimcache")
