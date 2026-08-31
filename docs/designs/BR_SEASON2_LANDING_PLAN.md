# Season 2 landing plan — br-season2-complete → main (P0 deliverable, DRAFT for Maxwell + James)

Answers the play-calling shell's P0 ask: which branches merge, in what
order, and which GameVersion numbers this work claims. Drafted 2026-08-30
against `maxwell/br-season2-complete` @ `0f0858af` (313 commits ahead of
main) and main @ `c226faf4` (GV47).

## The version gap, stated plainly

The BR lineage forked at **GV45**; main has since moved to **GV47**
(damage-credit stats rule). So this is a true reconciliation merge, not a
fast-forward, and the merged engine must prove it did not disturb either
lineage: **the merge criterion is that every archived gate-off fixture
re-simulates bit-identically post-merge.** All branch behavior is
config-gated dark (brMode, 16-team rosters, allowPolicyReflash default
off, glory ledger OUT of gameHash on inc2), so a fixture break in the
merge is a real conflict to resolve — never a re-record.

## Wave 1 — one integration base lands dark

Pre-landing folds INTO `br-season2-complete` (it already subsumes
restack-assembly, glory-inc1+inc2, reflash-integration, onepage-runner):

1. ~~`maxwell/br-onepage-vm`~~ **ADOPTED, not merged** (done, wave-1):
   the branch turned out to ride the unlanded **GloryVersion-10 broadcast
   lineage** (123 commits since common ancestor). The VM-only delta (14
   files: policy_page.nim, its tests, tools/flash/) was adopted from
   `br-onepage-vm-guard` @ b6beacd8 with test_policy_page wired into
   shard_2. See "The third lineage" below.
2. `maxwell/br-manifest` — the BR coworld manifest ✅ folded
3. `maxwell/br-team-outline`, `maxwell/br-lives-hud` — viewer/HUD ✅ folded
4. `maxwell/br-ladder-design` — docs only (BR_LADDER.md) ✅ folded

Then **one merge: season2-complete → main — with NO GameVersion bump.**
Corrected 2026-08-30 after reading the codec: `bitworld/replays.nim:370`
strict-equality-gates on `gameVersion` exactly as :363 does on
`formatVersion`, so ANY GV bump orphans every archived replay at load,
regardless of behavior. A dark landing therefore stays at GV47; version
bumps are reserved for actual behavior changes (which carry re-records
by construction). Landing dark first is what makes every later phase
reviewable against main instead of against a 313-commit stack.

Probe results (2026-08-30): merging main = 30 commits, 17 conflicts —
~10 source files (the GV46/47 damage-credit stats work vs our gated
additions), shard-import unions, and 6 BINARY fixture conflicts (both
lineages re-recorded). Fixture resolution rule: MAIN's fixtures win
(the merged engine's gate-off behavior must equal GV47 by the darkness
criterion, and the fixtures are its proof); BR-gated fixtures
(br-golden-16team) re-record on the merged engine if broken — that is a
gated-fixture refresh, not an archived-replay re-record. Pre-merge BR
demo recordings (rt_episode/*) are EXPECTED to stop re-simulating after
the merge (main's stats rule is mode-independent); they are demo
artifacts and get re-recorded post-merge.

## The third lineage (discovered during wave-1 folds)

**The GloryVersion-10 broadcast lineage is NOT on main and NOT in this
base** — rank-up pops, the Season 2 cheat sheet, and the v10 fixture
re-records (`237fdef8`, tip of what `br-onepage-vm` forked from). It
carries **hashed glory** and its own re-recorded fixtures, while this
lineage's glory-inc2 keeps the ledger OUT of gameHash. Reconciling the
two glory semantics is real work of glory-increment-3 shape, not a fold.
Plan: land it as **its own wave after GV49** (or merge INTO the inc3
work if the semantics converge there), owner TBD with Maxwell. Until
then the cheat sheet + broadcast HUD ship only from that lineage's
branches.

## Wave 2 — the two changes that touch gameHash, in this order

1. **Glory increment 3** (level-scaling + ledger INTO gameHash): claims
   **GV48** and the ONE planned 7-fixture re-record. Sequenced first and
   alone so the re-record happens exactly once, on the merged lineage.
   (Re-records are a dice roll — nothing else batches with this.)
2. **Play-calling P2's Season 2 gate** (call-hash + epoch mixing into
   gameHash under `season2Shell`): claims **GV49** — the shell's first
   live version — ONLY if P2 changes gate-off behavior; otherwise no
   bump, same rule as wave 1. Note for P2: the codec gates BOTH
   `formatVersion` (:363) and `gameVersion` (:370) with strict equality
   in the vendored bitworld package, so "old replays keep loading"
   requires dual-read on both axes (or no bump), and the dual-read lands
   either in the shared bitworld package or as a coworld-ctf load
   override — an open design point for James.

## The replay format bump (P2, coordinated)

`CtfReplayFormatVersion` 1 → 2: the call record as its own record type
(module hashes + seat epoch), the non-hashed Intent annotation array, the
manifest, the playbook archive. The codec today checks strict equality —
the v2 decoder must accept v1 and only write v2, or every archived replay
dies. The **page→play-call rename rides this same change** (one decoder
touch, not two): `PolicyPageMagic` retires; `recordPolicyPage` /
`isPolicyPageRecord` / `decodePolicyPageRecord` / `policyPageRecordPlayer`
/ `policyPageHash` / `applyPolicyPage` / `MaxPolicyPageBytes` /
`allowPolicyReflash` rename to play-call vocabulary; `tools/flash/`
(SCHEMA.md, prompt.md, playbook/) and `verify_reflash_roundtrip` follow.
`COWORLD_POLICY_PAGE_FILE` stays local-runner-only and dies with the
legacy runner path.

## Standing hazards the schedule must respect

- **The >16-viewer sim wedge** (`dedupObjectPlacements`) blocks anyone
  verifying at 32-seat scale — it gates the shell's containment and
  end-to-end acceptance (gates 3-4), not just our episodes. The pixel-pipe
  lane is therefore on the shell's critical path.
- Gate 4 builds on the verified episode shape in `rt_episode/` — the
  roundtrip verifier + glory dump + honest-roster tooling land in wave 1
  and become the template.

## Hosted pre-round huddle (separate workstream, owner TBD)

Recommendation to bring to the platform conversation: **platform
orchestrator owns it** (early container start, transport, transcript,
start barrier); the engine contributes only a named lobby-phase barrier.
Grounds: artifact provenance and container lifecycle are platform facts;
the engine's only chat is in-match by construction (`applyShout` refuses
outside Playing — a separation worth keeping structural); and the lobby
owning coordination is the standing product law. The local match app's
`lobby-chat` phase remains the reference experience.
