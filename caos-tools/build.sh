#!/usr/bin/env bash
#@doc Compile the game server (src/ctf.nim) inside caos and return its
#@doc diagnostics. The Nim deps come from a cached `deps` job keyed on
#@doc nimby.lock, and the C compilation is ccache-backed, so an unchanged
#@doc build never runs and a one-file edit recompiles one file. Nothing is
#@doc handed in from the host: the tree is compiled from source, in workers.
#@arg [salt] Force a rebuild — any fresh value (e.g. $(date --iso=s)) re-keys this build and nothing else.
#
# TWO STAGES, one script, selected by a curried --stage (caos's convention).
# Each stage ends where it must delegate rather than block: a worker describes
# its continuation and exits (design/map-then.md).
#
#   narrow   (default) narrow the tree, curry the deps job, run-then it
#   compile  the `then`: --result is the deps tree, so nim can be pointed at it
#
# The server build and the test build share NO artifact — Nim's codegen is
# whole-program, so ctf/sim.nim compiled into the server is different C from
# the same module compiled into the test binary (measured: 681,959 vs 691,954
# bytes). So this tool never waits on `test`, and vice versa.
set -euo pipefail

fail() { echo "BUILD FAIL: $*" >&2; exit 1; }

stage=narrow
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

narrow)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  # -r: we SOURCE common.sh, so we need its bytes, not a placeholder.
  caos get -r /cas/args/in/caos-tools/lib
  # shellcheck source=lib/common.sh
  source /cas/args/in/caos-tools/lib/common.sh

  # What the SERVER build reads. client/ is not optional: src/ctf/server.nim
  # staticReads client/replay_broadcast.html, chrome_common.js,
  # broadcast_core.js and league_replayer.html.
  narrow_tree /cas/ws src client data config.json

  # The deps job takes nimby.lock as its WHOLE input, so it stays a cache hit
  # across every source edit.
  deps=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/in/caos-tools/lib/deps.sh") || fail "currying deps"

  fwd=("--worker1:@=/cas/args/worker1" --stage=compile "--ws:@=/cas/ws"
       "--lib:@=/cas/args/in/caos-tools/lib/common.sh")
  if [ -e /cas/args/salt ]; then fwd+=("--salt:@=/cas/args/salt"); fi
  next=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying compile"

  caos run-then /cas/args/in/nimby.lock --run:hash="$deps" --then:hash="$next"
  ;;

compile)
  # --result is the deps tree; --ws the narrowed source tree.
  # Phase timings into the report. The worker's wall clock is dominated by
  # things that are invisible from outside it — materializing the deps tree is
  # not obviously cheaper than the compile — so measure rather than guess.
  T0=$(date +%s%N); ph() { echo "  $1: $(( ($(date +%s%N) - T0)/1000000 ))ms"; T0=$(date +%s%N); }
  : > /tmp/phases
  caos get -r /cas/args/result
  ph "fetch deps" >> /tmp/phases
  caos get -r /cas/args/ws
  ph "fetch ws" >> /tmp/phases
  caos get -r /cas/args/lib
  # Curried as its own arg rather than narrowed into the tree: the source tree
  # should not re-key on an edit to a tool script.
  source /cas/args/lib

  deps_flags /cas/args/result
  setup_ccache

  # Compile at a FIXED path so ccache hits: the generated C embeds absolute
  # paths, and a workspace that moves misses everything.
  rm -rf /tmp/build/src; mkdir -p /tmp/build
  cp -RL /cas/args/ws/. /tmp/build/src/
  cd /tmp/build/src
  ph "copy ws to the fixed build path" >> /tmp/phases

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  set +e
  nim c -d:release --hints:off "${CCACHE_NIM_FLAGS[@]}" "${DEPS_FLAGS[@]}" \
    --nimcache:"$NIMCACHE" -o:/tmp/build/ctf src/ctf.nim > "$R/report" 2>&1
  status=$?
  set -e
  echo "$status" > "$R/status"
  ph "nim c (frontend + C compile + link)" >> /tmp/phases

  # Cache stats into the report: a remote that cannot be reached is otherwise
  # indistinguishable from a cold one.
  {
    echo
    echo "---- phases ----"
    cat /tmp/phases 2>/dev/null
    echo "---- ccache ----"
    echo "  gcc:    $(command -v gcc)"
    echo "  remote: ${CCACHE_REMOTE_STORAGE:-<none: CAOS_WORKER_REDIS_ADDR unset>}"
    ccache -s 2>/dev/null || echo "  (no stats)"
  } >> "$R/report"

  # A compile failure is a VALUE, not a job error: this tool is often called
  # precisely because something broke, and a job error takes an agent's turn
  # down with it.
  if [ "$status" -eq 0 ]; then
    cp /tmp/build/ctf "$R/bin"
    { echo; echo "BUILD OK  ($(stat -c %s /tmp/build/ctf) bytes)"; } >> "$R/report"
  else
    { echo; echo "FAILED: nim exited $status"; } >> "$R/report"
  fi

  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
