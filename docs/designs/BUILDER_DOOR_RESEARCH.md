# The builder's door — research (epic 16d081ab, checkpoint draft)

Research only; no product change. Owner question (2026-09-09): template repo
vs guided CLI wizard (`coworld init paintbot`) vs in-browser editor, for a
developer who has never heard of Paintbot. This is a **checkpoint draft** —
sections marked **TODO** were not finished before this session closed;
everything else is fully sourced.

## Status of this pass

Done: browser-editor/notebook reference platforms (CodinGame, Lichess bot
API, Kaggle Simulations ConnectX/Halite IV, Lux AI Challenge), published DX
evidence (time-to-hello-world, CLI wizard vs template, in-browser completion
data, GitHub/Stripe/Vercel/academic HCI), and our own evidence (Stranger Walk
sonnet-a baseline + repo-verified constraints).

**TODO — not researched this pass:** Kaggle competitions (general), MIT
Battlecode, Halite by Two Sigma (original, pre-Kaggle), Screeps, Robocode
(local-first/template platforms); Terminal by Correlation One, Google AI
Challenge (Ants/Planet Wars), AWS DeepRacer (CLI-first platforms). Raw
per-dimension files for what IS done live at
`~/.ctf/knowledge/stranger-walk/builder-door-research/dimensions/`.

## 1. Reference findings (sourced; confidence marked)

**No platform researched in this pass publishes a time-to-first-submission
or onboarding-dropout metric, anywhere.** This was checked across CodinGame,
Lichess, Kaggle ConnectX, Kaggle Halite IV, and Lux AI — confirmed absent,
not merely unfound. Any number claimed for this metric elsewhere should be
treated as fabricated.

- **CodinGame** [HIGH, codingame.com/blog]: pure browser IDE, no local
  install ever. A scripted "Onboarding" tutorial puzzle teaches IDE mechanics
  first (~10–15 min, community-reported [MEDIUM]). Bot-programming contests
  layer a League/Boss ladder (Wood→Legend) explicitly redesigned from a flat
  ruleset because newcomers need to "gradually discover more rules... rather
  than being dropped into the full ruleset immediately" (CodinGame's own
  blog). Works because the artifact is text-in/text-out code the site
  executes directly — there is no bring-your-own-image step.
- **Lichess bot API** [HIGH, official README]: hybrid, not a browser editor —
  create a dedicated BOT account (one-way, must be unused), generate an OAuth
  token, clone `lichess-bot` locally, point it at a local chess-engine
  binary, run. Lichess's own 2018 blog explains the *why* for the separate
  account type: opening the API to normal accounts would defeat both their
  anti-cheat mechanisms.
- **Kaggle Simulations (ConnectX, Halite IV)** [HIGH, kaggle-environments +
  kaggle-cli READMEs]: dual path — fork a notebook, or `pip install
  kaggle-environments` locally — both converge on the same `kaggle
  competitions submit` CLI call. Halite's move from Two Sigma's own
  standalone platform (v1–3) to Kaggle-hosted notebooks (v4, 2020) is a
  confirmed, dated platform migration [HIGH for what/when], but no primary
  source states *why* [LOW for the rationale — inferred as reuse of Kaggle's
  existing users/ladder infra].
- **Lux AI Challenge** [HIGH, official README, directly quoted]: explicit
  dual path stated in the README itself — CLI/local (`npm install -g
  @lux-ai/...`, run a match offline against another bot binary, TrueSkill
  leaderboard locally) is the primary documented path; a from-scratch
  Kaggle-notebook tutorial is offered as an explicit skip-the-CLI alternative
  for Python users, both converging on the same Kaggle submission endpoint.

**Pattern across every dual-path platform found:** the browser/notebook path
is offered *alongside* a local/CLI path, converging on one submission
mechanism — never as the only path, and never as a different submission
artifact. No platform in this set requires the described game-arbitrary-code
artifact (a container image) as its submission unit; all of them submit a
function/script the platform's own runtime executes. This is a real paradigm
difference from Paintbot (see §3).

## 2. Published DX evidence (sourced; confidence marked)

- **Time-to-hello-world has no independent benchmark study anywhere.** Best
  evidence is single-company before/after deltas: Twilio reports 62% lift in
  first-message activation after an onboarding redesign [MEDIUM, Twilio's own
  blog, no methodology disclosed]; GitHub cut its own engineer bootstrap time
  45 min → 5 min → 10 sec via Codespaces prebuilds [MEDIUM-HIGH, GitHub's own
  eng blog]. Stripe is *repeatedly cited* as the TTFC gold standard by
  third-party DX blogs, but **no primary Stripe number exists anywhere in
  sources reached** — treat "Stripe is the benchmark" as reputation, not data.
- **CLI wizards vs templates — the best-evidenced item.** Every tool-maker
  that explicitly compared the two picked a wizard for the same stated
  reason: reducing decision/cognitive load at first contact. Create React
  App's 2016 launch post [HIGH, primary]: template/boilerplate repos leave
  users "fighting small incompatibilities... and illegible configuration
  files"; explicitly invokes the cognitive-load argument for curation over
  choice. `create-next-app`'s 2019 relaunch [HIGH, primary, quantified]: led
  with an interactive wizard by default, cut init time to "as quick as one
  second" and package size ~88%, while still offering `--example` for a
  static template as the alternative path. **No source anywhere A/B-tested
  wizard vs template completion/activation** — this is converged design
  philosophy, not measured outcome data. Counter-datapoint: CRA's own
  eventual staleness (its zero-config Webpack setup fell behind Vite,
  `eject`-only escape hatch) shows the wizard pattern's long-term risk is
  *maintaining* what it hands out, not the interactive-prompt UX itself.
- **In-browser editor completion/abandonment — the weakest-evidenced item.**
  No completion/drop-off numbers exist anywhere, for any named commercial
  in-browser IDE (CodeSandbox, StackBlitz, Replit, Codespaces, Glitch),
  despite extensive search. The one rigorous number found (IEEE VL/HCC 2017,
  peer-reviewed [HIGH rigor]) predicts 61–76% of learners who will abandon
  the next level on an *unnamed* browser coding-tutorial platform — not
  relevant to a named commercial tool. Adjacent MOOC literature (Katy Jordan,
  221 courses, 12.6% median completion) is rigorous but about lecture MOOCs,
  not run-code-in-browser tools.
- **Academic HCI has no paper comparing fork-template vs CLI-wizard vs
  browser-IDE onboarding for developer tools** — a real literature gap, not a
  search miss; the two closest CHI 2026 papers found are about K-12
  block-based programming and generative-3D-tool onboarding, both only
  directionally relevant.

## 3. Our own evidence (read-only; run-id:timestamp cited)

Baseline: Stranger Walk `sonnet-a` (live at
`/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-a/`, isolation-audited
PASS; the archival copy under `~/.ctf/knowledge/stranger-walk/2026-09-09/` is
not yet populated — sonnet-b is running, opus-a not started as of this
checkpoint). Entry `https://softmax.com/paintbot`, GV 0.7.367.

- M1 "what is this" at `sonnet-a:2026-09-09T05:13:53.221Z` (19.2s) — fast,
  read off the page.
- M2 "how scoring works" at `sonnet-a:2026-09-09T05:14:32.440Z` (58.4s).
- M5 "policy built" at `sonnet-a:2026-09-09T05:22:56.542Z` (9.4 min).
- **The single largest stall: 12.1 minutes stuck on `coworld run-episode
  --run` argv syntax** (epoch 1788931376.542→1788932100.679), resolved at
  `sonnet-a:2026-09-09T05:35:00.679Z`: "The `--run` argv... must be supplied
  one token per `--run` flag (not JSON), and it fully overrides the per-slot
  manifest default." **This trap is already known and documented in our own
  repo** (`policies/starters/README.md:167`: "`--run` is required: without it
  the runner reuses the manifest's reference player command (`/bin/baseline`)
  and every seat fails to start") — the stranger hit it live before ever
  reaching that README. This single stall is ~40% of the run's active
  "digging" time.
- **Terminal blocker: GitHub-only sign-in.** At
  `sonnet-a:2026-09-09T05:17:16.696Z`: "Sign-in only offers 'Sign in with
  GitHub'... I have no GitHub credentials." The run reached a fully built,
  Dockerized, locally-verified policy (`starter-opportunist`, a 4th persona
  on the real starter framework) and then stopped — not for lack of trying,
  but because `softmax login`/`coworld upload-policy` require an account this
  identity could not create.
- **Independent second finding, from our own PoC author (not a stranger):**
  `policies/poc_llm_policy/README.md:356-372`, "Where the docs and schemas
  were not enough": "There is no client-facing protocol reference... An
  outside policy author opening the obviously-named document learns nothing...
  **This is the single highest-leverage thing to fix.**" Corroborates the
  stranger's own dig pattern (bounced softmax.com → docs.softmax.com →
  github.com raw content, twice) with a second, independent voice.
- **Repo-verified constraints** (this worktree @ origin/main): the
  template-repo pattern already exists and is the recommended path
  (`README.md:84-100`, three working starter personas). The CLI is real and
  multi-command (`coworld run-episode`, `coworld play`, `coworld
  upload-policy`, `softmax login`) — **`coworld init paintbot` does not exist
  today**; grepped `docs/` for "coworld init" and "auto-champion": zero hits.
  `--platform linux/amd64` is a second silent-failure trap on Apple Silicon
  (`policies/starters/README.md:203`). GitHub OAuth is the sole sign-in
  method, confirmed live in the transcript, not just documented. The wiki is
  explicitly positioned as the canonical, live-tracking rules source
  (`README.md:41-53`). "Auto-champion / any upload goes live" is carried here
  as an owner-stated constraint from the task brief — **not independently
  re-verified against league-scheduler code this pass.**

## 4. Comparison table

| | Template repo (exists today) | CLI wizard (`coworld init paintbot`, new) | In-browser editor (new) |
|---|---|---|---|
| Time-to-first-submission | ~21 min to ready-to-submit, measured (sonnet-a), blocked only by GitHub auth, not the artifact type | Unmeasured; plausibly faster if it absorbs the `--run`/`--platform` traps, since it's the same underlying artifact | Unmeasured; every dual-path reference platform still funnels through a local/CLI step for anything beyond a toy — no evidence it's faster for a real submission here |
| Setup burden | Docker + Nim/uv toolchain, but only "fork, edit one file" per README's own framing; already proven to work | Same toolchain requirement underneath; wizard only removes *decisions*, not *installs* | Lowest local burden if server does the build, but Paintbot's submission unit is a linux/amd64 container image — server-side build-on-behalf-of-user is new infrastructure, not a UI change |
| Failure modes measured/likely | `--run` argv trap (12.1 min, confirmed), `--platform` arch trap (documented), GitHub-auth wall (confirmed) | Same three, unless the wizard is built to specifically absorb them | GitHub-auth wall still applies; new failure modes (build-service outages, image-size/timeout limits) with zero field data |
| Maintenance | Low — 3 starter dirs, already own | Medium — new CLI surface to keep in sync with the CTF engine's manifest/argv shape; CRA's staleness history is a documented cautionary case for wizards specifically | High — a hosted build/run service is new infra to operate, secure, and keep in sync with the same manifest/argv shape |
| Fits GitHub-only auth | Neutral — auth is a separate wall regardless of door | Neutral, same wall | Neutral, same wall — no reference platform's artifact-type choice changed its auth requirement |
| Fits "wiki is the book" | Good — starter READMEs point to the wiki already | Good, if wizard output prints "next: read the wiki at X" | Weaker — an in-page editor invites treating the editor's own UI as the source of truth, competing with the wiki for canonicity |

## 5. Ranked recommendation

1. **Fix the existing template-repo door first.** It already works — a
   stranger reached a submittable policy in ~21 minutes of active work. The
   single largest measured loss (12.1 min, `--run` argv) is a documented,
   known trap not yet surfaced where a builder hits it; closing it directly
   removes ~40% of the run's dig time for near-zero cost (the fix is
   documentation/tooling, not new infrastructure). This is the only option
   with real, measured evidence behind it (Stranger Walk sonnet-a) rather
   than analogy from other platforms.
2. **Then wrap it in a thin CLI wizard**, once the underlying traps are
   fixed — per the CRA/`create-next-app` evidence, a wizard's real value is
   removing decisions/traps at first contact, not a different artifact.
   Built on top of an already-working template it's low-risk; built before
   the template is fixed, it just moves the same traps one layer down.
3. **Do not lead with an in-browser editor.** No reference platform in this
   research submits a container image as its artifact — every one executes a
   function/script inside its own runtime, which is a fundamentally smaller
   surface than Paintbot's real distribution unit. Every dual-path platform
   found (Lux AI, Kaggle Simulations) offers the browser/notebook path
   *alongside*, not instead of, a local/CLI path, converging on the same
   submission mechanism. A browser editor for Paintbot would need new
   server-side build infrastructure and would not touch the GitHub-auth wall
   at all.

**GitHub-only sign-in is not a door-choice problem — it blocks all three
options equally** (confirmed: it stopped sonnet-a after a fully built,
locally-verified policy). It should be treated as its own fix, independent
of whichever door wins.

## 6. The 3 questions only the owner can answer

1. **Fix-the-existing-door first, before building anything new?**
   - **[Recommended] Yes — close the `--run` argv trap and the
     `--platform linux/amd64` trap in the current template/CLI path before
     starting any new artifact.** This is the only option backed by measured
     evidence (12.1 of ~21 minutes of dig time, sonnet-a).
   - No — build the CLI wizard or browser editor first and let it obsolete
     the current traps by replacement rather than patching them.
2. **Is a hosted, in-browser build/run pipeline (needed for a true
   in-browser editor) worth opening as new infrastructure at all right now?**
   - **[Recommended] No, not yet** — no reference platform researched
     submits a container image through a browser editor; the closest
     analogues (Lux AI, Kaggle) keep browser paths as a secondary on-ramp to
     the same CLI submission, not a full replacement.
   - Yes — commit to building it as a parallel on-ramp (not a replacement
     for the template/CLI path), understanding it is unmeasured and highest
     of the three in ongoing maintenance cost.
3. **Should GitHub-only sign-in be fixed (e.g., a second auth method) in the
   same push as the builder-door work, given it blocked a fully-built policy
   from being submitted in the one measured run we have?**
   - **[Recommended] Yes — scope it alongside, since it's the confirmed
     terminal blocker in the only real evidence we have, independent of
     which door is chosen.**
   - No — leave auth out of scope for this epic; treat it as a separate,
     later decision.

## What is NOT verified

- Local-first platforms (Kaggle general competitions, MIT Battlecode, Halite
  by Two Sigma pre-Kaggle, Screeps, Robocode) and CLI-first platforms
  (Terminal/Correlation One, Google AI Challenge Ants/Planet Wars, AWS
  DeepRacer) — not researched this pass (TODO above).
- Full Stranger Walk baseline — only 1 of 3 planned runs (sonnet-a) is
  complete; sonnet-b and opus-a are not yet scored, and Walk 2 (post-Field
  Guide comparison) does not exist yet.
- "Leagues set to auto-champion" — carried as an owner-stated constraint from
  the task brief, not independently checked against league-scheduler code.
- Whether an in-browser editor is technically buildable at all for a
  container-image submission model — not spiked; §5's ranking is reasoning
  from reference-platform analogy and the repo's stated distribution model,
  not a feasibility test.
- No platform anywhere publishes a time-to-first-submission metric — this
  was checked, not merely unfound; do not treat any number for this metric
  (ours or a reference platform's) as established until measured.
