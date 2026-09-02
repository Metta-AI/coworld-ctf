#!/usr/bin/env bash
# Build the LIVE Paintbot league champion (paintbot-focusfire:v26) for the
# termination battery, on this machine's nim toolchain.
#
# Source: the fork in the PRIVATE daveey-cogamer repo, games/paintbot/policies/
# paintbot-focusfire (player tree 825f2a74b8ea = the tree v26 shipped from).
# It is copied into exp/champion/ (gitignored: coworld-ctf is public and the
# champion source is private by design, see the fork's README) so that the
# repo-root nim.cfg supplies the package paths; the fork's own nim.cfg points
# at /root/.nimby and is not copied.
#
# Defines: the fork's DEFINES file (47, the v25 seed) minus -d:gv36SlotHunt,
# the token subtraction that shipped v26 (DEPLOYS.md DONE 2026-08-06T12:3xZ,
# champion.json pvid 7690b9b9). 46 defines.
#
# Compile line mirrors the fork's Dockerfile verbatim except paths.
set -euo pipefail
cd "$(dirname "$0")/.."
FORK="${COGAMER:-$HOME/code/daveey-cogamer}/games/paintbot/policies/paintbot-focusfire"
rm -rf exp/champion && mkdir -p exp/champion
cp "$FORK/baseline.nim" exp/champion/
cp -R "$FORK/baseline" exp/champion/
grep -v '^#' "$FORK/DEFINES" | sed 's/ -d:gv36SlotHunt//' > exp/champion/DEFINES.v26-live
DEFS="$(cat exp/champion/DEFINES.v26-live)"
test "$(echo "$DEFS" | tr ' ' '\n' | grep -c '^-d:')" -eq 46
# shellcheck disable=SC2086
nim c -d:release $DEFS -d:useMalloc --opt:speed --stackTrace:on \
  --nimcache:"${NIMCACHE:-/tmp/champ46-nimcache}" \
  --out:"$PWD/exp/champ46.out" exp/champion/baseline.nim
