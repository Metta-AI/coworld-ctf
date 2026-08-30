#!/usr/bin/env bash
# The replay-viewer build hook `coworld build` calls (its path is fixed:
# coworld's bundle.py looks for tools/build_replay_viewer.sh and requires it to
# be executable). It hands us an absolute output directory named
# static-replay-viewer and expects a bundle with an index.html in it.
#
# WHAT CHANGED: this used to `docker build --platform linux/amd64 --file
# Dockerfile.replay-viewer`, then `docker create` + `docker cp` the dist out of
# the image. The build is a caos tool now (caos-tools/build-viewer), so the
# bundle is content-addressed and cached — an unchanged tree is a lookup rather
# than a fresh emsdk compile — and it is the SAME bundle `test-viewer` steps
# through in the wasm runtime. Two producers of one artifact was the thing
# worth removing: CI smoke-tested a bundle it built itself, and the upload
# built a second one nobody ran.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
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

CAOS=${CAOS_CLI:-caos-cli}
command -v "${CAOS}" >/dev/null || {
  echo "no ${CAOS} on PATH — enter the dev shell (nix develop) or set CAOS_CLI" >&2
  exit 1
}

cd "${repo_dir}"
# stdout is "<kind> <hash>"; the report goes to stderr, where a person and
# `coworld build`'s own output can both see it.
result="$("${CAOS}" run-tool build-viewer)"
hash="${result##* }"

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
staged="$(mktemp -d)"
"${CAOS}" get "${hash}" "${staged}/result" >/dev/null
[[ -d "${staged}/result/dist" ]] || {
  echo "build-viewer produced no bundle; its report is above" >&2
  exit 1
}
cp -R "${staged}/result/dist/." "${output_dir}/"
rm -rf "${staged}"

test -f "${output_dir}/index.html"
