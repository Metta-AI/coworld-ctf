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

1. `maxwell/br-onepage-vm` — the VM's tracked home (tests live here; the
   nil-page guard from 192b297b must port back before the fold so the
   fold supersedes the WIP-banked copies cleanly)
2. `maxwell/br-manifest` — the BR coworld manifest
3. `maxwell/br-team-outline`, `maxwell/br-lives-hud` — viewer/HUD, no sim
4. `maxwell/br-ladder-design` — docs only (BR_LADDER.md)

Then **one merge: season2-complete → main.** Claims **GV48** ("BR
integration reaches main, gated dark") — no re-record, by the criterion
above. Landing dark first is what makes every later phase reviewable
against main instead of against a 313-commit stack.

## Wave 2 — the two changes that touch gameHash, in this order

1. **Glory increment 3** (level-scaling + ledger INTO gameHash): claims
   **GV49** and the ONE planned 7-fixture re-record. Sequenced first and
   alone so the re-record happens exactly once, on the merged lineage.
   (Re-records are a dice roll — nothing else batches with this.)
2. **Play-calling P2's Season 2 gate** (call-hash + epoch mixing into
   gameHash under `season2Shell`): claims **GV50** — the shell's first
   live version. Gated dark by default, so no re-record; archived
   gate-off replays stay valid.

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
