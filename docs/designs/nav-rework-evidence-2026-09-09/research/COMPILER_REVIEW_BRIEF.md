# Peer unit: production compiler and exact CPU targeting

Review a bounded compiler experiment before more algorithm changes. B0 used
Nim2.2.6 historically, CI pins2.2.10, Docker pins2.2.4. Inspect the real Docker
compiler flags and GCC primary docs for x86-64-v3 or SSE4.1 targeting with
-ffp-contract=off (no fast math). Could baseline floor/round conversion currently
pay scalar libm calls that the supported production CPUs can execute directly?
Do not assume a speedup: give a preregistered comparison and exactness checks.
Check observed m5a/c6a/m6i CPU flags and deployment constraints. No source edits,
no flags added to production, no benchmark concurrency. Write COMPILER_REVIEW.md.

Also correct ACCEPTANCE_MAP: GV_CLAIMS_BEFORE_L0.json contains a remoteGV63
claim (origin/maxwell/wire-over-identity);64is next free in that snapshot.
L1 fullnativecorpus andall65memory rows nowpass, samehash, pool16023601B,
colossal261919620B. Full activation ratios (map+index+mixednav)/map reach2.563
on pool48,2.420colossal; old activation harness includedindex/scratch/overlay/cache,
so don't silently exclude mixednav. Verify whether a later explicit ruling
superseded2x/3x before calling it definitively stillratified.
Keep failedL0/L1 experimental2000tick criterion. Do not invent human approval
requirements merely because m5a is slow: this task authorizes performance work;
fleet exclusion/new stale-cost policy would require a distinct decision.
