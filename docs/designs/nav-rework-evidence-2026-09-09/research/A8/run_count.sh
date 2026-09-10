#!/usr/bin/env bash
set -euo pipefail
cd /Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-early-visited
r=/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research/docs/designs/nav-rework-evidence-2026-09-09/research/A8
test -z "$(git status --porcelain -- src/shell/body_route_index.nim)"
test ! -e tools/check_pixel_recurrence.nim
cmp src/shell/body_route_index.nim "$r/snapshots/parent-body_route_index.nim"
trap 'cp "$r/snapshots/parent-body_route_index.nim" src/shell/body_route_index.nim; rm -f tools/check_pixel_recurrence.nim' EXIT
mkdir -p "$r/local-mac"
cp "$r/snapshots/count-body_route_index.nim" src/shell/body_route_index.nim
cp "$r/check_pixel_recurrence.nim" tools/
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
nim --version > "$r/local-mac/nim-version.txt"
shasum -a 256 src/shell/body_route_index.nim tools/check_pixel_recurrence.nim > "$r/local-mac/source-hashes.txt"
nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on --opt:speed --stackTrace:on --path:src/shell --nimcache:"$r/local-mac/cache" -o:"$r/local-mac/bench" tools/check_pixel_recurrence.nim > "$r/local-mac/build.log" 2>&1
"$r/local-mac/bench" > "$r/local-mac/counts.json" 2> "$r/local-mac/run.stderr"
printf 'A8 COUNTS DONE\n' > "$r/local-mac/DONE"
