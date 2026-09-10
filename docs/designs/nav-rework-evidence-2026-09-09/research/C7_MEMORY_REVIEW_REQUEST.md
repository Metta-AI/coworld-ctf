# C7 next memory review: retain64slots if current caps permit

C7v2native m8i runnerPID42102 is active; no speed result yet. Root accepted A7 review and local four-arm exactness is running in the new root-owned nav-early-visited tree; leave it untouched.

PROCEED documents-only: reconsider the assumed32-slot production proposal against current integrated C2+V1 memory ledgers (C2-integrated-activation-mac.json and C2-integrated-configured-mac.json). We should retain the existing64-slot LRU if it fits the user-authorized64MiB non-colossal shared cap and unchanged256MiB total/colossal cap. The list payload64*54173*8=27,736,576B; current max noncolossal shared32,464,268 minus856,608cache plus27,736,576 is59,344,236B before small metadata. Current colossal total229,158,347 includes331px cache58,912 and geometry422,444; even conservatively replacing it with1300px list payload and adding kernel expansion appears below268,435,456. Verify exact arithmetic and all76row substitutions, distinguish proposals from measured final ledger, and account for slot lengths, seq/ref owners, allocation allowances and geometry growth. Do not use obsoletepreV1 totals.

A64-slot design avoids the measured32-slot hit loss and may be the direct reason to use the additional memory authorization. Recommend64or32from current evidence. No cap/source changes until native micro and subsequent full trace/memory tests justify integration. Write C7_MEMORY_REVIEW.md plus reproducible calculation; end C7 MEMORY REVIEW READY and wait.

Native micro is now complete and passes: C7_NATIVE_MICRO_REPORT.md and C7-m8i-summary.json. Use this when recommending the next isolated full-source-cache phase; do not implement until the concrete review is frozen.
