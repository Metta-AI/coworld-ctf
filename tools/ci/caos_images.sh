#!/usr/bin/env bash
# Produce the game and player images with caos and load them into the LOCAL
# docker daemon under the tags compose.yaml names.
#
# WHY THIS EXISTS, AND WHY THE UPLOAD IS STILL THE PYTHON CLI. `coworld build`
# and `coworld upload-coworld` want the images in a local engine store: the
# upload derives its client_hash from `docker image inspect --format {{.Id}}`,
# and the local certification run boots them with docker. So the boundary is
# here — caos does every build, and the platform conversation stays with the
# tool that owns that API. caos-tools/upload-image's header names leagues and
# certification as exactly the surface not worth re-implementing in bash; this
# script is that judgement applied to the coworld upload.
#
# What compose.yaml then does is nothing: its services carry no `build:`, so
# `docker compose build` is a no-op over images that are already here, and the
# manifest's {{GAME_IMAGE}} / {{PLAYER_IMAGE}} placeholders resolve to these
# tags exactly as they did when compose built them.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_dir"

CAOS=${CAOS_CLI:-caos-cli}
GAME_TAG=${GAME_TAG:-coworld-ctf-game:latest}
PLAYER_TAG=${PLAYER_TAG:-coworld-ctf-baseline:latest}
# Both image tools take a --runtime, so this has to be able to pass one. It is
# not a way around the architecture gate — the gate checks whatever base you
# name, and coworld's own uploader refuses anything that is not linux/amd64
# before it pushes. It is how someone on non-amd64 hardware runs this chain end
# to end against a base built for their machine.
RUNTIME=${CAOS_RUNTIME:-}

command -v "$CAOS" >/dev/null || {
  echo "no $CAOS on PATH — enter the dev shell (nix develop) or set CAOS_CLI" >&2
  exit 1
}

# `run-tool` prints its report on stderr and "<kind> <hash>" on stdout, so the
# ref comes out of the RESULT rather than by scraping the report.
tool_ref() { # $1 = tool name
  local out hash dir args=()
  [ -n "$RUNTIME" ] && args+=("--runtime=$RUNTIME")
  out=$("$CAOS" run-tool "$1" ${args[@]+"${args[@]}"}) || { echo "$1 failed" >&2; exit 1; }
  hash=${out##* }
  dir=$(mktemp -d)
  "$CAOS" get "$hash" "$dir/result" >/dev/null
  [ -s "$dir/result/ref" ] || { echo "$1 produced no ref" >&2; exit 1; }
  cat "$dir/result/ref"
}

load() { # $1 = caos ref, $2 = local tag
  # docker, not skopeo: the daemon is already a hard requirement downstream
  # (`coworld build` shells out to docker compose, and the upload reads
  # `docker image inspect --format {{.Id}}` for its client_hash), while skopeo
  # is not on this repo's dev-shell PATH. The ref is a digest on the stack's
  # own registry, which answers plain HTTP on localhost — the one host docker
  # already treats as insecure without configuration.
  #
  # The re-tag is the point: compose and the manifest placeholders name a TAG,
  # and a pulled digest reference is not one.
  docker pull --quiet "$1" >/dev/null
  docker tag "$1" "$2"
}

echo "==> building the game image"
game=$(tool_ref build-game-image)
echo "==> building the player image"
player=$(tool_ref build-image)

echo "==> loading $game -> $GAME_TAG"
load "$game" "$GAME_TAG"
echo "==> loading $player -> $PLAYER_TAG"
load "$player" "$PLAYER_TAG"

# The images the upload will read are the images this printed. Say so: the
# whole failure mode this replaces was a compose build quietly producing
# something other than what was tested.
docker image inspect --format '{{index .RepoTags 0}}  {{.Id}}  {{.Architecture}}/{{.Os}}' \
  "$GAME_TAG" "$PLAYER_TAG"
