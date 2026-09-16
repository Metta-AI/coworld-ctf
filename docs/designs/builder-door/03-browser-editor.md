# Dimension 03: First-Run Onboarding — Browser-editor / Notebook / Hybrid Platforms

Scope: CodinGame, Lichess Bot API (hybrid), Kaggle Simulations (ConnectX, Halite IV), Lux AI Challenge (Kaggle-hosted, notebook + CLI paths). Read-only research, no code changes.

---

## 1. CodinGame

**Artifact type:** Pure in-browser IDE (no local install, no repo, no notebook). 25 languages supported in one editor. Multiplayer "bot programming" games are a distinct sub-mode from single-player puzzles, but both run in the same browser IDE.

**First-run flow (step by step, reconstructed from CodinGame's own blog + puzzle definitions — the live site is a JS SPA that would not render through fetch tooling, see Sources note):**
1. Land on codingame.com, create account (email or SSO).
2. First puzzle is literally titled **"Onboarding"** — a scripted tutorial puzzle at `codingame.com/ide/puzzle/onboarding` that teaches the IDE mechanics (reading stdin, using stderr for debug, submitting). Community-reported completion time: 10-15 minutes. [MEDIUM]
3. From there, a new user picks either (a) more single-player **Puzzles** (categorized Easy/Medium/Hard) or (b) a **multiplayer bot-programming game** (e.g., Coders Strike Back).
4. For bot programming specifically, CodinGame's own "My First Bot Programming Contest" post lays out the flow: check contest dates → register → optionally practice relevant puzzle skills beforehand (pathfinding, trig, permutations) → write code in the CodinGame browser IDE (or an external IDE + copy-paste, since experienced devs are told they "may use their preferred IDE") → submit → watch replay/battle viewer → iterate. [HIGH]
5. Progression uses a **League system**: Wood → Bronze → Silver → Gold → Legend. Every player starts in Wood; promotion requires beating a league's AI "Boss." You cannot be demoted. [HIGH]
6. Submission is immediate and in-IDE — no separate "deploy" step; code is graded/ranked live against the Boss or other players' bots.

**Time-to-first-submission / dropout stats:** Not published for the platform itself. CodinGame's 2019-2023 Developer Survey series (15k-20k+ respondents) reports general developer-engagement stats (e.g., 87% code outside work/school; 66.4% rate job satisfaction 7-10/10) but nothing broken out as CodinGame's own onboarding funnel, time-to-first-puzzle, or contest dropout rate. [HIGH — confirms absence, not presence]

**What changed over time / stated reason:** The League/Boss system was a deliberate redesign of bot-programming onboarding, described in CodinGame's own blog: previously contests were "flat" (one difficulty level, one ruleset for everyone). The team's stated goal was "intermediate objectives and a progressive difficulty" so newcomers "gradually discover more rules and challenges as they progress," rather than being dropped into the full ruleset immediately. This was rolled out starting with Coders Strike Back and stated as a template for future contests. [HIGH — CodinGame's own blog]

---

## 2. Lichess Bot API (hybrid: API + local script, NOT a browser editor)

**Artifact type:** Hybrid — no in-browser code editor at all. The user (a) creates a special "BOT" account via the Lichess web API, then (b) runs a **local Python bridge script** (`lichess-bot`) that connects a local/self-hosted chess engine binary (UCI/XBoard) to Lichess's live game servers over the Bot API. This is the closest of the four to a "CLI/local-agent" flow, included here per the task's framing as a hybrid reference point.

**First-run flow (step by step, per the official `lichess-bot` README and wiki):**
1. Create a **new** Lichess account (must not have played any games on it — bot upgrade is one-way and irreversible before first use).
2. Go to `lichess.org/api`, generate a personal **OAuth token** (needs `bot:play` scope).
3. Upgrade the account to BOT status: `curl -d '' lichess.org/api/bot/account/upgrade -H "Authorization: Bearer <token>"`.
4. Clone/download the `lichess-bot` repo locally.
5. Install dependencies: create a virtualenv (`pip install virtualenv`), activate it, `pip install -r requirements.txt`. Requires **Python 3.10+**; runs on Windows/Linux/macOS/Docker.
6. Copy `config.yml.default` → `config.yml`, paste the OAuth token in, and point the config at a local chess engine binary (Stockfish, etc.) — a separate "Setup the engine" step.
7. Run the script (`python lichess-bot.py` or platform equivalent) — the bot then polls/streams Lichess for challenges and plays live games, rated or casual.

The README itself lists the canonical order as: **Install → Create OAuth token → Setup the engine → Configure lichess-bot → Upgrade to BOT account → Run.** [HIGH — official README]

**Historical origin / rationale:** Lichess's own 2018 "Welcome Lichess Bots" blog post announced the Bot API and explained *why* it's a separate account type rather than an open API on normal accounts: opening the API broadly would defeat Lichess's two main anti-cheat mechanisms (server-side move-time/move-quality evaluation and client-side behavioral metrics gathered only in the real web UI). Isolating bots to a dedicated, clearly-labeled account type let them keep API access open without weakening cheat detection on human accounts. Rated games against bots award only half rating points, an explicit rule added at bot-API launch. [HIGH — Lichess's own blog]

**Time-to-first-submission / dropout stats:** Not found. No engagement/completion telemetry is published by Lichess or the lichess-bot maintainers for this flow.

**What changed over time:** The README/wiki don't expose changelog-level onboarding history in the fetched content (wiki sub-pages errored on fetch — see Sources note), but the current maintained repo lives under the `lichess-bot-devs` GitHub org (a community-maintained successor to earlier single-maintainer forks referenced in search results, e.g. `careless25/lichess-bot`, `dolegi/lichess-bot`) — i.e., the project has been forked/consolidated over time, though no single documented "why" for the onboarding flow changing was found. [LOW — inferred from repo ownership pattern, not a documented statement]

---

## 3. Kaggle Simulations — ConnectX

**Artifact type:** Choice of two paths, both centered on producing a Python **agent function**, not a notebook per se as the final artifact:
- **Notebook path:** fork/run a Kaggle Kernel (e.g. the community "ConnectX Getting Started" notebook by `ajeffries`) that installs `kaggle-environments`, defines `my_agent(observation, configuration)`, tests it locally against a random/negamax baseline, then writes it out as `submission.py`.
- **Local/CLI path:** `pip install kaggle-environments` (or `uv pip install kaggle-environments` per the current README) locally, write the same agent function, test with `env.run([my_agent, "random"])`, then submit the raw file via the `kaggle` CLI.

**First-run flow (step by step, reconstructed from the `kaggle-environments` README and the `kaggle-cli` simulation-competitions doc — the live Kaggle notebook page itself is JS-rendered and did not return body text to fetch tooling, see Sources note):**
1. Install: `pip install kaggle-environments` (agents in `kaggle_environments` package already include a working ConnectX environment).
2. Define an agent as a plain function, e.g. the README's own minimal example: `def my_agent(obs): return [c for c in range(len(obs.board)) if obs.board[c] == 0][0]`.
3. Locally validate: `env.run([my_agent, "random"])` runs a full episode against a baseline opponent — this is the "first local run" moment, entirely offline, no submission needed yet.
4. Package for submission: single file → `kaggle competitions submit connectx -f main.py -m "Single file agent v1"`; multi-file → bundle into `submission.tar.gz` with `main.py` at the root; **or** submit directly from an existing Kaggle notebook with `-k <username>/<notebook-slug> -f submission.tar.gz`.
5. Post-submission: check status (`kaggle competitions submissions connectx`), list episodes it has played (`kaggle competitions episodes <id>`), download a replay (`kaggle competitions replay <id>`) or logs (`kaggle competitions logs <id> <agent-index>`) to debug. Episodes are matched against similarly-rated submissions roughly once/day (frequency varies), i.e., ranking is a live, ongoing ladder rather than a one-shot score. [HIGH — `kaggle-cli` official docs repo]

**Category framing:** ConnectX is explicitly tagged by Kaggle as a **"Getting Started" / Simulation competition** — distinct from the general leaderboard-CSV competitions your teammate is covering. Simulation competitions submit *code that plays*, not predictions. [MEDIUM — corroborated across multiple Kaggle/forum sources, but the primary competition-overview page itself did not render body text through fetch tooling]

**Time-to-first-submission / dropout stats:** Not found. No forum threads or Kaggle blog posts surfaced with a stated median/typical time-to-first-submission for ConnectX; general "how long does submission scoring take" forum threads exist but measure scoring latency, not user onboarding time.

**What changed over time:** Not found in sources reached — no changelog/blog post documenting an onboarding redesign for ConnectX specifically was located.

---

## 4. Kaggle Simulations — Halite IV

**Artifact type:** Same dual-path model as ConnectX (notebook fork or local `kaggle-environments` + CLI submit of a Python agent file), but Halite IV is notable as **the first Halite version to be hosted on Kaggle** — prior versions (I-III) ran on Two Sigma's own standalone Halite platform with a downloadable starter-kit/local-CLI model, not notebooks.

**First-run flow (step by step, reconstructed from community "Getting Started with Halite" notebooks and the `kaggle-environments` package model — same fetch limitation as ConnectX, Kaggle notebook body text did not render, see Sources note):**
1. Fork a getting-started notebook (e.g. Alexis Cook's "Getting Started With Halite," or the community `halite-template-bot`) or `pip install kaggle-environments` locally — same as ConnectX.
2. Implement an agent against the Halite IV rules (fleet of ships, collect halite resource, build shipyards/ships, avoid/force collisions) — a materially bigger action/observation space than ConnectX's single-column-drop game.
3. Test locally via the `kaggle_environments` runner, then submit up to **5 agents/day**; each submission is scored via episodes against similarly-rated ladder opponents (same live-ladder model as ConnectX, not a one-shot leaderboard). [MEDIUM — corroborated by multiple secondary sources, not a primary Kaggle competition page]

**Time-to-first-submission / dropout stats:** Not found.

**What changed over time / stated reason:** Wikipedia's "Halite AI Programming Competition" article confirms the version history and the platform shift: Halite I (Nov 2016-Feb 2017, ~1,500 competitors), Halite II (Oct 2017-Jan 2018, ~6,000 players/100+ countries), Halite III (Oct 2018-Jan 2019, 4,000+ players/460+ organizations) — all on Two Sigma's own site — versus **Halite IV (launched mid-June 2020), explicitly stated as "hosted by Kaggle."** [HIGH — Wikipedia, itself citing Two Sigma/competition sources] This is the concrete "moved to notebooks-first" data point requested by the task, though **no documented first-person rationale** (blog post explaining *why* Two Sigma moved to Kaggle/notebooks) was found in the sources reached — the "why" is inferred (access to Kaggle's existing user base, ladder infrastructure, and the `kaggle-environments` tooling already built for ConnectX) rather than sourced to a maintainer statement. [LOW for the "why", HIGH for the "what/when"]

---

## 5. Lux AI Challenge (Kaggle-hosted; explicit dual path)

**Artifact type:** Explicit, documented choice between two onboarding paths, stated directly in the Season 1 repo README:
- **Path A — CLI/local (documented as the primary/recommended path):** local Node.js CLI + per-language starter kits.
- **Path B — Notebook:** fork a Kaggle Jupyter/Interactive Notebook tutorial, entirely in-browser, no local install.

**First-run flow, Path A (CLI/local), Season 1 — from the official `Lux-AI-Challenge/Lux-Design-S1` README:**
1. Prereq: Node.js v12+.
2. `npm install -g @lux-ai/2021-challenge@latest` (installs the CLI + engine globally).
3. Pick a starter kit from the repo's `kits/` folder — Python, JavaScript, Rust, C++, Java, TypeScript, or Kotlin all provided.
4. Read the kit's own README (language-specific API docs).
5. Run a local match immediately: `lux-ai-2021 path/to/botfile path/to/otherbotfile` — this is the "first local run," entirely offline against another bot binary.
6. View the replay either on the hosted visualizer (`2021vis.lux-ai.org`) or a local `LuxViewer2021` instance.
7. Optional CLI flags: fixed seeds, log levels, stateful-replay generation, and a `--tournament` mode that runs a local **TrueSkill-rated leaderboard** across multiple bots before ever touching Kaggle.
8. Submit the resulting bot on the Kaggle competition page (both paths converge here).

**First-run flow, Path B (notebook), Season 1:** README explicitly tells Python users they can skip the whole CLI section: *"For users who wish to use Python and Jupyter Notebooks / Kaggle Interactive Notebooks, feel free to skip this section and follow the tutorial notebook"* (linked to `kaggle.com/stonet2000/lux-ai-season-1-jupyter-notebook-tutorial`). This is a fork-and-run notebook, same submission endpoint as Path A. [HIGH — official README, directly quoted]

**Season 3 (current/most recent, 2024, hosted for NeurIPS'24) comparison:** The Season 3 kits README describes a materially different, more code-first flow with less notebook framing in what was reachable: each kit ships `main.py` (boilerplate, ignorable) + an `agent` file where the user implements an `act(step, obs, remainingOverageTime)` function returning a fixed `(N,3)` action array; debugging is via stderr/stdout logging captured by competition servers. The fetched kit README did **not** surface explicit CLI-match or notebook-tutorial instructions the way the S1 README did — this may reflect a genuinely simpler/thinner onboarding doc, or may be an artifact of only reading the kits' shared top-level README rather than a per-language kit README (e.g. `kits/python/README.md`), which likely holds the CLI run instructions. Flagged as inconclusive rather than a confirmed regression. [LOW — single source, incomplete fetch, do not treat as a confirmed onboarding downgrade]

**Time-to-first-submission / dropout stats:** Not found for any Lux AI season.

**What changed over time / stated reason:** No maintainer blog post or changelog explaining an onboarding-design rationale was found for Lux AI across seasons. The S1→S3 kit-structure difference above is observed, not explained by any documented source.

---

## Sources & confidence summary

| Platform | Source | Confidence | Fetch status |
|---|---|---|---|
| CodinGame | `codingame.com/blog/first-programming-contest/` | HIGH | Fetched OK (server-rendered blog) |
| CodinGame | `codingame.com/blog/bot-programming-challenges-get-polished/` | HIGH | Fetched OK |
| CodinGame | `codingame.com/training/easy/onboarding` + community solution repos/YouTube walkthroughs | MEDIUM | Search results only; puzzle page itself is JS SPA, did not render body via WebFetch |
| CodinGame | `en.wikipedia.org/wiki/CodinGame` | MEDIUM | Fetched OK, thin on onboarding detail |
| CodinGame | `codingame.com/faq`, `codingame.com/multiplayer/bot-programming` | — | **Fetch failed** — client-rendered SPA, only page title returned, no body text. Not used as a cited source. |
| CodinGame | `codingame.com/work/developer-survey-results-2019/` | — | **Redirected (301) to coderpad.io**, dead link — CodinGame's HR/dev-survey microsite appears to have been folded into CoderPad's site post-acquisition. Could not retrieve onboarding/dropout numbers this way. |
| Lichess | `github.com/lichess-bot-devs/lichess-bot` (README) | HIGH | Fetched OK |
| Lichess | `github.com/lichess-bot-devs/lichess-bot/wiki` | MEDIUM | Fetched OK for page list; individual sub-pages ("How to Install" etc.) errored on load, so wiki detail beyond the README's own summary is unconfirmed |
| Lichess | `lichess.org/@/lichess/blog/welcome-lichess-bots/WvDNticA` | HIGH | Fetched OK, directly quoted |
| Kaggle ConnectX | `github.com/Kaggle/kaggle-environments` (README) | HIGH | Fetched OK |
| Kaggle ConnectX | `github.com/Kaggle/kaggle-cli/blob/main/docs/simulation_competitions.md` | HIGH | Fetched OK, exact CLI commands quoted |
| Kaggle ConnectX | `kaggle.com/code/ajeffries/connectx-getting-started`, `kaggle.com/competitions/connectx/overview` | — | **Fetch failed** — Kaggle notebook/competition pages are client-rendered; only page `<title>` returned, no body. Content reconstructed instead from the `kaggle-environments` README + `kaggle-cli` docs + search-result snippets (MEDIUM, not primary-page-confirmed). |
| Kaggle Halite IV | `en.wikipedia.org/wiki/Halite_AI_Programming_Competition` | HIGH | Fetched OK, version history/dates directly quoted |
| Kaggle Halite IV | community notebooks (`kaggle.com/code/alexisbcook/getting-started-with-halite`, `.../halite-template-bot`) | MEDIUM | Search-result snippets only, page bodies not fetched (same SPA issue) |
| Lux AI S1 | `github.com/Lux-AI-Challenge/Lux-Design-S1` (README) | HIGH | Fetched OK, commands and notebook-alternative quote verified |
| Lux AI S3 | `github.com/Lux-AI-Challenge/Lux-Design-S3/blob/main/kits/README.md` | MEDIUM | Fetched OK but only top-level kits README, not per-language kit docs — flagged as incomplete above |
| Time-to-first-submission (all platforms) | Kaggle forums, CodinGame surveys | — | **Not found** — no platform in this set publishes a time-to-first-submission or onboarding-dropout metric in any source reached. Do not cite a number for this if asked; state "not published." |
| archive.org | — | — | WebFetch tool cannot reach `web.archive.org` at all in this environment (hard block, not a 403) — could not use Wayback snapshots as a fallback for the CodinGame/Kaggle SPA pages as the task suggested. |

**Net fetch-reliability note:** Every GitHub README/wiki and every server-rendered blog post (CodinGame blog, Lichess blog, Wikipedia) fetched cleanly on the first try. Every JS-rendered SPA page (codingame.com marketing/FAQ pages, Kaggle notebook/competition pages) returned only the `<title>` tag with no body content — this is a client-side-rendering limitation of the fetch tool, not a 403/paywall. Where this happened, the write-up above relies on search-result snippets (marked MEDIUM) or adjacent primary sources (READMEs, docs repos) instead, and the gap is flagged inline rather than silently backfilled.
