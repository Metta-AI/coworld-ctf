#!/usr/bin/env bash
# The SIM SOURCES STAMP: one content hash over every Nim input the replay
# viewer's wasm sim is compiled from, plus nimby.lock (which pins bitworld,
# the codec+protocol layer under it). This is the machine-derived engine
# version underneath the hand-bumped GameVersion:
#
#   - tools/build_replay_viewer.sh computes it here and bakes it into the
#     wasm bundle (-d:ctfSimSourcesStamp, exported as
#     ctf_sim_sources_stamp_ptr/len).
#   - tools/qa_module_eval.cjs recomputes it at HEAD in CI and compares it
#     to the committed bundle's export — catching sim-behavior drift that
#     ships WITHOUT a GameVersion bump (the 2026-09-01 engine train), which
#     the GameVersion tripwire is blind to by design.
#   - Server builds may pass the same define so recordings carry the stamp
#     in their header configJson ("engineStamp"), letting the viewer tell a
#     same-build determinism break (loud banner) from expected cross-build
#     drift (quiet chip). See src/ctf/build_stamp.nim.
#
# Hashes the WORKING-TREE bytes of the files git tracks, so a dirty local
# build stamps what was actually compiled, while a clean CI checkout stamps
# exactly HEAD. Output: 64 hex chars on stdout, nothing else.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_dir}"

git ls-files -z -- 'src/*.nim' 'replay-viewer/*.nim' nimby.lock \
  | LC_ALL=C sort -z \
  | {
      while IFS= read -r -d '' file; do
        printf '%s\0' "${file}"
        cat "${file}"
        printf '\0'
      done
    } \
  | openssl dgst -sha256 -r \
  | cut -d' ' -f1
