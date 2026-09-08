# seat_connectivity — "did my seat actually enter the match?"

A small, read-only checker for the Paintbot ladder. It answers one question
for one entrant over a round range: for each episode that entrant appears
in, did their policy process actually complete the match handshake, or did
it silently fail to enter the game before a single tag was ever thrown?

## Why this exists

A seat can be credited a score on the ladder — including a winning one —
while its policy process never actually finished joining its episode.
Community authors have independently reported their own Elite seat logs
stopping at `FAILED: no 0xB0 PlayContext from the server`, and separately
couldn't reconcile a batch of episodes that scored exactly zero. This tool
lets any entrant check their own rows directly instead of guessing.

## What it checks

For each episode where the requested entrant played, it classifies the
appearance as exactly one of:

| Class | Meaning |
|---|---|
| `HANDSHAKE-COMPLETE` | the policy log shows `0xB0 play_context` — the server handed the seat its match context and it is genuinely in the game. |
| `NO-PLAYCONTEXT` | the process ran and connected, but the log ends on `FAILED: no 0xB0 PlayContext from the server` — connected, never handed a context. |
| `NEVER-JOINED` | no policy log exists, and the round/episode record says the seat never joined the lobby inside its join window. |
| `NOT-STARTED` | no policy log exists, and the round/episode record says the platform never started that seat's process at all. |
| `UNKNOWN` | none of the above — reported honestly rather than guessed. |

## Setup

```sh
export SEATCHECK_TOKEN=...   # your own API token — NEVER pass it as a CLI flag or commit it
python3 tools/seat_connectivity/checker.py --entrant <your player name> --rounds 40
```

`SEATCHECK_TOKEN` is read from the environment only; the script never prints
or logs it. Use the same bearer token you already use to authenticate any
other call against your own league account — whatever that is for your own
setup (e.g. a local credentials file, or your own login flow's token). This
script does not perform any login itself and does not depend on any
internal tooling to obtain one.

Optional: `--division <div_id>` to point at a division other than the
default (Paintbot Season 2 Competition).

## The four documented API traps this script encodes (do not rediscover them)

Found in this repo's own knowledge base — cited by file so a future reader
can see the original incident, not just take our word for it:

1. **`/v2/rounds` silently ignores `league_id=`** (and any offset/page/skip
   param) — the only working server-side filter is `division_id=`. A round
   has no top-level `league` field either; it's `null` — the league only
   exists nested at `round.division.league.id`.
   (`ctf-rounds-endpoint-filter-and-offset-traps.md`, `ctf-coworld-scoped-queries-cross-leagues.md`)
2. **Pagination on `/v2/rounds` returns overlapping pages**, not disjoint
   ones — a multi-page sweep can see the same round 2-3x. Always dedupe by
   `round["id"]`. (same two files, addendum)
3. **`player_name` lies on filler seats** — a scripted filler seat can carry
   a real player's display name even though it is a different, scripted
   policy. Always require `is_filler` is falsy in addition to a name match.
   (`ctf-api-playername-lies-on-filler-seats.md`)
4. **Coworld-scoped queries cross leagues** — three leagues share the same
   Paintbot coworld, so anything scoped by coworld/game instead of
   league/division silently blends in another league's episodes. Always
   scope by `division_id`, never by coworld. (`ctf-coworld-scoped-queries-cross-leagues.md`)

Two more traps found while building this tool (not in the original four,
but real and worth naming so nobody re-pays for them):

5. A prior session's notes said the policy-log download route
   (`/v2/episode-requests/{id}/{policy_version_id}/policy-logs/{agent_idx}`)
   only accepts `X-Auth-Token`, not `Authorization: Bearer` (Bearer 404s
   there). Re-verified live 2026-09-07: both header styles returned 200
   with identical bodies today. This script sends both headers on every
   request regardless, since that costs nothing and hedges against this
   being version-dependent rather than fixed for good.
6. **An episode's `error` text can name a *different* seat's slot** (e.g.
   `"player slot 12 never joined the lobby..."`) in an episode where the
   requested entrant played a different position. Feeding that text
   straight into the classifier misattributes a stranger's no-show to the
   entrant being checked — caught live during this tool's own first real
   run (see "Real run" below). The script only lets error text drive a
   seat's classification when it names no specific slot, or names that
   seat's own position.

## Real run

Run live 2026-09-07 against our own entrant (`softmaxwell`) over the 30 most
recent Paintbot Season 2 Competition rounds at the time (rounds 4345-4374,
engine builds 0.7.345/0.7.346/0.7.347). Full transcript in
[`example_output.txt`](example_output.txt) (374 lines); excerpt:

```
seat-connectivity check for entrant='softmaxwell'

 round  episode_id                              class                 note
----------------------------------------------------------------------------------------------------
  4345  3ddb7d58-f01b-49d9-9b26-cf859270de9a    HANDSHAKE-COMPLETE
  4345  ereq_05f6ed62-d7f8-4850-8dff-2334931148ba  HANDSHAKE-COMPLETE    Game container exited with code 1
  ...
  4360  ereq_837a925c-f47c-4db4-827e-451c978f39d9  NOT-STARTED           player slot 12 never joined the lobby within 7200 lobby tick
  4360  ereq_16fed89f-61d6-40d2-ab4d-d9a12a299a72  HANDSHAKE-COMPLETE    Kubernetes did not start every player process before the gam
  ...
  4374  b2b086a1-a28f-49ba-a1e0-10bc43ff7113    HANDSHAKE-COMPLETE

Totals:
  HANDSHAKE-COMPLETE   330
  NO-PLAYCONTEXT       0
  NEVER-JOINED         0
  NOT-STARTED          30
  UNKNOWN              0
  TOTAL                360

Engine builds observed: 0.7.345, 0.7.346, 0.7.347
```

Two things worth calling out about this real run:

- **Round 4345's `Game container exited with code 1` episode still shows
  `HANDSHAKE-COMPLETE`** — the container crashed later in the match, but our
  seat's own policy log genuinely shows `0xB0 play_context` before that. The
  episode-level failure and our seat's own handshake status are two
  different facts, and the tool keeps them separate rather than assuming an
  episode-level failure means our seat never got in.
- **A correctness bug this real run caught before publish:** several
  episodes' `error` text names a specific seat by slot number (e.g. `"player
  slot 12 never joined the lobby..."`). An early version of this script fed
  that text straight into the classifier and got 5 false `NEVER-JOINED`
  results — round 4360's own participant data shows our entrant's seat was
  at `position: 13` in every one of those episodes, never slot 12 or 14. The
  script now parses any slot number out of the error text and only lets it
  drive the classification when it names OUR OWN seat's position; otherwise
  it falls back to what our own policy-log fetch itself proved (here, a
  clean 404 either way → `NOT-STARTED`, since no log existed for our seat in
  those episodes either). See the `_SLOT_RE` guard in `checker.py`.

No `NEVER-JOINED`/`NO-PLAYCONTEXT` appeared for our own entrant in this
particular window — all 30 non-`HANDSHAKE-COMPLETE` appearances were the
platform never starting/producing a log for our seat's process at all
(`NOT-STARTED`), consistent with `"Kubernetes did not start every player
process before the game's player-connect timeout"` being the dominant cause
in these rounds.

## Unit test

```sh
python3 tools/seat_connectivity/test_classify.py -v
```

Feeds the classifier representative log/metadata snippets (a real `0xB0`
success line, the documented `FAILED: no 0xB0 PlayContext` line, missing-log
+ lobby-timeout metadata, missing-log + container-failed metadata, and an
unrecognized blob) and checks it returns the expected class for each.
