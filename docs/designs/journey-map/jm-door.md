<!-- Source: ~/.ctf/knowledge/stranger-walk/journey-map/jm-door.md, copied verbatim 2026-09-09 (shot paths repointed to ./shots/) -->

Era: 2026-09-09 · live ladder paintbot-v0.7.374 (GV61/Glory16) · coworld-ctf main 070d4805 · walker jm-door, entry https://softmax.com/paintbot

# Journey map — THE DOOR → THE BUILDER HALLWAY

### S1 — Door page — https://softmax.com/paintbot
- Reached from: entry URL, typed directly; clicks: 0. Server redirected to `?e=<uuid>` (a session/episode-tracking param), no visible redirect UI.
- What it says: "Paintbot: paintball-flavored team tag." — a live stage (embedded round/episode viewer), a leaderboard, and a short paragraph explaining teams, no-respawn battle royale, and a scoring line ("Every act mints Glory as it happens").
- Beginner question answered: WHAT IS THIS + WHY WOULD I CARE — the paragraph and live leaderboard give both in one screen.
- Where the thread breaks: jargon — "Glory", "coworld" is never used here but "Full rules live in the wiki" is the only "how it works" pointer.
- Hand-off: nav bar (Join the League, Observatory, Human Play, Forum, Wiki) plus a "COMPETE → Submit a policy" button.
- Owning lane: James (home/nav) for the shell, observatory epic for the stage/leaderboard widgets.
- Shot: jm-door-01-door.jpg

### S2 — /browse — https://softmax.com/browse (clicked the top-left logo)
- Reached from: S1 logo link (not "Paintbot" text — the logo goes to Browse, not home); clicks: 1.
- What it says: "AI agents compete at real games, live. Watch them." — a catalog of 137 games/coworlds with live counters (episodes today, uploaded policies).
- Beginner question answered: WHY WOULD I CARE — shows Paintbot is one of many live games, "GAME OF THE WEEK".
- Where the thread breaks: page never reached network-idle (long-poll live counters) — playwright timed out waiting; page was still usable, just never "settles".
- Hand-off: back to Paintbot card, or any of 136 other games.
- Owning lane: observatory epic.
- Shot: none (page never idled cleanly; text captured mid-load).

### S3 — Join the League / Observatory (nav) → sign-in wall — /sign-in?redirect_url=...
- Reached from: S1 nav "Join the League" and, separately, "Observatory"; clicks: 1 each. Both redirect to the same `/sign-in` page.
- What it says: "Sign in with GitHub to access the Softmax Dashboard." One button: "SIGN IN WITH GITHUB". No email/password, no other IdP.
- Beginner question answered: none directly, but this page's footer is the ONLY place on the whole click path that lists Docs / Create a coworld / The SDK / Tutorial / Reference / Observatory — none of the door, wiki, or forum pages link to docs.softmax.com directly.
- Where the thread breaks: needs sign-in — a beginner clicking the two most obvious nav items ("Join the League", "Observatory") is walled immediately, with no guest/read-only view.
- Hand-off: the wall's own footer, to docs.softmax.com (see S9) or back to Browse.
- Owning lane: James (home/nav) for the wall; docs.softmax.com owns the footer links.
- Shot: jm-door-02-signin.png

### S4 — Human Play — https://softmax.com/paintbot/play
- Reached from: S1 nav "Human Play"; clicks: 1.
- What it says: no text banner — a canvas scene, "Bot Locker Room", "Filling hoppers with fresh paint…", a "LOADING REPLAY" bar, a "PLAY" button.
- Beginner question answered: WHY WOULD I CARE — visually appealing, clearly a real playable game with a human seat.
- Where the thread breaks: no next step visible within our wait budget — the loading bar never resolved to a playable/spectate state before we moved on (canvas app, not text-driven).
- Hand-off: "PLAY" button (not clicked — out of scope for this walk) or "LOBBIES".
- Owning lane: paintbot engine/viewer.
- Shot: jm-door-05-human-play.jpg

### S5 — Forum — https://softmax.com/paintbot/forum
- Reached from: S1 nav "Forum"; clicks: 1.
- What it says: top post opens "The ceiling I fitted in-sample last wake fired on a seat it never saw..." — real community discussion of scoring internals.
- Beginner question answered: none for a true beginner — HOW AM I DOING for an insider.
- Where the thread breaks: jargon wall — "clamp", "ceiling", "in-sample", "seat", "150x", "wake" all used with zero definition; a beginner cannot parse a single post.
- Hand-off: none obvious; a beginner would leave.
- Owning lane: forum (metta).
- Shot: jm-door-06-forum.jpg

### S6 — Wiki main — https://softmax.com/paintbot/wiki/main
- Reached from: S1 nav "Wiki"; clicks: 1.
- What it says: "Paintbot is a top-down team paintball game played by AI policies rather than by hand: you submit a policy — a linux/amd64 Docker image — that drives a Cog..."
- Beginner question answered: HOW IT WORKS — the clearest single explanation on the whole site of what a "policy" is.
- Where the thread breaks: page header says "Verified against GV24 / Glory 12" — three versions behind the door's live GV61/Glory16; a beginner has no way to know if the rules below are current.
- Hand-off: a 40-page sidebar index; "Build and submit" and "Submitting a policy" are the two build-relevant pages.
- Owning lane: wiki.
- Shot: jm-door-03-wiki.jpg

### S7 — Wiki: Build and submit — /paintbot/wiki/build-and-submit
- Reached from: S6 sidebar; clicks: 2.
- What it says: "Getting a policy from nothing to a real league entry is five steps..." — a literal, command-by-command walkthrough (uv init/add, download, run-episode, package, upload, submit), edited 6h ago, explicitly calls out two "undocumented traps".
- Beginner question answered: COULD I BUILD ONE — the single most actionable page found anywhere on the site.
- Where the thread breaks: docs≠CLI — see CLI surfaces below; several of its own claims needed correction against the real CLI (Python version, replay-viewer pointer).
- Hand-off: names submitting-a-policy, baseline-policy, action-mask as prerequisite reading.
- Owning lane: wiki.
- Shot: jm-door-04-build-submit.jpg

### S8 — Wiki: Submitting a policy — /paintbot/wiki/submitting-a-policy
- Reached from: S7 "See also"; clicks: 3.
- What it says: "Verified against GV24 / Glory 12" (edited 5 days ago) — states the platform's own submission path "has not been exercised or verified here."
- Beginner question answered: HOW IT WORKS (wire protocol, Docker packaging) — but stops short of submission.
- Where the thread breaks: docs≠another doc — this page's "Gaps" section says submission is unverified; S7 (newer) claims to have verified exactly that step. Same wiki, two pages disagree.
- Hand-off: none for the submission gap; defers to S7.
- Owning lane: wiki.
- Shot: none.

### S9 — docs.softmax.com (home) — https://docs.softmax.com/
- Reached from: S3's sign-in-wall footer ("Docs"); clicks: 2 (via the wall, not from wiki/forum, which never link here).
- What it says: "Build and evaluate agents in Coworlds" — generic cross-game platform docs (Guides / API Reference), not Paintbot-specific.
- Beginner question answered: HOW IT WORKS at the platform level (Coworld = game package, policy = player).
- Where the thread breaks: reachable only by first hitting a sign-in wall a beginner was told not to need for browsing; no direct link exists on softmax.com/paintbot, /wiki, or /forum.
- Hand-off: "Build your first player" quickstart.
- Owning lane: docs.softmax.com.
- Shot: jm-door-07-docs-home.png

### S10 — docs quickstart — https://docs.softmax.com/guides/quickstart
- Reached from: S9 "Build your first player"; clicks: 3.
- What it says: "Before you begin, you need: a coding agent that can edit files and run shell commands; Docker running locally; uv; a Softmax account." Then: "Give your coding agent this prompt: Let's follow https://softmax.com/play.md"
- Beginner question answered: COULD I BUILD ONE — answered, but not for a human alone.
- Where the thread breaks: contradicts another surface — the entire "quickstart" assumes the reader IS or HAS an AI coding agent; our persona (a human typing commands) is not who this page addresses. This is the single largest thread break of the walk.
- Hand-off: hands off to an AI agent via softmax.com/play.md, not to the human.
- Owning lane: docs.softmax.com.
- Shot: jm-door-08-docs-quickstart.png

### S11 — docs SDK + Author-a-Coworld overviews — /coworld/overview, /coworld/build-a-coworld/overview
- Reached from: S9 sidebar; clicks: 3–4.
- What it says: "A Coworld packages a game for local development and hosted competition" / "This track is for people defining that environment [a whole new game]. If you are improving a policy for an existing game, start with the player guides instead."
- Beginner question answered: HOW IT WORKS (generic Coworld concept) — but the "Author a Coworld" track is the wrong track for someone who just wants to play Paintbot.
- Where the thread breaks: vocabulary mismatch — docs say "player", wiki says "policy", for the same artifact; easy to read as two different things.
- Hand-off: "Build a player" guide (not separately walked — content duplicates S7/S12).
- Owning lane: docs.softmax.com.
- Shot: none.

### S12 — CLI: `uv init && uv add coworld` — fresh HOME, per the wiki's literal step 1
- Reached from: S7's exact command line; clicks: 0 (typed).
```
$ uv add coworld
× No solution found ... all versions of coworld depend on Python>=3.11,<3.13
```
- Beginner question answered: none — this is the first dead stop.
- Where the thread breaks: docs≠CLI — `uv init` defaults `requires-python` to the local system interpreter (3.9.6 here); the wiki never mentions pinning Python. Fixed only by editing `pyproject.toml` to `>=3.11,<3.13` (the CLI's own hint, not the wiki's).
- Hand-off: none documented; a beginner would search or give up.
- Owning lane: coworld CLI.
- Shot: fenced block above.

### S13 — CLI: `coworld --help`
- Reached from: not prompted by any doc — we ran it ourselves after the fix above; clicks: 0 (typed).
```
$ uv run coworld --help
Usage: coworld [OPTIONS] COMMAND [ARGS]...
```
- Beginner question answered: COULD I BUILD ONE — reveals ~35 subcommands, only ~7 of which any doc we found ever mentions (download, run-episode, replay, upload-policy, submit, leagues, xp-request).
- Where the thread breaks: no next step in the docs pointed here; the banner itself says "New agent? Start at https://softmax.com/llms.txt ... https://softmax.com/play.md" — addressed to an agent, confirming S10.
- Hand-off: llms.txt / play.md (see S18).
- Owning lane: coworld CLI.
- Shot: fenced block above.

### S14 — CLI: `coworld download` + `coworld leagues`
- Reached from: S7 step 1 command line; clicks: 0 (typed).
```
$ uv run coworld download cow_3aa0f59a-...
Downloaded Coworld: paintbot:0.7.367
```
- Beginner question answered: HOW IT WORKS — writes a manifest, pulls two images, drops an AGENTS.md.
- Where the thread breaks: version — `coworld leagues` confirms `league_b8fa9b35…` = Paintbot (Season 2), matching S1's live league; but the downloaded package's own AGENTS.md states "No public league runs this Coworld version" — 0.7.367 vs the door's live 0.7.374.
- Hand-off: AGENTS.md's own next step, `run-episode`.
- Owning lane: coworld CLI.
- Shot: fenced block above.

### S15 — CLI: `run-episode --variant battle-royale-s2`
- Reached from: S7 step 2 exact command; clicks: 0 (typed).
```
$ uv run coworld run-episode ... --variant battle-royale-s2 --timeout-seconds 400 -o runs/smoke2
Scores: 0=147456, 1=48, 2=4, ...
```
- Beginner question answered: HOW AM I DOING (for the bundled baseline players) + WHAT HAPPENED — results.json has scores/win/kills/deaths/achievements exactly as the wiki claims; config.json confirms mapPath=brpool16, hitPoints=4 (the real ladder ruleset).
- Where the thread breaks: none here — this step matched the docs exactly.
- Hand-off: `coworld replay` (S17).
- Owning lane: coworld CLI / paintbot engine.
- Shot: fenced block above.

### S16 — CLI: `run-episode` with `--variant` omitted (the wiki's "trap #1")
- Reached from: curiosity, to verify the wiki's own warning; clicks: 0 (typed).
```
$ uv run coworld run-episode ... -o runs/cert_default   # no --variant
Scores: 0=213, 1=237, 0=213, ...  (alternating)
```
- Beginner question answered: WHAT HAPPENED — confirmed: config.json shows mapPath=arena, hitPoints=1 (not brpool16/4) — a silent, un-erroring switch to "the certification fixture", exactly as warned.
- Where the thread breaks: no warning or error at run time — only `--help` text ("Defaults to the certification fixture") hints at this; a beginner who never reads `--help` would believe they tested the ladder game.
- Hand-off: none — this is a trap, not a hallway.
- Owning lane: coworld CLI.
- Shot: fenced block above.

### S17 — CLI: `coworld replay`
- Reached from: S7 step 2's documented replay command; clicks: 0 (typed).
```
$ uv run coworld replay ./coworld_manifest.json runs/smoke2/replay
Replay client: http://127.0.0.1:52446/client/replay
```
- Beginner question answered: WHAT HAPPENED — a real local web viewer with play/pause, 1x–16x speed, a scrubber, and a "GLORY" panel.
- Where the thread breaks: `run-episode`'s own success message instead points to "STATIC_REPLAY_VIEWERS.md" for inspecting a replay — that file (bundled in the CLI package) is an implementation spec for building a viewer, not instructions for using one; the wiki's `coworld replay` command is the real answer and the CLI's own hint is wrong. Also: the viewer was still on its "Bot Locker Room · Loading Replay" screen when captured — full render not confirmed within our wait budget.
- Hand-off: none further within the walk (this is the last player-facing artifact before sign-in).
- Owning lane: coworld CLI / paintbot engine/viewer.
- Shot: jm-door-09-replay-viewer.jpg

### S18 — softmax.com/llms.txt + softmax.com/play.md
- Reached from: S13's own banner text; clicks: 0 (typed as a URL, not clicked — a beginner following the CLI's own hint literally).
- What it says (play.md): "You are a coding agent helping a human build, optionally smoke-test, upload, request hosted experience for, and improve a Coworld player..."
- Beginner question answered: none for our persona — this text is not addressed to them at all.
- Where the thread breaks: contradicts the persona itself — every top-level "what next" pointer we found (CLI banner, docs quickstart, this file, AGENTS.md inside the download) is written in second person to an AI agent, never to a human typing commands. UNREACHABLE-BY-NAVIGATION for a human: nothing on softmax.com/paintbot, the wiki, or docs.softmax.com's rendered pages links here; it only surfaced because the CLI printed the URL as plain text.
- Hand-off: "make repeated Experience Requests the main optimization loop... Submit to a league only if the human asks."
- Owning lane: docs.softmax.com / coworld CLI.
- Shot: none (plain text, quoted above).

### S19 — CLI: `softmax --help` / `softmax login --help`
- Reached from: S7 step 4 ("Authenticate and upload"); clicks: 0 (typed, help only — never executed login).
```
$ uv run softmax login --help
Usage: softmax login [OPTIONS]
--no-browser / --force / --server / --help   (no token flag)
```
- Beginner question answered: none new — checks S7's claim.
- Where the thread breaks: the wiki says "there is no token or API-key alternative... (softmax login --help exposes no such flag)" — true for `login` itself, but `softmax --help` lists sibling commands `get-login-url`, `get-token`, `set-token`, `exchange-code` that ARE a token-based alternative path, just not flags on `login`. The wiki's claim is misleading, not false.
- Hand-off: STOP — this is the documented sign-in step; per hard rules we did not run `softmax login`, `coworld upload-policy`, or `coworld submit`.
- Owning lane: coworld CLI.
- Shot: fenced block above.

## Threads

B1: S3 (Join the League / Observatory nav) → walled by sign-in with no guest view → beginner's likely next action: leave, or dig for a public alternative.
B2: S1/S6/S5 (door, wiki, forum) never link to docs.softmax.com → only found via S3's sign-in-wall footer → search or give up.
B3: S7 vs S8 (two wiki pages) disagree on whether the platform submission step has been verified → guess which is current (newer page wins, but nothing marks S8 stale).
B4: S12 — `uv init && uv add coworld` fails immediately (Python version) with zero doc warning → search error text or ask.
B5: S10/S13/S18/AGENTS.md — the entire builder path is written for an AI coding agent, never for a human → a solo human beginner has no human-voiced tutorial at all.
B6: S16 — omitting `--variant` silently swaps the ruleset with no error → a beginner believes they tested the real game and didn't.
B7: S14 — the downloaded coworld version (0.7.367) is explicitly flagged by its own AGENTS.md as run by no public league (live is 0.7.374) → local testing may not reflect the real ladder at all.
B8: S17 — `run-episode`'s own hint ("see STATIC_REPLAY_VIEWERS.md") points to the wrong document for actually viewing a replay.
B9: S19 — wiki claim "no token alternative" is misleading; sibling CLI commands provide one.

## Hallways not reached
- home (https://softmax.com/): not linked from the door's own nav (logo goes to /browse); reached only via the sign-in wall's footer.
- observatory league page / standings (full): walled by sign-in; door page shows a partial top-12 leaderboard only.
- submission: not reached — stopped before `coworld submit`/`upload-policy` per hard rule; platform push also sits behind the sign-in wall.
- score-bug strip / endcard: not confirmed as distinct surfaces; no round was observed concluding on the embedded stage during the walk.
- Reached: nav, /paintbot, watch (embedded stage on the door), wiki, docs.softmax.com (indirectly), sign-in, CLI, replay viewer (local, still loading when captured), forum.

## The builder's first hour
After literally following the wiki (repairing two things the docs never mention — pinning Python to 3.11, and reading `--variant`'s own `--help` text) a beginner has: a downloaded Coworld package with two bundled baseline-policy images, one completed local episode against the real battle-royale-s2 ruleset with a results.json (scores/kills/deaths/achievements) and a scrubbable local replay viewer, and — if they'd skipped a flag — a second, identical-looking but silently wrong episode. They do NOT have: their own policy running (nothing here builds or edits a policy, only replays the bundled baseline), any confirmation their local build matches the live ladder (it doesn't), or a human-voiced "what next" — every next-step pointer we found hands off to an AI coding agent, not to them.
