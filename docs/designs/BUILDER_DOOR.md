# The builder's door — UX research and recommendation

Epic 16d081ab (THE WHOLE — stranger to ladder), task 9d37bf68. Research only;
no product change in this doc. Owner question (2026-09-09): template repo vs
guided CLI wizard (`coworld init paintbot`) vs in-browser editor vs a hybrid,
for a developer who has never heard of Paintbot.

**Era stamp:** repo `main` @ `9b6019aa`, `GameVersion = "61"` (`src/ctf/sim_types.nim:115`),
`GloryVersion 16` (GV61, `src/ctf/sim_types.nim:116`), latest shipped tag
`paintbot-v0.7.367`. The Stranger Walk evidence below ran live against
`paintbot-v0.7.367` / `GloryVersion 15` — one build older than this doc's
GLORYVERSION but the same CLI/auth surface; nothing cited below is
GLORYVERSION-sensitive.

All five research dimensions are now complete (this pass finished local-first
and CLI-wizard; browser-editor, DX evidence, and our own evidence were done in
the prior checkpoint). Full per-dimension writeups, sourced and
confidence-tagged, are checked in at `docs/designs/builder-door/01-local-first.md`
through `05-our-evidence.md` — this file is the synthesis.

## 1. The stranger's question ladder at the door

Owner's journey-quiz ruling (`~/.ctf/knowledge/stranger-walk/00-owner-decisions-2026-09-09.md`,
R7): the first minute must answer *what is this → why would I care → how does
it work*, in order; *how do I build* and *how do I submit* wait for a click.
Measured against Stranger Walk `sonnet-a` (`/Users/maxwellstarr/projects/stranger-walk-runs/sonnet-a/`,
`meta.json`, `score.json`, `transcript.jsonl`, isolation-audit PASS):

| Question | Today (measured) | Evidence |
|---|---|---|
| What is this? | 19.2s, 4 tool calls — genre/format/objective read straight off the landing page's "The coworld" section. Fast, works. | `score.json` M1; transcript.jsonl:17 |
| Why would I care? | **Not asked or answered anywhere on the path** — no milestone measures it because no surface states it. Owner's hook sentence ("My brain fights other people's brains...") is written down in the decision record but not shipped on the page (R9: "the fight of minds is not visible"). | `00-owner-decisions-2026-09-09.md` R8/R9; absence confirmed by the milestone list having no analog |
| How does it work? | 58.4s for scoring basics (M2) + 161.8s watching a replay to see why the winner won (M3) — both fast once found. `dig_count: 5`, bouncing softmax.com → docs.softmax.com → github.com raw content twice to get there. | `score.json` M2/M3; transcript.jsonl:26,65 |
| How do I build? | 9.4 min to a complete policy (M5), **then 12.1 minutes stuck** on an undocumented CLI argv contract before the policy could even be test-run locally. | `score.json` M5; transcript.jsonl:344-513 (BELIEF resolving the stall at line 513) |
| How do I submit? | Hard-blocked at the only sign-in method (GitHub OAuth) for 21 minutes; unblocked once a pre-provisioned GitHub identity became available, then upload + league submission completed in the same session. | transcript.jsonl:147-161 (wall hit), :550-851 (unblocked → submitted) |

Two caveats on "how do I submit," read from the source, not the prose: (a)
the run used a **pre-provisioned** synthetic GitHub account
(`~/.ctf/knowledge/stranger-walk/env`) — the ~2.5-minute gap between the wall
and "M6 unblocked" (transcript.jsonl:513→550, meta.json `resumes[0]`) is an
OAuth-redirect pause, not account-creation time. The cost of a stranger who
has *zero* GitHub account (signup + verification) is real but **unmeasured**.
(b) `softmax get-token` (`README.md:63`) only prints a bearer token *after*
`softmax login` has already completed OAuth — it is not an alternate,
non-GitHub auth path. There is no email/password/magic-link/token-only
sign-in anywhere in the product today.

## 2. Options ranked

Criteria: time-to-first-submission, install burden, where it stalls today
(cited), build scope, legibility payoff. Full source tables:
`docs/designs/builder-door/01-local-first.md` (Kaggle general, MIT Battlecode,
Halite by Two Sigma, Screeps, Robocode), `02-cli-wizard.md` (Terminal, Google
AI Challenge Ants/Planet Wars, AWS DeepRacer), `03-browser-editor.md`
(CodinGame, Lichess, Kaggle Simulations, Lux AI).

**Cross-cutting finding from the 14 reference platforms researched across both
passes: none publishes a time-to-first-submission or dropout number, and none
has a genuinely interactive CLI wizard (prompts → scaffolded files) as its
onboarding tool.** The CLI-first dimension's four platforms (Terminal, Ants,
Planet Wars, DeepRacer) are all either plain template-ZIP-plus-batch-CLI or a
browser-console wizard — never an interactive terminal wizard. The evidence
*for* CLI wizards (Create React App, `create-next-app`) comes entirely from
general dev tooling, not from this genre. Building `coworld init paintbot`
would be adopting a pattern proven in web tooling, not in bot-competition
platforms specifically — treat it as a reasoned bet, not a precedent match.

### Rank 1 — Fix the existing local-first door (template repo + CLI, as-is)

- **Time-to-first-submission:** ~21 min measured to a locally-verified,
  submittable artifact (sonnet-a), before the GitHub-auth wall.
- **Install:** Docker + the Nim/`uv` toolchain; "fork, edit one file" per
  `README.md:84-100`. Already proven to work end-to-end.
- **Stalls today:** the `--run` argv trap, 12.1 min, transcript.jsonl:344-513,
  already written down but unreached (`policies/starters/README.md:167`); the
  `--platform linux/amd64` silent-arch-mismatch trap
  (`policies/starters/README.md:203`), not hit by sonnet-a but documented as a
  known Apple-Silicon failure; the protocol-findability gap independently
  flagged by our own PoC author (`policies/poc_llm_policy/README.md:356-372`:
  "there is no client-facing protocol reference... this is the single
  highest-leverage thing to fix").
- **Build scope:** no new surface — docs/CLI-help/build-script edits only.
  Effort ~0.5–1 day. Risk: low (no engine change).
- **Legibility payoff:** none directly — same surfaces, fewer traps. It buys
  time and evidence for whichever door is chosen next.
- **Reference-platform fit:** matches every local-first platform researched
  (Battlecode, Terminal, Ants/Planet Wars) — template + local CLI is the
  *default* pattern for container/binary-artifact competitions; none of them
  needed a wizard to reach a first submission.

### Rank 2 — Hybrid: the fixed door plus a thin `coworld init paintbot` wizard

- **Time-to-first-submission:** unmeasured; plausibly removes most of the
  12.1-min stall by generating the working `--run` invocation and the
  `--platform linux/amd64` build flag into scaffolded files instead of
  requiring the builder to type them from `--help` and trial-and-error.
- **Install:** same toolchain underneath — a wizard removes *decisions*, not
  *installs* (per `create-next-app`'s own framing, `04-dx-evidence.md` §2).
- **Stalls today:** same three as Rank 1 unless specifically built to absorb
  them; the wizard is worthless if it just re-exposes the same raw argv.
- **Build scope:** new `coworld init paintbot` subcommand — prompt for a
  persona (aggressive/cautious/collaborative), copy the matching
  `policies/starters/*` tree, template-substitute a project name, and emit a
  generated run script/Makefile with the correct `--run`/`--platform` values
  baked in. Effort ~2–3 days. Risk: medium — new CLI surface that must track
  the engine's manifest/argv shape as it evolves; CRA's own staleness history
  is a documented cautionary case for exactly this failure mode
  (`04-dx-evidence.md` §2).
- **Legibility payoff:** real, if scoped for it — the wizard's own output is
  a legibility surface (it can print the hook sentence, the scoring loop
  summary, and "next: read the wiki at X" at scaffold time, the one place a
  stranger is guaranteed to be looking).
- **Reference-platform fit:** this is exactly the pattern every dual-path
  platform researched converges on — Lux AI and Kaggle Simulations both offer
  a second on-ramp that funnels into the *same* submission mechanism, never a
  replacement artifact (`03-browser-editor.md`).

### Rank 3 — CLI wizard alone, built before the door is fixed

Same wizard as Rank 2, built first instead of second. Not recommended as an
ordering: it just moves the same three traps one layer down, since a wizard
that hasn't absorbed them is decision-removal without trap-removal. No
CLI-first reference platform (Terminal, Ants, Planet Wars, DeepRacer)
provides precedent that a wizard *by itself*, without a working underlying
door, improves outcomes — all four of those platforms pair a plain
template/CLI with either no wizard or a browser-console wizard, never a CLI
wizard as the sole onboarding mechanism.

### Rank 4 — In-browser editor

- **Time-to-first-submission:** unmeasured; no reference platform funnels a
  real (non-toy) submission through a browser editor alone — every dual-path
  platform found still converges on a local/CLI step or a notebook-CLI
  bridge for anything beyond a toy submission.
- **Install:** lowest local burden *if* the server does the build — but
  Paintbot's real distribution unit is a linux/amd64 container image
  (`README.md`, `policies/starters/README.md`), not a function/script a
  platform runtime executes directly (which is what CodinGame, Lichess,
  Kaggle Simulations, and Lux AI all actually submit,
  `03-browser-editor.md` "Cross-platform note"). A browser editor here needs
  a new server-side build-and-push pipeline, not a UI change.
- **Stalls today:** does not touch the GitHub-auth wall at all — every
  reference platform's artifact-type choice was independent of its auth
  method. Adds unmeasured new failure modes (build-service outages,
  image-size/timeout limits) with zero field data.
- **Build scope:** 2+ weeks — hosted, sandboxed, linux/amd64-targeted build
  service; new auth-adjacent and abuse-surface concerns; ongoing infra to
  operate and keep in sync with the manifest/argv shape. Risk: high.
- **Legibility payoff:** weakest of the four — an in-page editor invites
  treating the editor's own UI as the source of truth, competing with the
  wiki's stated canonical role (`README.md:41-53`).

## 3. Recommendation

**Ship Rank 1 now, as a build scope one sonnet worker can execute in a single
session; queue Rank 2 (the wizard) as the next session once Rank 1 lands.**
Rank 1 is the only option backed by measured evidence (this run) rather than
analogy from other platforms, and every subsequent option is strictly
improved by having it done first — a wizard built on a fixed door is
low-risk; built on a broken one, it just relocates the same traps.

**Concrete one-session build scope (Rank 1):**
1. Surface the working `--run` invocation directly in
   `coworld run-episode --help` output and as a copy-pasteable example at the
   top of `policies/starters/README.md`'s "Run Season 2 locally" section
   (currently the trap-explaining prose is *below* the first command a
   builder would try) — closes the 12.1-min stall (~40% of this run's active
   dig time).
2. Fold `--platform linux/amd64` into every documented `docker build` command
   a builder is likely to copy. `policies/starters/README.md:198-200` already
   has it; `policies/poc_llm_policy/README.md:187` does not, despite
   `README.md:97-99` pointing strangers there as "a lower-level example of
   the binary upload/call/status protocol" — copying that command as-is
   builds an arm64 image `coworld upload-policy` will silently refuse
   (verified: grepped `docker build` across `README.md` and every
   `policies/*/README.md`; the only other bare hit, `README.md:234`, is
   under the deprecated Sprite v1 section, off the Season 2 builder path).
3. Add a short, prominently-linked protocol quick-reference (even a
   one-screen redirect pointing at `docs/designs/strategy-play-calling-shell-2026-08-29.md`'s
   §4.3 normative table) reachable from `docs/PROTOCOL.md`, which currently
   documents Sprite v1 only and never mentions the Season 2 packet
   (`policies/poc_llm_policy/README.md:356-372`).

**First three punchlist fixes that pay regardless of which door wins**
(from `~/.ctf/knowledge/stranger-walk/STATUS-2026-09-09.md`):
1. The `--run` argv trap above (punchlist #1, 12.1 min / 18 calls lost).
2. GitHub-only sign-in (punchlist #3) — scope a second auth method as its own
   fix, independent of the door choice; it blocks all four options equally
   and stopped this run cold until a pre-provisioned identity was available.
   The unmeasured cost for a stranger with *no* GitHub account at all should
   be closed as a follow-up Stranger Walk once a second method exists.
3. The `battle-royale-s2` wiki stub (punchlist #4) — the wiki is the stated
   canonical rules source (`README.md:41-53`) but the live variant's page is
   empty, forcing rule-inference from replays instead of reading.

## What is NOT verified

- The unmeasured cost of a stranger with *zero* pre-existing GitHub account
  (signup + verification latency) — this run used a pre-provisioned identity.
- Only 1 of 3 planned Stranger Walk baseline runs (`sonnet-a`) is complete;
  `sonnet-b` was running at research time (do not disturb, PID noted in the
  task brief), `opus-a` not started. This doc's evidence is single-run.
- Whether an in-browser editor is technically buildable at all for a
  container-image submission model — not spiked; Rank 4's placement is
  reasoning from reference-platform analogy and the repo's stated
  distribution model, not a feasibility test.
- "Auto-champion / any upload goes live" is carried as an owner-stated
  constraint from the task brief, not independently re-verified against
  league-scheduler code in this pass.
- No platform researched (14 total across both dimension passes) publishes a
  time-to-first-submission metric — checked, not merely unfound. Any number
  claimed for this metric elsewhere (ours or a reference platform's) should
  be treated as unestablished until directly measured with more than one run.
