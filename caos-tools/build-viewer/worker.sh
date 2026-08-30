#!/usr/bin/env bash
# The `build-viewer` tool's worker. Its DOCS live in the sibling `.caos-expr`
# here-string, not in this header (caos SPEC, "Tools").
#
# FOUR STAGES, one script, selected by a curried --stage. The first runs on
# caos/imgtools; the rest run on the emsdk image that first stage assembles.
#
#   prepare   (default) assemble the emsdk worker image, narrow the tree,
#             curry the shared `deps` job, run-then it
#   toolchain the `then`: --result is the deps tree. Curry the Nim install
#             and the build, and run-then them.
#   build     the `then` of that: --result is the Nim toolchain. Compile the
#             bundle and check it.
#
# WHY THE TOOLCHAIN IS A JOB AND NOT AN IMAGE. Dockerfile.replay-viewer put
# `nimby use 2.2.4` and `nimby --global sync` in RUN layers, so the wasm image
# was emsdk + Nim + deps baked together and every dep change rebuilt the
# toolchain. Splitting them means the emsdk pin, the Nim pin and nimby.lock
# each key their own cached job: bumping the lock re-fetches deps and leaves
# the compiler alone.
#
# WHY NOT REUSE caos/nim's COMPILER. This build is `nim c -d:emscripten`, which
# drives `emcc` from the emsdk image — so Nim has to live in THAT image's
# userland. The deps job is shared, though: nimby clones Nim SOURCE, and source
# does not care which compiler reads it.
set -euo pipefail

fail() { echo "BUILD-VIEWER FAIL: $*" >&2; exit 1; }

# The two pins the toolchain job is keyed on. nimby 0.1.27 rather than the
# 0.1.26 the native path uses, and the sha256 with it: this is the pair
# Dockerfile.replay-viewer verified, and an unchecked toolchain download is how
# a build gets a compiler nobody chose.
NIMBY_PIN=0.1.27
NIMBY_SHA=3b3084394bd26b09f84a3f82389f075221c8784893238390939d71dd66ac9e8b
NIM_PIN=2.2.4

stage=prepare
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

prepare)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  caos get -r /cas/args/in/caos-tools/lib
  caos get /cas/args/in/caos
  # shellcheck source=../lib/common.sh
  source /cas/args/in/caos-tools/lib/common.sh
  # shellcheck source=../lib/image.sh
  source /cas/args/in/caos-tools/lib/image.sh

  caos get -r /cas/args/in/caos/emsdk
  assemble_worker_image /cas/args/in/caos/emsdk /cas/emsdk

  # What the VIEWER build reads. replay-viewer/config.nims resolves rootDir
  # from currentSourcePath, so the tree has to keep the repo's shape: it adds
  # <root>/src to the path and preloads <root>/data into the wasm filesystem.
  # client/ carries the two HTML shells and the two shared scripts the bundle
  # is assembled from; tools/ carries gen_wire_constants.nim, which is compiled
  # and RUN natively to emit wire_constants.js.
  narrow_tree /cas/ws src client data tools replay-viewer

  deps=$(caos curry --base:@=/cas/args/nim \
    "--worker1:@=/cas/args/in/caos-tools/lib/deps.sh") || fail "currying deps"

  fwd=("--worker1:@=/cas/args/worker1" --stage=toolchain "--ws:@=/cas/ws"
       "--lib:@=/cas/args/in/caos-tools/lib/common.sh"
       "--nimlib:@=/cas/args/in/caos-tools/lib/nim-toolchain.sh")
  if [ -e /cas/args/build-salt ]; then fwd+=("--build-salt:@=/cas/args/build-salt"); fi
  # Every later stage runs on the assembled emsdk image, not on ours.
  next=$(caos curry --base:@=/cas/emsdk "${fwd[@]}") || fail "currying toolchain"

  caos run-then /cas/args/in/nimby.lock --run:hash="$deps" --then:hash="$next"
  ;;

toolchain)
  # --result is the deps tree. Carry it into the build stage as an ordinary
  # arg; this stage's own job is to get a compiler.
  caos get -r /cas/args/result
  caos get -r /cas/args/nimlib

  # The pins ARE the cache key of the install below, so they ride as its --in.
  # Written here rather than in nim-toolchain.sh so the values that key the job
  # are the values it reads.
  printf 'nimby=%s sha256=%s nim=%s' "$NIMBY_PIN" "$NIMBY_SHA" "$NIM_PIN" > /tmp/pins
  caos put /tmp/pins /cas/pins

  nimjob=$(caos curry --base:@=/cas/args/base "--worker1:@=/cas/args/nimlib") \
    || fail "currying the nim toolchain"

  fwd=("--worker1:@=/cas/args/worker1" --stage=build
       "--ws:@=/cas/args/ws" "--lib:@=/cas/args/lib" "--deps:@=/cas/args/result")
  if [ -e /cas/args/build-salt ]; then fwd+=("--build-salt:@=/cas/args/build-salt"); fi
  next=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying build"

  caos run-then /cas/pins --run:hash="$nimjob" --then:hash="$next"
  ;;

build)
  # --result is the Nim toolchain (~/.nimby), --deps the Nim packages,
  # --ws the narrowed source tree.
  T0=$(date +%s%N); ph() { echo "  $1: $(( ($(date +%s%N) - T0)/1000000 ))ms"; T0=$(date +%s%N); }
  : > /tmp/phases
  caos get -r /cas/args/result
  ph "fetch the nim toolchain" >> /tmp/phases
  caos get -r /cas/args/deps
  ph "fetch deps" >> /tmp/phases
  caos get -r /cas/args/ws
  caos get -r /cas/args/lib
  # shellcheck source=../lib/common.sh
  source /cas/args/lib
  deps_flags /cas/args/deps

  # A FIXED build path, for the same reason every other tool here uses one: the
  # emitted JavaScript and the preload manifest embed absolute paths.
  rm -rf /tmp/build/src; mkdir -p /tmp/build
  cp -RL /cas/args/ws/. /tmp/build/src/
  cd /tmp/build/src
  ph "copy ws to the fixed build path" >> /tmp/phases

  export HOME=/tmp
  export PATH="/cas/args/result/nim/bin:$PATH"
  command -v nim >/dev/null || fail "no nim on PATH from the toolchain tree"
  command -v emcc >/dev/null || fail "no emcc on PATH — is this the emsdk image?"

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  mkdir -p replay-viewer/dist
  set +e
  {
    nim c -d:emscripten "${DEPS_FLAGS[@]}" replay-viewer/ctf_replay.nim &&
    nim c -r --hints:off "${DEPS_FLAGS[@]}" -o:/tmp/gen_wire_constants \
      tools/gen_wire_constants.nim > replay-viewer/dist/wire_constants.js
  } > "$R/report" 2>&1
  status=$?
  set -e
  ph "nim c -d:emscripten + wire constants" >> /tmp/phases

  if [ "$status" -ne 0 ]; then
    echo "$status" > "$R/status"
    { echo; echo "FAILED: the wasm build exited $status"; } >> "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi

  d=replay-viewer/dist
  cp client/broadcast_core.js client/chrome_common.js "$d/"
  cp data/font.ttf "$d/font.ttf"
  cp replay-viewer/static_replay.js replay-viewer/static_replay_worker.js "$d/"
  sed -e 's|<!-- WIRE_CONSTANTS -->|<script src="./wire_constants.js"></script>|' \
      -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
      -e 's|<!-- BROADCAST_CORE -->|<script src="./static_replay.js"></script>|' \
    client/replay_broadcast.html > "$d/index.html"
  sed -e 's|<!-- WIRE_CONSTANTS -->|<script src="./wire_constants.js"></script>|' \
      -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
    client/league_replayer.html > "$d/league.html"
  for c in red blue green yellow; do
    cp "data/soldier_${c}_front.png" "data/soldier_${c}_front_gun.png" "$d/"
  done
  mkdir -p "$d/art/walls" "$d/art/lockerroom"
  cp client/art/walls/wall_h.jpg client/art/walls/wall_v.jpg "$d/art/walls/"
  cp client/art/lockerroom/bg.jpg client/art/lockerroom/*.webp "$d/art/lockerroom/"
  rm -rf "$d/nimcache"
  ph "assemble the bundle" >> /tmp/phases

  # THE BUNDLE'S SHAPE IS PART OF THE BUILD, not a separate opinion. Each of
  # these caught a real regression once: a missing script tag renders a page
  # that loads and then does nothing, and the two `!` checks pin the two tags
  # the static bundle must NOT carry (it owns the runtime in a worker, so the
  # broadcast and the raw emscripten glue are wrong here).
  miss=0
  want_file() { [ -f "$d/$1" ] || { echo "  missing file: $1"; miss=1; }; }
  want_grep() { grep -q "$2" "$d/$1" || { echo "  $1 does not carry: $2"; miss=1; }; }
  deny_grep() { grep -q "$2" "$d/$1" && { echo "  $1 must not carry: $2"; miss=1; }; return 0; }
  {
    for f in ctf_replay.wasm ctf_replay.data static_replay_worker.js index.html \
             league.html font.ttf art/walls/wall_h.jpg art/walls/wall_v.jpg \
             art/lockerroom/bg.jpg art/lockerroom/green_1.webp \
             art/lockerroom/red_6.webp; do
      want_file "$f"
    done
    for c in red blue green yellow; do
      want_file "soldier_${c}_front.png"; want_file "soldier_${c}_front_gun.png"
    done
    [ -s "$d/wire_constants.js" ] || { echo "  wire_constants.js is empty"; miss=1; }
    [ -s "$d/chrome_common.js" ] || { echo "  chrome_common.js is empty"; miss=1; }
    want_grep wire_constants.js '^window.CTF_WIRE={'
    want_grep chrome_common.js 'window.ChromeCommon'
    for page in index.html league.html; do
      want_grep "$page" 'wire_constants.js'
      want_grep "$page" 'chrome_common.js'
    done
    want_grep static_replay.js 'static_replay_worker.js'
    deny_grep index.html '<script src="./broadcast_core.js"></script>'
    deny_grep index.html '<script src="./ctf_replay.js"></script>'
  } > /tmp/checks
  ph "check the bundle" >> /tmp/phases

  echo "$miss" > "$R/status"
  {
    echo
    echo "---- phases ----"
    cat /tmp/phases
    echo
    echo "---- bundle ----"
    echo "  wasm:  $(stat -c %s "$d/ctf_replay.wasm" 2>/dev/null || echo 0) bytes"
    echo "  data:  $(stat -c %s "$d/ctf_replay.data" 2>/dev/null || echo 0) bytes"
    echo "  files: $(find "$d" -type f | wc -l)"
    echo
    if [ "$miss" -eq 0 ]; then
      echo "BUILD-VIEWER OK"
    else
      echo "---- bundle checks ----"
      cat /tmp/checks
      echo
      echo "FAILED: the bundle is incomplete"
    fi
  } >> "$R/report"

  [ "$miss" -eq 0 ] && cp -R "$d" "$R/dist"
  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
