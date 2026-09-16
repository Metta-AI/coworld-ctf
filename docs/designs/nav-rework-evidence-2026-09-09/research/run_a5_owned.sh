#!/usr/bin/env bash
set -euo pipefail
if [ -n "${A5_WAIT_PID:-}" ]; then
 while kill -0 "$A5_WAIT_PID" 2>/dev/null; do sleep 5; done
 test -f "$HOME/nav-throughput-results-20260909/C2/DONE"
fi
cd "$HOME/coworld-nav-wavefront-20260909"
test -z "$(git status --porcelain)"
backup="$HOME/a5-input/original"
test ! -e "$backup"
mkdir -p "$backup"
cp src/shell/body_route_index.nim "$backup/body_route_index.nim"
cp tools/profile_body_route_index.nim "$backup/profile_body_route_index.nim"
trap 'cp "$backup/body_route_index.nim" src/shell/body_route_index.nim; cp "$backup/profile_body_route_index.nim" tools/profile_body_route_index.nim' EXIT
cp "$HOME/a5-input/body_route_index.nim" src/shell/body_route_index.nim
cp "$HOME/a5-input/profile_body_route_index.nim" tools/profile_body_route_index.nim
export A5_TREE="$PWD"
bash "$HOME/a5-input/run_a5_profile.sh"
