# First light — watch the play-calling shell's first live episode

First light is the play-calling shell's first runnable milestone: a 32-seat
(16 duos × 2) BR episode driven by the shell's body layer. Movement, zone
awareness, cover holds, and partner cohesion are real; **weapons are
deliberately not compiled into this build** — eliminations come from zone
damage only.

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
- `FIRST_LIGHT_MOVEMENT tick=... moving=N aiming=M` telemetry windows.
- Zone-damage eliminations ("caught outside the zone") and a normal BR
  ending. Zero combat lines — there is no fire path in this build.

## Gating

Everything is behind the `season2Shell` config flag — **absent from every
shipped config, defaulting off**. The flag comes on only via the demo's own
generated config (the script overlays
`tests/fixtures/shell/first_light_config.json` onto `config.practice.json`). With the gate off the sim is byte-identical to
pre-shell main; the archived replay fixtures re-simulating hash-exact is the
enforced proof (`tests/test_shell_first_light.nim` and the replay compat
suite).

## Current limits (deliberate, tracked)

- The demo uses an authored fixture map: generated giant maps currently trip
  the body-map atlas density cap (`MaxCoverPostsExamined`), whose raise is
  queued for the constants freeze with a 33-seed census behind it.
- The idle-aim converge is a placeholder; stencil's oscillating `idleSweepAim`
  arrives with the full action port.
- `BrDefaultFallbacks` in `src/shell/standing_order.nim` documents the facts
  the body's belief surface doesn't expose yet (zone rect/timing, cover
  goal); each retires as the belief port grows.
