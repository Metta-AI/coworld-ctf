# caos/emsdk — the wasm toolchain worker base

The replay viewer ships as **wasm32**, and that is a different toolchain from
everything else here: `nim c -d:emscripten` drives `emcc`, and the bundle the
observatory serves has to be the bundle CI built. So this base is the upstream
`emscripten/emsdk` image, pinned by digest in [`base`](base) — **not** a nix
rebuild of emscripten.

That is deliberate, and it is the one place this repo does not reach for nix.
`caos/nim` and `caos/player-runtime` are nix flakes because their whole job is
to make a nim binary's absolute `/nix/store` RUNPATH resolvable at run time.
Nothing here runs at run time: the output is architecture-neutral wasm plus
some JavaScript. What matters instead is that `emcc` is the *same* `emcc` — a
nixpkgs emscripten at some other patch level would be a different compiler, and
the wasm32 bugs this pipeline exists to catch (`int` is 32 bits, the address
space ends at 2 GB — twice shipped to prod, PR #189) are exactly the class that
a compiler change moves around.

Unlike `caos/nim`, this directory is **not** an image on its own: it is `base`
plus the [`worker`](worker) trampoline, and `caos-tools/build-viewer` assembles
the two into a git-docker delta at job time — reading the upstream config with
skopeo rather than committing a copy of it that could drift from the digest
above.

**This base is amd64-only.** Upstream publishes a single manifest, not a list,
so an arm64 caos stack runs it under emulation (works, slowly) and an amd64
stack runs it natively. The output does not vary with the host either way; wasm
is wasm.
