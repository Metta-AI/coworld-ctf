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

Current build: GV22, source 3da0c06e111b2b688fc521051e9116ae11b17a76.
