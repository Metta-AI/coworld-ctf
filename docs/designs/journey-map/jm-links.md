<!-- Source: internal tracking, not public; copied verbatim 2026-09-09 (shot paths repointed to ./shots/) -->

# jm-links — cold entries walk. Era: 2026-09-09, live ladder paintbot-v0.7.374 (GV61/Glory16), coworld-ctf main ≈ 070d4805.

Slug `jm-links`, worker in epic 16d081ab (THE WHOLE). Five cold entries (a–e), each its own fresh headless-Chromium profile under `/tmp/jm-links/profile-<entry>`, click count restarted per entry. Persona: never-heard-of-Paintbot beginner. Screenshots: full-size in `.harness/screenshots/jm-links/`, downscaled copies at `./shots/`.

**Replay URL shape found (as myself, before the persona walk):** loading `https://softmax.com/paintbot` client-side-routes to `https://softmax.com/paintbot?e=<episode_id>#watch-stage` for whatever episode is on screen — this is what a "share/copy link" action would produce, and it is what a beginner pasted into a chat would receive.

---

## Entry (a) — shared replay link

### S1 — Paintbot Theater (cold replay) — https://softmax.com/paintbot?e=416bd795-3d07-46c6-9e05-47e5aabac419#watch-stage
- Reached from: entry (a), pasted cold, no prior page; clicks from entry: 0
- What it says: "Round 4604 Episode 2" header, and inline: "Paintbot: paintball-flavored team tag. The players are AI policies... Season 2 plays battle royale: sixteen duos on a giant generated map, a closing zone, no respawns, last team standing... Every act mints Glory as it happens." — the full game page: nav, live leaderboard, embedded replay, and a "THE COWORLD" blurb, all on one URL.
- Beginner question answered: WHAT IS THIS — the "THE COWORLD" paragraph answers it with zero clicks. WHY WOULD I CARE — partial, via "Every act mints Glory" and a "COMPETE — Submit a policy" CTA, but "Glory" itself is undefined jargon here.
- Where the thread breaks: (1) first paint shows only a spinner ("Loading replay...") for several seconds with no progress indicator — reads as broken; (2) once loaded, the embedded HUD uses unexplained jargon — "GLORY", "HUDDLE", "FIT", "HUNTING"/"TAGGING" — none defined on-screen; (3) the sidebar "Score" (e.g. 383.5K, a season-long ladder number) and the in-replay per-player "×N" counts (e.g. richard ×192, a single-episode tag count) are two different numbering systems shown side by side with nothing linking them.
- Hand-off: nav bar carries Observatory, Human Play, Forum, Wiki — all one click away. No "Docs" link anywhere on this page.
- Owning lane: paintbot engine/viewer (theater shell) + observatory epic (embedded replay)
- Shot: jm-links-01.png (cold spinner), jm-links-02.png (endcard, seeked via slider+16× — visual: whole map painted magenta, "FINAL" badge, no big on-screen "winner" banner; "RUST WINS"/"GAME OVER" only in accessibility text)

### S2 — Paintbot Wiki main — https://softmax.com/paintbot/wiki/main
- Reached from: (a) S1, clicked "Wiki" in nav; clicks from entry: 1
- What it says: "Verified against GV24 / Glory 12... Paintbot is a top-down team paintball game played by AI policies... you submit a policy — a linux/amd64 Docker image — that drives a Cog... In the game's classic capture-the-flag mode — the ruleset the rest of this wiki assumes unless a page says otherwise — two 8-player teams, Red and Blue..."
- Beginner question answered: HOW IT WORKS — yes, in depth (30+ linked pages: Combat, Scoring, Glory, Perception, Wire, etc.)
- Where the thread breaks: contradicts another surface — this page is stamped "GV24 / Glory 12" and describes classic CTF as the default ruleset, but the live game (S1, and the whole ladder) is running Battle Royale S2 at GV61/Glory16. A beginner reading this page first would learn the wrong ruleset.
- Hand-off: page list includes "Build and submit" (→ S3).
- Owning lane: wiki
- Shot: jm-links-03.png

### S3 — Wiki: Build and submit — https://softmax.com/paintbot/wiki/build-and-submit
- Reached from: (a) S2, clicked "Build and submit" in page list; clicks from entry: 2
- What it says: "Verified against coworld CLI package version resolving to paintbot-v0.7.372 (GV61 / Glory 16), 2026-09-09. Getting a policy from nothing to a real league entry is five steps: download the coworld package, prove it runs locally..." — a real, current, step-by-step build guide with exact CLI commands.
- Beginner question answered: COULD I BUILD ONE — yes, concretely, and current (contrast with S2's stale banner).
- Where the thread breaks: none on this page itself, but it is only reachable by guessing "Wiki" then scanning an alphabetical 30-item page list — no direct "build/get started" link from S1.
- Hand-off: none further needed; page is self-contained with runnable commands.
- Owning lane: wiki / coworld CLI
- Shot: jm-links-04.png

## Entry (b) — forum post

### S4 — /forum (guessed path) — https://softmax.com/forum
- Reached from: entry (b), typed guess; clicks from entry: 0
- What it says: "Nothing is playing here. That address does not name a league the theater can stage... Browse all leagues →" (HTTP 404, themed as a "no such league" page, not a generic 404)
- Beginner question answered: none
- Where the thread breaks: broken link — the themed message talks about "leagues," not forums, so it doesn't even signal that "/forum" was the wrong guess for the right reason.
- Hand-off: "Browse all leagues" link only.
- Owning lane: paintbot engine/viewer (theater 404 handler)
- Shot: none

### S5 — Paintbot Forum index — https://softmax.com/paintbot/forum
- Reached from: (b) landed on /paintbot, clicked "Forum" in nav; clicks from entry: 2
- What it says: "Paintbot forum / Hot New Top" then post titles like "The ceiling I fitted in-sample last wake fired on a seat it never saw: softmaxwell's 16,777,216 episode banked as 8,693,413, because the cap is 150x your OWN score..."
- Beginner question answered: none — all 8 visible "Hot" post titles are ladder-scoring-algorithm research, none oriented to a newcomer.
- Where the thread breaks: jargon (clamp, seat, round-sum, in-sample, binding, standing) — every visible post assumes deep familiarity with the ranking formula; no pinned "start here" post.
- Hand-off: full nav present (Paintbot/Theater, Wiki, Observatory) so a beginner isn't stuck, just unserved by the content.
- Owning lane: forum (metta)
- Shot: jm-links-05.png

### S6 — Forum post (cold, top "Hot") — https://softmax.com/paintbot/forum/post_751fa1e0-4052-495c-b207-1f9af4ff9ec0
- Reached from: (b) S5, clicked the top post; clicks from entry: 3
- What it says: same "ceiling"/clamp post in full — three paragraphs of statistics on the standing formula, by "Solbiati Alessandro."
- Beginner question answered: none
- Where the thread breaks: jargon (same as S5, worse — full technical body); no next step toward WHAT IS THIS from the post body itself.
- Hand-off: nav only (← Forum, Paintbot/Theater, Wiki, Observatory).
- Owning lane: forum (metta)
- Shot: none (text captured directly)

## Entry (c) — search result

### S7 — softmax.com root — https://softmax.com/
- Reached from: entry (c), typed as the natural first click for "softmax paintbot" / "softmax.com" queries (see Search truth); clicks from entry: 1
- What it says: "Train, eval, test, repeat. A universe of multiplayer games where humans and their coding agents compete, cooperate, and interact." Then a "Feature leagues" card for Paintbot: "Team paintball meets capture-the-flag: squads split roles, call positions, and trade territory for momentum."
- Beginner question answered: WHY WOULD I CARE ("Why Softmax" mission blurb) and WHAT IS THIS for Paintbot specifically (one-line card).
- Where the thread breaks: none major; this is the best-organized surface found in the whole walk — nav has Docs, Observatory, GitHub (footer icon), Discord, all one click away. Notably: no Wiki, no Forum link from here.
- Hand-off: "Paintbot (Season 2)" card → S8; "Docs" → entry (d); GitHub footer icon → entry (e).
- Owning lane: James (home/nav)
- Shot: jm-links-06.png

### S8 — Paintbot page via root nav — https://softmax.com/paintbot
- Reached from: (c) S7, clicked "Paintbot (Season 2)"; clicks from entry: 2
- What it says: same theater shell as (a) S1, auto-resolves to the current on-screen episode.
- Beginner question answered: same as (a) S1 (WHAT IS THIS, partial WHY).
- Where the thread breaks: same as (a) S1.
- Hand-off: same as (a) S1.
- Owning lane: paintbot engine/viewer
- Shot: none (same page as jm-links-01/02)

## Entry (d) — docs.softmax.com cold

### S9 — docs.softmax.com home — https://docs.softmax.com/
- Reached from: entry (d), typed cold; clicks from entry: 0
- What it says: "Softmax studies organic alignment: how agents learn to cooperate, specialize, and form effective groups. Coworlds turn that question into live multiplayer games where you can test agents against other minds." Heading: "Build and evaluate agents in Coworlds."
- Beginner question answered: HOW IT WORKS (generic, framework-level) — not WHY WOULD I CARE in concrete terms, and not WHAT IS THIS about any specific game.
- Where the thread breaks: no next step toward Paintbot — the word "paintbot" does not appear on this page at all (checked programmatically: false).
- Hand-off: "Build your first player" (quickstart), "Coworld on GitHub" → entry (e).
- Owning lane: docs.softmax.com
- Shot: jm-links-07.png

### S10 — docs subpages (quickstart / coworld overview / build-a-player overview) — https://docs.softmax.com/guides/quickstart, /coworld/overview, /coworld/build-a-player/overview
- Reached from: (d) S9, clicked "Build your first player" then two more Coworld guide links; clicks from entry: 1-3
- What it says: generic Coworld/agent-building instructions (CLI install, player contract) with no game named.
- Beginner question answered: HOW IT WORKS (generic) only.
- Where the thread breaks: no next step — three clicks deep and the word "paintbot" still never appears (checked programmatically on all three: false, false, false). A beginner who arrived at docs.softmax.com would have no way to learn this connects to the Paintbot game they may already know from elsewhere.
- Hand-off: none toward Paintbot specifically; docs stay game-agnostic throughout.
- Owning lane: docs.softmax.com
- Shot: none (text-verified)

## Entry (e) — GitHub

### S11 — github.com/Metta-AI/coworld README — https://github.com/Metta-AI/coworld
- Reached from: entry (e), WebSearch "coworld github softmax" (the query that surfaces it — "paintbot softmax github" does not, see Search truth); clicks from entry: 1
- What it says: "Coworld is where games become programmable arenas: worlds you can run locally, play in the browser, use to evaluate players, and enter through league submissions... The coworld package contains the public CLI, Python helpers, manifest types and schemas, runner tooling, and the Paint Arena reference world."
- Beginner question answered: HOW IT WORKS / COULD I BUILD ONE — yes, extensively (Build a player, Build a Coworld, Bedrock guide, cookbook, manifest reference all linked).
- Where the thread breaks: the word "paintbot" never appears (checked programmatically: false) — the README names "Paint Arena," a different, simpler bundled reference game, which risks a beginner conflating the two.
- Hand-off: heavily links out to docs.softmax.com (Coworld guide, Build a player, Build a Coworld) and to `softmax.com/play.md` / `softmax.com/coworlds/llms.txt` for live league guides — real, working hand-off to the site.
- Owning lane: GitHub README
- Shot: jm-links-08.png

---

## Threads

- B1: (a) S1 → cold replay first paint is a bare "Loading replay..." spinner for several real seconds with no progress cue → leave (looks broken)
- B2: (a) S1 → in-replay HUD jargon (GLORY, HUDDLE, FIT, HUNTING/TAGGING) shown with zero on-screen definitions → guess
- B3: (a) S1 → season "Score" (383.5K) and episode "×N" tag counts are two unlinked numbering systems on the same screen → guess
- B4: (a) S2 vs S3 → wiki/main stamped GV24/Glory12 describing classic CTF as default, contradicts wiki/build-and-submit stamped GV61/Glory16 (current) and contradicts the live game (battle-royale-s2) → ask / distrust the wiki
- B5: (a) S1 → no "Docs" link anywhere on the replay page; COULD I BUILD ONE only reachable by guessing "Wiki" then scanning 30 unsorted page titles → search/guess
- B6: (b) S4 → /forum guess 404s with a "no such league" themed message that never says forums exist elsewhere → leave
- B7: (b) S5/S6 → every visible forum post is deep ladder-scoring-algorithm research (clamp, seat, round-sum, in-sample) with no beginner on-ramp post → leave
- B8: (c) query "paintbot" bare → top 9 results are entirely unrelated products (wall-painting robots, a Bomberman clone, an RL painting-agent paper); softmax.com never appears → leave or refine query
- B9: (c) query "softmax.com" bare → top 9 results are all about the ML softmax activation function; the real site is absent from/last in the visible set → leave, conclude no company site exists
- B10: (c) query "paintbot ai league" → 7 of 8 results are irrelevant (League of Legends fan content, a video-game wiki, RoboCup, unrelated GitHub "paintbot" clones) → guess wrong link
- B11: (d) S9/S10 → docs.softmax.com never says "paintbot" at the landing page or three clicks deep → no next step toward the concrete game
- B12: (e) query "paintbot softmax github" → none of the top 9 results is the real repo; only the differently-worded "coworld github softmax" surfaces it (near the bottom) → leave or give up on GitHub
- B13: (e) S11 → README names "Paint Arena" (a different bundled reference game) but never "Paintbot" → mild conflation risk

## Hallways not reached

- (a) replay link: reached home/nav/paintbot/watch/wiki/standings/replay viewer/score-bug strip/endcard; observatory league page and forum present as links but not clicked in this entry; NOT reached: docs.softmax.com, sign-in, CLI (UI), submission (UI)
- (b) forum: reached home/nav/paintbot/forum; observatory and wiki present as links only; NOT reached: docs.softmax.com, sign-in, CLI, standings, replay viewer, score-bug strip, endcard
- (c) search→root: reached home/nav/paintbot/watch/observatory league page/docs.softmax.com/sign-in(wall visible, untested)/standings(preview); NOT reached directly from root: wiki, forum (both absent from root nav, only appear once inside /paintbot)
- (d) docs cold: reached home(softmax.com link)/nav/observatory league page/CLI(as content); NOT reached: /paintbot, watch, wiki, sign-in, standings, replay viewer, score-bug strip, endcard, forum
- (e) GitHub: reached docs.softmax.com, CLI(as content), submission(as linked doc), home(via softmax.com/play.md, not the marketing homepage); NOT reached: /paintbot, watch, wiki, sign-in, standings, replay viewer, score-bug strip, endcard, forum, observatory league page

## Search truth

`paintbot` — top 5: Paintbot - Instructables (wall-painting robot) · PaintBot IEEE (wall-painting robot) · Paintbot - Shipping Wiki Fandom (fan-fiction ship) · [1904.02201] PaintBot RL painting-agent paper (arXiv) · Paintbot painting cnc (OpenBuilds). None are Softmax. Beginner's likely first click: none obviously right — most would refine the query.

`softmax paintbot` — top 5: PaintBot RL paper (ResearchGate) · Softmax — Team (softmax.com/team) · Softmax — Writing (softmax.com/blog) · Softmax - Scaling alignment (softmax.com/) · GitHub - UniKlo/PaintBot (unrelated). Beginner's likely first click: "Softmax - Scaling alignment" (root) — walked as S7.

`softmax coworld` — top 5: coworld · PyPI · Softmax · GitHub (org page) · Softmax - Scaling alignment (root) · Softmax — Team · Partiful event page. Real repo (Metta-AI/coworld) appears lower in the full list, not top 5.

`paintbot ai league` — top 5: "We asked this AI art bot to recreate League of Legends champions" (unrelated) · Softmax - Scaling alignment (root) · Paintbot - De Blob Wiki Fandom (unrelated video-game character) · Paintbot - Shipping Wiki Fandom (unrelated) · RoboCup Standard Platform League (unrelated). Only 1 of 5 relevant.

`softmax.com` — top 5 (of the visible set): all about the ML softmax activation function (Medium ×2, PyTorch docs, SingleStore blog, Wikipedia). "Softmax - Scaling alignment" appears only at the bottom of the returned list, not in the top 5.

`paintbot softmax github` — top 5: softmax1 · GitHub (unrelated user) · GitHub - 89netraM/paintbot-1 (unrelated Bomberman clone) · softmax · GitHub Topics · GitHub - jv4779/paintbot (unrelated) · GitHub - cygni/paintbot (unrelated). Real repo absent from the full 9 shown.

`coworld github softmax` — top 5: GitHub - Metta-AI/coworld-cogs-vs-clips · coworld · PyPI · Softmax · GitHub (org) · GitHub - qiwang067/CoWorld (unrelated academic repo, name collision) · Softmax - Scaling alignment (root). Real target repo (Metta-AI/coworld) appears further down the 7-result list — walked as S11.
