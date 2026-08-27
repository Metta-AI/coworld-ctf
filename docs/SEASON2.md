# Paintbot Season 2 — the spec (v1, 2026-08-26)

The one-line answer to "what is Season 2": **paintbot becomes playable by people — the exact game the league plays, no 3D or first-person gimmick — and becomes the place you learn your AI by playing with it.** This file is the working spec for the app at paintbot.apps.softmax.com and for anyone growing surfaces around Season 2.

## The two pillars

**1. HUMAN-PLAYABLE PAINTBOT.** A human takes one real seat in a real episode: same engine, same tick (24/s), same rules, same fog. Controls: **WASD** move · **mouse** aim — **DIRECT: the turret head points wherever the mouse is, period (Maxwell's ruling, 2026-08-26).** Humans flick; no traverse-rate limit applies to a human's aim. This is a deliberate, explicit exception to the buttons-only symmetry rule, implemented as a config-gated direct-aim input channel on PLAY servers (league builds untouched; opponents still can't read exact aim — the anti-oracle fuzz stands; interim builds may ship mouse-chase until the engine channel lands) · **LMB** fire (click = one shot: the press arms a 5-tick windup that releases itself with aim locked at the pull — flick-then-click is the skill; holding does not charge; auto-repeat pulses) · **RMB** ping wheel (see Pings) · **Space** item use (grenade hold-charge/release-throw; spray; later: place cardboard) · **1–6** instant ping hotkeys. Governing rule for everything except aim: every control maps to something a policy could also do.

**2. PLAY — learn your AI's gameplay.** Anyone can spawn their own policy into a seat and play alongside or against it: lobby → configure seats (Human / a policy build / filler bots) → share link → start → live match → endcard. The lobby pattern mirrors the Observatory's league-lobby flow; the playable match itself runs on our self-hosted game server.

## Season 2 game additions (engine-side, league-wide, all symmetric)

- ~~Smooth aim~~ **PARKED (Maxwell, 2026-08-26: "humans don't need smooth aim")**: the spring-rotation prototype exists, proven and default-OFF (worktree commit 72be84d), but it is NOT part of the Season 2 human experience and nothing waits on it. Humans aim through the mouse at the game's real traverse rate — the same one every policy lives with. Any future arming is a league-wide balance A/B, decided separately.
- **Pings**: a standard, public callout vocabulary (`!<id>` + optional grid cell) any seat — human or any author's policy — can emit and perceive. It rides the existing shout channel (causal, proximity-audible ~250px, overhearable by nearby enemies — shouting reveals you, like a real field). This is the lingua franca for mixed teams (different authors' policies allied together, and humans + AIs on one team). Bots ping as part of playing; matches visibly chatter.
- **Cardboard** (design in review): a placeable cardboard bunker — Space to place, soakable, real paintball-field furniture.
- **Glory, live**: the per-life levels, deeds, and achievement toasts already in the league render on the live human view, not just replays.

## The app at paintbot.apps.softmax.com — the DECIDED experience (Maxwell interview, 2026-08-26)

**Front page = a short season front.** What's new / what's arriving, kept brief, no narrative prose. A small always-live tile streams the freeplay field (click to expand). Then the two doors:

1. **FREE PLAY** — a standing match against real league policies. Anyone who hits Free Play — **no sign-in; guests get paintball-register names** ("Green Rookie") — is assigned a policy seat and **takes it over at that cog's next respawn** (a "suiting up…" beat; never body-snatched mid-fight). Leave or disconnect and the policy resumes the seat. The match runs **embedded in-page with a fullscreen toggle**.
2. **LOBBIES** — create a lobby **by name** (sign-in required to create); it appears on a **public list on the site**; anyone viewing can click it and **join a team**. The host seats non-human slots with a **full any-policy picker** (search and seat any policy version you own — the complete "play with YOUR AI" from v1); unclaimed seats auto-fill with the standard field. Host presses Start.

**Identity: light.** Softmax auth keeps your display name (shown on the field). No stats, no human ladder at v1. "Playing with your AI" at v1 is exactly a seat — no telemetry or reports yet.

**Division of labor unchanged:** our self-hosted game server + client provide the field; cubi owns the hub/DNS/TLS and links or embeds what we hand over.

## Voice and style

Kids'-paintball register everywhere: players get *tagged* and *aced*, never the k/d words; supply drops, splats, heralds. Canonical naming: Coworld, League, Division, Round, Episode, Champion (= a league's representative). Ink & Print house style for all surfaces.

## Status (who is building what — 2026-08-26)

Live team: client engineer (WASD/mouse client — decision made to vendor the player client), renderer (camera-follow + live glory HUD), app/product (lobby shell + policy seats), engine lanes (smooth-aim prototype, one-command practice server), designer (cardboard one-pager done, awaiting review). Orchestrated from the coworld-ctf board epic "PAINTBOT SEASON 2 — HUMAN-PLAYABLE"; knowledge dossiers in ~/.ctf/knowledge/ (playtest, callout spec, lobby pattern, polyworld adoptables).
