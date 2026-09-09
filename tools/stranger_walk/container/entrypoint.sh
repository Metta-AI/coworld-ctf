#!/usr/bin/env bash
# tools/stranger_walk/container/entrypoint.sh — runs INSIDE the stranger
# container as its PID-1 process. Dispatches on $STRANGER_CONTAINER_MODE
# (set by run_container.sh via `docker run -e`):
#
#   probe — run the isolation self-probe (probe.sh) and exit. No Anthropic
#           credential needed. This is what PROVES isolation before any real
#           or smoke stranger prompt ever runs — see probe.sh and
#           docs/designs/STRANGER_WALK.md v1.3.
#   run   — the actual stranger: `claude -p` against
#           /home/stranger/prompt.rendered.md (bind-mounted in by
#           run_container.sh, same file run.sh already produces), writing
#           /home/stranger/transcript.jsonl + run.stderr.log in the SAME
#           shape run.sh writes them in, so score.py and isolation_audit.sh
#           work unchanged on a container run's output.
#
# Unlike run.sh (which fakes an isolated $HOME for Bash-tool subprocesses
# only, because claude's own top-level process needs the HOST's real $HOME
# to authenticate), this container has no host $HOME to leak from at all —
# $HOME is /home/stranger, period, for every process in this namespace,
# claude included. That is why this needs its OWN credential (an Anthropic
# API key, passed via `docker run --env-file`, never the host's ~/.claude)
# instead of reusing a host OAuth session — see run_container.sh's header.
set -euo pipefail

MODE="${STRANGER_CONTAINER_MODE:-run}"

if [ "$MODE" = "probe" ]; then
  exec /probe.sh "${1:-/home/stranger/isolation_probe.json}"
fi

if [ "$MODE" = "selftest" ]; then
  # No Anthropic credential required — proves the claude binary itself is
  # installed and invokable inside this image (npm install worked, PATH is
  # right) without touching the network or any credential. Used by
  # run_container.sh's build-verification step, distinct from a real run.
  echo "[selftest] claude --version:"
  claude --version
  echo "[selftest] node/python/git/uv on PATH:"
  node --version
  python3 --version
  git --version
  uv --version
  echo "[selftest] docker client present (no daemon reachable, by design):"
  docker --version || true
  exit 0
fi

cd /home/stranger

: "${MODEL:?MODEL env var required}"
: "${STRANGER_TOOLS:?STRANGER_TOOLS env var required}"
: "${MAX_BUDGET_USD:?MAX_BUDGET_USD env var required}"

if [ ! -f /home/stranger/prompt.rendered.md ]; then
  echo "no /home/stranger/prompt.rendered.md — run_container.sh should have rendered and mounted it" >&2
  exit 1
fi

CLAUDE_ARGS=(
  --model "$MODEL"
  --setting-sources ""
  --tools "$STRANGER_TOOLS"
  --strict-mcp-config
  --disable-slash-commands
  --permission-mode bypassPermissions
  --output-format stream-json
  --verbose
  --max-budget-usd "$MAX_BUDGET_USD"
  --safe-mode
)

set +e
claude -p "$(cat /home/stranger/prompt.rendered.md)" "${CLAUDE_ARGS[@]}" \
  > /home/stranger/transcript.jsonl 2> /home/stranger/run.stderr.log
EXIT_CODE=$?
set -e
exit "$EXIT_CODE"
