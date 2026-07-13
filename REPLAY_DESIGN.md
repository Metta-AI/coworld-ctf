# REPLAY_DESIGN — Ctf

> Companion artifacts: `DEPTH_TARGET.md` (Phase 0r) + `REPLAY_BRIEF.md` (Phase 0 engine-traced brief +
> fidelity audit). This file is the Phase-2 unlock; the Phase-4 battery grades the build against it.

## 1. PLATFORM + ARCHETYPE

Platform **A-plumbing, third-shape**: self-hosted Nim+mummy server (`src/ctf/server.nim`) serving
`/client/replay` + `/replay` WS on the bitworld engine (Crewrift fork). Archetype **#1 spatial arena**
(8v8 CTF shooter, drama on a map). Job = **ELEVATE-BY-REBUILD (L47)**: today the replay routes serve
bitworld's generic `global_client.html`, embedded at COMPILE time (`bitworldClient.serveClientFile`,
server.nim:560–569; `staticRead` in `~/.nimby/pkgs/bitworld/src/bitworld/client.nim:38`).

**Locked architecture (the thin-client split):**
- The **server sprite stream stays the BOARD renderer** — it already draws arena, team-tinted players,
  flags, tracers, splatters, sound rings, aim lines, fog POV. Replay-mode-only observation building may
  be elevated; the LIVE `/global` and `/player` paths stay byte-identical (rendering is outside
  `gameHash`, so determinism/replay hashes are untouched).
- A **new designed broadcast client** `client/replay_broadcast.html` lives in THIS repo, `staticRead`
  into `server.nim`, served for `ReplayClientRoute`/`CoworldReplayClientRoute` instead of bitworld's
  generic client. Single self-contained file (all assets inline, L13).
- A **JSON state channel**: the server sends a TextMessage frame alongside the binary sprite blobs to
  replay viewers (tick, maxTicks, phase, team lives, flag states + carriers, per-player roster
  K/D/lives/HP, beat events, winner/isDraw/timeLimitReached, playback speed/playing). Binary = board;
  text = chrome. No bitworld fork.
- **Transport**: DOM controls send the existing chat-char commands (replays.nim:326–370); scrub-to-tick
  + POV-select added as ctf-side text commands (`s:<tick>`, `v:<slot>`) parsed where replayCommands are
  drained (server.nim:1021). Legacy server-drawn replay HUD layers (84×5 scrubber, 20px panels,
  scoreboard) are dropped from REPLAY-mode packets only — the DOM chrome replaces them.

PRODUCT_SCOPE: replay

## 2. REAL CONTAINER TARGET

Measured from `CoworldReplayFrame.tsx` + usage sites (not assumed): League Featured Match
(`LeagueDetail.tsx:1876`) = `aspect-video min-h-[320px] w-full` at detail-column width with
`height="auto"`; Episode detail = `min(680px,72vh)`/420px; standalone defaults `min(900px,88vh)`/360px →
**effective desktop aspects ~1.5 and ~1.9**, floor **640×360**. **Phone / narrow middle column ≈390px
wide → the box goes PORTRAIT ~0.5:1** — the layout must REFLOW to a stacked portrait arrangement
(scorebug band → board → feed/transport), not letterbox a landscape stage (L88). Iframe sandbox =
`allow-scripts allow-same-origin`, no CDN reachable. QA at ~1.5, ~1.9, 640×360, and ≈390×780.

## 3. ART-DIRECTION LOCK

**One sentence:** a retro pixel arena-shooter broadcast — warm CRT-phosphor pixel action on a warm-dark
broadcast stage, NES pixel type for every number, the two team colors the only saturated channels, amber
for drama.

Palette (warm, never pure #000): stage `#16110d` vignetting to `#241a12`; light text/paper `#f2e8d8`;
structural ink `#2a1f16` (the brand line — all strokes/shadows warm-dark, L31); team vermillion
`#e0523a` / team cerulean `#3f7cc4`; drama amber `#e8a33d`; ghost/fog `#8a7f72`. Framing: the arena
canvas full-bleed center-stage with a soft light pool on the board (L32 — focus, not a literal set);
chrome floats in reserved bands. Type: `nes-pixel.ttf` (already in repo, `data/atlas/nes-pixel.ttf`,
vendored as data-URI) for display + numbers; system sans only for fine print. Register: **broadcast
scorebug** (competition/arena, L23).

## 4. PER-ENTITY PALETTE

Grounded in the engine's own palette (`data/pallete.png`, team tints applied in
`buildSpriteProtocolActorSprite`) + the CTF broadcast grammar (TagPro/Halo research): **Red team**
vermillion `#e0523a`, home = LEFT, reads first in every pairing; **Blue team** cerulean `#3f7cc4`, home
= RIGHT; **carrier** = the highlighted actor — persistent amber aura + flag riding the sprite (TagPro
carrier-outline convention); **flags** = pure team color at full saturation (the most saturated thing on
the board); **pedestals** neutral warm stone, glow when flag home; **capture zones** team-tinted edge
washes; **dead/ghost** desaturated `#8a7f72`, splatters dark warm rust; **tracers** hot white-amber
flash fading to team tint; **sound rings** low-alpha paper; **spawn protection** cool shimmer; **the
viewer's slots** marked with a paper chevron. Exact pixel values sampled from `pallete.png` in Phase 1
so chrome matches board.

## 5. RANKED BEAT → SURFACE

| Beat (engine-traced, REPLAY_BRIEF) | Spectator surface that stages it |
|---|---|
| CAPTURE (ends game) → | capture-zone floods team color on board + full-width CURTAIN banner + hold → end-card transition |
| WIPE / final kill → | kill-feed row at curtain weight + "TEAM WIPED" banner → end-card |
| FLAG STEAL → | scorebug flag icon flips HOME→TAKEN with pulse + banner chip "RED FLAG TAKEN" + carrier aura begins + scrubber marker |
| CARRIER KILL + FLAG RETURN (composite) → | feed row marked ⚑ + flag icon flips back with settle pulse + banner chip "FLAG RETURNED" |
| KILL → | kill-feed row (killer ▸ glyph ▸ victim, team-colored; TEAM-KILL badge; same-tick trade renders both rows) + victim lives pip dims + scrubber marker |
| RESPAWN → | board rematerialize + protection shimmer (engine 24 ticks); roster row un-dims |
| PHASE Lobby→Playing → | countdown treatment from engine "game starting in N" |
| GAME OVER verdict → | end-card: plain-language HOW (capture / wipe / tiebreak NAMING the key + values / draw kind), final roster with +100s applied, momentum ribbon, hold forever |

## 6. ART MANIFEST + PROVENANCE

ART_PROVENANCE: mixed · **COUNT: 46 wired subjects**

**Existing (server/board — source paths in this repo):** engine sprite sheet `data/spritesheet.aseprite`
(16 team-tinted crew sprites incl. facing/carry), palette `data/pallete.png`, flags + pedestals + self
markers + splatters + tracers + sound-ring + aim-dot + fog overlay sprites (drawn in
`src/ctf/global.nim`), procedural arena map (`src/ctf/sim.nim` arenaCtfMap), wordmark `data/logo.png`,
fonts `data/atlas/nes-pixel.ttf` + tiny5. ≈18 board subjects reused as-is.

**Generated/authored for the chrome (28):** 1 stage backdrop texture (nanobanana prompt: "warm-dark
broadcast stage backdrop, subtle CRT phosphor grain and vignette, deep warm brown-black #16110d to
#241a12, no objects, no text"), 1 board light-pool overlay, 2 scorebug team plates (SVG, ink-stroked),
4 flag-state icons (home/taken × red/blue, SVG pixel-style), 1 clock pill, 2 lives-pip states,
3 kill-feed glyphs (frag / team-kill / mutual-trade), 3 banner chips (steal/return/wipe), 1 capture
curtain, 1 end-card frame, 4 verdict badges (capture/wipe/tiebreak/draw), 7 transport icons
(play/pause/restart/back/+5s/end/loop), 1 speed chip strip, 3 scrubber beat-marker glyphs
(kill/steal/capture), 1 momentum ribbon style, 1 POV eye badge, 1 viewer-slot chevron. SVG/CSS authored
in the client file; raster only where texture demands (backdrop), everything inlined as data-URIs.

## 7. CHOREOGRAPHY GRAMMAR

Spatial-archetype grammar = interpolated locomotion → impact → objective consequence. **Locomotion is
engine-native**: the server streams every 24Hz tick of continuous movement (no sparse frames to lerp —
the sim IS the interpolation; L6 satisfied at the source). Chrome beats are staged sequences, each with
a read-hold, never a bare CSS fade:

- **KILL**: board tracer flash (engine) → feed row slides in from edge with overshoot → 250ms settle →
  victim's roster pip dims → row holds ≥2.4s at 1× before scroll-away.
- **STEAL**: flag lifts onto thief (board) → scorebug icon flip (3-frame pixel flip + pulse) → banner
  chip pops (overshoot → 60% hold → fade) → carrier aura persists until return/capture.
- **RETURN (composite with the kill)**: feed row ⚑ + flag arcs home on the scorebug icon → settle pulse.
- **CAPTURE**: zone flood (board) → curtain slams in (dim + card pop, 74%-hold like the reference
  curtain) → end-card crossfade.
- **RESPAWN**: shimmer for the engine's 24 protection ticks; roster row re-lights.
- **END-CARD**: dim → verdict line types on → roster finalizes with +100 counting up → holds forever.

## 8. HUD LIST + REGISTER

Register: **broadcast scorebug** (arena game). Panels, each in a **reserved slot** so the layout never
jumps on a quiet frame (L84):

1. **Top band scorebug**: team plates (name, TEAM LIVES aggregate — the real tiebreak currency, F1 —
   as pips+numeral, flag-state icon), center clock pill counting to `config.maxTicks` tiebreak (F3,
   honest label "TIEBREAK IN M:SS") + phase.
2. **Kill feed**: top-right column, fixed 4-row reserve, team-colored rows.
3. **Banner lane**: one reserved center lane under the scorebug for beat chips (steal/return/wipe);
   capture uses the full curtain.
4. **Roster rails** (wide aspects only): 8 per side — name, lives pips, K/D, carrier/dead state; click →
   POV inspect (fog honesty lens, `v:<slot>`). Collapses into tap-roster on portrait.
5. **Transport**: bottom bar — play/pause, restart, −1 tick, +5s, end, loop, speed chips 1–16×, and a
   **click-to-seek scrubber** with beat markers + lives-differential **momentum ribbon** (L44); fully
   CLICKABLE (TF7), keyboard shortcuts mirrored.
6. **End-card** (owns the frame at GameOver).

**Bounded-embed plan (L82/L83)**: all chrome sizes derive from container queries / a `--hudscale`
computed off the iframe box, proportional to the CONTAINER not the viewport; verified in a repro of the
League box (`aspect-video min-h-[320px]` at detail-column width) and at the 640×360 floor; portrait
≈390px reflows to stacked scorebug → board → feed → transport with roster behind a tap-toggle.

## 9. PERSON/ROLE MODEL

Not applicable: team arena shooter — no hidden roles, no person-vs-card split. The only hidden
information is fog-of-war vision, handled as the POV-inspect lens (§8) and audited in §13/F5.

## 10. DRAMA-COMPLETE FIXTURE

Existing `tests/replays/ctf.bitreplay` expands to ZERO events (verified via `tools/expand_replay.nim`)
— cert fixture only, unusable. Phase 1 records real full-scale episodes: `COGAME_HOST=0.0.0.0
COGAME_PORT=2000 COGAME_CONFIG_URI=file://$PWD/config.json nim r src/ctf.nim` + 16 baseline bots
(`players/baseline`, `ws://localhost:2000/player?slot=$i&token=0xBADA55_$i`) with the replay writer on;
verify with expand_replay that ≥1 fixture covers Kill, FlagSteal, FlagReturnHome, Capture, Respawn,
PhaseChanged, ScoreChanged, GameOver-by-capture (re-seed/re-run until a capture ending lands; baseline
bots are built to convert steals into captures). Additionally record a `maxTicks:300` short-config
fixture to exercise the TIEBREAK/draw end-card (certification config proves 300 works), and keep a
wipe-ending fixture if one occurs. Every §5 beat exercised ≥1× across the fixture set (PD7).

## 11. TEMPO + AMBIENT PLAN

Both levers, reference philosophy at shooter values: **animFactor cap** — chrome beat animations never
play faster than 2× no matter the replay speed (feed rows, icon flips, banners keep read time at 8–16×);
**dwell floor** — beat holds have minima (feed row ≥2.4s-equivalent, banner ≥1.8s, curtain ≥2.4s,
READ_PAUSE ≥600ms) and speed collapses only the dead time between contacts (both flags home, no
tracers). Board tempo is the engine's own 24Hz. **Ambient life** (idle systems, paused under beats,
`prefers-reduced-motion` honored): pedestal glow breathe, capture-zone low wash pulse, scorebug leader
pulse when lives lead ≥3, CRT grain drift on the stage backdrop, clock pill soft tick. The 16 moving
players ARE the board's life; ambient dresses the set only.

## 12. GENRE_RESEARCH

Researched this run (agent dispatch): **TagPro** competitive fans' vocabulary — grab/cap/return/snipe/
regrab/contain; carrier gets a persistent outline; scorebug = caps + countdown clock with flag icons on
team names; the signature moment is the **snipe → regrab → cap chain** ("the flag run" — a carrier
surviving the chase). **Halo/TF2 broadcast grammar** (the genre-peer spectator UI we borrow): top-center
scorebug with per-team flag-state icons, event banners with 1–3s holds ("X has the flag!", "TEAM
SCORES!"), top-right kill feed `killer [glyph] victim` with carrier-kills highlighted. **Fog-honesty
precedents**: SC2 observer + Dota spectator expose per-player vision on demand (toggle/lock-to-player)
while the default cast stays omniscient — exactly our POV-inspect model. Players of the source genre
find the CARRIER CHASE dramatic above all; the broadcast therefore spends its strongest highlight on
the carrier (aura + feed weight + curtain on capture).

## 13. FIDELITY_AUDIT

Full audit table in `REPLAY_BRIEF.md` (F1–F10), engine-traced. Headlines: **kills are never score** —
scoring is win-only +100 (sim.nim:72,2766); the standing axis is team lives + flag state (the actual
tiebreak keys, sim.nim:2860–2880). **No dropped-flag state exists** — carried or home only; no drop
iconography (invented-mechanic trap L17). **The clock is a REAL limit, not a safety cap** —
`checkMaxTicks` runs a lives→progress tiebreak, so a countdown labeled with its consequence is honest
(L75); the end-card names the tiebreak key (L76), checking `isDraw` before `winner` (a draw stores
winner=Red internally). **No flag arrows / global tracking** — fog replaced intel; nothing may imply
players see what the omniscient cast sees (L77/F5); fog honesty = POV-inspect. **Friendly fire ON** —
team-kills marked; **same-tick trades** render both kills; multi-kill tick attribution derived from sim
state per-victim, degrading honestly to "traded" if ambiguous (F7). No chat surface (chat recorded but
never applied, replays.nim:209).

## 14. CONTRACT COVERAGE

Chain: **writer** = server-side input recorder (`openReplayWriter` server.nim:784, `.bitreplay`
COWLDCTF v1) → **primary** = our broadcast client at `/client/replay` (server re-simulates
`stepReplay`+hash-verifies, streams board packets + JSON state) → **fallback** = board-only degradation
(binary sprite stream renders even if a state frame is missed; chrome hydrates on next state frame;
missing state entirely → board + transport still usable) → **live** = `/global` spectator keeps
bitworld client + unchanged packets (replay-mode-only divergence; live game byte-identical).

| Field | writer → primary → fallback → live | Assertion |
|---|---|---|
| winner/isDraw/timeLimitReached → | sim finishGame → state JSON → end-card verdict; fallback: board freeze on GameOver phase | fixture: capture-end + tiebreak-end cards render correct verdict text |
| team lives → | re-sim per tick → state JSON → scorebug pips/numerals; fallback: roster dims from board only | fixture: pip count equals expand_replay death ledger at 3 sampled ticks |
| flag state/carrier → | sim.flags carrier diff → state JSON → icon flip + carrier aura | fixture: steal tick flips icon within 1 tick; return restores |
| kills (incl. team-kill, trade) → | per-victim sim diff server-side → state events → feed rows | fixture: feed rows == expand_replay Kill events, team-kill flagged |
| tick/maxTicks → | sim.tickCount + config → state JSON → clock pill | clock shows config-derived limit (10000 main / 300 short fixture), never hardcoded |
| transport/seek → | chat-char commands + `s:<tick>` → applyReplayCommand/seekReplay → keyframe restore | scrub to tick N lands within keyframe interval; play/pause/speed reflect in state JSON |

Risk checkpoint (Phase 2): confirm whether viewer WS blobs are snappy-compressed; if so, vendor the
decoder inline in the client (no `/client/snappyjs.min.js` fetch through the proxy).

## 15. WHOLE-PRODUCT SURFACE MATRIX

Not required — PRODUCT_SCOPE: replay (§1). Live/player/global surfaces are explicitly out of scope and
guarded unchanged (§14 live column).
