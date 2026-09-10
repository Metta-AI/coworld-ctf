# THE WHOLE — the beginner's journey on softmax, designed as one thread

**Era:** 2026-09-09. Live ladder paintbot-v0.7.374 (GameVersion 61 / GLORYVERSION 16); GameVersion 62 / GLORYVERSION 17 staged in #504; `season_leg_transform` is `none` on the live league (Step A not armed); coworld-ctf main 8b7e78a7 (#504 merged: GameVersion 62 / GLORYVERSION 17 staged for publish; the live ladder still reports v0.7.374 until the upload-coworld run publishes). Evidence: `docs/designs/JOURNEY_MAP.md` (#510) — every `J<n>` below is a break in that map's register. Persona: a curious developer who has never heard of Paintbot.

**Status:** ACCEPTED BY DELEGATION on 2026-09-09 (epic 16d081ab): the owner's instruction is that nothing waits on him, so the lead has taken every decision in §6 and work has started; the owner may override any of them at any time. The clean before-walk runs first (§5). Owner rulings R7–R11 (internal tracking, not public) are treated as fixed; the only open choices are in §6.

**How to read this:** §1 is the thesis. §2 is the design: the journey as ten stops, each answering one beginner question and handing off to the next. §3 is the laws that make it one thread instead of ten fixes. §4 routes the work by lane. §5 is the order and the measurement. §6 is the short list of decisions that are yours. §7 is what this deliberately does not touch. Appendix A maps every break in the map to a stop.

---

## 1. The thesis

The north star is that outside people build on Paintbot, and that proves the Coworld thesis. The map says why they do not today, in one sentence: every surface answers one lane's question well, and the thread between surfaces is broken at nearly every hand-off. The first minute mostly works (WHAT IS THIS at zero clicks on the door and its twins). After that: the only web path to compete is a dead link (J9); the book's front page teaches a game that is three eras gone (J11); docs.softmax.com cannot be reached by clicking from the door tree and never says the word Paintbot (J7, J8); the builder path is written to a coding agent, not the human reading it (J16), and its literal first command fails on a fresh machine (J15); sign-in walls everything behind GitHub with no warning (J20, J21); after a submission, nothing on the site knows who you are (J23–J27), you cannot watch your own round end (J32), and a resubmit gives no signal at all (J35). No entry ever answers HOW AM I DOING about *me*.

The design is not a punchlist against those breaks. It is one change of frame: **the journey is a single object with a single owner (this epic), and every surface is a stop on it.** A stop must do four things: answer the question the beginner has at that moment, hand them to the next stop by a visible link, speak one vocabulary, and be stamped against the live ruleset. And the game must explain its own moments as they happen, so the book can be a book instead of a second HUD. The breaks close as a consequence of the frame; the crosswalk in Appendix A shows every one landing on a stop.

**The beginner's questions, in the order they arise** (R7, extended by the map's post-submit hallways):

| # | Question | Where it must be answered |
|---|---|---|
| Q1 | WHAT IS THIS | first screen, zero clicks |
| Q2 | WHY WOULD I CARE | first screen, zero clicks — make-or-break |
| Q3 | HOW DOES IT WORK (the loop) | first screen, zero clicks |
| Q4 | WHAT AM I WATCHING | the stage, as it happens |
| Q5 | COULD I BUILD ONE | one click from the door |
| Q6 | HOW DO I SUBMIT | the end of the build page |
| Q7 | HOW AM I DOING | the standings, knowing who I am |
| Q8 | WHAT HAPPENED (in my round) | my rounds, my replays, the endcard |
| Q9 | HOW DO I GET BETTER | a before/after read on a resubmit |
| Q10 | WHO DO I ASK | one pinned place |

Q1–Q3 are the first minute. Everything else waits for a click, but every click must exist.

---

## 2. The thread — ten stops

Each stop: the question · what is there today (map evidence) · the design · the hand-off · the lane and delivery form. Copy in quotes is proposed copy; copy marked **(R8)** is the owner's, verbatim.

### Stop 0 — Arrival: every door says the same three things

**Question:** Q1–Q3, wherever the beginner lands.
**Today:** seven doors, seven different first sentences. Home answers WHY at zero clicks but for readers who already own a coding agent; the door and the shared replay link answer WHAT; docs.softmax.com and the GitHub README never name Paintbot (J6, J7); the forum's first visible post is scoring research (J33); bare search does not find the site (J4, external); a bare `/forum` guess 404s with a message that never says forums exist (J5).
**Design:** one **door block**, three sentences, identical everywhere it appears: the WHAT line, the hook **(R8)**, the loop line (Stop 1 defines all three). Every door carries the block or a one-line pointer to the door:
- Home: the Paintbot card carries the WHAT line and the hook; the card's thumbnail is a real link (J2). James's page; we supply the copy.
- The door and the shared replay link (`/paintbot?e=`): the block is the first screen (Stop 1); the replay link is the door with an episode open, so it inherits everything.
- docs.softmax.com: a Paintbot page that carries the block and links the door and the build page (Stop 4). The quickstart names Paintbot as the worked example.
- GitHub README: names Paintbot (not only "Paint Arena") and links the door.
- Forum: a pinned "Start here" thread carrying the block and the stop links (owner-authored, §6 D5); the bare `/forum` 404 says where the forums are.
- Search: the door's `<title>` and meta description say Paintbot and the WHAT line, so the one query that reaches the site lands on the right page. (Search ranking itself is external and out of scope.)
- The CLI's own help banner (Stop 4) is a door too: it names the human page and the agent page.
**Hand-off:** every door → the door (Stop 1) or the build page (Stop 4).
**Lane:** James (home card copy) · docs.softmax.com · GitHub README · forum (owner pin) · the door's metadata (our metta PR).

### Stop 1 — The door's first minute (`softmax.com/paintbot`)

**Question:** Q1 → Q2 → Q3, in that order, zero clicks (R7).
**Today:** "Paintbot: paintball-flavored team tag… Every act mints Glory as it happens" — WHAT at zero clicks, WHY partial because Glory and "ledger of deeds" are never defined inline (J3); the hook is not live; the COMPETE call to action is a dead anchor to `/#production` (J9); metta #22190 adds the hook and a Watch-first call to action above the stage but does not touch the dead anchor, so landing it alone leaves the doorstep bug live.
**Design — the first screen, in the stranger's questions, not in boxes:**
1. **WHAT:** "Paintbot is a sixteen-seat paintball battle royale played by policies that people write."
2. **WHY:** "My brain fights other people's brains, and that produces a legible testbed for agent behavior." **(R8)** Then one sentence of consequence: "Put your own brain in the field and watch it fight the others; every move it makes is on the record." (§6 D6 if you want your own words here.)
3. **HOW (the loop, one line):** "Write a policy → it plays episodes against the field around the clock → every deed it pulls off mints Glory → your standing is a decaying average of your recent episodes → watch any episode to see why."
4. Then the stage, live, with the strip explaining itself (Stop 2). Watch first (§6 D1).
5. Exactly two actions above the fold: **Watch** (scrolls to the stage) and **Build** (Stop 4). The COMPETE control goes to the build page's Submit section (Stop 5), never to Observatory, never to a marketing anchor. "Join the League" is the same target.
6. Glory is defined inline the first time the word appears, in the glossary's one sentence (Law 1): "Glory is what one policy earns in one episode: every deed mints some, and the multipliers stack the more it does before the end."
7. The standings panel stays on the door (Stop 6) and the Highlights panel stays (Stop 7); both become links.
**Hand-off:** Watch → Stop 2 · Build → Stop 4 · standings row → Stop 6 · Highlights → Stop 7 · Wiki → Stop 3.
**Lane/delivery:** one metta PR by us, owner's click: #22190's hook/loop/Watch-first plus FRONT_DOOR.md's anchor fix plus the metadata, folded together (not two half-fixes). Nav structure stays James's.

### Stop 2 — Watch: the game explains itself

**Question:** Q4, as it happens; Q3 by demonstration.
**Today:** the strip's two counters are unlabeled (J30); GLORY, HUDDLE, FIT, HUNTING/TAGGING appear with no definition anywhere, and no `aria-label`/`title` exists on the pact ring, heat flame, multiplier figure, intent word or downed state (J30, #508); a season Score and an episode ×N sit side by side with nothing linking them (J31); pact grouping and the one-word intent landed in v0.7.374 (#498); no kickoff framing; the live stage's seek snaps back so no beginner ever sees an endcard (J32); the episode id in the URL is not stable (J28); the same episode reads "ended 3m ago" in Highlights and "LIVE" on the stage.
**Design — the mind lives in the strip, the field stays clean (R10, R11):**
- **Kickoff line**, first seconds of every episode: "16 seats drop in. Last one standing wins. The zone closes."
- **The strip as legend of itself.** First appearance per session, one short line each, and hover/tap text always: the pact ring ("these two share a pact: they won't fight each other"), the heat flame ("scoring fast; keeps climbing while it's hot"), the multiplier figure ("this number is the team's running multiplier; every pop stacks it"), the intent word ("what this cog is doing right now"), the downed state ("downed — can still be rescued"). The two counters get their nouns. Nothing new is drawn on the field.
- **Two numbers, two names.** "Glory this episode" and "Standing (season)" are never shown side by side without their names (J31).
- **Deed pops and the win rule** stay as they are (#508 moments 4, 8, 9 are already right).
- **The end is reachable.** The stage holds the endcard on screen for a fixed beat before the next episode; a "jump to the end" control exists; a seek on the live stage persists; Highlights and the stage agree on whether an episode is live or ended.
- **A stable permalink per episode** with a Share control, the same URL the standings rows and "your rounds" use (Stop 7).
- **The endcard:** v1 = the win rule (exists) + each seat's Glory with the deeds that built it, shown as the top rows plus your seat, never sixteen equal rows + each seat's standing before → after this episode (needs the platform data in Stop 6). v2 = the pact story. No "why the winner won in one line".
- **The same viewer locally.** `coworld replay` shows the identical strip and legend, so the builder learns the language once (Stop 4).
**Hand-off:** endcard → Standings (Stop 6) and "discuss this round" (Stop 8) · strip term → glossary line (Stop 3).
**Lane/delivery:** coworld-ctf replay client (bundle rebuild, one author at a time); the endcard's per-seat identity and a realized-economy stamp are one WIRE-OK batch (#508 items 9+10, one GameVersion bump, sequenced after #504's 62); the standing delta is the single platform ask in Stop 6.

### Stop 3 — Understand: the wiki is the book

**Question:** Q3 in depth; the reference for every term the game uses.
**Today:** `wiki/main` is stamped "Verified against GV24 / Glory 12" and frames classic CTF as the default while `build-and-submit` and `battle-royale-s2` are current (J11); `modes.md` contradicts its own changelog and the platform's `game.description` still says "sixteen duos" (J12); two pages disagree on whether submission was verified (J13); `ranks.md` says weaker than the truth (J14); the "no token alternative" claim is misleading (J20); standings labels have no glossary (J27).
**Design — the book follows the question ladder and cannot go silently stale:**
- **Front page = the ladder.** Eight chapters in the beginner's order: What is this · Why would I care (its own beat, carrying the hook) · How it works (the loop) · What happens in a round (`battle-royale-s2`) · How scoring works (Glory: deeds, multipliers, jackpots rare and earned; standing = a decaying average of recent episodes, never a max) · How to build (Stop 4's page is the canonical chapter) · How to submit (the GitHub requirement stated first) · How to read the ladder (the window, the labels, why #1 is #1). This is RESTRUCTURE-PLAN.md's eight chapters with WHY made explicit.
- **One era line, everywhere.** A single "live ruleset" record (variant, GameVersion, GLORYVERSION, standing rule, transform) is maintained in one place; every page's banner renders from it, so a page verified against an older era shows "verified against X — live is Y" automatically instead of claiming the wrong game. The 27 unaudited pages are either re-verified or wear that banner; `modes.md` is fixed; `game.description` is fixed on the platform.
- **One glossary, one source.** One line each for Glory, deed, multiplier, pact, heat, downed, standing, round, episode, division, champion (means currently competing, not winner) — the same lines the strip legend and the standings labels use (Law 1).
- **The book points at the product.** Chapters link to the in-product explanation (strip legend, endcard, why row) instead of restating it.
**Hand-off:** every chapter ends with the next chapter; "How to build" is Stop 4; "How to read the ladder" is Stop 6.
**Lane/delivery:** `docs/wiki` in coworld-ctf, published by PUBLISH.md's procedure (wiki publish needs the owner's go, per the standing authorizations); `game.description` via league settings (metta).

### Stop 4 — Build: the builder's hallway speaks to a human

**Question:** Q5, then Q6 at the end.
**Today:** every "what next" pointer on the path (CLI banner, docs quickstart, `play.md`, the package's AGENTS.md) is written in second person to an AI coding agent (J16); `uv init && uv add coworld` fails on a fresh machine because of an undocumented Python bound (J15); omitting `--variant` silently tests the certification fixture (J17); `coworld download` resolves to a version no public league runs (J18); the run's success message points at an implementation spec (J19); docs.softmax.com is reachable only through the sign-in wall's footer (J8); the template path's `--run` and `--platform` traps are documented in the wiki (BUILDER_DOOR Rank 1, #499) but the CLI itself is unchanged.
**Design — one page a human can follow to a local episode in one sitting, "Your first policy":**
1. Prerequisites, stated: Python 3.11 or 3.12 pinned in the project, Docker, uv. The starter's `pyproject` pins the bound so step one cannot fail the way it does today.
2. Get the starter: `coworld download` names the live ladder's version, or says in one line why it cannot and what that means.
3. Run one episode against the live ruleset **by default**: `--variant` defaults to the live ladder variant or the command refuses without it; there is no silent fixture.
4. Open the replay locally with the same viewer and legend as the stage (Stop 2); the success message names `coworld replay`.
5. Read your score: "this is Glory; these are the deeds that minted it" — the endcard, locally.
6. Change one thing: the starter exposes a few named knobs a beginner can turn (the retune sonnet-a actually made is the model).
7. Run again and compare: a local, seed-matched before/after of two runs, in the same words Stop 8 will use on the ladder.
8. Submit (Stop 5), with the GitHub requirement stated before the first command.
**Two audiences, one truth (Law 4):** the human page and the agent pages (`play.md`, `llms.txt`) are generated from the same source, and the CLI banner names both: "Building by hand? start at <the page>. Using a coding agent? point it at play.md."
**The wizard** (`coworld init paintbot`, BUILDER_DOOR Rank 2) is not in this design's critical path; it is §6 D2.
**Hand-off:** the page's last section is Stop 5; every error the CLI prints names the page section that fixes it.
**Lane/delivery:** starter and tooling in coworld-ctf (`policies/starters/`, `tools/`); CLI defaults and messages, docs.softmax.com Paintbot page, `play.md`/`llms.txt` mirror, README naming: metta PRs by us, owner's click.

### Stop 5 — Sign in and submit

**Question:** Q6.
**Today:** every Observatory route is a GitHub-only wall with no guest view (J21); the requirement is undisclosed until the attempt (no break number of its own: the map records the wall as J21 and the misleading no-token claim as J20; the disclosure fix is #508's item 7); the door's COMPETE control is dead (J9); the submission response is terse and its printed status page is stuck skeleton loaders (J23); `auto_champion=always` silently seats the policy in a second league (J36); the champion seat has no contention protection (J37, test artifact).
**Design:**
- **Disclosure before the attempt**, one line on the door's Build target and at the top of the submit chapter: "Submitting needs a GitHub account; sign-in is GitHub only."
- **The door's COMPETE and "Join the League" go to the submit section of Stop 4**, never to Observatory. No stop on the thread requires Observatory before or after sign-in (§6 D3).
- **The submission response says four things:** what was accepted (policy name, version), what happens next (queued for the next round, and how long a round typically takes, read from the league), where to look (a status URL that actually renders, or the CLI line that prints the same), and how to withdraw.
- **Default membership is the league you submitted to**; seating in a second league is opt-in and named in the response (J36).
- Sign-in itself is not redesigned here (Observatory is its own epic); the design only guarantees the beginner never needs it to reach any stop and always knows it is coming.
**Hand-off:** the response → your standings row (Stop 6) and your rounds (Stop 7).
**Lane/delivery:** CLI response text, membership default, status page: metta PRs by us; the disclosure lines: wiki (coworld-ctf) + door PR.

### Stop 6 — How am I doing: the standings know you

**Question:** Q7 — about *me*, which no entry answers today.
**Today:** field standings on the door with no identity; rows are not links (J26); search matches player names only (J24); a submission ages out of an unnamed window with no way back (J25); LEADER, "+N behind", MOST LETHAL and the rest have no definitions and no cause (J27); the standing model is nowhere stated, and a real stranger believed standing was a best-round max; Score and ×N sit unnamed together (J31).
**Design — the standings panel on the door, signed in:**
- **A "You" row**, pinned: your policy by its name and version, rank, standing, delta since your last round, and a link to your rounds (Stop 7).
- **Rows are links** to a player's rounds and their last replay; search matches policy or player; the window is named ("last N rounds") and older rounds are reachable.
- **Every label defined** on hover/tap from the glossary (Law 1); no bare numbers (Law 6).
- **The standing rule, in one line on the page, sourced live:** today "a decaying average of your recent episodes' Glory"; the typical-episode wording appears only when the transform is armed (Law 2 forbids hard-coding it).
- **WHY #1 IS #1 (R10):** the top row expands into what earned it — deeds first (the typical episode's Glory by deed, how many rounds it rests on, the gap to #2), the brain's style second (v2, after S3 risk bands) — and the same expander on **your** row: why you are where you are.
**The one platform ask.** The why row, the endcard's standing delta (Stop 2), and the iteration read (Stop 8) all need the same data: standing before and after each round per player, which the settlement path already has in hand (PLATFORM_LEGIBILITY_DATA.md Step 1, populate `recent_rounds`). This design asks for it once. Per-deed breakdown per round is a game-side WIRE-OK addition, batched with Stop 2's bump.
**Hand-off:** You row → your rounds (Stop 7) · any row → its replay (Stop 2) · the why row → "How to read the ladder" (Stop 3).
**Lane/delivery:** the standings panel lives in metta's door page (our PR, owner's click); the data is the platform ask (metta backend, our PR); the Observatory dashboard's own standings adopt the same row later (observatory epic, not on the thread's critical path).

### Stop 7 — What happened: my rounds and my replays

**Question:** Q8.
**Today:** no rounds list for a person; the episode id in the URL is not a permalink (J28); when two of fourteen episodes in a round fail for another seat's reason the beginner must diagnose it themselves to rule out their own policy (J29); the endcard is unreachable live (J32).
**Design:** "Your rounds": one line per round — your Glory that round, your rank in the round, standing before → after, and when an episode failed or a version was disqualified, the cause and whose it was (yours or the platform's) in plain words. Each line → the episode's permalink → the endcard with your seat marked. The stage's Highlights and the standings rows use the same permalinks.
**Hand-off:** endcard → discuss this round (Stop 8) · your rounds → compare versions (Stop 8).
**Lane/delivery:** metta (rounds list from the existing round API plus `recent_rounds`); permalink and endcard in the replay client (coworld-ctf).

### Stop 8 — Get better: iterate with a signal, and ask

**Question:** Q9, Q10.
**Today:** no comparison exists anywhere, and the one real resubmit observed returned a disqualification for a platform reason, so "did my change help" returned nothing (J35); the forum is insider scoring research with no on-ramp (J33); no channel a beginner could ask in was found (J34).
**Design:**
- **A "v2 vs v1" read** on your rounds page after a resubmit: each version's last N rounds, standing before → after, typical Glory by deed, and one plain verdict line in the glossary's words (for example "v2 mints more Glory from RESCUE and less from CLOSING TIME; standing up over N rounds"). No timing numbers. Disqualifications name their cause and whether it is yours.
- **The forum enters the thread with two links:** a pinned "Start here" thread (owner-authored, §6 D5) carrying the door block and the stop links, and a "discuss this round" link on every endcard and round line. A "help" line on the build page names the channels that actually exist; the design invents none.
**Hand-off:** back to Stop 4 (change one thing) and Stop 2 (watch it).
**Lane/delivery:** metta (rounds/uploads pages, forum links); forum pin is the owner's post.

### Stop 9 — Return: the loop closes

The beginner comes back to a stage that tells the story (Stop 2), a standings row that knows them (Stop 6), and a book that is current (Stop 3). The thread has an owner (this epic) and an instrument (§5). The loop line on the door was true.

---

## 3. The laws — what makes it one thread

1. **One vocabulary, one glossary.** Canonical Softmax names (Coworld, League, Division, Round, Episode, Player, Policy, PolicyVersion; Champion means currently competing) and tagging words in public text (tag, marker, spray). Glory, deed, multiplier, pact, heat, downed, standing each have one sentence, written once, rendered everywhere (door, strip legend, standings labels, wiki glossary, CLI messages).
2. **Era truth is sourced, never typed.** One live-ruleset record (variant, GameVersion, GLORYVERSION, standing rule, transform) feeds every banner, the standing line on the standings, and the CLI's version check. A surface older than the live era says so automatically. Copy never hard-codes a rule that a settings POST can change.
3. **Every stop hands off by a visible link.** No hallway is reachable only by a typed URL or a text banner: docs, the build page, `play.md`, the replay permalink, your rounds — each is a link from the previous stop. Nothing before Stop 5 needs an account.
4. **Two audiences, one truth.** Human pages and agent pages (`play.md`, `llms.txt`, AGENTS.md) are generated from the same source and the CLI names both. A human is never handed an instruction addressed to an agent.
5. **The game explains the moment; the book explains the depth.** Kickoff, pops, the strip, the endcard carry their own one-line explanations; the wiki links to them and does not restate the HUD. Neither duplicates the other.
6. **No bare numbers.** Every score, rank, multiplier and delta appears with its name and context (this episode vs season; rank of how many; delta since when).
7. **Once you are known, every stop knows you.** After sign-in the door's standings, the rounds list, the endcard and the comparison all resolve "you" without a search.
8. **Measure the thread, not the pieces.** The Stranger Walk v2 (owner's sentence only, post-hoc judge, container isolation) is the instrument; its outputs are milestones reached, stalls and their causes, and wrong beliefs held. No speed number is ever a headline for this epic.

---

## 4. The work, by lane

| Lane | Stops | Breaks closed | Delivery form |
|---|---|---|---|
| Ours — coworld-ctf replay client / wire | 2, 7 | J28, J30, J31, J32 (client half), J2 (thumbnail is an iframe of our client) | PRs to main; bundle rebuild, one author; one WIRE-OK GameVersion bump (economy stamp + per-seat identity on `over`), sequenced after #504 |
| Ours — coworld-ctf wiki | 3, 5 (disclosure), 6 (glossary) | J3, J11, J12 (wiki half), J13, J14, J20, J27 (labels) | PRs to main; publish via PUBLISH.md on the owner's go |
| Ours — coworld-ctf starters/tools | 4 | J15 (pin), J17 (variant default in the starter's run script) | PRs to main |
| Ours by metta PR (owner's click) — the door page | 0, 1, 5, 6 | J3, J9, J21 (the thread no longer needs Observatory), J24, J25, J26, J27, J31 | one door PR (hook + loop + anchor + metadata), one standings-panel PR (You row, links, search, window, labels, standing line, why row v1) |
| Ours by metta PR — CLI, docs, agent pages | 0, 4, 5 | J7, J8, J15, J16, J17, J18, J19, J23, J36 | CLI defaults/messages, docs Paintbot page, `play.md`/`llms.txt` mirror, submission response, status page, membership default |
| Ours by metta PR — platform data | 2, 6, 7, 8 | J32 (data half), J35, J29 (cause in plain words) | PLATFORM_LEGIBILITY_DATA.md Step 1: populate `recent_rounds` with standing before/after; the rounds list; the v2-vs-v1 read |
| James — home and nav | 0 | J1 | copy supplied (card WHAT line + hook; nav labels explained on hover); no nav merge by us |
| Observatory epic | — | J22 (unmeasured) | nothing on the thread's critical path; the You row and why row are handed over as the standings spec once they exist on the door |
| Owner | 0, 8 | J5 (pin), J33, J34 | the pinned "Start here" forum thread; wiki publish go; metta clicks |
| External / unowned | — | J4, J6 (README naming is ours; ranking is not) | door title/meta only |
| Glory lane | 6 (v2 style layer) | — | S3 risk bands feed the why row's second layer; the standing line's wording follows Step A/B when they arm |

---

## 5. Order and measurement

**Phase 0 — accept, instrument, baseline.** Accept this design (§6 answered). Instrument: the walk container gains a browser (v1.4: a stranger who cannot see the stage cannot judge half of this design) and an isolated Docker daemon per run (v1.5), so the browser tool the stranger actually invokes and the documented docker build path both work inside the container; a run on an instrument lacking either is VOID as a baseline; the run credential is resolved by the walk instrument without the owner (an existing key if one is present on the machine, else the host's Claude Code login copied into the run's fresh HOME inside the container, with the isolation audit extended to prove the credential never appears in any transcript or artifact). **Walk v2 BEFORE:** three runs (two Sonnet, one Opus), the owner's sentence only, `ENTRY_URL = https://softmax.com` (§6 D7), container isolation, judge post-hoc; the live era stamped on the run (build tag and league settings), so the before is frozen even as the ladder moves.

**Phase 1 — the first minute and the stage** (Stops 0–2): the one door PR; the strip legend, kickoff line, endcard hold and jump-to-end, persisting seek, permalink and share, the local viewer parity; the WIRE-OK batch after #504 lands.

**Phase 2 — the book** (Stop 3): the ladder front page, the live-ruleset record and era banners, the glossary, `modes.md` and `game.description`; publish on the owner's go.

**Phase 3 — the builder's hallway** (Stop 4): "Your first policy", the starter's pin and knobs and local compare, CLI defaults and messages, the docs Paintbot page, `play.md`/`llms.txt` from one source, the README naming.

**Phase 4 — submit and you** (Stops 5–6): disclosure, the COMPETE path, the submission response and status page, membership default; the You row, links, search, window, labels, standing line; platform Step 1; the why row v1.

**Phase 5 — what happened and get better** (Stops 7–8): your rounds, causes in plain words, the endcard's standing delta, the v2-vs-v1 read, the forum pin and discuss links.

**Walk 2 AFTER:** the same three runs, same sentence, same entry, same models, same judge version; compared on milestones reached post-hoc, stalls and their causes, wrong beliefs, and the question-ladder matrix re-walked (no NEVER cell for the door or the replay link; Q7 answered about *me* within a handful of clicks after submit). Era-stamped both sides.

Every phase lands as PRs to main (coworld-ctf) or metta PRs blessed by the owner; CI green and evidence before every merge; never stacked; a GameVersion bump re-records every fixture; one bundle author at a time.

---

## 6. The decisions — taken by the lead, open to override

Recommendation first in each.

- **DECIDED: D1 — Watch first.** The door's primary action is Watch (the stage, with the hook above it); Build is the second action. Alternative: Build first, stage below. I recommend Watch first: a beginner has to see minds fighting before caring to build one, and the map shows the stage is the surface that already answers the most.
- **DECIDED: D2 — The builder's door: Rank 1 now, the wizard later.** Rank 1 is the human page plus fixed defaults (Stop 4). Alternative: also build `coworld init paintbot` (Rank 2) in this epic. I recommend deciding Rank 2 after Walk 2 shows which stalls survive the page; no reference platform in the research has a wizard, so it is a bet, not a precedent.
- **DECIDED: D3 — The beginner never needs Observatory.** The You row, your rounds and the comparison live on the door and its pages; Observatory stays your dashboard after sign-in and is its own epic. Alternative: ask the observatory epic for an anonymous league view and put "you" there. I recommend the door: it keeps the thread on pages we ship, and the observatory epic can adopt the same rows later.
- **DECIDED: D4 — The why row's second layer waits for the Glory lane's risk bands.** v1 is deeds first, as you chose. Alternative: ship a rough "style" from the deed mix now. I recommend waiting: a wrong style label is a new wrong belief.
- **DECIDED: D5 — The forum enters the thread with a pinned "Start here" you post.** Alternative: keep the forum off the beginner's thread until it has beginner content. I recommend the pin now and the per-round discuss links in Phase 5; the pin is one post and it is the only thing on the thread I cannot write for you. Because nothing waits on the owner, the Start-here post is drafted in the repo at docs/forum/START_HERE.md as a paste-ready text, and the thread does not block on it being posted.
- **DECIDED: D6 — Taste: the sentence after the hook.** Mine: "Put your own brain in the field and watch it fight the others; every move it makes is on the record." Replace it with yours if you have one; the hook itself is not up for edit.
- **DECIDED: D7 — The Walks start at `softmax.com`.** Alternative: start at `/paintbot`. I recommend home for all six runs: it is the honest cold start that still lands on the site, and it exercises James's card and nav, which the after-walk should be allowed to fail on.

Everything else in §2–§5 is a design decision I am making; say so if any of it is wrong.

---

## 7. What this deliberately does not touch

- **Human play / "take a seat"** (R7): out of scope; `paintbot-entry-design.md` stays parked; `/paintbot/play`'s status (J10) is recorded, not designed.
- **Campaign:** David's side mode, not first-class here.
- **Nav and home structure:** James's; we supply copy and hand over specs.
- **The hook wording** (R8) and the first-minute order (R7): fixed.
- **Observatory's sign-in architecture:** its own epic; the thread routes around it (D3).
- **Scoring constants and the season rule:** the Glory lane's; this design only sources their live values (Law 2).
- **Search ranking:** external.

---

## Appendix A — every break in the map, placed on the thread

| Break | Stop | Law | Lane | Phase |
|---|---|---|---|---|
| J1 nav labels unexplained | 0 | 3 | James (copy) | 1 |
| J2 home thumbnail iframe swallows clicks | 0 | 3 | James / our client | 1 |
| J3 Glory undefined on the door | 1 | 1 | door PR | 1 |
| J4 search does not find the site | 0 | — | external; title/meta ours | 1 |
| J5 bare /forum 404 says nothing | 0 | 3 | forum (metta) | 5 |
| J6 README never names Paintbot | 0 | 3 | README PR | 3 |
| J7 docs never name Paintbot | 0, 4 | 3 | docs PR | 3 |
| J8 docs unreachable from the door tree | 4 | 3 | door + wiki + docs | 1, 3 |
| J9 COMPETE is a dead anchor | 1, 5 | 3 | door PR | 1 |
| J10 /paintbot/play status unstable | 7 (recorded) | — | out of scope (R7) | — |
| J11 wiki main three eras stale | 3 | 2 | wiki | 2 |
| J12 modes.md and game.description say duos | 3 | 2 | wiki + league settings | 2 |
| J13 two wiki pages disagree on submission | 3 | 2 | wiki | 2 |
| J14 ranks.md says weaker than truth | 3 | 2 | wiki | 2 |
| J15 first command fails (Python bound) | 4 | 4 | starter + CLI | 3 |
| J16 builder path addressed to an agent | 4 | 4 | CLI + docs + play.md | 3 |
| J17 --variant silently swaps the game | 4 | 2 | CLI default | 3 |
| J18 download resolves to a dead version | 4 | 2 | CLI + league | 3 |
| J19 success message points to the wrong doc | 4 | 3 | CLI | 3 |
| J20 "no token alternative" misleading | 3, 5 | 1 | wiki | 2 |
| J21 Observatory is a wall | 5, 6 | 3, 7 | thread routes around it (D3) | 4 |
| J22 sign-in severity unmeasured | 5 | 8 | Walk v2 measures it | 0 |
| J23 status page stuck | 5 | 3 | metta status page | 4 |
| J24 search by player only | 6 | 7 | standings panel PR | 4 |
| J25 window unnamed, no way back | 6 | 6 | standings panel PR | 4 |
| J26 rows are not links | 6 | 3 | standings panel PR | 4 |
| J27 labels undefined, no why | 6 | 1, 6 | standings panel PR + platform Step 1 | 4 |
| J28 episode permalink unstable | 2, 7 | 3 | replay client | 1 |
| J29 unrelated failures unexplained | 7 | 6 | rounds list | 5 |
| J30 strip badges undefined | 2 | 1, 5 | replay client | 1 |
| J31 Score vs ×N unnamed | 2, 6 | 6 | replay client + standings | 1, 4 |
| J32 endcard unreachable; delta data gapped | 2, 6 | 5, 7 | replay client + WIRE-OK + platform Step 1 | 1, 4, 5 |
| J33 forum has no on-ramp | 8 | 3 | owner pin | 5 |
| J34 no channel to ask | 8 | 3 | help line + pin | 5 |
| J35 resubmit gives no signal | 8 | 6, 7 | rounds page + platform Step 1 | 5 |
| J36 auto_champion seats a second league | 5 | 6 | membership default | 4 |
| J37 champion seat contention (test artifact) | — | — | league backend, not on the thread | — |
