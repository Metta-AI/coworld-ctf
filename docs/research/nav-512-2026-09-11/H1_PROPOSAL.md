# H1 proposal: reduce fixed-heap writes

Status: proposed to peer, not yet accepted or measured.
Mechanism: replace repeated HeapNode swaps plus two position-map writes at each
sift level with the standard held-node/hole approach: move one child/parent per
level and write the held node once at its final position. Keep binary arity,
nodeLess, left/right tie decisions, allocation sizes, generation, and external
operations unchanged. Both route A* and field minter use this FixedHeap.

Prior art inspected locally: Nim2.2.6 lib/pure/collections/heapqueue.nim,
siftup and siftdown. It holds the displaced item and shifts along the path.
Do not replace our indexed heap with HeapQueue: its find() is linear and it
has no fixed-capacity indexed decrease-key contract. Adapt the established
sifting pattern in the existing heap; no new dependency or abstraction.

Expected benefit: fewer large-node stores and position-generation writes,
principally minter but also A*. No route/work-count/heap-layout differences
are intended. Use a snapshot of current code as differential oracle, including
complete heap/positions after each randomized operation and navigation job
fingerprints at suspension boundaries. Preserve the existing fixed memory.

Root proposes peer implements H1 in its own tree after joint agreement, while
root prepares native A/A and paired acceptance work. Start with focused tests
and same-budget native diagnostic before candidate512 vs baseline256. Exact
threshold/card will be finalized before any candidate timings.
