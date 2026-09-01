# Recon: Paintbot Season 2 policy shell — foundation report

> **Historical recon (2026-08-29).** Branch inventory, missing-surface, default,
> and implementation-status claims below describe the pre-landing checkout.
> They are preserved as evidence, not current Season 2 guidance.

**Date:** 2026-08-29 · **Audience:** coding agents designing and building the Season 2
LLM policy shell · **Update (later the same day):** Maxwell cut
`origin/maxwell/br-season2-complete` (= br-reflash-integration + glory
increments + the flash playbook seeds + a BR episode recorder) after this recon
was written; it supersedes §5's "build on br-reflash-integration" advice, and
the play-calling design (`docs/designs/strategy-play-calling-shell-2026-08-29.md`)
names it as the base branch. · **Status:** recon only — this document deliberately does *no*
designing or planning. It states what exists, where, and how the pieces connect, with
citations, so design work can start from verified ground.

**Repos covered** (all local, all verified current as of 2026-08-29):

| Repo | Path | State |
|---|---|---|
| `Metta-AI/coworld-ctf` (public, push) | `/Users/jamesboggs/coding/coworlds/coworld-ctf` | `main` @ `4f8f77c`, clean |
| `Metta-AI/coworld-paintbot-player` (private, write) | `/Users/jamesboggs/coding/coworlds/coworld-paintbot-player` | fresh clone, `main` @ `5455d1b` |
| `personal_paintbot` (James's lab) | `/Users/jamesboggs/coding/personal_labs/personal_paintbot` | `main`, 2 ahead of origin (local work) |

Citation convention: repo-relative paths within a section's repo; `origin/<branch>:path:line`
for branch-only files. All branch reads were done via `git show`/`git diff` without
checking anything out.

---

## 0. Mission

James is adapting the `stencil` policy in `paintbot_lab` into a **shell** for a new
policy paradigm: the *policy* is an LLM that (a) chats in a pre-round lobby with other
participants and (b) occasionally "flashes a script" / "calls a play" — a smallish
DSL-like script sent to the running bot. The shell keeps running the orchestration loop
and the "body" (nav/combat/micro) as stencil does today, but the script dictates the
"mind": instead of a fixed priority ladder, the script assigns each sub-goal behavior
(carry flag, escort carrier, third-party, move to ring, form squad, move to post, …) a
scalar score; the shell argmaxes and the winning behavior emits a typed `Intent` as it
does now. Maxwell is building the Season 2 front end; this report maps everything the
backend must plug into.

---

## 1. TL;DR — the eight facts that shape everything

1. **The scored-behaviors paradigm already exists in prototype, twice, on Maxwell's
   branches.** `players/onepage/` (branch `maxwell/br-onepage-runner` in coworld-ctf)
   is a bot that argmaxes a fixed 12-intent menu under an LLM-authored JSON "page";
   `src/ctf/policy_page.nim` (branch `maxwell/br-onepage-vm`) is a real, engine-free
   scoring-DSL VM with validation, interning, and an LLM authoring loop (`tools/flash/`).
   **The two page languages are different and unreconciled** (§5.4) — choosing one is
   an early design decision.
2. **Mid-episode re-flash is fully built and proven live** on
   `maxwell/br-reflash-integration`: pages ride the `0x86` debug-sprite opcode with a
   `"CTFPOLICYPAGE1\n"` magic prefix, are gated by `allowPolicyReflash` (default off),
   recorded into the replay with a content hash, mixed into `gameHash` via a
   hash+epoch pair, and re-applied bit-identically at playback. A live round-trip
   harness with a GATE=off negative control exists (§5.2–5.3).
3. **The pre-round chat phase is fully built** on `maxwell/lobby-chat` in
   coworld-paintbot-player: `POST /api/lobbies/:id/start {"chat":true}` runs a bounded,
   fully-open, sequential LLM huddle (2 rounds, ≤30 s phase, ≤12 s/turn, ≤500 chars),
   then generates one page per seat and delivers it **once, by env var, at bot spawn**
   (`COWORLD_POLICY_PAGE` / `COWORLD_POLICY_PAGE_FILE`). A page is never null — every
   failure produces a recorded fallback with a `source`/`reason` (§6.4–6.5).
4. **The seam between the two:** `recordMidEpisodePage` exists in
   `origin/maxwell/lobby-chat:server/preround.mjs:460-466` and is verified uncalled
   anywhere in repo history; on the engine side, `pollForNewPage`
   (`origin/maxwell/br-reflash-integration:players/onepage/onepage.nim:1341-1352`) is a
   file-watching stand-in whose own comment says the real trigger "is a different
   lane's delivery mechanism." **Mid-episode page delivery from an LLM service to a
   running bot is the unbuilt piece** (§8.2).
5. **The game mode is Battle Royale**: 32 seats, 16 duos, one life, a shrinking
   rectangular zone, last-duo-standing, an uncalibrated placement-bonus table gated on
   one attack per match. **None of it is merged** — coworld-ctf `main` has zero BR
   code; `br-integrate` is 253 commits ahead (§4).
6. **Stencil cannot take a BR field today.** `BR_LADDER.md` §7: the `Team` enum has 4
   values, `WorldMap` construction is gated on perceiving endzones (a BR map emits
   none → `hold("no_worldmap")` forever), `seatsPerTeam` resolves to 4 for a duo, and
   the zone is not perceived at all (§7.9).
7. **Main's paintball KOTH mode is a shipped, scarred precedent** for the whole
   LLM-in-the-loop shape: fogged JSON view → Claude → typed directive with a closed
   intent enum → tolerant repair-never-reject parser → deterministic mask compiler,
   under a "degrade, never hang" budget regime (§3.6). Its design decisions (and its
   scar-tissue comments) are required reading before re-deciding any of them.
8. **A 989-line design document proposing the BR rung ladder for stencil already
   exists, written for James, dated today**:
   `origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md`. Its §6.5 sketches a
   "playbook page" scoring model where argmax over `baseWeight + Σ modifiers` reduces
   exactly to first-match-wins at default weights — i.e., the Season 2 paradigm is
   half-designed there already (§4.5, §8.1).

---

## 2. Repo, branch, and merge-state inventory

### 2.1 coworld-ctf (the engine)

`main` @ `4f8f77c` (2026-08-29, "Merge daveey/hit-damage-stats: GV47"). ~31k lines of
Nim under `src/`. `GameVersion* = "47"` (`src/ctf/sim_types.nim:20`); GV46 was skipped
because the glory port on a branch reserved it (`src/ctf/sim_types.nim:32`) — main's
*only* acknowledgement of BR.

**Merged on main:** classic CTF + the paintball KOTH LLM mode + four-team mode + the
mux transport (`COGAME_MUX_SOCKET`, `src/ctf/mux.nim`) + replay→BC trajectory export
(`tools/export_trajectories.nim`) + GV47 hit-damage stats.

**Not on main (branch-only):** everything BR (`~30 maxwell/br-*` branches), reflash,
onepage, the player client (`client/player_client.html`), glory, seat takeover,
Season 2 controls. Verified by exhaustive grep: "Season 2", "S2", "reflash",
"onepage", "preround" have **zero occurrences** on main.

Key branches (all `origin/maxwell/...`):

| Branch | Ahead of main | What it is |
|---|---|---|
| `br-integrate` | 253 | The BR trunk: 16-team engine core, `brMode` elimination, `zonePhases`, flagless spawns, placement scoring, GV45 |
| `br-reflash-integration` | 298 | **The join of the reflash lanes — the branch to build on** (its own commits say so). Contains the full wire + replay + live proof |
| `br-policy-reflash-replay` | (strict ancestor of the above) | Engine/replay lane only: record, gate, gameHash, playback |
| `br-onepage-runner` | 288 | `players/onepage/` — the 12-intent scored bot with a placeholder linear-page VM |
| `br-onepage-vm` | 122 | `src/ctf/policy_page.nim` — the real s-expression scoring VM + `tools/flash/` authoring loop |
| `br-ladder-design` | — | `docs/designs/BR_LADDER.md` (989 lines, for James, 2026-08-29) |
| `br-review-doc` | — | `REVIEW.md` (590 lines) — guided pre-merge read of the whole BR line |
| `ladder-scout-tooling` | — | `docs/designs/BR_MAPGEN.md` (594 lines) — the BR mode/doctrine spec. ⚠️ 20 files in the BR tree cite it by name; merging `br-integrate` without it dangles every citation (`REVIEW.md:~510`) |
| `br-team-outline` | 3 commits over BR base | The cited render-only example: +101 lines in one file, `client/player_client.html` |
| `s2-takeover-shout` | 9 commits | Human seat-takeover lane (tickets, watchdog, shout attribution) — *not* the policy lane |
| `br-day-one-reads` | — | `tools/ladder/br_reads.py`, `br_smoke.py` — pre-registered launch-day reads + rollback runbook |

**No JOURNAL file exists in this repo** on any ref (swept `git ls-tree` over all
`origin/maxwell/*` + main). Commit messages referencing "JOURNAL ea032db" point at a
fleet-coordination artifact outside the repo. In-repo design record = `REVIEW.md`,
`BR_LADDER.md`, `BR_MAPGEN.md`, and Maxwell's long doc-comment headers in source.

### 2.2 coworld-paintbot-player (everything outside the match)

`main` has only **5 commits**. Zero-dependency Node ≥20, ESM, no framework: `node:http`,
hand-rolled router, vanilla-JS front end. `server/` is 6 files, ~1350 LOC. Run via
`bin/paintbot-play` (default port 7333).

| Branch | What it is |
|---|---|
| `maxwell/lobby-chat` | **Pre-round chat + page generation + deferred boot** (4 commits; first commit *is* `onepage-policy-wire`). Doc: `docs/preround-chat.md` |
| `maxwell/onepage-policy-wire` | Strict subset: just the page delivery channel (`seat.page`, `pageEnv()`, `resolveBotBin()`), no LLM/chat |
| `maxwell/br-32seat` | BR as a config choice: `MODES=["br","ctf"]`, `DEFAULT_MODE="br"`, 32 seats for BR, engine-side `/takeover` handover, `server/rewards.mjs` |
| `maxwell/round-splash-and-br-pick` | Round-end splash pacing + BR-correct seat picking + round-counter fix |
| `maxwell/solo-freeplay` = `maxwell/zero-wait-arrival` | Identical trees: the rebuilt landing page ("Free Play / Lobbies doors with BR\|CTF up front") |
| `maxwell/zero-wait-seatres-app` | Server-side sibling: engine seat picker + 32-seat BR + mode-switch race fix |

⚠️ **Integration hazard:** `lobby-chat` branches off `main`; every BR/landing branch
shares a different base. They will conflict in `server/matchd.mjs`, `server/lobby.mjs`,
`server/engine.mjs`, `server/app.mjs`.

### 2.3 personal_paintbot / paintbot_lab (the lab)

The player is **Nim** (`paintbot/stencil_nim/`, 21 modules, 7,410 lines — corrected
2026-08-29; an earlier draft said 25/8,353). Live champion
is `stencil:v68` (submitted 2026-08-14); `stencil:v69` uploaded 2026-08-29, inert, tag
`purpose=idle-aim-intent`. The **strategy-rework epoch opened 2026-08-29**
(`paintbot_lab/WORKING_CONTEXT.md:113-116`): "separate the 'body' and the 'mind' of
Stencil — make the action, intent, and strategy loops separable with clear,
well-defined interfaces." **No Season 2 / DSL / LLM-policy document exists in the lab**
— that part is greenfield.

---

## 3. The engine on main (coworld-ctf)

### 3.1 Server architecture

- Entry: `src/ctf.nim` (seed randomization before `config.update`, `src/ctf.nim:5-46`).
  Server: `src/ctf/server.nim` (2452 lines); `runServerLoop*` at `server.nim:1262`,
  frame loop from `:1411`. `sim.nim` (4121 lines) re-exports every sibling.
- Transport: mummy websockets, Sprite v1 (`bitworld/spriteprotocol`), one binary
  message per tick per seat. Input `0x84` bitmask, ready `0x85`, chat `0x81`, sprites
  off `0x87` (`server.nim:317-321`). Routes: `/player`, `/global`, `/replay`,
  `/admin`, `/reward`, `/healthz`, `POST /control/{restart,kick}` (`server.nim:59-64`,
  `:661-667`).
- **Mux transport** (merged, `b729a18`): `COGAME_MUX_SOCKET=<path>` multiplexes all
  policy seats over one Unix socket; wire at `src/ctf/mux.nim:12-19`
  (client→server `0x01 JOIN`/`0x02 INPUT`/`0x03 READY`; server→client `0x01 FRAME`);
  `MaxMuxSeats* = 32` (`mux.nim:33`). Frames are byte-identical to the websocket path.
- Joins are **slot-sequential and token-checked** (`server.nim:284-395`). Seat↔cog:
  `cogSeat = cogIndex mod seatCount` (`sim.nim:268`); aliases like `"RED-alpha"`
  (`sim.nim:280`) — anonymity is a *tested* invariant
  (`tests/test_pb_identity_privacy.nim`, `tests/test_identity_privacy.nim`).

### 3.2 The two policy interfaces on main — do not conflate

**(a) Classic CTF: client-side policy, per-tick 8-bit actuator mask.** Spec:
`docs/PROTOCOL.md` (100 lines) + `docs/RULES.md:786-795`. D-pad = locomotion only;
B/Select rotate a 256-brad aim (`AimTurnRate* = 5`, `sim_types.nim:472`); A fires; C
(`0x80`) charges/releases grenades. Applied at `applyInput*` (`sim.nim:2352`,
aim decoupling `:2380-2386`). Observation = one fogged Sprite v1 frame per tick
(±60° cone to 1.5× gun range + ~90 px bubble; `README.md:37-48`, `docs/RULES.md:243`).
The reference implementation is `players/baseline/baseline.nim` (3,236 lines).

**(b) Paintball KOTH: server-side LLM, JSON directive every ~4.5 s.** See §3.6.

### 3.3 Shouts (`applyShout`) — the in-match chat channel

`proc applyShout*(sim, playerIndex, text): bool` — `src/ctf/sim.nim:2236`.

> ```nim
> if sim.phase != Playing:
>   return false
> ```
> — `sim.nim:2241-2242`. Phases: `Lobby | Playing | GameOver` (`sim_types.nim:1097-1100`).

- **Radius:** `ShoutRange* = MapWidth div 5` — declared at `sim_types.nim:1013`
  ("audible within 20% of the screen width") and shadowed at `arena.nim:3454`.
  Default arena `MapWidth* = 1235` → **247 px**. Audibility: `shoutAudibleTo*`
  (`sim.nim:2278-2289`); shouts pass through walls and fog; dead viewers hear nothing.
- **Caps:** `ShoutMaxChars* = 10`; visible `ShoutTicks* = 3 * ReplayFps`; cooldown
  `ShoutCooldownTicks* = ReplayFps` = 1 shout/second (`sim_types.nim:774`, `:819-821`).
  One live bubble per player (`sim.nim:2254-2258`).
- **Callers:** human chat `0x81` (`server.nim:1880`); a paintball cog's directive
  `say` — a real hashed in-game shout (`server.nim:2059`); replay playback
  (`replays.nim:415`). The LLM-path sanitizer `sanitizeSay*`
  (`directives.nim:70`) strips `{`/`}` because a leading `{` distinguishes a paintball
  control record from a shout in the replay chat stream (`:78-81`).
- ⚠️ **Determinism coupling:** `gameHash` hashes every entry in `sim.recentShouts`
  character-by-character — so mid-episode LLM chat over shouts is a simulation input
  (noted in `origin/maxwell/lobby-chat:docs/preround-chat.md:90-114`).

Maxwell's claims verified: proximity ≈ MapWidth/5 ✅; "applyShout refuses outside
Playing" ✅.

### 3.4 Env vars a policy process sees (main)

| Var | Read at | Meaning |
|---|---|---|
| `COWORLD_PLAYER_WS_URL` (fallback `COGAMES_ENGINE_WS_URL`) | `src/paintball_player.nim:58`, `players/baseline/baseline.nim:3233` | the seat websocket URL |
| `PLAYER_PROMPT` | `src/paintball_player.nim:62` | paintball: plain-English strategy → LLM seat. Cap `MaxPromptRunes = 4000` (`sim_types.nim:824`) |
| `PLAYER_SCRIPTED` | `src/paintball_player.nim:63` | `holdline` \| `sprayer` |
| `PLAYER_POLICY_LABEL` | `src/paintball_player.nim:65` | replay register label |
| `CTF_BOT_SHOUT` | `baseline.nim:3150` | enable baseline shouting |
| `CTF_BOT_FAST_READY` | `baseline.nim:3158` | **opt-in only.** Per-frame `0x85` on a wall-clock server corrupts input timing (accuracy 44–54% → 13–23%, p=0.0039; `baseline.nim:3151-3157`, `docs/PROTOCOL.md:26-41`). Needed for fast recording servers |

Game-container vars: `COGAME_{HOST,PORT,CONFIG_URI,RESULTS_URI,SAVE_REPLAY_URI,MUX_SOCKET,EVENTS_URI,METRICS_URI,PLAYER_FAILURE_URI}`, `COGAME_LOAD_REPLAY_URI`;
LLM credentials: `ANTHROPIC_API_KEY`, `ANTHROPIC_API_KEY_URI` (platform injects
`secret://coworld/paintball/anthropic_api_key`), Bedrock sidecar vars
(`src/ctf/llm.nim:15-21`, `:58-113`; `docs/paintball/PROTOCOL.md:27-32`).

The branch-only page vars (`COWORLD_POLICY_PAGE`, `COWORLD_POLICY_PAGE_FILE`) are in
§5.4/§6.4.

### 3.5 Manifest and variants

`coworld_manifest_paintbot.json` — **8 variants** (Maxwell's message listed 7; add
`paintball`): `2v2` (:935), `4ffa` (:1067), `4ffa8` (:1199, 32 seats, giant map),
`default` (:1428), `1v1` (:1559 — actually one policy fielding all 8 per side),
`ctf-default` (:1691, arena map), `ctf-1v1` (:1820, true 2-player), `paintball`
(:1866 — the LLM mode: 2 seats × 4 cogs, hill, `turnTicks:108`, `turnBudgetMs:10000`,
`fastMode:true`). Only one manifest `player`: `baseline` (:913) — deliberate
(`tests/test_pb_manifest.nim:35-39`). BR's manifest is authored on
`origin/maxwell/br-manifest` as `coworld_manifest_br.json` (BR ships as a **dedicated
league**, decided 2026-08-24 — `BR_MAPGEN.md` §1). Mode gate on main:
`squadMode = not replayLoaded and config.numAgents > 0 and config.cogsPerTeam > 1`
(`server.nim:1393-1394`); every gate defaults off and a gate-off config plays classic
rules byte-identically (`AGENTS.md:136-147`).

### 3.6 The paintball KOTH LLM pipeline — the shipped precedent

The single most relevant merged code for Season 2 design. Fielding a policy is
`coworld upload-policy <image> --run /bin/paintball-player --secret-env PLAYER_PROMPT="..."`
(`docs/paintball/COMMANDING.md:84-90`).

- **Architecture decision, already made and documented**
  (`src/paintball_player.nim:3-8`): the policy container is a deliberately thin seat
  registrar (146 lines); *every decision happens inside the game server*, because the
  game container is the only one the platform injects the Anthropic key into, and
  server-side control keeps the recorded mask log reproducible with no network in the
  loop. Reversing this is a platform-secrets fight, not a code fight.
- **Closed intent enum** (`src/ctf/directives.nim:22-31`): `paint_hill`, `hold_hill`,
  `hunt`, `guard`, `paint_path`, `fall_back`. Reply schema in `SystemPrompt`
  (`src/ctf/llm.nim:207-236`).
- **Tolerant, repairing, never-rejecting parser**: `parseSquadDirective*`
  (`directives.nim:205`, repair contract `:211-230`) — unknown intent → `paint_hill`,
  unmatched id → next unclaimed cog by position, missing target → hill centre, all
  clamped. `extractJsonObject*` (`:102`) tolerates fences/prose. Missing cogs repaired
  from last turn's order (`decide.nim:279`).
- **Deterministic compiler**: `compileMask*` (`src/ctf/control.nim:416`) — pure
  `(sim, directive, cogIndex) -> uint8`; the control layer sits *outside* the hash
  boundary and may use floating point (`control.nim:9-13`). Only compiled masks are
  recorded; the wasm viewer re-derives the match without running controller or LLM
  (`server.nim:2016-2021`).
- **Observation**: `seatViewJson*` (`src/ctf/decide.nim:74-214`) — built from the
  seat's own fog, with explicit redaction (`decide.nim:80-84`). Prose:
  `docs/paintball/PROTOCOL.md:61-95`.
- **"Degrade, never hang"** (`decide.nim:11-19`): bounded attempt-1 + one retry, a
  monotonic `turnBudgetMs` deadline, a budget guard that disables the LLM for the rest
  of the episode if two more turns wouldn't fit (`:333-344`), a rate floor
  (`turnSpacingMs`, `:385-395`), fail-fast on throttle (`:481-488`). Every failure
  yields a `fallback` record naming the cause
  (`no_credentials|budget_guard|timeout|transport_error|throttled|parse_error`).
- **Scar tissue**: curl's `CURLOPT_TIMEOUT` floors to whole seconds — 0.1.2's
  `attempt1Ms: 4500` really ran at 4 s and every "successful" directive was the
  deadline answering, not the model; `sim_config` now rejects sub-second values
  (`decide.nim:428-437`). Registration must be *re-sent* for ~10 s, not sent once —
  slot-sequential admission means a single registration can land while the seat has no
  index; this cost a real hosted round (`src/paintball_player.nim:102-111`).
- Docs: `docs/paintball/{RULES,PROTOCOL,COMMANDING}.md` and the ported 1,436-line
  design note `docs/paintball/plans/2026-08-25-paintball-design.md` — **the single
  most valuable merged document for S2 design**.

### 3.7 Client surfaces and the staticRead trap — corrected

Main has **no player client**: `client/` holds only `replay_broadcast.html` (4,671
lines), `league_replayer.html`, `broadcast_core.js`, `chrome_common.js`, art. Live
`/player` and `/global` on main serve bitworld's generic client (`server.nim:69-72`).
`window.CTF_WIRE` constants are spliced from Nim consts (`src/ctf/wire_constants.nim:21-37`).

**The trap, precisely:** on main, `src/ctf/server.nim:185` is
`MaxWsFrameBytes* = 900_000` — *no* staticRead of a player client. On the BR branches
the claim is exactly true: `origin/maxwell/br-onepage-runner:src/ctf/server.nim:185`
is
`EmbeddedPlayerClientHtml = staticRead("../../client/player_client.html").replace(`
(splicing `player_controls.js`, `:186-188`). So the page a human sees **is baked into
the ctf-server binary at compile time**; editing any on-disk copy ships nothing.

⚠️ **Line-count correction to Maxwell's message** (verified 2026-08-29): the vendored
copy `coworld-paintbot-player/vendor/client/player_client.html` is **335** lines (not
588); the engine-branch copies are **707** (`br-onepage-runner`) and **808**
(`br-team-outline`, which adds the +101-line team-ring code). The drift is worse than
stated; the conclusion stands — the vendored file is a stale reference, never served.
The paintbot-player app's own comment agrees:
`server/field.mjs:266-270` ("`/client/player` is baked into the sim binary at Nim
compile time (staticRead)…"), and `fieldClientStamp()` (`field.mjs:285-310`) SHA-1s
what the live port actually serves because that is the only ground truth. The vendor
warning block is at `bin/vendor-engine.sh:159-171` (Maxwell said 160-172 — off by one).

The **ping wheel** is branch-only too:
`origin/maxwell/br-onepage-runner:client/player_client.html:17-53` (`#wheel`, RMB-hold
radial callout wheel; seam hooks `window.onPingWheelOpen`/`onPingWheelCommit` at
`:443-444`). Controls legend on that branch (`:420`): `WASD move · mouse aim · LMB
fire · Space item · 1-6 ping · RMB wheel hook`.

`br-team-outline` (the "live example"): 3 commits, one file, +101 lines, pure browser
recomposition of labels the seat already receives. `b3d70a9`'s message: "a policy's
observation is byte-identical with this code present or deleted." Final contract:
self = engine's own 2px white rim + 3px near-black keyline; partner = 4px HUD amber +
keyline, weighted for the 0.498-scale arena camera (`fed4d9a`). This is the model for
a render-only change.

---

## 4. Battle Royale — the Season 2 game mode

Two canonical design docs, neither on main:
- **`origin/maxwell/ladder-scout-tooling:docs/designs/BR_MAPGEN.md`** (594 lines,
  DRAFT 2026-08-24) — mode/doctrine spec. ⚠️ Not on `br-integrate`; 20 BR files cite it.
- **`origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md`** (989 lines, DESIGN
  2026-08-29, written for James) — the stencil-BR decision-ladder design.
- Plus `origin/maxwell/br-review-doc:REVIEW.md` (the guided merge-review read) and the
  BR sections of `docs/RULES.md` on the BR branches.

### 4.1 Rules

- **32 seats, 16 duos**, field 3211×1713 px ("giant", ~6.9× CTF's arena), BR
  `gunRange` override 331 px (derived, `BR_MAPGEN.md` §4.1), 16 jittered 4×4-grid
  spawn points (§4.2). `MaxPlayers* = 32`
  (`origin/maxwell/br-integrate:src/ctf/sim_types.nim:509`).
- **One life.** `brMode:true` forces lives to 0 on first death; no respawn path at
  all. Base HP **3** (`sim_types.nim:421`). BR maps are flagless — no hearts,
  pedestals, endzones, "not even INERT ones" (`sim_types.nim:1309-1311`).
- **Win = last team standing**; simultaneous final wipe = draw; timeout resolves by a
  strict total order with no draws: living → last-death tick → kills → damage → seat
  (`4db68b3`).
- **The zone is a rectangle**, same 1.874:1 aspect, scaled by scalar `z` about a
  center **drawn once per game from the sim RNG** (not map center). `ZonePhase =
  (z, waitTicks, shrinkTicks, dps)`, ≤8 phases, `z` strictly falling. Reference
  schedule (`origin/maxwell/br-integrate:tools/record_br_match.sh:115-123`,
  maxTicks 6000 @ 24 tps): dps 0 → 2 → 4 → 8 → 12 → 16 → 20; **no damage until tick
  3528 of 6000**. Damage cadence 1 s (`ZoneDamageRollTicks* = TargetFps`),
  deterministic. Two markers re-stated **every frame**: `zone x0,y0 x1,y1` and
  `zonenext ...` (one-phase lookahead). BR_LADDER's read: "The zone is a hard wall,
  not attrition — and it does nothing for the first 59% of the match."
- **Zone center is predictable**: it drifts linearly from board center toward the
  drawn point as `z` falls (`sim.nim:3357-3388`), so two `zone` observations at
  different scales determine the final center — knowable during phase 1's 3000-tick
  wait (BR_LADDER §3.10 `zone_forecast`; confidence "medium on mechanism, low on
  exploit").
- **Combat unchanged from CTF** (gun 1 hp, grenade 2, spray 3/activation, shield 3,
  HP 3); no ammo; no death loot (`sim.nim:921-932`); medkits heal to full; item
  respawn 720 ticks. Item placement is a per-item gradient over site classes
  (`BR_MAPGEN.md` §4.9).

### 4.2 Scoring — currently in tension

- **Shipped:** `BrPlacementBonus*: array[2..16, int] = [5,4,4,3,3,2,2,2,1,1,1,0,0,0,0]`
  (`origin/maxwell/br-integrate:src/ctf/sim_types.nim:522-524`), explicitly
  "UNCALIBRATED … the evidence phase (real BR replays) picks the actual numbers."
  **Zero from 13th place on.**
- **Engagement gate:** one attack *or* one point of damage across the duo, whole
  match (`sim.nim:2995-3000`) — "the cheapest point in the mode" (BR_LADDER).
- **Intended:** "scored in glory" (`BR_MAPGEN.md` §1). Glory (`src/ctf/glory.nim` on
  `br-glory-port-v2`/`br-glory-visible`, GloryVersion 10; ranks
  `primer…maestro`, `glory.nim:756`) is ported but the ship-v1 decision is open
  (`REVIEW.md` §7.1). Constraint: survival-derived glory "must CAP or TAPER late"
  (`BR_MAPGEN.md` §7.3).
- **Placement is per team, decided by whichever duo member dies second**
  (`lastDeath[team] = max(...)`, `sim.nim:2841-2867`) — partner survival is direct
  placement equity (BR_LADDER §3.7).

### 4.3 Duos and the partner

Teams are **engine-assigned** — no duo-invite mechanic exists anywhere. `Team` widened
4→16 on `br-team16` (`7027e5b`; sprite/wire ID pool relocations to avoid silent
overlap). With 16 spawn points and 16 teams both duo members spawn **on the identical
pixel** (`tests/test_br_team_bridge.nim:37-40`); team→spawn binding rotates per
episode via a hashed seed offset (`sim_state.nim:340-352`). Partner death is
**invisible to a live bot** — corpses render only for ghost viewers
(`global.nim:8635-8636`); death must be inferred from a stale badge. Stencil's squad
consensus machinery "is safe at n=2, pointless at n=2, and hard-breaks in the state BR
guarantees for fifteen of sixteen teams — the solo survivor" (BR_LADDER §5; the lone
survivor loops walking toward a phantom home). Recommendation there: `SquadCommand=0`
for BR MVP, replaced by `partner_support` + `partner_regroup`.

### 4.4 The app-side BR (coworld-paintbot-player branches)

Mode is a **config choice, one binary**: `MODES=["br","ctf"]`, `DEFAULT_MODE="br"`,
`practiceConfigFor(mode)` → `config.practice.br.json` (brMode:true, teams:16, lives:1)
vs `config.practice.ctf.json` (`br-32seat:server/engine.mjs:122-124`). BR = 32 seats
(`MAX_SEATS_BY_MODE`, `br-32seat:server/lobby.mjs`). No drop phase — pre-round is:
mode pick on the landing page → `startWaitTicks:0` (countdown removed, `c3caefe`) →
spawn. BR seat-pick skips the engine's respawn-ranked `/takeover/seat` (backwards for
lives:1) and uses local team balance (`850ce6c`). ⚠️ 32-seat walk-on measured 7.4–14 s
vs a <5 s bar — "NOT SAFE FOR THE DEMO AS-IS" (`64bf653`).

### 4.5 BR_LADDER.md — the proposed stencil-BR ladder

Proposed order (§4): `clear_grenade`, `clear_spray`, `zone_escape`, `fall_back`,
`fetch_medkit`, `zone_rotate`, `partner_support`, `partner_regroup`, `fetch_item`,
`zone_forecast`, `third_party`, `hold_zone_ground`, `seek_survivors`. Load-bearing
conclusions: a kill pays nothing directly, so an even trade is strictly negative;
13th–16th pay zero, so "the first job of the policy is simply not to be in it";
`zone_rotate` promoted above item fetching. §6 (authorability): six goal-source
combinators (`Fixed`, `Track`, `Radial`, `ScoredLocal`, `ScoredRegion`, `Interp`)
cover all 14 existing goal producers; "No rung in the BR ladder needs a seventh
combinator"; two enabling refactors — the local ring scorer takes its weight vector as
a parameter (`strategy.nim:248-249`) and the threat-track filter takes a predicate
(`strategy.nim:168-170`). **§6.5 sketches the YAML "playbook page" scoring model where
argmax over `baseWeight + Σ modifiers` reduces exactly to first-match-wins at default
weights** — the direct intellectual ancestor of the Season 2 shell. §7 preconditions:
see §7.9 below.

---

## 5. Reflash + onepage — the mid-episode page channel (coworld-ctf branches)

Build-on branch: **`origin/maxwell/br-reflash-integration`** (298 commits ahead; the
only tree with both halves of the wire plus a live round-trip proof).
`br-policy-reflash-replay` is a strict ancestor (the replay/gate lane only).

### 5.1 The wire

- **Magic:** `const PolicyPageMagic* = "CTFPOLICYPAGE1\n"` —
  `origin/maxwell/br-reflash-integration:src/ctf/labels.nim:602`. Rides the existing
  `0x86` debug-sprite blob opcode. The leading byte `'C'` (0x43) is load-bearing:
  sprite packet opcodes are 0x01..0x06, so no legitimate overlay packet can begin with
  the magic (`labels.nim:618-627`). It is a wire prefix, **not** a sprite label — must
  never enter `PolicyScannedLabels` or `tests/label_manifest.txt` (`labels.nim:628-636`).
- **Send (bot):** `proposeReflash` (`players/onepage/onepage.nim:1315-1339`) —
  magic + page bytes verbatim via `blobFromSpriteDebugSprites`. Contract doc at
  `onepage.nim:1242-1252`.
- **Receive (server):** `isPolicyPagePacket*` / `policyPageFromPacket*`
  (`src/ctf/global.nim:2001-2023`; strictly-longer-than-magic check), a sixth
  out-param `policyPage` on `applyPlayerViewerMessage*` (`global.nim:2025-2053` — all
  four call sites deliberately broken rather than overloaded).
- **Inbox → tick boundary:** `policyPageFlashes: Table[WebSocket, string]`
  (`server.nim:86-93`), parked at `:1516-1525`, drained in the tick loop pre-step at
  `server.nim:2327-2344`, calling `applyPolicyPage` then
  `replayWriter.writePolicyPageFlash`.

### 5.2 The gate, the record, determinism

- **Gate:** `config.allowPolicyReflash`, default `false` (`sim_config.nim:63`; field
  doc `sim_types.nim:1693` "Season 2 one-page policy…"). Echoed into the replay header
  only when true (`sim_config.nim:1078-1079`); replay format version deliberately not
  bumped (strict-equality codec outside the repo, `sim_config.nim:1074-1077`).
- **Acceptance is deliberately minimal** — `applyPolicyPage*`
  (`sim_state.nim:347-385`): gate on, index in range, `0 < len ≤ MaxPolicyPageBytes`.
  No phase/alive/cooldown checks: "every extra clause here is another way for the live
  server and playback to reach different verdicts."
  `MaxPolicyPageBytes* = 60000` (`sim_types.nim:823-831`) — bounded by the record's
  uint16 length prefix; a bigger page would be applied live but unwritable, "an
  applied-but-unrecorded input, the single outcome determinism cannot survive."
- **Replay record:** rides the chat record with the player high bit set
  (`ReplayReflashRecordFlag* = 0x80'u8`, mask `0x3f`, `replays.nim:272-283`); body =
  16-hex FNV-1a-64 content hash + `' '` + page (`replays.nim:293-305`); decode
  verifies the hash (`:307-326`); playback re-applies at the identical tick and treats
  refusal as **fatal** (`replays.nim:582-602`).
- **gameHash:** mixes `policyPageHash` **and** `policyPageEpoch` behind the gate
  (`sim_state.nim:296-306`). The epoch exists because re-flashing the *same* page —
  "exactly the case an LLM produces most, reasserting the current plan" — would
  otherwise replay clean with a dropped record (`sim_types.nim:1900-1908`).
- **Bot-side swap boundary:** `T_effect = T_req + max(1, fireWindupRemaining_at_T_req)`
  (`onepage.nim:1299-1313`), computed once. `applyPolicyPage` server-side is
  bookkeeping only; only the bot process turns a new page into different buttons
  (`onepage.nim:1224-1240`). The episode-*start* page also goes through the propose
  path (tick-1 on-wire flash, `onepage.nim:1206-1222`, `:1504-1512`) so the starting
  page is not a hidden replay input; until it lands, all intents score 0 → deterministic
  fallback to `ROTATE_TO_RING`.

### 5.3 Tests and the live proof

`tests/test_policy_reflash.nim` (562 lines, in `shard_4`): four suites — record can
never be read as a shout; the gate is real (gate-off adds no byte; same-page reflash
still distinguishable; 7 archived fixtures still clean); bit-identical re-simulation
with **two negative controls** (drop the reflash records → diverges; shift them one
tick → diverges); wire discrimination (8 tests incl. bare-magic stays on overlay path,
oversize arrives verbatim and is refused at the drain). Live harness:
`tools/roundtrip_reflash_match.sh` + `tools/verify_reflash_roundtrip.nim` — a real
16-duo match, seat 0 = onepage, page file rewritten twice mid-episode, plus a GATE=off
control ("Gate on: 3 records. Gate off, everything else identical: 0"). The verifier
refuses a replay with zero reflash records rather than passing vacuously
(`verify_reflash_roundtrip.nim:15-18`). Committed evidence in `rt/` on the branch.
House style: **every mechanism ships with a paired negative control**.

### 5.4 The onepage policy and the two page languages ⚠️

**The runner** (`br-onepage-runner`, carried into `br-reflash-integration`):
`players/onepage/onepage.nim` — replaces baseline's CTF tactics tree (~lines
1547–3310) while reusing its wire decode/nav/steering verbatim (reuse ledger in the
module header `:1-43`). Fixed 12-intent menu (enum `:146-161`; ratified page-facing
vocabulary `:975-992`):

```
ROTATE_TO_RING HOLD_RING_SAFE ENGAGE FINISH PEEL HEAL
LOOT REGROUP_PARTNER SUPPORT_PARTNER AVOID_FIGHT THIRD_PARTY USE_GRENADE
```

Each intent resolves to `Act = (moveMask, desiredAim, wantFire, holdC)` (`:163-171`)
→ `actToMask` (`:1359-1380`, byte-for-byte from `baseline.nim:3296-3309`). Page
loading: `COWORLD_POLICY_PAGE` (inline JSON) else `COWORLD_POLICY_PAGE_FILE` (path)
(`onepage.nim:1268-1278`). `CTF_BOT_FAST_READY` honored (`:1471-1478`);
`setStdIoUnbuffered()` (`:1534`) because block-buffered stdout silently hid log lines
a harness keyed on. **Mid-episode trigger is a stand-in**: `pollForNewPage`
(`:1341-1352`) re-reads the page file; its comment: the real trigger "is a different
lane's delivery mechanism."

**Language A — "rows" (proven on the wire):** the placeholder VM
`players/onepage/onepage/policy_stub.nim` —
`{"rows": {"<candidate>": {"bias": n, "weights": {"<path>": n}}}}`; argmax over
`bias + Σ weight·resolve(path)`, first-listed wins ties (`policy_stub.nim:131-133`,
`:165-169`); fails loud on unknown keys. Example pages in `rt/page_{a,b,c}.json`.

**Language B — "rules" (the real VM, better authoring, not wired to the runner):**
`origin/maxwell/br-onepage-vm:src/ctf/policy_page.nim` (620 lines, zero engine
imports) + `tests/test_policy_page.nim` + `tools/flash/`. JSON s-expression DSL
(`tools/flash/SCHEMA.md:52-67`):

```json
{ "paintbot_policy": 1, "name": "...", "traits": {"nerve": 0.4},
  "rules": [ {"when": true,
              "score": ["+", ["*", 30, ["get","intent.is_enemy"]],
                             ["*", -8, ["get","intent.exposure"]]]} ] }
```

Rules **sum, never branch** (`SCHEMA.md:88-118`); closed op whitelist
(`policy_page.nim:59-65`): `get trait + - * / min max abs clamp < <= > >= == and or
not` — **no `!=`**, `"if"` is a hard parse-time rejection anywhere
(`SCHEMA.md:239-245`); unknown `get` path → hard rejection with a Levenshtein
suggestion (`policy_page.nim:320-344`); pages intern by canonical-AST hash so 16 cogs
on one page compile once (`:450-476`). Key API: `parsePolicyPage` (`:260`),
`validate` (`:407`), `IntentContext` with resolver closures (`:427`), `compile`
(`:575`), `flash` (`:593`), `scoreIntent` (`:610`), `argmax` (`:618`).
`DefaultPaths` (`:135-208`) is resolver-backed after `7811c57`. Author-facing traps:
several `world.*` distances use **-1 = "never observed"** (a naive weight silently
inverts sign, `:158-164`); `self.placement`/`self.score` deliberately absent
mid-episode (`:148-156`); `intent.is_peel` name-collides with the Glory PEEL deed and
means something unrelated (`:187-193`).

**The three-layer ruling** (Maxwell's, `SCHEMA.md:15-48`): STRATEGY = the page (no
code); INTENT = a fixed named menu the engine offers each tick, which the page only
*scores*; ACTION = engine-resolved, never visible to the page. "A strategy that tries
to name a specific enemy or a specific pickup is a malformed strategy — there is no
path for it, so it cannot be expressed."

**`tools/flash/` — the LLM authoring loop:** `flash author "<brief>" [--model
claude|gemini|xai]`, `flash validate <file>`, `flash lint <dir>`; author retries with
validation errors appended until valid — "an invalid page never reaches disk"
(`tools/flash/flash.nim:1-21`; keys `CLAUDE_KEY`/`GEMINI_KEY`/`XAI_KEY` `:64-68`;
prompt `tools/flash/prompt.md` with `{{SCHEMA}}` substitution; six seed strategies in
`tools/flash/playbook/`).

⚠️ **Unreconciled:** the reflash round-trip was verified against the `rows` form; the
`rules` VM has the authoring loop and validation. `onepage.nim:28-36` names the swap
as pending; `SCHEMA.md`'s §3 path catalog is already stale vs `7811c57`'s
`DefaultPaths` (e.g. SCHEMA lists `self.in_ring`/`intent.exposure`; landed paths are
`world.in_zone`/`world.zone_dist`/`intent.target_dist`). **Whichever branch you build
on decides your page language; reconciling them is unclaimed work.**

### 5.5 `s2-takeover-shout` — what it is and isn't

The *human-seat* lane (9 commits): takeover tickets, lock-free frame watchdog,
freeplay configs, `docs/SEAT_TAKEOVER.md`. Relevant piece: `277193b` makes a takeover
seat's shout resolve to the **driven cog's** index before `applyShout`/`writeChat` —
"same cog index, same replay record, same hash chain a policy's own shout would have
produced" (gated on `allowSeatTakeover`). `SEAT_TAKEOVER.md:110-120`: Season 2 pings
ride the shout. Operational gotchas: `fastMode` must be off for humans; binaries named
`freeplay-*` because the shared dev box pkills `bin/ctf-server`
(`SEAT_TAKEOVER.md:98-106`). **No pre-round lobby-chat surface exists on any engine
branch** — in-match messaging is 10-char shouts + `allowCallouts` pings
(`!<id>[ <cell>]` parsing).

---

## 6. coworld-paintbot-player — lobby, matchd, pages, pre-round chat

### 6.1 Shape and one-origin architecture

Zero-dep Node ≥20, ESM, no framework/bundler. `npm start` = `node server/app.mjs`;
tests via `node --experimental-test-module-mocks --test test/*.test.mjs`
(`package.json:7-12`). The app owns `/`, `/play`, `/lobbies`, `/lobby/*`, `/match/*`,
`/api/*`, `/assets/*`, `/_app/*`; **everything else is proxied to the sim at the
identical path** (`server/app.mjs:92-107`, `server/proxy.mjs:1-8`; strips
x-frame-options, forces `frame-ancestors 'self'` for the match iframe,
`proxy.mjs:46-48`). Config env: `PAINTBOT_PORT` (7333), `PAINTBOT_ENGINE`,
`PAINTBOT_FIELD_SEATS`, `PAINTBOT_GAME_PORT_BASE` (2600), `PAINTBOT_SERVER_BIN`,
`PAINTBOT_POLICY_BIN_<NAME>`, etc. (`README.md:110-116`).

### 6.2 matchd (`server/matchd.mjs`)

One sim process per started lobby, keyed by `lobbyId` (`matchd.mjs:18`).
`startMatch(lobby)` (`:188-258`): build runtime config → write
`.run/<lobbyId>/config.json` → spawn the vendored `ctf-server` with **only**
`COGAME_HOST`/`COGAME_PORT`/`COGAME_CONFIG_URI` (`:203-212`) → TCP-poll for listener
(90 s) → seat every non-human slot via `spawnBot` with 60 ms stagger (`:234-238`) →
tail `sim.log` through `foldLine` (scoreboard is parsed from stdout narration —
`:55-159`; `TEAM_WIN_RE` covers the 16-name BR team vocabulary `:80-84`) → 15 s
re-seat sweep (`:243-254`). `spawnBot` (`:269-313`): a seat is just a websocket
client —
`COWORLD_PLAYER_WS_URL=ws://127.0.0.1:<port>/player?slot=<slot>&token=<token>`
(`:277`); respawn on exit up to 12 times unless a human holds the slot. Human
takeover on main = SIGTERM the bot, hand out the slot creds (`releaseSlot`/
`restoreSlot`, `:316-334`).

### 6.3 Lobby model (`server/lobby.mjs`)

Three indexes — **do not confuse**: `pos` (seat index in `lobby.seats[]`, UI-facing;
team = `TEAMS[pos % 2]` on main, `lobby.mjs:16-17`), `slot` (index into the engine's
compacted `tokens[]`/`slots[]` — `pos !== slot` whenever a seat is `closed`,
`lobby.mjs:177-186`), `token` (static `0xBADA55_N` from `config.practice.json`).
Seat: `{pos, team, kind ∈ human|policy|filler|closed, build, label, claimed,
claimKey}` (`:23-33`, `SEAT_KINDS` `:11`). Lobby: `{id (6 hex), name, status ∈
draft|live|final, seats[], match}` (`:37-44`). `buildRuntimeConfig` trims the static
16-wide roster, dedupes names (engine rejects duplicates), sets `minPlayers = n`,
`maxGames = 0` (`:151-188`). API routes all in `server/app.mjs:130-251` — join by
color (`POST /api/lobbies/:id/join`), seat editing (`PUT .../seats/:pos`), start
(`POST .../start`), human seat claim → iframe URL (`POST .../seat`), watch, end.
`/start` on main **blocks** until all bots are seated (`app.mjs:218-226`).

### 6.4 Page delivery (branch `maxwell/lobby-chat`; subset on `onepage-policy-wire`)

**Does not exist on main.** On the branches:

- `pageEnv(page)` (`lobby-chat:server/matchd.mjs`): string starting `{`/`[` →
  `COWORLD_POLICY_PAGE` (inline); otherwise → `COWORLD_POLICY_PAGE_FILE` (path).
  Merged into the bot's spawn env alongside `COWORLD_PLAYER_WS_URL`.
- Stored as `seat.page` (settable only for `policy`/`filler` kinds, reset on kind
  change), carried onto `assignment[i].page` by `buildRuntimeConfig`.
- **Delivered exactly once, at process spawn.** `preround.mjs:37-39`: "there is no
  live channel to hand a running bot a page decided after it already connected." This
  single constraint forces the whole deferred-boot sequencing.
- `resolveBotBin`: a *known* build with a missing binary throws loudly naming the
  path; unknown names still fall back silently to baseline. `enginePaths().bots`
  gains `onepage: players/onepage/onepage.out` — **a binary that does not exist in
  this repo's vendor tree yet** (`lobby-chat:server/engine.mjs`).

### 6.5 The pre-round chat phase (`lobby-chat:server/preround.mjs`, 466 lines)

⚠️ **Two corrections to Maxwell's message:** the doc is **`docs/preround-chat.md`**
(283 lines), not `lobby-chat.md` (that was the pre-rename name, commit `160ecbe` →
renamed in `747738c`; stale references survive in comments). And the Message field is
**`matchId`**, not `lobbyId` — it *holds* `lobby.id`, but readers must use the
`matchId` key (`preround-chat.md:127`, `preround.mjs:332`).

**Contract:**
- `POST /api/lobbies/:id/start` body `{"chat": true}`; omitting `chat` is
  byte-identical to pre-feature behavior. `GET /api/lobbies/:id/preround-chat` is
  poll-only; there is deliberately no POST for it (`preround-chat.md:162-174`).
- **Message** (`preround-chat.md:124-136`; built `preround.mjs:330-339`):
  `{id, matchId, tick: null, phase: "pre_round", from: {pos, slot, name, team},
  role: "assistant"|"system", text (≤500 chars), model, ts}`. Exactly one channel —
  no scope/scopeKey (asserted absent by `test/preround.test.mjs:77`).
- **Page** (`preround-chat.md:143-153`; built `preround.mjs:389-403`):
  `{pos, slot, tick: null, model, page (NEVER null), source, reason, ts}`.
  `source ∈ llm | fallback_no_key | fallback_timeout | fallback_invalid |
  fallback_error | fallback_unavailable` (`classifyFailure`, `preround.mjs:421-427`);
  every failure falls through to `defaultPageFallback` and ultimately an in-process
  constant (`:433-450`).
- **GET envelope:** `{matchId, status: idle|running|done, enabled, reason, startedAt,
  endedAt, budgetMs, messages[], pages[]}` (`preround-chat.md:178-190`).
- ⚠️ **`phase: "mid_episode"` is never emitted by any code.** Mid-episode chat is
  explicitly out of scope (it must ride the engine's proximity shout channel,
  `preround-chat.md:78-88`); mid-episode *pages* would be Page records with a real
  integer `tick` and no phase field. Maxwell's message describes the intended
  convergence, not shipped behavior.

**Bounds** (`preround.mjs:93-105`): `ROUNDS = 2` (hard ceiling 3),
`DEFAULT_BUDGET_MS = 30_000` (`PAINTBOT_PREROUND_CHAT_BUDGET_MS`),
`PER_CALL_TIMEOUT_MS = 12_000` (`PAINTBOT_PREROUND_CHAT_TURN_MS`),
`MAX_REPLY_CHARS = 500`, `PAGE_MAX_ATTEMPTS = 3`. Per-call timeout shrinks to the
remaining phase budget; timeout SIGKILLs the child (`:183-186`).

**Orchestration:** participants = every non-human seat (`:308`); strictly sequential
double loop over rounds × participants (`:366-374`); models round-robin
`["claude","gemini","xai"]` by slot (`:111`, `:328`) — no per-seat model field yet
(open question, `preround-chat.md:271-273`). Each turn spawns the
`tools/lobby_chat/lobby_chat` CLI once (subcommands `turn`/`page`/`default-page`,
request JSON on stdin, one JSON line back; fake CLI fixture at
`test/fixtures/fake_preround_chat_cli.mjs`). `historyFor()` returns **every**
assistant message so far — fully open, no team scoping (`:343-347`; pinned by
`test/preround.test.mjs:81-88`). The system prompt tells seats collusion is rational
because placement pays nothing below ~12th (`chatSystemPrompt`, `:216-228`). The page
prompt reuses **the engine's** `tools/flash/SCHEMA.md` + `prompt.md`, read live off a
`findEngineRoot()` checkout — deliberately not the vendored payload, which has never
carried `tools/` (`loadPagePromptTemplate`, `:230-248`).

**Sequencing (`finishBooting`)** — the key architectural change: with `chat:true`,
`startMatch` returns immediately; `match.booting` runs the chat, **re-reads the
assignment** (pages landed on seats during the phase), rewrites `assignment.json`,
then seats bots. Consequences stated honestly in the doc: the human's seat works
immediately; **bots are invisible during the chat** (a human attaching sees an empty
room — a real, only-partially-closed gap, `preround-chat.md:58-69`, whose closure
"needs a live page-reflash channel that does not exist"); late bot failures surface
via `lobbyView`'s `match.error` instead of failing `/start`
(`preround-chat.md:70-76`). Proven by `test/startmatch-deferred.test.mjs:60-81`.

**`recordMidEpisodePage`** — defined at `lobby-chat:server/preround.mjs:460-466`,
header comment "NOT wired to a caller yet" (`:452-458`). Verified: `git grep` across
every reachable commit finds the definition, two prose mentions, the pre-rename twins
— **and no caller, import, or test, anywhere in history**. Record shape:
`{pos, slot, tick: Number(tick), page, source, reason, ts}`.

**Persistence:** `.run/<lobbyId>/{config.json, assignment.json (written pre- and
post-chat), preround_chat.json, sim.log, bot_<slot>.log}`; `.run/` is gitignored.

### 6.6 Vendor and web surfaces

`vendor/` = the deployed sim payload: `bin/ctf-server` (3.5 MB Nim binary — built from
the `s2-controls @ 15eabee` + `live-renderer-hud` merge per `docs/glory-vendor.md:11-12`),
`players/baseline/baseline.out` (the only policy binary present),
`config.practice.json`, reference `client/` copies, sprite `data/`. Vendor rules
(`bin/vendor-engine.sh:8-27`): explicit lineage only, atomic staging, content-probe
the staged binary on a scratch port; macOS ad-hoc re-signing (`:173-181`) — a stale
signature is SIGKILLed at exec with no log line.

`web/` = five buildless pages (`index` landing with the hard-coded "Season 2" chip at
`web/index.html:6,68` + `web/app.js:39`; `play`, `lobbies`, `lobby`, `match`) +
`app.js`. Plug-in facts for a new surface: `/assets/` serving uses `path.basename` —
subdirectories under `web/` are unreachable (`app.mjs:124`); a new page needs a GET
route line (`app.mjs:110-127`) *and* an `APP_PAGES`/`APP_PREFIXES` entry
(`app.mjs:92-93`) or it gets proxied to the sim. The chat UI is anticipated on
`lobby.html`/`match.html` polling the preround-chat endpoint
(`preround-chat.md:169-171`). Docs on main: `relocating-the-sim.md`,
`near-field-transport.md` (the tailnet Mac deployment at `100.102.207.18:7420`),
`route-flip.md` (⚠️ notes `maxwell/s2-controls` is **superseded — do not vendor from
it**, `:122`), `glory-vendor.md`.

---

## 7. The stencil policy today (paintbot_lab)

Everything below is `paintbot_lab/paintbot/stencil_nim/` unless prefixed. Primary
sources: the code; **`docs/reports/stencil-policy-loop-2026-08-29.md`** (341 lines,
"the strategy-rework pre-read", commit `eac564fc`) — the authoritative body/mind
description; `docs/designs/nav-layer4-intent-contract-2026-08-13.md` — the
authoritative Intent contract.

### 7.1 Three nested loops

1. **Process loop** (`stencil.nim:38-99`): connect to `COWORLD_PLAYER_WS_URL`
   (fallback `COGAMES_ENGINE_WS_URL`, entry `:95-99`), NoDelay, send sprites-off,
   then per binary frame: `applyFrame` → `policy.decide` → send `inputBlob(mask)` (+
   chat blob if any; + ready blob under `STENCIL_FAST_READY=1`). "Tick" = decision
   per applied packet, not wall clock. `STENCIL_WIRE_RECORD` (`:10-28`) writes
   base64-JSONL wire captures — the corpus `tools/compare_stencil.py` replays.
2. **Per-episode WorldMap build**, data-triggered not lifecycle-triggered
   (`policy.nim:39-50`): walkability + `gameTeams` + **all endzones** present and a
   changed `(w,h,teams)` signature → `newWorldMap` (fixed pipeline: clearance field →
   8 px walkable grid → components → watershed rooms/chokepoints → 16-sector cover →
   home Dijkstra fields → scored post atlas; `worldmap.nim:173-209`).
3. **Per-tick pipeline** (`policy.nim:22-111`): perceive → seat bootstrap → fold
   (`updateBeliefCore`) → orient (roles/posts, only while `rolesAssigned == false`) →
   decide (`decideObjective`) → act (`resolveAction`) → chat (`chooseShout`, attached
   *after* action — leak #3).

Perception is memoryless (`perception.nim:1`, `perceive` `:308-390`); belief folding
owns all persistence (`belief_update.nim`).

### 7.2 The strategy ladder (`strategy.nim`) — the behavior catalog

`decideObjective*` (`strategy.nim:502-515`) is the **only exported decision**, called
from exactly one place (`policy.nim:101`): base ladder → arc-pursuit override →
idle-aim stamp. Pre-ladder side effects run every tick before any rung
(`strategy.nim:330-347`): spray-flee latch update, clearing the six
`squadOrderPost*` belief fields, the early-defense completion latch, and
`updateConsensus()`.

The ladder, first-match-wins, in code order (verified in source 2026-08-29):

| # | reason | line | trigger → goal |
|---|---|---|---|
| 0 | `no_worldmap` (Hold) | `:331-332` | `map.isNil` |
| 1 | `carry_home` | `:349-351` | carrying → `capturePoint(team)` |
| 2 | `intercept_thief` | `:353-355` | own heart stolen, thief seen |
| 3 | `intercept_thief_heard` | `:356-357` | shout-derived fix |
| 4 | `clear_grenade` | `:359-370` | grenade warning → radial escape |
| 5 | `clear_spray` | `:372-374` → `:221-309` | flee latch → scored 16-dir × 2-ring argmax |
| 6 | `barrage_center` | `:376-383` → `:112-138` | argmax over watershed room peaks |
| 7 | `early_defense` | `:385-392` | posture gate → per-seat defense post |
| 8 | `rejoin` / `rejoin_hold` | `:394-402` | squad rejoin point |
| 9 | `escort_carrier` | `:404-411` | Attacker + some carried heart |
| 10 | `escort_carrier_heard` | `:412-420` | dead-reckoned from shout fix |
| 11 | `fetch_medkit` | `:422-425` | convenient-detour medkit |
| 12 | `fetch_item` | `:426-429` | `evaluateFetch(anchor)` accepted |
| 13 | `convert_hunt` | `:431-437` | `wipeInReach` → weakest team |
| 14–16 | `squad_move`/`squad_to_watch`/`squad_to_hold` (+arrived/held) | `:461-476` | consensus order kinds `M`/`W`/`H` |
| 17 | `to_post` / `hold_post` | `:480-490` | Defender + atlas post |
| 18 | `to_hold` / `hold_line` | `:480-491` | Defender + geometric fallback |
| 19 | `hunt_fallback` | `:493-498` | no steal goal |
| 20 | `steal` | `:500` | default: planted heart else pedestal |

Post-ladder: **`arc_pursuit`** replaces the whole objective when spray-arc conditions
hold (`:504-514`); then `idleAimCenterBrads` is stamped (`:515`). **Validated-goal
contract** (`:107-110`): every candidate routes through `reachableGoal` →
`nearestReachable`; `none` → fall through to the next rung; a goal that cannot be
validated never becomes an Intent.

### 7.3 The typed Intent (`types.nim:189-219`)

```nim
IntentKind* = enum NavigateTo, Hold
CostProfileKind* = enum ProfileDefault, ProfileCarrier, ProfileHunter
MicroFlag* = enum MicroPeekDuck, MicroSeparation, MicroFormationBias,
                  MicroSprayPursuit, MicroStealRushExempt
Intent* = object
  kind*: IntentKind
  point*: Option[Point]
  idleAimCenterBrads*: Option[int]
  arriveRadius*: float
  reason*: string            # telemetry-only, grep-gated since v66
  movingGoal*: bool
  clampToEndzone*: bool
  suppressFireFreeze*: bool
  profile*: CostProfileKind
  micro*: set[MicroFlag]
Command* = object
  heldMask*: uint8
  chat*: string
```

Single producer: `makeIntent` (`strategy.nim:40-99`) — a `case reason` table mapping
every reason string to its flag set (the centralized behavior→Intent-shape mapping; a
full per-reason table is in the lab recon and Appendix B of the body/mind report).
Consumers: follower (kind/point/arriveRadius/movingGoal/profile), micro layer
(micro+kind), combat (suppressFireFreeze), endzone clamp, idle-aim branch.

### 7.4 The body (`action.nim`, `nav.nim`, `planner.nim`)

`resolveAction` (`action.nim:402-551`), fixed order: telemetry reset → early-out (no
self/worldmap → zero mask) → spray fire-freeze calc → peek-duck override → windup
freeze/arrival/progress → **corridor gate** (override destinations outside
`nav.withinCorridor` rejected and counted — v68's law) → movement (freeze | override |
`astarWaypoint` ± formation bias | Hold separation nudge) → combat overlay
(`selectTarget` → aim-with-lead → `fireGate` → mask) → idle aim (`idleSweepAim`) →
endzone clamp → grenade overlay → `Command`. Follower replans on exactly four
triggers (`nav.nim:67-84`); unroutable → hold, never a beeline (`:108-109`). Planner
is pure: 4 px lattice, 4→2→1 completeness cascade, cost = step × (1 + dangerWeight ×
LOS-danger); profiles Default 1.0 / Carrier 2.5 / Hunter 0.25 (`planner.nim:31-38`).

### 7.5 Existing scoring/argmax machinery — no framework, six hand-rolled sites

No shared Score/Utility abstraction exists. The six sites (shapes to imitate):
target selection `fight.nim:162-283` (richest: weighted sum + deterministic tie-break
chain + **hysteresis** — `FirefightTargetMinDwellTicks` + switch margin); post ranking
`worldmap.nim:792-861` (two-phase bounded utility, truncate-to-top-8); spray flee
`strategy.nim:221-309`; barrage room peak `strategy.nim:112-138`; item fetch
`items.nim:91-152` (threshold acceptance + reason strings); squad consensus
`squads.nim:314-349` (plurality + safety tie-break `H>W>M` + geometric medoid).
Shared pattern: normalized terms × `STENCIL_*` weights, deterministic tie-break,
validate winner, explicit fallback, components written to Belief for trace. **What
does not exist: any argmax over behaviors** — converting the ladder to one is
precisely the Season 2 shell's job, and the ladder order above is the baseline
behavior it must be able to reproduce.

### 7.6 The body/mind report's seven boundary leaks (§8, `stencil-policy-loop-2026-08-29.md:233-270`)

1. ~~Threat-axis idle aim~~ — **closed by v69** (commit `1215ff5e`: +1 Intent field,
   strategy stamps it, `action.nim` −31 lines; 278,016/278,016 exact decisions on a
   48-file wire corpus; uploaded inert as `stencil:v69`).
2. Post assignment lives in the orchestrator (`policy.nim:55-98`), outside the module
   deciding "am I defending."
3. Outbound chat bypasses the Intent contract — `chooseShout` is a second per-tick
   decision ladder attached after action resolution.
4. Strategy writes Belief mid-decision — latches, counters, and the squad-order post
   geometry that action later reads for stance/aim ("a real dataflow: mind → belief →
   body, invisible to the Intent").
5. WorldMap is not actually immutable — `updateHearts` writes pedestal positions into
   it every percept (`belief_update.nim:16-20`).
6. Action writes telemetry onto Belief (by design; Belief is also the body's
   scratchpad).
7. A stale module doc (`nav.nim:1` still says flow-field).

A shell design that assumes "Intent is the whole mind output" will be wrong at leaks
2, 3, and 4.

### 7.7 Live directives and hazards for the rework

- **Roles are condemned** (`WORKING_CONTEXT.md:131-144`, James-directed 2026-08-29):
  delete the `Role` enum, `roleForSeat`/`defenderCount` (`STENCIL_DEFENDERS`), and
  the whole `policy.nim:55-98` assignment block. Rungs 9/17/18 and
  `fight.nim:150-160,239,250` are role-keyed. "How attack/defense posture is chosen
  dynamically instead … is THE central design question of the rework, not decided
  here."
- **Staleness becomes explicit strategy policy** (`WORKING_CONTEXT.md:151-165`):
  today staleness is exactly two triggers; nothing re-scores a post.
- **The argmax-conversion hazard #1:** several rungs and the pre-ladder block mutate
  Belief *as they evaluate/fire* (`converting` `:434-438`, `squadOrderPost*`
  `:448-455`, latches, ~8 counters). An argmax that evaluates every behavior fires
  every side effect. This rhymes exactly with the fresh lesson at
  `TENTATIVE_LESSONS.md:20-26` (a value mutated by being read; eager evaluation of a
  formerly-lazy value silently changes behavior).
- **Dead ticks bypass strategy** — `policy.nim:103` hand-builds a `not_alive` Hold
  intent and `resolveAction` still runs; any new Intent field must be stamped there
  too (`TENTATIVE_LESSONS.md:28-32`).
- **A scored selector needs hysteresis** or it will flicker where the priority ladder
  never did — `fight.nim`'s dwell/margin pattern is the in-house precedent.
- Replay comparisons must reproduce capture-time `STENCIL_*` env
  (`TENTATIVE_LESSONS.md:33-39`); same-seed self-play is timing-nondeterministic —
  the recorded-wire comparator is the only deterministic instrument (`:40-47`).

### 7.8 Lab validation, config, and process conventions

- **Determinism is the acceptance test**: `tools/compare_stencil.py` replays captured
  wire JSONL through a compiled `replay.nim` and requires exact mask+chat output. An
  LLM in the loop breaks bit-reproducibility unless the script/page is frozen
  per-episode (or per-flash) and the shell is deterministic given the page — **where
  the nondeterminism boundary sits is a design decision the lab's whole validation
  apparatus depends on.** (Note the engine's reflash work answers this for the
  *hosted* replay: pages are recorded inputs, §5.2.)
- **Config discipline:** 152 `STENCIL_*` knobs in `config.nim`, min/max-validated,
  **raising at process start** on bad values (`config.nim:7-51`); `self_play.py`
  refuses non-`STENCIL_*` env overrides (`tools/self_play.py:33-42`). A page is
  config-shaped and should expect the same fail-loud treatment.
- **Local tooling:** `tools/self_play.py` (fetches the exact live-canonical game
  commit into `.cache/`, native processes, `--record-wire`), `tools/render_nav.py`,
  `tools/render_topology.py` (era-gated), `tools/viewer.html`, committed property
  harnesses `tools/nav_v67_properties.nim` / `nav_v68_properties.nim` (the precedent
  for how this lab writes tests). Build/upload: `tools/build_player.sh stencil`
  (pins the game's `nimby.lock` from GitHub, `Dockerfile:33-36`;
  `tools/versions.env` = game pin ledger, currently 0.7.215/`6c7a4c0e`, canonical
  live is 0.7.242 — the pin goes stale unattended).
- **The change ritual** (v69 = the complete recent worked example): recon doc →
  design doc (Codex-reviewed) → implement → parity/property evidence → upload inert
  with `purpose=` tag → prereg JSON in `local_data/episodes/` → matched hosted A/B →
  `VERSION_LOG.md` entry (2,327 lines, append-only) → docs reconciled in the same
  commit.
- **Root conventions** (`personal_paintbot/AGENTS.md`): speed is the meta-priority
  ("the hosted evaluation IS the test"); uploading is routine and ungated; **league
  submission is the human's gate**; **propose-and-pause** — don't auto-chain into
  unrequested strategy/gameplay work; change one component per version; keep tunables
  in config, separate from logic. Also `best_practices.md` (game-agnostic rigor) and
  lab-local `paintbot_lab/best_practices.md` (no module-level map caches; the wire is
  the only map source; verify against the deployed game version).

### 7.9 Why stencil can't field BR yet (BR_LADDER §7, condensed)

- `Team` enum has 4 values (BR needs 16).
- `WorldMap` build requires perceiving endzones; BR maps emit none → `no_worldmap`
  Hold for the whole episode.
- `seatsPerTeam` resolves to 4 for a duo.
- The zone (`zone`/`zonenext` frame markers) is not perceived at all.
- Lives read `x0` for a healthy BR cog ("3hp x0").
- Squad consensus hard-breaks for the solo survivor (§4.3 above).

---

## 8. How the pieces connect — the seams (facts, not design)

### 8.1 The paradigm's existing statements

Three independent artifacts already state the "score the sub-goals, argmax, emit an
Intent" idea:
1. `tools/flash/SCHEMA.md:15-48` — Maxwell's three-layer ruling
   (STRATEGY/INTENT/ACTION) and the 12-intent BR menu (§5.4).
2. `BR_LADDER.md` §6.5 — the "playbook page" model over the *stencil* rung ladder,
   with the reduction-to-priority-ladder property and the two enabling refactors
   named (§4.5).
3. The paintball directive pipeline on main — a closed intent enum + deterministic
   compiler, LLM above, engine below (§3.6).

The Season 2 shell as described by James is the union: stencil's body + a
page-scored selection over rung-like behaviors + the reflash channel + the pre-round
chat. Each ingredient exists; no artifact yet combines them.

### 8.2 The unbuilt seams (verified gaps)

| Seam | State | Anchor |
|---|---|---|
| Mid-episode page delivery from an LLM service to a running bot | Unbuilt on both sides, by design | `pollForNewPage` stand-in (`onepage.nim:1341-1352`); `recordMidEpisodePage` uncalled (`preround.mjs:460-466`) |
| The two page languages (`rows` vs `rules`) | Unreconciled; swap named as pending | `onepage.nim:28-36`; §5.4 |
| The `onepage` bot binary in the app's vendor tree | Referenced, absent | `lobby-chat:server/engine.mjs` |
| Pre-round chat UI (transcript rendering) | Endpoint shipped, UI anticipated not built | `preround-chat.md:169-171` |
| `phase: "mid_episode"` records | Aspirational — no emitter | §6.5 |
| Stencil on a BR field | Blocked by §7.9 preconditions | BR_LADDER §7 |
| Whether the starting page needs an on-wire flash at connect (vs env-only) | Answered engine-side (tick-1 flash, `de03e4c`) but flagged as an open question app-side | `preround-chat.md:90-114`; `onepage.nim:1206-1222` |
| BR merge to main (both repos) | 0 merged; `br-integrate` +253; conflicts expected in `sim_types.nim`/`wire_constants.nim` vs GV47 | §2, `REVIEW.md` §7.2 |
| app-side branch bases (`lobby-chat` off main vs BR family off `8e63fce…`) | Will conflict in matchd/lobby/engine/app | §2.2 |

### 8.3 Timing/cadence facts that bound any design

- Pre-round chat: ≤30 s phase, ≤12 s/turn, 2 rounds, ≤500 chars/message, sequential
  (§6.5). Pages delivered once at spawn; bots invisible during the phase.
- In-match chat: 10 chars, 1/s, 247 px radius, Playing-phase only, hashed into
  determinism (§3.3).
- Reflash: ≤60,000 bytes/page, applied at tick boundary, effect at
  `T_req + max(1, windup)`, epoch-counted, gate default off (§5.2).
- BR clock: 6,000 ticks @ 24 tps (~4 min 10 s); zone harmless until tick 3528; from
  then, rotation windows are 528 → 180 ticks (§4.1).
- Paintball precedent cadence: a directive every `turnTicks:108` (~4.5 s) under
  `turnBudgetMs:10000` with `turnSpacingMs:5000` (§3.5–3.6).

---

## 9. Corrections to Maxwell's onboarding message

| Claim | Verdict |
|---|---|
| `server.nim:185` staticReads `client/player_client.html` | ✅ on the BR branches; ❌ on main (line 185 is `MaxWsFrameBytes`); main has no player client at all |
| Vendored copy drifted "588 vs 707 lines" | Direction right, numbers stale: **335** vendored vs **707** (`br-onepage-runner`) / **808** (`br-team-outline`) |
| "bin/vendor-engine.sh:160-172 says it outright" | ✅ (actual range 159-171) |
| `maxwell/br-team-outline`: own-team outlines, zero wire/sim change | ✅ exactly as described (3 commits, 1 file, +101, render-only) |
| Chat contract in `docs/lobby-chat.md` | File renamed: **`docs/preround-chat.md`** |
| Message record has `lobbyId` | Field is **`matchId`** (holds the lobby id) |
| `phase` is `"pre_round"` or `"mid_episode"` | Only `"pre_round"` is ever emitted; `"mid_episode"` is intended, not implemented |
| Page is never null | ✅ (`preround.mjs:405-407`) |
| `recordMidEpisodePage` exists, uncalled | ✅ verified across full history |
| Pages by env var at spawn; per-call + whole-phase timeouts; fallback with reason | ✅ (§6.4–6.5) |
| Pre-round fully open; mid-episode rides shout, ~MapWidth/5, Playing-only | ✅ all verified (§3.3, §6.5) |

---

## 10. Unresolved

- **The hosted platform's mid-episode delivery path**: how a page produced *outside*
  the game container would reach a running hosted bot on the real Coworld platform
  (as opposed to the local paintbot-player app) is not specified anywhere read. The
  paintball precedent keeps the LLM *inside* the game container for exactly the
  secrets/determinism reasons in §3.6 — whether S2 follows that or the
  app-orchestrated model is an open architecture fork, not resolvable from source.
- **BR league/manifest final shape**: `coworld_manifest_br.json` exists on
  `br-manifest` but was not read in depth; certification gates for BR
  (`BR_MAPGEN.md` §3) are designed but the corpus to calibrate them doesn't exist yet.
- **Whether `attacksMade` increments on any shot or only a resolved one** —
  BR_LADDER's own top uncertainty ("one grep"); not resolved in this recon.
- **Glory-vs-placement for BR v1** (`REVIEW.md` §7.1) — open decision, Maxwell's.
- **Maxwell's full-screen Season 2 preview** — announced in his message, not yet
  delivered; the front-end surfaces read here are the current state, not the preview.

---

## 11. Reading list (fastest path per topic)

**Before designing the shell:**
1. `paintbot_lab/docs/reports/stencil-policy-loop-2026-08-29.md` — body/mind today.
2. `origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md` — the BR ladder +
   playbook-page sketch (§6) + stencil preconditions (§7).
3. `origin/maxwell/br-onepage-vm:tools/flash/SCHEMA.md` + `src/ctf/policy_page.nim`
   — the page language with the authoring loop.
4. `docs/paintball/plans/2026-08-25-paintball-design.md` (main) +
   `src/ctf/{decide,directives,control,llm}.nim` — the shipped LLM-mode precedent
   and its scar tissue.

**Before touching the wire:** `origin/maxwell/br-reflash-integration:src/ctf/labels.nim:602-636`,
`tests/test_policy_reflash.nim`, `tools/verify_reflash_roundtrip.nim`,
`players/onepage/onepage.nim` header + `:1206-1352`.

**Before touching the app:** `server/matchd.mjs:188-313`,
`origin/maxwell/lobby-chat:docs/preround-chat.md` (all 283 lines),
`origin/maxwell/lobby-chat:server/preround.mjs`.

**Before touching BR:** `origin/maxwell/br-review-doc:REVIEW.md`, then
`origin/maxwell/ladder-scout-tooling:docs/designs/BR_MAPGEN.md`, then the BR sections
of `docs/RULES.md` on `br-integrate`.

**Before touching stencil:** `paintbot_lab/WORKING_CONTEXT.md:111-172`,
`paintbot_lab/TENTATIVE_LESSONS.md`, `docs/designs/nav-layer4-intent-contract-2026-08-13.md`,
`strategy.nim`, `types.nim:189-219`, and the v69 commit `1215ff5e` as the worked
example of a mind/body move done right.

---

## 12. Files read (full or significant section)

Main-agent verification reads: `strategy.nim:329-360,502-516` (lab);
`vendor/client/player_client.html` + branch copies (line counts);
`origin/maxwell/br-reflash-integration:src/ctf/labels.nim:600-604`;
`origin/maxwell/br-onepage-vm:src/ctf/policy_page.nim:59-65`;
`origin/maxwell/lobby-chat:server/preround.mjs:452-466`.

Subagent full/deep reads (five parallel Explore agents, 2026-08-29): coworld-ctf —
`README.md`, `AGENTS.md`, `docs/RULES.md`, `docs/PROTOCOL.md`, `docs/paintball/*`,
`src/ctf/{server,sim,sim_types,sim_config,sim_state,decide,directives,control,llm,mux,replays,labels,global}.nim`
(relevant sections), `src/paintball_player.nim`, `coworld_manifest_paintbot.json`,
branch files via `git show` on `br-reflash-integration`, `br-policy-reflash-replay`,
`br-onepage-runner`, `br-onepage-vm`, `br-team-outline`, `s2-takeover-shout`,
`br-ladder-design`, `br-review-doc`, `ladder-scout-tooling`, `br-day-one-reads`,
`br-integrate` (+ family); coworld-paintbot-player — all of `server/`, `bin/`,
`web/`, `docs/`, `vendor/` inventory, and the `lobby-chat`/`onepage-policy-wire`/
`br-32seat`/`round-splash-and-br-pick`/landing branches; paintbot_lab — all of
`stencil_nim/` (policy, strategy, types, action, nav, planner, fight, items, squads,
belief_update, perception, worldmap, config, stencil), `docs/` (reports, designs,
recon, audits), `WORKING_CONTEXT.md`, `TENTATIVE_LESSONS.md`, `VERSION_LOG.md`,
`tools/`, and the personal_paintbot root docs.
