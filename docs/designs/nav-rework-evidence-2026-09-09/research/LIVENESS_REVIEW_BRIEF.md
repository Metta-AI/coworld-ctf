# Peer unit: liveness review, no implementation

Latency harness accepted as a failing diagnostic, root owns harness now.
Investigate whether preserving dangerGeneration when rebuilt packed weights
are exactly equal would be sufficient and correct for this stationary-threat
case. Trace every dynamic input consumed by resumable search (zone elapsed,
blocked cells, profile, targets, attachments) and what invalidates jobs.
Read relevant ratified design clauses. Separate what existing contract allows
from behavior changes needing a new decision; do not invent a human approval
gate for preserving identical inputs. Research existing dynamic-search/update
invalidation practice with primary sources before recommending a change.
Write LIVENESS_REVIEW.md with narrow candidate, tests required, limitations.
No source edits, no remote benchmarks, no commits. Root is independently
verifying latency on EC2 and finishing the memory qualification.
