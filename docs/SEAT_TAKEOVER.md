# Freeplay seat takeover

> **Deprecated-mode surface since 0.7.253.** This document describes takeover
> of direct-input Sprite v1 seats. Such live modes require
> `allowDeprecatedModes: true`; this is not the Season 2 play-seat interface.

A human walks up to the standing freeplay field and **takes over a policy seat**.
They do not join an empty slot — every seat is already held by a policy — and
they are never dropped into a cog mid-fight. The handoff lands at **that cog's
next respawn**: a "suiting up…" beat, then the human starts a life at spawn.
Leave, and the policy resumes the seat.

The governing constraint: **takeover changes WHO presses, nothing else.** The
human drives the same eight-button `InputState` the policy was pressing. Same
cog index, same team, same fog, same replay record.

## The mechanism: server-side arbitration

The seat's policy **keeps its websocket for the whole episode**. It keeps
receiving its fogged view and keeps sending inputs; the server simply stops
*reading* them while a human drives. There is no bot-process choreography, no
slot vacancy, and no reconnect — which is exactly why the reverse handoff is
free: drop the human's socket and the next frame reads the policy again, mid
stride, with a policy that never stopped playing.

Three moving parts, all in `src/ctf/server.nim`:

- **`SeatTakeover`** — one record per human, keyed by the human's websocket. It
  is *not* a roster registration: a takeover socket never enters
  `playerIndices`, so it never joins, never occupies a slot, and never writes a
  join or leave record. `isPlayerWebSocket` excludes it, which is what keeps it
  out of every join, reset and re-register loop by construction.
- **`advanceSeatTakeover`** — the swap rule, one frame at a time. A pending
  takeover goes live on its cog's next `false -> true` `alive` edge. A cog that
  has not been sampled yet is never an edge, so a human arriving mid-life waits
  that life out.
- **the input gather** — for each seat, if a human is driving that cog, the mask
  is read off the human's socket instead of the policy's. The policy's mask is
  still drained every tick so nothing piles up.

`landSeatTakeoversOnNewMatch` covers the one case the alive edge cannot see: a
match reset empties the roster and re-seats it inside a single locked block, so
no frame ever samples the gap. A new match is a fresh spawn for every cog — the
cleanest handoff moment there is — so anyone still suiting up takes the field
with the whistle.

**Determinism.** Nothing about the sim changes but the source of the bits. The
replay records the applied mask under the same player index it always did, so
playback re-derives the identical game. No hash machinery is touched.

## Zero-diff for league builds

The mode exists only where a config turns it on:

```json
{ "allowSeatTakeover": true }
```

Default `false`. With it off, `/takeover` and `/client/takeover` answer 403,
`appState.takeovers` is empty forever, and every takeover branch is unreachable.
The key is echoed into the recorded config **only when it is on** — the same
rule the puddle, barrier and paintball knobs follow — so a league game's replay
config stays byte-identical to a pre-takeover build. Both properties are pinned
in `tests/test_seat_takeover.nim`.

## The wire

| route | what it is |
|---|---|
| `ws /takeover?slot=N&token=…&name=…` | the human connection for seat N |
| `GET /takeover/status` | seat state as JSON, for the app's "suiting up" beat |
| `GET /client/takeover?slot=N&token=…&name=…` | the demo shell (page + field) |

A dedicated websocket route rather than a flag on `/player`: the stock player
client force-copies `name`/`token`/`slot` onto whatever `address` it is handed,
so a browser reaches this path **with no client change at all**, and the
roster's player path stays untouched.

The seat's configured token is the takeover token — whoever the app hands a seat
to may drive it. One seat takes exactly one human. `name` is the guest display
name the app generates ("Green Rookie"); it is seat metadata the server reports
back, and it never enters the sim, the wire, or the replay.

`/takeover/status` reports, per seat: `state` (`suiting-up` / `driving`), the
resolved `cog`, `cogAlive`, and two masks — `mask`, what the seat **applied**,
and `policyMask`, what the policy **wanted** on that same frame while being
ignored. That pair is the arbitration made visible, and it is the honest answer
to "are my keys actually reaching the field?". Both are the requester's own
seat, so neither leaks anything the fog hides.

## Running the field

```
tools/freeplay.sh                                   # the standing field
FREEPLAY_CONFIG=config.freeplay-demo.json tools/freeplay.sh   # short matches
```

Every seat is filled with a policy and the server serves forever (`maxGames: 0`),
so the field is always up and a browser can join at any moment. The script
prints one takeover URL per seat.

Two things a human-playable field must get right, both learned the hard way:

- **`fastMode` must be off.** It defaults to *on*, and it advances a frame the
  moment every policy socket reports ready — on a box full of local bots that is
  many times faster than the 24 Hz tick a person is playing at. Matches blur
  past and a human's keys land in a game that has already moved on.
- **The binaries are named `freeplay-server` / `freeplay-bot.out`,** not
  `ctf-server`, because a shared dev box routinely runs `pkill -f
  "bin/ctf-server"` from other lanes.

## Known gaps (owned elsewhere)

- **The stock client is arrow-keys-only** — no WASD, no mouse aim. WASD + mouse
  arrive with the Season 2 vendored client (controls lane). The shell page
  passes `player=1`, which the stock client needs to enable input at all when
  its socket path is not `/player`.
- **A takeover seat cannot shout.** Chat is keyed by websocket through
  `playerIndices`, which a takeover socket deliberately never enters, so its
  chat resolves to player index -1 and is dropped. Season 2 pings ride the shout
  channel, so this needs closing before pings ship.
- **The wait can be long.** On a settled paintball field cogs die rarely, so
  "your cog's next respawn" can be minutes away. The match boundary is the other
  landing spot; a freeplay field wants a match length that bounds the wait.
