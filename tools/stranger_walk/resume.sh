#!/usr/bin/env bash
# tools/stranger_walk/resume.sh <run-id> "<message>"
#
# Continues a run that stopped on a `WAITING: ` line (run.sh sets
# meta.json.run_status = "waiting_on_code" and prints the exact command to use).
# <message> is whatever the owner relayed (a verification code, a "no such
# option, try again" note, etc.) — it's appended to the SAME session via
# `claude -p --resume <session_id>`, and the reply is appended to the same
# transcript.jsonl so score.py sees one continuous run.
#
# The wait between run.sh stopping and resume.sh being called is real elapsed
# time the stranger spent blocked on a human (the owner relaying a code from
# their inbox), not the stranger being out of ideas. score.py tags the stuck
# episode that covers this gap with "owner_latency": true so it's counted
# separately from genuine dead-ends in docs/designs/STRANGER_WALK.md.
#
# PROTOCOL v1.1 (2026-09-09, sonnet-a finding): interactively, a finished
# background shell command re-invokes the agent with a notification; in `-p`
# mode nothing does — the process exits at end_turn and the harness kills any
# still-running background task as a side effect, before it necessarily
# finished naturally. A stranger that backgrounds a command it needs the
# result of (sonnet-a did this with its own `coworld upload-policy`, then
# said "I'll wait for the notification") silently loses that follow-through —
# not its fault, a harness/protocol gap. Fix, applied uniformly here and in
# run.sh: after EVERY invocation exits, check bg_notify_check.py for a
# task_notification the process never got to react to; if found, feed the
# SAME session a message describing what was interrupted and its captured
# output (as close as -p mode allows to what an interactive session would
# have delivered), and loop — up to $STRANGER_MAX_AUTO_CONTINUE times — before
# handing control back. These auto-continues are NOT owner latency (no human
# wait involved) and are recorded distinctly in meta.json's "resumes" entries
# via "kind": "auto_continue" vs "kind": "owner_relay".
set -euo pipefail

RUN_ID="${1:?usage: resume.sh <run-id> \"<message>\"}"
MESSAGE="${2:?usage: resume.sh <run-id> \"<message>\"}"
INITIAL_KIND="${3:-owner_relay}"
MAX_AUTO_CONTINUE="${STRANGER_MAX_AUTO_CONTINUE:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"
RUN_DIR="$RUNS_PARENT/$RUN_ID"

META="$RUN_DIR/meta.json"
if [ ! -f "$META" ]; then
  echo "no meta.json at $META" >&2
  exit 1
fi

MODEL="$(python3 -c "import json; print(json.load(open('$META'))['model'])")"
SESSION_ID="$(python3 -c "import json; print(json.load(open('$META')).get('session_id') or '')")"
STRANGER_TOOLS="$(python3 -c "import json; print(','.join(json.load(open('$META'))['stranger_tools']))")"
MAX_BUDGET_USD="$(python3 -c "import json; print(json.load(open('$META'))['max_budget_usd'])")"
BROWSER_ENABLED="$(python3 -c "import json; print('1' if json.load(open('$META')).get('browser_enabled') else '0')")"
PLAYWRIGHT_PROFILE="$(python3 -c "import json; print(json.load(open('$META')).get('playwright_profile') or '')")"

if [ -z "$SESSION_ID" ]; then
  echo "no session_id recorded for $RUN_ID — cannot resume" >&2
  exit 1
fi

# Reuse the SAME isolated $HOME run.sh created for this run (see its header
# note on the 2026-09-09 credential-leak incident) — never the real one.
STRANGER_HOME="$RUN_DIR/home"
mkdir -p "$STRANGER_HOME"
ISOLATED_SETTINGS="$(python3 -c "
import json
h = '$STRANGER_HOME'
print(json.dumps({'env': {
    'HOME': h,
    'DOCKER_CONFIG': h + '/.docker',
    'AWS_CONFIG_FILE': h + '/.aws/config',
    'AWS_SHARED_CREDENTIALS_FILE': h + '/.aws/credentials',
    'AWS_PROFILE': '',
    'AWS_REGION': '',
    'SSH_AUTH_SOCK': '',
    'GIT_CONFIG_GLOBAL': h + '/.gitconfig',
    'GIT_CONFIG_NOSYSTEM': '1',
    'NETRC': h + '/.netrc',
    'XDG_CONFIG_HOME': h + '/.config',
    'XDG_CACHE_HOME': h + '/.cache',
    'XDG_DATA_HOME': h + '/.local/share',
}}))
")"

CLAUDE_ARGS_BASE=(
  --resume "$SESSION_ID"
  --model "$MODEL"
  --setting-sources ""
  --tools "$STRANGER_TOOLS"
  --strict-mcp-config
  --disable-slash-commands
  --permission-mode bypassPermissions
  --output-format stream-json
  --verbose
  --settings "$ISOLATED_SETTINGS"
  --max-budget-usd "$MAX_BUDGET_USD"
)
if [ "$BROWSER_ENABLED" = "1" ] && [ -n "$PLAYWRIGHT_PROFILE" ]; then
  MCP_CONFIG="$(python3 -c "
import json
print(json.dumps({'mcpServers': {'playwright': {
    'command': 'npx',
    'args': ['--yes', '@playwright/mcp@latest', '--headless', '--user-data-dir', '$PLAYWRIGHT_PROFILE']
}}}))
")"
  CLAUDE_ARGS_BASE+=(--mcp-config "$MCP_CONFIG")
else
  CLAUDE_ARGS_BASE+=(--safe-mode)
fi

cd "$RUN_DIR"

RUN_STATUS="completed"
KIND="$INITIAL_KIND"
ITER=0
while true; do
  WAIT_RESUME_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  WAIT_RESUME_EPOCH="$(date +%s)"

  set +e
  claude -p "$MESSAGE" "${CLAUDE_ARGS_BASE[@]}" \
    >> "$RUN_DIR/transcript.jsonl" 2>> "$RUN_DIR/run.stderr.log"
  EXIT_CODE=$?
  set -e

  END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  END_EPOCH="$(date +%s)"

  python3 - "$META" "$KIND" "$WAIT_RESUME_ISO" "$WAIT_RESUME_EPOCH" "$END_ISO" "$END_EPOCH" "$EXIT_CODE" <<'PYEOF'
import json, sys
p, kind, wri, wre, ei, ee, exit_code = sys.argv[1:8]
meta = json.load(open(p))
meta.setdefault("resumes", [])
last_text = ""
transcript_path = p.rsplit("/", 1)[0] + "/transcript.jsonl"
try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            if ev.get("type") == "assistant":
                for block in ev.get("message", {}).get("content", []) or []:
                    if block.get("type") == "text":
                        last_text = block.get("text", "")
except FileNotFoundError:
    pass
waiting_again = any(l.strip().startswith("WAITING:") for l in last_text.splitlines())
meta["resumes"].append({
    "kind": kind,
    "wait_resume_iso": wri,
    "wait_resume_epoch": int(wre),
    "end_iso": ei,
    "end_epoch": int(ee),
    "exit_code": int(exit_code),
})
meta["end_iso"] = ei
meta["end_epoch"] = int(ee)
meta["wall_clock_seconds"] = int(ee) - meta["start_epoch"]
meta["exit_code"] = int(exit_code)
meta["run_status"] = "waiting_on_code" if waiting_again else "completed"
json.dump(meta, open(p, "w"), indent=2)
PYEOF

  RUN_STATUS="$(python3 -c "import json; print(json.load(open('$META'))['run_status'])")"
  echo "[$RUN_ID] resumed ($KIND). exit=$EXIT_CODE status=$RUN_STATUS" >&2

  if [ "$RUN_STATUS" = "waiting_on_code" ]; then
    echo "[$RUN_ID] STOPPED ON WAITING: — relay the code, then rerun resume.sh $RUN_ID '<code>'" >&2
    break
  fi

  ITER=$((ITER + 1))
  if [ "$ITER" -ge "$MAX_AUTO_CONTINUE" ]; then
    break
  fi

  BG_MSG="$(python3 "$SCRIPT_DIR/bg_notify_check.py" "$RUN_DIR")"
  if [ -z "$BG_MSG" ]; then
    break
  fi
  echo "[$RUN_ID] orphaned background task detected post-exit — auto-continuing (protocol v1.1)" >&2
  MESSAGE="$BG_MSG"
  KIND="auto_continue"
done

exit "$EXIT_CODE"
