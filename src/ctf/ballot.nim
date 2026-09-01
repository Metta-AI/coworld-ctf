## Pre-match vote ballot candidate generation (docs/designs/
## prematch-vote-phase-2026-08-31.md §3, prematch-vote-wire-2026-08-31.md).
## v1 scope only.
##
## The design's ballot is 3 heterogeneous candidates (A/B/C, each a
## complete, already-certified map+mode+roster bundle) plus D ("random",
## which delegates to a draw over A/B/C — resolution lives in sim.nim, not
## here). §3's full picture is a SCHEDULER producing fresh, freshly-seeded
## instances within already fairness-certified map families each round;
## that negotiation is explicitly out of v1's scope (task instructions:
## "Do NOT build the scheduler-side ballot-space negotiation"). v1 instead
## draws 3 DISTINCT candidates, deterministically from the episode seed,
## out of a small pool standing in for the league's already-declared,
## already-certified variants — paintbot's `2v2`/`4ffa`/`4ffa8`/`default`/
## `1v1`/`ctf-default`/`ctf-1v1`/`paintball` (coworld_manifest_paintbot.json)
## and BR's `default`, with its baked `mapSpec.genSeed: 1339`
## (coworld_manifest_br.json, post-#331). Each pool entry is, by
## construction, an already-declared, already-certified variant — never a
## synthesized one — so §3's "each candidate must clear the same gates
## their scheduled variant would" holds trivially for v1: selecting among
## already-cleared configs cannot fail a gate a config already passed.
##
## The generator sits behind `BallotCandidateSource`, a plain proc type, so
## a later scheduler-side negotiation lane (out of v1's scope) can swap the
## SOURCE a caller uses without touching sim.nim's voting substate, tally,
## or resolution code at all.

import std/random

type
  BallotCandidate* = object
    mode*: string         ## the declared variant's own name/mode, e.g.
                           ## "battle-royale", "4ffa", "ctf-default" —
                           ## exactly the manifest's variant name.
    manifestRef*: string  ## which manifest declares it (a citation; v1
                           ## does not parse the JSON file at runtime).
    genSeed*: int          ## the certified instance's own seed (BR's baked
                           ## 1339 for its one declared variant; 0 = the
                           ## variant has no fixed instance seed of its own
                           ## in v1's pool).

  BallotCandidateSource* = proc(episodeSeed: int): array[3, BallotCandidate]
    {.noSideEffect.}
    ## The swap point: anything matching this signature can stand in for
    ## `defaultBallotCandidates` below without sim.nim's voting substate
    ## changing at all.

const
  DeclaredVariantPool = [
    BallotCandidate(mode: "battle-royale",
      manifestRef: "coworld_manifest_br.json", genSeed: 1339),
    BallotCandidate(mode: "4ffa",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "4ffa8",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "ctf-default",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "ctf-1v1",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "2v2",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "1v1",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "default",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
    BallotCandidate(mode: "paintball",
      manifestRef: "coworld_manifest_paintbot.json", genSeed: 0),
  ]
  BallotGenerationTag = 0xBA110701'u32
    ## Domain-separates candidate generation's draw stream from sim.nim's
    ## vote RESOLUTION draws (the tie-break and D-delegation draws, tags 1
    ## and 2 there) — a different lobby moment, no reason to correlate;
    ## kept visibly distinct so neither module's tag space can collide by
    ## accident if either grows more draws later.

proc defaultBallotCandidates*(episodeSeed: int): array[3, BallotCandidate] =
  ## Deterministically samples 3 DISTINCT entries from the declared-variant
  ## pool, keyed only by `episodeSeed`: same seed, same 3 candidates, every
  ## time (tests/test_vote_phase.nim proves this). A fresh, tag-separated
  ## PRNG stream, NOT `sim.rng` — this must be recomputable from the seed
  ## alone by anything that knows the episode's launch config, independent
  ## of how much unrelated gameplay randomness ran first (same reasoning as
  ## sim.nim's own `voteDraw`).
  var mixed = 14695981039346656037'u64
  mixed = mixed xor cast[uint64](int64(episodeSeed))
  mixed *= 1099511628211'u64
  mixed = mixed xor uint64(BallotGenerationTag)
  mixed *= 1099511628211'u64
  var rng = initRand(cast[int64](mixed))
  var pool: seq[BallotCandidate] = @DeclaredVariantPool
  for slot in 0 ..< 3:
    let pick = slot + rng.rand(pool.len - 1 - slot)
    swap(pool[slot], pool[pick])
    result[slot] = pool[slot]
