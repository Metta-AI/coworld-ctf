<!-- Source: ~/.ctf/knowledge/stranger-walk/journey-map/jm-home.md, copied verbatim 2026-09-09 (shot paths repointed to ./shots/) -->

Era: 2026-09-09; live ladder paintbot-v0.7.374 (GameVersion 61 / GLORYVERSION 16); coworld-ctf main ≈ 070d4805. Walker: jm-home (entry HOME, https://softmax.com).

## Entry-URL truth
A beginner told "go look at softmax.com" who already knows the word "Paintbot" would most naturally guess `softmax.com/paintbot`. That guess **works**: it 200s and serves the real public game page (S3 below) — no dead end here. The bare `softmax.com/observatory` guess (for "where do I see standings") does **not** work for an anonymous visitor — see S4.

### S1 — Home page — https://softmax.com
- Reached from: typed URL (entry point); clicks from entry: 0
- What it says: "A universe of multiplayer games where humans and their coding agents compete, cooperate, and interact." — headline over a `softmax.com/play.md` code snippet and a 4-step diagram (Pair with your coding agent → Code players who compete → Learn from every game → Climb ranks and level up your agent), then "Why Softmax", then a "Feature leagues" list of 6 games (Paintbot, Hanabi, Muster, Paintarena, Sugarscape Solo, Cogs vs Clips) each with an autoplaying preview.
- Beginner question answered: WHY WOULD I CARE — "Most AI training environments offer single-player-only, static challenges... Softmax is not building a cram school where agents grind alone, we are building a summer camp where agents learn together." Assumes the reader already codes agents; a non-technical visitor gets no answer.
- Where the thread breaks: none on this surface itself, but the leaderboard panel in the 4-step diagram ("Crewrift", "Rose&Astra 94.2 +3"...) is illustrative mock data, not real Paintbot standings — a beginner has no way to tell it's fake.
- Hand-off: nav (Leagues / Products / About) or the Paintbot feature card.
- Owning lane: James (home/nav).
- Shot: ./shots/jm-home-01.jpg

### S2 — Nav dropdowns — https://softmax.com (Leagues / Products / About)
- Reached from: S1, hover/click each top-nav item; clicks from entry: 1
- What it says: "Leagues" → the 6 games list (identical to the home-page feature cards, plus "All 137 games"); "Products" → Docs, Create a coworld, The SDK, Tutorial, Reference (all docs.softmax.com), and Observatory; "About" → Team, Jobs, Mission, Writing, Media, Events, Community, Contact.
- Beginner question answered: HOW IT WORKS (partial) — Products dropdown promises a build path (Create a coworld / SDK / Tutorial) without requiring a click yet.
- Where the thread breaks: jargon — "Observatory" appears with zero explanation of what it is before you click it; and there are two separate "Paintbot" entries in the Leagues list ("Paintbot (Season 2)" and plain "Paintbot") that both resolve to the same `/paintbot` URL — confusing duplication for a first-time scanner.
- Hand-off: any listed link.
- Owning lane: James (home/nav).
- Shot: ./shots/jm-home-02.jpg

### S3 — /paintbot page — https://softmax.com/paintbot
- Reached from: S1, clicking the "Paintbot (Season 2)" title text beside the feature card; clicks from entry: 1
- What it says: "Paintbot: paintball-flavored team tag." then "The players are AI policies... Season 2 plays battle royale: sixteen duos on a giant generated map, a closing zone, no respawns, last team standing. Policies talk before the round, shout during it, and alliances hold only as long as both sides keep them. Every act mints Glory as it happens - the league standing is a ledger of deeds, not a placement average. Full rules live in the wiki."
- Beginner question answered: HOW IT WORKS — the above paragraph, plus a live embedded "stage" (the site's *watch*, no separate "watch" page/nav-item exists), a "Competition Division" standings table (public, no sign-in), "League Leaders" award cards, and a "COMPETE — Submit a policy, it plays every round" CTA that answers COULD I BUILD ONE only at the level of "yes, submit something."
- Where the thread breaks: jargon (Glory, "ledger of deeds") stated but not defined inline — a beginner is told to go read the wiki for the definition; also the home-page feature-card thumbnail is itself an autoplaying, opacity-0 `<iframe>` that intercepts clicks — a real click on the thumbnail image (not the title text) silently does nothing about 1 time in 5 in this walk.
- Hand-off: nav row (Join the League / Observatory / Human Play / Forum / Wiki / Kiosk), or a Highlights entry to open a specific replay.
- Owning lane: paintbot engine/viewer.
- Shot: ./shots/jm-home-03.jpg

### S4 — Observatory sign-in wall — https://softmax.com/sign-in?redirect_url=...
- Reached from: S3, three separate ways, all tested: (a) the in-page "Observatory" nav link → `/sign-in?redirect_url=%2Fobservatory`; (b) "Join the League" → `/sign-in?redirect_url=%2Fobservatory%2Fv2%3Fdetail%3Dleague...`; (c) global nav Products ▸ Observatory (from S1/S2) → `/sign-in?redirect_url=%2Fobservatory%2Fv2`. Clicks from entry: 2.
- What it says: "Sign in with GitHub to access the Softmax Dashboard." — a bare GitHub OAuth button, no other content.
- Beginner question answered: none.
- Where the thread breaks: needs sign-in — **every** route into the Observatory app (bare `/observatory`, `/observatory/v2`, and the deep league-detail link) redirects an anonymous visitor straight to GitHub sign-in. There is no anonymous view of the "real" Observatory/league dashboard at all. (Not signed in; observed only, per instructions.)
- Hand-off: NONE for an anonymous beginner.
- Owning lane: observatory epic.
- Shot: ./shots/jm-home-04.jpg

### S5 — Standings (found on /paintbot, not Observatory) — https://softmax.com/paintbot
- Reached from: same page as S3 (right-hand "Competition Division" panel); clicks from entry: 1
- What it says: a ranked table — "1 soft-codexter-t2 383.5K Score LEADER... 2 macromackie 238.9K +144.5K behind..." plus "League Leaders" cards (Most Lethal, Untouchable, The Closer, Point Machine).
- Beginner question answered: HOW AM I DOING (for the field, not for "me" — there is no player identity yet) — evidence: the "GAP ... behind" column.
- Where the thread breaks: no next step — the standings **rows are not links** (confirmed: not in the page's clickable-element set); a beginner cannot click a name to see that team's replay. The only way to open a replay is the separate Highlights panel (S6) or the sign-in-gated "Open episode →" link.
- Hand-off: the Highlights panel, a few pixels to the left of the standings, not the standings itself.
- Owning lane: paintbot engine/viewer.
- Shot: none (same screenshot as S3).

### S6 — Replay opened from the Highlights panel — https://softmax.com/paintbot?e=&lt;episode-uuid&gt;
- Reached from: S3/S5, clicking a Highlights entry ("2nd won a field of 16 / paintbot.r4604.e2"); clicks from entry: 2
- What it says: the center "stage" swaps in-place (no navigation) to that episode and shows a HUD/score-bug strip: two team counters with team-color icons, a "6:44 TIME LEFT" countdown, and "+40 CLOSING TIME" (the shrinking-zone timer).
- Beginner question answered: WHAT HAPPENED (partial) — the score-bug shows raw numbers and a clock but never labels what the two counters mean (kills? players left? score?) — a beginner cannot tell who is winning or why from the strip alone; a "spoilers" toggle at the bottom, if turned on, prints the outcome directly (e.g. "PLUM WINS") ahead of the finish.
- Where the thread breaks: contradicts another surface — the same episode is labelled "ended 3m ago" in the Highlights list but "● LIVE ... started 8m ago" once opened, and it always replays from an early point at real-time (1x) speed, not from where it actually is; a beginner watching literally has to wait out the match in real time. A playback-speed control (up to 16×) and a frame scrubber exist, but scrubbing to a later frame did not stick — the stage auto-reverted to whatever episode is currently live and reset the position and speed, discarding the seek.
- Hand-off: NONE reliable — the endcard could not be reached this way (see Threads, B3).
- Owning lane: paintbot engine/viewer.
- Shot: ./shots/jm-home-05.jpg (score-bug strip); ./shots/jm-home-06.jpg (scrub/speed controls, zoomed)

## Threads
- B1: S2 (nav) → jargon ("Observatory" promised with no definition; two identical "Paintbot" entries) → beginner's likely next action: click anyway, guess.
- B2: S4 → needs sign-in on every Observatory route (in-page nav, "Join the League", and the global Products-menu link all gate identically) → beginner's likely next action: leave, or sign in with GitHub (not attempted here — hard rule).
- B3: S6 → endcard unreachable within this walk — real-time-only playback plus a scrub/speed control that does not persist a seek (stage snaps back to "live") → beginner's likely next action: leave before the match ends, or leave the tab open and wait.
- B4: S3 → the home-page feature-card thumbnail is an invisible, click-intercepting iframe (autoplaying preview) → beginner's likely next action: click again, or click the title text instead (works).
- B5: S5 → standings rows are inert (not links) even though they visually sit right next to a clickable Highlights list → beginner's likely next action: try clicking a name, nothing happens, give up on that path.

## Hallways not reached
- Observatory/league page (real dashboard): confirmed UNREACHABLE-BY-NAVIGATION for an anonymous visitor — hits sign-in on every tested route (S4).
- Sign-in page: reached and observed only, per hard rule — not signed in.
- docs.softmax.com, CLI, submission flow, Human Play, Forum, Wiki, Kiosk, Fullscreen mode: links/buttons for all of these were confirmed present (Products dropdown; /paintbot's own nav row) but not opened — the lead's stop-now check-in landed before this walker followed them, and "no new hallways" was the instruction at that point.
- Endcard: not reached — see B3. The score-bug strip (mid-match HUD) was captured; the actual end-of-match card was not observed live, and no reliable seek path to it was found within this session.

## First minute
- First screen (home, above the fold): "A universe of multiplayer games where humans and their coding agents compete, cooperate, and interact." — WHAT IS THIS: answered at a high level (a games platform for AI agents), aimed at people who already have a coding agent. WHY WOULD I CARE: not yet answered on this screen — that comes further down ("Why Softmax"). HOW IT WORKS: gestured at by the 4-step diagram icons but not explained in words yet.
- After the first click (into /paintbot): "Paintbot: paintball-flavored team tag." followed by the battle-royale rules paragraph — HOW IT WORKS is now answered concretely (sixteen duos, closing zone, no respawns, alliances). WHY WOULD I CARE is still unanswered for this specific game (no beginner-facing "why watch/play this one" line — only "Submit a policy — it plays every round," which assumes you already want to).

## What could not be verified
- Whether the standings table on /paintbot ever becomes clickable (e.g., behind a different viewport/breakpoint) — only tested at 1440×900.
- Whether the sign-in wall is uniform for literally every Observatory sub-route, or whether some read-only Observatory views exist that this walk didn't try.
- The literal endcard screen content (what an ended match's final overlay says) — not reached; see B3.
