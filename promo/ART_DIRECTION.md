# Paintbot Season 2 — promo art direction (READ FIRST)

Every promo asset must look like it came off the same press as
`docs/designs/season2-cheatsheet.html`. That file is the reference. Open it
(http://localhost:8899/docs/designs/season2-cheatsheet.html) before you design.

## The look, in one line
**Retro 8-bit paintball broadcast** — amber and warm paper on a warm CRT near-black
stage, chunky NES-pixel display type, real engine paint splats in the margins.

## Hard rules

**Palette — use the tokens in `promo/brand.css`, never raw hex.**
- stage `#16110d` → `#241a12` (radial, warm near-black — NEVER pure #000)
- paper `#f2e8d8` · paper-dim `#b8ac98` · ghost `#8a7f72`
- team red `#e0523a` · team blue `#3f7cc4` · amber `#e8a33d` (the accent)
- Amber is the accent for headings, numbers, and the single most important thing on
  the asset. If everything is amber, nothing is.

**Type.**
- `var(--pix)` = NES-pixel. Display only: titles, kickers, numbers, labels. Uppercase.
  Letterspace kickers ~0.2em. Big pixel type gets `text-shadow: Npx Npx 0 rgba(0,0,0,.6)`.
- `var(--disp)` = rajdhani. Sentences, subtitles, body. Weight 500-700.
- Never mix a third face. Never use pixel type for a full sentence — it stops being readable.

**Hierarchy comes from type size, weight, and whitespace — NOT from boxes.**
- Cards only for a genuinely navigable unit or one focused object, and then ONE
  hairline (`.panel` = `1px solid var(--line)`). No shadow stacks, no rounded
  "app card" chrome, no gradient washes, no left accent stripes.
- Minimize divider lines; keep hierarchy. A single `--line` rule under a heading is
  the house move (see the cheat sheet panels).
- No decorative even card grids. No stat-tile metric grids.
- No emoji as icons, ever.

**Splats — `promo/splats.js`, the engine's real sprites.**
- `paintSplats(canvasEl, spots, {w,h})`; colors `PB_RED` / `PB_BLUE`.
- They live in the MARGINS and corners. They must never sit behind display type at
  high alpha — the pilot's first draft crowded the wordmark and had to be pulled back.
- Keep alpha ≤ .85 for hero splats, ≤ .45 for background puddles.
- `imageSmoothingEnabled = false` always — they are pixel sprites, keep them crisp.

## Voice
Kids'-paintball register. Players get **tagged**, **splatted**, **aced** — never
"kill/death/K/D". Supply drops, splats, heralds. Canonical nouns, capitalized:
Coworld, League, Division, Round, Episode, Champion (= a league's representative,
NOT the winner), Glory, Deed, Rank, Power, Paintbot, Cog.

Season-2 terms: **FREE PLAY**, **LOBBIES**, **PLAY**, seat takeover, direct aim, Pings.

Never show a bare number — give it context (a unit, a rank, a delta).

## The facts (do not invent features)

**CORRECTED 2026-08-28 by Maxwell — the earlier human-playable framing was wrong in
emphasis. Re-read this whole section; it supersedes anything you were told before.**

### The headline: policies are LLM policies
The biggest change in Season 2 is that **a policy is now an LLM policy.** When a unit
**spawns**, it gets **flashed with a fresh one-page policy** — written by an LLM, in the
live game. Precise mechanic, per Maxwell: this happens **in-flight during the match, but
at the spawn boundary — NOT while a unit is alive and fighting.** A cog fights the life
it was given. The next life, it gets a new page.

**The through-line for the whole launch:** Glory is per-life and resets on death. The
policy is re-flashed per spawn. **A life is the atomic unit of both scoring and
adaptation.** Everything else in Season 2 hangs off that.

### The main changes, in priority order
1. **LLM policies** — one-page policies flashed to units at spawn (above). THE headline.
2. **Glory scoring** — the per-life rank/deed/achievement economy (GLORYVERSION 10).
3. **Battle Royale mode** — BR ships as a League on the paintbot coworld.
4. **The forum** — agents/policies talk to each other in LLM conversations between
   episodes and **rewrite their own one-pagers** as a result. It is a real improvement
   loop AND it is **public and watchable — the readability is the point.** You can read
   the agents reasoning about their own play. Treat that as a headline feature, not a
   footnote.
5. **Callouts / the ping wheel** — a standard public callout vocabulary (`!<id>` +
   optional grid cell) any seat can emit and perceive, riding the shout channel
   (proximity-audible ~250px, enemies overhear). Maxwell has escalated this to "one of
   the most important" and it is being implemented now. It is the in-match sibling of
   the forum: the forum is how policies talk BETWEEN episodes, callouts are how they
   talk DURING one.

### The human-playable surface is a MARKETING TOOL
Humans taking a seat is **not a pillar** — Maxwell: "The human playable surface is a
marketing tool." It is the on-ramp: the way a person feels what the policies are doing.
Give it ONE slide/asset, framed as "come feel it yourself", never as the headline.
Do NOT lead any asset with "PLAY THE LEAGUE" or a human-first framing.

The mechanics of that surface, when you do show it: same engine, same tick (24/s), same
rules, same fog as the policies. Two doors at **paintbot.apps.softmax.com** —
**FREE PLAY** (no sign-in, guest paintball-register names like "Green Rookie", you take
over a policy seat at that cog's next respawn, policy resumes when you leave) and
**LOBBIES** (sign in to create by name, public list, host seats any policy they own).
Controls: WASD move · mouse direct aim · LMB fire (click = one shot; a 5-tick windup
releases with aim locked at the pull) · RMB ping wheel · Space item use · 1–6 ping hotkeys.

### Status honesty
SHIPPED: Glory (GV10), the League, human seat, seat takeover, direct aim, aim assist,
BARRIER. IN FLIGHT: callouts/ping wheel, LLM policies, the forum.
PARKED: smooth aim (cut — "humans don't need smooth aim").
Never promote something as shipped that isn't. If an asset needs a status, say what is
live and what is arriving.

## Glory — exact strings only
Ranks (RANK UP pays POWER, resets on death):
`RECRUIT` `TAGGER` `MARKSMAN` `IRONHIDE` `QUICKDRAW` `LEGEND`

Deeds (pay GLORY): `TAG` `FIRST!` `SPRAYED` `BOMBED` `POINT-BLANK` `CHASE` `PAYBACK`
`LONGSHOT` `MULTI!` `BOUNTY` `ESCORT` `STEAL` `PEEL` `DENIED!` `CAPTURE` `WIPEOUT`
`SHIELD SOAK` `OWN PAINT` `RANK UP`

Achievement trees (tiers I–V): `THE SIDEARM` `THE CAN` `THE BOMB` `THE BACKUP`
`THE PROVIDER` `THE HEART` `THE PEEL` `THE SQUAD`

## Pipeline — which tool for what
- **Text on an asset → HTML/CSS + `promo/render.mjs`.** Real fonts, crisp, on-palette,
  editable. This is the default.
- **Illustration/texture/emblem art → Nano Banana** (`GEMINI_CLI_TRUST_WORKSPACE=true
  gemini --yolo "/generate '...'"`), then composite into HTML if it needs text.
  Nano Banana renders text badly — never ask it for a wordmark or a label.

## How to render
Static server must be up: `python3 -m http.server 8899 --directory <repo root>`
```
node promo/render.mjs <page.html> <W> <H> promo/out/<name>.png [dpr]
```
Pages live in `promo/pages/`, output in `promo/out/`. `dpr 2` for everything raster;
the renderer screenshots the `.frame` element, so `.frame` must be exactly W×H.

## Verify before you claim done
Downscale (`sips -Z 800 <out> --out /tmp/x.png`) and LOOK at it. Judge it like a
picky user: crowding, overlap, truncation, splats fighting the type, orphaned words,
contrast. Fix and look again. Never report an asset done unseen.
