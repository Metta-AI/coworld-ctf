#!/usr/bin/env bash
# Assemble the game image. See .caos-expr for the agent-facing docs; this
# header is the mechanism.
#
# TWO STAGES, one script, selected by a curried --stage:
#
#   narrow   (default) curry `build`, run-then it
#   assemble the `then`: --result is build's {bin/{ctf,paintball-player},…}
#
# WHY THIS COMPILES NOTHING, and why the game image is no longer a Dockerfile.
# It used to be `FROM debian:bookworm-slim` with a compile stage inside it, so
# every image build recompiled the game from scratch — the same source `build`
# had just compiled, on a different toolchain, with the flags written down a
# second time. `build` now compiles with GAME_NIM_FLAGS (the shipped flags), so
# there is one compile and this places its output. The debian base went with
# it: a nim binary bakes absolute /nix/store paths for its glibc RUNPATH and
# its dlopen'd libcurl, so it can only run on a runtime built from the same
# nixpkgs pin — which is exactly the base a policy image already uses.
#
# WHAT WE GIVE UP by leaving debian: apt, a shell, and a package manager inside
# the shipped image. That is the point rather than the cost — the same trade
# players/baseline/Dockerfile already made — and a pin mismatch fails LOUDLY at
# module init ("could not load: libcurl.so(|.4)"), before the websocket, rather
# than degrading into a server that runs and misbehaves.
#
# WHY A GIT-DOCKER DELTA AND NOT A TARBALL: see build-image's header. The same
# reasoning applies, with a larger layer — data/ is 7.4 MB, and it is linked
# BY REFERENCE out of the input tree, so it is not copied to say the binaries
# changed.
set -euo pipefail

fail() { echo "BUILD-GAME-IMAGE FAIL: $*" >&2; exit 1; }

stage=narrow
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

narrow)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  # -r: we CURRY these bytes onward, so we need the file, not a placeholder. A
  # tool's `.caos-expr` is evaluated against its OWN directory, so `..` cannot
  # reach a sibling tool — the workspace tree is how tools reach each other.
  caos get -r /cas/args/in/caos-tools/build
  caos get -r /cas/args/in/caos-tools/lib

  # Hand the whole tree to `build` and let ITS narrow stage decide what a game
  # build reads. Duplicating that list here is how the two would drift.
  fwd=("--worker1:@=/cas/args/in/caos-tools/build/worker.sh")
  if [ -e /cas/args/build-salt ]; then fwd+=("--build-salt:@=/cas/args/build-salt"); fi
  # `build` runs on the NIM image, not ours: it compiles.
  game=$(caos curry --base:@=/cas/args/nim "${fwd[@]}") || fail "currying build"

  next=("--worker1:@=/cas/args/worker1" --stage=assemble
        "--lib:@=/cas/args/in/caos-tools/lib/image.sh")
  if [ -e /cas/args/runtime ]; then next+=("--runtime:@=/cas/args/runtime"); fi
  then_=$(caos curry --base:@=/cas/args/base "${next[@]}") || fail "currying assemble"

  # The whole tree is the run-then input, so `assemble` receives it as --in.
  # That is deliberate: the image carries data/ and the top-level JSON, which
  # are repo content rather than build output.
  caos run-then /cas/args/in --run:hash="$game" --then:hash="$then_"
  ;;

assemble)
  # --result is build's tree: { bin/{ctf,paintball-player}, report, status }.
  caos get -r /cas/args/result
  caos get -r /cas/args/lib
  # shellcheck source=../lib/image.sh
  source /cas/args/lib

  status=$(cat /cas/args/result/status 2>/dev/null || echo 1)
  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  if [ "$status" != "0" ]; then
    # The compile is the whole job when it fails. Return ITS diagnostics rather
    # than a confusing "no binary" from the assembly step.
    { cat /cas/args/result/report 2>/dev/null
      echo; echo "FAILED: the game did not compile, so there is no image."
    } > "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi

  # --in is the workspace tree. One level at a time: a path has to exist before
  # it can be descended into, and nothing here is READ — the entries below are
  # linked by reference and `caos put` records the hash already known for them.
  caos get /cas/args/in

  runtime=$DEFAULT_RUNTIME
  if [ -e /cas/args/runtime ]; then caos get /cas/args/runtime; runtime=$(cat /cas/args/runtime); fi

  resolve_base "$runtime"
  # Both binaries, not just the first: they come from one compile, but a check
  # that only covers half the layer is a check that reads as though it covers
  # the layer.
  archhint="Run the caos stack on matching hardware, or point --runtime at a base built for this one."
  assert_image_arch "$BASE_CONFIG" /cas/args/result/bin/ctf "/bin/ctf" "$archhint"
  assert_image_arch "$BASE_CONFIG" /cas/args/result/bin/paintball-player "/bin/paintball-player" "$archhint"

  img=$R/image; rm -rf "$img"; mkdir -p "$img/layer00/bin" "$img/layer00/workspace/ctf"
  for b in ctf paintball-player; do
    cp "/cas/args/result/bin/$b" "$img/layer00/bin/$b"
    # Git trees cannot encode an exec bit the way an image layer needs, so caos
    # takes it from a sidecar (the same mechanism std/flake-builder uses for
    # the setuid /bin/caos).
    printf '{"mode":"0755","uid":0,"gid":0}' > "$img/layer00/bin/$b.caosmeta"
  done

  # data/ and the top-level JSON, BY REFERENCE: a symlink into /cas resolves to
  # the hash already recorded for it, so 7.4 MB of art is named rather than
  # fetched and copied. The server reads both against its working directory.
  ln -s /cas/args/in/data "$img/layer00/workspace/ctf/data"
  json=0
  for f in /cas/args/in/*.json; do
    [ -e "$f" ] || continue
    ln -s "$f" "$img/layer00/workspace/ctf/$(basename "$f")"
    json=$((json + 1))
  done
  [ "$json" -gt 0 ] || fail "no top-level JSON in the tree — config.json is not optional"

  printf 'docker://%s' "$BASE_PIN" > "$img/base"
  # Cmd names the SERVER; /bin/paintball-player is reached by a policy's own
  # `run`, which is why it ships here rather than in a second image. WorkingDir
  # is load-bearing: the server resolves data/ and its config against the cwd.
  # Everything else — Env, and SSL_CERT_FILE in particular — is the base's and
  # is carried through untouched.
  jq '.config.Cmd = ["/bin/ctf"] | .config.WorkingDir = "/workspace/ctf"' "$BASE_CONFIG" \
    > "$img/config.json" || fail "rewriting the image config"

  publish_delta "$img" "$R"

  { echo "game:    src/ctf.nim, src/paintball_player.nim"
    echo "base:    $BASE_PIN"
    echo "         (referenced by digest, not copied — resolved from $runtime)"
    echo "layer:   /bin/ctf                ($(stat -c %s /cas/args/result/bin/ctf) bytes)"
    echo "         /bin/paintball-player   ($(stat -c %s /cas/args/result/bin/paintball-player) bytes)"
    echo "         /workspace/ctf/data     (by reference)"
    echo "         /workspace/ctf/*.json   ($json files, by reference)"
    echo "config:  the base's, with Cmd=/bin/ctf and WorkingDir=/workspace/ctf"
    echo "ref:     $IMAGE_REF"
    echo
    echo "image/ is the git-docker delta; ref/ is what the server converted it"
    echo "to, in the stack's own registry. Load it into a local daemon with"
    echo "tools/ci/caos_images.sh — that is what feeds compose, and what"
    echo "coworld build/upload-coworld read."
    echo
    echo "BUILD-GAME-IMAGE OK"
  } > "$R/report"
  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
