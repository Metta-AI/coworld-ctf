# The front door — hook, loop, and entry-URL truth

Phase 2c of epic 16d081ab (THE WHOLE). Scope: the **paintbot page itself** — the door a stranger
walks through first. The wiki (the book) is a separate worker's lane; this doc only touches it
where the stranger's path passes through it.

Owner decisions this obeys: `~/.ctf/knowledge/stranger-walk/00-owner-decisions-2026-09-09.md`.
Era stamp: GameVersion 61 / GLORYVERSION 16, main `9b6019aa`. Source evidence: the real Sonnet
stranger-walk transcript at `/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-a/` (run
`sonnet-a`, completed 2026-09-09, entry URL `https://softmax.com/paintbot`, resolved 200, tags
`paintbot-v0.7.367` / Glory 15 at walk time) plus my own live browser visits to every URL below on
2026-09-09 (screenshots in `.harness/screenshots/p2-door/`, downscaled copies referenced from
`/tmp/p2-door/` — not committed, per context-hygiene practice; the PR body carries the key ones).

## 1. Entry-URL truth table

Every URL the stranger actually hit, from `paintbot` to first submission, and what it shows today.

| # | URL | What it shows today | Verified |
|---|---|---|---|
| 1 | `softmax.com/paintbot` | **ENTRY.** Season 2 league page: live replay, standings, league-leader chips, a "Compete → Submit a policy" link (bottom of right rail) and a "Join the League" link (top nav). Works. | Live visit + transcript |
| 2 | `paintbot/wiki/main` + 9 sub-pages (`battle-royale`, `round.md`, `glory-season-2.md`, `policies.md`, `submitting-a-policy.md`, `baseline-policy.md`, `modes.md`, `wire.md`, `labels.md`) | The Field Guide. Renders; banner reads "Verified against GV24 / Glory 12" — three eras stale against live GV61/Glory16. Owned by the wiki worker; noted here only because the stranger spent 9 of ~15 pre-signup navigations here. | Live visit (wiki/main) + transcript (rest) |
| 3 | `paintbot/forum.md` | Forum content as agent-readable markdown. | Transcript |
| 4 | `paintbot/play` | A **spectate/lobby surface** — loads a live replay by default with a `PLAY` button and `LOBBIES` link. Not a submission path; per owner ruling ("take a seat" is out of scope for this task) this is correctly bypassed by the stranger. | Live visit |
| 5 | `paintbot#production` (in-page anchor click) | Benign no-op: resolves to `/paintbot?e=<new-episode-id>` — just a fresh episode of the same page. Not the bug. | Transcript |
| 6 | **Click "Compete → Submit a policy"** → `softmax.com/#production` | **THE DOORSTEP BUG.** See §1a below. | Live visit (reproduced today) |
| 7 | `docs.softmax.com/guides/quickstart` | Generic **cross-game** Coworld quickstart (Docker/uv, no Paintbot specifics). Correctly punts onward: "follow the live participation guide at `https://softmax.com/play.md`." | Transcript (WebFetch) |
| 8 | `softmax.com/sign-in` | Standard GitHub-OAuth sign-in gate. Works. | Live visit + transcript |
| 9 | `softmax.com/play.md` | The **real, correct, paintbot-specific instructions** — agent-readable markdown: `docker`/`uv` setup, `uv run coworld download cow_...`, local smoke test, submit. This is what should be one click from the door; today it's reachable only via step 7's detour or by guessing the URL. | Transcript (WebFetch) |
| 10 | `github.com/Metta-AI/coworld-ctf/tree/main/policies/starters` (+ raw files) | Stranger self-served starter code from GitHub because no single UI surface pointed there directly. | Transcript |
| 11 | `softmax.com/observatory`, `/observatory/v2` (post sign-in) | Command Center / Browse. Paintbot's card shows a **"Participate in this League"** dropdown → a copy-paste **Play Prompt** box: `Get the contents of https://softmax.com/api/observatory/v2/participate?league_id=<id> and follow the instructions.` This is the actual working, agent-native submission door — but it lives three clicks deep inside Observatory, not on `/paintbot` itself. | Transcript screenshots (`dashboard.png`, `participate-dropdown.png`) |
| 12 | Submission confirmed | Stranger's handle (`gloriouslyagentic`) appears in the round/standings. | Transcript (`confirmed-standings.png`) |

### 1a. The doorstep wrong-app route (precise)

- **Where:** `/paintbot`, right-rail "Compete" panel, link captioned **"Submit a policy — it plays
  every round."** — the single most on-the-nose CTA on the entire page for a stranger who just
  decided to try this.
- **Href today:** literally `/#production` (verified live via accessibility snapshot: `link "Compete
  Submit a policy — it plays every round." /url: /#production`).
- **What clicking it actually does:** navigates to `https://softmax.com/#production` — the
  **company marketing homepage** ("Softmax — Scaling alignment"), a different app/product context
  entirely: generic "A universe of multiplayer games..." hero, a 4-step diagram, a `softmax.com/play.md`
  teaser, and a sample Paintarena leaderboard. No Paintbot context survives the click. Screenshot:
  `.harness/screenshots/p2-door/02-wrong-app-production.png`.
- **Why:** the `#production` anchor is **dead**. `document.getElementById('production')` on the
  homepage returns nothing today. A real target once existed — `id="production"` was a homepage
  section titled *"Play, Train, and Build with Coworlds"* — but it was deleted when the homepage
  was redesigned (commit `2db1f16484`, "cut the homepage over to the redesign", #21018). The
  Paintbot CTA was never updated to follow; it's been silently dead ever since.
- **What it should show:** a Paintbot-scoped participate flow. The page already HAS the correct
  pattern one link away — see §2.

## 2. Where the door lives

**Repo: `metta`**, not `coworld-ctf`. `/paintbot` is a Next.js dynamic route rendering
`<WatchTheater>`:
- `web/softmax.com/src/app/[coworld]/page.tsx` — root dynamic segment; comment: *"`/paintbot` is
  the coworld's default league."* Nested-league variant re-exports it:
  `web/softmax.com/src/app/[coworld]/[league]/page.tsx`.
- The page body is `web/softmax.com/src/app/watch/WatchTheater.tsx`.
- `/paintbot/wiki/*` → `[coworld]/wiki/page.tsx` + `[coworld]/wiki/[...page]/page.tsx`.
  `/paintbot/forum` → `[coworld]/forum/page.tsx`.
- `/paintbot/play` is **not** a route in this app — it's claimed at the ingress level by a regex
  location (commit `22a97ccd45`, "claim the paintbot play app with a regex location") and served by
  a separate process.
- **Deploy:** `package.json` name `@softmax/website`; built via Bazel target
  `//web/softmax.com:deployment`, packaged as a Docker image, pushed to ECR, deployed to Kubernetes
  via ArgoCD on `main`. No Vercel, no relation to this repo's CI.

Because the door lives in `metta`, **I am not opening a metta PR** — per instructions, here is the
exact proposed diff for someone with metta write access to apply.

### Proposed diff (metta, `web/softmax.com/src/app/watch/WatchTheater.tsx`)

The working "Join the League" link (line ~3429) already does this correctly:

```tsx
// WatchTheater.tsx:3427-3436 (working reference — do not change)
{!isBrowse && league ? (
  <TrackedLink
    href={leagueRoute(league.id)}
    analyticsEvent={ANALYTICS_EVENTS.watchJoinLeagueClicked}
    analyticsProperties={{ source: ANALYTICS_SOURCES.watch, leagueId: league.id, leagueName: league.name }}
    className={JOIN_LEAGUE_CLASS}
  >
    Join the League
  </TrackedLink>
) : null}
```

`leagueRoute` (`web/softmax.com/src/observatory/lib/routes.ts:48-52`) returns
`` `/observatory/v2?detail=league:${encodeURIComponent(leagueId)}` `` — sign-in gating happens
server-side in the proxy (it admits only `isPublicObservatoryPath` and carries `redirect_url`
through `/sign-in`), so this single href already gets you: sign-in if needed → Observatory →
the league's "Participate in this League" prompt (§1, row 11) — the real door.

The broken CTA (line 7938) sits in the same render tree, and `league` is **already in unguarded
scope** there (referenced just above at lines 7211, 7281–7285, 7326 via `CoworldBrief`/`outlookLine`)
— no new prop threading needed:

```diff
- <a
-   href="/#production"
+ <a
+   href={leagueRoute(league.id)}
    className="group focus-visible:outline-accent hover:bg-surface-alt active:bg-surface -mx-2 block rounded-[3px] px-2 py-1.5 no-underline transition-colors focus-visible:outline-2 focus-visible:-outline-offset-2"
  >
    <span className="flex items-baseline justify-between gap-2">
      <span className="eyebrow text-foreground">Compete</span>
      <span aria-hidden className="...">&rarr;</span>
    </span>
    <span className="text-foreground-muted mt-1 block text-[12px] leading-snug">
      Submit a policy — it plays every round.
    </span>
  </a>
```

One-line fix, zero new state, reuses an existing, already-correct helper. (A `TrackedLink` swap for
analytics parity would be a nice-to-have, not required to fix the doorstep bug.)

Also flagged, not fixed here (belongs to the wiki worker / a separate ticket): the wiki's stale
"Verified against GV24 / Glory 12" banner, three eras behind live GV61/Glory16.

## 3. Three copy candidates (first screen, hook → loop → next click)

Tagging vocabulary only (tag/marker/spray — no "shoot/gun/kill"; matches the live wiki's own usage:
*"Nobody is killed: a bullet removes 1 of a Cog's 3 hit points... a heart on screen"*). No internal
version strings, no policy-source attribution. Order per R7: what-is → why-care → how-it-works,
folded into one paragraph, then the loop, then one CTA. Each ≤120 words total.

### Candidate 1 — RECOMMENDED

> **My brain fights other people's brains, and that produces a legible testbed for agent behavior.**
>
> Paintbot is a live paintball-tag battle royale where every player on the field is a submitted AI
> policy, not a human with a controller. Every tag, push, and truce gets logged, so a round doesn't
> just end with a winner — it explains itself: this is where you find out whether your agent holds
> up under real pressure, and exactly why. The loop: build a policy, submit it, watch it fight on
> the ladder every round, read the replay to see why it won or lost, retune.
>
> **[ Watch a round live → ]**

(106 words.) **Why recommended:** cleanest what-is/why-care/how-it-works ordering: the hook's
"legible testbed" claim is immediately cashed out concretely ("every tag, push, and truce gets
logged"), which is the owner's stated #1 legibility priority. The CTA is a low-commitment first
click ("watch," not "build") — appropriate since the first minute's job is to earn the click, the
build waits for the next one.

### Candidate 2 — stakes-first

> **My brain fights other people's brains, and that produces a legible testbed for agent behavior.**
>
> Somewhere on this ladder an AI policy is winning and another is losing, right now, and you can
> watch it happen. Paintbot is a paintball-tag battle royale where every player is a submitted
> policy — no rank average, no black box: every tag, alliance, and push is logged into a ledger of
> deeds, so a round tells you exactly what earned the win. That's the deal: build a policy, submit
> it, it plays every round on the ladder, read why it won or lost, retune.
>
> **[ See why the leader is winning → ]**

(106 words.) Leans harder on urgency/stakes; risks reading as hype before the mechanism is
established.

### Candidate 3 — builder-invitation

> **My brain fights other people's brains, and that produces a legible testbed for agent behavior.**
>
> Paintbot is a live ladder where AI policies play paintball-tag battle royale, and anyone can
> submit one — including yours. It's built to be read, not just watched: every tag, truce, and push
> is logged so a round explains itself, which is exactly what makes it worth building on instead of
> just admiring. The loop: build a policy, submit it, it fights on the ladder every round, read the
> replay to see why it won or lost, retune and resubmit.
>
> **[ Build your first policy → ]**

(99 words.) Most directly serves the north star ("outside people BUILD on Paintbot") but asks for
the bigger commitment (build) before why-care is fully earned; better suited to a returning
visitor or a secondary CTA than the very first sentence a stranger reads.

## 4. Static mock

`docs/designs/front-door/index.html` — Candidate 1, in the Ink & Print house style (light-mode
tokens per the owner's light-default ruling; the live page currently renders dark, which is a
separate, already-flagged theme bug — not addressed here). Screenshot in the PR body.
