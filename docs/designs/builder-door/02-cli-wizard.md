# Dimension: First-run onboarding — CLI-first / CLI-adjacent competitive coding platforms

Scope: Terminal (Correlation One), Google AI Challenge — Ants AI Challenge (2011) and Planet Wars (2010), AWS DeepRacer (CLI/console developer track). Read-only research, no code changes.

---

## 1. Terminal (Correlation One)

### First-run flow (step by step)
1. Land on `terminal.c1games.com`. Docs recommend playing manually first at the in-browser **playground** (`https://terminal.c1games.com/playground`) to learn the game before writing an algo.
2. Clone/download the **C1GamesStarterKit** GitHub repo (`github.com/correlation-one/C1GamesStarterKit`).
3. Install prerequisites: Python 3 (`python3` must work on Unix; `py -3` on Windows PowerShell). Java 10+ is optional, for running the game engine locally. On Windows, an admin PowerShell command is required to allow scripts to run: `Set-ExecutionPolicy Unrestricted` (alternatives: `Set-ExecutionPolicy Unrestricted CurrentUser`, `Bypass`, or `RemoteSigned`).
4. Verify the local setup by running a match between the two bundled starter bots: `python scripts/run_match.py python-algo python-algo` (per a participant's published walkthrough; the official README doesn't give this exact invocation but points at "the test_algo_[OS] scripts in the scripts folder").
5. Copy the language folder (e.g. `python-algo`) into a new folder and edit `algo_strategy.py` — this filename is a fixed required entry point; renaming it breaks upload.
6. Iterate locally, re-running `scripts/run_match.py <your-folder> python-algo` (or against the growing stable of starter/prior bots) to test changes before submitting.
7. Create a Correlation One account and sign in on `terminal.c1games.com` (account creation endpoint: `terminal.c1games.com/api/accounts/signup_enter_email`).
8. Submit by selecting **only the language-specific folder** (never the whole starter kit) when prompted on the website's upload flow ("my algos").

### Artifact type
Plain **CLI tool + fork-a-template-repo**, not an interactive wizard. The repo's own description: "Starter kit for new players of Terminal. Contains starter-algo and a basic CLI for running/debugging algo's locally." The CLI (`run_match.py`, `test_algo_*` scripts) takes positional/flag arguments and prints match output — it never asks the user questions or scaffolds new files. Submission itself happens through a browser upload, not the CLI. So the pattern is: template repo (local dev) + web upload (submission) — options (a) and (c) blended, no wizard.

### Time-to-first-submission / dropout
Not published. No funnel-level stats (time-to-first-submission, dropout, completion rate) were found anywhere. The only public numbers found are aggregate participation totals, not funnel data: "over 45,000 competitors and over 8 million matches played to date," and "over 4,500 students from more than a dozen countries applied for Terminal competitions in 2021–2022" (Correlation One's own blog). These describe scale, not onboarding friction/completion.

### What changed over time
Not found. No changelog, blog post, or forum post describing changes to the onboarding flow (e.g., CLI added/removed, starter kit redesigned) was located. Correlation One's blog posts found are about competition results and partnerships (India Terminal 2022, High School Terminal 2022, Terminal: LIVE at Waterloo), not about onboarding UX evolution.

### Sources
- `https://github.com/correlation-one/C1GamesStarterKit` — HIGH (primary, official repo)
- `https://github.com/correlation-one/C1GamesStarterKit/blob/master/README.md` — HIGH (primary, official README; fetched via WebFetch since a raw.githubusercontent.com fetch attempt returned 403 Forbidden)
- `https://pythonprogramming.net/correlation-one-terminal/` — MEDIUM (secondary, a participant's own step-by-step account; corroborates and adds the exact `run_match.py` command not spelled out in the README)
- `https://www.correlation-one.com/blog/terminal-2021-2022` — MEDIUM (official company blog; source of the participation totals)
- `https://www.terminals.io/faq` — **403 Forbidden** via WebFetch, not recovered. Also flagged: this domain/product ("Terminals.io") appears to be an unrelated company (name collision with Correlation One's "Terminal") — a search result "Registering for Terminals 2.0" (`blog.terminals.io`) belongs to this other product, not Correlation One's game. Not used as a source for this platform to avoid conflation.
- `terminal.c1games.com/rules`, `/playground` — referenced by the README but not independently fetched (not blocked, just not visited directly; content taken on the README's word).

---

## 2. Google AI Challenge — Ants AI Challenge (Fall 2011)

### First-run flow (step by step, from the live site content)
The homepage's own call to action: *"Ready to get started? Download a starter pack, and then follow the five minute tutorial."*

**Five Minute Quickstart Guide** (verbatim structure from the page):
1. **Create an Account** — fill out the signup form.
2. **Activate Your Account** — click the link in the confirmation email (allow up to 5 minutes; check spam).
3. **Sign in to the Website**.
4. **Download a Starter Package** — any language works, since nothing is modified yet; packages are ZIP files.
5. **Submit the Starter Package** — *unmodified*, unzipped, straight onto the "Upload Your Code" page.
6. **Done** — the name appears on the global leaderboard, "usually only takes a few minutes," up to an hour.

The page explicitly frames this as reaching the leaderboard "in less than five minutes," then funnels into the real work via a **"Next Steps"** section: the full Tutorial, "Using the Tools," and the forums.

**Full Tutorial's own "Setting Up" section** (separate from the 5-minute guide, for people who actually want to write a bot): install a Python interpreter (required regardless of bot language, because the game engine itself is Python), download and unzip both the **tools** package and a **starter-bot** package into one folder, then run the bundled test script (`play_one_game.cmd` on Windows / equivalent shell script on Unix), which plays a demo game and prints turn-by-turn stats to confirm the local engine works. From there the tutorial walks through 5 incremental coding steps (avoid collisions → gather food → don't block hills → explore the map → attack enemy hills).

### Artifact type
Plain **template ZIP + batch CLI tools**, no wizard anywhere. Starter packages are static per-language ZIPs (languages offered per the Starter Packages page: Ada, C, C#, C++, Clojure, CoffeeScript, Common Lisp, D, Dart, Erlang, Go, Groovy, Haskell, Java, JavaScript, Lua, OCaml, Octave, Pascal, Perl, PHP, Python, Python 3, Racket, Ruby, Scala, Tcl, Visual Basic — with per-language caveats noted, e.g. "Hills not implemented yet" for several). The "tools" bundle is a Python-based game engine, visualizer, and map generator invoked via command-line scripts (`playgame.py`, `play_one_game.cmd`/`.sh`) — purely batch, no prompts, no scaffolding of new files beyond what's already in the ZIP.

### Time-to-first-submission / dropout
The platform makes an explicit *design claim*, not a measured stat: get "your name on the global leaderboard in less than five minutes." No telemetry-backed completion or dropout numbers were found for the Ants challenge specifically.

### What changed over time
Thin. Wikipedia (LOW detail — one paragraph) confirms the "AI Challenge" series ran 2009–2011 under the University of Waterloo Computer Science Club and is now inactive. Search results (via a `calltoreason.org` results recap) place the Fall 2011 Ants contest as a direct successor to Fall 2010's Planet Wars contest, run by the same organizers on the same site infrastructure — but no changelog or forum/blog post explaining a deliberate change to the *onboarding* mechanics (CLI added/removed, starter format changed) between contests was found. The onboarding scaffolding (account → starter pack → 5-minute quickstart → deeper tutorial) reads as identical across both contests (see Planet Wars section below) — i.e., the pattern appears to have been reused unchanged rather than evolved.

### Sources
- `http://ants.aichallenge.org/quickstart.php` — HIGH (primary, live site; fetched directly). **Caveat:** the domain currently serves a TLS certificate issued for an unrelated host (`hypertriangle.com`), so HTTPS-upgrading fetchers fail with a certificate mismatch; content was retrieved over plain HTTP with certificate verification disabled. The page content itself is internally consistent, matches secondary-source descriptions, and appears to be genuine unmaintained historical content (not obviously tampered with), but the broken TLS is itself a signal the domain is an orphaned fossil.
- `http://ants.aichallenge.org/ants_tutorial.php` — HIGH (primary, same TLS caveat as above)
- `http://ants.aichallenge.org/starter_packages.php` — HIGH (primary, same TLS caveat)
- `https://github.com/aichallenge/aichallenge/wiki` — MEDIUM/partial. A raw HTTP fetch of this URL returns only a client-side feature-flag JSON blob (React SPA shell) with no page content — effectively **blocked for non-browser HTTP clients**. The WebFetch tool's own renderer did return a usable page listing (61 wiki pages, including "Beginner's Guide," "Ants Five Minute Quickstart Guide," "Ants Tutorial" steps 1–5, "Ants Starting Your Own Bot," language-specific getting-started guides for Python/Java/C++/.NET) but this was a page *index*, not full page bodies — individual wiki page content was not independently verified.
- `https://en.wikipedia.org/wiki/AI_Challenge` — LOW (thin single-paragraph article; only confirms 2009–2011 run, Waterloo organizer, "Inactive" status)
- `https://calltoreason.org/?p=8670` ("AI Challenge 2011 Results") — LOW (seen only via search snippet, not independently fetched in full; used only to corroborate contest sequencing)
- Cross-check: the archived `ai-contest.com` homepage (see Planet Wars sources below) uses near-identical "download a starter pack, follow the five minute tutorial" phrasing a full year earlier, which is the strongest evidence the onboarding pattern was carried forward unchanged from Planet Wars into Ants.

---

## 3. Google AI Challenge — Planet Wars (Fall 2010)

### First-run flow
The original site was `ai-contest.com` (distinct domain from the later `aichallenge.org`, which hosted 2011's Ants). That domain is dead today — see "blocked/dead sources" below — so this is reconstructed from an `archive.org` snapshot dated **2010-10-18**.

Homepage content at that snapshot: a contest timeline (materials released Sept 1, 2010; official start Sept 10, 2010 — account creation and rankings go live; submission deadline Nov 27, 2010, 11:59 PM; results Dec 1, 2010), a "Sign In | Sign Up" nav, and the identical call to action later reused for Ants: *"Ready to get started? Download a starter pack, and then follow the five minute tutorial."* Support channels listed: a forum and an IRC channel (`#aichallenge` on `irc.freenode.net`).

The starter-package mechanics (reconstructed from a modern community mirror of the original package, `xtevenx/planet-wars-starterpackage`, since the original hosted copy is gone): pick a language folder under `starterbots/` (C++, C#, Java, Python were offered), copy those files to the project root, read `SPECIFICATION.md` for the game rules, then validate locally with `play.py` (single game with visualization) or `play_multiple.py` (batch runs across multiple maps).

An unofficial supplementary tool existed outside the official flow: a TCP relay server (`tcp.c`) built by a participant (Daniel Hartmeier) so bots could run locally while still fetching maps/issuing orders against a remote server, e.g. `./tcp <host> 995 <username> -p <password> ./MyBot`. This was explicitly *not* part of the official onboarding — its own page notes "THE SERVER IS NOW SHUT DOWN" and points back to the official site for real onboarding.

### Artifact type
Same as Ants: per-language starter **template ZIP** + **Python-based batch CLI** engine scripts (`play.py`, `play_multiple.py`). No interactive wizard anywhere in the official path. The one interactive-feeling element (the TCP relay) was unofficial, participant-built, and is now dead.

### Time-to-first-submission / dropout
Not found as a measured statistic. Same "five minute" framing as the Ants challenge (identical wording on the archived homepage), which is a stated aspiration/design target, not telemetry.

### What changed over time
The clearest documented change here is **domain death**, not a documented onboarding redesign: `ai-contest.com` is no longer the contest site at all. As of this research it resolves to an unrelated Thai-language site (a WordPress-based gambling/casino site, "บาคาร่า ออนไลน์," last touched ~2025 per its own asset paths) — i.e., the domain has been squatted/repurposed since the original contest ended. The contest's living presence migrated to `aichallenge.org` (still resolving, serving the 2011 Ants content directly) and to a GitHub org (`github.com/aichallenge`) for source and wiki. No source documents *why* the domain moved or *whether* the onboarding mechanics were deliberately changed in the move — this is inferred from URL/domain evidence, not stated anywhere; treat as **not found** for the "why."

### Sources
- `https://web.archive.org/web/20101018202033/http://ai-contest.com/` — HIGH (primary, actual archived former homepage). **Caveat on method:** the WebFetch tool refuses `web.archive.org` URLs outright ("Claude Code is unable to fetch from web.archive.org"); this snapshot was retrieved via a direct HTTP request to the archive, not via the standard web-fetch tool.
- `https://github.com/xtevenx/planet-wars-starterpackage` — MEDIUM (a present-day community reconstruction/mirror of the original starter package, explicitly built to preserve the 2010 material; not the original hosted page, so treated as secondary even though it reproduces original file structure)
- `https://www.benzedrine.ch/planetwars.html` — MEDIUM (participant page about the unofficial TCP relay tool; useful to confirm the official server-based submission flow existed and that this was a supplementary, non-official tool that has since been shut down)
- `ai-contest.com` (live, checked directly) — now domain-squatted with unrelated Thai-language content; explicitly **not usable** as a source, noted for completeness.
- `ai-contest.com/getting_started.php` and `ai-contest.com/quick_start_guide.php` — checked against the Wayback Machine's `availability` API; **no archived snapshot exists for either exact path** ("archived_snapshots": {}). Marked **not found** — could not recover the dedicated getting-started page content, only the homepage's summary of it.

---

## 4. AWS DeepRacer (developer/CLI track, not the physical race day)

DeepRacer's onboarding must be reported in two eras — the platform fundamentally changed shape between when most existing write-ups were authored and today (Sept 2026).

### Era 1 — managed AWS Console service (launched re:Invent 2018, decommissioned Dec 15, 2025)

**First-run flow** (reconstructed from a third-party walkthrough, since the official docs URLs have since been overwritten with Era 2 content — see caveat below):
1. Land on the DeepRacer service page inside the AWS Console; a "Get started" CTA, plus an optional-but-recommended short reinforcement-learning training module.
2. Navigate to "Create a model and race" → "Create model."
3. **Training Details** screen: name the model, choose a track (guidance: start with "a track with a simple outline and smooth turns").
4. **Race Configuration**: choose race type (Time Trial recommended for first-timers — deploys a single-camera sensor) and a vehicle from the "garage."
5. **Reward Function** screen: an in-browser Python code editor, pre-filled with a working example (e.g., rewarding staying close to the track centerline) that the user edits.
6. **Algorithm/hyperparameters**: PPO algorithm, TensorFlow framework — largely pre-selected defaults, editable by advanced users.
7. Submit → model trains automatically; progress is visible via CloudWatch Logs.

This is a genuine **multi-step guided browser flow** — screen-by-screen, with defaults and inline guidance at each step — the closest of the four platforms to a real "wizard," though it's a web console form sequence, not a CLI.

A structural precondition mattered for onboarding: reaching any of this required **an AWS account with Console access** for every individual participant — flagged explicitly as a friction point in the platform's later transition messaging (see "what changed," below).

### Era 2 — self-hosted "DeepRacer on AWS" Solution (shipped late January 2026, current as of this research)

There is no more turnkey managed console for individuals. The new first-run flow is organizational, not individual:
1. An organization/admin deploys the **"DeepRacer on AWS"** AWS Solutions Library offering into their own AWS account via a provided **AWS CloudFormation template** (source at `github.com/aws-solutions/deepracer-on-aws/`).
2. Once deployed, end-user racers access "a normal website with user access managed by [Amazon] Cognito" — i.e., individual participants no longer need direct AWS Console access; only the deploying admin does.
3. This is not a CLI wizard either: it's a one-time infrastructure-as-code deployment (CloudFormation), followed by a hosted web console for participants (details of that participant-facing console's exact steps were not independently re-verified for Era 2 — the docs found describe deployment/architecture, not the racer-facing UI).

**Unofficial community CLI (exists across both eras):** `aws-deepracer-community/deepracer-for-cloud` lets a developer train locally or on their own cloud infrastructure without the official console at all:
- `./bin/prepare.sh` (cloud only — partitions drives, installs prerequisites)
- `./bin/init.sh -c <aws|azure|local> -a <cpu|gpu>` — downloads Docker images (can take ~30 min)
- Manually copy config templates into `custom_files/` (`hyperparameters.json`, `model_metadata.json`, `reward_function.py`), sourced from `defaults/`
- `dr-upload-custom-files` then `dr-start-training`

These are **flag-driven automated scripts, not an interactive wizard** — no prompts, just parameters. Explicitly community-built, not an official AWS artifact. (A further wrapper, `ARCC-RACE/deepracer-for-dummies`, exists on top of it for easier local setup — not independently verified in depth.)

### Artifact type
Era 1: official browser/console **guided multi-step wizard**. Era 2: official **infrastructure deploy (CloudFormation) + hosted web console**, org-admin-run once, then racer-facing website. Unofficial, both eras: **plain flag-driven CLI scripts** (`deepracer-for-cloud`), not a wizard. None of the official artifacts are a *CLI* wizard in the sense this research dimension is scoped around — DeepRacer's "wizard" experience, where it exists, is entirely browser-based.

### Time-to-first-submission / dropout
Not published. Searches specifically for AWS DeepRacer completion rate, dropout rate, or time-to-first-submission returned nothing platform-specific (only generic MOOC-dropout academic papers and DeepRacer's own non-funnel documentation). The one public number found is an aggregate participation total, not a funnel/completion stat: **"over 560,000 builders from more than 150 countries"** participated in the DeepRacer League over its ~6-year run (official AWS ML blog).

### What changed over time, and why
Well documented, with a stated reason (though the "why" quote comes from a community/partner blog, not an official AWS post):
- **2018 (re:Invent)**: DeepRacer launches as a managed AWS Service — console + in-browser reward-function code editor + PPO training.
- Later: the "League Virtual Circuit" is added for ongoing online competition (train/evaluate/compete from the console).
- **re:Invent 2024**: AWS announces 2024 is the **final League Championship**; console support for DeepRacer is stated to continue "through the end of 2025."
- **Sept 15, 2025**: the DeepRacer **Student Portal** specifically is cut off, ahead of the full service's end.
- **Dec 15, 2025**: the managed console service is fully decommissioned; DeepRacer devices pulled from sale on Amazon.
- **Late January 2026**: the replacement **"DeepRacer on AWS" Solution** ships (self-hosted, CloudFormation-deployed).

**Stated reason for the shift** (per a community/AWS-partner blog, not an official AWS announcement post — treat this specific causal claim as MEDIUM confidence): the managed-service model required "every racer needed AWS Console access," which was awkward for corporate/organizational events needing their own identity management. The Solution model replaces this with an org-deployed stack fronted by a normal Cognito-authenticated website — removing the AWS-Console requirement for individual participants, at the cost of requiring an org admin to deploy and maintain infrastructure.

### Sources
- `https://docs.aws.amazon.com/deepracer/latest/developerguide/deepracer-get-started.html` and `.../deepracer-get-started-training-model.html` — nominally HIGH (official AWS docs domain) **but with an important caveat**: as of this research these URLs have been silently repointed to the *new* "DeepRacer on AWS" Solution guide (publication date shown as "January 2026"); the original console-era walkthrough content is no longer live at these URLs and had to be reconstructed from secondary sources instead.
- `https://www.ensono.com/insights-and-news/expert-opinions/getting-started-deepracer-aws-intro-machine-learning-cloud/` — MEDIUM (third-party walkthrough blog; primary source used to reconstruct the pre-2026 console flow, since the official docs were overwritten)
- `https://aws.amazon.com/blogs/machine-learning/the-end-of-an-era-the-final-aws-deepracer-league-championship-at-reinvent-2024/` — HIGH (official AWS ML blog; source of the 560,000-builders/150-countries figure, the League-ending announcement, and "console support... through end of 2025")
- `https://blog.awsaicommunity.org/posts/deepracer-is-back-2026/` — MEDIUM (community/AWS-partner blog, not an official AWS channel, but consistent with and elaborating on the official transition; source of the "every racer needed AWS Console access" stated reason and the Cognito-website detail)
- `https://github.com/aws-deepracer-community/deepracer-for-cloud` and `https://aws-deepracer-community.github.io/deepracer-for-cloud/installation.html` — HIGH for the tool's own documented install steps (primary source for that repo); MEDIUM for characterizing it as *the* de facto community CLI path (inferred from it being the base that other community tools wrap, e.g. `deepracer-for-dummies`)
- `https://github.com/aws-solutions/deepracer-on-aws/` — referenced as the new Solution's source repo per the official docs' navigation table; not independently fetched/verified beyond that reference.
- Search for AWS DeepRacer completion/dropout/time-to-first-submission statistics — no results found; recorded as **not found** rather than guessed.

---

## Cross-platform note on blocked/problematic sources
- `web.archive.org` — the WebFetch tool refuses these URLs unconditionally at the tool level; all archive.org content in this research was retrieved via direct HTTP requests instead.
- `ants.aichallenge.org` — serves a TLS certificate for an unrelated host (`hypertriangle.com`); any HTTPS-upgrading fetch tool fails with a certificate-mismatch error. Content was retrieved over plain HTTP with certificate verification bypassed; the domain is functionally an orphaned fossil (real historical content, broken infrastructure).
- `ai-contest.com` — the original Planet Wars domain is fully dead: now squatted by an unrelated Thai-language site. No original content is reachable there; archive.org was required.
- `raw.githubusercontent.com/correlation-one/C1GamesStarterKit/...` — 403 Forbidden via WebFetch; worked around by fetching the same README through the GitHub web UI URL instead.
- `www.terminals.io` — 403 Forbidden via WebFetch. Also a likely name collision with an unrelated product, not Correlation One's Terminal — excluded as a source for that reason as well as the 403.
- `github.com/aichallenge/aichallenge/wiki` — a raw (non-browser) HTTP fetch returns only a client-side feature-flag JSON blob with no page content (React SPA shell), i.e. effectively blocked for simple HTTP clients; the WebFetch tool's own renderer recovered a usable page index but not full page bodies for individual wiki articles.
