# Stranger Walk

The whole has never been the focus. Every surface we ship answers one lane's question; nobody
measures whether a total stranger — a competent developer who has never heard of Paintbot or
Softmax — can get from zero to a policy climbing the ladder. This is the instrument that measures
it, and the first baseline reading (**Walk 1**).

> **Read this first: Walk 1 (below) is INVALID as a discovery baseline.** Its prompt handed the
> stranger the eight milestones by name and asked it to narrate them — scaffolding, not
> discovery. It's still valid as a defect punchlist. See "Protocol v2" below for the ruling, the
> fix, and the clean baseline this document now points to.

Tooling lives in `tools/stranger_walk/`: `prompt.md` (the fixed stranger prompt), `judge.md` (the
scoring rubric), `run.sh` / `resume.sh` (launch/continue one run), `launch.sh` (protocol v1.2 —
launch a run fully detached), `score.py` (extract timings from a transcript), `isolation_audit.sh`
(catch a stranger that saw something it shouldn't have), `run_container.sh` + `container/` (protocol
v1.3 — the same run, inside its own Linux container: own PID namespace, own filesystem, own network).

## Protocol, in one page

**Entry point.** The public URL a stranger would actually be handed today: **`https://softmax.com/paintbot`**.
Memory going in claimed the canonical human URL was tailnet-only and served the wrong app — that's
true of `paintbot.apps.softmax.com` and of trying to reuse the wiki publisher as a hosting path,
but it is *not* what a stranger is handed: `softmax.com` is the real public site, and
`/paintbot` is a real, working, public page with standings, a description, and links to
`/paintbot/play`, `/paintbot/forum`, `/paintbot/wiki/main`, and `/observatory/v2`. That in itself
is a finding worth recording: the public entry point is fine; nobody had actually walked it end to
end as a first-time visitor before.

**The stranger.** A fresh `claude -p` process per run, cwd = a brand-new directory under
`/Users/maxwellstarr/projects/stranger-walk-runs/<run-id>/`, given only `prompt.md` (with the
entry URL substituted) as its instructions. It thinks aloud (`BELIEF:` lines), announces
milestones (`MILESTONE: M<n>`), and stops cleanly at one of: `M8` reached, `READY-TO-SUBMIT:`
(credentials/identity absent), `BLOCKED-M6:` (the site needs an identity provider it can't
self-serve), `WAITING:` (needs a human-relayed code — see below), or `GIVE-UP:` (stuck 30 min or
3 hours elapsed).

**Milestones.** M1 knows what the game is · M2 states the top ways to score · M3 watches a round
and explains why the winner won · M4 takes a seat and plays · M5 builds a policy from what it
finds · M6 submits · M7 sees it in standings · M8 changes it and sees rank respond. A
`MILESTONE:` line is a claim, not proof — `judge.md` defines what actually has to be true in the
transcript for each one to count. Runs are free to skip an unreachable/inapplicable milestone (all
five Walk 1 runs skipped or deferred M4 — see below) and to hit them out of order.

**Isolation (`$HOME`/config/cookies).** The single biggest engineering surprise of this project
(see incident below): the Claude Code flags that isolate a session's *own* config
(`--setting-sources ""`, optionally `--safe-mode`) do nothing about third-party CLI credential
stores under the same `$HOME`. Every run gets a real, isolated `$HOME` scoped to just its own
Bash-tool subprocesses (via `--settings '{"env": {...}}'`, which Claude Code honors even though
it's not auto-discovered) — covering `HOME`, `DOCKER_CONFIG`, `AWS_CONFIG_FILE`/
`AWS_SHARED_CREDENTIALS_FILE`/`AWS_PROFILE`/`AWS_REGION`, `SSH_AUTH_SOCK`,
`GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM`, `NETRC`, and the `XDG_*` dirs. `claude`'s own process
keeps the real `$HOME` (it needs that to authenticate) — only Bash-tool children see the fresh
one. `isolation_audit.sh` is the second, independent check: grep the transcript for internal
paths/vocabulary (`~/.ctf`, `.claude/projects` — excluding the run's own harmless tool-results
self-reference, `projects/coworld-ctf`, `projects/metta`, `ctf-monet`, `paintbot-ops`,
`tailscale`, `.apps.softmax`); any real hit disqualifies the run.

**Isolation gap found in Walk 1, NOT fixed (process-table visibility).** `sonnet-c` ran
`ps aux | grep -E "coworld|upload"` — ordinary, reasonable behavior for a stranger checking on its
own backgrounded upload — and was disqualified: `ps aux` is not scoped by the `$HOME` fix at all
(process listing is a kernel/OS property, not a per-process environment variable), so it returned
the *entire host's* process table. Its own narrow grep still matched two unrelated
orchestration/harness processes because their command lines embed the literal path
`/Users/maxwellstarr/projects/coworld-ctf/...`, which contains "coworld" as a substring —
real internal absolute paths and model identifiers leaked through a filter that had no intention
of looking for them. This is a distinct gap from the `$HOME` fix and from protocol v1.2 below; it
is **not fixed this round** (would need real process-namespace/container isolation, out of scope
for a bash-launched `-p` process on macOS with no container runtime available) — see "Not verified
this round." Per the existing rule, any hit disqualifies and the run is discarded and rerun once;
that's what happened (`sonnet-c` → `sonnet-d`).

**Real browser, fresh profile.** Official runs get a `playwright` MCP server (`--mcp-config`,
headless) with its own `--user-data-dir` under `<run-id>/home/.playwright-profile` — never the
shared playwright instance other agents on this machine use, which can carry logged-in
softmax/google/github cookies (the same leak by a different door). `run.sh` refuses to launch if
that profile somehow already has cookies for those three domains.

**Signing up is part of the measured path** (owner decision, 2026-09-09): the stranger's own
working directory gets a copy of `~/.ctf/knowledge/stranger-walk/env` (never committed) as `env`.
**Finding superseded during Walk 1:** the identity-recon note going into this walk said sign-in is
GitHub-OAuth-only with no self-serve path, so every run would hit `BLOCKED-M6:` and stop at
`READY-TO-SUBMIT:`. That was true when only `STRANGER_EMAIL` existed in `env`. Since then the
owner added real `GITHUB_USER`/`GITHUB_PASS` to the same `env` file, and **all five Walk 1
runs used them to complete the real GitHub OAuth flow themselves** (`prompt.md` never mentions
these variables by name — every run independently discovered and used them because rule 3 tells
it to check its own working directory for `env`, and rule 5 doesn't forbid using what's already
there). No `prompt.md` change was needed, so this isn't a protocol-version bump — it's a
same-account signup unlock, and it means **M6–M8 were fully measurable this round**, contrary to
the pre-walk expectation. One direct consequence: all five runs share the *same* underlying
GitHub/Softmax account (confirmed independently — `sonnet-b`'s own transcript flagged "another
concurrent process is using this same shared throwaway account"), which is why the "one live
stranger identity submitting at a time" rule exists and why every run's live ladder submissions
get withdrawn as soon as it's scored (ledger at the bottom of this doc).

## Protocol v1.1: background-notification loss in `-p` mode (2026-09-09, `sonnet-a` finding)

Interactively, a backgrounded shell command finishing re-invokes the agent with a notification.
`claude -p` (non-interactive) does not: the process exits at `end_turn` and the harness kills any
still-running backgrounded task as a side effect of that exit — before it necessarily finished
naturally. `sonnet-a` hit this directly: it backgrounded its own `coworld upload-policy`, said
"I'll wait for the notification," and then the process ended its turn without ever seeing one.

Fix, in `tools/stranger_walk/bg_notify_check.py` + both `run.sh` and `resume.sh`: after every
`claude -p` invocation exits, scan the transcript for a `system`/`task_notification` event with no
turn after it to consume it — a task the harness reports on but the process never got to react to.
If found, feed the *same session* (`claude -p --resume <session_id>`) a synthesized message
describing what was interrupted and its captured output tail (as close as `-p` mode allows to what
an interactive session would have delivered), and loop — up to `STRANGER_MAX_AUTO_CONTINUE` (3)
times — before handing control back. These auto-continues are tagged `"kind": "auto_continue"` in
`meta.json`'s `resumes[]` (distinct from `"owner_relay"`, a human-relayed signup code) and are
**not** counted as owner latency in `score.py`'s stuck-time totals. `sonnet-a` needed one manual
resume (this fix predates it) and one auto-continue; `opus-a` and `sonnet-c` each triggered exactly
one auto-continue cleanly under this fix, both completing normally afterward.

## Protocol v1.2: detached launch (2026-09-09, `sonnet-b` finding)

`sonnet-b` was killed mid-run (`SIGKILL`, exit 137) at `2026-09-09T06:42:43Z`, 67.5 minutes in,
mid-progress (it had just made `v3` champion and was waiting for the next round). Root cause: the
`claude -p` stranger process `run.sh` execs stays in the process group of whatever shell launched
`run.sh`; the previous S2-lead session had started it as a background call and then closed, and
the harness tore down that whole process group — including the still-running, still-progressing
stranger — as a normal side effect of the session exiting. Nothing about the stranger's own
behavior caused this.

Fix: `tools/stranger_walk/launch.sh <run.sh|resume.sh> <args...>` launches the target script fully
**detached** — its own session, its own process group, stdio pointed at files up front:

- `os.setsid()`, via a tiny inline `python3 -c` shim (macOS ships no `setsid(1)` binary — that's a
  util-linux tool, absent by default on Darwin), puts the child in a brand-new session before
  `os.execvp`-ing into the real target. A process-group-directed signal to the OLD group no longer
  reaches it.
- `nohup` additionally makes it immune to `SIGHUP` specifically.
- `</dev/null` and redirecting stdout/stderr to a file *before* backgrounding means the child never
  blocks on, or is affected by, a pipe/fd the parent session owns.
- `disown` drops the launching shell's own job-table reference.

**Verified empirically** (not just by inspection): a `sleep`-based smoke test showed the detached
child's `PPID` reparent to `1` and its own new `SID` immediately after backgrounding, and — the
real test — after the *launching* Bash-tool process had itself already exited (each Bash tool call
here is its own short-lived process), the detached child was still alive, running under `PPID=1`,
and ran to completion normally. `opus-a` and `sonnet-d` both then completed full real runs (1.17h
and 0.68h) via `launch.sh` with zero teardown incidents, including `opus-a` surviving one
protocol-v1.1 auto-continue cycle mid-run.

Usage: `tools/stranger_walk/launch.sh run.sh <model> <run-id> [max-budget-usd]`. The dispatcher
gets the PID back immediately and polls (never a backgrounded "wait for the notification" itself —
that pattern is exactly what killed `sonnet-b` one layer up): `while kill -0 "$(cat
<run-dir>/launch.pid)" 2>/dev/null; do sleep 60; done`, or poll `meta.json`'s `run_status`.

## Protocol v1.3: container isolation (2026-09-09, closes the process-table gap)

Walk 1 left one gap explicitly unfixed (see above, "Isolation gap found in Walk 1, NOT fixed"):
`sonnet-c` ran an ordinary `ps aux | grep coworld` and got back the HOST's entire process table —
`run.sh`'s isolated-`$HOME` trick scopes environment variables for Bash-tool subprocesses, not the
OS-level process list, which is a kernel property `$HOME` cannot touch. Real internal paths and
model identifiers leaked through a grep that had no intention of finding them. This needed real
process/filesystem/network-namespace isolation, which a bare `-p` process on macOS with no
container runtime available (the situation Walk 1 shipped under) does not have.

**What changed.** `tools/stranger_walk/run_container.sh` + `tools/stranger_walk/container/{Dockerfile,
entrypoint.sh,probe.sh}` run the stranger inside its own Linux container instead of a bare process
on the host: own PID namespace (`ps aux` can only ever see that container's own processes), own
filesystem (no `/Users`, no `~/.softmax`, `~/.ctf`, `~/.claude/projects` — the image ships none of
this project's tooling or vocabulary, only a plain developer toolbox: git, curl, python3, uv, the
`docker` CLI, and Claude Code itself), own network namespace (bridged — reaches the public internet,
cannot reach anything bound to the HOST's `127.0.0.1`). The run-dir *contract* is unchanged: same
`/Users/maxwellstarr/projects/stranger-walk-runs/<run-id>/` layout, `meta.json`, `transcript.jsonl`,
`prompt.rendered.md` — `score.py` and `isolation_audit.sh` work on a container run's output exactly
as they do on a `run.sh` run's.

**What closes it.** `tools/stranger_walk/container/probe.sh` is a scripted, non-`claude` probe (no
Anthropic credential needed) that runs inside the container and checks, for real, each time: (1)
`ps aux` shows only this namespace's own processes, no host path/vocabulary; (2) `/Users` is absent;
(3) none of `~/.softmax`, `~/.claude/projects`, `~/.ctf`, `~/.aws` exist; (4) `env` carries no host
username/path string; (5) this process's own PID namespace has its own PID-1 init, not the host's;
(6) network reaches `https://softmax.com/paintbot`; (7) network does *not* reach the container's own
loopback (nothing of the host's is bound there). Result is written to `isolation_probe.json` in the
run dir; `isolation_audit.sh` now reads it when present and treats any failed check as a disqualifying
hit, same severity as a transcript boundary hit. **Verified empirically 2026-09-09** (all 7 checks,
run for real — not just inspected — via `run_container.sh probe <run-id>`): `overall_pass: true`.
Honesty note carried in `probe.sh`'s own header: checks 2 and part of 4 are trivially true on *any*
stock Linux container regardless of isolation quality (`/Users` is a macOS path, full stop) — the
checks that actually exercise isolation are 1, 3, 5, and 7.

**Credential contract** (the one genuinely new problem a container introduces): `run.sh` reuses the
HOST's own `claude` OAuth session — its top-level process deliberately keeps the real `$HOME` so it
can authenticate; only Bash-tool subprocesses get an isolated `$HOME`. A container has **no** host
`$HOME` at all (`$HOME` is `/home/stranger` for every process in it, `claude` included), so it needs
its own credential, and that credential must never be the host's `~/.claude`:
- **Source**: an Anthropic API key, one line, at `$STRANGER_ANTHROPIC_API_KEY_FILE` (default
  `~/.ctf/knowledge/stranger-walk/anthropic_api_key`, never committed — same convention as
  `run.sh`'s `STRANGER_OWNER_ENV` for the site-signup identity).
- **Injection**: `run_container.sh` copies it into `$RUN_DIR/credential.env` (mode 600) and passes it
  to `docker run --env-file` — never baked into the image, never a `docker run -e` CLI arg (those are
  more visible in `docker inspect`/process listings than an env-file's contents), never a mounted
  `~/.claude` directory in any form.
- **No fallback**: if that file is absent, `run_container.sh` refuses to launch a real/smoke `run`
  and says so — there is no silent "reuse whatever `claude` happens to already be authenticated as."
  That silent-reuse path is exactly what caused the 2026-09-09 real-ladder-submission incident below
  for third-party CLI credential stores; a container makes the same mistake strictly worse (it would
  require handing the container the host's own credential store wholesale).
- **One-line launch, once a key file exists**: `tools/stranger_walk/run_container.sh sonnet
  <run-id>` for a real baseline, or `STRANGER_SMOKE=1 tools/stranger_walk/run_container.sh sonnet
  <run-id>` for a mechanism smoke test (hard-stops at M5, same guarantee as `run.sh`'s smoke path —
  verified: see below). `probe`/`selftest` modes need no credential (`run_container.sh probe
  <run-id>` / `run_container.sh selftest <run-id>`).

**Verified empirically 2026-09-09, with a placeholder (non-functional) key, not a real credential**
(this task was scoped to never mint or spend a real Anthropic credential; see "What v1.3 does not
verify" below): `STRANGER_SMOKE=1 STRANGER_ANTHROPIC_API_KEY_FILE=<placeholder> run_container.sh
sonnet maxwell-c1-smoke` ran the full pipeline end-to-end — image build, container launch as the
invoking host user's own non-root `uid:gid` (a real bug found and fixed along the way: `claude
--permission-mode bypassPermissions` refuses to start as root/sudo, so the container cannot run as
root — see `run_container.sh`'s header), `claude -p` genuinely attempting authentication (transcript
shows real `401 authentication_failed` `api_retry` events, 10/10 attempts, real backoff, ~187s wall
clock — this is not a stub, `claude` really tried and really failed), `docker wait` blocking for the
container's real exit, and `meta.json`/`transcript.jsonl`/`isolation_probe.json` produced in the
exact run-dir layout `score.py` and `isolation_audit.sh` already expect. Both tools ran clean against
this run's output (`score.py`: 0 milestones, correctly — no assistant turn ever ran; `isolation_audit.sh`:
PASS, including the new probe-check path, verified both for a real pass and, separately, a synthetic
forced-failure copy of the same `isolation_probe.json` to confirm the fail path actually disqualifies).

**Compatibility with protocol v2 (branch `maxwell/walk-protocol-v2`, replacing `prompt.md`).**
`run_container.sh` never hard-codes prompt text: like `run.sh`, it reads whichever of `prompt.md` /
`smoke_prompt.md` is present in `tools/stranger_walk/` **at invocation time** and renders it into
`$RUN_DIR/prompt.rendered.md`, which is what the container actually receives (bind-mounted, read at
container start). Whatever v2 lands as the new `prompt.md` is picked up automatically, no launcher
change needed.

**What v1.3 still does not close:**
- **No real `claude -p` run against a working credential was exercised by this task**, by design — no
  Anthropic API key was minted or extracted for this proof, only a placeholder used to prove the
  pipeline (see above). The mechanism is proven; a real baseline run through the container has not
  been. Whoever runs the first real container baseline should confirm a full walk still reaches its
  usual milestones (M1–M8) the same way it does through `run.sh` — nothing about the container should
  change *that*, but it hasn't been observed.
- **Docker socket / policy-image builds**: the image ships the `docker` CLI (no daemon) so `docker
  build` is on `PATH`, but with no socket mounted it cannot reach any daemon — a stranger that decides
  to build a policy image this way hits a dead end. `run_container.sh`'s `STRANGER_ENABLE_DOCKER_SOCKET=1`
  flag mounts the HOST's `/var/run/docker.sock`, which grants the container root-equivalent control of
  the host's docker daemon — create/exec/mount arbitrary host paths into *any* container on the host,
  not a scoped grant. Off by default; use only if a real walk demonstrates it actually needs to build a
  policy image (no evidence from Walk 1 that it does — see the "Signing up is part of the measured
  path" section above; every real run submitted via `coworld upload-policy`/`coworld submit`, no
  `docker build` involved).
- **No browser inside the container.** `run.sh`'s official (non-smoke) runs get a headless `playwright`
  MCP server with its own fresh profile; `run_container.sh` does not wire this up (would need a
  Chromium install in the image plus the same MCP config `run.sh` already renders) — out of scope for
  this pass, flagged for whoever runs the next real container baseline.
- **Container-escape / kernel-level isolation is only as strong as the container runtime** (OrbStack,
  here). This closes the specific gap Walk 1 found (process table, filesystem, network) — it is not a
  claim of hardened-sandbox/gVisor-grade isolation against a genuinely adversarial process.

## Protocol v2: the prompt was scaffolding, not discovery (2026-09-09, owner ruling)

Owner ruling, after reviewing Walk 1's five runs: `prompt.md`'s "Announce milestones" rule (the
old rule 2) handed the stranger the exact eight-item list — M1 knows the game, M2 top ways to
score, ... M8 changed it and saw rank respond — and told it to narrate `BELIEF: `/`MILESTONE: `
lines the moment it formed them. That primes a stranger to go looking for exactly the eight things
being measured; it is not what an unprompted stranger would naturally do on its own. **Walk 1's
five runs (`sonnet-a`, `sonnet-b`, `opus-a`, `sonnet-c`, `sonnet-d`) are therefore INVALID as a
"did the game explain itself with zero help" baseline.** They remain valid for a narrower claim:
every concrete defect they surfaced (the stale wiki protocol page, the silently-required
"Institution" field, the `--run` argv footgun, the 404ing free-play field, the shared-account
collision, the qualification-wait documentation gap, and the rest below) is real regardless of how
the run was prompted, because those are properties of the site/CLI, not artifacts of the
stranger's instructions. What Walk 1 can no longer support is any claim shaped like "a stranger
naturally reaches M-such-and-such in N minutes" or "a stranger naturally forms belief X at this
point" — those numbers are contaminated by the milestone list being handed out in advance.

Protocol v2's `prompt.md` (see that file) strips the prompt to the owner's own one-paragraph goal
statement plus the mechanics that are genuine operational necessities, not scaffolding (checking
the working directory for an `env` file; the `WAITING: ` handshake for a human-relayed signup
code — kept because `resume.sh` needs it to know a run is paused on a human, not stuck or done).
It says nothing about milestones, beliefs, or the words "blocked"/"ready." `judge.md` and
`score.py` moved milestone/belief extraction to a post-hoc step: the judge reads the plain
think-aloud transcript after the run and decides, using outside knowledge the stranger never had,
where each M1–M8 was actually reached and what beliefs were stated and whether they were true —
there's no longer a self-report to grade against. `score.py`'s mechanical layer (tool-call counts,
digs, stuck-episode timing) stays transcript-derived either way; see that file's docstring for one
caveat found while rebuilding it — the new stuck-episode signal (gaps between assistant turns) is
coarser than v1's marker-gap version, since a genuinely-waiting stranger tends to check in every
30-300 seconds rather than fall silent, so `stuck_minutes_total` is now a lower bound the judge
should double-check against the transcript, not a measurement.

The clean, un-scaffolded baseline — the one THE WHOLE epic's before/after comparison actually
needs — runs under Protocol v2's `prompt.md` through `run_container.sh` (Protocol v1.3, above),
combining both fixes: no milestone-list scaffolding and real container-level process/filesystem/
network isolation instead of the bash-launched `-p` process's `$HOME`-scoping-only approach.
`run_container.sh` reads whichever `prompt.md`/`smoke_prompt.md` is present at invocation time, so
it already picks up Protocol v2's prompt with no launcher change (see v1.3's "Compatibility with
protocol v2" note above) — what's still missing is a real, credentialed, scored run through that
combined path (v1.3 only proved the container pipeline with a placeholder key; no Protocol v2 run,
container or otherwise, has been scored yet). Walk 1's numbers stay in this document as a
historical record and a defect punchlist, explicitly relabeled: not a baseline.

**Verified working end-to-end under Protocol v2 (2026-09-09):** a haiku smoke run
(`smoketest-v2-1`, `STRANGER_SMOKE=1`) using the new `smoke_prompt.md` completed in 115s, stopped
of its own accord before any login/signup/submit action (hard-stop verified both by the model's
own words and by `run.sh`'s independent post-hoc grep for `login`/`upload-policy`/`submit`/
`exchange-code` — PASS, zero hits), produced a `meta.json` with a `prompt_sha256` binding it to
the exact new prompt text, scored cleanly with the new `score.py` (mechanical fields populated,
`milestones`/`beliefs` correctly left empty pending judge extraction, as designed), and passed
`isolation_audit.sh` with no boundary hits. No real ladder run was launched for this
verification — a scored Protocol v2 baseline is separate, future work.

## Incident: a $1 smoke test put a real submission on the real ladder

Before the baselines ran, a cheap haiku smoke test of the mechanism (not a scored run) proved the
isolation gap the hard way. `--safe-mode`/`--setting-sources ""` isolate Claude Code's *own*
config; they do nothing for a third-party CLI reading its own dotfiles under the same real
`$HOME`. The smoke test ran `uv run softmax login --no-browser`, which silently authenticated as
the real `softmaxwell` account (via `~/.softmax/credentials.yaml`) — its own `coworld submissions`
output immediately showed the real account's full history (Monet v1–v48, Picasso v28–v59) — then
placed a real submission (`sub_f466e574-7eec-493e-9ca7-abf2d348be72`) on the real live
"Paintbot (Season 2)" league / division `div_aa7825db-262f-4a62-b01a-177c1b48f7ee`.

Read-only recon confirmed the blast radius was contained to that one entry: the real house
policy (Monet, pv `34a345fe-9f3b-49d6-ae80-ac1a50d16791`, v48) was untouched before and after: no
Monet submission or image exists after the incident's timestamp. Of the three local policy
variants the smoke test built, only the first ("baseline") was ever actually `coworld submit`-ted;
"aggressive" and "collaborative" were uploaded as images but never submitted — the "M8, rank
responded to my change" the stranger claimed was real round-to-round standing drift on the *same*
v1 entry, not a policy swap. A wrong belief, and a reminder that self-reported milestones need
verification even when the tool calls look plausible.

Owner-authorized cleanup: `coworld retire-membership lpm_7b8dcacb-023e-4506-91df-5b79a2a44f64
--reason "..."` — membership now `disqualified`/`inactive`. Its already-played rounds (875) still
show in `coworld results`; that's the results ledger keeping history, not a live re-entry — an era
note, not a live-state one.

**Fix, verified:** an isolated `$HOME` scoped to Bash-tool subprocesses only (see Protocol above).
Re-running the exact command that leaked the real account, under the fix, now correctly fails with
"Interactive login requires a TTY" and points at a fresh `https://softmax.com/cli-auth` flow —
no ambient identity reachable. Every smoke test since additionally runs a hard-stop-at-M5 prompt
variant (`smoke_prompt.md`) that never attempts login/upload/submit by construction, checked by a
post-run guard in `run.sh` that inspects actual Bash commands (not just any mention of the words —
the first version of that guard false-positived on the prompt text quoting its own rules).

## Era: which build each run played under

Origin/main went red→green mid-walk (unpinned Nim 2.2.12 drift broke the `hello_play` fuel golden;
fixed by pinning to 2.2.10 at `9b6019aa`, #487) and the ladder itself moved builds mid-walk:
`paintbot-v0.7.367` (GloryVersion 15 / GameVersion 60) was live through `2026-09-09T07:24Z`, when
`paintbot-v0.7.369` @ `070d4805` (GloryVersion 16 / GameVersion 61) deployed — the first round
after that time runs the new build. Separately, the public repo `main` a stranger clones has
carried GloryVersion-16 code since #477 (`62fa0146`) since *before* Walk 1 started — so a
stranger's own locally-built/reasoned-about glory rules and the live ladder's actual rules
disagreed until 07:24Z, independent of anything a stranger did.

| run | started (UTC) | tag @ origin/main at start | local `GloryVersion` read | actually played under |
|---|---|---|---|---|
| `sonnet-a` | 05:13:34Z | `paintbot-v0.7.367` | 15 | 0.7.367 / GV15, throughout |
| `sonnet-b` | 05:35:13Z | *(none — main had advanced past the tag)* | 15 | 0.7.367 / GV15, throughout (killed 06:42:43Z, well before the cutover) |
| `opus-a` | 06:56:25Z | *(none)* | 16 | **straddles the cutover**: M6 submit 07:17:14Z pre-cutover; M7 (champion) 07:25:45Z, just after 07:24Z; rounds 4550/4551 failed (platform-wide ~9.9% episode-fulfillment issue per the stranger's own sourced belief, unrelated to the version switch); round 4552 — its first actually-completed round — ran post-cutover under 0.7.369/GV16 |
| `sonnet-c` (DISQUALIFIED) | 08:07:56Z | *(none)* | 16 | 0.7.369 / GV16, throughout |
| `sonnet-d` | 09:05:03Z | *(none)* | 16 | 0.7.369 / GV16, throughout |

## Baseline runs (Walk 1 — INVALID as a discovery baseline; see "Protocol v2" above)

Everything below this line is Protocol v1 data: the stranger was handed the milestone list and
asked to self-report `BELIEF:`/`MILESTONE:` lines. Per the owner ruling above, that makes every
timing/ordering number below a measurement of "how fast a primed stranger checks off a known
list," not "how legible the game is to an unprimed one" — read them as defect evidence, not as
THE baseline. The clean baseline is future work under Protocol v2 + container isolation.

Five runs total. Three complete, isolation-clean runs form the (invalid-as-baseline) set
(`sonnet-a`, `opus-a`,
`sonnet-d`). `sonnet-b` was killed by session teardown mid-progress, not a stranger failure —
reported separately. `sonnet-c` completed a full run but is **disqualified** by the isolation
audit (see the new gap above) — reported separately, discarded per protocol, replaced by
`sonnet-d`.

| run-id | model | furthest milestone | wall-clock | tool calls | digs | stuck (non-owner) | belief count | isolation |
|---|---|---|---|---|---|---|---|---|
| `sonnet-a` | sonnet | M8 | 1.44h | 229 | 5 | 65.6m | 13 | PASS |
| `opus-a` | opus | M8 | 1.17h | 217 | 0 | 13.1m | 20 | PASS |
| `sonnet-d` | sonnet | M8 | 0.68h | 188 | 1 | 31.8m | 6 | PASS |
| `sonnet-b` | sonnet | M7 (killed mid-progress past it) | 1.12h (to kill) | 229 | 2 | 16.8m | 17 | PASS |
| `sonnet-c` | sonnet | M8 | 0.91h | 195 | 2 | 26.1m | 5 | **FAIL — DISQUALIFIED** |

**THE NUMBER: median time to first ladder placement (M7) over the three complete, clean runs =
29.3 minutes** (`opus-a`; `sonnet-a` 47.9 min, `sonnet-d` 20.3 min). Full M1→M8 arc (submit,
appear in standings, retune, watch rank respond) over the same three runs: median **46.3
minutes**, range 40.7–86.6 min. `sonnet-b`'s M7 was reached at 26.7 min before the kill; it went on
to iterate two more versions (both reaching champion status) before being killed at 67.5 min —
reported separately, not counted in the median. `sonnet-c` reached M7 at 29.4 min and full M8 at
0.91h but is excluded from the median as disqualified.

### Per-milestone times (complete runs)

| milestone | `sonnet-a` | `opus-a` | `sonnet-d` |
|---|---|---|---|
| M1 (knows the game) | 0.3 min | 0.5 min | 0.3 min |
| M2 (top scoring levers) | 1.0 min | 1.9 min | 1.3 min |
| M3 (watched a round, explains winner) | 2.7 min | 7.5 min | 2.7 min |
| M4 (human seat) | skipped by choice | 32.2 min (after M7 — see finding below) | skipped |
| M5 (built a policy) | 9.4 min | 12.0 min | — |
| M6 (submitted) | 24.6 min | 20.8 min | 9.0 min |
| M7 (seen in standings) | 47.9 min | 29.3 min | 20.3 min |
| M8 (changed it, rank responded) | 86.6 min | 46.3 min | 40.7 min |

### Where each run landed

- `sonnet-a`: v1 reached champion, played a full round, **rank 12/17**, score 807. v2 (retuned
  `recall_seconds` 8.0→6.0, `max_calls` 6→8) was disqualified before playing a single round on
  Paintbot (Season 2) — a real, observed (if not the hoped-for) response to the change — while
  remaining "competing" in the separate Elite Paintbot league throughout (that membership was not
  touched by this walk — see "Not verified this round").
- `opus-a`: v1 reached champion; v2 (persona retune) moved the standing 8207.7 → 7902.5. **Final:
  rank 18/18**, standing 7635.3 over 7 rounds — last place, but a fully closed loop.
- `sonnet-d`: v1 "aggressive" reached rank 12; v2 "collaborative" moved rank 18→17 for one round
  each (round score 62→70) — the stranger correctly called this "within noise for one round each"
  rather than over-claiming a win.
- `sonnet-b` (killed): v1 → v2 → v3, each reaching champion status in turn, before being killed
  waiting on the round after v3 became champion. Never got a full round's score for any version.
- `sonnet-c` (disqualified): v1 reached **rank #7/18**, 12.4K episode score, 17% win rate — the
  strongest single-round placement of any run this walk — before the isolation hit voided it.

### Finding: M4 (human seat) is unreachable on the live S2 slot config, only on a currently-404ing surface

`opus-a` is the only run that reached M4, and only after M7 (order isn't required). Its own belief,
verified against the actual slot config: "the human seat only works on the *legacy* non-play
variants (`control: "bot"` slots). On `battle-royale-s2` every slot is `control: "play"`, which a
human client cannot drive — so the S2 human seat is only offered through the free-play field, which
is currently 404ing on `/api/field`." Matches prior memory (human play is a fresh match, not a seat
takeover) but adds a new, concrete fact: the free-play surface itself is currently broken.

### Finding: the winner-explains-itself mechanism (M3) is legible, but scoring math needs unpacking

All three complete runs reached M3 quickly (2.7–7.5 min) once they knew where to look (round/replay
pages). Every run independently derived the same underlying fact from the numbers, not from prose:
winning-episode scores factor as small powers of 2 and 3 (`2^a·3^b`) — a stack of `×2`/`×3`/`×8`
multiplicative deed factors, not a linear kill count — and losers cluster near the ordinary-tag
floor. This is a real, repeatable, cross-run-verified finding about how legible the *replay* data
is (once you pull it and do the arithmetic) versus how legible the *wiki prose* is (all three runs
also separately found the `battle-royale-s2` wiki page an empty stub and had to reconstruct the
ruleset from `glory-season-2` + the replay data itself).

### Stuck list (merged, ranked by total minutes lost)

| minutes | run(s) | root cause |
|---|---|---|
| 22.9 | `sonnet-a` | M8 cycle: retune → rebuild Docker image → re-upload → resubmit → re-qualify — the qualification-episode wait dominates, not the stranger's own reasoning |
| 20.5 | `sonnet-d` | same M8 qualification-wait pattern |
| 16.8 | `sonnet-b` | M7 qualification wait (never got a MILESTONE line past this before continuing unlogged to v2/v3) |
| 15.8 | `sonnet-a` | M7 qualification wait |
| 14.8 | `sonnet-a` | path to M6: GitHub OAuth + Softmax "Complete Profile" account setup flow |
| 14.4 | `sonnet-c` | M8 qualification wait |
| 13.1 | `opus-a` | M8 qualification wait |
| 12.1 | `sonnet-a` | `coworld run-episode --run` argv undocumented (one token per `--run` flag, not JSON) — see Upstream fixes |
| 11.7 | `sonnet-c` | M7 qualification wait |
| 11.3 | `sonnet-d` | M7 qualification wait |

**Root cause, ranked #1 by total minutes across every run that reached M7/M8 (126.5 of 153.4
total stuck minutes, 8 of 10 stuck episodes): the platform's own qualification/round-fulfillment
latency after a submit.** No stranger reasoning failure is behind any of these — every run independently
reinvented a polling loop (`sleep N; check status` in a shell `for` loop) because nothing in the
participation guide states a typical qualification time or suggests a poll interval. This is the
single highest-leverage documentation fix available: state the typical qualification wait (looks
like single-digit minutes to ~15 minutes from this data) and give a canonical poll snippet in
`play.md`, so every future stranger doesn't re-derive the same shell loop from scratch.

### Wrong beliefs

| run-id | belief | truth | source |
|---|---|---|---|
| (smoke, not scored) | "M8 — I changed my policy and observed rank respond" | Only the baseline v1 was ever submitted; score moved from normal round-to-round standing drift, not a swap | `coworld submissions --league league_b8fa9b35 --mine` (see incident above) |
| `sonnet-a` | "v2 was disqualified... a genuine response to the change" | True as stated, but the run never separately checked *why* — the far more likely mechanism (consistent with `sonnet-d`'s later finding of noise-level single-round swings) is normal qualification variance, not a signal from the tuning change itself | cross-run comparison; `sonnet-d`'s own explicit "within noise for one round each" caveat on the same kind of change |
| `sonnet-b`, `sonnet-c` (pre-walk assumption, not a run belief) | "Sign-in is GitHub-OAuth-only with no self-serve path — every baseline will hit `BLOCKED-M6:`" | Superseded once `GITHUB_USER`/`GITHUB_PASS` were added to the shared `env` file — all five runs completed real GitHub OAuth and reached M6+ | this walk's own five run transcripts |

## Isolation audits

| run-id | result | detail |
|---|---|---|
| `sonnet-a` | PASS | no boundary hits |
| `sonnet-b` | PASS | no boundary hits (audited post-mortem after the teardown kill) |
| `opus-a` | PASS | no boundary hits |
| `sonnet-c` | **FAIL — DISQUALIFIED** | `ps aux \| grep -E "coworld\|upload"` leaked the full host process table; 2 pattern hits (`projects/coworld-ctf`, `projects/metta`) from harness/orchestration process command lines matched by the stranger's own substring-matching grep on "coworld" — see the new isolation gap noted above |
| `sonnet-d` | PASS | no boundary hits (launched as `sonnet-c`'s replacement) |

## Ladder submission withdrawals (all as the stranger identity, never the owner's)

Every run's live league memberships were retired via `coworld retire-membership <lpm-id>
--reason "..."`, run with that specific run's own isolated `$HOME`/credentials (never the owner's
or another run's), after that run was scored and audited:

- `sonnet-a`: not touched by this task (already finished before this task began; its Paintbot S2
  v1/v2 memberships were already `disqualified`/`inactive` by natural qualification churn — see
  "Not verified this round" for its untouched Elite Paintbot membership).
- `sonnet-b`: `lpm_14f87893` (v1), `lpm_03febcf9` (v2), `lpm_a6f4eff2` (v3, was champion at kill
  time) — all retired.
- `opus-a`: `lpm_3187cc4a` (v1, benched), `lpm_cd89221f` (v2, champion) — both retired.
- `sonnet-c`: `lpm_b2ecab96` (only live one at scoring time; two others had already
  self-disqualified through natural qualification churn before withdrawal) — retired.
- `sonnet-d`: `lpm_e3750786` (v1, benched), `lpm_e4c4d999` (v2, champion) — both retired.

## Upstream fixes

Fixes that belong in the `coworld` CLI itself (built from the `metta` repo, not this one) — proposed
diffs only, no `metta` PR opened per scope.

### `--run` argv is silently repeatable, but the help text doesn't say so (12.1 min lost, 18 calls, `sonnet-a`)

`coworld` package `v0.1.46`, `coworld/cli.py`. Four separate command definitions
(`play` L668, `run-episode` L1061 — the one every stranger actually hits, `certify`-equivalent
L1206, and a fourth L1346) each declare:

```python
run: Annotated[
    list[str] | None,
    typer.Option("--run", help="Command argv for supplied player image(s)."),
] = None,
```

`typer` makes a `list[str]`-typed `Option` repeatable by construction (`--run a --run b --run c`
accumulates `["a", "b", "c"]`), but nothing in the rendered `--help` output says so — it reads as a
single `<str>` value. `sonnet-a` tried, in order: no `--run` at all (wrong image entrypoint), `--run
'[]'` (a literal JSON-array *string*, parsed as one executable path token `"[]"`), `--run '["python",
"/app/.../policy.py"]'` (same mistake, one big JSON string), before landing on the only form that
actually works: `--run python --run /app/policies/starters/opportunist/policy.py --run --canned`.

**Proposed diff** (same fix at all four call sites, `cli.py:668,1061,1206,1346`):

```diff
- typer.Option("--run", help="Command argv for supplied player image(s)."),
+ typer.Option(
+     "--run",
+     help=(
+         "One argv token for the supplied player image's command, repeatable — "
+         "e.g. --run python --run policy.py --run --canned. NOT a JSON array or "
+         "a single shell-quoted string; each token needs its own --run."
+     ),
+ ),
```

## Not verified this round

- **Process-table isolation gap — CLOSED by protocol v1.3** (see that section above): `run_container.sh`
  runs the stranger in its own Linux container (own PID/filesystem/network namespace); `probe.sh`
  proves it for real (7/7 checks, run empirically 2026-09-09). `run.sh` (bare host process) still has
  this gap and is unchanged — v1.3 is a new, additional path, not a replacement of `run.sh`. Not yet
  verified through v1.3: an actual authenticated baseline run (only a placeholder-credential pipeline
  proof exists so far — see v1.3's "What v1.3 still does not close").
- **`sonnet-a`'s Elite Paintbot league membership.** Its own M8 belief states v2 "remained stably
  'competing' in the separate Elite Paintbot league the whole time" — that membership was never
  identified by lpm-id or withdrawn by this task (only its Paintbot Season 2 memberships were
  checked, and those had already self-disqualified naturally). Open risk: a stranger-identity
  submission may still be live on that separate ladder. Owner: confirm and withdraw if so.
  Given every run shares one account, this is a proceeds-to-nagging item, not a
  boundary/blast-radius risk on the order of the earlier real-credential-leak incident.
  <!-- 2026-09-09: sonnet-a is a previous worker's run, completed and scored before this task
  began; leaving its cleanup as an explicit owner decision rather than silently acting on another
  run's account under a different task's authorization. -->
- **Qualification/round-fulfillment latency root-causing.** This walk observed ~9.9%
  episode-fulfillment failure (per `opus-a`'s own sourced belief, citing a same-day changelog note)
  and single-digit-to-teens-of-minutes qualification waits dominating stuck time, but did not dig
  into *why* fulfillment fails ~1 in 10 times — that's a platform-reliability question outside this
  walk's scope, just flagged as the highest-leverage doc fix available (see Upstream fixes' spirit,
  though this one is a `play.md` content fix, not a CLI code fix).
