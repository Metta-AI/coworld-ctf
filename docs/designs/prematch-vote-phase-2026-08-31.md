# A Pre-Match Vote Phase: One Vote Among Four Options

**Status:** DESIGN, for discussion · **Date:** 2026-08-31 · **Author:**
Maxwell's coding agent, direction from Maxwell's spec (verbatim below) ·
**Reviewers:** James (owns every surface this design extends — the
play-calling shell, the lobby phase, the wire), Maxwell (ballot content,
scheduling) · **Canonical home:** this file, in `coworld-ctf`.

Nothing here ships without James's ruling on section 4 and the open
questions of section 9. Every place this document touches his machinery
is phrased as a question, not a decision. **Shell:** below cites
`docs/designs/strategy-play-calling-shell-2026-08-29.md`, the surface
being extended.

---

## 1. Requirement

Maxwell, verbatim (2026-08-30): "we are implementing a vote phase before
the match where the LLM policies can vote between 3 generated maps or
'random' as an option. maps and game modes like BR vs CTF and how many
teams, how many ppl per team, whatever."

Restated, as the canonical ballot: before an episode's players start
playing, every play-seat policy is shown exactly **four options, A
through D, and picks one.**

- **A, B, C** are the 3 pre-generated candidates. Each is a **complete,
  already-certified episode config** — a finished map whose mode (Battle
  Royale, CTF, ...), team count, and seats per team are baked into it,
  whatever generator produced it (section 3). There is no separate axis
  for mode or roster; voting for a candidate votes for its whole bundle,
  full stop.
- **D is "random."** It never produces a config outside A/B/C — it
  delegates the seat's pick to a uniform random draw over the same three
  (section 5). The vote's entire outcome space is therefore {A, B, C}.

That's the whole interface. Nothing else is voted on.

## 2. Phase placement — and the tension it exposes

The obvious placement is inside the Shell's lobby phase (**Shell §9**): a
`voting` step beside or before `chatting`, recorded in-replay the same
way, so playback shows the ballot, the votes, and the result — consistent
with Maxwell's ruling that pre-match negotiation is viewer-visible, not a
black box (Shell §9.1, §9.3).

That placement collides with two things the Shell already fixes earlier
than a lobby-phase vote could reach:

- **`PlayContext` carries mode and map once, at registration**, before
  `joining`, before `chatting`: "At registration the server ... sends the
  `PlayContext`" (Shell:519), whose payload is "the game mode ..., the map
  identity and dimensions, the roster" (Shell:1174). A seat learns its map
  and mode the instant it connects — the same instant it becomes a ballot
  participant.
- **The map's shared episode layer builds once, before the section-10
  barrier**, normally finishing *during* `chatting`: "the map build starts
  when `joining` begins, so it normally finishes during chat"
  (Shell:2455). The engine is already building the one true map while the
  lobby it would vote in is still running.

One fact de-risks this considerably. The entrant policies loaded into an
episode are the **same fixed, already-uploaded set regardless of which of
A/B/C wins.** The vote changes only runtime parameters — how many
instances of each policy to instantiate (the seat count the winning
config needs), which map they run on, how long the episode runs — never
which policy artifacts get fetched. So there is no ordering deadlock on
the provisioning side: the policy set is known before the vote runs, and
the sequence is simply load the known policies, run the vote, instantiate
the right number of them on the winning map. From the platform side,
waiting on the vote is waiting on a count and a map choice for artifacts
already in hand, not a re-provisioning problem. Whether that lands as
cleanly inside James's own handshake — specifically, whether `PlayContext`
can carry a placeholder until the tally and only then fill in mode, map,
and roster — is the mechanical question §9's Q2 asks him, not an
architectural one.

So the vote is meant to decide the **whole bundle** — mode, map, and
roster together, since A/B/C can each be a different mode with a
different roster shape — that `PlayContext` and the episode-layer build
already assume is fixed before a lobby starts. Three shapes, none ruled
here:

1. **Pre-registration ballot** — a new phase ahead of today's lobby, so
   `PlayContext`'s mode+map+roster stays honest the moment it's sent.
   Cheapest on the wire; most disruptive to the container-start order
   Shell §9.1 fixed (game up, health check, then players) precisely to
   avoid new choreography.
2. **Defer `PlayContext`'s full gameplay payload until the vote closes**
   — seats register and chat immediately, but mode, map, *and* roster
   (and the section-10 build) all wait for the tally together, as one
   unit, not map alone. Keeps container order untouched; breaks the
   "once per episode, at registration" framing both currently have.
   (Instance count also waits on the tally, but per the fact above,
   that's a wait on a number against known artifacts, not a
   re-provisioning problem — a footnote, not a risk.)
3. **Speculative build** — the engine builds all 3 candidates' episode
   layers in parallel and commits to the winner's, discarding the rest.
   Harder than it sounds when A/B/C are heterogeneous (a BR candidate and
   a CTF candidate are different engine subsystems, section 3): no
   `PlayContext` timing change, but real throwaway compute across
   possibly-different pipelines (Shell §3.1's per-episode build, up to
   3x).

## 3. Ballot composition (our lane)

A, B, C: three generated candidates, each a finished, complete episode
config. D: "random." Per Maxwell's spec, and per his later correction,
the 3 are **heterogeneous by construction**: each comes from whatever
generator and mode fit it, not one generator run three times over
variant parameters. A candidate might be a BR map out of the BR kit
(`tools/brmapkit.nim`) or a CTF map out of the CTF generator
(`tools/mapkit.nim`) — two different tools producing two different
shapes of thing — and which of A/B/C lands as which mode is effectively
a coin flip, decided by whatever mix the scheduler asks for that round.
The ballot simply offers 3 finished, independently valid results side by
side; there is no shared parametric family they're all drawn from in
common.

**"Generated" is not "generated live."** Map fairness certification is
expensive — ">=5 wins per spawn to certify," "16 spawns costs ~8x the
episodes of 2 homes" (`origin/maxwell/ladder-scout-tooling:docs/designs/
BR_MAPGEN.md` §3.5) — and cannot be paid inside a thirty-second lobby.
Each candidate must be a **fresh instance of its own already
fairness-certified map family**, in its own mode's pipeline (a new
`genSeed` within a certified BR family for one slot, a certified CTF
instance for another), re-run only through the cheap static checks at
instantiation — weld test, thumbnail test, anti-confetti,
density-uniformity (`BR_MAPGEN.md` §5.3, §4.7) — never the statistical
certification itself. This is the "guarantee, not filter" house rule:
those static checks are hard guarantees, so each candidate is
unconditionally valid alone, drawn independently of the other two; there
is no best-of-3-for-quality step across them, because best-of-K only
moves a distribution's tail, never its support (`memory:
ctf-mapgen-guarantee-not-filter`). Nothing bends one mode's map to match
another's silhouette — a CTF candidate is exactly what CTF's own
pipeline certifies.

**Timing: ready before the game container reports healthy.** The runner
already orders "start the game container, wait for its health endpoint,
then launch the player containers" (Shell:2420-2424) so a lobby beginning
is a lobby a policy can attend. A, B, and C — whichever generators
produced them — must each exist, be validated, and be in the episode's
launch configuration before that health check passes, regardless of
which of section 2's three shapes James picks.

Each candidate must clear the same gate its own scheduled variant would:
nothing reaches the ballot that would fail the checks gating today's
declared variants (e.g. BR's baked `genSeed: 1339` instance in
`coworld_manifest_br.json`), whichever generator and mode it came from.

## 4. Voting interface (James's) — three sketches, no ruling

**(a) Ride `LobbyChat` as a convention.** The ballot is prose; a vote is
a `LobbyChat` (`0xA3`) message whose text is an agreed small JSON blob.
Zero new opcodes — the existing `0x13` record and transcript panel carry
it verbatim (Shell §9.3). Cost: unvalidated, unacknowledged — no
`voteAccepted`/`voteRejected` the way a call gets one (Shell §4.3), so a
malformed vote fails silently, exactly what the durable status list
exists elsewhere to prevent.

**(b) A dedicated packet pair.** `BallotOffer` (server to client, once)
and `Vote` (client to server, fixed small packet), modeled on the
`PlayCall` transaction: admitted at the tick boundary, validated, minted
as a durable status, replay-recorded as its own record type. Matches the
rigor the rest of the seat protocol has; costs new opcode space, a new
limits-table row, new goldens.

**(c) Overload `PlayCall`.** A vote is a call to a reserved play name
(`"vote_b"` for choice B), reusing `proposalId`/epoch/`callAccepted`
verbatim.
Cheapest from the authoring-loop side (`tools/flash`'s LLM already emits
ladder JSON), but a vote is not a play — it has no class, doesn't activate
under guards, and "drops the outgoing ladder's instances" (Shell §4.3)
means nothing for a one-shot choice. Named so it's rejected on purpose,
not silently assumed.

## 5. Tally and tie rules (proposed, simple)

- **Plurality wins** among A, B, C, D.
- **Ties break uniformly at random** from the episode's own deterministic
  seed (manifests already thread one, e.g. `"seed": 679961` in
  `coworld_manifest_paintbot.json`; BR's `mapSpec.genSeed`). No new
  entropy source — replay reproduces the same draw because it reproduces
  the same seed.
- **D ("random") is settled: it resolves to a uniform random draw over A,
  B, C — never a fourth, uncertified config.** The vote's full outcome
  space is exactly {A, B, C}; a policy voting D is delegating its pick to
  that draw, not asking for something off-ballot. This follows section
  7's constraint that the vote never selects outside what the certifier
  already blessed, and is Maxwell's call, decided.
- **Abstention folds into the tally as an implicit D vote**
  (section 8), so silence has a defined, symmetric effect rather than an
  unspecified one.
- **Deterministic given the recorded votes**: every accepted vote is an
  ordinal-stamped, replay-recorded input (paralleling `LobbyChat`'s
  ordinal/tick/seat/team discipline); replay reproduces the same tally and
  tie-break bit-for-bit.

## 6. Determinism and replay

Votes and the resulting selection must be replay-recorded inputs, or
re-simulation cannot reproduce the episode it claims to record. Two
existing precedents disagree on where this lands, and which one governs
is a real open question:

- **Lobby chat text is excluded from the game hash**: "it drives no
  gameplay, so it is not mixed into the game hash" (Shell:2579).
- **The lifecycle records (`0x14`-`0x16`) are the opposite**: "covered by
  the gameplay hash chain like them [joins and leaves], not by a manifest
  arm" (Shell:876-878).

A vote's tally is not prose — it determines which whole bundle (map,
mode, and roster together) the rest of the episode simulates under,
which argues for the second precedent. That puts it with any other sim-config-determining change:
wave 2 of the landing plan claims a new GameVersion for exactly this
class — glory-ledger-into-hash claims GV48, call-hash-and-epoch mixing
claims GV49, each "ONLY if [it] changes gate-off behavior; otherwise no
bump" (`docs/designs/BR_SEASON2_LANDING_PLAN.md:68-77`). A live vote
plainly changes gate-off behavior, so wiring it for real is very likely
its own GV claim and, per that plan's caution, its own re-record —
flagged, not decided.

One more novelty: mode/map/roster arrive today as launch configuration
(`game_config`, `mapSpec`), never as an in-episode record. "B won" is a
new *kind* of record — an in-episode input determining what was
previously only supplied out-of-band at launch. Same fact as section 2's
tension, from the replay side.

## 7. Scheduler and certifier interplay

**Today** the league scheduler fixes one variant per round from a fully
specified, fixed set declared in a coworld manifest: paintbot's declares
`2v2`, `4ffa`, `4ffa8`, `default`, `1v1`, `ctf-default`, `ctf-1v1`,
`paintball` (`coworld_manifest_paintbot.json`); BR's declares one,
`default`, with a baked `mapSpec` (`genSeed: 1339`, `teams: 16`,
`num_agents: 32`, `coworld_manifest_br.json`). A vote cannot conjure a
configuration that isn't already declared and certified somewhere — every
option the scheduler puts on a ballot has to already be one of these.
This is the load-bearing constraint: **certification, not the vote,
defines what counts as a valid episode config; the vote only chooses
among configs that already cleared it.**

**With a vote**, the scheduler's job changes from fixing one variant per
round to producing A, B, and C for the ballot — each independently
certified as a complete episode config, each possibly a different
manifest, mode, and generator (section 3). There is no shared "variant
space" the three are drawn from in common, and no separate axis the vote
resolves apart from picking one of them: the only thing A, B, and C share
is that each, on its own, is already a certified, playable episode config
offered on the same ballot.

**Certifier scope is narrower today than this needs.** The manifest's
`certification` block is one cheap smoke fixture per manifest —
paintbot's is `lives: 1, hitPoints: 1, gameOverTicks: 1, maxTicks: 300`
(`coworld_manifest_paintbot.json:1925`), nothing like any scheduled
variant's real shape — proving only that a submitted container speaks
its manifest's protocol, not that it survives whichever of three
possibly-different-mode candidates the vote lands it in. Proposal, not a
ruling: a policy needs a certification pass for every mode any of A, B,
or C could put it in, not one fixture per manifest.

**The soft landing already exists.** A play module's own manifest
self-declares "its supported modes" (Shell §6.2). A policy that lands, by
vote, in a mode none of its plays support should fall back to the
engine's default play — the existing behavior for a policy that "never
sends anything, or ... dies at startup" (Shell:535-536) — not fault the
episode.

## 8. Fairness and the strategy note

The vote is a new strategic surface, and that's a feature: a
close-quarters policy votes for the tight map, a patient `wide-intel`-
style policy votes for the open one — and because A/B/C can each be a
different mode, a policy whose playbook only declares support for one
mode (Shell §6.2) has an obvious, legitimate reason to vote against
candidates in the other. This is meta-strategy one level above the play
ladder — `docs/designs/BR_PLAYS.md` already frames "plays are the
strategy layer"; voting for the arena is the same idea applied to setup
instead of execution, and could become its own play later (a `vote` play
with a `prefer` param over A/B/C) — named as a future direction, not
proposed for v1.

The fallback matters because the surface is strategic: a policy that
never votes must not be quietly disenfranchised, and must not default
toward whichever seat is lowest-indexed — the same class of unnoticed
asymmetry 2-team formulas kept producing when applied past 2 teams.
Section 5's abstention-as-"random" is symmetric by construction.

Worth flagging so it isn't conflated in review: `BR_MAPGEN.md` §5.5
already has "a human vote" — Maxwell and reviewers grading a candidate
"good / not it / rework," offline, as part of *certifying a map family
for the corpus*, before any episode exists. That's upstream of this
vote: it decides what's allowed to become a certified candidate at all;
this design's vote picks among candidates that gate already passed.

## 9. Open questions for James

After the ballot-model correction, everything that assumed a separate
"variant space" the vote resolves apart from picking A/B/C/D falls away.
What's left, genuinely his to rule on:

1. **Vote wire and record shape (§4, §6).** Which of the three sketches
   — LobbyChat convention, dedicated opcode pair, or reused `PlayCall` —
   and does the resulting selection record sit inside the gameplay hash
   chain (lifecycle-record precedent) or excluded like chat text
   (lobby-chat precedent)? The answer decides whether wiring this live
   claims a new GameVersion, the way glory-inc3 (GV48) and play-calling
   P2 (GV49) did, with its own fixture re-record.
2. **Where the bundle lands in the handshake (§2), not whether it can.**
   The policy set loaded into an episode is invariant across A/B/C — the
   vote only decides a map, a mode, and an instance count for artifacts
   already in hand — so from the platform/provisioning side, deferring
   that decision past registration is low-risk: waiting on a count and a
   map choice, not a re-provisioning problem. The ask for James is
   mechanical: does `PlayContext`'s mode+map+roster payload (and the
   section-10 build) defer cleanly to the vote's close inside his own
   handshake (§2 option 2), or does he prefer the ballot precede
   registration entirely (§2 option 1) or a speculative build (§2 option
   3)? Confirming it lands cleanly on his side is the open item, not the
   architecture.

---

🤖 Drafted for review; nothing here ships without James ruling on section
4 and the questions above, and without Maxwell's go per the standing
see-and-test rule.
