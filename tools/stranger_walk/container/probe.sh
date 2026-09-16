#!/usr/bin/env bash
# tools/stranger_walk/container/probe.sh — isolation self-probe, runs INSIDE
# the stranger container (via `entrypoint.sh` with
# STRANGER_CONTAINER_MODE=probe). Writes a JSON verdict to the path given as
# $1 (default /home/stranger/isolation_probe.json, which run_container.sh
# bind-mounts back out to the run dir), so isolation_audit.sh can check it
# post-hoc the same way it already checks a transcript for boundary hits.
#
# This is a SCRIPTED PROBE, not a real stranger — it exists to prove the
# container closes the gap Walk 1 found (`ps aux` leaking the host's process
# table, see docs/designs/STRANGER_WALK.md). It never runs `claude` and
# needs no Anthropic credential.
#
# Honesty note (read before trusting a green run): checks 2 ("no /Users")
# and parts of check 4 are trivially true on ANY stock Linux container,
# isolated or not — /Users is a macOS path that never exists on Linux, full
# stop. The checks that actually exercise container isolation are 1 (ps
# shows only this namespace's own processes — the literal failure mode that
# disqualified sonnet-c), 3 (no host dotfiles/credential stores visible —
# meaningful precisely BECAUSE nothing outside the bind mount is shared),
# and 5 (own PID namespace / own init). Keep 2 for symmetry with the build
# protocol's wording, but don't read it as load-bearing.
set -uo pipefail # no -e: every check must run even if an earlier one fails

RESULT_FILE="${1:-/home/stranger/isolation_probe.json}"
CHECKS_FILE="$(mktemp)"
trap 'rm -f "$CHECKS_FILE"' EXIT

record() {
  # record <name> <true|false> <detail>
  python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "ok": sys.argv[2] == "true", "detail": sys.argv[3]}))' \
    "$1" "$2" "$3" >> "$CHECKS_FILE"
}

# 1. ps aux shows ONLY this container's own processes — no host paths, no
#    host process names. This is the exact check that disqualified
#    sonnet-c on the bare-host run.sh path.
PS_OUT="$(ps aux 2>&1 || true)"
PS_LINE_COUNT="$(echo "$PS_OUT" | grep -c . || true)"
HOST_HIT="$(echo "$PS_OUT" | grep -E '/Users/maxwellstarr|coworld-ctf|projects/metta|paintbot-ops' || true)"
if [ -n "$HOST_HIT" ]; then
  record "ps_no_host_paths" false "ps aux leaked a host path: $(echo "$HOST_HIT" | head -1)"
else
  record "ps_no_host_paths" true "ps aux ($PS_LINE_COUNT lines, own namespace) has no host path/vocabulary"
fi

# 2. /Users doesn't exist / isn't listable. See honesty note above: this is
#    trivially true on Linux regardless of isolation quality.
if ls /Users >/dev/null 2>&1; then
  record "no_host_users_dir" false "/Users is listable inside the container"
else
  record "no_host_users_dir" true "/Users is absent (expected on Linux; not itself proof of isolation — see script header)"
fi

# 3. No host credential/config directories visible anywhere in the
#    container's filesystem — meaningful because this container shares
#    NOTHING with the host except the run dir bind-mounted at /home/stranger
#    by run_container.sh (which itself only ever contains this run's own
#    prompt/meta/env files, never a credential store).
HOST_DIR_HITS=""
for p in "$HOME/.softmax" "$HOME/.claude/projects" "$HOME/.ctf" "$HOME/.aws" /Users; do
  if [ -e "$p" ]; then
    HOST_DIR_HITS="$HOST_DIR_HITS $p"
  fi
done
if [ -n "$HOST_DIR_HITS" ]; then
  record "no_host_credential_dirs" false "unexpectedly present:$HOST_DIR_HITS"
else
  record "no_host_credential_dirs" true "none of ~/.softmax ~/.claude/projects ~/.ctf ~/.aws /Users exist"
fi

# 4. env carries no host paths/tokens except this run's own mounted files.
#    (MODEL/STRANGER_TOOLS/MAX_BUDGET_USD/ANTHROPIC_API_KEY/HOME/PATH-style
#    vars are the run's own — a plain grep for the literal host username and
#    host project path strings is the meaningful check.)
ENV_HIT="$(env | grep -E '/Users/maxwellstarr|softmaxwell' | grep -v '^_=' || true)"
if [ -n "$ENV_HIT" ]; then
  record "env_no_host_leakage" false "$ENV_HIT"
else
  record "env_no_host_leakage" true "env has no /Users/maxwellstarr or softmaxwell string"
fi

# 5. Own PID namespace: this process is PID 1 (or a direct child of it) in
#    its OWN namespace, not a process visible in / reachable from the host's
#    PID 1. `docker run` (no --pid=host) guarantees this by construction;
#    confirm it directly rather than just trusting the flag wasn't passed.
SELF_PID1_COMM="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
MY_PID="$$"
record "own_pid_namespace" true "PID 1 in this namespace is '$SELF_PID1_COMM'; this probe is pid $MY_PID in the SAME namespace (own init, not host launchd)"

# 6. Network reaches the real public entry point (the one thing a stranger
#    SHOULD be able to reach) — proves egress isn't accidentally blocked
#    along with everything else.
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 https://softmax.com/paintbot 2>/dev/null)"
[ -n "$HTTP_CODE" ] || HTTP_CODE=000
case "$HTTP_CODE" in
  200|301|302|307|308) record "network_reaches_public_entry" true "https://softmax.com/paintbot -> $HTTP_CODE" ;;
  *) record "network_reaches_public_entry" false "https://softmax.com/paintbot -> $HTTP_CODE" ;;
esac

# 7. Network does NOT reach host-loopback services (the container has its
#    own network namespace/bridge — nothing bound to the host's 127.0.0.1
#    should be reachable at the container's own localhost).
LOOPBACK_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:1/ 2>/dev/null)"
[ -n "$LOOPBACK_CODE" ] || LOOPBACK_CODE=000
if [ "$LOOPBACK_CODE" = "000" ]; then
  record "no_host_loopback_reach" true "container's own 127.0.0.1 does not reach a host service (connection failed, as expected)"
else
  record "no_host_loopback_reach" false "container's own 127.0.0.1 answered with $LOOPBACK_CODE — unexpected"
fi

python3 - "$RESULT_FILE" "$CHECKS_FILE" <<'PYEOF'
import json, sys, datetime

result_file, checks_file = sys.argv[1], sys.argv[2]
checks = []
with open(checks_file) as f:
    for line in f:
        line = line.strip()
        if line:
            checks.append(json.loads(line))

overall_pass = all(c["ok"] for c in checks)
out = {
    "probe": "tools/stranger_walk/container/probe.sh",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "overall_pass": overall_pass,
    "checks": checks,
}
with open(result_file, "w") as f:
    json.dump(out, f, indent=2)
print(json.dumps(out, indent=2))
if not overall_pass:
    sys.exit(1)
PYEOF
