# H2 proposal: reuse clearance to certify short legal segments

Status: proposed, no code or timing yet. Parent6b6b3408, independent of H1.
Existing segmentClear scans every supercover pixel and side pixel with
canStand. BodyMap already stores a Chebyshev distance-to-wall/boundary field
in bytes, built by buildClearance. For span=max(abs(dx),abs(dy)), if clearance
at start > PlayerHalf+span, every visited pixel is standable. Return true in
that case, retaining the existing scan otherwise. Saturation255 only prevents
some fast-path hits; it cannot make an unsafe segment pass. Boundaries are zero
neighbors in buildClearance. No new array, cache, dependency or changed unit.
This applies particularly to the common4px A* neighbors in open space and may
also help connectors. Shared-heap H1 remains independent and can be ablated.

Prior art is the clearance-bounded ray skip already ported in PR544. This is
its application to the planner's larger-body supercover legality predicate,
not a replacement of supercover with the visual ray predicate. Verify against
an independent original function on boundary, narrow corridor, corner, reverse,
saturated-clearance and generated obstacle cases; end-to-end plan fingerprints
and work counts must match at each suspension point. Root can implement H2
while peer implements H1, in isolated trees, if peer agrees.
