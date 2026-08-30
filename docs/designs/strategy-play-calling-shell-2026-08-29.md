# The Play-Calling Shell: Compiled Plays Above the Intent Contract

> **Provenance:** this is a synced copy published for Maxwell and his coding
> agents. The canonical home is James's paintbot lab
> (`paintbot_lab/docs/designs/strategy-play-calling-shell-2026-08-29.md`);
> `LAB:` citations below refer to that lab's `paintbot/stencil_nim/` tree,
> which is not in this repository. If the copies ever disagree, the lab copy
> wins.

**Status:** DESIGN (rev 9; nine Codex cross-review rounds, converged at
VERDICT: SATISFIED) ·
**Date:** 2026-08-29 · **Author:** James's coding agent, direction from James ·
**Reviewers:** Codex (cross-agent, round-gated, adversarial), Maxwell (notified
re: divergences)

Companion documents (read first for context):
- `coworld-ctf:docs/reports/maxwell-s2-paradigms-2026-08-29.md` — the boundary
  research this design builds on (paradigm, interfaces, stencil clusters).
- `coworld-ctf:docs/recon/paintbot-s2-policy-shell-2026-08-29.md` — branch
  inventory and merge state.
- `origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md` (coworld-ctf) — BR
  rung analysis; §2 kill list, §6 authorability, §7 preconditions.

Citation conventions follow the research report: bare paths = coworld-ctf;
`PBP:` = coworld-paintbot-player; `LAB:` = this lab (`paintbot/stencil_nim/`
unless another lab path is given); `origin/<branch>:` = unmerged branch files.

---

## 1. Problem

Season 2 pits LLM "policies" against each other in Battle Royale: the policy
chats in a pre-round lobby, then directs a cog mid-match. Maxwell's shipped
substrate (branch `origin/maxwell/br-season2-complete`, cut 2026-08-29, =
reflash-integration + glory increments + playbook seeds + episode recorder)
implements this as *page scoring*: the LLM authors a JSON weight sheet over a
fixed 12-intent menu, and a bot argmaxes it every tick
(`origin/maxwell/br-reflash-integration:players/onepage/onepage.nim`).

James's ruling (2026-08-29) overhauls everything above the `Intent` contract:

> The plays are codelets/mini-programs which produce a typed `Intent` with
> parameters at each tick. The `Intent`→action logic remains the same, using
> stencil as the base. Those codelet plays are written by the player during the
> optimization loop — bringing in logs from previous games and forum posts — and
> evolve over time. The policy LLM starts with a playbook of these codelets,
> chats with other policies in the lobby, and selects a play to give the cog,
> along with any parameter values the play requires. The cog executes that play
> until it's given a new play.

The design goal: the *sophistication* of a strategy lives in offline-authored,
tested code; the *runtime* LLM only selects and parameterizes. This gives (a)
complex strategies that evolve through the optimization loop and the forum, (b)
on-the-fly strategic agility in the lobby and mid-match without runtime code
generation, and (c) player-controlled knob count — each play's parameter schema
is exactly as wide as its author wants.

## 2. Goals and non-goals

**Goals**
1. Define the Play abstraction and its contract with stencil's existing body.
2. Reuse Maxwell's reflash/pre-round machinery unchanged wherever it is
   payload-agnostic; enumerate the exact deltas where it is not.
3. Preserve the lab's determinism/validation instruments (`compare_stencil.py`
   + `replay.nim` exact-parity on recorded wire), extended to cover play calls.
4. Specify the reflex layer and the shell finalizer: what stays above and
   below the play, fixed in the shell.
5. Name the v1 play library for BR with complete parameter schemas, making
   James's "avoid conflict(squadmates)" example concrete end to end —
   including the one typed widening of `Intent` it requires (§4.2).
6. Sequence the work against the blocking BR preconditions, with parity
   anchors and behavior-changing phases kept separate.

**Non-goals**
- The mid-episode delivery lane (service → running bot). Both ends are stubs by
  design (`onepage.nim:1341-1352` `pollForNewPage`;
  `PBP:origin/maxwell/lobby-chat:server/preround.mjs:460-466`
  `recordMidEpisodePage`); this design defines the shell's hook and stops.
- The forum/optimization outer loop tooling (log harvest → play authoring).
  Sketched in §10; designed separately.
- Any interpreted play language. Ruled out for v1 (§3.2).
- Changing `resolveAction`'s resolution *order* or the planner/follower/micro
  machinery. (One typed contract widening does thread new data through the
  combat paths — §4.2 — the same way v69 threaded idle aim; that is a contract
  extension, not a body redesign.)

## 3. The paradigm, revised

### 3.1 Four layers

Maxwell's constitution (`origin/maxwell/br-onepage-vm:tools/flash/SCHEMA.md:15-48`)
has three layers: STRATEGY (LLM-authored page) → INTENT (fixed menu, page
scores it) → ACTION (engine-resolved). This design re-cuts it into four:

| Layer | Artifact | Author | Cadence |
|---|---|---|---|
| **CALL** | `{play, params}` — a play call | policy LLM (runtime selection) | spawn + reflash edges |
| **PLAY** | a compiled Nim codelet: params + belief → Intent | the player, offline | evolves per policy version |
| **INTENT** | stencil's typed `Intent` struct (`LAB:types.nim:189-219`), extended per §4.2 | play output, shell-finalized | every tick |
| **ACTION** | `resolveAction` → 8-bit mask (`LAB:action.nim:402-551`) | stencil body | every tick |

The LLM's runtime artifact shrinks from a program-shaped weight sheet to a
*call*: a play name plus typed arguments. Authoring moves entirely offline. This
keeps the property Maxwell's `"if"`-ban was protecting — no LLM-written control
flow reaches the match — while lifting the ceiling on strategy complexity to
"anything the player can write, test, and ship in Nim."

Terminology: **play** replaces **page** at the product level. Wire-level names
(`PolicyPageMagic`, `COWORLD_POLICY_PAGE`, `applyPolicyPage`, the replay record)
stay as-is until/unless Maxwell renames them; this doc says "play call" for the
payload those carriers move.

### 3.2 Why compiled Nim codelets (decision)

James ratified compiled-in plays. Recording the reasoning for future readers:

- **Determinism is inherited, not engineered.** A play is shell code; the shell
  is already deterministic given (frame stream, config, play-call stream). The
  lab's falsifier (`LAB:tools/compare_stencil.py`, 278,016/278,016 exact
  decisions for v69) keeps working with the extensions in §8.
- **The deployment loop already exists.** Coworld policies ship as container
  images; "edit Nim → build → upload" is the lab's routine cadence
  (`LAB:tools/build_player.sh`). Playbook evolution rides it for free.
- **The flash payload becomes trivial**: a play call is well under 1 KB against
  the 60,000-byte record cap (`origin/maxwell/br-reflash-integration:src/ctf/sim_types.nim:823-831`).
- **Rejected:** the `rules` s-expression VM
  (`origin/maxwell/br-onepage-vm:src/ctf/policy_page.nim`) and the `rows` stub
  — both exist to make LLM-authored artifacts safe; with authoring moved
  offline they solve a problem this design no longer has. Also rejected for
  v1: any embedded interpreter (Lua/wasm) — revisit only if same-binary play
  updates become a demonstrated need, and research existing options first at
  that point.

Trade-off accepted: the LLM cannot field a play the binary doesn't carry.
That is the design intent ("without needing to write new ones" — James), and
the catalog handshake (§7.2) makes the constraint visible to the LLM instead
of silent.

### 3.3 Divergences from Maxwell's constitution (deliberate, ratified by James)

1. **Entity-naming parameters.** SCHEMA.md rules that a strategy "cannot name a
   specific enemy or a specific pickup — there is no path for it." Play
   *parameters* relax this: a play's schema may accept entity references (team
   colors, "partner"), because lobby-negotiated alliances — which the pre-round
   system prompt itself encourages
   (`PBP:origin/maxwell/lobby-chat:server/preround.mjs:216-228`) — need a
   no-shoot list to be actionable. The constraint moves from "inexpressible"
   to "typed, play-scoped, and validated by the play author's schema."
2. **Selection replaces per-tick scoring.** No argmax over behaviors in the
   shell; the play is the behavior. (An individual play may still score
   sub-goals internally; that becomes a play-authoring pattern, not
   architecture.)

Maxwell was notified of both on 2026-08-29 (Discord); the second message with
this document follows.

## 4. The Play contract (stencil-side)

### 4.1 Types (concrete; the feasibility sketch)

Heterogeneous per-play parameters and state are closed tagged unions — the
registry stays a flat `seq`, and the compiler enforces exhaustiveness the same
way the existing enums do. Module ownership is deliberately acyclic (a naive
"plays.nim owns the union AND the registry while plays import plays.nim" is a
Nim import cycle — Codex round-3 finding 2):

The complete directed graph (each module imports only what is left of it):

```
types / belief_state / worldmap
  → play_queries.nim    (owns + exports the opaque PlayView, GameMode, and
                         the audited read API; exports no raw Belief;
                         imports NO play module)
  → play_contract.nim   (the shared types below incl. every PlayState arm;
                         imports play_queries to name PlayView, nothing else
                         play-related)
  → plays/<name>.nim    (one module per play; may import ONLY play_contract,
                         types, play_queries, plus an explicit safe std/*
                         allowlist — math, options, sets, tables, algorithm,
                         heapqueue; other project modules and side-effecting
                         std modules (os, net, times, osproc, …) are
                         rejected — build-time import check)
  → play_registry.nim   (let Playbook* = @[...]; imports the play modules)
  → plays.nim           (shell machinery; imports the registry; no play
                         module imports it back)
```

Sketch (types in `play_contract.nim`):

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
    minVal*, maxVal*: float            # vkNumber only; validated fail-loud
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
    name*: string                      # snake_case, the catalog/wire identity
    doc*: string
    schema*: seq[ParamSpec]
    reflexes*: set[Reflex]             # which shell reflexes this play delegates
    init*: proc(params: PlayParams, view: PlayView): PlayState {.nimcall.}
    step*: proc(state: var PlayState, params: PlayParams,
                view: PlayView): Intent {.nimcall.}
```

`init` takes the view because initialization is mode- and world-aware (§6.1);
it runs only when both are known — see the bootstrap rule in §4.6.

Feasibility proof obligations for P1, before any behavior work: (a) the
contract compiles with **two** plays of different parameter and state shapes
registered through `play_registry.nim`; (b) a **compile-negative fixture** —
a play module that tries to read or write a raw `Belief` field fails the
build (no such symbol reaches it).

Contract rules:

- **`step` is the mind.** It replaces the deliberate body of
  `decideBaseObjective` (`LAB:strategy.nim:329-500`). Every goal routes
  through the validated-goal contract (`reachableGoal` → `nearestReachable`,
  `LAB:strategy.nim:107-110`) — a play that cannot validate its goal emits a
  Hold with a reason, never a beeline. The v66 law, unchanged.
- **Plays own their state, mutably and explicitly.** `state: var PlayState` is
  the one mutation surface a play is *supposed* to use; it is created by
  `init` at swap time and dropped at the next swap or episode edge.
- **Plays never see `Belief` at all.** `Belief` is a `ref object` with
  exported mutable fields (`LAB:belief_state.nim:19-137`); an import
  allowlist alone cannot help once the type is nameable in a play's `step`
  signature (Codex round-3 finding 1). Ruling: `step` takes an opaque
  **`PlayView`** — defined in `play_queries.nim` with a **private** backing
  `Belief` field (ref-backed, no copying) — and plays read the world only
  through that module's exported query procs (fact getters + the pure
  helpers: `reachableGoal`, track/zone/item queries, `makeIntent`, plus the
  shell context of §6.1). The import allowlist still applies (it keeps
  helper-module sprawl out), but the mutation boundary is the private field:
  a play cannot name a Belief field it cannot reach. **And no mutable alias
  escapes**: Belief and `WorldMap` are ref objects full of reference-backed
  containers (`LAB:belief_state.nim:19-58`, `LAB:worldmap.nim:70-94`), so a
  getter returning a raw ref, a backing `seq`, or a table would hand plays
  shared mutable state without ever naming a Belief field. Contract: query
  procs return scalars, value snapshots, or copied sequences of value-only
  records; map operations (`reachableGoal`, post lookups) *execute inside*
  `play_queries` and return values — `WorldMap`/`Belief` refs and their
  backing containers never cross the boundary. Proof: the compile-negative
  fixtures (raw Belief access; WorldMap field access) plus a runtime alias
  test — mutating a returned collection must not change Belief. Query procs
  are audited on every addition for both in-body mutation (the
  sweep-oscillator lesson, `LAB:TENTATIVE_LESSONS.md:20-26`) and result
  ownership. Latch/counter writes that today's rungs
  make on Belief (`LAB:strategy.nim:434-438,448-455`) move into `PlayState`
  as their rungs are absorbed into plays — except the grandfathered legacy
  default (§4.4, §6.1); the body's telemetry writes (leak #6) are unchanged.
  Escalation path if the query surface proves too narrow: widen
  `play_queries`, never the boundary.
- **Plays emit *semantic* intents; the reason string stays telemetry.**
  `makeIntent`'s `case reason` table is behavior-bearing today — the exact
  string selects profiles, micro sets, radii (`LAB:strategy.nim:40-99`) — and
  BR_LADDER independently warns `reason` must not become load-bearing and
  recommends a separate semantic identifier
  (`origin/maxwell/br-ladder-design:docs/designs/BR_LADDER.md:800-804`).
  Ruling: `makeIntent` gains an explicit semantic parameter — an
  `IntentShape` enum whose members are today's reason vocabulary — and the
  telemetry string becomes free-form: plays call
  `makeIntent(kind, point, shape = isClearSpray, reason = "play:default:clear_spray")`.
  The shape enum, not the string, drives the flag table. Migration of existing
  call sites is mechanical (shape := the current literal).

### 4.2 The one typed widening: `CombatPolicy` on `Intent`

Codex's round-1 review is right that the rev-1 contract could not implement
`avoid_conflict`: `Intent` carries movement/aim/micro only
(`LAB:types.nim:189-219`), and `resolveAction` selects combat targets itself —
`selectTarget(belief, candidates)`, spray pursuit, and the grenade overlay
never consult the mind (`LAB:action.nim:472-524`, `LAB:fight.nim:226-283`).
A no-shoot list has **no data path** to the body without widening the
contract. So it widens — the same move v69 made for idle aim, and for the same
reason: the decision belongs to the mind, the mechanism to the body.

```nim
type
  CombatPolicy* = object
    noShootTeams*: set[Team]   # never targeted by gun, spray, or grenade
    protectTeams*: set[Team]   # bias: up-weight proximity threats near these teams

  Intent* = object
    ...                        # all ten existing fields unchanged
    combat*: CombatPolicy      # default: both sets empty
```

Body threading. "Never shoot" is stronger than "never select as the target
endpoint" — the body's own safety machinery shows the three ways a bullet,
cone, or blast reaches a cog nobody aimed at. The enforcement principle:
**`noShootTeams` members join the protected set that every existing
friendly-safety check already consults** — they are treated the way teammates
are treated today, in each weapon path:
- *Target selection*: `selectTarget` candidate filtering and `scoreTarget`'s
  defensive-threat term (`LAB:fight.nim:150-283`) exclude `noShootTeams`
  members; enemies **threatening** `protectTeams` members are up-weighted.
  "Threatening" is defined deterministically from what perception actually
  contains — observations carry position/facing/aim/team/loadout but no
  attacker–victim relation (`LAB:types.nim:38-69`), and heard impacts have no
  attacker identity — so the relation is proximity-based, generalizing the
  heuristic onepage already uses for `partner.in_combat` — made fully
  deterministic by naming its constants **and by defining both sides of the
  relation by color, never by track container**: stencil's `enemyTracks` is
  observer-relative (every cog not the policy's own color,
  `LAB:perception.nim:325-346`, `LAB:belief_update.nim:411-433`), so "enemy
  track near protected cog" would make two duo-mates on one protected team
  read as threats to each other. The relation: a *protected candidate* is
  any fresh track (teammate or enemy container) with `color in
  protectTeams`; a *threat candidate* is any fresh track whose color differs
  from that protected cog's **and** is in neither `noShootTeams` nor
  `protectTeams` (listed teams are never threats to each other — anything
  else contradicts `avoid_conflict`'s purpose). The policy's **own team is
  legal in `protectTeams`** (its cogs arrive via `teammateTracks`) — the
  implementation scans both containers by color. Freshness: both tracks
  within `TrackTtlTicks` (120, `LAB:config.nim:144-149`); distance strictly
  `<` `ProtectThreatRangePx` (default 200, matching onepage's
  `ThreatRange`/strict-`<` precedent, `onepage.nim:75-84,1110-1118`; a new
  `STENCIL_*` knob). The up-weight is one new additive term in `scoreTarget`
  with its own named weight knob (`ProtectThreatWeight`), zero when
  `protectTeams` is empty (the parity default). Positioning tie-break for
  `avoid_conflict`'s `protect`: nearest protected cog under threat, then
  lowest cog index. No attacker attribution is claimed or needed; richer
  inference (aim-cone, damage attribution) is explicitly future work.
  Fixtures: one clear threat; ambiguous crossfire; stale tracks (each side of
  the pair stale independently); no observable threat; two nearby cogs on one
  protected team (no mutual threat); two nearby protected teams (no
  cross-threat); a real unprotected third-team threat; own-team protection
  via teammate tracks. Tie-break unchanged: eligibility filter first, then
  nearest protected cog under threat, then lowest cog index.
- *Every acquisition path, plus a final endpoint veto.* `selectTarget` is not
  the only way the body acquires a target: outside an active firefight the
  gun falls back to `belief.nearestEnemy` (`LAB:action.nim:472-476`, scan at
  `:31-39`), and the arc selector scans all enemies independently
  (`LAB:fight.nim:26-44`). The policy filter therefore applies at **all**
  acquisition sites (`selectTarget`, `nearestEnemy`, `sprayTarget`/arc), and
  — as defense in depth against any future path that forgets the early
  filter — a **final endpoint veto** runs immediately before each weapon's
  fire decision, refusing a `noShootTeams` endpoint regardless of how it was
  acquired (the corridor helper alone cannot do this: it deliberately
  ignores the entity at the endpoint, `LAB:action.nim:94-105`). Tests:
  `Firefight=false` and `firefightActive=false` cases where the nearest cog
  is excluded but a farther allowed target exists; an arc-selector case.
- *Gun*: the corridor check that refuses a shot when a teammate lies along the
  segment (`LAB:action.nim:94-118`) extends its blocker set to `noShootTeams`
  — an allowed target behind a protected cog is not a legal shot.
- *Spray*: the cone paths (`LAB:action.nim:51-60,490-499`) refuse activation
  when a protected cog is inside the cone, exactly as for teammates.
- *Grenade*: the blast-safety prediction (`LAB:action.nim:273-278`) treats
  protected cogs as splash-forbidden, and the cluster planner
  (`LAB:action.nim:285-335`) never counts them as value. **An in-progress
  charge is revalidated the tick `CombatPolicy` changes**: if the held throw
  (`belief.throwTarget`, force-release path `LAB:action.nim:353-400`) would
  violate the new policy, the charge is cancelled, never force-released
  through the veto.
- The dead-tick hand-built intent (`LAB:policy.nim:103`) stamps
  `combat = CombatPolicy()` — per the standing lesson that every new Intent
  field must be stamped there (`LAB:TENTATIVE_LESSONS.md:28-32`).
- **Parity default:** an empty `CombatPolicy` must be bit-identical to today's
  behavior; the P1 parity gate proves it (§8).
- **Tests (landing with the first play that exercises them, P4c; controls in
  P1):** an excluded cog (a) between
  shooter and an allowed gun target, (b) inside the spray cone beside an
  allowed target, (c) inside grenade radius of an allowed center, (d) entering
  the policy while a grenade is already charging — plus the empty-policy
  parity control.

This is the one place the design amends "the `Intent`→action logic remains the
same": the logic's *order and machinery* are unchanged; the contract gains one
field the machinery filters by. James has ratified the play's semantics
("not shoot anyone on that squad mates list … and also cover them"); this is
the minimal honest implementation of them.

### 4.3 The decide pipeline: reflexes → play → finalizer

Per tick, the decide station (`LAB:policy.nim:99-105` today) becomes:

1. **Unconditional guards**: `not_alive`, `no_worldmap` — always shell-owned
   (they are prerequisites of *any* decision, and match today's ordering).
2. **Subscribed reflexes** (§4.4): the shell runs exactly the reflexes in the
   active play's `reflexes` set, in fixed order. If one fires, its Intent goes
   to the finalizer; the play's `step` is not called this tick.
3. **The active play's `step`** otherwise.
4. **The shell finalizer** (fixed, **origin-aware** — this answers "who stamps
   what the ladder's tail used to" without changing control flow):
   - For an **alive-path** Intent (play or subscribed reflex): applies the
     **arc-pursuit override** exactly as today's post-ladder step does
     (`LAB:strategy.nim:504-514`) — shell-owned combat opportunism, gated on
     the winning Intent's `MicroSprayPursuit` flag, so a play opts out the
     same way rungs do today (by shaping its micro set); then stamps
     `idleAimCenterBrads` (`LAB:strategy.nim:515`) — absence is a producer
     bug the body `.get`s on (`LAB:action.nim:525-533`), so the finalizer,
     not each play, owns it.
   - For the **`not_alive` guard**: arc pursuit is bypassed — today's dead
     branch never enters `decideObjective` (`LAB:policy.nim:99-105`), and
     that exclusion is contract, not accident — and the Intent receives
     exactly the fields the current dead branch stamps, plus the empty
     `CombatPolicy`. Fixture: a dead-tick field-level parity test with
     hostile Belief values (`iHaveArc` true, a live spray target) proving the
     exclusion is control flow, not luck.
   - Both paths: prefix the telemetry reason with `play:<name>:` /
     `reflex:` / `guard:` for trace.

Reflexes and finalizer are the only shell-owned decision logic; everything
between them is the play.

### 4.4 The reflex layer (subscribed, above the play)

Reflexes are shell-implemented behaviors a play *delegates* via its
`reflexes` set (§4.1) — subscription, not universal preemption, because a
universal reflex-first ladder is a behavior change in disguise: today's
ladder runs `carry_home` and the thief intercepts *before* grenade/spray
clearing (`LAB:strategy.nim:349-374`), so a carrier inside grenade range
carries home rather than fleeing, and reflex-first would silently invert
that. The subscription model preserves both worlds:

- `clear_grenade` (`rxClearGrenade`) — radial escape from grenade warnings
  (`LAB:strategy.nim:359-370`).
- `clear_spray` (`rxClearSpray`) — the scored 16-direction flee under the
  existing hysteresis latch (`LAB:strategy.nim:221-309`).
- `zone_escape` (`rxZoneEscape`, BR only, new) — triggered on
  **damage-imminent** (outside the rect with `dps > 0` live, or the shrink
  putting the cog outside within a small tick horizon), NOT on mere edge
  proximity — a rim-hugging play must not fight its own reflex. Shortest
  validated route inside. Predictive zone work stays in plays.

**Reflex state is shell-owned and always current.** Reflexes with memory (the
spray hysteresis latch, `LAB:strategy.nim:186-225`) keep it in an explicit
`ReflexState` owned by the shell, not on Belief and not in any play's
`PlayState`. Lifecycle: reset at episode edges; **the reflex observers update
`ReflexState` every alive tick regardless of the active play's
subscriptions** — subscription gates only whether a reflex may *preempt*, not
whether it *observes*. That rule is what makes persistence real across a
swap: a play change mid-flee finds the shell latch already active, because it
never stopped watching (no state bridging from the legacy fields needed).
Fixture: with the legacy default active, enter the hysteresis band
(`sprayFleeActive` true), swap to a subscribed play, and assert the flee
continues uninterrupted. Exception for parity: the **CTF legacy adapter**
(§6.1 — a privileged shell path, not a play module) keeps using today's
Belief latch fields exactly as the code does now (the shell observer writes
only `ReflexState`, never Belief, and since the adapter runs with
`reflexes = {}` semantics the observer never preempts, so parity is
untouched); telemetry counters stay on Belief where they live today. The
exception ends when P4 reworks CTF strategy.

Subscription policy: **new plays delegate everything applicable**
(`{rxClearGrenade, rxClearSpray, rxZoneEscape}` on BR) so a play author never
re-implements survival; **the CTF legacy adapter runs with `reflexes = {}`** and
keeps grenade/spray clearing as its own rungs in their historical positions —
which is what makes the P1 parity reduction exact: with `reflexes = {}`, the
pipeline is (unconditional guards) + (the full old ladder) + (finalizer) =
today's `decideObjective`, statement for statement. Adopting reflex
delegation for CTF play is a P4-measured behavior change, never a refactor
claim.

Everything else that is currently a rung — `barrage_center`, `carry_home`,
item fetching, squad orders, posts — is play territory. The reflex enum is
deliberately small; growing it is a design decision, not a convenience.
Reflex preemption is visible in telemetry (`reflex:<name>`).

### 4.5 The playbook registry and catalog

```nim
let Playbook*: seq[Play] = @[defaultPlay, avoidConflictPlay, ...]  # sole registration point
```

- Names are the wire identity; renaming a play is a breaking change to any
  stored call and is treated like a config-schema change.
- Call validation is config-grade and fail-loud (`LAB:config.nim:7-51` is the
  template): unknown play name, unknown/missing/ill-typed param, out-of-range
  number, string outside `allowedStrings`, malformed team name, duplicate
  team, non-finite number → the call is **rejected before it is proposed on
  the wire** (mirrors `onepage.nim:1445-1451`), and the active play is
  unchanged. At process start, an invalid startup call is FATAL (mirrors
  `onepage.nim:1533-1546`). Parsing applies `default` for every omitted
  optional param, so a `PlayParams` is always total over the schema.
- **Catalog provenance (single source of truth, no skew):** the stencil binary
  gains a `--print-catalog` mode that emits `{"catalog": …, "catalog_hash":
  …}` to stdout and exits — `catalog` carrying names, schemas (defaults,
  ranges, allowed values), and docs. The hash has a byte-exact
  cross-language contract: **SHA-256, lowercase hex, over the UTF-8 bytes of
  the canonical JSON serialization of the `catalog` value** — object keys
  sorted, play/schema array order preserved as declared, shortest-round-trip
  number formatting, no insignificant whitespace, no trailing newline; the
  `catalog_hash` field is outside the hashed bytes by construction. A golden
  fixture (one checked-in catalog byte string + expected digest, including
  non-ASCII doc text and numeric defaults) is consumed by both the Nim and
  app test suites. The app obtains a seat's catalog by executing **the exact
  resolved seat binary** offline once per build (cached by binary hash) —
  never from a checkout, a sibling file, or a separately versioned asset,
  which would recreate the skew the handshake exists to close. App-side and
  Nim-side validation consume the same serialized catalog; shared conformance
  vectors cover omitted optionals, unknown keys, wrong JSON types, invalid
  team names, duplicates, and non-finite/out-of-range numbers (§7.2).

### 4.6 The swap state machine

Ported from onepage's propose/schedule/swap (`onepage.nim:1206-1339`), with
one contradiction from rev 1 resolved:

- One mutation point: the active `(Play, PlayState)` pair changes only in the
  `maybeApplyReflash` equivalent.
- Startup call arrives via env (`COWORLD_POLICY_PAGE` inline /
  `COWORLD_POLICY_PAGE_FILE` path — names kept, §3.1); it is **proposed on
  the wire at the playing edge** so the replay records the opening play (the
  determinism ruling in `onepage.nim:1210-1223`, adopted verbatim).
- **Absence is a compatibility case, not an error** (unlike onepage's
  fatal-on-missing, `onepage.nim:1268-1278`, which would break every existing
  stencil launcher — plain `stencil.nim:95-99` startup, the no-chat app spawn
  that omits page env (`PBP:origin/maxwell/lobby-chat:server/matchd.mjs:400-412`),
  and `self_play.py`): a missing env synthesizes the canonical raw
  `{"play":"default","params":{}}`, validates it, and proposes it on-wire at
  the playing edge like any other startup call — so the replay still records
  the opening play. A **present-but-invalid** value remains FATAL at process
  start. (`self_play.py`'s env allowlist additionally learns to pass
  `COWORLD_POLICY_PAGE*` through, `LAB:tools/self_play.py:33-42` — §12.)
- **Bootstrap rule (the built-in default first; env bytes only via the
  wire).** Before the WorldMap exists there is no active `PlayState` — the
  `no_worldmap` guard answers every tick, as rung 0 does today. At the first
  completed WorldMap build the shell fixes `GameMode` (§6.1) and runs `init`
  exactly once for the **canonical built-in default — always**, regardless of
  what the env carries. The env-provided startup raw (already
  catalog-validated at process start) then travels the one road every call
  travels: proposed on the wire at the playing edge, through
  `acceptCallEvent` — if canonical default, it is the documented reassertion
  (observed, no re-`init`); if different, it schedules normally and
  activates only in the `maybeApplyReflash` equivalent at `T_effect`. This
  preserves the sole-mutation-point rule and the replay contract: the first
  world-ready decisions are the built-in default's, and no decision ever
  depends on env bytes replay has not consumed from the wire (the exact
  ruling onepage encodes, `onepage.nim:1206-1222,1280-1317`). Fixtures: CTF
  and BR startup covering WorldMap creation, the pre-call ticks,
  canonical-default reassertion, and a **non-default startup call** whose
  first world-ready tick is still default, whose `T_effect` tick switches,
  and whose replay diverges when the outbound record is dropped.
- Swap boundary: `T_effect = T_req + max(1, fireWindupRemaining)` computed
  once, using stencil's real windup state (`fireHoldTicks`,
  `LAB:action.nim:424-432`) rather than onepage's local estimate. `init` runs
  at the swap tick; the old play's state is dropped.
- **Reassertion contract (rev-1 fix).** Two raws are tracked separately:
  `pendingRaw` (a candidate delivered but not yet sent) and `activeRaw` (the
  call behind the running play). Duplicate-suppression applies only to
  `pendingRaw` — the same candidate delivered twice before sending is sent
  once. A delivered call whose raw equals `activeRaw` is a **deliberate
  reassertion**: it IS sent on the wire (so the engine accepts it and
  increments the epoch — the exact lost-repeated-event detectability the
  engine's epoch exists for, `sim_state.nim:347-385` +
  `sim_types.nim:1900-1908`), and locally it is a state-preserving no-op: no
  `init`, `PlayState` intact. A call with the same play but different params
  is a normal swap (state reset). "Re-call to reset state" is therefore not a
  thing; if a play needs a reset knob, its author adds a param.
- **One transition for live and replay:** both feed
  `acceptCallEvent(raw, requestTick)` — if `raw == activeRaw`, the event is
  observed (wire-visible, logged) but schedules nothing and runs no `init`;
  otherwise the normal swap is scheduled. `replay.nim` calls the same
  function from captured outbound records (§8), so a reassertion cannot
  reset state in replay while preserving it live.
- Mid-episode trigger: a `pendingCall` hook checked each frame (the
  `pendingProposal` pattern, `onepage.nim:1445-1462`), fed by the file-watch
  stand-in for local dev; the real delivery lane plugs in here (non-goal).

## 5. What is reused, byte-for-byte

| Piece | Where | Status under this design |
|---|---|---|
| Reflash wire (0x86 + `PolicyPageMagic`) | `origin/maxwell/br-reflash-integration:src/ctf/labels.nim:602-636` | unchanged; payload is opaque |
| Gate / acceptance / 60 KB cap | `sim_state.nim:347-385` | unchanged |
| Replay record + hash + epoch + playback re-apply | `replays.nim:272-357,582-602` | unchanged |
| Tick-boundary inbox drain | `server.nim:86-93,2327-2344` | unchanged |
| Pre-round chat phase (bounds, sequencing, fallback discipline, records) | `PBP:origin/maxwell/lobby-chat:server/preround.mjs` | reused; one step swapped (§7.1) |
| Spawn env delivery (`pageEnv`) | `PBP:origin/maxwell/lobby-chat:server/matchd.mjs` | unchanged (call JSON starts with `{` → inline var) |
| Deferred boot (`finishBooting`) | same | unchanged |
| Stencil body: planner, follower, corridor, micro, resolution order | `LAB:` | unchanged |
| Stencil `Intent` + combat paths | `LAB:types.nim`, `action.nim`, `fight.nim` | **extended, not redesigned**: the `CombatPolicy` field + its filters (§4.2); empty-policy behavior bit-identical |
| Base engine branch | `origin/maxwell/br-season2-complete` | the integration substrate |

What this design **retires**: both page languages (`policy_page.nim` VM +
`policy_stub.nim` rows), their reconciliation problem, the evaluate-all purity
refactor, and per-tick selection hysteresis.

## 6. The play library

### 6.1 The default play

`default` — required, parameterless, and the parity anchor. The CTF legacy
behavior is **not a play module**: today's ladder is mutation-heavy far
beyond any read-only `PlayView` contract — it clears squad-post fields, runs
consensus, flips latches, and bumps counters on Belief
(`LAB:strategy.nim:329-405,425-480`) — so pretending it is a normal play
would either break parity or force a mutating "query" export every play
could then call (Codex round-6 finding 1). Ruling: the `default` wire
identity dispatches on `GameMode` to two implementations —
- `gmCtf` → a **privileged parity adapter in the shell** (not under
  `plays/`, not subject to the import allowlist) that invokes today's
  `decideObjective(Belief)` path unchanged: full historical ladder order,
  grenade/spray clearing internal, `reflexes = {}` semantics, every Belief
  write exactly as now. Because `decideObjective` already contains the
  arc-pursuit override and the idle-aim stamp (`LAB:strategy.nim:502-515`),
  **the adapter's result bypasses the finalizer's behavioral steps** (only
  the telemetry tag is applied) — running arc pursuit a second time on its
  own output would double-fire the pursuit counter and break parity. It is
  the *sole* mutation exception and exists only for the parity anchor.
  **Its retirement is a future design, not a promise of this one**: P4a
  replaces only the roles/posture slice; the other privileged Belief writes
  (spray latches, consensus/order state, conversion state, counters) remain
  behind the adapter until a dedicated CTF strategy-rework design migrates
  them into `PlayState`/shell operations with its own baseline — explicitly
  out of scope here. Tests: a compile check that no module under `plays/`
  has mutation privilege, and a parity test pinning the adapter as the only
  exception.
- `gmBr` → `plays/survive_default.nim`, a **normal read-only play** written
  to the real contract from day one. **Its behavior arrives in two steps**:
  until P4b it is a deliberately behavior-neutral placeholder — a validated
  Hold at position (reason `play:default:br_hold`), no subscribed reflexes,
  empty state — created with the seam in P1 so the P2/P3 BR binaries compile,
  boot, and give the hosted round-trip a stable, named baseline; its catalog
  doc says "placeholder". P4b then replaces its body with the real `survive`
  behavior (predictive zone rotation + cover hold + partner proximity) as
  the one measured change, wire identity unchanged.

The CTF adapter keeps **the Role machinery intact**: role-keyed rungs,
role-keyed target scoring, and the orchestrator's assignment block stay as-is
(`LAB:strategy.nim:404-420,480-491`, `LAB:fight.nim:150-160,239-250`,
`LAB:policy.nim:55-98`). Byte-identical decisions to the pre-play shell,
provable on the recorded-wire corpus (§8, gate 1). Role *deletion* is a
separate, behavior-changing phase with its own acceptance (§9, P4) — parity
and deletion cannot share a phase (rev-1 finding 4; the replacement
division-of-labor mechanism is itself the open design question the lab
directive names, `LAB:WORKING_CONTEXT.md:135-154`).

On BR (post-preconditions) the default's *behavior* is `survive`: predictive
zone rotation + cover hold + partner proximity — the "do no harm" baseline a
fallback call can always name (§7.1's never-null rule needs it).

**Mode dispatch is explicit, not inferred per tick.** The shell context
carries a `GameMode` (`gmCtf | gmBr`), fixed once per episode **at WorldMap
build completion**: endzones perceived by then → `gmCtf`, none → `gmBr` (BR
maps author no endzones, "not even INERT ones" —
`origin/maxwell/br-integrate:src/ctf/sim_types.nim:1309-1311`; P2 changes the
build gate to not *require* endzones). This is timing-safe by construction:
no play decision precedes the WorldMap (the `no_worldmap` guard holds until
it exists), so no play ever runs with mode undetermined. `default` stays one
wire identity and one `PlayKind`; **the shell's activation step dispatches on
`GameMode`** — `gmCtf` to the privileged adapter, `gmBr` to
`plays/survive_default.nim`'s normal `init`/`step` (above). Both startup
paths are tested. `GameMode` is exposed to all plays via `PlayView`.

### 6.2 v1 BR plays (small on purpose)

Schema notation: `name: kind (required | default=X) [constraints]`.

1. **`avoid_conflict`** — James's motivating example.
   - `no_shoot_teams: TeamList (required)` — teams never targeted (gun, spray,
     grenade), via `Intent.combat.noShootTeams` (§4.2).
   - `protect: bool (default=false)` — when true, listed teams also populate
     `combat.protectTeams`, and positioning biases toward listed cogs under
     threat.
   - Behavior: route along the safe interior of the current/next zone rect
     preferring cover (planner danger weights + post atlas,
     `LAB:planner.nim`, `LAB:worldmap.nim:792-861`); combat policy as above.
2. **`zone_rotate`**
   - `earliness: number (default=0.5) [0..1]` — rotate at phase edge vs. late.
   - `route_bias: string (default="cover") [allowed: "cover", "direct"]`.
   - Predictive rotation into `zonenext`; salvages `barrageGoal`'s room-peak
     scorer restricted to the next rect, per BR_LADDER's suggestion.
3. **`third_party`**
   - `min_advantage: number (default=1.0) [0..3]` — required HP/engagement
     advantage before committing.
   - `disengage_hp: number (default=1.0) [0..3]` — break off at/below.
   - Fight-detection → flank approach → disengage below threshold.

Parameter count per play is the author's choice — that is the design's point:
`avoid_conflict` exposes two knobs; a future `tempo` play might expose ten.

## 7. App-side integration (coworld-paintbot-player)

### 7.1 Pre-round: page generation becomes play calling

The phase machinery is untouched (2 rounds, 30 s budget, 12 s turns, 500-char
replies, sequential, fully open). The delta is the generation step
(`preround.mjs:377-413`):

- CLI subcommand `page` → **`call`**: input gains the seat's **catalog JSON**
  (§4.5); output is `{ok, call: {play, params}}`. The prompt is the catalog +
  the chat transcript + a brief, replacing `SCHEMA.md`/`prompt.md` as the
  template source (`loadPagePromptTemplate`, `preround.mjs:230-248`).
- Validation loop unchanged in shape: an invalid call (checked against the
  same serialized catalog with the same conformance rules) retries with
  errors appended, ≤3 attempts; **a call is never null** — every failure
  falls back to the canonical `{"play":"default","params":{}}` with the
  existing `source`/`reason` taxonomy (`preround.mjs:389-450`). **Canonical
  shape everywhere:** a missing top-level `params` is *normalized* to `{}`
  before proposal (never rejected) by every producer — normalization rather
  than rejection because raw byte equality is the reassertion identity
  (§4.6), and two spellings of the same default must not read as a
  state-resetting swap. Conformance vector included; the app fallback raw is
  asserted byte-equal to the shell's canonical default raw.
- The Page record's `page` field carries the call object; records stay
  per-seat (a duo runs two calls, possibly the same one).

### 7.2 The catalog handshake (concrete)

- Build side: `--print-catalog` on the stencil binary (§4.5) is the only
  catalog source. `LAB:tools/build_player.sh` runs it as a build gate (a
  binary that cannot print its catalog fails the build).
- App side: seat-binary resolution (`PBP:server/engine.mjs`'s
  `enginePaths().bots` path) gains a **bounded catalog probe** in
  `matchd`/`preround`: execute the resolved binary with `--print-catalog`
  once per build, under a short deadline (2 s, then SIGKILL — a legacy binary
  that ignores the flag enters its connect/retry loop and must be killed, not
  awaited), stdout/stderr capped (256 KB), requiring exactly one JSON
  document whose embedded catalog hash recomputes. The result is a
  per-binary **capability**: catalog-capable or not, cached by content hash.
- Capability gating: only catalog-capable builds participate in call
  generation and delivery. A non-capable build (today's `baseline`,
  `picasso`, `onepage` — `PBP:origin/maxwell/lobby-chat:server/engine.mjs:77-123`)
  gets **no call env at all** — its spawn environment is exactly what it is
  today (`matchd.mjs:400-412` already omits page env when no page) — and the
  phase records `source: fallback_unavailable` with a reason naming the
  binary. `{play:"default"}` is never delivered to a binary whose missing
  catalog is the evidence it doesn't speak this contract. The phase never
  stalls (the preround "never throws" discipline, `preround.mjs:286-287`).
- Tests: two builds receive their own catalogs (anti-skew), plus fake-binary
  fixtures for hang (deadline kill), oversized output, invalid JSON, bad
  hash, and legacy no-catalog behavior.

### 7.3 Mid-episode

`recordMidEpisodePage` gains its caller when the delivery lane is built; the
record shape (`{pos, slot, tick, page→call, source, reason}`) is already
right. Out of scope here beyond noting the shell hook (§4.6) it will call.

## 8. Determinism and validation

**Call events have one source of truth in a capture: the outbound wire.**
Every proposed call is an outbound `0x86` magic-prefixed frame, present in
wire captures (`STENCIL_WIRE_RECORD`, `LAB:stencil.nim:10-28`). The replay
side must *consume* them, which it does not today: `replay.nim` processes
inbound packets only (`LAB:replay.nim:47-56`), and `compare_stencil.py`
passes only `(wire path, slot)` (`LAB:tools/compare_stencil.py:81-107`).
Both are in scope (rev-1 finding 7):

- `replay.nim` learns the outbound call records: on encountering one after
  decision tick N, it feeds the same `acceptCallEvent(raw, requestTick)`
  transition the live path uses (§4.6) — a differing raw schedules the swap
  under the same `T_effect` rule from the replayed action-state windup; a
  reassertion is observed without scheduling or `init`, so a stateful play's
  state survives in replay exactly as it does live. Startup call included
  (it is on the wire at the playing edge). Capture-time env
  (`COWORLD_POLICY_PAGE*`) is thereby *not* a second source of call truth
  for replay; it remains part of capture identity only for process-start
  validation. Fixtures: a stateful-play reassertion whose state must not
  reset, and a negative control that incorrectly resets and must diverge.
- `compare_stencil.py` compares, in addition to mask+chat, the specialized
  Intent fields that parity gate 1 asserts (profile, micro, radii, combat) —
  mask-only parity can mask a lost flag (rev-1 finding 2's tail).

**Parity gates,** in order:
1. *Refactor parity (P1):* shell with plays compiled in, `default` play
   active, roles intact, CTF corpus → exact mask+chat+field parity with v69.
2. *Swap determinism (P3):* replay a capture containing mid-episode swaps
   twice → identical; **negative controls**: drop the call records →
   divergence; shift them one tick → divergence (the paired-negative-control
   discipline from `tests/test_policy_reflash.nim`, copied deliberately).
3. *Hosted round-trip (P3):* the `tools/roundtrip_reflash_match.sh` pattern
   against a `br-season2-complete` server with a stencil seat, gate on +
   gate-off control.

## 9. Prerequisites and sequencing

- **P0 — time the WorldMap build on a BR-scale map** before anything else
  (BR_LADDER §7 item 6, OPEN): 3211×1713 ≈ 6.9× CTF area, built in one tick
  (`LAB:policy.nim:39-50`, `LAB:worldmap.nim:173-209`). A first-frame stall
  here re-scopes P2.
- **P1 — the play seam on CTF, behavior-preserving**: the module graph of
  §4.1 (`play_contract`/`play_queries`/`play_registry`/`plays.nim` shell;
  compiling two-play feasibility proof + compile-negative fixtures), catalog
  mode, reflex observers/finalizer (`IntentShape` migration of `makeIntent`),
  `CombatPolicy` threading with empty-policy parity, the **CTF parity
  adapter** wired as `default`'s `gmCtf` dispatch (legacy ladder untouched in
  `strategy.nim`), the BR placeholder `survive_default`, swap machinery, env
  load, `replay.nim` + comparator extensions. Acceptance: parity gate 1. No
  BR dependency.
- **P2 — BR perception preconditions** (research report §7.2, all of it):
  16-wide `Team`, WorldMap without endzones, `zone`/`zonenext` percepts,
  partner tracking, lives-label fix; `seatsPerTeam` handled with BR_LADDER
  §5(a)'s caveat (the wrong 4 currently yields the right duo pairing;
  correcting it also moves `defenderCount`/`enemyLivesLeft`); squads disabled
  for BR (`SquadCommand=0`).
- **P3 — flash plumbing against the engine**: propose-at-edge, swap boundary,
  file-watch stand-in; parity gates 2–3. Also the **hosted call-injection
  lane P4's evaluations depend on** (they precede P5's LLM path): the fixed
  evaluation call is delivered as upload-time env — the platform already
  injects per-policy env at upload (`coworld upload-policy … --secret-env
  PLAYER_PROMPT=…` is the shipped paintball precedent,
  `docs/paintball/COMMANDING.md:84-90`) — deterministic, non-LLM, recorded
  on-wire at the playing edge like any startup call. The calls are the
  *registered* names only: P4b uploads with
  `--secret-env COWORLD_POLICY_PAGE='{"play":"default","params":{}}'` (BR
  mode dispatch selects the `survive` behavior — `survive` is not a wire
  name, §6.1); each P4c candidate uploads its named call, e.g.
  `'{"play":"zone_rotate","params":{"earliness":0.5,"route_bias":"cover"}}'`.
  The hosted round-trip gate asserts the accepted on-wire raw before an
  evaluation counts. Each P4 evaluation thereby holds the call fixed and
  varies exactly one play.
- **P4 — behavior-changing strategy work**, split so every hosted evaluation
  is attributable to one change (the lab's one-component-per-version rule,
  `personal_paintbot/AGENTS.md:60-70`); none of it is parity-gated:
  - *P4a — roles/posture.* Role deletion and its dynamic-posture replacement
    are **not executable from this document**: the replacement mechanism is
    the open design question the lab directive names
    (`LAB:WORKING_CONTEXT.md:135-154`) and gets its own approved design doc
    first. This document only sequences it (after P1's roles-intact parity
    anchor) and constrains it (acceptance is hosted A/B against the P1
    baseline, never byte parity). The `CombatPolicy` safety tests (§4.2)
    land with the first play that exercises them.
  - *P4b — the BR `survive` default* — one version, one evaluation.
  - *P4c… — one version and one evaluation per v1 play* (§6.2), in whatever
    order the BR corpus makes most informative.
- **P5 — app-side `call` step + catalog handshake** (needs Maxwell's repo;
  coordinate — `lobby-chat` branches off PBP main while BR branches share a
  different base, a known conflict cluster).

## 10. The outer loop (sketch, non-goal)

Plays are authored offline: harvest hosted episode logs + replay analyses +
forum discussion → propose/edit a play → property tests + self-play A/B →
version the playbook with the policy upload (the lab's existing ritual:
design → implement → evidence → `VERSION_LOG.md`). Tooling for the harvest
step is future work; nothing in the match path depends on it.

## 11. Risks and open questions

1. **Between-flash brittleness.** A mis-called play runs until re-called; the
   reflex layer bounds death-by-negligence but not strategic error. Mitigant:
   the default play is strong, and fallback calls always name it. Real
   exposure until the mid-episode lane exists (a bad pre-round call lasts the
   whole episode).
2. **Belief purity rests on the import boundary** (§4.1): plays can only
   reach Belief through `play_queries.nim`, so the risk concentrates in that
   module's exports — a query proc that mutates (the sweep-oscillator lesson,
   `LAB:TENTATIVE_LESSONS.md:20-26`) would be invisible to the import check.
   Review rule: `play_queries` exports are audited for mutation on every
   addition.
3. **`zone_escape` reflex threshold** (damage-imminent horizon) to be tuned in
   P3 against rim-hugging plays.
4. **WorldMap build cost** (P0) — could force incremental construction and
   re-scope P2.
5. **`CombatPolicy` scope creep.** Two sets today; pressure will come for
   priorities, truces-with-conditions, focus targets. Rule: it grows only
   with a play that needs it and a parity story for the empty value.
6. **Maxwell's response** to the divergences (§3.3) — may adjust naming or
   the parameter-entity rule's phrasing in the shared vocabulary.

## 12. Affected files (planning aid)

- New (acyclic ownership per §4.1): `LAB:paintbot/stencil_nim/play_contract.nim`
  (shared types incl. `PlayState` arms), `LAB:…/play_queries.nim` (`PlayView`
  with private Belief backing + the audited read API + `GameMode`),
  `LAB:…/plays/` (one module per play; import allowlist checked in the
  build), `LAB:…/play_registry.nim` (the `Playbook`), `LAB:…/plays.nim`
  (shell machinery: guards, reflexes + `ReflexState`, finalizer, swap incl.
  `acceptCallEvent`, the privileged CTF parity adapter (§6.1), catalog
  emission).
- Modified: `LAB:types.nim` (`CombatPolicy` on `Intent`; `IntentShape`),
  `LAB:strategy.nim` (`makeIntent` shape migration only — the legacy ladder
  body **stays in place** behind the CTF parity adapter through this design;
  it does not move into a default
  play; the shell's reflex observers and finalizer are new code in
  `plays.nim`, not extractions), `LAB:action.nim` (combat-policy
  filters in target/fire/spray/grenade paths; windup exposure for the swap
  boundary), `LAB:fight.nim` (candidate filter + protect weighting),
  `LAB:policy.nim` (decide station → reflex/play/finalizer; dead-tick stamp;
  roles block deleted in P4), `LAB:perception.nim` + `LAB:belief_*.nim`
  (BR percepts, 16 teams), `LAB:replay.nim` (outbound call-record
  consumption), `LAB:tools/compare_stencil.py` (field-level parity + call
  inputs), `LAB:tools/self_play.py` (call env passthrough),
  `LAB:tools/build_player.sh` (catalog build gate), `LAB:Dockerfile`
  (unchanged runtime; catalog printed at build).
- App (Maxwell's repo, coordinated): `PBP:server/preround.mjs` (`call` step +
  catalog injection), `PBP:server/matchd.mjs` or `engine.mjs`
  (catalog-by-execution + cache), CLI `lobby_chat` (subcommand), app tests
  (two-build anti-skew).
- Engine: none required. (Product-level rename page→play is Maxwell's call.)
