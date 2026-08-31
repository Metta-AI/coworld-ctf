# The baseline policy image.
#
# Both stages sit on nix-built bases that this repo defines (caos/nim and
# caos/player-runtime) and CI publishes. YOU DO NOT NEED NIX TO BUILD THIS —
# `docker build --platform=linux/amd64 -f players/baseline/Dockerfile .` pulls
# them like any other base. Only regenerating a base needs nix, which is rare
# and happens in CI on linux/amd64, never on a contributor's machine.
#
# WHY NIX BASES, when this used to be plain debian: nim bakes ABSOLUTE
# /nix/store paths into the binary — the RUNPATH for glibc and gcc-lib, and,
# because the nim `libcurl` package dlopens curl rather than linking it, an
# absolute path for libcurl.so.4. A binary built on one of these bases
# therefore only runs on a runtime image built from THE SAME nixpkgs pin, which
# caos/nim and caos/player-runtime share. In exchange:
#
#   - `caos-cli run-tool build-player` produces a binary that is linked exactly
#     like the one this file builds, so it CAN be dropped into the runtime
#     stage as-is. Nothing here does that — this file is the standalone path,
#     and it compiles from source. Assembling the image around a caos-built
#     binary is the `build-image` tool's job.
#   - the image is 69 MB rather than 93 MB, and all of it is used — the old
#     debian base was 78 MB to carry a 1 MB policy.
#   - the runtime stage has no compiler, no apt and no shell.
#
# A pin mismatch dies LOUDLY at startup ("could not load: libcurl.so(|.4)"),
# before the websocket, because nim's dynlib load runs at module init. It
# cannot degrade into a policy that runs while silently dropping telemetry.
#
# The two ARGs below let a local build point at locally-built bases:
#   docker build --build-arg NIM_IMAGE=ctf-nim:latest \
#                --build-arg RUNTIME_IMAGE=coworld-ctf-runtime:latest ...
# The tag IS the nixpkgs pin both bases were built from. Bumping it is a
# deliberate two-line edit, and the two lines must move together — that is the
# whole coupling, made visible instead of implicit.
ARG NIM_IMAGE=ghcr.io/metta-ai/coworld-ctf-nim:b47ad65d
ARG RUNTIME_IMAGE=ghcr.io/metta-ai/coworld-ctf-runtime:b47ad65d

FROM ${NIM_IMAGE} AS build
# nimby writes its global package tree under $HOME; the image has no home dir.
ENV HOME=/tmp
WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock
COPY . .
ARG NIM_DEFINES=""
# buildDefines feeds artlog meta.json: the full define set this build was
# TOLD to compile with (records intent, not that guarded code exists).
#
# A FROM-SCRATCH COMPILE, deliberately, and NOT routed through the image's
# /ccache-bin/gcc shadow. A build stage's filesystem is discarded, so ccache
# here would be a cold local cache on every build: a fork per compile buying
# nothing, while reading as though the build were cached. The caos redis cache
# is not reachable from `docker build` either. An unobservable cache is one you
# cannot trust (see caos-tools/lib/common.sh, setup_ccache) — so rather than
# ship a cache nobody can see, this path is honestly slow, and the fast path is
# `run-tool build-player`, which reports its hit rate on every run.
RUN nim c \
  -d:release $NIM_DEFINES \
  -d:useMalloc \
  -d:buildDefines="-d:release $NIM_DEFINES -d:useMalloc" \
  --opt:speed \
  --stackTrace:on \
  --nimcache:/tmp/ctf-nimcache \
  --out:baseline \
  players/baseline/baseline.nim

FROM ${RUNTIME_IMAGE}
COPY --from=build /workspace/ctf/baseline /bin/baseline
CMD ["/bin/baseline"]
