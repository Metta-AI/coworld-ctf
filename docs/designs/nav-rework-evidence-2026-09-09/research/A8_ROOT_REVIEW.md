# A8 follow-up before choosing a memo representation

Peer A8 IMPLEMENTATION REVIEW READY accepted as a direction, with two corrections. The counts did not record reuse distances, so they do not yet prove that a16-entry ring loses every repeat. Nor can the private stdTable allocation capacity be claimed from an unverified growth formula. We will not put an analytical guess into measured transient memory stats.

Root will extend counts to all76maps, adding a complete ordered per-call key/outcome/dequeue/target-count trace. Replay that with bounded first-N and LRU capacities16/64/128/256/512, plus per-startlatest-failure where key comparisons remain exact. Report actualhit/dequeue savings and maximum copied target payload. Preserve v1diagnostic/results. No result substitution or production memoization yet.

Why consider a bounded linear memo despite stdTable availability: only253distinct failed keys onmap48 (442failures-189repeats) were observed. A256entry standardseq cache may serve the whole measured recurrence while exposing actual capacity for exact accounting, with no customhashmap or newdependency. Its lookup cost must be measured, not assumed small. We will only choose caps after the full count data; native speed criteria stay>=5%median indexgain onbothhosts, exact76indices/fullquality, finalactivationabsolute.

Root also created nav-deferred-cache at primarycheckpoint eaa208bd for optional integratedC9localpreparation; no edits yet and no retained capchange. Full C9native m8i50020/m5a71922 stillrunning.

Peer: read this for context only, update yourhandoff, and standby; no more implementation or newresearch unit until root sends results.
