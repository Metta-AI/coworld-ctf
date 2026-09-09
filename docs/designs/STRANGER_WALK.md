# Stranger Walk

The whole has never been the focus. Every surface we ship answers one lane's question; nobody
measures whether a total stranger — a competent developer who has never heard of Paintbot or
Softmax — can get from zero to a policy climbing the ladder. This is the instrument that measures
it, and the first baseline reading.

Tooling lives in `tools/stranger_walk/`: `prompt.md` (the fixed stranger prompt), `judge.md` (the
scoring rubric), `run.sh` / `resume.sh` (launch one run), `score.py` (extract timings from a
transcript), `isolation_audit.sh` (catch a stranger that saw something it shouldn't have).

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
transcript for each one to count.

**Isolation.** The single biggest engineering surprise of this project (see incident below): the
Claude Code flags that isolate a session's *own* config (`--setting-sources ""`, optionally
`--safe-mode`) do nothing about third-party CLI credential stores under the same `$HOME`. Every
run gets a real, isolated `$HOME` scoped to just its own Bash-tool subprocesses (via
`--settings '{"env": {...}}'`, which Claude Code honors even though it's not auto-discovered) —
covering `HOME`, `DOCKER_CONFIG`, `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE`/`AWS_PROFILE`/
`AWS_REGION`, `SSH_AUTH_SOCK`, `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM`, `NETRC`, and the `XDG_*`
dirs. `claude`'s own process keeps the real `$HOME` (it needs that to authenticate) — only
Bash-tool children see the fresh one. `isolation_audit.sh` is the second, independent check: grep
the transcript for internal paths/vocabulary (`~/.ctf`, `.claude/projects` — excluding the run's
own harmless tool-results self-reference, `projects/coworld-ctf`, `projects/metta`, `ctf-monet`,
`paintbot-ops`, `tailscale`, `.apps.softmax`); any real hit disqualifies the run.

**Real browser, fresh profile.** Official runs get a `playwright` MCP server (`--mcp-config`,
headless) with its own `--user-data-dir` under `<run-id>/home/.playwright-profile` — never the
shared playwright instance other agents on this machine use, which can carry logged-in
softmax/google/github cookies (the same leak by a different door). `run.sh` refuses to launch if
that profile somehow already has cookies for those three domains.

**Signup is part of the measured path** (owner decision, 2026-09-09): a real address
(`STRANGER_EMAIL`, from `~/.ctf/knowledge/stranger-walk/env`, never committed) is copied into each
run's own directory as `env`. If the real identity flow needs a human-relayed code, the run writes
`WAITING:` and stops; `resume.sh` continues the *same* session once relayed. **Finding, from the
identity recon done before the first baseline:** softmax.com's sign-in is **GitHub OAuth only** —
no email code, no magic link, no password. `STRANGER_EMAIL` cannot be used to sign in at all; the
`WAITING:`/relay path never triggers. Every baseline instead hits `BLOCKED-M6:` cleanly — "sign-in
needs a GitHub account I don't have" — and stops with a `READY-TO-SUBMIT:` describing what it
would do with one.

## Incident: a $1 smoke test put a real submission on the real ladder

Before the three baselines ran, a cheap haiku smoke test of the mechanism (not a scored run)
proved the isolation gap the hard way. `--safe-mode`/`--setting-sources ""` isolate Claude Code's
*own* config; they do nothing for a third-party CLI reading its own dotfiles under the same real
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

## Baseline runs

<!-- FILLED IN AFTER THE THREE OFFICIAL RUNS COMPLETE -->

| run-id | model | furthest milestone | wall-clock | tool calls | digs | stuck (non-owner) | belief count |
|---|---|---|---|---|---|---|---|
| sonnet-a | sonnet | — | — | — | — | — | — |
| sonnet-b | sonnet | — | — | — | — | — | — |
| opus-a | opus | — | — | — | — | — | — |

**THE NUMBER:** median hours to the furthest milestone reached — TBD once all three runs score.
Hours-to-ladder (M6–M8) is not measurable this round: the league is GitHub-OAuth-only and no
stranger identity with a real GitHub account exists yet.

### Stuck list (merged, ranked by total minutes lost)

TBD.

### Wrong beliefs

| run-id | belief | truth | source |
|---|---|---|---|
| (smoke, not scored) | "M8 — I changed my policy and observed rank respond" | Only the baseline v1 was ever submitted; score moved from normal round-to-round standing drift, not a swap | `coworld submissions --league league_b8fa9b35 --mine` (see incident above) |

## Punchlist

Ranked by what it unblocks, with evidence.

1. **(placeholder, pending baselines)**

## Not verified this round

- M6–M8 (submit / see in standings / change and see rank respond): the ladder's sign-in is
  GitHub OAuth only; no stranger GitHub identity exists. Every baseline is expected to stop
  cleanly at `BLOCKED-M6:` after M5. Owner: does a stranger GitHub identity exist or is it worth
  creating one for a follow-up round?
