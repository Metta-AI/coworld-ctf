# The Pre-Match Vote Wire: 0xA4 Ballot, 0xB3 Vote State, Record 0x17

**Status:** DESIGN, final layouts for reservation · **Date:** 2026-08-31 ·
**Author:** Maxwell's coding agent · **Reviewers:** James (owns the opcode
and record space, the manifest, and the shell handshake this rides on),
Maxwell (ballot content, scheduling) · **Canonical home:** this file, in
`coworld-ctf`. **Builds on:**
`docs/designs/prematch-vote-phase-2026-08-31.md` (PR #319, merged — the
ballot's product design: four options A-D, A/B/C are complete certified
episode configs, D is "random," section 5's tally and tie rules) and
`docs/designs/strategy-play-calling-shell-2026-08-29.md` (the shell this
extends; cited below as **Shell:line**).

This document does one thing: it turns PR #319 §4(b)'s sketch — "a
dedicated packet pair... modeled on the `PlayCall` transaction" — into
byte-exact layouts, in the exact documentation style of the landed
`0xA3`/`0xB2`/`0x13` triple (Shell:489-490, 2467-2492, 267-270), using the
opcodes and record number already pencilled for this purpose: **`0xA4`**
(ballot, client→server), **`0xB3`** (vote state, server→client), and
replay record **`0x17`**. Two structural questions PR #319 left open for
James (§9, Q1 and Q2) are answered here as proposals, not decisions —
flagged in section 6.

---

## 1. Where voting sits in the lobby phase

PR #319 §2 sketched three shapes and left the choice to James; this
document assumes shape 2, **"defer `PlayContext`'s full gameplay payload
until the vote closes"** (prematch-vote-phase-2026-08-31.md:90-97),
because it is the one that changes nothing about container-start order or
the section-10 map barrier — only the timing of one already-deferrable
send. Concretely, this extends Shell §9.2's three-substate table
(Shell:2451-2455) with a fourth substate, **`voting`**, entered after
`joining` and exited before `chatting` begins:

| Substate | Entry | While in it | Exit |
|---|---|---|---|
| `voting` | once per episode, when `joining` exits and any play seat is configured | ballot casts (below) are admitted; the `startWaitTicks` countdown is held, exactly as `chatting` holds it (Shell:2454); `PlayContext`'s gameplay payload send is **deferred** for every play seat until this substate exits — until then a play seat that registers receives the existing pre-activation **control-only `PlayView`** frames (`viewLen = 0`, Shell:522-526) as if it had not yet been sent `PlayContext` at all, which is a direct generalization of the existing pre-activation rule rather than a new mechanism: today `PlayContext` sends "at registration ... its gameplay payload depends only on the mode, map, and the configured closed roster of section 5.1, all known at registration" (Shell:521-522); in a vote-enabled episode that precondition is false until resolution, so the send point moves from registration to resolution and the control-only interim is unchanged. Uploads, calls, and acknowledgments flow exactly as in the existing pre-activation state (Shell:527-528) — nothing about them depends on knowing the map or mode. | `voteTicks` elapses, **or** every configured play seat has cast a valid ballot (early resolution — see judgment call J1) |
| `chatting` | `voting` exits | unchanged from Shell:2454 | unchanged |

`voting` precedes `chatting` (not the reverse) so that lobby chat, once it
starts, can refer to the resolved bundle ("we got map B") rather than
negotiating blind. `joining`'s roster-sufficiency and `playSeatBindTicks`
presence-budget rules (Shell:2453) are untouched; `voting` is simply
inserted where `chatting` used to be first in line.

## 2. `0xA4` BallotCast — client to server

Fixed-size, mirroring `StatusAck`'s (`0xA2`) shape rather than the
variable-length `LobbyChat`/`PlayCall` shape, because a ballot is a choice
among four fixed options, not free text or JSON:

```
u8 op (0xA4), u8 ver (1), u64 castId, u8 option, u8[5] reserved (zero)
```

Total = **16 bytes, fixed** — the same size as `StatusAck`. `option` is
`0` = A, `1` = B, `2` = C, `3` = D; any other value is rejected
(`ballotOption`). `castId` is client-chosen and numerically monotonic per
seat, exactly the `uploadId`/`proposalId` discipline (Shell:743-759):

- Accepted only during the `voting` substate; a message arriving outside
  it is rejected (`votingClosed`), mirroring `LobbyChat`'s `lobbyClosed`
  (Shell:2483).
- **A seat's vote is its latest accepted cast.** A new `castId` with a
  different `option` **replaces** the seat's current declared vote — the
  same "current declaration" model `PlayCall` uses (Shell:591-593) — so
  re-voting is not a special case, it is the general case evaluated once
  at resolution.
- A resend of an already-accepted `(castId, option)` pair is a silent
  no-op: no new ordinal, no new broadcast, no rate-budget charge (exactly
  "returns the original outcome ... without re-applying or re-recording
  anything," Shell:747-749). A `castId` reused with a *different* option
  is rejected (`castIdConflict`); a `castId` at or below one already used
  by that seat is rejected (`castIdStale`), the same floor rule as
  uploads and calls (Shell:749-750).
- Rate caps, admitted at receive: at most `BallotCastMaxPerSeatPerPhase`
  casts per seat per phase, no two closer than `BallotCastMinSpacingTicks`
  ticks, an excess message dropped at admission with the overflow counter
  — the identical shape as `LobbyChat`'s caps (Shell:2480-2483), values
  proposed in section 4.
- Ballot casts count toward the existing per-seat-per-tick socket message
  and byte classification budgets (Shell:781-782); no separate budget is
  introduced there.
- **Acknowledgment model: mirrors `LobbyChat`, not `PlayCall`/
  `ModuleUpload`.** A cast has no durable `StatusEntry`; its own broadcast
  back (the `0xB3` kind-0 packet, section 3, sender included) is the
  acknowledgment, exactly as a `LobbyChat` sender's own `0xB2` echo is its
  only confirmation. This is a judgment call (J2, section 6) — the heavier
  `StatusAck`/status-list machinery exists for uploads and calls because
  their outcomes are asynchronous (compile, validation) and must survive
  reconnect independent of chat; a ballot cast's outcome is synchronous
  and its whole value is exhausted the moment it either lands in the
  broadcast/record stream or doesn't.

## 3. `0xB3` VoteState — server to client

One opcode, two fixed-size payload shapes selected by a `kind` byte read
right after the version byte, both totalling **18 bytes**:

```
kind 0 (cast):     u8 op (0xB3), u8 ver, u8 kind (0), u64 ordinal,
                   u32 tick, u8 seat, u8 team, u8 option
kind 1 (resolved): u8 op (0xB3), u8 ver, u8 kind (1), u64 ordinal,
                   u32 tick, u8 category, u8 tieBreakDrawn, u8 finalOption
```

`kind` outside `{0, 1}` rejects the packet at the decoder (same "any other
value rejects the packet" discipline as the version byte, Shell:479).

- **Kind 0** broadcasts an accepted `0xA4`, one message per packet,
  **broadcast to every play seat, sender included, in ordinal order,
  never coalesced** — byte-for-byte the same delivery contract `LobbyChat`
  (`0xB2`) has (Shell:490, 2501-2507). Identity is `seat`/`team` only, no
  display name, the same "a seat is a seat" rule (Shell:2498-2499). Votes
  are **open, not secret-ballot** (judgment call J3, section 6): every
  play seat sees every cast live, consistent with the lobby's existing
  "no fog" philosophy for pre-match negotiation (Shell:2396) and with
  PR #319 §8's framing of voting as a visible strategic surface, not a
  blind one.
- **Kind 1** is sent exactly once per episode, when `voting` exits, to
  every play seat (and carries the ordinal that immediately follows the
  last kind-0 ordinal). `category` is the plurality-winning bucket among
  A/B/C/D (`0`-`3`); `tieBreakDrawn` is `1` if `category` needed the
  episode-seed tie-break among tied leaders, else `0`; `finalOption` is
  **always** the resolved bundle, `0`-`2` (A/B/C) — when `category < 3`,
  `finalOption == category` trivially; when `category == 3` (D), a second,
  independent seed draw over {A, B, C} produces `finalOption` (section 5).
  A client never has to branch on `category` to learn the outcome — it
  reads `finalOption`.
- Delivery, coalescing, and reconnect-replay reuse the existing
  `LobbyChat` machinery verbatim: the same outbound queue
  (`MaxOutboundEvents`/`MaxOutboundBytes`, Shell:2518, unchanged), the
  same ordinal-based dedup on a rebinding socket, the same "never
  coalesces `0xB2`" rule extended to `0xB3` (Shell:2554). No new
  transport constant is needed — the existing `H`-based replay-on-bind
  cursor (Shell:2508-2513) generalizes directly because `0xB3` is, like
  `0xB2`, ordinal-stamped and per-message.

## 4. Replay record `0x17`

Mirrors `RecLobbyChat` (`0x13`)'s role and placement exactly: a global,
per-episode array (not per-seat), stored in ordinal order, placed within
one time value after that tick's join/leave/rebind records (Shell:271-278)
and before any call record (`0x10`) — the identical tick-ordering rule
`0x13` already follows (Shell §9.3). Same two `kind`s as `0xB3`, both
**17 bytes fixed** (one byte shorter than the wire packet: `type` +
`replayTimeMs` replaces `op` + `ver`, and there is no `tick` field, the
same trim `0x13` already makes relative to `0xB2`):

```
kind 0 (cast):     u8 type (0x17), u32 replayTimeMs, u8 kind (0),
                   u64 ordinal, u8 seat, u8 team, u8 option
kind 1 (resolved): u8 type (0x17), u32 replayTimeMs, u8 kind (1),
                   u64 ordinal, u8 category, u8 tieBreakDrawn,
                   u8 finalOption
```

**Hash-coupled, not excluded.** `LobbyChat` (`0x13`) is explicitly
excluded from the game hash because "it drives no gameplay" (Shell:2579).
A ballot is the opposite: its resolution selects the map, mode, and
roster the rest of the episode simulates under (prematch-vote-phase-
2026-08-31.md:214-216), so record `0x17` is proposed to ride the gameplay
hash chain **the same way the lifecycle records `0x14`-`0x16` already do**
— "covered by the gameplay hash chain like [joins and leaves], not by a
manifest arm" (prematch-vote-phase-2026-08-31.md:210-212, citing
Shell:876-878) — rather than getting its own excluded-but-integrity-
checked global manifest arm the way `0x13` does. Concretely: **no change
to `RecManifest` (`0x12`) is proposed**, because hash-coupled records need
no separate arm, the same reason `0x14`-`0x16` need none today. This is
the single largest judgment call in this document (J4, section 6) and is
explicitly flagged for James — it resolves PR #319 §9 Q1 by choosing the
"lifecycle record" precedent over the "lobby chat" precedent, which PR
#319 itself already flagged as "very likely its own GV claim" (prematch-
vote-phase-2026-08-31.md:216-223); this document does not name that
GameVersion, only the record shape it would cover.

**What a replaying client reconstructs from `0x17` alone,** given the
episode's already-launch-known roster of configured play seats and
deterministic seed (no new entropy source enters the wire — section 5):

1. The full ballot transcript: every accepted cast, who cast it, when,
   and what it declared (kind-0 entries).
2. The exact same tally: fold each play seat's *latest* kind-0 entry
   before the recorded kind-1 entry's ordinal into one of four buckets
   (A/B/C/D); any configured play seat with no kind-0 entry counts as an
   implicit D (abstention, PR #319 §5).
3. The exact same resolution, independently recomputed by re-running the
   plurality-and-tie-break algorithm of section 5 against (2) and the
   episode seed — which must equal the recorded kind-1 entry's `category`/
   `tieBreakDrawn`/`finalOption`. A mismatch is corruption, caught by the
   same per-seat/per-tick hash-chain verification that already catches a
   tampered `0x14`-`0x16` record, with no new negative-control test class
   needed (a direct consequence of J4).
4. Which of the launch config's A/B/C bundles (map, mode, roster) the
   rest of the recorded episode plays out under — the same fact the live
   client learns from its deferred `PlayContext` (section 1) — before the
   first playing tick.

## 5. Tally, re-vote, and the two-stage random draw

Restating PR #319 §5 precisely enough to implement, with the parts this
document adds to make it wire-exact:

1. **Bucketing.** Every configured play seat contributes exactly one
   vote to exactly one of four buckets {A, B, C, D} at the tick `voting`
   exits: its latest accepted `0xA4` before that tick, or an implicit D
   if it cast none (PR #319 §5, "abstention folds into the tally as an
   implicit D vote").
2. **Plurality.** The bucket(s) with the highest count are the leaders.
   One leader: that bucket is `category`. Multiple tied leaders: the
   episode's own deterministic seed draws uniformly among the tied
   leaders (PR #319 §5, "ties break uniformly at random from the
   episode's own deterministic seed... no new entropy source") —
   `tieBreakDrawn = 1`, `category` = the drawn leader.
3. **D resolves, never wins outright.** If `category == D`, a second,
   independent uniform draw from the same seed picks `finalOption` from
   {A, B, C} — "it resolves to a uniform random draw over A, B, C — never
   a fourth, uncertified config" (PR #319 §5). If `category != D`,
   `finalOption = category` and no second draw happens.
4. **The seed itself never appears on the wire** — not in `0xA4`, not in
   `0xB3`, not in `0x17`. It is the episode's existing launch-config seed
   (`"seed": 679961`-style, or BR's `mapSpec.genSeed`, PR #319 §5), already
   available to a replaying client from the same launch config that names
   what A/B/C *are*. The wire and the record carry only the **outcome**
   of applying it (`tieBreakDrawn`, `finalOption`), which is what makes
   `0x17` alone sufficient for reconstruction (section 4) without
   re-deriving or transmitting entropy.
5. **A re-vote is not a special case.** Because bucketing (step 1) only
   ever looks at each seat's *latest* accepted cast, a seat that votes B
   then changes to C before `voting` exits is counted for C, full stop;
   its earlier B cast remains in the `0x17` transcript (for auditability
   and strategic legibility — other seats saw it live, section 3) but
   contributes nothing to the tally.

## 6. Judgment calls and open questions

**Judgment calls made here** (documented, not blocking — flagged so
James can overrule any of them without this document being wrong about
anything else):

- **J1 — early resolution.** `voting` exits at `voteTicks` **or** when
  every configured play seat has cast, whichever is first, rather than
  always running the full timer the way `chatting` does. Chat is
  open-ended prose with no natural completion signal; a ballot is a
  closed four-way choice that has one the instant every seat has spoken.
- **J2 — acknowledgment model.** `0xA4` follows `LobbyChat`'s
  broadcast-is-the-ack model rather than the durable `StatusEntry`/
  `StatusAck` model uploads and calls use (section 2).
- **J3 — open ballot, not secret.** Votes broadcast live to every play
  seat as they're cast (section 3), matching the lobby's existing
  "no fog" stance rather than revealing only the final tally.
- **Proposed limits and defaults** in section 7 (`voteTicks`,
  `BallotCastMaxPerSeatPerPhase`, `BallotCastMinSpacingTicks`) are sized
  by analogy to `lobbyChatTicks` and `LobbyChatMaxPerSeatPerPhase`, not
  measured; P0-style retuning is expected once real casts are run.

**Genuinely open, his surface** (per the standing rule that most
"questions for James" collapse into decisions we can make inside his
format contract — these three do not, because they touch the number
space, the manifest, or the handshake directly):

1. **The number reservation itself.** `0xA4`, `0xB3`, and `0x17` are
   used throughout this document as already pencilled; this document is
   the "proposed layout" his reservation commit was waiting on
   (prematch-vote-phase-2026-08-31.md, task framing). Formal ask: land
   them as shown in Appendix A.
2. **J4 — hash-coupled `0x17`, no new manifest arm (section 4).** This is
   the one ruling PR #319 explicitly left as "flagged, not decided"
   (§9 Q1). If James prefers the excluded/manifest-arm shape instead (to
   keep the ballot out of the game-hash-chain GameVersion bump, matching
   `0x13` rather than `0x14`-`0x16`), `RecManifest` (`0x12`) would need a
   new global arm — record count + ordered-chain hash of the `0x17`
   array, the same shape `0x13`'s transcript arm already has (Shell §9.3)
   — and this document's section 4 reconstruction guarantee would rest on
   that arm's integrity check instead of the hash chain. Either shape is
   fully specified by this document; only the choice is his.
3. **Whether the `voting` substate and the `PlayContext`-defer mechanism
   (section 1) land cleanly inside his actual handshake code as
   described**, or need a hook the description above doesn't anticipate.
   The mechanism is proposed as a pure generalization of the existing
   pre-activation control-only-frame rule (Shell:521-526) with no new
   state — but confirming that's true of the real implementation, not
   just the spec prose, is his call, the same way PR #319 §9 Q2 framed it
   ("mechanical... not architectural").

## 7. Additions to the §4.3 limits table

Same format as the existing table (Shell:765-794): rationale parenthetical
inside the Limit cell, one row per constant.

| Limit | Value |
|---|---|
| Ballot option count (`A`/`B`/`C`/`D`; fixed by the product design, PR #319 §1, not configurable) | 4 |
| `BallotCast` packet size (`0xA4`, fixed) | 16 bytes |
| `VoteState` packet size (`0xB3`, both kinds, fixed) | 18 bytes |
| Ballot record size (`0x17`, both kinds, fixed) | 17 bytes |
| Ballot casts per seat per phase / minimum spacing (`BallotCastMaxPerSeatPerPhase` / `BallotCastMinSpacingTicks`; tighter spacing than chat's 24 ticks because a fixed four-way choice needs no drafting time) | 8 / 4 ticks |
| Vote phase length (`voteTicks`, per-episode config, wall-clock paced like `lobbyChatTicks`; 0 disables the phase, the byte-identical gate-off shape; default shorter than chat's 30 s because a ballot is a single decision, not open negotiation) | default 240 (10 s), range [0, 2400] |
| `castId` (ballot cast identity) | uint64, monotonic per seat, no wrap within an episode — same discipline as `uploadId`/`proposalId` |
| `category`, `finalOption` (tally outcome fields) | `u8`, range [0, 3] and [0, 2] respectively |

No new per-socket transport, outbound-queue, or classification constants
are introduced: ballot casts are covered by the existing per-seat-per-tick
socket budgets (Shell:781-782), and `0xB3`'s delivery reuses the existing
outbound queue and replay-on-bind cursor unchanged (section 3).

---

## Appendix A: proposed constant block, for the reservation commit

In the exact style of `src/shell/types.nim`'s existing opcode and record
blocks (lines 226-278), for James to drop in with the reservation:

```nim
  OpBallotCast* = 0xA4'u8
    ## client→server: u8 op, u8 ver, u64 castId, u8 option, u8[5] reserved
    ## (zero). Total = 16, fixed. option in [0,3] (A/B/C/D). Accepted only
    ## during the voting substate (§9.2 extension).
  OpVoteState* = 0xB3'u8
    ## server→client: u8 op, u8 ver, u8 kind, u64 ordinal, u32 tick, then
    ## kind 0 (cast): u8 seat, u8 team, u8 option; kind 1 (resolved):
    ## u8 category, u8 tieBreakDrawn, u8 finalOption. Total = 18, fixed,
    ## both kinds. One message per packet, broadcast to every play seat,
    ## never coalesced.

  RecBallot* = 0x17'u8
    ## u8 type, u32 replayTimeMs, u8 kind, u64 ordinal, then kind 0:
    ## u8 seat, u8 team, u8 option; kind 1: u8 category, u8 tieBreakDrawn,
    ## u8 finalOption. Total = 17, fixed, both kinds. Global transcript
    ## array, ordinal order, hash-coupled (proposed — §6 open item 2).

  BallotCastPacketBytes* = 16
  VoteStatePacketBytes* = 18
  RecBallotBytes* = 17
  BallotCastMaxPerSeatPerPhase* = 8
  BallotCastMinSpacingTicks* = 4
```

---

🤖 Drafted for review; nothing here ships without James's ruling on
section 6's three open items, and without Maxwell's go per the standing
see-and-test rule.
