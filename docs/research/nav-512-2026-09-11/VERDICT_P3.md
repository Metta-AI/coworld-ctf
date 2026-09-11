# H2 review and next research review

Root verified the clearance raster construction and supercover bounds. H2
certificate is sound for internal map-sized inputs. Native correctness and
performance are pending; do not claim acceptance. H2_CARD.md preregisters the
conditional candidate composition: H1+H2 if H1 passes, otherwise H2 only.

PROCEED P4, read-only: review root H3_PROPOSAL.md and P1_SAMPLING_PLAN.md.
Independently assess the best next small mechanism if H2 is insufficient,
including exactness and diagnostic tradeoffs. Verify whether the tiny heap
comparator pays Nim frame bookkeeping under the pinned production flags, and
whether a template is a reasonable explicit tradeoff rather than blanket
stacktrace removal. Consider alternatives already in your plan. No code edits,
no native use, no new timing, no commit. Write NEXT_REVIEW.md, end literal
PHASE 4 READY and wait. Root will supply native results before choosing.
