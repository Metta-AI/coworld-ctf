# Documentation audit — park archive

Scope: the approved archive-only merge. The runtime rework remains unqualified
and is preserved as a patch; no production code or authoritative runtime
contract is changed by this merge. Historical design/contract changes from
the research branch are inside implementation.patch, not applied to main.

Added a current entry point at docs/designs/nav-research-park-2026-09-10.md
and a parked banner in the evidence README. The park README links Claude's
handoff, the ledger, scoreboard, acceptance map, C10 outcome and C11 proposal.
It states the incomplete gates, cap permission versus retained cap, provisional
budget, route-hash distinction and exact restoration commands.

Verification: reconstructed every non-evidence tracked blob and mode in the
primary and seven side bases using temporary Git indexes. All seven dirty
patches also apply. verify_restore.py and tracked-files.json make those checks
repeatable without the historical research commit objects. Staged paths are
restricted to docs/designs plus one .dockerignore exclusion for the large
archive; runtime, SDK, tests, game configuration and viewer changes are absent. No GameVersion bump or viewer rebuild applies to this
archive-only merge. No coworld/softmax CLI is used.

Historical raw logs, disassembly, frozen source and patches retain their
original whitespace to preserve provenance and hashes. A full diff --check
reports historical whitespace, including patch context and captured terminal
output; it is not described as clean. Newly authored park prose and the
restore verifier are checked separately. No existing qualification failure
is waived or converted into a passing result.

The original checkout's unrelated in-progress merge and divergent local main
are preserved. Submission uses an isolated clone with main at fetched
origin/main, rather than rewriting the shared local main branch.

Final collection: C10 m8i passes, m5a fails the registered randomized-trace total limit; both strict quality checks pass. Both evaluators reproduce their saved JSON exactly. All four owned research instances read back stopped. The final handoff and scoreboard explicitly close C10 as rejected for adoption.

Packaging audit: Dockerfile copies the build context into its build stage. The evidence directory is excluded through .dockerignore so archived raw traces do not inflate that context. No production source or build script refers to this evidence directory. The final image already copies only selected binaries, JSON and data.

Independent-review follow-up: large raw JSON files are gzip-compressed without byte changes, with original digests and explicit expansion instructions. Side historical heads are provenance-only. Current operations records use host labels; frozen historical identifiers are deliberately preserved as non-secret provenance. The complete source patches remain byte-identical and the verifier still passes.
