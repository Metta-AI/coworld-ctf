#!/usr/bin/env bash
# The `build` tool's worker. Its DOCS — the description and `@param` tags an
# agent registers it by — live in the sibling `.caos-expr` here-string, not in
# this header (caos SPEC, "Tools"): a doc edit then re-keys the tool's arg tree
# without touching the tree this script compiles from.
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
#
# TWO BINARIES, ONE IMAGE, and that is the game's whole shipped surface:
# /bin/ctf (the server, which also serves the paintball KOTH mode when the
# config gates it on) and /bin/paintball-player (the thin paintball seat
# registrar). They compile with GAME_NIM_FLAGS — the SHIPPED flags — because
# `build-game-image` assembles the image around exactly this result. Nothing
# recompiles them downstream, so what this tool returns is what runs in
# production.
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
  # --build-salt, not --salt: `salt` is a RESERVED arg name (the interpreter
  # binds it from CAOS_SALT and threads it into every sub-run), so a tool
  # declaring `@param [salt]` is refused at REGISTRATION and an agent never
  # gets the parameter at all — only a hand-run could reach it. Under its own
  # name it rides in the compile stage and nowhere else, so a fresh value
  # re-keys this build while leaving the deps job a cache hit. Nothing reads
  # it: its presence in the key is the whole mechanism.
  if [ -e /cas/args/build-salt ]; then fwd+=("--build-salt:@=/cas/args/build-salt"); fi
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

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R/bin"
  # A SEPARATE NIMCACHE PER BINARY. Nim's codegen is whole-program and both
  # entry points pull in ctf/, so one shared nimcache would have each compile
  # overwrite the other's .c for the same module and hand ccache a moving
  # target. Fixed paths still (see NIMCACHE): absolute paths are baked into the
  # generated C, so a cache that moves misses everything.
  set +e
  nim c "${GAME_NIM_FLAGS[@]}" "${CCACHE_NIM_FLAGS[@]}" "${DEPS_FLAGS[@]}" \
    --nimcache:"$NIMCACHE/ctf" -o:/tmp/build/ctf src/ctf.nim > "$R/report" 2>&1
  status=$?
  ph "nim c src/ctf.nim" >> /tmp/phases
  if [ "$status" -eq 0 ]; then
    { echo; echo "---- src/paintball_player.nim ----"; } >> "$R/report"
    nim c "${GAME_NIM_FLAGS[@]}" "${CCACHE_NIM_FLAGS[@]}" "${DEPS_FLAGS[@]}" \
      --nimcache:"$NIMCACHE/paintball-player" \
      -o:/tmp/build/paintball-player src/paintball_player.nim >> "$R/report" 2>&1
    status=$?
    ph "nim c src/paintball_player.nim" >> /tmp/phases
  fi
  set -e
  echo "$status" > "$R/status"

  {
    echo
    echo "---- phases ----"
    cat /tmp/phases 2>/dev/null
    ccache_report
  } >> "$R/report"

  # A compile failure is a VALUE, not a job error: this tool is often called
  # precisely because something broke, and a job error takes an agent's turn
  # down with it.
  if [ "$status" -eq 0 ]; then
    cp /tmp/build/ctf "$R/bin/ctf"
    cp /tmp/build/paintball-player "$R/bin/paintball-player"
    { echo
      echo "BUILD OK"
      echo "  /bin/ctf               $(stat -c %s /tmp/build/ctf) bytes"
      echo "  /bin/paintball-player  $(stat -c %s /tmp/build/paintball-player) bytes"
    } >> "$R/report"
  else
    rmdir "$R/bin"
    { echo; echo "FAILED: nim exited $status"; } >> "$R/report"
  fi

  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
