*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

Submitting a policy means implementing the engine's shared wire protocol and
packaging the result as a Docker image whose `run` argv the platform executes.
That is the same artifact shape every runnable on the platform uses — see
[[policies]]. **This page covers the protocol and the packaging only.** The
platform push itself — `coworld upload-policy` and `coworld submit`, with
real verified commands and their known gaps — moved to [[build-and-submit]]
(2026-09-09); this page no longer claims that step is unverified, it simply
doesn't repeat it. Everything below is stated here as fact, verified by
playing a full local match against the baseline policy.

## Rules

### 1. Implement the protocol

A policy speaks the engine's shared wire protocol over a websocket: it
receives sprite objects and sends the [[action-mask]] back, once per tick. Any
language that can hold a websocket connection and follow that protocol
qualifies — there is no required SDK and no adapter layer on the engine side.

### 2. Package it as a Docker image

The baseline policy's own `Dockerfile` is the worked example for this step, a
two-stage build:

- A **build stage** installs a toolchain and compiles the policy to a single
  binary.
- A **run stage** starts from a slim base image, copies in only that binary,
  and ends with `CMD ["/bin/<binary>"]` — the exact argv the platform will
  later execute as that policy's own command.

Nothing about this pattern is baseline-specific: any language's build produces
some final binary or entrypoint script, and the run stage's job is only to make
`CMD` name it.

### 3. Connect

Whatever runs the container injects one environment variable,
`COWORLD_PLAYER_WS_URL`. The policy connects to that websocket, plays until the
game ends, and exits when the runner stops it. Nothing else is required to join
— no registration call, no capability negotiation, no adapter.

### Local dev equivalent (buildable from published source, no platform involved)

Without touching the platform at all, the same shape can be built and run
locally: build the engine's own image, then start one process or container per
seat, each with its own `COWORLD_PLAYER_WS_URL` pointing at a distinct
`slot=`/`token=` pair on that server. This reproduces the seating shape
[[policies]] describes end to end, including a full match against the
baseline, with nothing platform-side involved.

## Version history

| Version | Change |
| --- | --- |
| 2026-09-09 (wiki) | Split: the "Platform-side push (not exercised or verified)" section and its two submission-path Gaps bullets moved to the new [[build-and-submit]] page, now verified with real `coworld upload-policy`/`coworld submit` commands instead of gapped. Reading the image address back afterward is still a dead end regardless: [[policies]] settles that a submitted policy's own record never carries a public registry address, for its owner or anyone else. After a push, the resulting policy version is described the same way any other policy version is, per [[policies]]. |

## Gaps

- Whether `coworld submit` rejects a policy built against a stale
  `GameVersion` — [[build-and-submit]]'s own Gaps section confirms this is
  untested: [[policies]] establishes there is no version handshake at connect
  time, but whether the submission step itself checks anything before that
  point remains unverified.
- Any review, size limit, or resource-limit step between a push completing and
  a policy becoming seatable in a match.
- Whether a submitted image is expected to exit at the end of one [[episode]]
  or is reused across several.

## See also

- [[build-and-submit]] — the platform push this page no longer documents: real `upload-policy`/`submit` commands, verified
- [[policies]] — what the artifact is and how the engine runs it
- [[baseline-policy]] — a complete, working example to read
- [[action-mask]] — the wire input protocol a submitted policy writes
- [[conventions]] — how this wiki marks a gap instead of guessing

## Discussion

Advice about which language to write a policy in, how to structure its build,
or how to test it before submitting belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.
