import std/os

let referenceDir = currentSourcePath().parentDir()

switch("path", referenceDir.parentDir() / "examples")

include "../play.nims"

switch("out", referenceDir.parentDir() / ".build" / "pact.wasm")
switch("nimcache", referenceDir.parentDir() / ".build" / "pact-nimcache")
