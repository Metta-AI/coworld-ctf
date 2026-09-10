# Stranger Walk tooling

Full protocol writeup: `docs/designs/STRANGER_WALK.md`. This file is a quick index of what's here.

- `prompt.md` / `smoke_prompt.md` — the fixed stranger prompt (real / hard-stop-at-M5 smoke variant).
- `judge.md` — milestone scoring rubric.
- `run.sh` / `resume.sh` — launch/continue one run as a bare host process (protocol v1.1: auto-continue
  on lost background notifications). Reuses the HOST's own `claude` OAuth session; isolates `$HOME` for
  Bash-tool subprocesses only. Does **not** isolate the process table — see v1.3 below.
- `launch.sh` — protocol v1.2: launch `run.sh`/`resume.sh`/`run_container.sh` fully detached (survives
  the launching session dying).
- `run_container.sh` + `container/{Dockerfile,entrypoint.sh,probe.sh}` — **protocol v1.3, browser +
  credential fallback in v1.4, per-run docker-in-docker sidecar in v1.5, sidecar network+workspace
  sharing in v1.6**: the same run, inside its own Linux container (own PID namespace, own
  filesystem, own network). Closes the process-table visibility gap `run.sh` cannot close (`ps aux`
  inside the container can only ever see the container's own processes). v1.4 adds a headless
  Chromium browser (Python `playwright` for the no-credential `selftest` screenshot proof;
  `@playwright/mcp` wired via `--mcp-config` for the stranger's own `claude -p` session, same
  mechanism `run.sh` already uses on the host) and a credential fallback chain — see the script's
  header for the full contract. v1.5 gives each run its own docker-in-docker sidecar (own daemon,
  ephemeral storage, private network) so the stranger can `docker build`/`docker run` at all. v1.6
  fixes two DinD traps found by actually running `coworld run-episode` (the documented local test)
  through a v1.5 sandbox+sidecar pair: (a) `-v` bind mounts resolve on the DAEMON's filesystem, not
  the client's, so the sidecar needs the run's `$WORKSPACE_DIR` mounted at `/workspace` too, same as
  the sandbox — without it, `coworld run-episode` failed with `cannot open: /coworld/config.json
  [IOError]` on every real run; (b) the sandbox now joins the sidecar's own network namespace
  (`--network container:<sidecar>`) instead of a separate bridge address, so `127.0.0.1` — which
  `coworld run-episode`'s own health check hardcodes — means the same loopback on both sides. See
  `start_sidecar`'s header in `run_container.sh` for the full write-up. Three modes:
  - `run_container.sh probe <run-id>` — isolation self-probe, no credential needed. Writes
    `isolation_probe.json` to the run dir; `isolation_audit.sh` checks it automatically when present.
  - `run_container.sh selftest <run-id>` — proves the image itself is built right (claude/node/python/
    git/uv on PATH, plus a real headless-Chromium screenshot of the public entry point via Python
    playwright), a `docker build`+`docker run` through the per-run sidecar, and (v1.6) a REAL
    `coworld run-episode` through that same sidecar with a real `results.json`/`replay` on disk —
    the certification default until #527 (the play-seat baseline) lands. No Anthropic credential.
  - `run_container.sh <model> <run-id> [max-budget-usd]` — the actual stranger. Set `STRANGER_SMOKE=1`
    for the hard-stop-at-M5 smoke prompt (same guarantee `run.sh` gives). Credential resolved in order:
    (a) `STRANGER_ANTHROPIC_API_KEY_FILE` (default `~/.ctf/knowledge/stranger-walk/anthropic_api_key`),
    a run-scoped Anthropic API key; (b) else the HOST's own Claude Code login (on a Mac, extracted from
    the macOS Keychain service `"Claude Code-credentials"` — owner-authorized 2026-09-09, two guards:
    the stranger's own working directory is a separate bind mount (`/workspace`) that is never an
    ancestor of `/home/stranger` where the credential file lives, and `isolation_audit.sh` gained a
    credential-leak scan of every run artifact plus any docker image the run built). Refuses to launch
    without either.
- `credential_scan.py` — v1.4 helper: substring-search run artifacts / a `docker save`d image for a
  `host_claude_login` run's own credential value, reporting PASS/FAIL + a SHA256 fingerprint only —
  never the value itself. Used by `isolation_audit.sh`.
- `score.py` — extract milestone timings from a `transcript.jsonl` (works on `run.sh` and
  `run_container.sh` output alike — same run-dir contract).
- `isolation_audit.sh` — grep a transcript for internal-vocabulary boundary hits; also checks a
  container run's `isolation_probe.json`, and (v1.4) a `host_claude_login` run's credential-leak scans,
  when present. Any hit disqualifies the run.
- `bg_notify_check.py` — protocol v1.1 helper (detect an orphaned background-task notification a `-p`
  process never got to react to).

Run dirs live under `/Users/maxwellstarr/projects/stranger-walk-runs/<run-id>/` (outside the repo,
never committed): `meta.json`, `transcript.jsonl`, `prompt.rendered.md`, `workspace/` (the stranger's
own cwd — separate from the run dir's HOME root, v1.4), plus (container runs only)
`isolation_probe.json`, `container.id`, `container.exit_code`, and either `credential.env` (mode 600,
credential option (a)'s copied API key) or `.claude/.credentials.json` + `credential_meta.json` (mode
600/644, credential option (b)'s copied host login + its SHA256 fingerprint) — never the host's own
`~/.claude` directory in any form.
