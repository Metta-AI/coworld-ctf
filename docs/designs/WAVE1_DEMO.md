# Wave 1 demo — watch the BR episode in one step

Watches `rt_episode/episode-s830.bitreplay`, the wave-1 launch candidate:
seed 20260830, BR_FIRST_WAIT=1500, 16 duos, map
`br-match-showmatch-4242.json`, roster `rt_episode/roster_v2.json`.
Winner: YELLOW (TIGHT-TRADE play), 831 glory.

## Recipe

From a checkout of this branch, at repo root (Docker must be running):

    tools/build_replay_viewer.sh "$(pwd)/static-replay-viewer" \
      && cp rt_episode/episode-s830.bitreplay static-replay-viewer/episode-s830.bitreplay \
      && (cd static-replay-viewer && python3 -m http.server 8767)

Then open:

    http://127.0.0.1:8767/index.html?replay=episode-s830.bitreplay

It autoplays. Deep-link to a paused tick with `&t=<tick>` (e.g. `&t=1800`
for mid-episode, zone visibly closing; `&t=5000` clamps to the endcard).

The build takes ~1 minute (pinned emscripten/Nim toolchain in
`Dockerfile.replay-viewer`). `static-replay-viewer/` is gitignored — it's
a build artifact, rebuild any time.

## Traps
- **The browser caches the wasm hard.** Rebuilding without changing the
  served path/filename means you're looking at the stale build. Use a
  fresh port or rename the output dir if you rebuild and re-serve.
- **Asset paths are relative.** Serve from `static-replay-viewer/` itself
  (as above) — the wrong root gives a blank page with 404s in console.
- Verify by reading the canvas (paint tide + duos moving), not just "the
  page loaded." A blank/one-color canvas is the failure mode that slips
  through silently.

## Re-verify the claims yourself

    nim c -d:release -o:/tmp/verify_reflash tools/verify_reflash_roundtrip.nim
    REQUIRE_MID_FLASH=0 /tmp/verify_reflash rt_episode/episode-s830.bitreplay
    # -> ROUND TRIP VERIFIED: 32 flashes, all causal (each one load-bearing)

    nim c -d:release -o:/tmp/dump_glory tools/dump_glory_from_replay.nim
    /tmp/dump_glory rt_episode/episode-s830.bitreplay
    # -> winner Yellow, 831 glory, 16 teams nonzero, zone center printed

`REQUIRE_MID_FLASH=0` because this recording only flashes each cog's
starting page (episode-start window) — there's no live mid-match
reflash in this take, so the tool's mid-episode-reflash gate doesn't
apply here.
