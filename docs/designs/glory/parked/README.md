Identity on `over` is keyed by seat position at registration-time env parsing, not by the
platform's own name-keyed reward/roster identity, and is never re-derived after startup:
fillers carry a declared-but-unverified entry with no corresponding live occupant; a
mid-match reseat (bot departs, a different bot or a human takeover claims the same slot)
leaves `over.identity` pointing at whichever identity the platform declared before the
episode began, silently wrong for the rest of the match. The platform must key by seat
NAME (matching `/reward` and roster) when attributing `over.identity` to a live occupant,
or must re-issue `COWORLD_SEAT_IDENTITY` (or an equivalent live-update channel) on every
seat change; this repo's consumer is a correctly-documented, correctly-tested passthrough
of whatever the platform sends and cannot fix a platform-side index/name mismatch from
inside the game process. No code changed on this branch: the mapping's fragility is
already self-documented in `sim_types.nim`'s `SeatIdentityEntry` comment and matches its
own existing test suite (`tests/test_seat_identity.nim`) — this trace's contribution is
empirical proof, on a real running episode's real wire, that the fragility is real, not
merely theoretical.

metta #22382 was amended on 2026-09-10 (58bdccdd) to key COWORLD_SEAT_IDENTITY by seat NAME
(game_config.players[].name = player.address); when it lands, this consumer is re-cut to
look up identity by NAME, not slot index.
Reseat/takeover staleness is still open on the platform side (no re-issue channel); it is a
separate item, not solved by name-keying.

Parked until metta #22382 keys COWORLD_SEAT_IDENTITY by seat NAME or re-issues it on every
seat change.

## What this is

`seat-identity-consumer.patch` in this directory is the game-side half of the seat-identity
channel (metta PR #22382, `dispatcher: forward per-seat platform identity to the game
runtime`), extracted BY HAND from `origin/maxwell/glory-s8-ship` @ `eb8e8be2` — the old,
wire-batched cut of the S8 ship that bundled this consumer with an unrelated GameVersion
bump. It adds:

- `SeatIdentityEntry` (`src/ctf/sim_types.nim`) — one seat's platform identity: `slot`,
  `playerId`, `policyVersionId`, `policyName`, `roundId`, `episodeId`, `isFiller`.
- `SimServer.seatIdentity: seq[SeatIdentityEntry]` (`src/ctf/sim_types.nim`) — appended at
  the true end of the type, flatty append-only, per this file's own layout discipline.
- `CoworldSeatIdentityEnv` / `parseSeatIdentity` (`src/ctf/server.nim`) — reads
  `COWORLD_SEAT_IDENTITY` once at live server startup, never on a replay-loaded run, never
  re-read on a mid-match reset.
- `over.identity` emission (`src/ctf/broadcast.nim`) — a verbatim echo of
  `sim.seatIdentity`, omitted from the wire entirely when empty (every local/dev/test run
  and every non-platform-hosted episode).
- `tests/test_seat_identity.nim` — the full suite proving both halves (parse + emission).

The patch deliberately **excludes** `eb8e8be2`'s `GameVersion 63->64` bump and
`ReplayCompatibleGameVersions` allowlist edit in `sim_types.nim` — those belong to whichever
ship actually changes the wire; this consumer does not need a GameVersion of its own to sit
parked, and the GLORY GRADIENT S8 ship this directory's sibling files belong to is
explicitly SCORING ONLY (GLORYVERSION 17->18) and does not touch the wire.

## Why it is parked, not shipped

See the constraint paragraph above, in full at
`~/.ctf/knowledge/glory-gradient/00x-s8-seat-identity-trace.md` — a real-episode trace on
the old branch's own release build proved the fragility empirically (a disconnect+reconnect
re-seat leaves `over.identity` pointing at the departed occupant's declared identity for
the rest of the match), not merely as a theoretical reading of the code.

## How to unpark

1. Confirm metta #22382 (or its successor) keys `COWORLD_SEAT_IDENTITY` by seat NAME, or
   re-issues it on every seat change (departure, reconnect, takeover).
2. Re-derive this patch against the then-current `main` (the hunks above were cut from a
   commit that also carried a GameVersion bump this ship did not take — check for drift
   before applying by hand).
3. This DOES require its own GameVersion bump when it ships (a new flatty keyframe field,
   `SimServer.seatIdentity`) and its own full fixture re-record — it was never free just
   because it carries no GLORYVERSION/pricing weight of its own.
4. Land `tests/test_seat_identity.nim` alongside it, unmodified from this patch unless the
   re-derivation required changes.
