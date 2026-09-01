# First light — retained Season 2 integration demo

First light is the retained end-to-end smoke for a 32-seat (16 duos × 2) BR
episode driven by the shell's body layer. It predates the complete Season 2
surface, but the script still exercises the production upload, compile, call,
ladder, body, and mask path. The full body weapon path is compiled; this demo
installs only `edge_ride` controllers and no combat-policy overlay, so its seats
do not choose weapon targets and eliminations normally come from zone damage.

**The demo now runs mixed seats**: seats 0–7 are driven by `edge_ride`, a
real uploaded WASM play that travels the full production path (upload →
validate → compile → commit → call → ladder) inside the live episode, while
seats 8–31 run the engine-native default play as the floor. edge_ride plays
the zone earlier and smarter than the default — expect its cogs to move to
the next zone rectangle well before the default seats react, arriving in
cover with time to spare. `FIRST_LIGHT_PLAY_*` log lines carry the upload/
commit/call evidence and `provenance=entry:edge_ride` marks its installs.

## Run it

```bash
./tools/run_first_light.sh
```

The script builds a release server plus probes into a temp dir, runs the
annotation/timing gates first, then boots the real BR server with 32
presence-only play seats and tails the per-seat install telemetry. It prints
the viewer URL (default `http://localhost:21814/client/global`). Ctrl-C
stops every child.

Knobs (environment variables):

- `FIRST_LIGHT_PORT` — server port (default 21814).
- `FIRST_LIGHT_MEASURE_ONLY=1` — run only the probe gates, no live server.

## What you should see

- 32 cogs activate under a safe-hold, then move under the default play's four
  rules: rotation pulses ahead of each zone shrink, quiet cover-holds between
  shrinks, partner leash keeping duos together (`FIRST_LIGHT_INSTALL` lines
  name the rule per seat: `safe_hold`, `brPartnerLeash`, `brRotate`,
  `brCoverHold`, `brHold`).
- Seats 0-7 additionally run the `edge_ride` reference play (`rule=edge_ride`,
  `provenance=entry:edge_ride`); the other 24 stay on the default.
- `FIRST_LIGHT_MOVEMENT tick=... moving=N aiming=M` telemetry windows.
- Zone-damage eliminations ("caught outside the zone") and a normal BR
  ending. This scenario should emit no policy-selected fire because it installs
  no combat-policy overlay; that is a scenario choice, not a missing body path.

## Gating

Season 2 now defaults on. The demo's distinctive path is gated by its
configured `control: "play"` seats plus its generated config overlay (the
script overlays `tests/fixtures/shell/first_light_config.json` onto
`config.practice.json`); an all-input roster still takes the direct-input path.
The overlay carries no map of its own, so the demo runs the practice config's
BR arena — the generated `br-gen-4242`, 3211x1713. (It used to pin an authored
512x256 map to dodge the body-map atlas density cap; the constants freeze
retired that workaround, and the small arena made 32 seats look like a scrum.)
The archived replay fixtures re-simulating hash-exact remain the compatibility
proof (`tests/test_shell_first_light.nim` and the replay compat suite).

## Demo limits

- The 32 helper processes are presence clients, not policy containers; only
  the fixture's seats 0–7 receive the scripted `edge_ride` upload/call.
- The fixture deliberately compresses zone timings and disables lobby chat so
  movement and installation evidence appear quickly. It is an integration
  smoke, not the published `battle-royale-s2` match configuration or a policy
  starter.
- Use `policies/starters/` for policy authoring and the published manifest for
  current game defaults. This script remains useful for the narrow shell/body
  wiring proof above.
