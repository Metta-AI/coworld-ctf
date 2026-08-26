# Season 2 human-seat controls — the REAL action space

Every claim here is traced to a source line and, where it is behavioural,
covered by a test. Nothing in this document is inferred from prose.

## 0. The action space, in full

A seat — human or policy, the engine does not distinguish — emits **one 8-bit
button mask per tick**, plus an optional chat string. That is the entire
interface. `InputState` has exactly eight fields
(`~/.nimby/pkgs/bitworld/src/bitworld/spriteprotocol.nim:58`), and the bit
values are `ButtonUp..ButtonC` (`spriteprotocol.nim:20-27`).

| bit | button | engine effect | site |
|---|---|---|---|
| `0x01` | up | `inputY -= 1` → accelerates | `sim.nim` `applyInput` |
| `0x02` | down | `inputY += 1` | " |
| `0x04` | left | `inputX -= 1` | " |
| `0x08` | right | `inputX += 1` | " |
| `0x10` | select | aim **CW**: `aimBrads -= aimTurnRate` | " |
| `0x20` | attack | **rising edge** → `startFireWindup` | `sim.nim` `step` |
| `0x40` | b | aim **CCW**: `aimBrads += aimTurnRate` | `sim.nim` `applyInput` |
| `0x80` | c | **hold** charges a grenade, **release** throws | `applyGrenadeInput` |
| — | chat | `sim.applyShout`: ≤10 printable ASCII, 1/sec | `sim.nim` `applyShout` |

Constants: `AimBradsTurn=256`, `AimTurnRate=5`, `FireWindupTicks=5`,
`GrenadeChargeTicks=24`, `ReplayFps=24`, `Accel=76`, `MaxSpeed=704`,
`MotionScale=256`, `FrictionNum/Den=144/256`.

**The governing rule holds by construction:** every binding below resolves to
one of the eight bits or to a shout. There is no human-only capability,
because there is nowhere to put one.

## 1. The bindings

| input | wire | notes |
|---|---|---|
| `W A S D` / arrows | d-pad bits | chords compose; opposing keys are forwarded and the engine cancels them |
| mouse move | `b` / `select`, one per tick | shortest-arc chase toward the cursor |
| **LMB** | `attack` | click = one shot; held = the bit is *pulsed* to re-arm |
| **Space** | `c` | hold to charge, release to throw |
| **1–6** | chat `!N [cell]` | standard ping vocabulary |
| **RMB** | — | reserved for the ping wheel; we leave the hook, that lane fills it |
| **Shift** | — | **cut**, see §2 |
| Enter | chat | unchanged; already correct on this client (§5) |

## 2. (a) Sprint: there is none, and Shift is CUT

There is **no speed modifier anywhere in the engine**. The only `speedScale` in
`applyInput` is `carrierSpeedPct` — a 70% *penalty* for carrying the heart
(`sim.nim:140`, `sim.nim:6760-6763`), plus the `buffLevel` scale on that same
penalty. No button changes speed.

Nor is there room for one: all eight bits are spoken for by the table in §0.
A sprint would need a **ninth bit**, i.e. a sprite-protocol change in the
pinned package.

So Shift binds to nothing and ships bound to nothing. Wiring it client-side to
a speed change would be precisely the human-only speed hack the governing rule
forbids — a policy could not express it.

`tests/test_player_controls.nim` asserts this executably: for **all 256**
possible masks, neither axis ever exceeds `maxSpeed`.

**If Season 2 wants a sprint, it is a real engine mechanic** — a new
`InputState` bit, a stamina/cooldown cost, exposed to every policy, and A/B'd
on its own. Filed as follow-up, not smuggled in here.

## 3. (b) Number keys 1–6: glory is PASSIVE, so they carry pings

`src/ctf/glory.nim` is **entirely pure pricing functions** — `deedGlory`,
`mintGlory`, `tierGlory`, `levelForXp`, and so on. It has no input surface at
all: nothing in the glory lane is callable, by a human or by a policy. Deeds
and achievements are *awarded* by the sim in response to events
(`sim.awardDeed`, `sim.evalAchievementsAllTeams`), never *requested*.

So the number keys cannot "call" glory. They carry **callouts** instead — the
standard ping vocabulary from `callout-spec.md` §5 — on the shout wire that
every bot already shouts on (`players/picasso/baseline.nim:8107`):

| key | wire | meaning |
|---|---|---|
| 1 | `!1 <cell>` | SPOTTED HERE |
| 2 | `!2 <cell>` | PUSH HERE |
| 3 | `!3` | FALL BACK |
| 4 | `!4` | ON ME / NEED BACKUP |
| 5 | `!5` | NICE ONE (social tier) |
| 6 | `!6` | reserved |

The cell is the `chessCell` under the cursor — the same 26×14 encoding the
shipped `E` callout already round-trips (`baseline.nim:3010-3034`). Worst case
`"!2 Z14"` is 6 of the 10 available characters.

This is **zero engine diff**: `sanitizeShout` already accepts any printable
ASCII, and `computeGameHash` already mixes shout text as opaque bytes. A human's
ping is exactly as legal, as hashed, and as rate-limited as a bot's, because
`applyShout` takes a `playerIndex` and does not care who is behind it.

## 4. (c) Space = item use

Space maps to `c`, level-triggered straight through: hold charges
(`throwCharge` up to `GrenadeChargeTicks`), release throws. This is the
engine's own grenade contract, unmodified.

This binding also **fixes a real defect**. The stock browser client masked the
top bit off — `new Uint8Array([0x84, mask & 127])` — so `ButtonC` could never
reach the server, and the grenade was documented but unreachable in a browser.
Our client sends `mask & 255`.

## 5. Client ownership: VENDORED, not patched

**Decision: vendor the browser client into this repo; leave the pinned package
byte-identical.**

The production human-play surface is `client/player_client.html` — a
self-contained ~200-line vanilla-JS page, `staticRead` into the binary at
compile time. It is *not* the Nim `player_client.nim`, which is a separate
native desktop client.

We vendor `client/player_client.html` + `client/player_controls.js` and serve
them from `src/ctf/server.nim` at bitworld's own `/client/player` route, in a
branch placed **ahead** of the `bitworldClient.serveClientRoute` fallback.

Why this way:

- **Zero-diff for league.** `~/.nimby/pkgs/bitworld` is untouched, so every
  league build is bit-identical. A league seat is a bot process; it never
  fetches this page.
- **It follows an existing precedent in the same file.** The replay routes
  already do exactly this — the in-code comment reads *"ELEVATE-BY-REBUILD: our
  HTML, not bitworld's."* We are not inventing a mechanism.
- **We own the half that is ours.** Only the input layer is replaced. The
  sprite-protocol parse, snappy decode, and layer compositor are untouched —
  that half is upstream's and should keep tracking upstream.
- **Patching the pin would be invisible and unshippable**: it lives outside the
  repo, is not code-reviewed, and would silently un-patch on any re-pin.

### Correction to the callout spec

`callout-spec.md` §1/§4 records the human client's chat as **broken** — legacy
opcode `0x01` against a server that parses only `0x81-0x86` — and calls it "the
one truly load-bearing fix."

**That is true of `player_client.nim` (the native client) and false of the
browser client.** The browser client already speaks the modern sprite protocol:
it flips a `spriteMode` flag on the first sprite packet and then sends chat as
`0x81` and input as `0x84` (`player_client.html`, `chat()` and `sendMask()`).

Verified live, not read: pressing `1` in the browser produced the perception
label `red shout player1: !1 S9` — the exact format policies scan for. The
human→bus channel was already open. That answers callout-spec §8 open
question 1: the Observatory surface is the HTML client, and it is not
wire-broken.

## 6. Mouse aim is dead-reckoned, by engine mandate

There is **no analog aim field on the wire**. Raw mouse packets do cross
(`SpriteClientMouseMoveMessage`) but the CTF server decodes and **discards**
them (`global.nim:1339-1340`). So a human aims the way a policy aims: one
rotate button per tick.

The client must therefore know its own aim to decide which button to press —
and it cannot read it. Every soldier sprite in a player view, **including your
own self marker**, renders with a fuzzed aim (`global.nim:6211-6226`, GV24).
That code says so outright:

> your true aim is knowable only from the commands you issued, never from the
> pixels.

So we integrate the commands we issue: seed at `spawnAimBrads(team)`, and
advance by `AimTurnRate` per **applied tick**. The tick clock is the server's
own frame cadence — one sprite frame is one sim tick — so the rotate decision
is made once per frame and never mid-tick. (Movement and item bits *do* update
mid-tick for responsiveness; re-deciding rotation mid-tick would feed the
server a rotate tick the reckoning never counted.)

**Measured drift: ≤2 brads.** Against a live match, aiming at four bearings and
recovering the engine's true aim by averaging 120 samples of the fuzzed
rendered rotation (the fuzz is zero-mean over its 12-tick re-roll):

| bearing | desired | dead-reckoned | error vs cursor | drift vs engine |
|---|---|---|---|---|
| north | 64 | 65 | −1 | +2 |
| west | 128 | 130 | −2 | −2 |
| south-east | 224 | 225 | −1 | +1 |
| east | 0 | 255 | +1 | −1 |

`AimResyncBrads` in Picasso is 4 for comparison; we are inside half of that.

### Game-feel consequence worth flagging

`AimTurnRate=5` means a 180° flick takes **26 ticks ≈ 1.07 s**. That is a
turret, not a mouse-look. Mouse aim makes the *intent* natural, but it cannot
make the traverse fast — the rate is an engine constant that applies to every
policy equally. If Season 2 wants snappier aim, that is a balance change to
`aimTurnRate`, not a client change.

## 7. Fire semantics — a correction to the brief

The lane brief specified "press = windup, release = shoot". **The engine does
not do that.** `sim.nim` `step`:

```nim
if input.attack and not prev.attack:
  ...
  sim.startFireWindup(playerIndex)
```

A **rising edge** arms the windup; the shot releases `fireWindupTicks` later on
its own, with the aim locked at the pull. Release is not read at all, and
*holding the button fires exactly once*.

So auto-repeat must **pulse** the bit — press one tick, release the next —
which is exactly what a policy does. `startFireWindup` self-guards on `canFire`
and on an in-flight windup, so a pulse landing during cooldown is ignored; we
never gain a shot a bot could not take. Both halves are tested: holding arms
exactly one windup, pulsing arms more than one.

## 8. What this lane did NOT ship

- **No reticle oracle.** The crosshair and aim ray are drawn client-side from
  the aim we *commanded*. They reveal nothing the seat did not already know and
  do not unfuzz the render. A genuinely private unfuzzed self-aim channel
  remains engine-lane work.
- **No gamepad.** The stock client's pad bindings were dropped with the keyed
  aim they shared. Re-adding them is a small, separate change.
- **No ping wheel.** RMB swallows the context menu and calls
  `onPingWheelOpen` / `onPingWheelCommit` with the map cell under the pointer.
  That is the whole seam; the wheel lane fills it.

## 9. Running it

```bash
tools/dev_play.sh                       # release build + practice config + bot fill
# or, for a durable controls testbed (99 hp, serve-forever):
COGAME_PORT=2100 COGAME_CONFIG_URI="file://$PWD/config.demo.json" ./bin/ctf-server
```

Then open the printed URL. Tests:

```bash
node client/player_controls.test.js                                   # translator
nim c -d:release --path:src -o:/tmp/tpc tests/test_player_controls.nim && /tmp/tpc
```
