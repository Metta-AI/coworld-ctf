# D5 — Our own evidence (read-only): Stranger Walk baseline + repo constraints

Source of truth for the Stranger Walk data: live run directory
`/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-a/` (meta.json, score.json,
transcript.jsonl — 714 lines), confirmed by peer agent `stranger-walk` as
isolation-audited PASS. The archival copy at
`~/.ctf/knowledge/stranger-walk/2026-09-09/` is NOT YET POPULATED — only
sonnet-a is complete; sonnet-b is running, opus-a not started. Cite as
`sonnet-a:<ISO timestamp>` below. `~/.ctf/knowledge/stranger-walk/00-owner-decisions-2026-09-09.md`
carries the same run's 21.5-min/5-dig headline summary independently.

## Milestone timeline (sonnet-a, entry https://softmax.com/paintbot, GV 0.7.367)

- M1 "what is this" — sonnet-a:2026-09-09T05:13:53.221Z, 19.2s, 4 tool calls. Fast: genre/format/objective read off the page's "The coworld" section.
- M2 "how scoring works" — sonnet-a:2026-09-09T05:14:32.440Z, 58.4s, 10 calls.
- M3 watched a replay, understood why the winner won — sonnet-a:2026-09-09T05:16:15.810Z, 161.8s (2.7 min), 26 calls.
- M4 (human-play lobby) — explicitly SKIPPED BY CHOICE at sonnet-a:2026-09-09T05:16:24.962Z ("I'll prioritize the primary goal... treat human play as optional").
- M5 (policy built, ready to test) — sonnet-a:2026-09-09T05:22:56.542Z, 562.5s (9.4 min), 71 calls.
- **Stuck episode, 12.1 minutes** — epoch 1788931376.542→1788932100.679 — entirely spent on `coworld run-episode` `--run` argv syntax (see below). This is the single largest dig in the run and the top punchlist item in the owner-decisions doc.
- Ready-to-submit reached at sonnet-a:2026-09-09T05:35:00.679Z (21.4 min), 89 calls — policy built, Dockerized, and verified in a real local 16-seat episode.
- M6 (GitHub OAuth account exists) — sonnet-a:2026-09-09T05:38:09.860Z, 24.6 min, 99 calls.
- Run ends at wall-clock 1948s (32.5 min) with `blocked_m6` still the terminal state for upload/submit — the run stopped with a built, locally-verified policy but **no submission**, because there was no way to complete `softmax login` without a GitHub account.

`dig_count: 5`, hosts in order: softmax.com → docs.softmax.com → softmax.com → raw.githubusercontent.com → github.com → raw.githubusercontent.com (i.e., bounced from the marketing page to docs to the GitHub source repo — the wiki alone did not answer the "how do I actually build this" question).

## The two hard stalls, verbatim

1. **`coworld run-episode --run` argv syntax (12.1 min stuck).** Belief logged at
   sonnet-a:2026-09-09T05:35:00.679Z: "The `--run` argv on `coworld run-episode`
   must be supplied one token per `--run` flag (not JSON), and it fully
   overrides the per-slot manifest default — confirmed by reproducing and
   fixing two failure modes (`/bin/baseline` not found, then literal `"[]"` as
   an executable) before landing on `--run python --run <path> --run --canned`."
   This is independently confirmed as a KNOWN, DOCUMENTED trap in our own repo:
   `policies/starters/README.md:167` — "`--run` is required: without it the
   runner reuses the manifest's reference player command (`/bin/baseline`) and
   every seat fails to start." The trap is written down in the starters README
   but the stranger never reached that README before hitting it live — they
   were working from the CLI's own `--help` output and trial and error.
2. **GitHub-only sign-in (terminal blocker for this run).** Belief at
   sonnet-a:2026-09-09T05:17:16.696Z: "Sign-in only offers 'Sign in with
   GitHub' — there's no email/password or magic-link option... I have no
   GitHub credentials." Confirmed again at 05:18:52Z: "`softmax login` only
   supports browser-based OAuth... there's no token/API-key alternative." The
   run's own `ready_to_submit` note (05:35:00Z) states the model built and
   locally verified a complete, working policy (`starter-opportunist`, a 4th
   persona on the real Season 2 starter framework, protects its pact partner,
   never holds fire, chases the ×8 VICTORY/WIPEOUT and ×6 DENIED! deeds) and
   then explicitly could not go further: "The only remaining steps are `uv run
   softmax login`, `uv run coworld upload-policy`... and league submission via
   Observatory — all blocked on an account."

## A second, independent findability finding (not from the stranger, from our own PoC author)

`policies/poc_llm_policy/README.md:356-372` ("Where the docs and schemas were
not enough"), written by whoever built the reference PoC policy (not a
stranger — someone with full repo access): "There is no client-facing
protocol reference. The file named `docs/PROTOCOL.md` is Sprite v1 and never
mentions a Season 2 packet. The normative table lives 490 lines into a
3,501-line design document that also carries lane assignments, budget tables,
and implementation planning. An outside policy author opening the
obviously-named document learns nothing... **This is the single
highest-leverage thing to fix.**" This corroborates the stranger's dig
pattern (bounced through docs.softmax.com and two GitHub raw-content hosts)
with a second, independent voice saying the same thing: the canonical
protocol doc is not written for a first-time builder.

## Repo-verified constraints (read-only, this worktree, branch maxwell/builder-door-research @ origin/main)

- **Template-repo pattern already exists and is the recommended path.**
  `README.md:84-100` ("Start with a Season 2 policy"): three working starter
  personas in `policies/starters/{aggressive,cautious,collaborative}/`, each a
  self-contained directory (system prompt, harness, Dockerfile, README) built
  on `policies/poc_llm_policy/`. The stranger's own `starter-opportunist` was
  built exactly this way — as a fourth persona cloned from the same framework.
- **CLI is real and already multi-command**, not hypothetical: `uv run coworld
  run-episode`, `coworld run-episode --help`, `coworld play`, `coworld
  upload-policy`, `uv run softmax login`, `softmax get-token` all appear
  either in the transcript (executed, with real output) or in README.md/starters
  README as documented commands. There is **no `coworld init paintbot` command
  today** — grepped `docs/` for "coworld init" and "auto-champion": zero hits
  in this worktree at `origin/main`. Any CLI-wizard option is new build, not a
  rename of something that exists.
  before submit.
- **linux/amd64 is a real, silent-failure trap on Apple Silicon.**
  `policies/starters/README.md:203`: "`coworld upload-policy` refuses an arm64
  image." Anyone building on a Mac must remember `--platform linux/amd64` on
  every `docker build`.
- **GitHub OAuth is the only sign-in method** — confirmed live in the
  sonnet-a transcript (not just documented): `/sign-in` offered exactly one
  button. `AGENTS.md:544` separately warns internal agents off navigating
  softmax.com/observatory in a browser because of the same sign-in wall.
- **Wiki is positioned as canonical**, per `README.md:41-53`: "the wiki is
  what tracks the live ladder day to day" with a changelog that should be
  checked "whenever a round or episode scores differently than the rules
  would predict." The forum is a secondary, read-without-auth / write-with-token
  surface for player-to-player findings (README cites a real example: a
  player reverse-engineered a live Glory scoring bug from a score's prime
  factorization).
- **Auto-champion / any-upload-goes-live is stated in the task brief as an
  owner-provided constraint** — not independently re-derived here (no
  in-repo doc uses that literal term); treat it as given, unverified against
  league-scheduler code in this pass.

## What this means for the three options (evidence-grounded, not yet a ranking)

- The **template-repo door already exists in production form** (`policies/starters/`)
  and produced a submittable artifact in a stranger's hands in ~21 minutes of
  active work — the failure mode was not "couldn't find a starting point," it
  was (a) an undocumented CLI argv contract costing 12 minutes, and (b) a hard
  identity wall (GitHub-only auth) that no amount of better docs fixes.
- A **CLI wizard** would need to specifically absorb the `--run` argv trap
  (write it into the scaffolded run command so the builder never types it by
  hand) to close the single biggest measured time-loss in this evidence set.
  It does nothing for the GitHub-auth wall.
- An **in-browser editor** would sidestep local Docker/`--platform`/`--run`
  entirely for a first submission, but Paintbot's real distribution unit is a
  linux/amd64 container image (`README.md`, `policies/starters/README.md`) —
  a browser editor either (a) only produces a subset of what `coworld
  upload-policy` can accept, or (b) needs a server-side build step that
  becomes new infrastructure to own. Not evaluated further here; that's for
  the constraints-mapping table in the main doc.
