# Wave 1 demo — watch the BR episode in one step

Watches `rt_episode/episode-s830.bitreplay`, the wave-1 launch candidate:
seed 20260830, BR_FIRST_WAIT=1500, 16 duos, map
`tests/fixtures/br-match-showmatch-4242.json`, roster `rt_episode/roster_v2.json`.
Winner: PEACH (TIGHT-TRADE play), 39 glory, GameOver at tick 3573.

Recorded fresh against GameVersion 48 (GLORY PORT increment 3/3, the
glory-inc3-gv48 wave) — the prior take of this same seed/roster/map,
recorded on GV47, had PEACH (same play) win at 626 glory. The winner is
UNCHANGED from the GV47 take; the glory number is not — GV48 disables
`awardWipe` in `brMode` (see `glory.nim`'s own v11 changelog), and that
one mint was 95.8% of the GV47 winner's total. 626 -> 39 is that fix
landing on this exact recording, not noise. Across all 7 rt_episode
demos this same re-record pass produced, EPISODE TOTALS now vary
meaningfully (192g-508g, vs a near-constant ~886-926g band before) — the
direct, expected signature of the wipe-dominance fix. The WINNER's own
glory specifically stayed low and largely flat (18g on 6 of 7 — one
`dHonorableKill`-class deed — with this file's 39g the one outlier): in
these short, quiet demo recordings the eventual survivor usually wins by
NOT fighting much rather than by piling up kills, so removing the wipe
bonus reveals a real, low combat floor rather than a second hidden
constant. Flagged here rather than smoothed over — a genuine follow-on
finding, not a regression.

Episode outcomes are GameVersion-sensitive in general: a re-record on a
new GV may legitimately change the winner, since stats and combat-tuning
changes between versions can shift who converts fights (see the GV45->47
take's own YELLOW->PEACH swap). Don't expect this file's specific winner
to be stable across future GV bumps either.

## Recipe

This path is self-contained: Docker plus a static file server, nothing
else — no local Nim toolchain required. From a checkout of this branch,
at repo root (Docker must be running):

    tools/build_replay_viewer.sh "$(pwd)/static-replay-viewer" \
      && cp rt_episode/episode-s830.bitreplay static-replay-viewer/episode-s830.bitreplay \
      && (cd static-replay-viewer && python3 -m http.server 8767)

Then open:

    http://127.0.0.1:8767/index.html?replay=episode-s830.bitreplay

It autoplays. Deep-link to a paused tick with `&t=<tick>` (e.g. `&t=2900`
for mid-episode, zone visibly closing — Playing starts at tick 824, the
zone holds until 2324, then shrinks in ~528-tick steps; GameOver lands at
3573 — `&t=4000` clamps to the endcard). These tick numbers are specific
to this recording; a future re-record can shift them (see the
GameVersion-sensitivity note above) — re-derive with
`tools/dump_glory_from_replay` (prints the final tick) if this file
changes again.

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

This path is for engineers, not viewers: it needs a working local Nim
toolchain and nimble deps synced (`nimby --global sync nimby.lock`), plus
a `nim.cfg` at repo root — it's gitignored/untracked, so copy one in from
an existing checkout (`cp ../other-checkout/nim.cfg .`). Without it,
compilation fails with `Error: cannot open file: bitworld/spriteprotocol`.

    nim c -d:release -o:/tmp/verify_reflash tools/verify_reflash_roundtrip.nim
    REQUIRE_MID_FLASH=0 /tmp/verify_reflash rt_episode/episode-s830.bitreplay
    # -> ROUND TRIP VERIFIED: 32 flashes, all causal (each one load-bearing)

    nim c -d:release -o:/tmp/dump_glory tools/dump_glory_from_replay.nim
    /tmp/dump_glory rt_episode/episode-s830.bitreplay
    # -> winner Peach, 39 glory, 16 teams nonzero, zone center printed

`REQUIRE_MID_FLASH=0` because this recording only flashes each cog's
starting page (episode-start window) — there's no live mid-match
reflash in this take, so the tool's mid-episode-reflash gate doesn't
apply here.
