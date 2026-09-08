# Reflex plays: decision record — 2026-09-08

Evidence commit: `dbd80a3473fc876e028cde2557af0442a70ef6a4` (`origin/main`).
All repository `path:line` citations below refer to that commit. This is a
proposal for implementation after ratification; no reflex behavior changes here.
All ten rulings were ratified by James on 2026-09-08; rulings 6, 7 and 8 carry amendments recorded under their headings.

Source: [decision umbrella](https://app.asana.com/0/0/1218165831099140/f).
The September 4 correction (comment `1218197624790523`) supersedes the first
three scope comments; the name correction (`1218194513555826`) remains valid.
James's September 8 comments `1218286489475097` and `1218287229740002`
supersede overlapping open questions with rulings 1–4 below. Old references to
FIRST_LIGHT, epochs, the finisher, 1/2 init quotas, and GV52 are not current.

Motivation: the [hosted profiling report](https://app.asana.com/0/0/1218200078207627/f)
(comment `1218284916102556`, paintbot-profiling 0.1.1) reports native reflex
selection at about **1.1 ms per game tick**, with **~400 μs p50 per seat-step**
and 650–700 μs p95. These are reported hosted observations, not a worst-case
replacement budget or evidence that the proposed plays meet it.

## 1. RATIFIED — yield is an ABI-v2 step outcome

Return `1` means yield/withdraw: clear the entry's cached output immediately
and continue through controllers in priority order in the same tick. Return `0`
keeps today's semantics, including silence retaining cache; other nonzero returns
fault. ABI-v1 modules keep today's nonzero-is-fault behavior.

Reason: silence cannot release a cached escape intent. Today `invokeStep` faults
on every nonzero result (`src/shell/instance.nim:588`), and `stepEntry` retains
cache on silence (`src/shell/ladder.nim:603`). Change the ordinary runtime result
and ladder continuation contract, with no privileged reflex entry class.
The proposed finite stopping rule is in ruling 6; ABI mechanics are in ruling 7.

## 2. RATIFIED — hazard guards use existing body facts

The independent [hazard-guards task](https://app.asana.com/0/0/1218287237058955/f)
implements these shell-only paths; consume its landed contract:

| Path | Meaning |
|---|---|
| `world.grenade_threat` | A tracked airborne grenade covers self and has nonnegative ticks to blast. |
| `world.grenade_ticks_to_blast` | Minimum such deadline, or `-1` when absent. |
| `world.spray_threat` | A visible cone covers self, or at least two anonymous impacts remain within 48 ticks. |
| `world.spray_impact_count` | Count of those retained impacts. |
| `world.zone_ticks_until_outside` | Outside current rectangle: `0`; inside: ticks to next shrink; no schedule/CTF: `-1`. |

Grenade coverage is the server's circle-versus-body-box predicate at the plain
**52 px blast radius**, with **no +24 px margin**
(`src/ctf/sim_types.nim:1017`). The server supplies `coversSelf`
(`src/ctf/server.nim:3867`); native reflexes currently add the margin
(`src/shell/reflexes.nim:143`). A failed guard spends no guest step and contributes
no cached order (`src/shell/ladder.nim:616`, `src/shell/ladder.nim:699`).

Reason: idle escape entries should be cheap. The dependency extends
`playGuardContext` (`src/shell/episode.nim:584`) and its registry; this work must
not duplicate it, expand the one-page policy vocabulary, or weaken fog.

## 3. RATIFIED — policies author their own safety entries

No automatic harness injection. Starter policies include good escape plays in
the calls they build; external policies may omit or reorder them. Recommend
stable entry IDs in grenade, spray, zone, persona-controller order, with ordinary
policy-authored guards. Include this choice in each starter's pre-call, opening,
model re-call and maintenance paths; the generic harness must not silently add
entries. The 16-entry limit and ordinary call validation still apply.

Reason: composition belongs to the policy. The existing manifest catalog and
call builder are the integration seams (`policies/starters/common/plays.py:1`,
`policies/starters/common/starter_harness.py:698`). **PROPOSED scope detail:** keep
`policies/poc_llm_policy` as the independent low-level wire example, without
mandatory safety entries; starters are the recommended starting point
(`AGENTS.md:187`). Packaging tests must prove both starter inclusion and the
ability of another policy to omit/reorder, not test injection that was rejected.

## 4. RATIFIED — release the entire reflex namespace

Delete the `reflex_*` reservation entirely. `reflex_clear_grenade`,
`reflex_clear_spray`, and `reflex_zone_escape` become ordinary module names;
`reflex_grenade_escape` and `reflex_spray_escape` were scoping transcription errors.
Keep `default` reserved and retain ordinary identifier, binding and collision rules.

Reason: special names would preserve an unnecessary engine distinction.
Remove the prefix rejection and constant (`src/shell/manifest.nim:327`,
`src/shell/types.nim:511`) and correct the manifest/call schema descriptions
(`src/shell/schemas/manifest.schema.json:2`,
`src/shell/schemas/ladder_call.schema.json:15`).

## 5. RATIFIED (James, 2026-09-08) — behavior-level equivalence within two spatial calls

Ratified as recommended below.

Recommend preserving emergency triggers, release, deterministic choices and
policy priority, while allowing different destinations from Appendix R's
1,089-candidate search. Exact Appendix R requires absent route/cover/timing
queries and would keep substantial host machinery. The existing SDK offers
`nearest_reachable` and `nearest_cover` (`play_sdk/play.nim:416`), limited to two
calls per step (`src/shell/types.nim:419`). No new host query or dependency.

The established priority-fallback pattern is illustrated by
[BehaviorTree.CPP ReactiveFallback](https://behaviortree.github.io/BehaviorTree.CPP/dc/d04/class_b_t_1_1_reactive_fallback.html).
Reuse the current ladder: importing a C++ behavior-tree runtime would duplicate
its ordering, guest lifecycle and cache ownership without solving the ABI gap.

| Scoping difference | Recommended answer and consequence |
|---|---|
| Zone timeline reduction | **CURRENT:** retain outside→0 / inside→ticks-to-shrink, matching the guards dependency (`src/shell/episode.nim:990`). Keep 72-trigger/96-release hysteresis and next-rectangle progress; do not claim interpolated exclusion-time parity. Keep distance toward the next rectangle ahead of distance from self, preventing a far-zone self-hold (`src/shell/reflexes.nim:461`). |
| Grenade fallback comparison | **NORMATIVE comparison:** exact integer ratio ordering, using cross multiplication where denominators differ; plain 52 px for all coverage/scoring. Current scaling truncates (`src/shell/reflexes.nim:244`). Equal radii allow direct numerator comparison. Deadline-based aggregation is explicitly relaxed below because live speed is absent. |
| Multi-cone spray ordering | **CURRENT:** first serialized visible cone, otherwise retained-impact centroid (`src/shell/reflexes.nim:618`). Preserve the landed normalized order; no guest re-sort or invented attacker identity. Use engine `coversSelf` for triggering and the 48-tick window, not “48 px.” |
| Zero resolved candidates | **DELIBERATE FIX:** yield and clear cache; try the next controller within the step cap, then default. Current native no-goal returns no native base (`src/shell/reflexes.nim:701`); Appendix R's “standing order unchanged” is not the implementation. |
| Route distance | **CURRENT distance source:** straight-line, not a new route query. Production `reflexInput` never sets `routeDistance` (`src/shell/episode.nim:1004`); the planner's optional route lookup is dormant there (`src/shell/plan_escape.nim:150`). Do not present distance as a guaranteed arrival time. |
| Death/state reset | **DELIBERATE FIX:** retain ordinary instance adoption/retune/parking, but reference plays reset their own transient hysteresis on the first step or any nonconsecutive tick. This catches death/respawn without a new host lifecycle signal. It also resets after guard skips, preemption or cap starvation; this is an intentional observable difference. Current death clears standing/body state, not native active bits (`src/shell/episode.nim:1054`); ordinary guest caches clear on death while instances park (`src/shell/ladder.nim:625`). |

A bounded reference algorithm is part of this recommendation: grenade chooses
at most two literal escape targets in opposite directions along the self-to-
earliest-threatening-blast axis, 256 px from self (fixed +x axis at coincident
centers); resolve each with `nearest_reachable`. Score resolved points against
**all** triggering blasts: uncovered by all first, then greatest minimum
normalized body-box clearance, shortest straight-line distance, candidate order.
No predicted-arrival hard pass or arrival-filtered blast subset: live effective
velocity and motionScale are absent from the view, so a default-speed estimate
would lie for handicaps, carriers and custom configs. This is a deliberate
relaxation of Appendix R's deadline logic, not a claim of exact native fallback.

Spray asks `nearest_cover` with available fog-visible threats, then uses at most
one `nearest_reachable` query for a literal point away from the selected cone
axis or impact centroid; prefer a returned cover goal. Zone asks
`nearest_reachable` toward the nearest point inside the next rectangle, then
its center if needed; reject non-progressing results unless already safely
inside. Returned points, never unresolved literals, are scored and emitted.
Use stable integer ties and independent boundary/multi-hazard tests. These are
bounded heuristics; no two-query method promises to find every reachable escape.

Decode existing binary sections 9–12 with independent landed-byte fixtures
(`src/shell/binary_view.nim:475`), plus the existing zone/tick fields. Grenade
rows omit `coversSelf` (`src/shell/binary_view.nim:319`): the guest recomputes
the same plain-radius body-box predicate from the predicted blast center;
independent tests must match it to the server verdict. Add versioned
SDK constants for blast radius and body half-extent, asserted against the engine
(`src/ctf/sim_types.nim:1017`, `src/shell/body_map.nim:14`);
no new wire fields for radius, velocity or motionScale. Cover-query success is
sufficient; do not invent a cover-membership query. Blast cues and own throws
remain history/negative inputs, never escape triggers. Emit ordinary
`navigate_to`, arrival radius 8 and default motion; no unread reflex telemetry.

For zone, author the guard as `0 <= zone_ticks_until_outside <= 96`, not `<=72`:
it must permit an already-active play to finish its hysteresis band. After a
skipped tick the play recomputes activation at 72. Grenade/spray recompute from
current hazards on every actual step. Stable module identity and unchanged params
retain other instance state across call replacement (`src/shell/ladder.nim:370`);
new instances start clean.

## 6. RATIFIED (James, 2026-09-08) — retain three steps, with explicit exhaustion behavior

Ratified with one amendment. Guarding escape plays well, so that they neither consume
attempts nor yield out, is the policy's and playbook's responsibility, not the engine's.
Amendment: add tracing so the number of seats that fall through to the engine default
because their attempts ran out is visible on the existing `SHELL_*` once-a-second
diagnostic line (and a Fluffy marker if useful). No new metrics surface.

Keep `MaxStepsPerSeatPerTick = 3`, `MaxInitsPerSeatPerTick = 3`, and
`MaxInitsPerTick = 16` (`src/shell/types.nim:410`). The old 1/2 init proposal is
superseded. Retain round-robin initialization (`src/shell/ladder.nim:521`).
Count every actual step, including yields and faults; guard skips cost zero.

Preserve overlay-first stepping (`src/shell/ladder.nim:646`), then attempt
controllers in priority order. Stop before a fourth step. If no controller has
won when capacity ends, use the same-tick engine default with the active overlays;
do not select unstepped lower entries from stale cache. Retry normal priority
next tick, without rotation. Two overlays therefore leave one controller attempt;
three yielding escape controllers without overlays leave none for the persona.
This can repeatedly starve a lower controller: ratification accepts that tradeoff.
Guards do not eliminate the simultaneous-hazard case. Today's terminal assertion
is not a per-attempt limit (`src/shell/ladder.nim:719`); enforce the cap in selection.

**Measurement gate before releasing native removal:** on one production-equivalent
linux/amd64 CPU, pinned toolchain/container and release flags, compare current
native and replacement paths after the navigation dependency. Run 5 warmups and
30 measured repetitions per quiet/contention case; retain raw timings and commit,
CPU/OS, Nim/C compiler, Wasmtime/WASI versions and flags. Exercise 32 seats with
all three hazards, zero/one/two overlays, active winners, all-yield, faults, maximum
hazard rows, two spatial calls per attempted step, full fuel and cold init bursts.

Report per-tick p50/p95/p99/max for the complete runtime slice: guest init/step,
host queries and emit validation, ladder work and lazy view build/encode. Proposed
acceptance is **p99 ≤4.0 ms** in every case, with maxima reported and no quota
violations; the design assigns runtime 4.0 ms
(`docs/designs/strategy-play-calling-shell-2026-08-29.md:3381`). Also measure total
shell time and native reflex time separately, without double-counting nested
markers. A miss blocks removal and returns the budget decision to James; never
raise quotas silently. Use disposable probes and existing trace markers, not a
committed benchmark framework, RSS gate or new metrics. No measurement runs in
this docs-only task, and no passing result is claimed.

## 7. RATIFIED (James, 2026-09-08) — declare ABI 2 through the existing manifest field

Ratified with one amendment. **ABI v1 is deprecated as of this change and will not be
supported after the next ABI version (v3).** Do not write extensive back-compat shims.
The deprecation notice must appear where players see it when they upload policies and
plays (the upload/validation result for an `abi: 1` module and the SDK docs) and in many
noticeable places in the codebase (the `ShellAbiVersion` constant and its comment, the
manifest validator, `abi.nim`, the manifest schema comment, the design's ABI section), so
that v1 support is dropped when v3 is built.

A module declares `"abi": 2` in its `play_manifest` JSON. Accept exactly integer
1 or 2; reject missing, unsupported and malformed values. Preserve existing
import/export, memory, fuel and class validation. Do not merely change
`ShellAbiVersion` to 2: it is currently 1 and manifest parsing compares equality
(`src/shell/types.nim:389`, `src/shell/manifest.nim:324`).

Carry the validated ABI from the cached manifest to each instance and dispatch
step results by that value (`src/shell/module_cache.nim:39`). Mixed v1/v2 entries
may share a call. Upload manifest probing precedes step dispatch; module hashes
remain identity. Update the schema and SDK manifest helpers accordingly, with
no host import signature or binary-view layout change.

Recommend **yield plus any accepted emission faults as ambiguous**. A clean
controller yield clears both runtime and ladder accepted-output caches before
continuation. Overlay yield clears only that entry's overlay output; other
overlays still fold and controller priority is unchanged. Neither yield closes
the instance nor consumes an init slot. These details are proposals refining
ruling 1. Tests pin v1 nonzero fault and silent-cache behavior, mixed dispatch,
same-tick withdrawal, overlay folding, fault continuation and all-yield default.

## 8. RATIFIED AS AMENDED (James, 2026-09-08) — ordinary live provenance, no backward compatibility

**Amendment overriding the proposal below:** there is no backward compatibility. Old
replays that contain native reflex labels may break. Do not keep a legacy decode path, do
not add shims, and do not add back-compat tests. The proposal's archived-playback gate
and legacy-decoding preservation are withdrawn. Implementation note: because replays
recorded at GV59 before the change will no longer decode, the Replay & Viewer task makes
the break explicit by claiming the next GameVersion and re-recording the eight fixtures
(a version refusal rather than a decode error) unless James rules otherwise there. The
direct-input parity check below still applies.

Original proposal, for the record:

New executions use ordinary `pbEntry` provenance: entry ID, module hash and
accepted emission tick. Live accepted calls already write only `cikModule`
(`src/shell/ladder.nim:358`); native reflex evidence is `pbReflex`, not a live
`cikNative` call entry. Remove live native construction, preserving legacy
format-2 discriminants and decoding (`src/shell/replay_records.nim:389`,
`src/shell/replay_records.nim:478`). The viewer may still label legacy records.

Reason: deleting an execution path need not delete its historical codec.
Preserve byte goldens for native identities/reflex annotations. Separately,
initialize and step a real archived format-2 replay from a currently accepted
GameVersion through native and headless-WASM playback with recorded hashes.
Synthetic codec fixtures alone do not establish playback compatibility
(`tests/test_replay_compat.nim:110`). If no suitable archive exists, obtain one
from the unchanged accepted-version engine before deletion; do not rewrite a
header or recut a golden to manufacture compatibility.

At the evidence commit, `ReplayCompatibleGameVersions` is **[59]**, not [52] or
“GV50+” (`src/ctf/sim_types.nim:32`). Preserve decoding of legacy record payloads
without widening that replay allowlist. Re-pin the accepted version after nav lands.

Recommend **no GameVersion bump** for this composition change if deterministic
direct-input simulations preserve per-tick masks/gameHash, hash schema and wire
layouts, and the accepted archived playback gate passes. Compare identical
literal direct-input sequences on the pre-removal base and replacement. Plays
can choose different masks under ruling 5; replay executes recorded inputs.
If direct-input sim/hash or compatibility changes unexpectedly, stop and report
for a separate decision; do not change versions or fixtures in this task.

## 9. RATIFIED sequencing — guards first; implementation waits for navigation

The [guards task](https://app.asana.com/0/0/1218287237058955/f) lands first.
Reflex implementation waits for the
[navigation rework](https://app.asana.com/0/0/1218165906459726/f), because both touch
`ladder.nim` and `episode.nim` (native seam: `src/shell/episode.nim:1292`). Both
were In Progress at September 8 readback. The original
[hazard-feed dependency](https://app.asana.com/0/0/1218165930724417/f) is completed;
the server now fills the feed (`src/ctf/server.nim:3764`).

Reason: establish one current navigation/guard contract before removing the
native selector. After both land, refresh all citations and acceptance baselines;
do not carry this commit's source assumptions into the implementation unchanged.

## 10. RATIFIED (James, 2026-09-08) — exactly four Layer-owned implementation tasks

Ratified as recommended; filed 2026-09-08 as Asana tasks 1218293193121666 (Shell & Plays),
1218306338645470 (Bots & Policies), 1218304490341496 (Replay & Viewer) and
1218301431393211 (Docs & Comms) with the dependency edges below.

These are scopes to create **after ratification**, not Asana tasks created here.
Use Shell & Plays in place of the correction's old Sim & Rules ownership.
Dependency edges: guards + nav + ratification → Shell & Plays; Shell & Plays +
completed hazard-feed dependency → Bots & Policies; Shell & Plays + Bots &
Policies → Replay & Viewer; all three implementation tasks → Docs & Comms.

**Shell & Plays.** First pin v1/v2 outcomes, cache withdrawal, mixed-ABI calls,
namespace admission, overlay semantics and actual capped attempts with failing
regressions. Implement ABI/manifest/ladder contracts and remove native selection,
subscriptions, seat state, `nativeBase`, planner and unread telemetry
(`src/shell/episode.nim:557`, `src/shell/ladder.nim:654`). Preserve the default,
body/combat behavior and legacy codec hooks. Capture native reference evidence before deletion. This task can finish as a
local prerequisite; release of its native removal remains blocked until the
Bots-owned semantic/performance evidence passes on the combined work and
starter modules are available.

**Bots & Policies.** First pin independent SDK hazard decoding and policy-authored
starter calls, including omission/reordering and every call phase. Implement the
three reference modules, manifests and starter composition with bounded queries,
52 px fog-safe triggers, release, no-goal, multi-hazard, skipped-tick and
replacement/retune/death tests (`play_sdk/play.nim:416`,
`policies/starters/common/plays.py:273`). Own repeated replacement performance
measurements against Shell's captured native baseline, before releasing native removal. Do not add injection,
new host primitives, or engine planner copies.

**Replay & Viewer.** First pin legacy payloads and archived accepted-version
playback, plus new entry attribution (`src/shell/replay_records.nim:478`). Remove
live native presentation assumptions while keeping historical decoding/labels.
Prove direct-input/hash parity with Shell, then rebuild the viewer once from the
combined source and run native and headless-WASM replay gates. Keep existing
goldens; any unpredicted parity failure stops the change.

**Docs & Comms.** Once implementation is verified, correct current claims in
Season 2 section 7.3, pipeline, Appendix R/H, SHELL_DEMO, SDK and starter docs;
keep the hand-maintained design HTML twin consistent. The native opt-in claim
already disagrees with the fixed subscription array
(`docs/designs/strategy-play-calling-shell-2026-08-29.md:2251`,
`src/shell/episode.nim:557`). Replace it with implemented truth at that time.
Preserve dated reports/recon/coordination records and publish no new metrics or
board ceremony. Record validation and the exact ratified behavior changes.

The current umbrella subtasks are a checklist, not dependency edges. This
record advances subtask 1's decisions and proposes subtask 2's split; it completes
none of the implementation gates. Subtasks 3–13 and 15 are deferred to those
owners. Subtask 14's broad prose/twin updates wait for implementation. This
change is Markdown plus one AGENTS pointer only: no source, tests, SDK, policy,
tools, GameVersion, fixtures, viewer rebuild, Asana mutations or remote publication.
