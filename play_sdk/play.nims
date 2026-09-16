import std/os

let
  sdkDir = currentSourcePath().parentDir()
  wasiSdk = getEnv("WASI_SDK_PATH")

if wasiSdk.len == 0:
  quit("WASI_SDK_PATH must point at wasi-sdk 33.", 1)

switch("threads", "off")
switch("os", "standalone")
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
switch("passC", "-I" & sdkDir)
switch("passL", "-Wl,--no-entry")
switch("passL", "-nostdlib")
switch("passL", "-Wl,--export=play_alloc")
switch("passL", "-Wl,--export=play_manifest")
switch("passL", "-Wl,--export=play_init")
switch("passL", "-Wl,--export=play_step")
switch("passL", "-Wl,--export=play_retune")
switch("passL", "-Wl,--export-memory")
switch("passL", "-Wl,--max-memory=1048576")
