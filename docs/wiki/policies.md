*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 17`; treat details as unconfirmed.**

A policy is a **`linux/amd64` Docker image plus a `run` argv** — not wasm, not a
weights blob, not a source bundle, as the artifact submitted. What runs, or
lives, inside that image once it starts is a separate question from what the
artifact itself is, and this page does not address it. Fetching a policy means
pulling that image; running one means starting a container from it and
executing the argv as its command. The engine gives a running policy container exactly one thing to reach
it by — the environment variable `COWORLD_PLAYER_WS_URL` — and nothing else:
the container dials out over that websocket and is seated into one [[episode]]
for as long as it stays connected, trading labelled sprite objects for one
[[action-mask]] byte every tick.

**Nothing about connecting checks that the two sides agree on an engine
version.** A policy built against a different engine than the one it connects
to still seats, still plays an entire episode, and still produces a scored
result — with no error, no warning, and no signal anywhere that the result
carries no meaning. See below for why.

## Rules

### What an entrant provides

Every runnable the platform knows about — the engine itself, a bundled player,
an entrant's own policy — is described the same way: an image plus the `run`
argv the platform executes as that container's command.

**Whether an image is actually pullable splits along one line — coworld-packaged
versus entrant-submitted — not along engine versus baseline.** The engine and
the baseline are each buildable straight from source today — the baseline's
own build is the shipped, open-source artifact [[baseline-policy]] points to
— and each has its own `Dockerfile` (see below). But once either one ships as part
of a coworld version — which is how a match actually seats one — the
platform's own coworld lookup resolves it to a digest-pinned image on a
public registry that needs no login or token to pull, and the same lookup
names the exact source commit the image was built from. An entrant's own
submitted policy sits on the other side of that line: the platform's own
published schema marks a policy version's container-image field optional, and
no publicly reachable record for one ever carries a registry address —
checkable by any entrant against their own policy version's record. There is
no `docker pull` path for a submitted policy today, for its owner or anyone
else. This is a live platform fact, not an engine constant, and either side
of it can change independently of the GV/Glory stamp above.

### Running the artifact

Whatever the class, a fetched image is run the same way — no per-language or
per-team adapter:

```
docker run --rm --platform linux/amd64 \
  -e COWORLD_PLAYER_WS_URL='ws://…' \
  <image> <run argv>
```

`<run argv>` is exactly the argv from that artifact record. The baseline
policy's own packaging matches this shape exactly: a multi-stage `Dockerfile`
that compiles the baseline's Nim source in a build stage, then copies just
the binary into a slim final image ending `CMD ["/bin/baseline"]`.

### Seating into an episode

The seat protocol is one environment variable. A container that receives
`COWORLD_PLAYER_WS_URL` connects out to that websocket, plays until the game
ends, and exits when the runner stops it — there is no adapter to write and no
handshake beyond opening the socket. Locally, that URL carries the seat and an
auth token as query parameters, e.g. `ws://host:2000/player?slot=1&token=…`; one
running container fills one seat for one [[episode]]. That socket is where the
sprite-and-action-mask exchange named above happens, once per tick for as long
as the episode runs — see [[submitting-a-policy]] for an implementation
walkthrough.

### No version handshake at connect time

**Neither side exchanges a version at connect time.** `GameVersion` (a plain
string constant baked into the binary at compile time) has no field of its own
on the wire — a connecting container is never asked what it was built against,
and never volunteers it. Seat a policy compiled against a different engine and
it still connects, still gets seated, still plays an entire episode start to
finish, and still produces a score — indistinguishable, by anything either
side can observe, from a match that actually meant something. Getting the
engine versions to agree is therefore something you have to establish before
the container starts; the connection itself gives you no way to check it once
running.

## Version history

| Version | Change |
| --- | --- |
| Wiki | This page previously said the engine and baseline have no published, pullable image, full stop — true only for building straight from source, and mistaken for the whole picture of how either one reaches a match. Once either ships as part of a coworld version, its image is public, digest-pinned, and needs no credentials to pull. An entrant's own submitted policy is the opposite case, and stays that way: no publicly reachable record for one ever carries a registry address. |

## Gaps

- Whether a policy container can be re-seated into a second episode without
  restarting it, or whether one process is expected to exit at the end of every
  episode.
- How the platform assigns and rotates the slot/token pair a production seat
  uses — the `slot=`/`token=` query form above is confirmed only for local dev.
- Whether anything on the platform's own submission path checks a submitted
  image's `GameVersion` before it is ever seated, given that the wire itself
  cannot.

## See also

- [[submitting-a-policy]] — how an image gets built and connected
- [[baseline-policy]] — the one shipped, inspectable policy
- [[episode]] — what a policy is seated into
- [[perception]] — what a seated policy actually observes

## Discussion

Advice about how to structure a policy's own code, which language to write it
in, or how to size its container belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
