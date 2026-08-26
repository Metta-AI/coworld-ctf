# Live player view — the replay viewer's chrome, driven by the stepping sim

`/client/play?slot=<n>&token=<t>` serves the SAME designed broadcast client the
replay routes serve (`client/replay_broadcast.html` + `client/broadcast_core.js`),
pointed at the per-seat `/player` websocket instead of `/replay`. One HTML, one
visual language, one set of chrome code: the live view is the replay viewer with
the transport swapped for a camera and a personal HUD.

`/client/player` still serves the stock bitworld client, untouched — it is the
fallback and the before-picture.

## Run the demo

```sh
./run-practice.sh                                   # server + 7 bots on :2137
open 'http://localhost:2137/client/play?slot=0&token=0xBADA55_0'
```

Keys: `WASD`/arrows move · `Z`/`J` fire · `X`/`K` aim CCW · `Space` aim CW ·
`C` grenade · `V` toggle follow / whole arena · `-` `=` zoom the follow camera.
(The key map is the documented engine fallback. Mouse aim and click-to-fire are
the CONTROLS lane's call — see the seam note in the client.)

## What the playtest found, and what answers it

| Playtest failure | Answer |
|---|---|
| bird's-eye whole arena, no follow — you lose your cog among 15 bots | follow camera in `broadcast_core.js` (`setCamera`), eased at display rate, clamped to the board edges; `V` returns the fit view |
| own sprite fully occluded by the flag-pedestal banner at spawn | `global.soldierXray` — the self outline drawn a SECOND time above every prop, over a translucent ghost of the body |
| HUD was the text "3hp x2": no cooldown/windup, no personal feed | the seat card (health thirds, lives, rank + per-life xp, a readiness meter that distinguishes windup from cooldown, weapon/grenade/carry) and `.feed-row.mine` in the shared feed |

Live-play presentation a recording never needed: a hurt wash on taking paint, a
`TAGGED OUT` respawn read with the board dimmed, and incoming-fire arcs.

## The two rules this had to respect

**A bot's observation is byte-identical.** Everything added to the player stream
is gated on `PlayerViewerState.hudEnabled`, set only by a client that sent
`hud:on` over the chat channel. A policy never sends it. That covers both the
chrome JSON sprite and the x-ray plate.

**The aim-fuzz anti-oracle rule is untouched.** No true aim is sent anywhere.
The private unfuzzed reticle and shooter-side shot feedback are a separate lane;
`liveview.SelfAimSeam` names the slot they land in. The one directional read here
— the incoming arcs — is computed from `global.shotImpactPoint`, the JITTERED
ring the human can already see on the board, never a shot's true landing.

## Where the code is

- `src/ctf/liveview.nim` — the live chrome frame + the seat's private `me` block
- `src/ctf/global.nim` — `hudEnabled`, `soldierXray`, `shotImpactPoint`
- `src/ctf/broadcast.nim` — `buildStateJson` gains an optional `selfState`
- `src/ctf/server.nim` — `/client/play`, live beat events per sim step
- `client/broadcast_core.js` — follow camera, `sendInputMask`
- `client/replay_broadcast.html` — `LIVE` mode: seat card, respawn, hurt, arcs

## Embedding it (for the app lane)

SEASON2.md ships the match "embedded in-page with a fullscreen toggle". Verified
working in a real cross-origin iframe (`tools/embed_host_probe.html` is the probe; serve it with
`python3 -m http.server 8899 -d tools` so it is genuinely cross-origin to the
game server, the way the real site will be):

- **Keyboard.** An iframe does not hold the keyboard until it is clicked, and
  the failure is silent — you press W and nothing happens. The client now takes
  focus on load, retakes it on any pointerdown on the board, and shows a quiet
  `Click to take the controls` pill whenever it genuinely has neither focus nor
  a forwarding host. The match keeps rendering behind that pill, so an
  unfocused embed is still a valid always-live tile.
- **Preferred: forward keys.** The host can post
  `{src:'ctf-shell', type:'key', down:<bool>, key:'w'}` to the iframe — the same
  bridge that already carries transport commands. A forwarding host is playable
  with no focus at all and never sees the pill. **Your own fullscreen button
  takes focus the moment it is clicked**, so a host with a fullscreen toggle
  wants this.
- **Fullscreen.** Toggle it on the *wrapper*, not the iframe; the client's
  ResizeObserver recomputes the camera and chrome scale on its own.
- **Do NOT pass `?embed=1` for live play.** That flag is for the League
  Replayer shell, which redraws the scorebug itself; it hides `#scorebug`, and
  the live view's glory/HEAT readout lives inside it.

## Practice config

`practice.json` differs from `config.json` only to make an iteration cheap:
`minPlayers` 8 (not 16, so 7 bots suffice), `maxTicks` 20000, and
`respawnTicks` 192 (the shipped 72 = 3s is shorter than a screenshot round trip;
the overlay reads the config, so it shows whatever is set).

## Screenshots (all from live matches, `.harness/screenshots/`)

- `sbs-before-after.png` — stock client vs `/client/play`, same rig
- `sbs-replay-vs-live.png` — the replay viewer vs the live view, same chrome
- `xray-through-banner-900w.png` — the spawn-banner occlusion case, at 900px
- `after-live-05-taggedout.png` — the respawn read, board dimmed, ghost view
- `after-live-08-endcard.png` — the broadcast end card off a live match
- `after-live-06-wholearena.png` — the `V` fallback view, self still findable
