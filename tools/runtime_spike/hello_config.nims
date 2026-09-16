import std/os

let
  spikeDir = currentSourcePath().parentDir()
  wasiSdk = getEnv("WASI_SDK_PATH")

if wasiSdk.len == 0:
  quit("WASI_SDK_PATH must point at wasi-sdk 33.", 1)

switch("nimcache", spikeDir / ".build" / "hello-nimcache")
switch("threads", "off")
switch("os", "linux")
switch("cpu", "wasm32")
switch("cc", "clang")
switch("clang.exe", wasiSdk / "bin" / "clang")
switch("clang.linkerexe", wasiSdk / "bin" / "clang")
switch("clang.cpp.exe", wasiSdk / "bin" / "clang++")
switch("clang.cpp.linkerexe", wasiSdk / "bin" / "clang++")
switch("mm", "arc")
switch("exceptions", "goto")
switch("define", "noSignalHandler")
switch("define", "release")
switch("define", "useMalloc")
switch("noMain", "on")
switch("passC", "-I" & spikeDir)
switch("passL", "-mexec-model=reactor")
switch("passL", "-Wl,--export=play_alloc")
switch("passL", "-Wl,--export=play_init")
switch("passL", "-Wl,--export=play_step")
switch("passL", "-Wl,--export-memory")
switch("passL", "-Wl,--max-memory=1048576")
switch("out", spikeDir / ".build" / "hello_play.wasm")
