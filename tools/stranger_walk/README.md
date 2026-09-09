# Stranger Walk tooling

Full protocol writeup: `docs/designs/STRANGER_WALK.md`. This file is a quick index of what's here.

- `prompt.md` / `smoke_prompt.md` — the fixed stranger prompt (real / hard-stop-at-M5 smoke variant).
- `judge.md` — milestone scoring rubric.
- `run.sh` / `resume.sh` — launch/continue one run as a bare host process (protocol v1.1: auto-continue
  on lost background notifications). Reuses the HOST's own `claude` OAuth session; isolates `$HOME` for
  Bash-tool subprocesses only. Does **not** isolate the process table — see v1.3 below.
- `launch.sh` — protocol v1.2: launch `run.sh`/`resume.sh`/`run_container.sh` fully detached (survives
  the launching session dying).
- `run_container.sh` + `container/{Dockerfile,entrypoint.sh,probe.sh}` — **protocol v1.3**: the same
  run, inside its own Linux container (own PID namespace, own filesystem, own network). Closes the
  process-table visibility gap `run.sh` cannot close (`ps aux` inside the container can only ever see
  the container's own processes). Needs its own credential — never the host's `~/.claude` — see the
  script's header for the full contract. Three modes:
  - `run_container.sh probe <run-id>` — isolation self-probe, no credential needed. Writes
    `isolation_probe.json` to the run dir; `isolation_audit.sh` checks it automatically when present.
  - `run_container.sh selftest <run-id>` — proves the image itself is built right (claude/node/python/
    git/uv on PATH), no credential, no network beyond nothing.
  - `run_container.sh <model> <run-id> [max-budget-usd]` — the actual stranger. Set `STRANGER_SMOKE=1`
    for the hard-stop-at-M5 smoke prompt (same guarantee `run.sh` gives). Requires
    `STRANGER_ANTHROPIC_API_KEY_FILE` (default `~/.ctf/knowledge/stranger-walk/anthropic_api_key`) to
    point at a run-scoped Anthropic API key; refuses to launch without one.
- `score.py` — extract milestone timings from a `transcript.jsonl` (works on `run.sh` and
  `run_container.sh` output alike — same run-dir contract).
- `isolation_audit.sh` — grep a transcript for internal-vocabulary boundary hits; also checks a
  container run's `isolation_probe.json` when present. Any hit disqualifies the run.
- `bg_notify_check.py` — protocol v1.1 helper (detect an orphaned background-task notification a `-p`
  process never got to react to).

Run dirs live under `/Users/maxwellstarr/projects/stranger-walk-runs/<run-id>/` (outside the repo,
never committed): `meta.json`, `transcript.jsonl`, `prompt.rendered.md`, plus (container runs only)
`isolation_probe.json`, `container.id`, `container.exit_code`, `credential.env` (mode 600, the run's
own copied API key — never the host's).
