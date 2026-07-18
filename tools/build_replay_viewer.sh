#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$1"

if [[ "${output_dir}" != /* || "${output_dir}" == "/" || "${output_dir}" == "${repo_dir}" ]]; then
  echo "unsafe bundle output: ${output_dir}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

image_tag="coworld-ctf-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null
  fi
  docker image rm "${image_tag}" >/dev/null
}
trap cleanup EXIT

docker build \
  --platform linux/amd64 \
  --file "${repo_dir}/Dockerfile.replay-viewer" \
  --target replay-viewer-builder \
  --tag "${image_tag}" \
  "${repo_dir}"
container_id="$(docker create "${image_tag}")"
docker cp "${container_id}:/workspace/ctf/replay-viewer/dist/." "${output_dir}"

test -f "${output_dir}/index.html"
