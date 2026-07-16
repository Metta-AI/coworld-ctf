# CTF eval / A-B harness (headless, in-process)

Runs a full 8v8 CTF game with **no websocket and no real-time clock**, driving
the shipped baseline's byte-identical `decide()` directly against the real sim.
It is both the "do the bots actually hit each other" accuracy proof and the
paired-seed A/B rig for a sharper policy (control = baseline on both sides).

## Build & run

```sh
export PATH="$HOME/.nimby/nim/bin:$PATH"; nimby use 2.2.10
nim c -d:release --opt:speed -o:players/baseline/eval/harness.out \
  players/baseline/eval/harness.nim
./players/baseline/eval/harness.out --games 20 --seed 200 --ticks 10000
```

Flags: `--games N` (episodes), `--seed S` (first episode seed; episode `g` uses
`S+g`), `--ticks T` (max ticks/episode, hosted default 10000), `--players P`
(default 16). Prints a per-episode row (kills / captures / shots / hit% per
team, winner, ticks) and a totals block.

## How it stays faithful to the hosted game

- **Real fogged view per slot.** Each tick the engine wrapper calls
  `buildSpriteProtocolPlayerUpdates` (the exact proc the live server uses — real
  FOV/fog culling, aim indicators, delta-encoded object deletes), runs it
  through `blobFromBytes`, and feeds the identical blob into a real
  `ProtocolClient`. A `PlayerViewerState` **and** a `ProtocolClient` persist per
  slot across ticks (mirroring `src/ctf/server.nim`), so the delta encoding
  sheds objects that leave a bot's vision.
- **Real decision path.** `harness.nim` `include`s `../baseline.nim`, so it
  drives the shipped `decide()` and its per-frame preamble (tick advance, aim
  dead-reckon, `mapCameraReady` gate, one-shot nav build) unmodified.
- **Fire edge.** Masks are decoded with `decodeInputMask` and stepped as
  `sim.step(cur, prev)`; a fresh A-press (`attack and not prev.attack`) arms the
  5-tick windup exactly as the baseline self-pulses fire (1 decide : 1 step).
- **Per-bot RNG.** Hosted bots are separate processes each seeded
  `randomize(slot*7919+1)`. Each driver gets its own `Rand` swapped into the
  global around `decide`, so one seat's draws never perturb another's. CTF
  gameplay is otherwise fully input-deterministic (the sim's `rng` field is
  never consumed), so the episode seed salts each seat's stream to give a batch
  genuine per-episode variety while keeping every run reproducible and paired.

## Touch points in shipped code (both behavior-neutral)

- `players/baseline/baseline/protocols.nim`: `applySpritePacket` exported +
  `feedInProcessPacket*` added (in-process one-packet frame feed).
- `players/baseline/baseline.nim`: the websocket `isMainModule` entrypoint is
  guarded with `and not defined(ctfEvalHarness)`. The shipped player builds
  **without** that define, so its runtime behavior is unchanged; this harness
  sets it in `config.nims`.

## A/B a sharper policy

`HUNTER_SLOTS="0,2,4,..."` selects which seats run the forked "hunter" policy
(Red seats are even). It is threaded through the loop but is a no-op until a
hunter `decide` variant exists; with only the baseline present every run is an
all-baseline control.
