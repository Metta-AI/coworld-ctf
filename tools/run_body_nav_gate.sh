#!/bin/sh
set -eu

if [ -n "$(git status --porcelain)" ]; then
  echo "canonical navigation gate requires a clean working tree" >&2
  exit 2
fi

commit=$(git rev-parse HEAD)
tag=coworld-ctf-nav-gate
docker buildx build --load --platform linux/amd64 --target build \
  --build-arg NimMain=tools/bench_body_nav_rework.nim \
  --build-arg 'NimFlags=-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on' \
  --tag "$tag" .
image_id=$(docker image inspect --format '{{.Id}}' "$tag")

echo "canonical Docker gate: quality, activation, retained memory, and determinism"
echo "tick timing is gated separately on native or real linux/amd64 hardware"
docker run --rm --platform linux/amd64 --cpus=1 \
  -e NAV_GATE_COMMIT="$commit" \
  -e NAV_GATE_DIRTY=false \
  -e NAV_GATE_IMAGE_ID="$image_id" \
  -e NAV_GATE_CPU_LIMIT=1 \
  "$tag" ./ctf --all \
    --corpus tests/fixtures/shell/nav_route_corpus.json
