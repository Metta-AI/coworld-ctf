import std/os

let exampleDir = currentSourcePath().parentDir()

include "../play.nims"

switch("nimcache", exampleDir.parentDir() / ".build" / "hello-nimcache")
switch("out", exampleDir.parentDir() / ".build" / "hello_play.wasm")
