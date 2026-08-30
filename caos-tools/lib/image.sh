#!/usr/bin/env bash
# Shared by the build-image and build-game-image tools' worker.sh. Sourced, not
# run. Both assemble a git-docker delta over a published nix base, and both run
# on caos/imgtools (skopeo + jq + coreutils) rather than caos/nim — they place
# a binary someone else compiled, they do not compile one.
#
# Each caller defines its own `fail`; these functions use it.

# The runtime base both image tools layer onto. Kept in step with the nixpkgs
# pin caos/nim and caos/player-runtime share BY HAND, which is the coupling
# this repo chose to make visible rather than clever: the tag IS the pin, and a
# mismatch dies loudly at a policy's first module init rather than silently.
DEFAULT_RUNTIME=ghcr.io/metta-ai/coworld-ctf-runtime:b47ad65d

# Read a base's config and pin it by digest. Sets BASE_CONFIG (a path to the
# config JSON) and BASE_PIN (the <name>@sha256:… the delta records).
#
# skopeo rather than curl: it already speaks the token dance, the auth file and
# both manifest media types, and it is in this image precisely so we do not
# reimplement a registry client badly.
#
# TLS is verified for a real registry and skipped for a bare host:port, which is
# docker's own rule for telling a registry name from a path segment: a host with
# no dot is local (the caos stack's own registry answers plain HTTP on
# caos-registry:5000). Nothing secret moves here — the base is public and this
# is a pull.
#
# PINNED BY DIGEST because caos refuses a mutable tag in a git-docker delta
# ("is mutable; use <name>@sha256:..."), and it is right to: the delta is
# content-addressed, so a base that could be re-tagged underneath it would make
# one hash mean two different images. Resolving here also means the recorded
# base is the exact bytes this build read the config from, not whatever the tag
# points at when someone later converts the tree.
#
# $1 = the base image ref.
resolve_base() {
  local runtime=$1 tlsflag=--tls-verify=true digest
  case "${runtime%%/*}" in *.*) ;; *) tlsflag=--tls-verify=false ;; esac
  BASE_CONFIG=/tmp/base-config.json
  skopeo inspect --config $tlsflag "docker://$runtime" > "$BASE_CONFIG" \
    || fail "cannot read the config of $runtime (is the base published?)"
  # ALREADY PINNED is the normal case for caos/emsdk, whose `base` names a
  # digest outright. Re-deriving a pin from one produces `name@sha256@sha256:…`
  # — a ref skopeo accepts as a name and then cannot copy, which fails deep in
  # the server's convert rather than here.
  case "$runtime" in
    *@sha256:*) BASE_PIN=$runtime; return 0 ;;
  esac
  digest=$(skopeo inspect $tlsflag --format '{{.Digest}}' "docker://$runtime") \
    || fail "cannot resolve $runtime to a digest"
  BASE_PIN="${runtime%%:*}@$digest"
  case "$runtime" in *:*/*|*/*:*) BASE_PIN="${runtime%:*}@$digest" ;; esac
}

# The docker architecture name of an ELF file, or "" if $1 is not an ELF.
#
# Byte at a time (-tx1), not -tx2: a two-byte read is printed in the HOST's
# byte order, so the same binary would read 003e on one machine and 3e00 on
# another. e_machine is a 2-byte little-endian field at offset 18, and ELF is
# little-endian on both architectures this project ships.
elf_arch() {
  [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' ')" = "7f454c46" ] || return 0
  case "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' ')" in
    3e00) echo amd64 ;;
    b700) echo arm64 ;;
  esac
}

# THE ARCHITECTURE GATE, and the reason it exists: NOTHING ELSE CATCHES THIS.
#
# A git-docker delta inherits the base's config verbatim — that is the point,
# the base carries store paths and rootfs diff_ids we cannot invent — and the
# config carries `architecture`. So layering a binary from an arm64 caos stack
# onto the amd64 base produces an image that DECLARES amd64 and contains an
# aarch64 ELF. It builds clean, it uploads clean, and it dies on the platform
# with "exec format error", one deploy later and a long way from here.
#
# The coworld upload path happens to assert linux/amd64 before it pushes
# (coworld's `_upload_container_image`), but `upload-image` — this repo's own
# policy path — makes three raw API calls and asserts nothing. So the gate goes
# here, where both paths converge, rather than in either uploader.
#
# $1 = the base's config JSON, $2 = the binary, $3 = a label for the message,
# $4 = what the caller can do about it.
assert_image_arch() {
  local config=$1 binary=$2 label=$3 hint=$4 want have
  want=$(jq -r '.architecture // empty' "$config")
  [ -n "$want" ] || fail "the base image config declares no architecture"
  have=$(elf_arch "$binary")
  [ -n "$have" ] || fail "$label is not an ELF binary — cannot check its architecture against the base"
  [ "$want" = "$have" ] && return 0
  fail "ARCHITECTURE MISMATCH: the base is $want, $label is $have.
  A git-docker delta inherits the base's config, so this image would claim
  $want and die with 'exec format error' wherever it ran. Both binaries take
  the architecture of the caos stack that produced them, so this stack is
  $have.
  $hint"
}

# Convert an assembled delta into a real image and record the ref beside it.
# Sets IMAGE_REF and writes it to <result>/ref.
#
# WHY THE TOOLS RESOLVE RATHER THAN LEAVING IT TO THEIR CALLER. A git-docker
# delta is not something a docker daemon can pull; `caos resolve-image` is what
# turns it into a digest in the stack's own registry, and only a WORKER has
# that verb (the host `caos-cli` does not). Leaving it undone meant every
# consumer needed a job of its own just to learn the ref — which is why
# `upload-image` carries a whole `realize` stage. Both host paths (compose,
# and the local certification `coworld build` runs) want a pullable ref, so the
# tool that assembles the image is the right place to produce one.
#
# The conversion is cached on the delta, so re-resolving an unchanged image is
# a lookup, not work.
#
# $1 = the delta directory, $2 = the result directory.
publish_delta() {
  local delta
  caos put "$1" /cas/image
  delta=$(caos hash /cas/image) || fail "hashing the image delta"
  IMAGE_REF=$(caos resolve-image "$delta") || fail "converting the image delta $delta"
  printf '%s' "$IMAGE_REF" > "$2/ref"
}

# Assemble a worker image from a directory holding `base` (a pinned
# docker:// ref) and `worker` (the trampoline), and put it at $2 so a later
# stage can name it as --base. Sets WORKER_BASE_PIN.
#
# WHY A TOOL ASSEMBLES THIS RATHER THAN THE TREE JUST BEING THE IMAGE. A
# git-tree image must carry a config.json — the server generates the diff_ids
# but not the rest — and for an upstream base that config is upstream's: its
# PATH, its EMSDK variables, its WORKDIR. Committing a copy would be a second
# place for it to be right, drifting silently from the digest beside it the
# first time upstream changed one. skopeo reads it from the pinned digest
# instead, so there is one source for both.
#
# WHAT A WORKER IMAGE NEEDS BEYOND THE BASE, and why this adds so little. caos
# does NOT install anything into an image at run time: an image is a worker
# because it CARRIES the pieces. std/flake-builder's `stack` stage adds a
# larger set — /bin/caos, /usr/bin/env, a 1777 /tmp, an /etc/passwd with a uid
# 1000 — but it stacks onto a SCRATCH nix image, which has none of them. A
# distro base has all of them already, and adding them again is not harmless.
#
# DO NOT PUT ANYTHING UNDER /bin HERE. On a usrmerged base — Ubuntu, Debian,
# anything modern — `/bin` is a SYMLINK to `usr/bin`, and a layer carrying a
# `bin/` DIRECTORY replaces that symlink outright. Every one of /bin/bash,
# /bin/env, /bin/sh then stops existing, and the failure is
#
#     worker failed: running /worker: No such file or directory
#
# which is exec's ENOENT for a missing INTERPRETER, not a missing /worker. It
# reads like the trampoline was never installed. (This cost a CI run.) Placing
# caos at usr/bin/caos gets the same /bin/caos runnerd's forced entrypoint
# wants, through the base's own symlink, and touches nothing else.
#
# Same reasoning for the rest of that set, checked against caos/emsdk's base:
# /usr/bin/env is a real binary there and must not be shadowed; /tmp is already
# 1777; uid 1000 already exists (`emscripten`, and it owns the emcc cache the
# build writes to), so overwriting /etc/passwd would delete the user the
# toolchain expects.
#
# THE caos BINARY IS THIS WORKER'S OWN, which is what makes it the right
# version by construction — and what makes this function refuse to run on a
# host of the wrong architecture. See the arch check below.
#
# $1 = the source directory (base + worker), $2 = the /cas path to put it at.
assemble_worker_image() {
  local src=$1 dest=$2 ref img l
  ref=$(tr -d '[:space:]' < "$src/base")
  [ -n "$ref" ] || fail "$src/base is empty"
  resolve_base "${ref#docker://}"
  WORKER_BASE_PIN=$BASE_PIN

  # The copied binary has to RUN in the assembled image, so this stack's
  # architecture has to be the base's. Without this the image builds happily
  # and the first job dies as `exec: "/bin/caos": stat /bin/caos: no such file
  # or directory` — docker's message for a binary it cannot exec — which points
  # nowhere near the cause.
  assert_image_arch "$BASE_CONFIG" /bin/caos "this caos stack's own /bin/caos" \
    "Run the caos stack on $(jq -r .architecture "$BASE_CONFIG") hardware. This base is pinned upstream and is not ours to rebuild for another architecture — see caos/emsdk/README.md."

  img=$(mktemp -d)/image; l=$img/layer00
  mkdir -p "$l/usr/bin"
  install -m 0755 "$src/worker" "$l/worker"
  printf '{"mode":"0755","uid":0,"gid":0}' > "$l/worker.caosmeta"
  # Git trees cannot encode setuid, so a sidecar carries mode/uid/gid and the
  # server applies it when it rebuilds the layer tar.
  cp /bin/caos "$l/usr/bin/caos"
  printf '{"mode":"4755","uid":0,"gid":0}' > "$l/usr/bin/caos.caosmeta"

  printf 'docker://%s' "$BASE_PIN" > "$img/base"
  # Upstream's config, untouched. Cmd and Entrypoint are irrelevant here —
  # runnerd forces `/bin/caos runner` — but Env is not: emsdk puts its whole
  # toolchain on PATH there.
  cp "$BASE_CONFIG" "$img/config.json"
  caos put "$img" "$dest"
}
