# The Play-Calling Shell: Compiled Plays Above the Intent Contract

> **Provenance:** this is a synced copy published for Maxwell and his coding
> agents. The canonical home is James's paintbot lab
> (`paintbot_lab/docs/designs/strategy-play-calling-shell-2026-08-29.md`);
> `LAB:` citations below refer to that lab's `paintbot/stencil_nim/` tree,
> which is not in this repository. If the copies ever disagree, the lab copy
> wins.

**Status:** DESIGN (rev 10 — prose rewritten for clarity on James's direction;
no technical content changed since rev 9, which converged after nine rounds of
adversarial cross-review by Codex, ending in VERDICT: SATISFIED) ·
**Date:** 2026-08-29 · **Author:** James's coding agent, working from James's
direction · **Reviewers:** Codex (cross-agent, round-gated) and Maxwell
(notified of the two deliberate departures from his design, described in §3.3)

Two companion documents provide the background this design assumes:

- `coworld-ctf:docs/reports/maxwell-s2-paradigms-2026-08-29.md` — a research
  report on Maxwell's Season 2 architecture: what the game engine, the
  match-orchestration app, and the prototype bot currently do, and where the
  boundaries between them sit.
- `coworld-ctf:docs/recon/paintbot-s2-policy-shell-2026-08-29.md` — an
  inventory of the relevant repositories and branches, including what is and
  is not merged.

A third document is cited heavily:
`origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md` (in coworld-ctf) is
Maxwell's analysis of how the stencil bot would need to change to play Battle
Royale. Its section 2 lists which of stencil's current behaviors are
meaningless in that mode, section 6 analyzes how behaviors could be authored
externally, and section 7 lists the things that block stencil from playing
Battle Royale at all today.

How to read the file citations in this document: a bare path such as
`src/ctf/sim.nim` refers to the `coworld-ctf` repository. A path prefixed
`PBP:` refers to the `coworld-paintbot-player` repository. A path prefixed
`LAB:` refers to this lab — specifically `paintbot/stencil_nim/` unless some
other lab path is written out. A path prefixed `origin/<branch>:` refers to a
file that exists only on that unmerged git branch.

---

## 1. The problem this design solves

Season 2 of Paintbot pits language-model "policies" against each other in a
Battle Royale game mode. Each policy is an LLM. It chats with the other
policies in a pre-game lobby, and then it directs a robot (a "cog") during the
match itself.

Maxwell has already built a substrate for this. His branch
`origin/maxwell/br-season2-complete`, cut on 2026-08-29, combines the Battle
Royale engine work, the mid-match "reflash" channel (explained in §5), a
starter set of strategy documents, and an episode recorder. In his version of
the system, the LLM's influence on the match takes the form of *page scoring*:
the LLM writes a JSON sheet of numeric weights over a fixed menu of twelve
possible intentions, and a bot re-scores that menu every game tick and acts on
whichever intention scores highest
(`origin/maxwell/br-reflash-integration:players/onepage/onepage.nim`).

James has ruled that we should replace everything above the `Intent` level of
our own bot with a different model. In his words:

> The plays are codelets/mini-programs which produce a typed `Intent` with
> parameters at each tick. The `Intent`→action logic remains the same, using
> stencil as the base. Those codelet plays are written by the player during the
> optimization loop — bringing in logs from previous games and forum posts — and
> evolve over time. The policy LLM starts with a playbook of these codelets,
> chats with other policies in the lobby, and selects a play to give the cog,
> along with any parameter values the play requires. The cog then executes that
> play until it's given a new play.

The idea, unpacked: the sophistication of a strategy should live in real,
tested code that we (the player, meaning James plus his coding agents) write
offline, between matches, drawing on game logs and forum discussion. That code
takes the form of a library of **plays**. At runtime, the LLM does not write
any code at all. It reads its playbook, talks to the other policies in the
lobby, and then *calls a play* — it names one play from the playbook and fills
in that play's parameters. The cog runs that play until someone hands it a new
one.

This arrangement buys three things at once. Complex strategies can grow over
time through the offline loop, because they are ordinary code. The policies
can still adapt on the fly — in the lobby and mid-match — because switching
strategies is just calling a different play. And the player controls how many
knobs the runtime LLM has to handle, because each play's author decides how
many parameters that play exposes.

## 2. Goals and non-goals

This design commits to six goals.

1. Define the Play abstraction precisely, including its contract with the
   parts of stencil that do not change.
2. Reuse Maxwell's existing machinery — the reflash channel and the pre-round
   chat phase — unchanged wherever it genuinely does not care what bytes it is
   carrying, and spell out the exact places where it does need to change.
3. Preserve the lab's validation tooling. Our acceptance instrument is exact
   replay comparison (`compare_stencil.py` together with `replay.nim`), and it
   must keep working, extended to account for play calls.
4. Specify the two fixed pieces of decision logic that sit outside any play:
   the emergency behaviors the shell owns (§4.4) and the finishing step that
   runs after every decision (§4.3).
5. Name the first version of the play library for Battle Royale, with complete
   parameter definitions, so that James's motivating example — an "avoid
   conflict" play that takes a list of allied teams — is specified end to end.
   Making that example real requires one addition to the `Intent` type, which
   §4.2 describes.
6. Order the work into phases, keeping the phases that must not change
   behavior strictly separate from the phases that exist to change behavior.

Four things are explicitly *not* goals of this design.

- **The mid-match delivery channel.** Nothing currently exists that can tell a
  running bot "a new play call is ready for you." Both ends of that channel
  are deliberate stubs today: on the bot side, a placeholder that watches a
  file (`onepage.nim:1341-1352`), and on the app side, a bookkeeping function
  that nothing calls yet
  (`PBP:origin/maxwell/lobby-chat:server/preround.mjs:460-466`). This design
  defines the hook the future channel will call and stops there.
- **The offline authoring tools.** The pipeline that turns game logs and forum
  posts into new plays is sketched in §10 and will be designed separately.
- **Any interpreted language for plays.** Plays are compiled Nim. §3.2 records
  why, and what it would take to revisit that.
- **Changes to how actions are resolved.** The order of operations inside
  `resolveAction`, the path planner, the movement follower, and the
  micro-movement machinery all stay as they are. One new field does get added
  to the `Intent` type and threaded through the combat code (§4.2), in the
  same way an earlier version of stencil threaded idle-aim through — that is
  an extension of the existing contract, not a redesign of the body.

## 3. The shape of the system

### 3.1 Four layers

Maxwell's design constitution
(`origin/maxwell/br-onepage-vm:tools/flash/SCHEMA.md:15-48`) describes three
layers: STRATEGY (a scoring sheet the LLM writes), INTENT (a fixed menu the
sheet scores), and ACTION (the engine turning the winning intention into
button presses). This design re-cuts the stack into four layers.

| Layer | What the artifact is | Who authors it | How often it changes |
|---|---|---|---|
| **CALL** | a play call: `{play, params}` — one play's name plus its argument values | the policy LLM, at runtime | at bot startup, and at each mid-match reflash |
| **PLAY** | a compiled Nim mini-program that reads the world and produces one `Intent` per tick | the player, offline | with each new version of the policy binary |
| **INTENT** | stencil's existing typed `Intent` struct (`LAB:types.nim:189-219`), extended as described in §4.2 | produced by the play, finished by the shell | every tick |
| **ACTION** | `resolveAction` turning the `Intent` into the 8-bit input mask the game accepts (`LAB:action.nim:402-551`) | stencil's body, unchanged | every tick |

The important shift is in the top layer. In Maxwell's version, the artifact
the LLM produces is shaped like a program: a sheet of weights that gets
evaluated continuously. In this version, the LLM's runtime artifact shrinks to
a *function call*: the name of a play plus typed arguments. All authoring
moves offline. This preserves the property Maxwell's design was protecting —
his page language rejects `"if"` outright, precisely so that no LLM-written
control flow can reach a live match — while removing the ceiling on how
sophisticated a strategy can be. A play can be anything the player can write,
test, and ship in Nim.

A note on naming. James has ruled that the product-level word for this
artifact is **play**, not "page." However, the wire-level and engine-level
names — `PolicyPageMagic`, the `COWORLD_POLICY_PAGE` environment variable,
the `applyPolicyPage` procedure, and the replay record format — all belong to
Maxwell's code and keep their current names unless he renames them. When this
document says "play call," it means the payload those mechanisms carry.

### 3.2 Why plays are compiled Nim (a decision record)

James ratified this choice directly. The reasoning is recorded here for
future readers, because it is the decision from which most of the design's
simplicity flows.

First, determinism comes for free. A play is shell code, and the shell is
already deterministic: given the same stream of game frames, the same
configuration, and the same stream of play calls, it produces the same
decisions. The lab's whole validation approach depends on that property —
version 69 of stencil shipped on the strength of 278,016 out of 278,016
decisions reproduced exactly from recorded game traffic
(`LAB:tools/compare_stencil.py`) — and compiled plays keep it intact, with
the extensions described in §8.

Second, the deployment pipeline already exists. Coworld policies ship as
container images, and "edit the Nim, build the image, upload it" is already
the lab's routine loop (`LAB:tools/build_player.sh`). Evolving the playbook
requires no new infrastructure; a new playbook is just a new policy version.

Third, the payload that has to cross the network becomes tiny. A play call is
well under a kilobyte, against a hard limit of 60,000 bytes imposed by the
replay record format
(`origin/maxwell/br-reflash-integration:src/ctf/sim_types.nim:823-831`).

Two alternatives were considered and rejected. Maxwell's two page languages —
the expression-based virtual machine in
`origin/maxwell/br-onepage-vm:src/ctf/policy_page.nim` and the simpler
row-of-weights placeholder that currently runs on the wire — both exist to
make *LLM-authored* artifacts safe to execute. Once authoring moves offline
into ordinary code review, they solve a problem we no longer have. An
embedded interpreter (Lua, WebAssembly, or similar) was also rejected for
now: it would buy the ability to update plays without rebuilding the binary,
at the cost of designing and validating a whole interpreter's determinism
story. If updating plays without a rebuild ever becomes a demonstrated need,
that decision should be revisited — starting with a survey of existing
options, not a hand-rolled interpreter.

The accepted trade-off is that the LLM cannot invoke a play the binary does
not contain. That is not a limitation we are tolerating; it is the design
intent. James's words: the policies select from complex strategies "without
needing to write new ones." Section 7.2 describes how the lobby learns
exactly which plays a given bot supports, so this constraint is visible to
the LLM rather than a source of silent failures.

### 3.3 Two deliberate departures from Maxwell's design constitution

Both of these were ratified by James, and Maxwell was notified of both by
direct message on 2026-08-29. A second message with this document followed.

The first departure concerns naming other entities in the game. Maxwell's
constitution states that a strategy "cannot name a specific enemy or a
specific pickup — there is no path for it, so it cannot be expressed." Play
*parameters* relax that rule: a play's author may declare parameters that
refer to entities, such as a list of team colors. The reason is practical.
The pre-round chat phase's own system prompt tells the policies that open
collusion is rational (`PBP:origin/maxwell/lobby-chat:server/preround.mjs:216-228`)
— and an alliance negotiated in the lobby is worthless unless the cog can be
told "do not shoot these teams." The safety rationale behind Maxwell's rule
does not disappear; it moves. Instead of being *inexpressible*, entity
references become typed, scoped to one play's declared parameters, and
validated against that play's schema.

The second departure is that per-tick scoring goes away. In Maxwell's model,
the strategy sheet is re-scored every tick and the best-scoring intention
wins. In this model there is no scoring step in the shell at all: the
selected play simply *is* the strategy, and it runs until replaced. (Nothing
stops an individual play from doing its own internal scoring over sub-goals —
that just becomes one pattern a play author might use, rather than the
architecture of the system.)

## 4. The Play contract on the stencil side

### 4.1 Types, and the module layout that makes them compilable

Plays have different parameters and different internal state from one
another, but the registry that holds them needs one concrete type for "a
play." The standard Nim answer is a closed tagged union (an object variant):
one enum lists every play, and the parameter and state types are variant
objects over that enum. The compiler then enforces exhaustiveness the same
way it does for stencil's existing enums.

The module layout needs care, because a naive arrangement — one `plays.nim`
that owns both the shared types and the registry, with each play module
importing it — is an import cycle Nim will reject. (Codex caught this in
review round 3.) The complete dependency graph, in which each module imports
only modules listed above it:

```
types / belief_state / worldmap
  → play_queries.nim    (owns and exports the opaque PlayView, the GameMode
                         enum, and the audited read API; exports no raw
                         Belief; imports no play module)
  → play_contract.nim   (the shared types below, including every PlayState
                         arm; imports play_queries so it can name PlayView,
                         and nothing else play-related)
  → plays/<name>.nim    (one module per play; may import ONLY play_contract,
                         types, play_queries, plus an explicitly allowlisted
                         set of standard-library modules — math, options,
                         sets, tables, algorithm, heapqueue; every other
                         project module, and side-effecting standard modules
                         such as os, net, times, and osproc, are rejected
                         by a build-time import check)
  → play_registry.nim   (declares `let Playbook* = @[...]`; imports the play
                         modules)
  → plays.nim           (the shell machinery; imports the registry; no play
                         module imports it back)
```

The shared types, which live in `play_contract.nim`:

```nim
type
  PlayKind* = enum
    pkDefault, pkAvoidConflict, pkZoneRotate, pkThirdParty   # grows per play

  ParamKind* = enum vkNumber, vkBool, vkString, vkTeamList, vkPoint
  ParamValue* = object
    case kind*: ParamKind
    of vkNumber:   num*: float
    of vkBool:     flag*: bool
    of vkString:   str*: string        # constrained by allowedStrings
    of vkTeamList: teams*: set[Team]   # canonical JSON: ["red","navy",...]
    of vkPoint:    pt*: Point          # canonical JSON: [x, y]

  ParamSpec* = object
    name*: string
    kind*: ParamKind
    required*: bool
    default*: Option[ParamValue]       # required xor default: exactly one
    doc*: string                       # one line, surfaced in the catalog
    minVal*, maxVal*: float            # vkNumber only; checked on parse
    allowedStrings*: seq[string]       # vkString only; empty = free-form

  PlayParams* = Table[string, ParamValue]   # validated + defaulted at parse

  PlayState* = object                  # per-play state, one closed union
    case kind*: PlayKind
    of pkDefault:       ds*: DefaultState
    of pkAvoidConflict: acs*: AvoidConflictState
    of pkZoneRotate:    zrs*: ZoneRotateState
    of pkThirdParty:    tps*: ThirdPartyState

  PlayCall* = object                   # the parsed flash payload
    play*: PlayKind
    params*: PlayParams
    raw*: string                       # verbatim bytes, for logging/records

  Reflex* = enum rxClearGrenade, rxClearSpray, rxZoneEscape
    ## not_alive and no_worldmap are unconditional and not subscribable.

  Play* = object
    kind*: PlayKind
    name*: string                      # snake_case; the name used on the
                                       # wire, in the catalog, and in replays
    doc*: string
    schema*: seq[ParamSpec]
    reflexes*: set[Reflex]             # which shell reflexes this play
                                       # delegates (see §4.4)
    init*: proc(params: PlayParams, view: PlayView): PlayState {.nimcall.}
    step*: proc(state: var PlayState, params: PlayParams,
                view: PlayView): Intent {.nimcall.}
```

`init` receives the view because initialization needs to know the game mode
and the world (§6.1), and it therefore runs only once both are known — the
startup sequence in §4.6 spells out exactly when.

Phase 1 (§9) carries two proof obligations for this layout, both to be
satisfied before any behavior work begins. First, the whole graph must
compile with two plays of *different* parameter and state shapes registered
through `play_registry.nim` — that proves the type design actually works in
Nim, not just on paper. Second, a deliberately wrong play module that tries
to read or write a raw `Belief` field must *fail* the build, proving that no
such symbol can even reach a play.

The contract itself consists of four rules.

**Rule one: `step` is the mind.** The play's `step` function replaces the
decision-making part of today's `decideBaseObjective`
(`LAB:strategy.nim:329-500`). Everything it wants the cog to do is expressed
by returning one `Intent`. It must put every movement goal through the
existing goal-validation path (`reachableGoal`, which calls
`nearestReachable`; `LAB:strategy.nim:107-110`). A play whose goal cannot be
validated returns a stay-put `Intent` with a reason attached; it never emits
a raw "walk toward this pixel" instruction. That has been the law since
stencil v66 and it does not change here.

**Rule two: plays own their state, explicitly and mutably.** The
`state: var PlayState` argument is the one place a play is *supposed* to
write. `init` creates it when the play becomes active; it is thrown away when
the play is replaced or the episode ends. Today, several of stencil's
behaviors stash their working state — latches, counters, cool-downs — on the
shared `Belief` object, which the lab's own architecture review flagged as a
leak. As those behaviors are absorbed into plays, that state moves into
`PlayState`. (There is one temporary exception, described in §4.4 and §6.1.)

**Rule three: plays never see `Belief` at all.** `Belief` is a Nim `ref
object` whose fields are all exported and mutable
(`LAB:belief_state.nim:19-137`). If a play's `step` received it, nothing
could stop the play from modifying it — an import restriction is useless once
the type itself is in hand, and Codex demonstrated in review that every
polite-looking alternative (a grep for assignment syntax, an import
allowlist alone) has holes. So the contract is: `step` receives an opaque
`PlayView` instead. `PlayView` is defined in `play_queries.nim` with a
*private* field holding the underlying `Belief` reference — no copying — and
plays read the world only through that module's exported query functions:
fact getters, the goal-validation helpers, track and zone and item queries,
`makeIntent`, and the game-mode value from §6.1.

The queries must also not leak. `Belief` and `WorldMap` are full of
reference-backed containers (`LAB:belief_state.nim:19-58`,
`LAB:worldmap.nim:70-94`), and a query that returned one of those raw would
hand a play shared mutable state through the back door. So query functions
return plain values: scalars, value-type snapshots, or copied sequences of
value-only records. Operations that need the map — validating a goal,
looking up a firing position — run *inside* `play_queries` and return their
results as values. Three tests pin this down: the compile-failure fixture for
raw `Belief` access, a second compile-failure fixture for raw `WorldMap`
access, and a runtime test proving that mutating a collection a query
returned does not change `Belief`. Every future addition to `play_queries`
gets reviewed on two axes: does the function body mutate anything (the lab
has been burned before by a value that changed its own oscillator merely by
being read — `LAB:TENTATIVE_LESSONS.md:20-26`), and does the return value
alias anything. If the query surface ever proves too narrow for a play
someone wants to write, the fix is to widen `play_queries` — never to loosen
the boundary.

**Rule four: plays emit meaning through a type, and the reason string stays
what it always was — a label for humans.** Today, `makeIntent` takes a
reason *string* and uses it to decide behavior: the exact string selects the
cost profile, the micro-movement permissions, the arrival radius
(`LAB:strategy.nim:40-99`). That worked while every caller was in one file,
but it is a trap for play authors — a reason like
`"play:default:clear_spray"` would fall through the string match and
silently lose all of those settings. BR_LADDER's authoring analysis warns
about exactly this and recommends a separate semantic identifier
(`origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md:800-804`). The
ruling: `makeIntent` gains an explicit `shape` parameter — an `IntentShape`
enum whose members are today's reason vocabulary — and the flag table keys
off the enum. The string becomes pure telemetry, free to say whatever is
most useful in a trace, for example
`makeIntent(kind, point, shape = isClearSpray, reason =
"play:default:clear_spray")`. Migrating the existing call sites is
mechanical: each one's shape is the literal it passes today.

### 4.2 One addition to `Intent`: the combat policy

Codex's first review round proved that the contract as originally drafted
could not implement James's motivating play. The `Intent` type carries
movement, aim, and micro-movement permissions only
(`LAB:types.nim:189-219`), and the body chooses its own combat targets —
`selectTarget`, the spray-pursuit logic, and the grenade planner never
consult the mind (`LAB:action.nim:472-524`, `LAB:fight.nim:226-283`). A
"don't shoot these teams" instruction therefore had *no route from the play
to the trigger*. The fix is to widen the contract, exactly the way stencil
v69 widened it for idle-aim: the decision moves into the mind's output type,
and the body's machinery learns to honor it.

```nim
type
  CombatPolicy* = object
    noShootTeams*: set[Team]   # never targeted by gun, spray, or grenade
    protectTeams*: set[Team]   # up-weight proximity threats near these teams

  Intent* = object
    ...                        # all ten existing fields unchanged
    combat*: CombatPolicy      # default: both sets empty
```

"Never shoot" has to mean more than "never select as the aiming target." The
body's own safety code shows the three ways a bullet, a spray cone, or a
grenade blast can hit a cog nobody was aiming at, and the enforcement
principle follows from it: **members of `noShootTeams` join the protected
set that every existing friendly-fire check already consults.** They are
treated the way teammates are treated today, in each weapon path:

- **Every target-acquisition path is filtered, and there is a final veto at
  the trigger.** `selectTarget` is not the only way the body picks a target:
  outside an active firefight, the gun falls back to `belief.nearestEnemy`
  (`LAB:action.nim:472-476`, with the unfiltered scan at `:31-39`), and the
  spray-arc selector scans all enemies on its own (`LAB:fight.nim:26-44`).
  The filter therefore applies at all three acquisition sites. On top of
  that, as defense in depth against any future code path that forgets the
  early filter, a final check runs immediately before each weapon's fire
  decision and refuses a `noShootTeams` endpoint no matter how it was
  acquired. The corridor-safety helper cannot serve as this check, because
  it deliberately ignores the entity at the endpoint of the shot
  (`LAB:action.nim:94-105`). Tests cover the fallback paths specifically:
  cases with `Firefight` disabled and with `firefightActive` false, where
  the nearest cog is excluded but a farther legitimate target exists, plus
  an arc-selector case.
- **Gun:** the corridor check that already refuses a shot when a teammate
  stands along the bullet's path (`LAB:action.nim:94-118`) extends its
  blocker set to `noShootTeams`. A legitimate target standing behind a
  protected cog is not a legal shot.
- **Spray:** the cone checks (`LAB:action.nim:51-60,490-499`) refuse to
  activate when a protected cog is inside the cone, exactly as they do for
  teammates today.
- **Grenade:** the blast-radius prediction (`LAB:action.nim:273-278`) treats
  protected cogs as must-not-splash, and the cluster planner
  (`LAB:action.nim:285-335`) stops counting them as value in a target
  cluster. One subtlety needs its own rule: a grenade that is already
  charging when the combat policy changes still holds its old throw target,
  and the code will force-release an overdue charge
  (`LAB:action.nim:353-400`). So the charge is re-validated on the very tick
  the policy changes, and cancelled if the held throw would now violate it.
  A force-release never bypasses the veto.

The `protectTeams` half needs a careful definition, because stencil's
perception does not actually know who is attacking whom. An observation
carries a cog's position, facing, aim, team, and equipment — but no
attacker-victim relationship (`LAB:types.nim:38-69`), and a heard impact
carries no attacker identity. So "protecting" is defined through proximity,
generalizing a heuristic Maxwell's prototype bot already uses for its
partner. And the definition must be written in terms of *team colors*, not
stencil's track containers, because those containers are relative to the
observer: perception files every cog that is not the bot's own color under
"enemies" (`LAB:perception.nim:325-346`, `LAB:belief_update.nim:411-433`),
which means two cogs on the same allied team would otherwise register as
threats *to each other*.

The full relation: a *protected candidate* is any sufficiently fresh track —
from either the teammate or the enemy container — whose color is in
`protectTeams`. A *threat candidate* is any sufficiently fresh track whose
color differs from that protected cog's, and is in neither `noShootTeams`
nor `protectTeams` (teams on the list are never treated as threats to each
other; anything else would contradict the play's purpose). The policy's own
team is allowed in `protectTeams`; its cogs arrive through the teammate
container, and the implementation scans both containers by color.
"Sufficiently fresh" means both tracks are within `TrackTtlTicks` (120
ticks; `LAB:config.nim:144-149`). "Near" means strictly less than
`ProtectThreatRangePx` apart — default 200 pixels, matching the precedent in
Maxwell's bot (`onepage.nim:75-84,1110-1118`), exposed as a new `STENCIL_*`
tuning knob. The up-weighting itself is one new additive term in
`scoreTarget` with its own named weight knob (`ProtectThreatWeight`), which
is zero when `protectTeams` is empty — that zero is what makes the empty
policy behave identically to today. When the `avoid_conflict` play positions
the cog to cover a protected ally, ties break deterministically: eligibility
filter first, then the nearest protected cog under threat, then the lowest
cog index.

Deliberate attacker attribution — inferring "this enemy is shooting at that
ally" from aim cones or damage timing — is explicitly left as future work.

The protection relation carries its own test list: one unambiguous threat;
an ambiguous crossfire; stale tracks, with each side of the pair going stale
independently; no observable threat at all; two nearby cogs on a single
protected team (who must not read as threats to each other); two nearby
protected teams (likewise); a genuine threat from an unlisted third team;
and protection of the policy's own team, exercised through the teammate
track container.

Two bookkeeping rules complete the picture. The hand-built `Intent` that the
orchestrator constructs on ticks when the cog is dead (`LAB:policy.nim:103`)
stamps `combat = CombatPolicy()`, because the lab has already learned the
hard way that every new `Intent` field must be stamped there too
(`LAB:TENTATIVE_LESSONS.md:28-32`). And the parity requirement is absolute:
with both sets empty, behavior must be bit-for-bit identical to today's,
which the Phase 1 gate proves (§8).

The test list for the whole mechanism (landing with the first play that
exercises it, in Phase 4c, with the empty-policy control in Phase 1): an
excluded cog standing between the shooter and a legitimate gun target; an
excluded cog inside the spray cone next to a legitimate target; an excluded
cog inside the grenade radius of a legitimate blast center; and a combat
policy arriving while a grenade is already charging.

This is the one place where the design amends James's sentence "the
`Intent`→action logic remains the same." The logic's order and machinery are
unchanged; the contract gains one field that the machinery filters by. James
has ratified the play's semantics — "not shoot anyone on that squad mates
list … and also cover them" — and this is the minimal honest implementation
of those semantics.

### 4.3 What happens each tick: guards, then the play, then the finisher

Today, the orchestrator's decision station (`LAB:policy.nim:99-105`) calls
`decideObjective` when the cog is alive and hand-builds a stay-put intent
when it is dead. Under this design, the station becomes a fixed four-step
pipeline.

**Step one — unconditional guards.** Two conditions preempt everything,
exactly as they do today: the cog is dead (`not_alive`), or the world map
has not been built yet (`no_worldmap`). These are prerequisites of any
decision at all, and they are always the shell's job.

**Step two — the subscribed reflexes.** The shell checks the emergency
behaviors that the active play has *delegated* to it — §4.4 explains the
delegation model. These run in a fixed order. If one fires, its `Intent`
goes to the finisher and the play's `step` is not called this tick.

**Step three — the play.** Otherwise, the active play's `step` runs and
produces the tick's `Intent`.

**Step four — the finisher.** A fixed shell step completes the `Intent`
before it goes to the body. This step exists because two pieces of the
current ladder's tail must keep happening and should not be every play
author's responsibility — but it has to be *aware of where the intent came
from*, because applying it blindly would change behavior Codex caught in
review:

- For an intent from a live play or reflex: the finisher applies the
  spray-arc pursuit override exactly as today's post-ladder step does
  (`LAB:strategy.nim:504-514`). This is shell-owned combat opportunism, and
  a play opts out of it the same way today's behaviors do, by shaping its
  intent's micro-permission set. The finisher then stamps the idle-aim
  center (`LAB:strategy.nim:515`) — a field whose absence the body treats
  as a bug and dereferences unconditionally (`LAB:action.nim:525-533`), so
  the finisher owns it rather than trusting each play to remember.
- For the dead-cog guard's intent: the pursuit override is *skipped*.
  Today's dead branch never enters `decideObjective` at all
  (`LAB:policy.nim:99-105`), so pursuit cannot run on a dead tick — that
  exclusion is part of the current contract, not an accident, and the
  finisher preserves it. The dead-tick intent receives exactly the fields
  the current dead branch stamps, plus the new empty `CombatPolicy`. A test
  pins this with deliberately hostile belief values (`iHaveArc` true, a
  live spray target visible) to prove the exclusion is control flow, not
  luck.
- In both cases the finisher prefixes the telemetry reason with
  `play:<name>:`, `reflex:<name>`, or `guard:<name>` so traces show who
  actually decided.

### 4.4 The reflex layer: emergencies a play can delegate to the shell

A single play runs at a time, and a play might run for a long stretch
between calls. Something has to guarantee that a cog does not die of simple
negligence — standing in a grenade blast, ignoring a spray attack, getting
caught by the shrinking zone — without every play author re-implementing
survival. That something is the reflex layer: emergency behaviors
implemented once, in the shell.

The first design draft made reflexes universal — they always ran before the
play. Codex's review showed that this quietly changes today's behavior:
in the current ladder, carrying the flag home and intercepting a flag thief
*outrank* grenade and spray evasion (`LAB:strategy.nim:349-374`). A carrier
inside grenade range today keeps carrying; a universal reflex-first rule
would make it flee instead. That is a gameplay change wearing a refactor's
clothes.

So reflexes are *subscribed*, not imposed. Each play declares, in its
`reflexes` field, which emergencies it delegates to the shell. The three
subscribable reflexes:

- `rxClearGrenade` — escape radially from an incoming grenade warning
  (today's logic at `LAB:strategy.nim:359-370`).
- `rxClearSpray` — the scored sixteen-direction flee from spray attacks,
  with its existing trigger/release thresholds (`LAB:strategy.nim:221-309`).
- `rxZoneEscape` — Battle Royale only, and new. It triggers on *imminent
  damage*: the cog is outside the zone rectangle while the zone is dealing
  damage, or the shrink will put the cog outside within a short horizon of
  ticks. It deliberately does not trigger on mere closeness to the edge — a
  play whose whole strategy is hugging the zone rim must not fight its own
  reflex. When it fires, it routes the cog to the nearest validated point
  inside. Everything *predictive* about the zone — rotating early, guessing
  the final circle — is play territory, not reflex territory.

Reflexes that need memory keep it in an explicit `ReflexState` owned by the
shell — not on `Belief`, and not inside any play's state. Its lifecycle: it
resets at episode boundaries, and it **persists across play swaps,
re-sent calls, and subscription changes**. More than that, the reflex
*observers* — the code that watches for spray attacks and updates the
trigger/release latch — run every living tick regardless of what the active
play subscribed to. Subscription controls only whether a reflex may *seize
control*, never whether it *watches*. This is what makes the persistence
guarantee real: if the policy calls a new play in the middle of a spray
flee, the new play's first tick finds the shell latch already active,
because the shell never stopped watching. There is no state to hand over
from anywhere. The test for this: with the legacy behavior active, enter the
spray-flee condition, switch to a play that subscribes to `rxClearSpray`,
and confirm the flee continues without a gap.

One temporary exception exists for the sake of the compatibility proof. The
legacy CTF behavior (§6.1) is served by a special adapter rather than a
normal play, and that adapter's internal grenade/spray logic keeps using
today's `Belief` latch fields exactly as the current code does. This is safe
alongside the always-running shell observers because the observers write
only to `ReflexState`, never to `Belief`, and because the adapter runs with
an empty subscription set, so the observers never preempt it. The exception
ends when Phase 4's strategy work retires the adapter.

Everything else that is a behavior today — centering during a grenade
barrage, carrying the flag, fetching items, squad orders, defensive posts —
belongs to plays, not reflexes. The reflex enum is deliberately small.
Adding to it is a design decision, never a convenience. Every reflex
preemption is visible in telemetry with a `reflex:` prefix.

### 4.5 The playbook registry, validation, and the catalog

The playbook is one sequence, declared in one place:

```nim
let Playbook*: seq[Play] = @[defaultPlay, avoidConflictPlay, ...]
```

A play's `name` is its identity everywhere outside the binary — on the wire,
in the lobby's catalog, and in saved replays. Renaming a play breaks every
stored call that used the old name, so a rename is treated with the same
gravity as changing a configuration schema.

Validating an incoming call follows the lab's existing configuration
discipline (`LAB:config.nim:7-51` is the model): every problem fails
immediately with a specific error, and nothing is ever silently coerced. An
unknown play name, a missing required parameter, a wrongly typed value, a
number out of its declared range, a string outside its allowed set, a
malformed or duplicated team name, a non-finite number — any of these causes
the call to be **rejected before it is ever proposed on the wire**, mirroring
the validate-before-send behavior of Maxwell's bot (`onepage.nim:1445-1451`),
and the currently active play continues unaffected. At process startup the
rule is harsher: a startup call that is *present but invalid* kills the
process immediately (mirroring `onepage.nim:1533-1546`), because a bot that
silently ignored its instructions would be worse than one that visibly
failed. Parsing fills in the declared default for every omitted optional
parameter, so a parsed `PlayParams` always contains a value for every
parameter in the schema.

The lobby needs to know which plays a given bot binary actually supports,
and the answer must come from the binary itself — any second copy of that
information would eventually drift. So the stencil binary gains a
`--print-catalog` mode: run with that flag, it prints one JSON document,
`{"catalog": ..., "catalog_hash": ...}`, and exits. The catalog holds every
play's name, its full parameter schema (defaults, ranges, allowed values),
and its documentation lines. The hash exists so a JavaScript consumer and
the Nim producer can verify they are looking at the same catalog, and it
has a byte-exact contract: SHA-256, rendered as lowercase hex, over the
UTF-8 bytes of the canonical JSON serialization of the `catalog` value —
object keys sorted, arrays kept in declared order,
shortest-round-trip number formatting, no insignificant whitespace, no
trailing newline. The `catalog_hash` field sits outside the hashed bytes by
construction. A golden fixture — one checked-in catalog byte string with its
expected digest, including non-ASCII documentation text and numeric
defaults — is consumed by both the Nim and the app test suites, so the two
implementations of "canonical JSON" can never quietly disagree.

### 4.6 When a play call actually takes effect

The mechanics of receiving and applying a call are ported from Maxwell's
bot, whose propose/schedule/swap machinery was already reviewed and ratified
on his side (`onepage.nim:1206-1339`). The rules, including two that came
out of this design's own review rounds:

**There is exactly one mutation point.** The active pair — the play and its
state — changes in exactly one function, the equivalent of Maxwell's
`maybeApplyReflash`. Nothing else ever touches it.

**The startup call arrives by environment variable, but takes effect only
through the wire.** The variables keep Maxwell's names:
`COWORLD_POLICY_PAGE` for an inline JSON value, `COWORLD_POLICY_PAGE_FILE`
for a file path. If neither is set, that is not an error — unlike Maxwell's
bot, which dies without a page (`onepage.nim:1268-1278`), stencil has
existing launch paths that set no such variable (plain startup at
`LAB:stencil.nim:95-99`, the app's no-chat spawn, and `self_play.py`, whose
environment allowlist will also learn to pass these variables through —
`LAB:tools/self_play.py:33-42`). A missing variable simply synthesizes the
canonical default call, `{"play":"default","params":{}}`.

**Startup, in order.** Before the world map exists there is no active play
state at all; the `no_worldmap` guard answers every tick, just as the
ladder's first rung does today. When the first world-map build completes,
the shell fixes the game mode (§6.1) and initializes **the built-in default
play — always**, regardless of what the environment variable says. The
environment-provided call (which was validated at process start) then
travels the same road every call travels: it is proposed on the wire at the
moment the match starts playing, flows through `acceptCallEvent` (below),
and — if it differs from the default — takes effect at its scheduled tick
like any mid-match call. This indirection is not ceremony. An environment
variable is invisible to a replay; if it changed behavior directly, a
replayed match would be missing an input and could not reproduce the game.
Maxwell's bot encodes exactly this ruling (`onepage.nim:1206-1222,1280-1317`),
and this design keeps it: the first world-ready decisions are the built-in
default's, and no decision ever depends on bytes that the replay has not
consumed from the wire. The startup fixtures cover both game modes and walk
the whole sequence: world-map creation, the ticks before any call has
landed, acceptance of the canonical default as a re-assertion, and a
non-default startup call — for which the first world-ready tick still runs
the default, the scheduled tick switches, and deleting the call's wire
record makes the replay diverge.

**A new play takes effect after your own trigger is clear.** The moment of
effect is computed once, when the call is accepted:
`T_effect = T_request + max(1, ticks remaining on the current fire
wind-up)`. In plain terms: never swap your own strategy out from under your
own pulled trigger. Stencil computes this from its real wind-up state
(`fireHoldTicks`, `LAB:action.nim:424-432`) — better information than the
local estimate Maxwell's bot has to use. The new play's `init` runs at the
effect tick, and the old play's state is discarded.

**Re-sending the same call is meaningful, and it does not reset anything.**
Two remembered values make this work: the raw bytes of the call currently
*pending* (delivered but not yet sent), and the raw bytes of the call behind
the *active* play. Duplicate suppression applies only to the pending slot —
if the same candidate is delivered twice before it goes out, it is sent
once. But a delivered call whose bytes equal the active call is a
*deliberate re-assertion*, and it IS sent on the wire. The engine counts
every accepted flash — even an identical one — in a counter it folds into
the game's integrity hash, precisely so that a lost repeated event is
detectable (`sim_state.nim:347-385`, `sim_types.nim:1900-1908`); swallowing
re-assertions locally would defeat that. On the bot side, a re-assertion is
a state-preserving no-op: no `init`, state intact. A call with the same play
but different parameters is an ordinary swap, with a state reset.
Consequently "re-call the play to reset it" is not a thing; a play that
wants a reset knob declares a parameter for it.

**Live play and replay share one code path.** Both feed the same transition
function, `acceptCallEvent(raw, requestTick)`: bytes equal to the active
call → the event is observed (logged, visible on the wire) but schedules
nothing and initializes nothing; different bytes → a normal scheduled swap.
The replay reader calls this same function when it encounters a recorded
call (§8), which is what makes it impossible for a re-assertion to preserve
state live but reset it in replay.

**The mid-match hook.** A `pendingCall` slot is checked every frame — the
same pattern as Maxwell's `pendingProposal` (`onepage.nim:1445-1462`). For
local development it is fed by the file-watching stand-in; the real delivery
channel, when it is built, plugs into this slot and nothing else.

## 5. What is reused without modification

The table below is the reuse ledger. Everything marked "unchanged" is code
this design depends on and does not touch.

| Piece | Where it lives | Status under this design |
|---|---|---|
| The reflash wire format (the `0x86` message type with the `"CTFPOLICYPAGE1\n"` prefix) | `origin/maxwell/br-reflash-integration:src/ctf/labels.nim:602-636` | unchanged — the payload is opaque bytes to it |
| The engine's acceptance gate and 60 KB size cap | `sim_state.nim:347-385` | unchanged |
| The replay record, content hash, flash counter, and replay-time re-application | `replays.nim:272-357,582-602` | unchanged |
| The engine's rule that inputs are applied only at tick boundaries | `server.nim:86-93,2327-2344` | unchanged |
| The pre-round chat phase — its time limits, turn order, and never-fail fallback behavior | `PBP:origin/maxwell/lobby-chat:server/preround.mjs` | reused; one step is replaced (§7.1) |
| Delivery of the startup payload through environment variables at spawn | `PBP:origin/maxwell/lobby-chat:server/matchd.mjs` | unchanged — a play call is JSON starting with `{`, which already routes to the inline variable |
| The deferred match boot that waits for the chat phase | same | unchanged |
| Stencil's body: the planner, the movement follower, the corridor rule, micro-movement, and the order of `resolveAction` | `LAB:` | unchanged |
| Stencil's `Intent` type and combat code | `LAB:types.nim`, `action.nim`, `fight.nim` | **extended, not redesigned**: the `CombatPolicy` field and its filters (§4.2); with the field empty, behavior is bit-identical |
| The engine branch this all builds on | `origin/maxwell/br-season2-complete` | the integration base |

And the list of things this design makes unnecessary: both of Maxwell's page
languages (the expression VM and the row-of-weights placeholder), the work
of reconciling them, the refactor that would have been needed to score all
behaviors side-effect-free every tick, and the anti-flicker machinery a
per-tick scorer would have required.

## 6. The play library

### 6.1 The default play, and how the game mode is decided

Every playbook must contain a play named `default`. It takes no parameters,
and it is the play a bot runs when nothing has told it otherwise. It is also
the anchor for the compatibility proof, which forces an honest split in how
it is implemented, because "default behavior" means different things in the
two game modes.

**In classic CTF, the default is not a play module at all.** Today's
decision ladder is deeply entangled with `Belief` — it clears squad-order
fields, runs the consensus protocol, flips latches, and bumps counters as it
evaluates (`LAB:strategy.nim:329-405,425-480`). No read-only `PlayView`
contract can express that, and Codex's review made the choice stark: either
break the compatibility promise, or export a mutating "query" that every
play could then abuse. The design does neither. The `default` name, when the
game mode is CTF, dispatches to a **privileged adapter inside the shell** —
not under `plays/`, not subject to the import allowlist — which simply
invokes today's `decideObjective(Belief)` unchanged: the full historical
ladder, in its historical order, grenade and spray evasion in their
historical positions, every `Belief` write exactly as now. Because
`decideObjective` already contains the pursuit override and the idle-aim
stamp (`LAB:strategy.nim:502-515`), the adapter's result skips the
finisher's behavioral steps — only the telemetry tag is applied — since
running the pursuit override a second time on its own output would
double-count and break the proof. The adapter is the sole exception to the
mutation boundary, and it exists only to make "the refactor changed
nothing" provable. Two tests pin it: a compile-level check that no module
under `plays/` has any mutation privilege, and a parity test confirming the
adapter is the only exception. As for retiring it: that is a *future*
design's job, stated honestly. Phase 4a replaces only the role/posture
slice of the ladder; the rest of the privileged writes — spray latches,
consensus state, conversion state, counters — stay behind the adapter until
a dedicated CTF strategy redesign migrates them properly, with its own
baseline. This document does not promise that work.

**In Battle Royale, the default is a normal play**,
`plays/survive_default.nim`, written to the real read-only contract from its
first line. Its behavior arrives in two steps. Until Phase 4b it is a
deliberately inert placeholder: a validated hold-position intent (telemetry
reason `play:default:br_hold`), no reflex subscriptions, empty state. The
placeholder exists so the Phase 2 and Phase 3 Battle Royale binaries can
compile, boot, and give the end-to-end test a stable, named baseline; its
catalog documentation says "placeholder" in so many words. Phase 4b then
replaces its body with the real survival behavior — rotate ahead of the
shrinking zone, hold cover, stay near the partner — as a single measured
change, with the wire name `default` never changing. This ordering exists
because the lab's evaluation discipline requires one attributable change
per version; shipping the placeholder and the survival logic together with
the plumbing would make regressions unattributable.

**How the mode is decided.** The shell context carries a `GameMode` value —
`gmCtf` or `gmBr` — fixed once per episode at the moment the world-map
build completes. The rule is simple and observable: if endzones were
perceived by the time the map is built, the mode is CTF; if none were, it
is Battle Royale. Battle Royale maps author no endzones at all — the engine
forbids even inert ones
(`origin/maxwell/br-integrate:src/ctf/sim_types.nim:1309-1311`) — and Phase
2's perception work changes the map-build trigger so that it no longer
*requires* endzones. The timing works out by construction: no play decision
ever happens before the world map exists (the `no_worldmap` guard sees to
that), so no play ever runs with the mode undetermined. The `default` name
remains a single entry in the registry; the shell's activation step reads
the mode and dispatches — CTF to the adapter, Battle Royale to the
survive play. Both startup paths are covered by fixtures, and every play
can read `GameMode` from its `PlayView`.

### 6.2 The first Battle Royale plays

The starting library is deliberately small: the default plus three plays.
The library grows through the optimization loop, not through this document.
Parameter notation: `name: type (required, or its default) [constraints]`.

**`avoid_conflict`** — James's motivating example.

- `no_shoot_teams: TeamList (required)` — the teams this cog must never
  fire at, with any weapon. Implemented through
  `Intent.combat.noShootTeams` (§4.2).
- `protect: bool (default = false)` — when true, the listed teams also
  populate `combat.protectTeams`, and the play positions the cog to cover
  listed cogs that come under threat.

The play routes the cog along the safe interior of the current and next
zone rectangles, preferring positions with cover — this composes the
existing planner's danger weighting with the firing-position atlas
(`LAB:planner.nim`, `LAB:worldmap.nim:792-861`) — while the combat policy
handles the weapons side.

**`zone_rotate`**

- `earliness: number (default = 0.5) [0..1]` — rotate at the moment the
  next zone is announced (1) versus as late as survivable (0).
- `route_bias: string (default = "cover") [allowed: "cover", "direct"]`.

Predictive rotation into the next zone rectangle. Its goal scoring salvages
an existing piece of machinery: the barrage-centering room scorer, restricted
to rooms inside the upcoming rectangle — a reuse BR_LADDER specifically
recommends.

**`third_party`**

- `min_advantage: number (default = 1.0) [0..3]` — the health/engagement
  advantage required before committing to crash someone else's fight.
- `disengage_hp: number (default = 1.0) [0..3]` — break off at or below
  this health.

Detect a fight between two other parties, approach on a flank, and leave
when the numbers stop being favorable.

The number of knobs per play is the author's choice, and that is the point
of the whole design: `avoid_conflict` exposes two, and some future
tempo-control play might expose ten.

## 7. Integration with the match app (coworld-paintbot-player)

### 7.1 The pre-round phase calls a play instead of writing a page

The chat phase machinery does not change: two rounds of open conversation,
a thirty-second budget for the whole phase, twelve seconds per turn,
replies capped at five hundred characters, every seat hearing every seat.
The one step that changes is generation — the moment where, today, the
phase asks an LLM to *write a page* for each seat
(`preround.mjs:377-413`).

Under this design, the CLI's `page` subcommand becomes a `call` subcommand.
Its input gains the seat's play catalog (§4.5); its output is
`{ok, call: {play, params}}`. The prompt shown to the LLM becomes the
catalog — play names, parameter schemas, documentation — plus the chat
transcript and a briefing, replacing the page-language schema documents as
the prompt source (`loadPagePromptTemplate`, `preround.mjs:230-248`).

The validation loop keeps its current shape: a call that fails validation
(checked against the same serialized catalog, with the same conformance
rules the bot itself applies) is retried with the errors appended to the
conversation, up to three attempts. And the phase's cardinal rule holds: **a
seat always ends up with a call.** Every failure mode — no API key, a
timeout, three invalid attempts, a crashed CLI, the phase not running at
all — falls back to the canonical default call with the existing
`source`/`reason` bookkeeping (`preround.mjs:389-450`).

One canonical spelling, everywhere. The fallback, the prompt examples, and
the bot all use exactly `{"play":"default","params":{}}`. A call whose
top-level `params` key is missing is *normalized* to include the empty
object before it is proposed — normalized rather than rejected, because raw
byte equality is what identifies a re-sent call (§4.6), and two spellings
of the same default must never read as a state-resetting change of play.
This case is in the shared conformance vectors, and a test asserts the app's
fallback bytes equal the shell's canonical default bytes exactly.

Play calls remain per-seat, exactly as pages are per-seat today. A duo is
two seats and two calls, which may or may not name the same play.

### 7.2 How the lobby learns what a binary can do

The only source of truth about a binary's playbook is the binary. The app
obtains a seat's catalog by *executing the exact resolved seat binary* with
`--print-catalog`, once per build, caching the result keyed by the binary's
content hash. It never reads a catalog from a checkout, a sibling file, or
any separately versioned asset — every one of those alternatives can drift
from the binary it claims to describe, and drift is precisely the failure
this handshake exists to prevent.

The probe is strictly bounded, because not every binary will cooperate. A
legacy binary that does not know the flag will ignore it and enter its
normal connect-and-retry loop; the probe therefore runs under a two-second
deadline and then kills the process, caps stdout and stderr at 256 KB,
requires exactly one JSON document, and recomputes the embedded catalog
hash. The outcome is a per-binary capability: this build can describe its
plays, or it cannot.

Capability gates everything downstream. Only catalog-capable builds
participate in call generation and delivery. A build that is not capable —
which today means all of them: `baseline`, `picasso`, and Maxwell's
`onepage` (`PBP:origin/maxwell/lobby-chat:server/engine.mjs:77-123`) — gets
**no call environment variable at all**. Its spawn environment is exactly
what it is today (the current code already omits the page variable when
there is no page, `matchd.mjs:400-412`), and the phase records the seat as
`fallback_unavailable` with a reason naming the binary. The design pointedly
does *not* send `{"play":"default"}` to such a binary: the missing catalog
is the evidence that the binary does not speak this contract, and handing it
instructions anyway would be a guess. The phase never stalls in any of
these cases, per its existing never-throw discipline
(`preround.mjs:286-287`).

The test suite for this includes two builds receiving their own distinct
catalogs (the drift case), and fake binaries that hang (deadline kill),
print oversized output, print invalid JSON, embed a wrong hash, and predate
the flag entirely.

### 7.3 Mid-match calls

When the mid-match delivery channel is eventually built, the app-side
bookkeeping function `recordMidEpisodePage` finally gains its caller, and
its record shape — position, slot, tick, the call, source, reason — is
already right. On the bot side, the channel feeds the `pendingCall` hook
and nothing else (§4.6). Everything in between is out of scope here.

## 8. Determinism and validation

The validation story rests on one principle: **in any recorded game, the
stream of play calls has exactly one source of truth — the outbound wire.**
Every proposed call, including the startup call, is an outbound `0x86`
frame with the magic prefix, and the lab's wire recorder captures outbound
frames already (`STENCIL_WIRE_RECORD`, `LAB:stencil.nim:10-28`).

What does not exist yet is the consuming side, and Codex's review flagged
both gaps precisely. The offline replay tool processes only inbound packets
today (`LAB:replay.nim:47-56`), and the comparison script passes it only a
capture path and a seat number (`LAB:tools/compare_stencil.py:81-107`).
Both are in scope for this design:

- `replay.nim` learns to consume the outbound call records. When it
  encounters one after decision tick N, it feeds the very same
  `acceptCallEvent(raw, requestTick)` function the live path uses (§4.6). A
  call that differs from the active one schedules a swap under the same
  effect-tick rule, computed from the replayed wind-up state; a re-sent
  identical call is observed without scheduling or re-initializing, so a
  play's accumulated state survives in replay exactly as it does live. The
  startup call needs no special handling, because it is on the wire like
  everything else. Capture-time environment variables are therefore *not* a
  second source of call truth for replay; they matter only for validating
  process startup. Two fixtures pin the semantics: a play with real
  internal state that receives a re-assertion and must not reset, and a
  deliberately broken variant that does reset and must visibly diverge.
- `compare_stencil.py` learns to compare more than the output mask and chat.
  The Phase 1 gate asserts the specialized `Intent` fields too — cost
  profile, micro-permissions, radii, combat policy — because a comparison of
  masks alone can hide a lost flag that only matters in rare situations.

The acceptance gates, in the order they are earned:

1. **The refactor gate (Phase 1).** The rebuilt shell — plays compiled in,
   `default` active, roles intact — replays the existing CTF capture corpus
   and reproduces every decision exactly, field for field, against stencil
   v69.
2. **The swap gate (Phase 3).** A capture containing mid-match play swaps
   replays identically twice. Then the negative controls, copied
   deliberately from the engine's own reflash test suite
   (`tests/test_policy_reflash.nim`): delete the call records and the replay
   must diverge; shift them one tick and it must also diverge. A test that
   cannot fail is not a test.
3. **The live round-trip gate (Phase 3).** The pattern of
   `tools/roundtrip_reflash_match.sh`, run against a
   `br-season2-complete` engine build with a stencil seat: a real match, a
   mid-match play swap, plus a control run with the engine's reflash gate
   switched off, which must produce zero call records.

## 9. Prerequisites and phases

The work is ordered so that measurement comes first, behavior-preserving
work comes second, and behavior-changing work comes last and arrives in
separately attributable pieces.

**Phase 0 — measure the world-map build on a Battle Royale map.** Before
anything else. The Battle Royale field is about 6.9 times the area of the
CTF arena (3211×1713 pixels), and stencil currently builds *all* of its map
knowledge in the single tick after the map data arrives
(`LAB:policy.nim:39-50`, `LAB:worldmap.nim:173-209`). BR_LADDER flags this
as an open, unmeasured risk — the kind that appears as a mysterious
first-frame stall rather than an error — and says plainly that it is worth
timing before anything else is diagnosed. If the build does not fit the
budget, Phase 2 changes shape.

**Phase 1 — the play seam, on CTF, changing nothing.** The module graph of
§4.1 with its two compile-level proofs; the catalog mode; the reflex
observers and the finisher; the `IntentShape` migration of `makeIntent`;
the `CombatPolicy` field threaded through the body with its empty-value
proof; the CTF adapter wired as `default`'s CTF dispatch (the legacy ladder
untouched in `strategy.nim`); the Battle Royale placeholder
`survive_default`; the swap machinery; environment loading; and the
`replay.nim` and comparator extensions. The acceptance test is gate 1. None
of this depends on Battle Royale.

**Phase 2 — Battle Royale perception.** Everything the companion research
report's §7.2 lists: widening `Team` to sixteen values, building the world
map without endzones, reading the zone rectangles from the frame, partner
tracking, and the lives-display fix. One item carries a warning label from
BR_LADDER §5(a): `seatsPerTeam` currently computes the wrong value (4) for
a duo, but that wrong value happens to route the squad table into the
branch that produces the correct duo pairing — and correcting it to 2 also
changes `defenderCount` and the `enemyLivesLeft` arithmetic. It cannot be
"fixed" in isolation. Squad consensus is disabled outright for Battle
Royale (`SquadCommand = 0`), per BR_LADDER's analysis of how it
misbehaves for a lone survivor.

**Phase 3 — the flash plumbing, live against the engine.** The
propose-at-start behavior, the effect-tick rule, the file-watching
stand-in for mid-match calls, and gates 2 and 3. This phase also
establishes the hosted evaluation lane that Phase 4 depends on, since the
LLM-driven path does not arrive until Phase 5: the platform already
supports injecting per-policy environment variables at upload time (the
paintball mode ships this way — `coworld upload-policy … --secret-env
PLAYER_PROMPT=…`, `docs/paintball/COMMANDING.md:84-90`). A Phase 4
candidate is uploaded with its evaluation call baked in the same way. The
calls use registered names only: the Phase 4b candidate uploads with
`--secret-env COWORLD_POLICY_PAGE='{"play":"default","params":{}}'` (in
Battle Royale, mode dispatch selects the survival behavior — remember that
`survive` is not a wire name), and each Phase 4c candidate uploads its own
named call, for example
`'{"play":"zone_rotate","params":{"earliness":0.5,"route_bias":"cover"}}'`.
The round-trip gate checks the accepted on-wire bytes before any
evaluation counts. Every Phase 4 evaluation therefore holds the call fixed
and varies exactly one play.

**Phase 4 — the behavior changes, one at a time.** Nothing in this phase
claims byte-compatibility; every piece gets its own hosted evaluation,
per the lab's one-change-per-version rule
(`personal_paintbot/AGENTS.md:60-70`).

- *Phase 4a — roles and posture.* Deleting the `Role` machinery and
  choosing its dynamic replacement is **not executable from this
  document**. The lab's own directive says the replacement mechanism is
  the central open design question (`LAB:WORKING_CONTEXT.md:135-154`), and
  it gets its own design doc first. This document only fixes its position
  in the sequence — after the Phase 1 baseline exists — and its acceptance
  style: a hosted comparison against that baseline, never byte parity. The
  combat-policy safety tests (§4.2) land with the first play that
  exercises them.
- *Phase 4b — the real Battle Royale survival default.* One version, one
  evaluation.
- *Phase 4c and onward — the version-one plays* (§6.2), one version and
  one evaluation each, in whatever order the accumulating match corpus
  makes most informative.

**Phase 5 — the app side.** The `call` subcommand, the catalog probe, and
the prompt changes, in Maxwell's repository, coordinated with him — noting
that his `lobby-chat` branch and his Battle Royale branches currently
diverge from different bases, a known merge hazard.

## 10. The offline loop (a sketch; not part of this design)

Plays are authored between matches: harvest the hosted episode logs and
replay analyses, read the forum discussion, propose or revise a play, prove
it with property tests and self-play comparisons, and ship it in the next
policy version through the lab's existing ritual — design note,
implementation, evidence, `VERSION_LOG.md` entry. The harvesting tools do
not exist yet and are a separate piece of work. Nothing in the match path
depends on them.

## 11. Risks and open questions

1. **A wrong call sticks.** A badly chosen play runs until somebody calls a
   new one. The reflex layer bounds how badly that can go, but it bounds
   negligence, not strategic error. The mitigations are that the default
   play is genuinely strong and that every failure path falls back to it.
   The exposure is largest while the mid-match delivery channel does not
   exist, because until then, a bad pre-round call lasts the entire episode.
2. **The read-only boundary concentrates risk in `play_queries`.** Plays can
   only reach the world through that module, which means a mutating or
   alias-leaking query is the one place the guarantee could quietly break —
   invisible to the import check. The review rule stands: every addition to
   that module is audited for both in-body mutation (the lab's
   sweep-oscillator lesson, `LAB:TENTATIVE_LESSONS.md:20-26`) and for what
   its return value aliases.
3. **The zone-escape reflex trigger needs tuning.** "Imminent damage" has a
   horizon parameter, and it must be set so that rim-hugging plays are never
   fighting their own reflex. Phase 3 is where that gets tuned.
4. **The world-map build might not fit the tick budget** on a
   Battle-Royale-sized map (Phase 0). If it does not, map construction goes
   incremental, and Phase 2 is re-planned.
5. **`CombatPolicy` will attract feature requests.** Two team-sets today;
   pressure will come for priority targets, conditional truces, focus fire.
   The rule: the type grows only together with a play that needs the
   addition, and only with a proof that the empty value still means
   "exactly today's behavior."
6. **Maxwell's replies are pending** on the two departures in §3.3. His
   answers may adjust naming or how the parameter-entity rule is phrased in
   the shared vocabulary.

## 12. Affected files

For planning. New modules, following the dependency graph in §4.1:

- `LAB:paintbot/stencil_nim/play_queries.nim` — the opaque `PlayView`, the
  `GameMode` value, and the audited read API.
- `LAB:paintbot/stencil_nim/play_contract.nim` — the shared types,
  including every `PlayState` variant.
- `LAB:paintbot/stencil_nim/plays/` — one module per play, with the import
  allowlist enforced at build time.
- `LAB:paintbot/stencil_nim/play_registry.nim` — the `Playbook`.
- `LAB:paintbot/stencil_nim/plays.nim` — the shell machinery: the guards,
  the reflex observers and `ReflexState`, the finisher, the swap machinery
  including `acceptCallEvent`, the privileged CTF adapter (§6.1), and
  catalog emission.

Modified files:

- `LAB:types.nim` — the `CombatPolicy` field on `Intent`; the `IntentShape`
  enum.
- `LAB:strategy.nim` — the `makeIntent` shape migration only. The legacy
  ladder body stays where it is, behind the CTF adapter, for the life of
  this design; it does not move into a play. The reflex observers and the
  finisher are new code in `plays.nim`, not extractions from here.
- `LAB:action.nim` — the combat-policy filters in the target, fire, spray,
  and grenade paths; exposing the wind-up state for the effect-tick rule.
- `LAB:fight.nim` — the acquisition filter and the protect weighting.
- `LAB:policy.nim` — the decision station becomes guards → reflexes → play →
  finisher; the dead-tick stamp; the role-assignment block is deleted in
  Phase 4a.
- `LAB:perception.nim`, `LAB:belief_*.nim` — Battle Royale perception;
  sixteen teams.
- `LAB:replay.nim` — consuming outbound call records.
- `LAB:tools/compare_stencil.py` — field-level comparison and call inputs.
- `LAB:tools/self_play.py` — passing the call environment variables through.
- `LAB:tools/build_player.sh` — the catalog build gate.
- `LAB:Dockerfile` — unchanged at runtime; the catalog is printed at build
  time.

In Maxwell's repository, coordinated with him: `PBP:server/preround.mjs`
(the `call` step and catalog injection), `PBP:server/matchd.mjs` or
`engine.mjs` (the bounded catalog probe and its cache), the `lobby_chat`
CLI (the new subcommand), and the app tests (the two-build catalog case).

In the engine: nothing. The product-level rename of "page" to "play" is
Maxwell's call to make.
