#!/usr/bin/env bash
# tools/stranger_walk/run.sh <model> <run-id> [max-budget-usd]
#
# Launches one Stranger Walk baseline run: a fresh `claude -p` process, in its own
# fresh working directory, given ONLY the fixed prompt in prompt.md. See
# docs/designs/STRANGER_WALK.md for the full protocol writeup.
#
# Isolation choices (verified 2026-09-09, see that doc for the preflight evidence):
#   --safe-mode                disables CLAUDE.md auto-discovery, auto-memory, hooks,
#                               plugins, and MCP servers. A haiku preflight in an empty
#                               dir reported "NONE LOADED" for CLAUDE.md/memory content
#                               with this flag on.
#   --setting-sources ""        --safe-mode alone still lists this machine's plugins
#                               (with their absolute filesystem paths, e.g.
#                               /Users/.../projects/metta/agent-plugins/ux) in the
#                               system-init transcript line, which trips
#                               isolation_audit.sh's `projects/metta` pattern on every
#                               single run regardless of stranger behavior. Verified
#                               2026-09-09: adding --setting-sources "" empties that
#                               plugins array (and mcp_servers, slash_commands) with no
#                               loss of the CLAUDE.md/memory isolation from --safe-mode.
#   --tools "..."               this machine injects harness-only tools (Task, Cron*,
#                               SendMessage, ListAgents, ToolSearch, Workflow, ...) into
#                               every `claude` process regardless of --safe-mode; this
#                               explicitly whitelists only what a real stranger would
#                               have: a shell, file ops, and the public web.
#   --strict-mcp-config          no MCP servers, even if ambient config exists.
#   --disable-slash-commands     hides this machine's plugin-provided slash commands.
#   --permission-mode bypassPermissions
#                               `-p` is non-interactive; anything that isn't
#                               auto-approved stalls forever (no TTY to answer). This is
#                               the closest available substitute for a real interactive
#                               permission grant. Isolation is enforced by convention
#                               (prompt.md's "stay in your lane" instruction), checked
#                               post-hoc by isolation_audit.sh — not by an OS-level
#                               sandbox. That is a deliberate, documented choice, not an
#                               oversight.
#   (session IS persisted, deliberately: owner decision 2026-09-09 has the stranger
#   sign itself up with a real address from ~/.ctf/knowledge/stranger-walk/env
#   (STRANGER_EMAIL; never committed, copied into $RUN_DIR/env before launch). If
#   signup emails a verification code, the stranger writes `WAITING: ` and stops —
#   resume.sh then continues the SAME session once the owner relays the code.)
#   --settings '{"env": {...}}'  INCIDENT 2026-09-09: a $1 haiku smoke test proved
#   --safe-mode/--setting-sources isolate Claude Code's OWN config but do nothing
#   for third-party CLI credential stores under the same $HOME — `uv run softmax
#   login --no-browser` silently authenticated as the REAL softmaxwell account
#   (via ~/.softmax/credentials.yaml) and placed a real submission on the real
#   live Paintbot ladder. `env -i HOME=<fresh>` breaks claude's OWN auth (it needs
#   something under the real $HOME to log in), so instead this scopes a fresh
#   HOME (+ DOCKER_CONFIG/AWS_*/GIT_CONFIG*/NETRC/XDG_*/SSH_AUTH_SOCK) to just the
#   Bash-tool subprocess environment via --settings env, which claude honors even
#   under --safe-mode (it's explicit, not auto-discovered). Verified 2026-09-09:
#   claude itself still authenticates (is_error:false) while a Bash call's `env`
#   shows the overridden values and `~/.softmax` resolves to the fresh, empty
#   home; re-running the exact `coworld submissions --mine` that leaked the real
#   account now correctly fails with "Interactive login requires a TTY" and
#   points at a fresh https://softmax.com/cli-auth flow instead.
#   --output-format stream-json --verbose
#                               full transcript, per-turn timestamps. (Tested and
#                               rejected --include-partial-messages: it multiplies the
#                               transcript with token-level deltas that add no
#                               belief/milestone signal.)
#   Real browser for official (non-smoke) runs, per owner order 2026-09-09: a
#   playwright MCP server, --mcp-config'd fresh per run with its OWN
#   --user-data-dir under $RUN_DIR/home/.playwright-profile — NEVER the shared
#   playwright instance other agents use (that profile can carry logged-in
#   softmax/google/github cookies, which would be the exact same leak by a
#   different door). --safe-mode disables MCP servers outright even when
#   explicitly passed via --mcp-config (verified 2026-09-09), so browser runs
#   drop --safe-mode and rely on --setting-sources "" alone for CLAUDE.md/
#   memory/plugin isolation — verified equivalent: a haiku probe with
#   --setting-sources "" and no --safe-mode still reported "NONE LOADED" and
#   plugins:[], while the playwright MCP server registered and its
#   browser_* tools became available (both fail together under --safe-mode).
set -euo pipefail

MODEL="${1:?usage: run.sh <model> <run-id> [max-budget-usd]}"
RUN_ID="${2:?usage: run.sh <model> <run-id> [max-budget-usd]}"
MAX_BUDGET_USD="${3:-25}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
ENTRY_URL="${STRANGER_ENTRY_URL:-https://softmax.com/paintbot}"

RUNS_PARENT="${STRANGER_RUNS_PARENT:-/Users/maxwellstarr/projects/stranger-walk-runs}"
RUN_DIR="$RUNS_PARENT/$RUN_ID"
mkdir -p "$RUN_DIR"

if [ -e "$RUN_DIR/meta.json" ]; then
  echo "refusing to overwrite existing run: $RUN_DIR" >&2
  exit 1
fi

# STRANGER_SMOKE=1 (any mechanism smoke test, never an official baseline): use
# the hard-stop-at-M5 prompt instead of the real one — no login, no upload, no
# submit, by construction — and grep the transcript for those verbs afterward.
# Coordinator order 2026-09-09 after the credential-leak incident: keep smoke
# tests from ever reaching a real submission again, even with HOME isolated.
if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
  SOURCE_PROMPT="$SCRIPT_DIR/smoke_prompt.md"
else
  SOURCE_PROMPT="$SCRIPT_DIR/prompt.md"
fi

# Render the fixed prompt with the entry URL substituted. sha256 is over the
# TEMPLATE (protocol identity), independent of which URL got filled in.
PROMPT_SHA256="$(shasum -a 256 "$SOURCE_PROMPT" | awk '{print $1}')"
sed "s#{{ENTRY_URL}}#$ENTRY_URL#g" "$SOURCE_PROMPT" > "$RUN_DIR/prompt.rendered.md"

# Isolated $HOME for the stranger's Bash-tool subprocesses ONLY (see header
# note above) — never for claude's own process, which needs the real $HOME to
# authenticate. Any third-party CLI (softmax/coworld/docker/aws/git/ssh) that
# a Bash call reaches for now sees a completely fresh, empty identity.
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

# Real browser, official (non-smoke) runs only, per owner order 2026-09-09 —
# see header note. Fresh --user-data-dir per run; refuse to launch if that
# profile somehow already has softmax/google/github cookies (should be
# impossible for a brand-new run-id, but this is the explicit check ordered).
STRANGER_BROWSER="${STRANGER_BROWSER:-$( [ "${STRANGER_SMOKE:-0}" = "1" ] && echo 0 || echo 1 )}"
PLAYWRIGHT_PROFILE="$STRANGER_HOME/.playwright-profile"
MCP_CONFIG='{"mcpServers":{}}'
COOKIE_PRECHECK="not_applicable (no browser for this run)"
if [ "$STRANGER_BROWSER" = "1" ]; then
  mkdir -p "$PLAYWRIGHT_PROFILE"
  COOKIES_DB="$PLAYWRIGHT_PROFILE/Default/Cookies"
  COOKIE_HITS=0
  if [ -f "$COOKIES_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    COOKIE_HITS="$(sqlite3 "$COOKIES_DB" "select count(*) from cookies where host_key like '%softmax.com%' or host_key like '%google.com%' or host_key like '%github.com%';" 2>/dev/null || echo 0)"
  fi
  if [ "$COOKIE_HITS" != "0" ]; then
    echo "[$RUN_ID] REFUSING TO LAUNCH: playwright profile at $PLAYWRIGHT_PROFILE already has $COOKIE_HITS softmax/google/github cookie(s) — not a fresh profile" >&2
    exit 1
  fi
  COOKIE_PRECHECK="verified pre-launch: 0 cookies for softmax.com/google.com/github.com in $PLAYWRIGHT_PROFILE"
  MCP_CONFIG="$(python3 -c "
import json
print(json.dumps({'mcpServers': {'playwright': {
    'command': 'npx',
    'args': ['--yes', '@playwright/mcp@latest', '--headless', '--user-data-dir', '$PLAYWRIGHT_PROFILE']
}}}))
")"
fi

# Resolve the entry URL for real (follow redirects) so drift/redirects are on record.
ENTRY_RESOLVED="$(curl -sS -o /dev/null -w '%{http_code} %{url_effective}' -L --max-time 15 "$ENTRY_URL" || echo "CURL_FAILED")"

# Owner-provided signup address (never committed): copy into the run's own cwd as
# `env` so the stranger finds it via prompt.md's "check your working directory for a
# file named env" instruction. Absence is a valid, recorded state (the run then has
# no usable credentials and stops on its own). Smoke tests never get this — the
# smoke prompt hard-stops before signup, so there's
# no reason to hand out the real address.
OWNER_ENV_SRC="${STRANGER_OWNER_ENV:-$HOME/.ctf/knowledge/stranger-walk/env}"
HAD_OWNER_ENV="false"
if [ "${STRANGER_SMOKE:-0}" != "1" ] && [ -f "$OWNER_ENV_SRC" ]; then
  cp "$OWNER_ENV_SRC" "$RUN_DIR/env"
  chmod 600 "$RUN_DIR/env"
  HAD_OWNER_ENV="true"
fi

# Read-only recon of the internal repo, for the record only — never shown to the stranger.
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
    "playwright_profile": $( [ "$STRANGER_BROWSER" = "1" ] && echo "\"$PLAYWRIGHT_PROFILE\"" || echo None ),
    "cookie_precheck": "$COOKIE_PRECHECK",
    "start_iso": "$START_ISO",
    "start_epoch": $START_EPOCH,
}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
PYEOF

echo "[$RUN_ID] model=$MODEL entry=$ENTRY_URL resolved=[$ENTRY_RESOLVED] glory=$GLORY_VERSION" >&2
echo "[$RUN_ID] launching, cwd=$RUN_DIR ..." >&2

cd "$RUN_DIR"
CLAUDE_ARGS=(
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
if [ "$STRANGER_BROWSER" = "1" ]; then
  CLAUDE_ARGS+=(--mcp-config "$MCP_CONFIG")
else
  CLAUDE_ARGS+=(--safe-mode)
fi

set +e
claude -p "$(cat "$RUN_DIR/prompt.rendered.md")" "${CLAUDE_ARGS[@]}" \
  > "$RUN_DIR/transcript.jsonl" 2> "$RUN_DIR/run.stderr.log"
EXIT_CODE=$?
set -e

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
if [ "$RUN_STATUS" = "waiting_on_code" ]; then
  echo "[$RUN_ID] STOPPED ON WAITING: — relay the code, then run: tools/stranger_walk/resume.sh $RUN_ID '<code>'" >&2
fi

# Protocol v1.1 (2026-09-09): if the stranger backgrounded a shell command and
# the process exited at end_turn before it finished naturally, the harness
# still wrote a task_notification the process never got to react to (see
# resume.sh header note). Auto-continue the SAME session with that
# notification, exactly as an interactive session would have delivered it.
if [ "$RUN_STATUS" = "completed" ]; then
  BG_MSG="$(python3 "$SCRIPT_DIR/bg_notify_check.py" "$RUN_DIR")"
  if [ -n "$BG_MSG" ]; then
    echo "[$RUN_ID] orphaned background task detected post-exit — auto-continuing (protocol v1.1)" >&2
    "$SCRIPT_DIR/resume.sh" "$RUN_ID" "$BG_MSG" "auto_continue"
    EXIT_CODE=$?
  fi
fi

# Smoke-test guard (coordinator order 2026-09-09, post-incident): a smoke run
# should never even ATTEMPT login/upload/submit — the smoke prompt hard-stops
# at M5 by construction, but check the transcript as a second, independent
# check. Inspects only actual Bash tool_use commands (not e.g. the prompt text
# itself, which mentions these verbs by name in its own rules and would
# false-positive on a plain grep — found this the hard way on smoketest-4).
# Any real hit means the smoke prompt needs tightening, not a real-baseline
# concern (baselines are expected to run these and are gated by GO + HOME
# isolation above).
if [ "${STRANGER_SMOKE:-0}" = "1" ]; then
  LOGIN_HITS="$(python3 -c "
import json, re
pat = re.compile(r'softmax login|coworld submit|upload-policy|exchange-code')
for line in open('$RUN_DIR/transcript.jsonl'):
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
")"
  if [ -n "$LOGIN_HITS" ]; then
    echo "[$RUN_ID] SMOKE GUARD WARNING: login/upload/submit command(s) actually run in a smoke test:" >&2
    echo "$LOGIN_HITS" | sed 's/^/  /' >&2
  else
    echo "[$RUN_ID] smoke guard: PASS — no login/upload/submit command was run" >&2
  fi
fi
exit "$EXIT_CODE"
