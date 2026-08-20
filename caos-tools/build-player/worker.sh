#!/usr/bin/env bash
# The `build-player` tool's worker. Its DOCS — the description and `@param`
# tags an agent registers it by — live in the sibling `.caos-expr`
# here-string, not in this header (caos SPEC, "Tools"): a doc edit then
# re-keys the tool's arg tree without recompiling a policy.
#
# TWO STAGES, one script, selected by a curried --stage — build/worker.sh's
# shape, and for the same reason: a worker describes its continuation and
# exits rather than blocking on a job (design/map-then.md).
#
#   narrow   (default) narrow the tree, curry the deps job, run-then it
#   compile  the `then`: --result is the deps tree, so nim can be pointed at it
#
# WHY A SEPARATE TOOL FROM `build`, AND NOT A FLAG ON IT. A policy and the game
# server share no artifact and barely share an input:
#
#   - different TREE. The server staticReads four files out of client/ and reads
#     data/ and config.json; a policy reads none of them — players/baseline's
#     shipped image carries no data/ at all. It needs players/ and src/, and
#     only one file of src/ at that (ctf/labels, which is deliberately
#     import-free so the renderer's pixie/mummy cone cannot reach a bot).
#   - different FLAGS. The Dockerfile builds a policy -d:useMalloc --opt:speed
#     --stackTrace:on and injects -d:buildDefines; the server takes none of
#     those.
#   - different CODEGEN anyway. Nim compiles whole-program, so even the modules
#     both binaries import are different C in each. There is nothing to reuse
#     but the deps tree and the ccache, and both are shared already.
#
# Two tools also means an agent tuning a bot re-keys only the bot: editing
# baseline.nim leaves `build` and `test` untouched, and vice versa.
set -euo pipefail

fail() { echo "BUILD-PLAYER FAIL: $*" >&2; exit 1; }

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

  # What a POLICY build reads, and all it reads. players/<name>/config.nims puts
  # ../../../src on the path for `ctf/labels`, the sprite-label vocabulary the
  # engine emits against — the one thing a bot shares with the game.
  #
  # Both WHOLE, not the two files a policy actually reads — so an edit anywhere
  # under either re-keys this build. That is cheap, because a re-key is not a
  # rebuild: nim codegens only what is IMPORTED, so a comment in src/ctf/sim.nim
  # (which no bot imports) leaves every .c byte-identical and ccache hands back
  # the same binary. Measured, comment-only edits, warm cache:
  #
  #   README.md        1.4s   outside the narrowed tree — compile is a cache HIT
  #   src/ctf/sim.nim  5.9s   re-keys; 72/72 ccache hits, same 1,040,856 bytes
  #   baseline.nim     5.7s   same
  #
  # Narrowing to src/ctf/labels.nim alone would buy those 4s and break the first
  # time a policy imports one more module — silently, in a way that looks like a
  # missing dependency rather than a too-clever tree.
  narrow_tree /cas/ws players src

  # Byte-for-byte the same currying `build` does, so this is a cache HIT against
  # the game build's deps job rather than a second fetch of the same 29 repos.
  deps=$(caos curry --base:@=/cas/args/base \
    "--worker1:@=/cas/args/in/caos-tools/lib/deps.sh") || fail "currying deps"

  fwd=("--worker1:@=/cas/args/worker1" --stage=compile "--ws:@=/cas/ws"
       "--lib:@=/cas/args/in/caos-tools/lib/common.sh")
  if [ -e /cas/args/player ]; then fwd+=("--player:@=/cas/args/player"); fi
  if [ -e /cas/args/defines ]; then fwd+=("--defines:@=/cas/args/defines"); fi
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

  player=baseline
  if [ -e /cas/args/player ]; then
    caos get /cas/args/player
    player=$(cat /cas/args/player)
  fi

  # Whitespace-split, globbing off. `read -ra` would stop at the first newline;
  # unquoted expansion under `set -f` splits on every IFS character and expands
  # nothing, which is what a define list wants.
  extra=()
  if [ -e /cas/args/defines ]; then
    caos get /cas/args/defines
    raw=$(cat /cas/args/defines)
    set -f
    # shellcheck disable=SC2206  # splitting is the point; `set -f` blocks globbing
    extra=($raw)
    set +f
  fi

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"

  # A bad argument is a VALUE too, not a job error — same reason a failed
  # compile is (see below). An agent that typo'd a policy name wants the list of
  # real ones back, not a dead turn.
  reject() {
    { echo "$1"; echo; echo "FAILED"; } > "$R/report"
    echo 2 > "$R/status"
    caos put "$R" /cas/out
    exit 0
  }

  # A directory name, not a path. Checked rather than assumed: everything below
  # interpolates it into a path, and the narrowed tree has a src/ next door.
  case "$player" in
    ''|*[!a-zA-Z0-9_-]*) reject "player must be a bare directory name under players/; got: $player" ;;
  esac

  entry="players/$player/$player.nim"
  if [ ! -f "/cas/args/ws/$entry" ]; then
    have=$(find /cas/args/ws/players -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)
    reject "no such policy: $entry
players holding a <name>/<name>.nim: ${have:-<none>}"
  fi
  for d in ${extra[@]+"${extra[@]}"}; do
    case "$d" in
      -d:*|--define:*) ;;
      *) reject "defines takes only -d:… / --define:… terms; got: $d" ;;
    esac
  done

  deps_flags /cas/args/result
  setup_ccache

  # Compile at a FIXED path so ccache hits: the generated C embeds absolute
  # paths, and a workspace that moves misses everything.
  rm -rf /tmp/build/src; mkdir -p /tmp/build
  cp -RL /cas/args/ws/. /tmp/build/src/
  cd /tmp/build/src
  ph "copy ws to the fixed build path" >> /tmp/phases

  # players/baseline/Dockerfile's compile line, and it has to STAY it — a policy
  # that is only green under different flags is a policy that fails in the
  # league, and this tool's whole claim is that it builds what ships. So the
  # SEMANTIC flags are copied verbatim, redundancy included: --opt:speed adds
  # nothing to -d:release, and it is here because the Dockerfile has it.
  # -d:buildDefines is the set the build was TOLD to compile with — artlog
  # parses it into its meta.json, recording intent (NOT that any code guarded by
  # a define still exists). The rest — --hints:off, --nimcache, the ccache and
  # --path: flags — are the WORKER's, invisible to the binary.
  bd_parts=(-d:release ${extra[@]+"${extra[@]}"} -d:useMalloc)
  bd="${bd_parts[*]}"
  set +e
  nim c -d:release ${extra[@]+"${extra[@]}"} -d:useMalloc \
    "-d:buildDefines=$bd" --opt:speed --stackTrace:on --hints:off \
    "${CCACHE_NIM_FLAGS[@]}" "${DEPS_FLAGS[@]}" \
    --nimcache:"$NIMCACHE" -o:/tmp/build/player "$entry" > "$R/report" 2>&1
  status=$?
  set -e
  echo "$status" > "$R/status"
  ph "nim c (frontend + C compile + link)" >> /tmp/phases

  {
    echo
    echo "---- build ----"
    echo "  policy:  $entry"
    echo "  defines: $bd"
    echo "---- phases ----"
    cat /tmp/phases 2>/dev/null
    ccache_report
  } >> "$R/report"

  # A compile failure is a VALUE, not a job error: this tool is often called
  # precisely because something broke, and a job error takes an agent's turn
  # down with it.
  if [ "$status" -eq 0 ]; then
    cp /tmp/build/player "$R/bin"
    { echo; echo "BUILD OK  $player ($(stat -c %s /tmp/build/player) bytes)"; } >> "$R/report"
  else
    { echo; echo "FAILED: nim exited $status"; } >> "$R/report"
  fi

  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
