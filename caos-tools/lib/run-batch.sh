#!/usr/bin/env bash
# One module's tests, as a caos job. Curried by test.sh's fanout stage and run
# once per module (the `map` of a map-then), so 58 of these run in parallel.
#
# Args:
#   tests  the test binary  — curried into the MAPPER, so all 58 jobs name the
#          same blob by the same hash and it is stored once
#   in     THIS module's child: { names, salt? }
#
# Result: { output, status, ms }. A failing test is a VALUE — if it were a job
# error, one red test would abort the fan-out and lose the other 57 results.
set -euo pipefail

caos get -r /cas/args/tests
caos get -r /cas/args/in
caos get -r /cas/args/ws

# THE BINARY NEEDS THE TREE AT ITS COMPILE-TIME PATH. Nim bakes
# currentSourcePath, so tests resolve fixtures against the directory they were
# compiled in (/tmp/build/src, fixed by the compile stage for ccache's sake).
# Without this they die with `No such file or directory /tmp/build/src`, at RUN
# time, having compiled and linked perfectly.
#
# A symlink, not a copy: the tree is already materialized under /cas and this
# runs 58 times.
mkdir -p /tmp/build
ln -sfn /cas/args/ws /tmp/build/src

# /cas is root-owned and this worker is unprivileged, so the binary has to be
# copied out before it can be executed.
install -m 755 /cas/args/tests /tmp/tests

# Nim's unittest takes EXACT test names as argv (no globs — verified), and
# accepts many at once. They go in as argv elements and are never
# shell-interpolated: plenty contain spaces and apostrophes.
mapfile -t names < /cas/args/in/names

R=/tmp/r; rm -rf "$R"; mkdir -p "$R"
start=$(date +%s%N)
set +e
# From the tree root, per AGENTS.md ("assets resolve via data/").
# tests/helpers.nim chdirs to GameDir only inside certain helpers, so a module
# whose tests never call one keeps the process cwd — which is / in a container,
# where readImage("data/heart_red.png") becomes /data/heart_red.png and dies.
( cd /tmp/build/src && /tmp/tests "${names[@]}" ) > "$R/output" 2>&1
status=$?
set -e
echo $(( ($(date +%s%N) - start) / 1000000 )) > "$R/ms"
echo "$status" > "$R/status"

caos put "$R" /cas/out
