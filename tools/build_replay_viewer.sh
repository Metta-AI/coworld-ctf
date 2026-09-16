#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  echo "  this rm -rf's the output dir mid-run -- do not run" >&2
  echo "  tests/test_season2_replay_hud.nim or tests/test_pb_manifest.nim" >&2
  echo "  concurrently against the same checkout (phantom failures)" >&2
  exit 1
fi

requested_output="$1"

if [[ "${requested_output}" != /* || "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

# `coworld build` pre-creates the bundle's output parent; CI does not, and the
# containment check below resolves it by cd-ing in. Create it first or every
# fresh checkout fails here (the ecos 2026-08-23 scar).
mkdir -p "$(dirname "${requested_output}")"

output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ "${output_dir}" != "${repo_dir}"/* || -L "${output_dir}" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

image_tag="coworld-ctf-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The sim-sources stamp is computed HERE, on the host, because the build
# context excludes .git (.dockerignore) — the container cannot derive it.
# It is baked into the wasm (-d:ctfSimSourcesStamp) and exported as
# ctf_sim_sources_stamp_ptr/len so tools/qa_module_eval.cjs can recompute
# at HEAD and fail CI when the committed bundle was built from older sim
# sources — the same-GameVersion drift the GameVersion tripwire cannot see.
sim_sources_stamp="$("${repo_dir}/tools/sim_sources_stamp.sh")"

build_args=(
  --platform linux/amd64
  --file "${repo_dir}/Dockerfile.replay-viewer"
  --target replay-viewer-builder
  --build-arg "SIM_SOURCES_STAMP=${sim_sources_stamp}"
  --tag "${image_tag}"
  "${repo_dir}"
)
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}"
else
  # Docker Desktop installations without the buildx plugin still honor the
  # explicit amd64 platform through their Linux VM. CI installs Buildx above.
  docker build "${build_args[@]}"
fi
container_id="$(docker create --platform linux/amd64 "${image_tag}")"
docker cp "${container_id}:/workspace/ctf/replay-viewer/dist/." "${output_dir}"

test -f "${output_dir}/index.html"
