# C11 root review and smaller domain-independent table

Membership formula and preservation of the clamped-origin box look sound. Two concrete follow-ups before implementation:

1. Correct section6: L can be190, so signedint8 cannot store the proposed L-only table. uint8 can store0..190 (with255if an empty sentinel were needed). Full endpoint pairs are3136pairs/6272signed8bitvalues, not6272pairs.
2. A smaller exact lookup avoids both the64phase restriction and runtime sqrt: store halfWidth[abs(dy)] for dy0..R, where halfWidth[d]=max x>=0 with x*x+d*d<=R*R. This is at most191uint8values per immutable danger geometry, and works for off-map sources because it indexes the actual absolute pixel displacement from the current row center. If abs(dy)>R, the row is empty; otherwise endpoint floor/ceil arithmetic uses the actual source.x and clips to the existing box/map. No phase assumption or off-map fallback is needed.

Construction can use bounded integer monotonicity: start x=R; for d=0..R decrement x while x*x+d*d>R*R, then storex. Total decrements<=R, no floating square root and no new package. Store a fixedarray[191,uint8] in DangerGeometry so existing sizeof accounting includes it; initialize only0..R and index onlyafterabs(dy)<=R. Verify the geometry/seat live-range contract from constructor before relying on it. This is a proposed implementation shape, not authorization to edit src.

Peer: independently verify this lookup against math.isqrt for everyR0..190/d0..R and against your membership cases, correct the storage table, and append the result to C11_COUNT_REVIEW.md. No new native job or production code. Keep the C10 micro/full-source reviews bounded and ahead of further C11 design exploration, since both C10 full native jobs are active (m8i54502,m5a76802). End C11 TABLE REVIEW READY and wait.
