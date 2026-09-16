import std/os

let fixtureDir = currentSourcePath().parentDir()

include "../play.nims"

when defined(contextFullDecode):
  switch("out", fixtureDir.parentDir() / ".build" / "context_meter_full.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "context-meter-full-nimcache")
else:
  switch("out", fixtureDir.parentDir() / ".build" / "context_meter_raw.wasm")
  switch("nimcache", fixtureDir.parentDir() / ".build" / "context-meter-raw-nimcache")
