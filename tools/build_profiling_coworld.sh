#!/usr/bin/env bash
# Build and certify the separate profiling Coworld; see AGENTS.md for runs.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_SOURCES_STAMP=$(tools/sim_sources_stamp.sh)
export GAME_NIM_FLAGS="-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:ProfileTracePath=/tmp/profile-trace.json -d:ProfileTicks=${PROFILE_TICKS:-2400}"
SOFTMAX_TOKEN=$(uv run --python .venv/bin/python softmax get-token)
export SIM_SOURCES_STAMP SOFTMAX_TOKEN
package_dir=build/profiling-coworld
mkdir -p "$package_dir"
version=$(uv run --python .venv/bin/python python - "$package_dir/template.json" <<'PY'
import json
import os
from pathlib import Path
import sys

from coworld.upload import CoworldUploadClient, _submit_replay_viewer_bundle

sys.path.insert(0, "tools/ci")
from next_coworld_version import compute_next, fetch_all_rows

rows = fetch_all_rows(os.environ["SOFTMAX_TOKEN"])
template = json.loads(Path("coworld_manifest_paintbot.json").read_text())
template["game"]["name"] = "paintbot-profiling"
del template["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"]
template["game"]["runnable"]["env"]["COWORLD_WORKDIR"] = "/coworld"
with CoworldUploadClient.from_login(server_url="https://softmax.com/api") as client:
    # Register the existing viewer using the same helper as upload-coworld.
    # Its digest avoids coworld build's automatic source-viewer rebuild.
    template = _submit_replay_viewer_bundle(client, template, Path.cwd())
Path(sys.argv[1]).write_text(json.dumps(template, indent=2) + "\n")
print(compute_next(rows, "paintbot-profiling"))
PY
)

uv run --python .venv/bin/python coworld build \
  --version "$version" --project . --compose compose.yaml \
  --template "$package_dir/template.json" \
  --output "$package_dir/coworld_manifest.json"
uv run --python .venv/bin/python coworld upload-coworld \
  "$package_dir/coworld_manifest.json" --timeout-seconds 900 \
  --wait-hosted-smoke --hosted-smoke-timeout-seconds 1800 \
  --wait-certification --certification-timeout-seconds 1800 \
  | tee "$package_dir/upload.log"
sed -n 's/^Coworld: //p' "$package_dir/upload.log"
