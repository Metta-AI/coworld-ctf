# Paintbot Season 2 — launch presentation plan

**What Season 2 is:** paintbot becomes playable by people — the exact game the League
plays, no 3D or first-person gimmick — and becomes the place you learn your AI by
playing with it. Ships at paintbot.apps.softmax.com behind two doors: FREE PLAY and
LOBBIES.

**Status check (from the board, epic `e61bc621`):** the substance is built — human
seat, seat takeover, direct aim, aim assist, controls, glory HUD all DONE; direct aim
in REVIEW. Callout/ping wheel is BACKLOG, smooth aim is PARKED. Promo must therefore
sell the seat, the two doors, and Glory — **not** pings, **not** smooth aim.

## What you need, in five buckets

### 1. Identity core — everything else is built on these
| # | Asset | Size | Why you need it |
|---|-------|------|-----------------|
| 1 | Season 2 wordmark lockup | 2400×800 + transparent | The one mark that goes on every surface. No finished logo exists today. |
| 2 | Key art / hero | 1920×1080 | The single image that answers "what is this" without copy. |
| 3 | App icon / avatar | 1024/512/256/128 | Site favicon, Slack, any profile. Must read at 64px. |

### 2. Announcement & social — the launch post itself
| # | Asset | Size | Why |
|---|-------|------|-----|
| 4 | OG / link-preview card | 1200×630 | Every paste of the URL renders this. Highest-leverage single asset. |
| 5 | X/Twitter header | 1500×500 | Account dressing for launch week. |
| 6 | Square announce post | 1080×1080 | The main feed post. |
| 7 | Vertical story | 1080×1920 | Stories/shorts. |
| 8 | "Two doors" card | 1200×630 | FREE PLAY vs LOBBIES — the one thing people must understand. |

### 3. The presentation deck — for actually presenting the launch
16:9, 1920×1080. Ten slides, in the order you'd walk someone through it:
1. Title — Paintbot Season 2
2. The one-liner — what Season 2 is
3. Pillar 1 — a human takes a real seat (same engine, tick, rules, fog)
4. The controls card — WASD / mouse / LMB / RMB / Space / 1–6
5. Pillar 2 — PLAY: learn your AI by playing with it
6. The two doors — FREE PLAY vs LOBBIES, side by side
7. Seat takeover — how you join without body-snatching a cog mid-fight
8. Glory, live — ranks and deeds on the human view
9. What shipped — the honest build status
10. Where it lives — paintbot.apps.softmax.com, the call to action

### 4. Glory art — the most distinctive thing you own
| # | Asset | Why |
|---|-------|-----|
| 11 | 6 rank insignia — RECRUIT → LEGEND | Ranks are the progression story; they need faces. |
| 12 | 8 achievement emblems — THE SIDEARM … THE SQUAD | Trees are the depth story. |
| 13 | Glory board poster | One printable sheet that shows the whole system. |

### 5. Surfaces & texture
| # | Asset | Why |
|---|-------|-----|
| 14 | Landing hero banner | Top of the site. |
| 15 | Seamless splat pattern tile | Backgrounds, slide fills, merch. |
| 16 | Real product screenshots | The most credible asset of all — actual play, not art. |

## The pipeline (decided)
**Hybrid, and deliberately so.**
- Anything **with text** is composed in HTML/CSS against `promo/brand.css` and shot with
  `promo/render.mjs` — real NES-pixel + rajdhani fonts, exact palette, crisp at 2x, and
  editable later. Image models render text badly; this sidesteps that entirely.
- Anything **illustrative** (key art, emblems, textures) is generated with Nano Banana,
  then composited into HTML when it needs a label.
- Splats are never drawn by hand or by a model — `promo/splats.js` stamps the engine's
  own sprite code, ported pixel-for-pixel out of `src/ctf/global.nim`.

## Files
- `promo/ART_DIRECTION.md` — the rules every asset follows
- `promo/brand.css` + `promo/fonts.css` + `promo/font.ttf` — the kit
- `promo/splats.js` — the engine's real paint splats, reusable
- `promo/render.mjs` — HTML → exact-pixel PNG
- `promo/pages/*.html` — one page per asset
- `promo/out/*.png` — the deliverables
