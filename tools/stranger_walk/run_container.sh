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
# ~/.claude, resolved in this order (v1.4, 2026-09-09 owner ruling):
#   (a) an Anthropic API key at $STRANGER_ANTHROPIC_API_KEY_FILE (default
#       ~/.ctf/knowledge/stranger-walk/anthropic_api_key — never committed,
#       same convention as run.sh's STRANGER_OWNER_ENV for the site-signup
#       identity). A bare API key, nothing else, one line. Copied into
#       $RUN_DIR/credential.env (mode 600, a normal `KEY=value` line docker
#       --env-file reads), passed to the container via `docker run
#       --env-file` — never baked into the image, never a `docker run -e`
#       CLI arg (those show up in `docker inspect`/process listings on THIS
#       host more readily than an env-file's contents do).
#   (b) else, the HOST's own Claude Code login. On THIS host that is not a
#       file under ~/.claude at all (checked 2026-09-09, absent) — Claude
#       Code here stores its OAuth session in the macOS Keychain, service
#       "Claude Code-credentials". Extracted via `security
#       find-generic-password -s "Claude Code-credentials" -w` piped
#       DIRECTLY to a file (never through a shell variable/echo) at
#       $RUN_DIR/.claude/.credentials.json (mode 600) — the exact relative
#       path Claude Code reads as its Linux/non-Keychain credential store,
#       which is why this authenticates inside the container. Owner-
#       authorized 2026-09-09 with two guards: (1) that file lives under
#       $RUN_DIR (bind-mounted at /home/stranger); the stranger's own
#       working directory is a SEPARATE bind mount at /workspace (see
#       WORKSPACE_DIR below) — never an ancestor of /home/stranger and never
#       contained by it — so no `docker build .` / `tar czf policy.tar.gz .`
#       from the stranger's cwd can sweep this file in by construction.
#       (2) isolation_audit.sh gained two new checks (via
#       tools/stranger_walk/credential_scan.py): a substring search of every
#       run artifact for the credential's own value (reported by SHA256
#       fingerprint + PASS/FAIL only — the value itself is never printed
#       anywhere), and a `docker save` + tar-layer scan of any docker image
#       the run built (relevant only if --enable-docker-socket was used;
#       N/A/PASS by construction otherwise, since the container can't reach
#       a docker daemon by default). This credential is a LIVE, shared
#       login — the same one Walk 1's host-mode `run.sh` runs already
#       executed under (a macOS Keychain session is per-user, not per-run),
#       and the same one other agents on this machine may be using
#       concurrently. The owner can invalidate it at any time by signing out
#       of Claude Code and back in — every run authenticated with it stops
#       working immediately.
#   No further fallback: if neither (a) nor (b) is resolvable, this script
#   REFUSES to launch a `run`-mode container — there is no silent "reuse
#   whatever `claude` is already authenticated as via some other path." That
#   silent-reuse path is exactly what caused the 2026-09-09
#   real-ladder-submission incident (see docs/designs/STRANGER_WALK.md's
#   Incident section) for third-party CLI credential stores.
#   `probe` and `selftest` modes need no credential at all and skip this
#   check entirely.
set -euo pipefail

# --dry-run (protocol v2, 2026-09-09): for `run`-mode only (probe/selftest
# don't take a credential and aren't gated). Validates the prompt
# contamination gate, renders the prompt, and checks for the Anthropic
# credential file WITHOUT requiring Docker, building an image, or starting a
# container — so the credential-absent refusal (below) can be demonstrated
# on a box that doesn't even have Docker running. Never mints or reads the
# credential file's contents.
DRY_RUN=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--dry-run" ]; then
    DRY_RUN=1
  else
    ARGS+=("$a")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

MODE_OR_MODEL="${1:?usage: run_container.sh probe^|selftest^|MODEL RUN_ID MAX_BUDGET_USD_optional [--dry-run]}"
RUN_ID="${2:?usage: run_container.sh probe^|selftest^|MODEL RUN_ID MAX_BUDGET_USD_optional [--dry-run]}"
MAX_BUDGET_USD="${3:-25}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CONTAINER_DIR="$SCRIPT_DIR/container"
ENTRY_URL="${STRANGER_ENTRY_URL:-https://softmax.com/paintbot}"
IMAGE_TAG="${STRANGER_IMAGE_TAG:-stranger-walk:v1.6}"

# Protocol v2 contamination gate — see run.sh's identical check and
# check_prompt.py's own header. Runs before anything else, dry-run or not.
if ! python3 "$SCRIPT_DIR/check_prompt.py" "$SCRIPT_DIR/prompt.md" >&2; then
  echo "[$RUN_ID] REFUSING TO LAUNCH: prompt.md failed the Protocol v2 contamination gate (see above)." >&2
  exit 1
fi

if [ "$DRY_RUN" = "1" ] && [ "$MODE_OR_MODEL" != "probe" ] && [ "$MODE_OR_MODEL" != "selftest" ]; then
  MODEL="$MODE_OR_MODEL"
  if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
    SOURCE_PROMPT="$SCRIPT_DIR/smoke_prompt.md"
  else
    SOURCE_PROMPT="$SCRIPT_DIR/prompt.md"
  fi
  PROMPT_SHA256="$(shasum -a 256 "$SOURCE_PROMPT" | awk '{print $1}')"
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH"' EXIT
  python3 "$SCRIPT_DIR/check_prompt.py" --show-body "$SOURCE_PROMPT" \
    | sed "s#{{ENTRY_URL}}#$ENTRY_URL#g" > "$SCRATCH/prompt.rendered.md"
  echo "[$RUN_ID] DRY RUN (container) — docker not invoked, no run dir written." >&2
  echo "[$RUN_ID]   model=$MODEL image_tag=$IMAGE_TAG" >&2
  echo "[$RUN_ID]   source_prompt=$SOURCE_PROMPT (sha256=$PROMPT_SHA256)" >&2
  echo "[$RUN_ID]   rendered body ($(wc -l < "$SCRATCH/prompt.rendered.md" | tr -d ' ') lines) begins:" >&2
  head -3 "$SCRATCH/prompt.rendered.md" | sed 's/^/[dry-run]   | /' >&2
  echo "[$RUN_ID]   \$HOME inside the container is /home/stranger by construction (own filesystem namespace — no host \$HOME to leak, unlike run.sh's env-scoping trick)." >&2
  echo "[$RUN_ID]   would docker run: --user \$(id -u):\$(id -g) --network container:stranger-walk-dind-$RUN_ID -e DOCKER_HOST=tcp://127.0.0.1:2375 -v <run-dir>:/home/stranger -v <run-dir>/workspace:/workspace -w /workspace -e MODEL=$MODEL $IMAGE_TAG" >&2
  echo "[$RUN_ID]   would also start a per-run docker-in-docker sidecar (stranger-walk-dind-$RUN_ID) sharing its network namespace (v1.6) and its <run-dir>/workspace mount — see start_sidecar in this script's header." >&2
  echo "[$RUN_ID]   NOTE (v1.4): browser is wired via @playwright/mcp, same mechanism run.sh uses on the host — see mcp-config.json below." >&2
  CRED_SRC="${STRANGER_ANTHROPIC_API_KEY_FILE:-$HOME/.ctf/knowledge/stranger-walk/anthropic_api_key}"
  if [ -f "$CRED_SRC" ]; then
    echo "[$RUN_ID] credential option (a): Anthropic API key file present at $CRED_SRC (contents never read/printed by dry-run) — a real launch would proceed." >&2
  elif security find-generic-password -s "${STRANGER_HOST_CLAUDE_KEYCHAIN_SERVICE:-Claude Code-credentials}" >/dev/null 2>&1; then
    echo "[$RUN_ID] credential option (a) absent ($CRED_SRC not found); option (b) available: host Claude Code login in the macOS Keychain (service \"${STRANGER_HOST_CLAUDE_KEYCHAIN_SERVICE:-Claude Code-credentials}\") — a real launch would extract and use it (see this script's header for the guards)." >&2
  else
    echo "[$RUN_ID] REFUSING TO LAUNCH: no Anthropic API key at $CRED_SRC and no host Claude Code Keychain login found." >&2
    echo "[$RUN_ID] container auth must be THIS RUN'S OWN credential — see this script's header." >&2
    exit 1
  fi
  exit 0
fi

RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"
RUN_DIR="$RUNS_PARENT/$RUN_ID"
# v1.4 guard #1: the stranger's own working directory is a SEPARATE bind
# mount at /workspace, never an ancestor of /home/stranger (=$RUN_DIR) and
# never contained by it — so a `docker build .` / `tar czf x.tar.gz .` run
# from the stranger's own cwd cannot sweep in $RUN_DIR/.claude/.credentials.json
# (the host_claude_login credential, when that's the resolved option — see
# this script's header) or anything else under $RUN_DIR. Verified by
# construction: two independent bind mounts, container-side paths /workspace
# and /home/stranger are siblings under /, neither contains the other.
WORKSPACE_DIR="$RUN_DIR/workspace"
mkdir -p "$RUN_DIR" "$WORKSPACE_DIR"

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

# v1.5: each run gets its OWN isolated Docker — a docker-in-docker sidecar
# container with its own daemon and ephemeral storage, on the run's own
# private network, never the host's docker socket. Found 2026-09-09
# (triaging sonnet-before-1, v1.4): no daemon was reachable inside the
# container at all (no root, no userns, `newuidmap` missing — the
# `docker.io` CLIENT was there, but nothing gave it a daemon to talk to),
# so the stranger could not build its policy image the documented way and
# hand-rolled an OCI pusher plus a from-scratch WebSocket client instead —
# the builder hallway cannot be measured like that.
DIND_IMAGE="${STRANGER_DIND_IMAGE:-docker:27-dind}"

# v1.6: TWO independent DinD traps, found by reproducing the documented local
# test (`coworld run-episode`) inside a v1.5 sandbox+sidecar pair — see
# docs/designs/STRANGER_WALK.md's v1.6 section for the full repro.
#   Trap A — bind-mount source resolution: `coworld run-episode` (running
#     INSIDE the sandbox, cwd /workspace) launches the game container via
#     `docker run -v <workspace-path>:/coworld ...` against DOCKER_HOST (the
#     sidecar). A `-v host:container` bind mount is resolved on the DAEMON's
#     own filesystem, not the API client's — the sidecar had no /workspace at
#     all, so the mount silently attached an empty directory and the game
#     binary died with `cannot open: /coworld/config.json [IOError]`. Fixed by
#     bind-mounting the SAME host directory ($WORKSPACE_DIR) at the SAME
#     container path (/workspace) into the sidecar too, via start_sidecar's
#     new $4 — never $RUN_DIR (=/home/stranger, where a host_claude_login
#     credential can live); only the workspace half of guard #1's split ever
#     reaches the sidecar.
#   Trap B — published-port reachability: `coworld run-episode` health-checks
#     its game container at a hardcoded `http://127.0.0.1:<port>/healthz`
#     (coworld/runner/runner.py — third-party package, not ours to patch)
#     called from the SANDBOX process, after asking the SIDECAR's daemon to
#     publish that port on `127.0.0.1` — two different loopbacks when sandbox
#     and sidecar are separate network namespaces on a bridge network. Fixed
#     by giving the sandbox `--network container:<sidecar>` instead of its
#     own bridge address: it then shares the sidecar's network namespace (so
#     127.0.0.1 is the same loopback on both sides) without inheriting the
#     sidecar's --privileged capabilities, mount namespace, or pid namespace
#     — only the network stack is shared. `--hostname` cannot be set together
#     with `--network container:...` (docker rejects the combination), so
#     callers that switch to this mode must drop `--hostname stranger` too.
start_sidecar() {
  # $1 = run_id, $2 = network name, $3 = sidecar container name, $4 = host
  # workspace dir to ALSO bind-mount at /workspace in the sidecar (optional —
  # omit for callers that never launch a game container through it, e.g. a
  # bare isolation probe). See the v1.6 header above for why this exists.
  # --privileged is required for a nested dockerd to run at all (it needs
  # kernel capabilities a normal container doesn't get); DOCKER_TLS_CERTDIR=
  # (empty) skips the dind entrypoint's TLS cert generation so the inner
  # daemon just listens on plain TCP — acceptable here because this daemon
  # is reachable ONLY from this run's own private network, never the host
  # or any other run.
  docker network create "$2" >/dev/null
  local workspace_mount=()
  if [ -n "${4:-}" ]; then
    workspace_mount=(-v "$4:/workspace")
  fi
  docker run -d --name "$3" --network "$2" --network-alias dockerd \
    --privileged \
    -e DOCKER_TLS_CERTDIR= \
    "${workspace_mount[@]+"${workspace_mount[@]}"}" \
    "$DIND_IMAGE" --host=tcp://0.0.0.0:2375 >/dev/null
  local tries=0
  until docker exec "$3" docker version >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
      echo "[$1] sidecar docker daemon never became ready (waited 60s)" >&2
      return 1
    fi
    sleep 1
  done
  echo "[$1] sidecar docker daemon ready: $3 on network $2" >&2
}

stop_sidecar_and_scan() {
  # $1 = run_dir, $2 = sidecar container name. Persists a `docker save` of
  # every image the sidecar ever held to a LOCAL tar file under
  # $RUN_DIR/sidecar_images/ BEFORE removing the sidecar — its storage is
  # ephemeral by design (see header), so this is the only chance to keep
  # anything isolation_audit.sh can later scan (possibly long after this
  # run, and this run's sidecar, are both gone).
  local run_dir="$1" sidecar="$2"
  mkdir -p "$run_dir/sidecar_images"
  local img
  for img in $(docker exec "$sidecar" docker images -q 2>/dev/null | sort -u); do
    docker exec "$sidecar" docker save "$img" > "$run_dir/sidecar_images/$img.tar" 2>/dev/null || true
  done
  docker rm -f "$sidecar" >/dev/null 2>&1 || true
}

echo "[$RUN_ID] building image $IMAGE_TAG from $CONTAINER_DIR ..." >&2
docker build -q -t "$IMAGE_TAG" "$CONTAINER_DIR" > "$RUN_DIR/docker-build.log" 2>&1 \
  || { echo "[$RUN_ID] docker build FAILED — see $RUN_DIR/docker-build.log" >&2; tail -40 "$RUN_DIR/docker-build.log" >&2; exit 1; }
echo "[$RUN_ID] image built." >&2

CONTAINER_NAME="stranger-walk-$RUN_ID-$(date +%s)"

if [ "$MODE_OR_MODEL" = "probe" ] || [ "$MODE_OR_MODEL" = "selftest" ]; then
  MODE="$MODE_OR_MODEL"
  RESULT_PATH="/home/stranger/isolation_probe.json"
  NETWORK_NAME="stranger-walk-net-$RUN_ID"
  SIDECAR_NAME="stranger-walk-dind-$RUN_ID"
  NETWORK_ARGS=(--network bridge)
  HOSTNAME_ARGS=(--hostname stranger)
  WORKSPACE_MOUNT_ARGS=()
  if [ "$MODE" = "selftest" ]; then
    # selftest (unlike probe) must prove `docker build`+`docker run` really
    # work through the same per-run sidecar a real run gets, AND (v1.6) that
    # a real `coworld run-episode` completes through it — see
    # entrypoint.sh's docker build+run check and its v1.6 episode check.
    echo "[$RUN_ID] starting isolated docker-in-docker sidecar for selftest ..." >&2
    start_sidecar "$RUN_ID" "$NETWORK_NAME" "$SIDECAR_NAME" "$WORKSPACE_DIR" || { echo "[$RUN_ID] sidecar setup FAILED" >&2; exit 1; }
    # v1.6 Trap B fix (see start_sidecar's header) — share the sidecar's own
    # network namespace so 127.0.0.1 means the same thing on both sides;
    # --hostname cannot be combined with --network container:.
    NETWORK_ARGS=(--network "container:$SIDECAR_NAME" -e DOCKER_HOST=tcp://127.0.0.1:2375)
    HOSTNAME_ARGS=()
    # v1.6 Trap A fix (see start_sidecar's header) — same host dir at the
    # same container path (/workspace) in both the sandbox and the sidecar.
    WORKSPACE_MOUNT_ARGS=(-v "$WORKSPACE_DIR:/workspace")
  fi
  echo "[$RUN_ID] running mode=$MODE (no credential needed) ..." >&2
  set +e
  docker run --rm \
    --name "$CONTAINER_NAME" \
    "${HOSTNAME_ARGS[@]+"${HOSTNAME_ARGS[@]}"}" \
    "${NETWORK_ARGS[@]+"${NETWORK_ARGS[@]}"}" \
    --pids-limit 512 \
    --user "$HOST_UID_GID" \
    -e HOME=/home/stranger \
    -e STRANGER_CONTAINER_MODE="$MODE" \
    -v "$RUN_DIR:/home/stranger" \
    "${WORKSPACE_MOUNT_ARGS[@]+"${WORKSPACE_MOUNT_ARGS[@]}"}" \
    -w /home/stranger \
    "$IMAGE_TAG" "$RESULT_PATH" \
    > "$RUN_DIR/$MODE.stdout.log" 2> "$RUN_DIR/$MODE.stderr.log"
  EXIT_CODE=$?
  set -e
  if [ "$MODE" = "selftest" ]; then
    docker rm -f "$SIDECAR_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  fi
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

# v1.4 credential resolution: (a) Anthropic API key file, else (b) the
# host's Claude Code login (owner-authorized 2026-09-09 — see this script's
# header for the full guard rationale). CRED_MODE records which was used;
# CRED_ENV_FILE is only set for (a).
CRED_SRC="${STRANGER_ANTHROPIC_API_KEY_FILE:-$HOME/.ctf/knowledge/stranger-walk/anthropic_api_key}"
CRED_MODE=""
CRED_ENV_FILE=""
if [ -f "$CRED_SRC" ]; then
  CRED_MODE="anthropic_api_key"
  CRED_ENV_FILE="$RUN_DIR/credential.env"
  printf 'ANTHROPIC_API_KEY=%s\n' "$(cat "$CRED_SRC")" > "$CRED_ENV_FILE"
  chmod 600 "$CRED_ENV_FILE"
  echo "[$RUN_ID] credential option (a): Anthropic API key from $CRED_SRC" >&2
else
  KEYCHAIN_SERVICE="${STRANGER_HOST_CLAUDE_KEYCHAIN_SERVICE:-Claude Code-credentials}"
  if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    CRED_MODE="host_claude_login"
    mkdir -p "$RUN_DIR/.claude"
    chmod 700 "$RUN_DIR/.claude"
    # Piped straight to a file — never through a shell variable, never
    # echoed — see this script's header for the full guard rationale.
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w > "$RUN_DIR/.claude/.credentials.json"
    chmod 600 "$RUN_DIR/.claude/.credentials.json"
    CRED_SHA256="$(shasum -a 256 "$RUN_DIR/.claude/.credentials.json" | awk '{print $1}')"
    KEYCHAIN_ACCOUNT="$(id -un)"
    python3 - "$RUN_DIR/credential_meta.json" "$CRED_SHA256" "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" <<'PYEOF'
import json, sys
out = {
    "credential_source": "host_claude_login",
    "credential_sha256": sys.argv[2],
    "keychain_service": sys.argv[3],
    "keychain_account": sys.argv[4],
    "note": "value never stored in this file or printed anywhere; see isolation_audit.sh's credential leak check",
}
with open(sys.argv[1], "w") as f:
    json.dump(out, f, indent=2)
PYEOF
    echo "[$RUN_ID] credential option (b): host Claude Code login, macOS Keychain service \"$KEYCHAIN_SERVICE\" account \"$KEYCHAIN_ACCOUNT\" (sha256=$CRED_SHA256, value never printed)" >&2
  else
    echo "[$RUN_ID] no Anthropic API key at $CRED_SRC and no host Claude Code Keychain login found — refusing to launch a 'run'-mode container." >&2
    echo "[$RUN_ID] container auth must be THIS RUN'S OWN credential — see this script's header." >&2
    exit 1
  fi
fi

if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
  SOURCE_PROMPT="$SCRIPT_DIR/smoke_prompt.md"
else
  SOURCE_PROMPT="$SCRIPT_DIR/prompt.md"
fi
PROMPT_SHA256="$(shasum -a 256 "$SOURCE_PROMPT" | awk '{print $1}')"
python3 "$SCRIPT_DIR/check_prompt.py" --show-body "$SOURCE_PROMPT" \
  | sed "s#{{ENTRY_URL}}#$ENTRY_URL#g" > "$RUN_DIR/prompt.rendered.md"

ENTRY_RESOLVED="$(curl -sS -o /dev/null -w '%{http_code} %{url_effective}' -L --max-time 15 "$ENTRY_URL" || echo "CURL_FAILED")"

# Site-signup identity (GITHUB_USER/GITHUB_PASS/STRANGER_EMAIL) goes into
# the stranger's own WORKSPACE, not $RUN_DIR/home — prompt.md tells the
# stranger to check "your own working directory (`.` — the directory you
# were launched in)" for a file named `env`, and the stranger's cwd is
# /workspace (see WORKSPACE_DIR / guard #1 above), not /home/stranger.
OWNER_ENV_SRC="${STRANGER_OWNER_ENV:-$HOME/.ctf/knowledge/stranger-walk/env}"
HAD_OWNER_ENV="false"
if [ "${STRANGER_SMOKE:-0}" != "1" ] && [ -f "$OWNER_ENV_SRC" ]; then
  cp "$OWNER_ENV_SRC" "$WORKSPACE_DIR/env"
  chmod 600 "$WORKSPACE_DIR/env"
  HAD_OWNER_ENV="true"
fi

# v1.4: real browser for official (non-smoke) runs, mirroring run.sh's own
# --mcp-config wiring (same @playwright/mcp server, fresh --user-data-dir
# per run). Config is written to a FILE in $RUN_DIR (not a docker -e CLI
# arg) so entrypoint.sh can reference it with --mcp-config, avoiding any
# JSON-through-docker-run-e quoting hazard.
STRANGER_BROWSER="${STRANGER_BROWSER:-$( [ "${STRANGER_SMOKE:-0}" = "1" ] && echo 0 || echo 1 )}"
COOKIE_PRECHECK="not_applicable (no browser for this run)"
if [ "$STRANGER_BROWSER" = "1" ]; then
  mkdir -p "$RUN_DIR/.playwright-profile"
  COOKIES_DB="$RUN_DIR/.playwright-profile/Default/Cookies"
  COOKIE_HITS=0
  if [ -f "$COOKIES_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    COOKIE_HITS="$(sqlite3 "$COOKIES_DB" "select count(*) from cookies where host_key like '%softmax.com%' or host_key like '%google.com%' or host_key like '%github.com%';" 2>/dev/null || echo 0)"
  fi
  if [ "$COOKIE_HITS" != "0" ]; then
    echo "[$RUN_ID] REFUSING TO LAUNCH: playwright profile at $RUN_DIR/.playwright-profile already has $COOKIE_HITS softmax/google/github cookie(s) — not a fresh profile" >&2
    exit 1
  fi
  COOKIE_PRECHECK="verified pre-launch: 0 cookies for softmax.com/google.com/github.com in $RUN_DIR/.playwright-profile"
  # v1.5 fix: triaging sonnet-before-1 (v1.4) found the stranger's browser
  # tool failing every real navigation with "Chromium distribution 'chrome'
  # is not found at /opt/google/chrome/chrome" — @playwright/mcp's default
  # --browser channel is the SYSTEM "chrome" (a real Google Chrome install),
  # not the playwright-managed Chromium this image actually installs (see
  # Dockerfile's PLAYWRIGHT_BROWSERS_PATH). --browser chromium pins it to
  # the bundled one. The selftest's MCP probe (mcp_probe.py, see
  # entrypoint.sh) launches the identical command/args, so this exact
  # mismatch is caught before a real run ever hits it again.
  python3 -c "
import json
print(json.dumps({'mcpServers': {'playwright': {
    'command': 'npx',
    'args': ['--yes', '@playwright/mcp@latest', '--headless', '--browser', 'chromium', '--user-data-dir', '/home/stranger/.playwright-profile']
}}}))
" > "$RUN_DIR/mcp-config.json"
fi

# Legacy v1.4 host-docker-socket opt-in — off by default, superseded by
# the always-on per-run sidecar below, kept only so an explicit
# STRANGER_ENABLE_DOCKER_SOCKET=1 invocation still tracks its own images
# the old way. New runs get docker access via the sidecar regardless.
ENABLE_DOCKER_SOCKET="${STRANGER_ENABLE_DOCKER_SOCKET:-0}"
if [ "$ENABLE_DOCKER_SOCKET" = "1" ]; then
  docker images -q | sort -u > "$RUN_DIR/docker_images_before.txt" || true
fi

# v1.5: this run's own isolated Docker — see start_sidecar's header above
# for the full rationale (no host daemon was reachable at all before this,
# so a stranger could not build its policy image the documented way).
NETWORK_NAME="stranger-walk-net-$RUN_ID"
SIDECAR_NAME="stranger-walk-dind-$RUN_ID"
start_sidecar "$RUN_ID" "$NETWORK_NAME" "$SIDECAR_NAME" "$WORKSPACE_DIR" || { echo "[$RUN_ID] sidecar setup FAILED — refusing to launch a 'run'-mode container without one (owner order 2026-09-09: the builder hallway must be measurable)" >&2; exit 1; }

PAINTBOT_TAGS_AT_MAIN="$(git -C "$REPO_ROOT" tag --points-at origin/main --list 'paintbot-v*' 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
# Freshest possible era stamp: query origin directly (not the local clone's
# last `git fetch`) so a build that publishes mid-chain (this walk expects
# exactly that — see docs/designs/STRANGER_WALK.md's "Era" section) is
# still reflected on every stage's own meta.json, not just the first.
LATEST_PAINTBOT_TAG="$(git ls-remote --tags origin 2>/dev/null | grep -oE 'paintbot-v[0-9.]+$' | sort -V | tail -1)"
[ -n "$LATEST_PAINTBOT_TAG" ] || LATEST_PAINTBOT_TAG="$(git -C "$REPO_ROOT" tag --list 'paintbot-v*' --sort=-v:refname 2>/dev/null | head -1)"
GLORY_VERSION="$(grep -m1 -oE 'GloryVersion\*? = [0-9]+' "$REPO_ROOT/src/ctf/glory.nim" 2>/dev/null | grep -oE '[0-9]+$' || echo "unknown")"

# Public read of the live league's current standing rule (no commissioner
# token needed — this is content any visitor to the public page already
# gets), read-only recon for the record only, never shown to the stranger.
# Falls back to "not readable publicly" if the page's shape ever changes.
# NOTE: this heredoc is deliberately NOT nested inside a `$( ... )` command
# substitution — this host's /bin/bash (old, GPLv2-era, shipped by Apple)
# has a real, reproducible quoting bug where a heredoc inside `$(...)`
# requires an EVEN total count of literal `'` characters in its body even
# when the delimiter itself is quoted (verified empirically 2026-09-09);
# an apostrophe in an ordinary comment ("curl's") was enough to trip it.
# Writing to a temp file sidesteps the bug entirely.
STANDING_RULE_TMP="$(mktemp)"
python3 - "$STANDING_RULE_TMP" <<'PYEOF' 2>/dev/null
import re, sys, urllib.request

result = "not readable publicly"
try:
    # A default urllib User-Agent gets a 403 from this site (verified
    # 2026-09-09); curl-s default UA does not — send a plain one instead
    # of shelling out, so this stays a single self-contained recon step.
    req = urllib.request.Request(
        "https://softmax.com/paintbot",
        headers={"User-Agent": "Mozilla/5.0 (compatible; stranger-walk-recon/1.0)"},
    )
    html = urllib.request.urlopen(req, timeout=15).read().decode("utf-8", "ignore")
    # The page embeds its data as a JSON STRING inside a script payload, so
    # the quotes are backslash-escaped in the raw HTML (verified
    # 2026-09-09: literal `\"ranking\":` on the wire, not `"ranking":`) —
    # match the escaped form, then unescape the captured group so it's
    # valid JSON on its own.
    m = re.search(
        r'\\"ranking\\":(\{[^{}]*\}),\\"divisions\\":\[\{\\"name\\":\\"Competition\\",'
        r'\\"division_id\\":\\"div_aa7825db-262f-4a62-b01a-177c1b48f7ee\\"',
        html,
    )
    if m:
        result = m.group(1).replace('\\"', '"')
except Exception:
    pass
with open(sys.argv[1], "w") as f:
    f.write(result)
PYEOF
STANDING_RULE_PUBLIC="$(cat "$STANDING_RULE_TMP" 2>/dev/null)"
rm -f "$STANDING_RULE_TMP"
[ -n "$STANDING_RULE_PUBLIC" ] || STANDING_RULE_PUBLIC="not readable publicly"

START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"

STRANGER_TOOLS="Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch"

python3 - "$RUN_DIR/meta.json" "$STANDING_RULE_PUBLIC" <<PYEOF
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
    "browser_enabled": $( [ "$STRANGER_BROWSER" = "1" ] && echo True || echo False ),
    "playwright_profile": $( [ "$STRANGER_BROWSER" = "1" ] && echo "\"/home/stranger/.playwright-profile\"" || echo None ),
    "cookie_precheck": "$COOKIE_PRECHECK",
    "workspace_dir": "/workspace",
    "credential_source": "$CRED_MODE",
    "enable_docker_socket": $( [ "$ENABLE_DOCKER_SOCKET" = "1" ] && echo True || echo False ),
    "docker_sidecar": True,
    "docker_host": "tcp://127.0.0.1:2375",
    "docker_network": "container:$SIDECAR_NAME",
    "docker_sidecar_workspace_shared": True,
    "start_iso": "$START_ISO",
    "start_epoch": $START_EPOCH,
}
# Passed via argv, not interpolated into this source text — the standing
# rule is raw JSON-shaped text (embedded double quotes) that would corrupt
# a bash-interpolated python string literal.
try:
    meta["standing_rule_public_read"] = json.loads(sys.argv[2])
except Exception:
    meta["standing_rule_public_read"] = sys.argv[2]
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
PYEOF

echo "[$RUN_ID] model=$MODEL entry=$ENTRY_URL resolved=[$ENTRY_RESOLVED] glory=$GLORY_VERSION isolation=container credential=$CRED_MODE browser=$STRANGER_BROWSER" >&2

DOCKER_RUN_ARGS=(
  run -d --name "$CONTAINER_NAME"
  # v1.6 Trap B fix (see start_sidecar's header): share the sidecar's own
  # network namespace instead of a separate bridge address, so 127.0.0.1
  # means the same loopback on both sides — `coworld run-episode`'s own
  # health check hardcodes 127.0.0.1. --hostname cannot be combined with
  # --network container:, so it is dropped here (not checked anywhere else
  # in this tooling — grepped clean).
  --network "container:$SIDECAR_NAME"
  -e DOCKER_HOST=tcp://127.0.0.1:2375
  --pids-limit 512
  --memory 2g
  --cpus 2
  --user "$HOST_UID_GID"
  -e HOME=/home/stranger
  -e MODEL="$MODEL"
  -e STRANGER_TOOLS="$STRANGER_TOOLS"
  -e MAX_BUDGET_USD="$MAX_BUDGET_USD"
  -e STRANGER_CONTAINER_MODE=run
  -e STRANGER_BROWSER="$STRANGER_BROWSER"
  -v "$RUN_DIR:/home/stranger"
  -v "$WORKSPACE_DIR:/workspace"
  -w /workspace
)
if [ -n "$CRED_ENV_FILE" ]; then
  # Option (a) only — the API key is handed in via --env-file, never baked
  # into the image or a `docker run -e` CLI arg. Option (b)'s credential is
  # already present on disk at $RUN_DIR/.claude/.credentials.json, which the
  # -v "$RUN_DIR:/home/stranger" mount above already places at
  # /home/stranger/.claude/.credentials.json — no extra docker flag needed.
  DOCKER_RUN_ARGS+=(--env-file "$CRED_ENV_FILE")
fi
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
# run.sh today — v1.4 correction: launch.sh's dispatch actually needed a
# fix for this to be true (it only ever recognized run.sh/resume.sh; see
# docs/designs/STRANGER_WALK.md's v1.4 "Correction to v1.3's launch.sh
# claim").
set +e
docker wait "$CONTAINER_ID" > "$RUN_DIR/container.exit_code" 2> "$RUN_DIR/docker-wait.stderr.log"
EXIT_CODE="$(tr -d '[:space:]' < "$RUN_DIR/container.exit_code" 2>/dev/null || echo 1)"
[ -n "$EXIT_CODE" ] || EXIT_CODE=1
set -e

docker logs "$CONTAINER_ID" > "$RUN_DIR/container.stdout.log" 2> "$RUN_DIR/container.stderr.log" || true
docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true

# v1.5: persist the sidecar's own images to local tar files (its storage
# is ephemeral — this is the only chance) BEFORE removing it, then remove
# the sidecar and the run's private network. See isolation_audit.sh's
# sidecar_images/ scan, and stop_sidecar_and_scan's header above.
stop_sidecar_and_scan "$RUN_DIR" "$SIDECAR_NAME"
docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true

# Legacy v1.4 guard #2, tracking half (see docker_images_before.txt
# snapshot above): only relevant if STRANGER_ENABLE_DOCKER_SOCKET=1 was
# explicitly set — off by default, superseded by the sidecar above.
if [ "$ENABLE_DOCKER_SOCKET" = "1" ]; then
  docker images -q | sort -u > "$RUN_DIR/docker_images_after.txt" || true
  comm -13 "$RUN_DIR/docker_images_before.txt" "$RUN_DIR/docker_images_after.txt" > "$RUN_DIR/docker_images_created.txt" || true
fi

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
