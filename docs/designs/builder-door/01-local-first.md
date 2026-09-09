# Dimension: First-Run Onboarding — Local-First / Template-Repo / Installable-SDK Platforms

Scope: Kaggle competitions (general flow, not the notebook-only Simulations track), MIT Battlecode, Halite by Two Sigma (original multi-year competition, not Kaggle's Halite IV), Screeps, Robocode. Each section covers: (1) first-run flow, (2) artifact type, (3) time-to-first-submission / dropout stats, (4) what changed over time + stated reason. Confidence tags: HIGH (primary/official), MEDIUM (secondary, corroborated), LOW (single secondary source or inference).

---

## 1. Kaggle Competitions

### 1. First-run flow
1. Create a Kaggle account (email/Google/GitHub sign-in). [MEDIUM]
2. Browse the Compete tab; beginners are steered to "Getting Started" competitions (e.g., Titanic, House Prices, Digit Recognizer) — rolling deadline, no cash prize, "plenty of tutorials and example submissions available." [MEDIUM]
3. Click "Join Competition" / accept competition rules on the competition page. [MEDIUM]
4. Two parallel paths from here, both officially supported:
   - **In-browser path (now the more heavily pushed default):** click "New Notebook" on the competition page → a Jupyter-style Kaggle Notebook opens with the competition's dataset already attached under the Input panel, free CPU/GPU/TPU quota, libraries pre-installed. [MEDIUM]
   - **Local path:** go to the Data tab → "Download all" → work in your own local environment (any language/IDE). [MEDIUM]
5. Explore data, often starting by reading public notebooks other competitors have shared for that competition. [MEDIUM]
6. Train a model, generate predictions on the test set, and format them into a submission CSV matching the competition's `sample_submission.csv` schema (typically an ID column + a prediction column). [MEDIUM]
7. Submit either by (a) dragging the CSV onto the web upload widget on the competition's "Submit Predictions" page, or (b) using the official Kaggle CLI: `pip install kaggle`, place API token at `~/.kaggle/kaggle.json`, then `kaggle competitions submit -c <competition> -f submission.csv -m "message"`. [HIGH for the CLI mechanics — from the official `kaggle-api` README]
8. See your score appear on the (provisional) public leaderboard; iterate.

### 2. Artifact type
**Hybrid**, and the mix has shifted over time toward "no local setup at all": the primary modern path is an **in-browser notebook environment** (Kaggle Notebooks, formerly "Kernels") auto-attached to competition data — closer to a "browser editor" than a template repo. But Kaggle also still fully supports a **local-dev + web-upload** flow, and a **CLI tool** (`kaggle` Python package) for programmatic download/submit. There is no fork-a-template-repo pattern in Kaggle's general competition flow — that pattern doesn't exist here at all.

### 3. Time-to-first-submission / dropout
**No platform-wide official metric found.** Kaggle does not publish aggregate time-to-first-submission or completion/dropout numbers for competitions in general.
One concrete, competition-specific data point exists in an academic writeup of a single Kaggle competition: for **"IceCube — Neutrinos in Deep Ice,"** 6,460 people registered but only 901 (~14%) submitted at least one valid solution. [MEDIUM — figure surfaced via WebSearch's reading of the arXiv paper (arxiv.org/abs/2307.15289); I could not independently re-extract the exact sentence from the raw PDF text, which came back as unparseable binary through the fetch tool, so treat this number as needing a second check before citing it hard]. This is one competition's funnel, not a Kaggle-wide statistic — do not generalize it.

### 4. What changed over time
- **2010:** Kaggle founded (Anthony Goldbloom, Ben Hamner) as a pure predictive-modeling competition marketplace — no in-browser compute at all; competitors worked entirely locally and uploaded CSVs. [MEDIUM]
- **July 2016:** Launched "Kernels" — an in-browser, cloud-hosted notebook environment — letting competitors write/run code with zero local setup for the first time. [MEDIUM]
- **~2016:** Kaggle API (CLI) released, adding a scriptable path for downloading data and submitting predictions outside the browser. [HIGH for the tool's existence/README; MEDIUM for the 2016 dating]
- **March 2017:** Acquired by Google; gained free TPU access for notebooks and deeper Google Cloud Storage/BigQuery integration, plus engineering investment in leaderboard/API reliability. [MEDIUM]
- **Later (exact date not pinned):** "Kernels" renamed to "Notebooks" — confirmed via an official Kaggle product-feedback thread title ("Renaming 'Kernels' to Kaggle Notebooks"), but the thread's own rationale text and exact ship date were not retrievable (Kaggle's site is a JS-rendered SPA that could not be fetched for body content — see blocked sources below). [LOW — title only, no retrievable rationale]
- **Ongoing:** the competition page's "New Notebook" button, which auto-attaches the competition's dataset, has become the default/most-promoted entry point into a competition, effectively pushing new entrants toward the in-browser path over local-download-and-upload. I could not find an official announcement dating or explaining this shift explicitly — this is inferred from current product behavior and secondary tutorials, not sourced to a dated statement. [LOW — inference]

### Sources
- [Kaggle API README (github.com/Kaggle/kaggle-api)](https://github.com/Kaggle/kaggle-api) — HIGH
- [Serokell: How to Participate in a Kaggle Competition](https://serokell.io/blog/kaggle-competition) — MEDIUM
- [Towards Data Science: Making Your First Kaggle Submission](https://towardsdatascience.com/making-your-first-kaggle-submission-36fa07739272/) — MEDIUM
- [Data Science Dojo: My First Kaggle Submission](https://datasciencedojo.com/tutorial/my-first-kaggle-submission/) — MEDIUM (thin: intro framing only, fetch tool couldn't reach full body)
- [Wikipedia: Kaggle](https://en.wikipedia.org/wiki/Kaggle) / [DataCamp: What is Kaggle?](https://www.datacamp.com/blog/what-is-kaggle) — MEDIUM (history/founding/acquisition/Kernels dates)
- [Kaggle product-feedback: Renaming "Kernels" to Kaggle Notebooks](https://kaggle.com/product-feedback/116093) — LOW (title only)
- [arXiv: Kaggle Chronicles — 15 Years of Competitions](https://arxiv.org/abs/2511.06304) — MEDIUM (abstract only; full text not retrievable through fetch tooling)
- [arXiv: Public Kaggle Competition "IceCube — Neutrinos in Deep Ice"](https://arxiv.org/pdf/2307.15289) — MEDIUM (dropout stat, see caveat above)
- **Blocked/inaccessible:** `www.kaggle.com/docs/competitions`, `www.kaggle.com/code/alexisbcook/getting-started-with-kaggle-competitions`, and every other `kaggle.com/*` URL attempted via WebFetch returned only the HTML `<title>` tag with no body content — Kaggle's site is a client-side-rendered SPA and the fetch tool cannot execute JavaScript. Not a 403, but functionally equivalent to one for this research method. Worked around via third-party tutorials and the (non-JS, static) GitHub API README.

---

## 2. MIT Battlecode

### 1. First-run flow
1. Visit `battlecode.org`, register/create a team on `play.battlecode.org` (the team/scrimmage dashboard). [MEDIUM — page fetch only returned partial content]
2. Clone or fork the **year-specific scaffold repo** on GitHub, e.g. `github.com/battlecode/battlecode25-scaffold`. This is a genuine fork/clone-a-template-repo pattern, reissued fresh every season (older seasons: `bc18-scaffold`, `battlecode24-lectureplayer`, etc., all under the `battlecode` GitHub org). [HIGH — fetched directly]
3. Choose a language subdirectory: `java/` (primary/fully supported) or `python/` (marked "EXPERIMENTAL" in the 2025 scaffold, "not eligible to participate against other java bots"). Follow the README inside that subdirectory. [HIGH — quoted verbatim from the scaffold README]
4. Java path specifics (from `java/README.md`): copy the example bot (`examplefuncsplayer`) into a new package rather than editing it directly; key Gradle commands are `./gradlew build` (compile), `./gradlew run` (run a match per `gradle.properties` settings), `./gradlew update` (pull latest engine/config), `./gradlew zipForSubmit` (package your bot for submission), `./gradlew tasks` (list more commands). [HIGH — quoted verbatim]
5. View match replays in the client — the 2025 season notes: "We are using a rewritten version of the client this year, so please let the devs know if you encounter any issues." [HIGH — quoted verbatim]
6. Optional but notable: MIT runs **daily lectures for the first two weeks of January** covering the skills needed to play, streamed and uploaded to YouTube, plus a Discord for support — i.e., onboarding is partly a live, cohort-based, time-boxed event (tied to MIT's January IAP term), not purely self-serve async docs. [MEDIUM]
7. Submit the zipped bot via the `play.battlecode.org` web dashboard to enter scrimmages and tournament rankings.

**Naming-collision flag:** search results also surface `docs.battlecode.cam` ("Cambridge Battlecode," with its own `cambc` CLI and a "Your First Bot" Python-only guide). This is a **separate, unofficial community competition**, not MIT's official Battlecode — don't conflate the two when citing "Battlecode's" onboarding flow.

### 2. Artifact type
**Hybrid: template repo (fork/clone a fresh scaffold each season) + local CLI build tooling (Gradle) + a web dashboard** (`play.battlecode.org`) for team management, submission, and scrimmage/replay viewing. Code is written and compiled locally; the web layer is for coordination/competition infrastructure, not for writing code (no browser IDE for the official competition).

### 3. Time-to-first-submission / dropout
**Not found.** No published participation-funnel statistics located for MIT Battlecode.

### 4. What changed over time
- **Client rewrite for the 2025 season:** stated directly in the scaffold README ("We are using a rewritten version of the client this year"), but no further rationale is given beyond a request for bug reports/feedback. [HIGH for the fact, LOW for any "why"]
- **Python support widening:** the 2025 scaffold README calls Python "EXPERIMENTAL" and explicitly bars it from competing against Java bots; the current `battlecode.org/about.html` page (2026 season) states "This is the first year that we are offering Python globally, and updates may be made during the season." Read together, this suggests a gradual rollout — Python went from an experimental, segregated track to a globally-supported second language over roughly one season. [MEDIUM — pieced together from two different seasons' pages, not one document narrating the change]
- **Yearly scaffold reissue as a structural pattern:** rather than maintaining one evergreen template repo, the `battlecode` GitHub org publishes a new scaffold repo every season (`bc18-scaffold`, `battlecode24-lectureplayer`, `battlecode25-scaffold`, …) — the template-repo pattern itself is stable, but the artifact is deliberately non-persistent year over year. [HIGH — visible directly in the GitHub org's repo listing]

### Sources
- [battlecode/battlecode25-scaffold (GitHub)](https://github.com/battlecode/battlecode25-scaffold) — HIGH
- [battlecode25-scaffold/java/README.md](https://github.com/battlecode/battlecode25-scaffold/blob/master/java/README.md) — HIGH
- [battlecode.org/about.html](https://battlecode.org/about.html) — HIGH (official, but fetch tool only surfaced partial content)
- [battlecode GitHub org (repo history)](https://github.com/orgs/battlecode/repositories) — HIGH
- [Cambridge Battlecode docs — "Your First Bot"](https://docs.battlecode.cam/getting-started/first-bot) — MEDIUM, but flagged as a **different, unofficial platform**, not MIT's
- **Blocked/inaccessible:** `play.battlecode.org` root returned only a page `<title>` (JS single-page app); `play.battlecode.org/bc25java/quick_start` (linked from the Java README as "the full quick start guide") returned HTTP 404 through the fetch tool.

---

## 3. Halite by Two Sigma

### 1. First-run flow
Recovered directly from an archived copy of the official `halite.io` "Learn How to Get Started with Halite" page (Halite II era, captured 2017-12-11 by the Wayback Machine). The page laid out an explicit 4-step numbered flow:
1. **SIGN UP** — "First, you need to sign up via Github and create a user profile."
2. **WATCH A FEW GAMES** — "get a feel for how to play the game" via example match videos and other players' replay-filled profiles, before reading the rules.
3. **DOWNLOAD A BOT** — "download the game environment and starter kit for your platform and language of choice. The game environment and starter kit are bundled together, so you should be all set."
4. **SUBMIT THE STARTER BOT** — "just go ahead and submit the starter bot you downloaded and then [go] to your user profile to see how you've done," then iterate using a follow-on "improving the basic bot" guide.
[HIGH — quoted verbatim from the archived primary source]

### 2. Artifact type
A **downloadable starter-kit bundle** (zip containing a local game-environment binary + a template bot in your chosen language) is the primary onboarding artifact — not a GitHub fork-a-repo flow for beginners (though the underlying engine/starter-kit source was also open-sourced on GitHub under `github.com/HaliteChallenge`), not browser-based, and not CLI-first for newcomers (an advanced "Halite CLI, Tools and API" section existed in the docs nav for power users, but the beginner path is "download, don't clone"). Sign-in was GitHub-OAuth-based even though the artifact itself wasn't a repo fork.

### 3. Time-to-first-submission / dropout
**Not found.**

### 4. What changed over time
- **Halite I** (Nov 2016 – Feb 2017): grid-based territory-conquest game; ~1,500 competitors. Originated as an **internal Two Sigma summer-intern project** (Ben Spector and Michael Truell, 2016) before being opened to the public. [MEDIUM — Wikipedia dates; HIGH for the internal-origin story, quoted from the Halite-II GitHub README's "Authors" section]
- **Halite II** (Oct 2017 – Jan 2018): ~6,000 players across 100+ countries. The GitHub README states the team explicitly **considered simply reviving Halite I** but chose a full game redesign instead — "given the progress the community made and the number of open source bots that had been published" — moving from discrete grid movement to continuous-space ship/planet combat. This is a directly stated rationale for redesigning the game (not just re-skinning it) each season. [HIGH — quoted verbatim]
- **Halite III** (Oct 2018 – Jan 2019): ocean/resource-collection theme; 4,000+ players, 460+ organizations. [MEDIUM — Wikipedia]
- **Halite IV** (mid-June 2020): **migrated wholesale onto Kaggle** as the hosting platform, rather than continuing on the bespoke `halite.io` site. [MEDIUM — Wikipedia] This is the single largest onboarding-model change in Halite's history: the flow shifted from "GitHub sign-up → download a starter-kit zip → bespoke leaderboard site" to "use Kaggle's own account/notebook/leaderboard infrastructure" (i.e., Halite IV effectively inherited whatever onboarding flow Kaggle competitions use generally — see Section 1). No official Two Sigma statement explaining *why* they moved to Kaggle was found (plausibly reduced hosting/ops burden, but this is speculation, not sourced).
- `halite.io` itself appears to have gone dark/parked sometime after — Wayback Machine captures from 2022–2024 show garbled/spam-pattern URLs being crawled rather than the original site content, but no explicit shutdown announcement was found. [LOW — inferred from crawl artifacts, not a stated fact]

### Sources
- [Wayback Machine: halite.io/learn-programming-challenge (2017-12-11 capture)](http://web.archive.org/web/20171211092411/https://halite.io/learn-programming-challenge/) — HIGH (primary source, fetched and verified verbatim)
- [github.com/HaliteChallenge/Halite (README)](https://github.com/HaliteChallenge/Halite) — HIGH
- [github.com/HaliteChallenge/Halite-II (README)](https://github.com/HaliteChallenge/Halite-II) — HIGH
- [github.com/HaliteChallenge/Halite-III (README)](https://github.com/HaliteChallenge/Halite-III) — HIGH
- [Wikipedia: Halite AI Programming Competition](https://en.wikipedia.org/wiki/Halite_AI_Programming_Competition) — MEDIUM
- [Two Sigma: Halite II Concludes, Winners Announced](https://www.twosigma.com/articles/halite-ii-concludes-winners-announced/) / [Two Sigma: Introducing Halite](https://www.twosigma.com/articles/introducing-halite-our-limited-release-ai-challenge/) — surfaced via search, not independently deep-fetched — LOW/MEDIUM, listed for completeness
- **Blocked, worked around:** the WebFetch tool explicitly refuses `web.archive.org` URLs ("Claude Code is unable to fetch from web.archive.org"). Worked around by shelling out to `curl` directly against Wayback's raw snapshot URLs and its CDX search API. This workaround stopped being available partway through the session (the sandboxed working-directory/worktree was removed out from under the Bash tool — an environment/session issue unrelated to the research target), which prevented pulling additional Halite III–specific archived pages (e.g., the Halite III "Downloads and Starter Kits" page, which would have named the exact local CLI tool, e.g. a `hlt_client`-style tool referenced only indirectly in Halite I's `advanced_command_line.php` page seen in the CDX index but not fetched).

---

## 4. Screeps

### 1. First-run flow
For the original game, **Screeps: World**:
1. No install, no download, and **no account required** to start: go to `screeps.com`, scroll to the "Live Demo" button, click "Tutorial." [MEDIUM — quoted claim from a third-party walkthrough, consistent with the official docs' framing of an "interactive tutorial"]
2. The in-browser interactive tutorial runs in a simulated room and is broken into **5 steps**; the first 3 are documented in the source found:
   - Step 1 — Game UI & basic scripting: spawn a creep, command a harvester creep to gather energy.
   - Step 2 — Upgrading your controller: introduces creep memory to differentiate creep roles.
   - Step 3 — Building structures: build extensions to increase available energy.
   - Steps 4–5: titles/content not recovered in sources checked. [MEDIUM for steps 1–3; NOT FOUND for steps 4–5]
3. To play persistently beyond the tutorial, create an account and claim a room in a live shard. The main "MMO" shard's higher CPU is subscription-gated, but a free non-subscription shard (**Shard3**, launched October 2018) exists, and free-tier CPU was raised from 10 to 20 at that launch. [MEDIUM — official blog post title/summary, "Non-Subscription Shard Launched"]
4. Ongoing play is code-only: Screeps ships an in-browser code editor on the site itself, and also supports local development in any editor with code pushed to the server via the Screeps API — an official open-source Atom-editor package ("Screeps IDE," released 2019-08-31) added API autocomplete, an in-editor console, a memory viewer, and file sync for players who want a local workflow. [HIGH — official blog post, title and feature list confirmed]

### 2. Artifact type
**Hybrid, and unusually so**: the onboarding path is a true **browser-based interactive tutorial/IDE with zero install**, but ongoing "real" play requires **persistent server-side code execution** (your JS keeps running against a live shared world whether you're at the keyboard or not) — closer to "deploy a long-running service" than either a template repo or a one-shot submission. Serious players commonly move to local editors + a sync tool, making the eventual artifact type "local code, pushed to a persistent remote runtime," not a repo you fork/PR.

### 3. Time-to-first-submission / dropout
**Not found.** Steam aggregator sites (SteamSpy, PlayTracker, SteamCharts) report ownership/concurrency (Screeps: World has roughly 200k–500k Steam owners) but these are not onboarding-funnel or tutorial-completion statistics.

### 4. What changed over time — the World/Arena split
This is the most significant, best-documented "what changed and why" finding across all five platforms:
- **Screeps: World** (the original, persistent MMO) has an acknowledged onboarding/legibility problem: per community discussion, "trying to explain a persistent Screeps bot requires a weeks course" — because there's no natural start/end point to a match, it's hard to demo or teach quickly.
- **Screeps: Arena** was built as a **separate Steam product on the same underlying engine**, deliberately trading the persistent-colony model for short, match-based 1v1 PvP with ELO ranking — explicitly framed by the community as solving the demo/onboarding problem: "you can show off an Arena match over maybe 10 minutes and explain the concepts, choices and factors causing a victory," versus the weeks-long ramp for World. [MEDIUM/LOW — this rationale comes from Steam community/forum characterization rather than an official developer blog post stating "we built Arena because onboarding to World was too slow"; I could not find an official post making that causal claim explicitly, only the Steam store's own description of Arena as fast/asynchronous/match-based, which is consistent with the community's read but doesn't itself state the motive]
- Net effect: rather than redesigning World's onboarding, Screeps shipped an entirely separate, faster-to-learn product alongside it — a "spin off a light onboarding product" strategy distinct from Kaggle's or Battlecode's approach of iterating on one onboarding flow in place.

### Sources
- [docs.screeps.com](https://docs.screeps.com/) / [docs.screeps.com/introduction.html](https://docs.screeps.com/introduction.html) — HIGH (official), but the fetch tool only returned a partial table of contents/summary, not the full page body
- [LearnCodeByGaming: Screeps Tutorial Introduction](https://learncodebygaming.com/blog/screeps-tutorial-introduction) — MEDIUM
- [blog.screeps.com](https://blog.screeps.com/) (official blog/changelog index) — HIGH for the specific posts identified ("Non-Subscription Shard Launched," "Screeps IDE Alpha Release," "Power Era Has Begun"); the blog archive returned by the fetch tool only extended back to 2019, so more recent (Arena-launch-era) posts were not directly retrieved
- [Steam Community: Screeps: World vs. Screeps: Arena discussion](https://steamcommunity.com/app/464350/discussions/0/5281042383609335126/) and [Difference to Screeps: World discussion](https://steamcommunity.com/app/1137320/discussions/0/3060743663452237852/) — LOW/MEDIUM (community/forum opinion, not official, but the "10 minutes vs weeks" characterization was consistent across independent threads)
- [Screeps: Arena on Steam (store page)](https://store.steampowered.com/app/1137320/Screeps_Arena/) — MEDIUM (official product description, corroborates the match-based/asynchronous framing)
- [SteamSpy: Screeps: World](https://steamspy.com/app/464350) / [PlayTracker: Screeps: World](https://playtracker.net/insight/game/10815) — MEDIUM (ownership aggregates only, not onboarding data)

---

## 5. Robocode

### 1. First-run flow

**Classic Robocode** (desktop Java app), quoted verbatim from RoboWiki's official-linked "My First Robot" tutorial:
1. Download Robocode (version 1.11.1 referenced) from SourceForge — requires a JDK. [MEDIUM]
2. From the main Robocode screen: **Robot menu → Source Editor**, then **File menu → New Robot**; name your bot and enter your initials in the prompts.
3. The generated template contains a `run()` method with `while(true) { ... }` — "'Do the stuff inside my curly brackets, forever'" — plus default movement (`ahead()`, `back()`), gun rotation (`turnGunRight()`), and a firing routine in `onScannedRobot()`.
4. **File menu → Save**, then **Compiler menu → Compile**.
5. **Battle menu → New**, add your robot plus at least one opponent, then click **"Start Battle."**
[HIGH — all steps quoted verbatim from the tutorial]

**Robocode Tank Royale** (modern rewrite):
1. Follow the official "Installation guide," then the "Getting Started" tutorial: install and run the Tank Royale GUI, unzip the provided sample bots, point the GUI at the sample-bots directory, and run a practice battle to see how the game plays before writing any code. [HIGH]
2. Move to "My First Bot": create a bot directory + a JSON descriptor file + a bot source file (same base name as the directory) in your language of choice — official Bot APIs exist for Python, Java/JVM languages (incl. Kotlin, Groovy, Scala, Clojure), .NET (C#, F#, VB), and TypeScript/JavaScript — then run the bot via the GUI or the Battle Runner API. [HIGH]
3. Under the hood, each bot now runs as an **independent OS process** talking to a central server over a WebSocket-based protocol, rather than living inside one shared JVM as in classic Robocode.

### 2. Artifact type
**Classic Robocode** = a single **all-in-one desktop application** (download + install; the app itself bundles a source editor, compiler, and battle runner — genuinely no external IDE required). **Tank Royale** = a **language-agnostic protocol/server + GUI + per-language SDK ("Bot API") libraries** installed via each language's own package manager (pip / Maven / NuGet / npm) — a real hybrid of "run a local server/GUI" plus "install an SDK and write code in your own editor," much closer to a modern installable-SDK model than the classic monolithic app.

### 3. Time-to-first-submission / dropout
**Not found** for either version.

### 4. What changed over time — why Tank Royale exists
Quoted directly from the official Tank Royale docs' "Tank Royale vs original Robocode" article:
- **Explicit clean break, not an upgrade path**: "the goal of Tank Royale is not to be compatible with the old version." It's meant to be "a better and improved version of the original game," not a patch to it.
- **Stated motivation**: enable "any programming language" (as long as it can speak WebSocket) and enable play "via the Internet," neither of which classic Robocode — Java-only, single-shared-JVM, local-only — could support.
- **Architecture change and its acknowledged trade-off**: classic Robocode ran every bot inside one shared JVM, which let the engine directly police each bot's CPU/RAM/disk usage. Tank Royale runs each bot as an independent process communicating over WebSocket, and the docs explicitly acknowledge the regression this causes: the engine "will not be able to constrain how much CPU, RAM, disk space, etc. the bot is allowed to use" the way it previously could. This is a rare case of a maintainer team stating both the reason for a rewrite *and* the cost it introduced, in one official document.
- Determinism was also explicitly engineered in: Tank Royale is turn-based with commands executing sequentially (removing the "which bot's thread got scheduled first" non-determinism classic Robocode could exhibit).

### Sources
- [robocode.sourceforge.io](https://robocode.sourceforge.io/) (official classic site) — HIGH
- [RoboWiki: Robocode/My First Robot](https://robowiki.net/wiki/Robocode/My_First_Robot) — HIGH (community wiki, but this is the tutorial linked directly from the official site; quoted verbatim)
- [github.com/robocode-dev/tank-royale](https://github.com/robocode-dev/tank-royale) (official repo README) — HIGH
- [robocode.dev/articles/tank-royale.html — "Tank Royale vs original Robocode"](https://robocode.dev/articles/tank-royale.html) — HIGH (official docs, quoted verbatim)
- [robocode.dev/tutorial/getting-started.html](https://robocode.dev/tutorial/getting-started.html) — HIGH (official docs)
- No 403s or blocked sources encountered for Robocode — all key pages were reachable directly.

---

## Cross-platform note on tooling limitations encountered

- **Kaggle** (`kaggle.com/*`) is a client-rendered SPA; the fetch tool could retrieve only `<title>` tags, never body content, on every attempt. All Kaggle claims above rest on third-party tutorials/blogs plus the one static, non-JS official source available (the `kaggle-api` GitHub README).
- **web.archive.org** is explicitly refused by the WebFetch tool ("Claude Code is unable to fetch from web.archive.org"). The Halite section's primary-source material was only obtainable by shelling out to `curl` directly. That workaround became unavailable partway through this task when the sandboxed session's working directory was removed out from under the Bash tool (an environment/session-isolation issue, not a block imposed by any research target) — this capped how much archived Halite III–specific detail (e.g., the exact local CLI tool name) could be recovered.
- **play.battlecode.org** is a JS single-page app; both the root URL and a specific deep-linked "quick start" page failed to yield usable content, so MIT Battlecode's flow is sourced from the (static, fetchable) GitHub scaffold repos and `battlecode.org/about.html` instead.
- No outright HTTP 403s were hit on any platform; the practical blockers were all either JS-rendering (Kaggle, play.battlecode.org) or a tool-level policy refusal (web.archive.org).
