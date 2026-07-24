import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead, which is how the
# use-after-free fixed in ctf_replay.nim (emscripten_exit_with_live_runtime)
# was found. Keep this so any future stale free crashes at the fault instead
# of corrupting replay playback at a distance.
--define:useMalloc

switch(
  "passL",
  (&"""
  -o {distDir / "ctf_replay.js"}
  --preload-file {rootDir / "data"}@data
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s FILESYSTEM=1
  -s ENVIRONMENT=web
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_ctf_load_replay,_ctf_frame,_ctf_input,_ctf_packet_ptr,_ctf_packet_len,_ctf_mismatch_tick,_ctf_error_ptr,_ctf_error_len
  """).replace("\n", " ")
)
