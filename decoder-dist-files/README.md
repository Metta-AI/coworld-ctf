# decoder-dist — prebuilt static replay decoder binaries

Orphan branch holding static linux x86-64 builds of `tools/expand_replay.nim`,
so agent sandboxes can decode replays without installing the nim toolchain.

- Built with nim 2.2.4 + `nimby.lock` deps, `-d:release --opt:speed --passL:-static`.
- The binary bakes `GameDir = /workspace/coworld-ctf` at compile time and needs a
  repo checkout at that path at runtime (map assets).
- Each build is announced as a GitHub release `decoder-gv<GameVersion>-<shortsha>`;
  this branch exists because sandbox tokens cannot upload release assets
  (uploads.github.com), while the `build-decoder.yml` CI workflow (dispatched on
  merge to main) publishes proper release assets.
- Consumers: `cogames/ctf/team/bin/fetch-decoder.sh` in daveey/cogamer, pinned to
  an immutable commit sha of this branch via raw.githubusercontent.com.

Current build: GV23, source 493793bc8cdf94aeadddcb44c6e4ee9d2f982c96 (includes PR #130
spray-can label renames; replay-compatible with GV23 replays recorded at 11c1317).
Historical GV22 build: pinned at branch commit 96951473b858672698d3da96ac5f95580ae0acc1
(source 3da0c06e111b2b688fc521051e9116ae11b17a76) — fetch that commit's raw URL to
decode the GV22 replay corpus.
