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
- The diagnostic lines below, all keyed by `tick=` so they join against each
  other, the `FIRST_LIGHT_INSTALL` stream, and the replay's per-tick masks.
- Zone-damage eliminations ("caught outside the zone") and a normal BR
  ending. This scenario should emit no policy-selected fire because it installs
  no combat-policy overlay; that is a scenario choice, not a missing body path.

## Diagnostic log lines

Every line carries `tick=` (the same tick numbering as `FIRST_LIGHT_INSTALL`
and the replay), so any two streams join on it. Seat lists are printed as
`[0,5,17]`.

- `FIRST_LIGHT_ANNOTATION ... kind=play_fault epoch=E entry=ID code=C
  reason="..."` — a play instance faulted. `code` is the stable cause
  (`outOfFuel`, `epochDeadline`, `unreachable`, `memoryOutOfBounds`,
  `returnedNonzero`, `abiViolation`, ... — the engine `FaultCode`, the same
  value the policy sees as `code` in its `play_faulted` status), so faults
  aggregate by code without parsing text. `player=` carries the seat's roster
  name when the episode has one, and `reason` is the runtime's own message
  with the cause first and the backtrace frames after it, because the status
  that carries it is capped at 256 bytes and trimmed from the end. Printed on
  the fault
  tick; the same record is written to the replay's annotation stream. The
  `FIRST_LIGHT_INSTALL` line that follows on that tick and seat shows what
  the standing order fell back to, so a provenance switch with a fault line
  beside it was a fault, and one without was a guard, reflex, or call.
- `FIRST_LIGHT_PLAY_LOG tick=T seat=S entry=ID phase=P level=N
  message="..."` — a play's accepted `log` call from `init`, `step`, or
  `retune`, with opaque signed level and raw bytes encoded by
  `strutils.escape` so the record stays on one physical line. The synchronous
  stdout sink admits four lines per seat per 24 ticks; later records are
  suppressed and the next window's first admitted line adds
  `dropped_previous=N`. These operator-visible diagnostics are best effort,
  not private or durable, and do not enter status, replay, game state, or
  `gameHash`. A slow stdout collector can delay the server loop. Upload-time
  manifest-probe logs have no seat/entry identity and are not printed here.
- `FIRST_LIGHT_PLAN_BUDGET tick=T seat=S revision=R visits=V units=U
  outcome=suspended|completed|failed` — the seat's cold route plan ran out
  of the pooled per-tick budget (`suspended`, once per starved visit), or a
  plan that had been suspended at least once finally resolved
  (`completed`/`failed`, with `visits` as the total retry count). A plan
  that fits its first visit prints nothing.
- `FIRST_LIGHT_NAV tick=T pending_plans=N stale_path=[...] no_path=[...]` —
  follower census: seats walking a route planned for an earlier request
  while the current one computes, and seats with a navigate order and no
  route at all (standing still). Printed once a second and on every tick
  with a plan-budget event, so the two join.
- `FIRST_LIGHT_COMBAT tick=T fired= aligning= none_shootable= vetoed=
  no_enemy= no_policy= no_policy_enemy_in_range= ..._seats=[...]` — weapon
  path census, once a second. `no_policy` means the seat's folded combat
  policy is the neutral value, under which the body never runs the weapon
  path (the default play and the safe hold both produce it);
  `no_policy_enemy_in_range` is the subset that had a shootable non-partner
  track at the time, which is the "facing each other and never shooting"
  signature. `aligning` is a shootable target held but not yet fired on
  (rotating, cooldown, windup); `none_shootable` is fresh tracks with none
  in range and line of sight; `vetoed` is shootable tracks excluded by
  noShoot, protect, or holdFire.

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
