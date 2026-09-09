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

  # v1.4: prove the browser mechanism for real — no Anthropic credential
  # needed, this is a scripted Python playwright fetch, not a claude turn.
  # Screenshot lands at /home/stranger/browser-selftest.png, which
  # run_container.sh's bind mount (`-v "$RUN_DIR:/home/stranger"`) puts
  # straight into the run dir on the host at $RUN_DIR/browser-selftest.png.
  echo "[selftest] python playwright: headless chromium fetch of https://softmax.com/paintbot"
  python3 - <<'PYEOF'
import sys
from playwright.sync_api import sync_playwright

try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        resp = page.goto("https://softmax.com/paintbot", timeout=30000, wait_until="load")
        page.screenshot(path="/home/stranger/browser-selftest.png")
        status = resp.status if resp else None
        title = page.title()
        browser.close()
    print(f"[selftest] browser screenshot OK: status={status} title={title!r} saved=/home/stranger/browser-selftest.png")
except Exception as e:
    print(f"[selftest] browser screenshot FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

  exit 0
fi

# v1.4 guard #1: `claude -p` starts in the stranger's own WORKSPACE, never
# in $HOME — see run_container.sh's header and the "workspace_dir" meta.json
# field. $HOME (/home/stranger, where a host_claude_login credential would
# live at .claude/.credentials.json) stays the process's $HOME for auth
# purposes only; it is never the stranger's own working directory, so a
# `docker build .` / `tar czf x.tar.gz .` from its actual cwd cannot sweep
# the credential file in.
cd /workspace

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
)

# v1.4: real browser, official (non-smoke) runs, mirroring run.sh's own
# --mcp-config wiring for the identical @playwright/mcp server (--safe-mode
# disables MCP servers outright even when passed via --mcp-config, so
# browser runs drop it — same tradeoff run.sh documents in its own header;
# --setting-sources "" alone already isolates CLAUDE.md/memory/plugins, and
# this container has none of those on its filesystem in the first place).
# run_container.sh writes /home/stranger/mcp-config.json only when
# STRANGER_BROWSER=1 and sets that env var via `docker run -e`.
if [ "${STRANGER_BROWSER:-0}" = "1" ] && [ -f /home/stranger/mcp-config.json ]; then
  CLAUDE_ARGS+=(--mcp-config /home/stranger/mcp-config.json)
else
  CLAUDE_ARGS+=(--safe-mode)
fi

set +e
claude -p "$(cat /home/stranger/prompt.rendered.md)" "${CLAUDE_ARGS[@]}" \
  > /home/stranger/transcript.jsonl 2> /home/stranger/run.stderr.log
EXIT_CODE=$?
set -e
exit "$EXIT_CODE"
