#!/usr/bin/env bash
# tools/stranger_walk/run_container.sh probe <run-id>
# tools/stranger_walk/run_container.sh selftest <run-id>
# tools/stranger_walk/run_container.sh <model> <run-id> [max-budget-usd]
#
# Protocol v1.3: runs the stranger inside its OWN Linux container — own PID
# namespace, own filesystem, own network namespace — instead of a bare
# `claude -p` process on the host. Closes the process-table visibility gap
# Walk 1 found and left open (see docs/designs/STRANGER_WALK.md, "Isolation
# gap found in Walk 1, NOT fixed"): `sonnet-c` ran an ordinary
# `ps aux | grep coworld` and got back the HOST's entire process table,
# because run.sh's isolated-$HOME trick scopes environment variables for
# Bash-tool subprocesses, not the OS-level process list — that is a kernel
# property `$HOME` cannot touch. A container closes it by construction: `ps`
# inside a container with no `--pid=host` can only ever see that container's
# own namespace.
#
# Keeps run.sh's run-dir CONTRACT unchanged: same
# /Users/maxwellstarr/projects/stranger-walk-runs/<run-id>/ layout,
# meta.json, transcript.jsonl, prompt.rendered.md, env — score.py and
# isolation_audit.sh work on a container run's output exactly as they do on
# a run.sh run's, plus isolation_audit.sh also checks this script's
# isolation_probe.json when present (see that script).
#
# Three modes:
#   probe    — run container/probe.sh (isolation self-probe) inside a fresh
#              container and exit. No Anthropic credential needed. This is
#              what PROVES isolation, independent of whether any stranger
#              prompt ever runs.
#   selftest — proves the image itself is built correctly (claude/node/
#              python/git/uv on PATH, invokable) with no network or
#              credential use. Cheap smoke test of the Dockerfile alone.
#   run      — the actual stranger process (real prompt.md, or
#              STRANGER_SMOKE=1 for smoke_prompt.md — same env var run.sh
#              honors, same hard-stop-at-M5 guarantee).
#
# Requires OrbStack or Docker Desktop (`docker version` must succeed).
#
# CREDENTIAL MODEL — deliberately different from run.sh, and the whole
# reason this needs its own auth story: run.sh reuses the HOST's own
# `claude` OAuth session (its top-level process keeps the real $HOME
# specifically so it can authenticate; only the Bash-tool subprocess
# environment gets isolated). A container has NO host $HOME at all — $HOME
# is /home/stranger for every process in it, claude included — so there is
# nothing for claude's own process to authenticate with unless this script
# gives it one. That credential must be THIS RUN'S OWN, never the host's
# ~/.claude:
#   - Source: $STRANGER_ANTHROPIC_API_KEY_FILE (default
#     ~/.ctf/knowledge/stranger-walk/anthropic_api_key — never committed,
#     same convention as run.sh's STRANGER_OWNER_ENV for the site-signup
#     identity). A bare API key, nothing else, one line.
#   - Handling: copied into $RUN_DIR/credential.env (mode 600, a normal
#     `KEY=value` line docker --env-file reads), passed to the container via
#     `docker run --env-file` — never baked into the image, never passed as
#     a `docker run -e` CLI arg (those show up in `docker inspect`/process
#     listings on THIS host more readily than an env-file's contents do),
#     never the host's ~/.claude directory mounted in any form.
#   - No fallback: if the credential file is absent, this script REFUSES to
#     launch a `run`-mode container. There is no silent "reuse whatever
#     `claude` is already authenticated as" path — that path is exactly what
#     caused the 2026-09-09 real-ladder-submission incident (see
#     docs/designs/STRANGER_WALK.md's Incident section) for third-party CLI
#     credential stores, and a container makes the SAME mistake worse (it
#     would require mounting host state wholesale, not just leaving env
#     vars ambient).
#   `probe` and `selftest` modes need no credential at all and skip this
#   check entirely.
set -euo pipefail

MODE_OR_MODEL="${1:?usage: run_container.sh probe^|selftest^|MODEL RUN_ID MAX_BUDGET_USD_optional}"
RUN_ID="${2:?usage: run_container.sh probe^|selftest^|MODEL RUN_ID MAX_BUDGET_USD_optional}"
MAX_BUDGET_USD="${3:-25}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CONTAINER_DIR="$SCRIPT_DIR/container"
ENTRY_URL="${STRANGER_ENTRY_URL:-https://softmax.com/paintbot}"
IMAGE_TAG="${STRANGER_IMAGE_TAG:-stranger-walk:v1.3}"

RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"
RUN_DIR="$RUNS_PARENT/$RUN_ID"
mkdir -p "$RUN_DIR"

command -v docker >/dev/null 2>&1 || { echo "docker not found — install OrbStack/Docker Desktop" >&2; exit 1; }
docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (\`docker version\` failed)" >&2; exit 1; }

# Run the container as the INVOKING HOST USER's own uid:gid, never root.
# Two independent reasons, found empirically while building this:
#   1. `claude`'s own `--permission-mode bypassPermissions` (required for any
#      non-interactive `-p` run — there is no TTY to approve prompts)
#      refuses to start as root/sudo: "--dangerously-skip-permissions cannot
#      be used with root/sudo privileges for security reasons". A
#      root-in-container stranger simply cannot run at all.
#   2. It happens to sidestep a uid-mismatch problem for free: the run dir
#      ($RUN_DIR) is bind-mounted at /home/stranger and was created by THIS
#      script under the operator's own uid/gid — running the container as
#      that exact uid:gid means it can read/write its own run dir with no
#      chmod, no dedicated fixed-uid user baked into the image, and no
#      `--user 0` "root inside is fine, it's namespaced" caveat to document.
HOST_UID_GID="$(id -u):$(id -g)"

echo "[$RUN_ID] building image $IMAGE_TAG from $CONTAINER_DIR ..." >&2
docker build -q -t "$IMAGE_TAG" "$CONTAINER_DIR" > "$RUN_DIR/docker-build.log" 2>&1 \
  || { echo "[$RUN_ID] docker build FAILED — see $RUN_DIR/docker-build.log" >&2; tail -40 "$RUN_DIR/docker-build.log" >&2; exit 1; }
echo "[$RUN_ID] image built." >&2

CONTAINER_NAME="stranger-walk-$RUN_ID-$(date +%s)"

if [ "$MODE_OR_MODEL" = "probe" ] || [ "$MODE_OR_MODEL" = "selftest" ]; then
  MODE="$MODE_OR_MODEL"
  RESULT_PATH="/home/stranger/isolation_probe.json"
  echo "[$RUN_ID] running mode=$MODE (no credential needed) ..." >&2
  set +e
  docker run --rm \
    --name "$CONTAINER_NAME" \
    --hostname stranger \
    --network bridge \
    --pids-limit 512 \
    --user "$HOST_UID_GID" \
    -e HOME=/home/stranger \
    -e STRANGER_CONTAINER_MODE="$MODE" \
    -v "$RUN_DIR:/home/stranger" \
    -w /home/stranger \
    "$IMAGE_TAG" "$RESULT_PATH" \
    > "$RUN_DIR/$MODE.stdout.log" 2> "$RUN_DIR/$MODE.stderr.log"
  EXIT_CODE=$?
  set -e
  echo "[$RUN_ID] mode=$MODE exit=$EXIT_CODE — logs: $RUN_DIR/$MODE.std{out,err}.log" >&2
  if [ "$MODE" = "probe" ]; then
    echo "[$RUN_ID] probe result: $RUN_DIR/isolation_probe.json" >&2
  fi
  exit "$EXIT_CODE"
fi

MODEL="$MODE_OR_MODEL"

if [ -e "$RUN_DIR/meta.json" ]; then
  echo "refusing to overwrite existing run: $RUN_DIR" >&2
  exit 1
fi

CRED_SRC="${STRANGER_ANTHROPIC_API_KEY_FILE:-$HOME/.ctf/knowledge/stranger-walk/anthropic_api_key}"
if [ ! -f "$CRED_SRC" ]; then
  echo "[$RUN_ID] no Anthropic API key at $CRED_SRC — refusing to launch a 'run'-mode container." >&2
  echo "[$RUN_ID] container auth must be THIS RUN'S OWN credential, never the host's ~/.claude — see this script's header." >&2
  echo "[$RUN_ID] set STRANGER_ANTHROPIC_API_KEY_FILE to a file containing one Anthropic API key, or run 'probe'/'selftest' instead." >&2
  exit 1
fi
CRED_ENV_FILE="$RUN_DIR/credential.env"
printf 'ANTHROPIC_API_KEY=%s\n' "$(cat "$CRED_SRC")" > "$CRED_ENV_FILE"
chmod 600 "$CRED_ENV_FILE"

if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
  SOURCE_PROMPT="$SCRIPT_DIR/smoke_prompt.md"
else
  SOURCE_PROMPT="$SCRIPT_DIR/prompt.md"
fi
PROMPT_SHA256="$(shasum -a 256 "$SOURCE_PROMPT" | awk '{print $1}')"
sed "s#{{ENTRY_URL}}#$ENTRY_URL#g" "$SOURCE_PROMPT" > "$RUN_DIR/prompt.rendered.md"

ENTRY_RESOLVED="$(curl -sS -o /dev/null -w '%{http_code} %{url_effective}' -L --max-time 15 "$ENTRY_URL" || echo "CURL_FAILED")"

OWNER_ENV_SRC="${STRANGER_OWNER_ENV:-$HOME/.ctf/knowledge/stranger-walk/env}"
HAD_OWNER_ENV="false"
if [ "${STRANGER_SMOKE:-0}" != "1" ] && [ -f "$OWNER_ENV_SRC" ]; then
  cp "$OWNER_ENV_SRC" "$RUN_DIR/env"
  chmod 600 "$RUN_DIR/env"
  HAD_OWNER_ENV="true"
fi

PAINTBOT_TAGS_AT_MAIN="$(git -C "$REPO_ROOT" tag --points-at origin/main --list 'paintbot-v*' 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
LATEST_PAINTBOT_TAG="$(git -C "$REPO_ROOT" tag --list 'paintbot-v*' --sort=-v:refname 2>/dev/null | head -1)"
GLORY_VERSION="$(grep -m1 -oE 'GloryVersion\*? = [0-9]+' "$REPO_ROOT/src/ctf/glory.nim" 2>/dev/null | grep -oE '[0-9]+$' || echo "unknown")"

START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"

STRANGER_TOOLS="Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch"

python3 - "$RUN_DIR/meta.json" <<PYEOF
import json, sys
meta = {
    "run_id": "$RUN_ID",
    "model": "$MODEL",
    "isolation_mode": "container",
    "image_tag": "$IMAGE_TAG",
    "prompt_sha256": "$PROMPT_SHA256",
    "entry_url_template": "$ENTRY_URL",
    "entry_url_resolved": "$ENTRY_RESOLVED",
    "paintbot_tags_at_origin_main": "$PAINTBOT_TAGS_AT_MAIN".split(",") if "$PAINTBOT_TAGS_AT_MAIN" else [],
    "latest_paintbot_tag_anywhere": "$LATEST_PAINTBOT_TAG",
    "glory_version": "$GLORY_VERSION",
    "stranger_tools": "$STRANGER_TOOLS".split(","),
    "max_budget_usd": $MAX_BUDGET_USD,
    "had_owner_env": $( [ "$HAD_OWNER_ENV" = "true" ] && echo True || echo False ),
    "smoke": $( [ "${STRANGER_SMOKE:-0}" = "1" ] && echo True || echo False ),
    "browser_enabled": False,
    "start_iso": "$START_ISO",
    "start_epoch": $START_EPOCH,
}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
PYEOF

echo "[$RUN_ID] model=$MODEL entry=$ENTRY_URL resolved=[$ENTRY_RESOLVED] glory=$GLORY_VERSION isolation=container" >&2

DOCKER_RUN_ARGS=(
  run -d --name "$CONTAINER_NAME"
  --hostname stranger
  --network bridge
  --pids-limit 512
  --memory 2g
  --cpus 2
  --user "$HOST_UID_GID"
  --env-file "$CRED_ENV_FILE"
  -e HOME=/home/stranger
  -e MODEL="$MODEL"
  -e STRANGER_TOOLS="$STRANGER_TOOLS"
  -e MAX_BUDGET_USD="$MAX_BUDGET_USD"
  -e STRANGER_CONTAINER_MODE=run
  -v "$RUN_DIR:/home/stranger"
  -w /home/stranger
)
if [ "${STRANGER_ENABLE_DOCKER_SOCKET:-0}" = "1" ]; then
  echo "[$RUN_ID] WARNING: --enable-docker-socket is ON. Mounting /var/run/docker.sock gives this" >&2
  echo "[$RUN_ID]   container root-equivalent control of the HOST's docker daemon — it can create," >&2
  echo "[$RUN_ID]   exec into, and bind-mount arbitrary host paths into ANY container on this host," >&2
  echo "[$RUN_ID]   which is a full isolation escape, not a scoped grant. Only use this if the" >&2
  echo "[$RUN_ID]   stranger genuinely needs to build a policy image; see docs/designs/STRANGER_WALK.md v1.3." >&2
  DOCKER_RUN_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi
DOCKER_RUN_ARGS+=("$IMAGE_TAG")

CONTAINER_ID="$(docker "${DOCKER_RUN_ARGS[@]}")"
echo "$CONTAINER_ID" > "$RUN_DIR/container.id"
echo "[$RUN_ID] container launched: $CONTAINER_ID (name=$CONTAINER_NAME)" >&2
echo "[$RUN_ID] this container is managed by dockerd, independent of this script's own process —" >&2
echo "[$RUN_ID] it survives this script (or the session that called it) dying, same v1.2 guarantee" >&2
echo "[$RUN_ID] launch.sh already gives run.sh, with a second, independent layer underneath it." >&2

# Block until the container exits — same shape as run.sh's synchronous
# `claude -p ...` call. `tools/stranger_walk/launch.sh run_container.sh
# <model> <run-id>` detaches THIS script exactly like it already detaches
# run.sh today; no changes to launch.sh were needed.
set +e
docker wait "$CONTAINER_ID" > "$RUN_DIR/container.exit_code" 2> "$RUN_DIR/docker-wait.stderr.log"
EXIT_CODE="$(tr -d '[:space:]' < "$RUN_DIR/container.exit_code" 2>/dev/null || echo 1)"
[ -n "$EXIT_CODE" ] || EXIT_CODE=1
set -e

docker logs "$CONTAINER_ID" > "$RUN_DIR/container.stdout.log" 2> "$RUN_DIR/container.stderr.log" || true
docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true

END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
END_EPOCH="$(date +%s)"

python3 - "$RUN_DIR/meta.json" <<PYEOF
import json
p = "$RUN_DIR/meta.json"
meta = json.load(open(p))
meta["end_iso"] = "$END_ISO"
meta["end_epoch"] = $END_EPOCH
meta["wall_clock_seconds"] = $END_EPOCH - meta["start_epoch"]
meta["exit_code"] = $EXIT_CODE

session_id = None
last_text = ""
try:
    with open("$RUN_DIR/transcript.jsonl") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            if ev.get("type") == "system" and ev.get("subtype") == "init":
                session_id = ev.get("session_id")
            if ev.get("type") == "assistant":
                for block in ev.get("message", {}).get("content", []) or []:
                    if block.get("type") == "text":
                        last_text = block.get("text", "")
except FileNotFoundError:
    pass

meta["session_id"] = session_id
waiting = any(l.strip().startswith("WAITING:") for l in last_text.splitlines())
meta["run_status"] = "waiting_on_code" if waiting else "completed"
json.dump(meta, open(p, "w"), indent=2)
PYEOF

RUN_STATUS="$(python3 -c "import json; print(json.load(open('$RUN_DIR/meta.json'))['run_status'])")"
echo "[$RUN_ID] done. exit=$EXIT_CODE wall_clock=$((END_EPOCH - START_EPOCH))s status=$RUN_STATUS" >&2
echo "[$RUN_ID] transcript: $RUN_DIR/transcript.jsonl" >&2

if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
  LOGIN_HITS="$(python3 -c "
import json, re
pat = re.compile(r'softmax login|coworld submit|upload-policy|exchange-code')
try:
    f = open('$RUN_DIR/transcript.jsonl')
except FileNotFoundError:
    raise SystemExit
for line in f:
    line = line.strip()
    if not line:
        continue
    ev = json.loads(line)
    if ev.get('type') != 'assistant':
        continue
    for block in ev.get('message', {}).get('content', []) or []:
        if block.get('type') == 'tool_use' and block.get('name') == 'Bash':
            cmd = (block.get('input', {}) or {}).get('command', '')
            if pat.search(cmd):
                print(cmd)
" 2>/dev/null || true)"
  if [ -n "$LOGIN_HITS" ]; then
    echo "[$RUN_ID] SMOKE GUARD WARNING: login/upload/submit command(s) actually run in a smoke test:" >&2
    echo "$LOGIN_HITS" | sed 's/^/  /' >&2
  else
    echo "[$RUN_ID] smoke guard: PASS — no login/upload/submit command was run" >&2
  fi
fi

exit "$EXIT_CODE"
