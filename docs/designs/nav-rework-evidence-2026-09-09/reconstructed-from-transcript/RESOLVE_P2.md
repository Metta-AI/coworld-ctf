RESOLVE P2: the sparse 4 px micro-corridor contingency is AUTHORIZED, with the negative-int32 encoding you proposed (value >= 0 coarse nav cell; value < 0 decodes to fine 4 px grid index -1 - value). Rationale: the design brief pre-authorizes exactly this when the proof fails; your diagnostic shows a local 4 px crossing exists in 8 steps inside the 32 px box while the 8 px graph needs a 96-step detour, so this is a representation gap, not a cap problem.

Binding constraints:
1. Fine points appear ONLY inside crossing segments (and, if the pixel-coverage proof later needs it, in pocket connectors). Rooms, portal fields, and ordinary intra-room segments stay 8 px.
2. Crossing search order per choke: (a) direct legal 8 px move, (b) bounded 8 px search in the +-4-cell box / 64 pops, (c) bounded 4 px lattice search in the same 32 px box with a fixed pop cap (256; assert, never map-derived). Every step of a fine crossing is validated at build with the exact pixel `segmentClear`; the stored crossing is a point sequence the follower walks like any leg.
3. Danger, blocked-cell and hazard sampling for a fine point use its containing 8 px nav cell. Static length uses the true Q4 pixel distance between consecutive points.
4. Qualification rows gain columns: fine_crossings, fine_points, and the retained bytes they add. A map whose choke still cannot be crossed at 4 px within the box fails activation by map and choke, as now.
5. Keep the 32,767 edge-ID assert; fine points do not create new edges, only cells inside the crossing segment.
6. The coverage proof is unchanged: every standable pixel needs a <=32 px exact connector to an anchored coarse cell of the same pixel component, and anchored-cell graph connectivity must equal pixel-component equality. If pockets still fail after the crossing fix, apply the same fine-point mechanism to those pocket connectors and report them in the same columns.

Commit the index in the planned order (index, then contingency + proof). Then finish Phase 2 as planned: all 64 published maps + arena + colossal rows, retained/transient bytes, build vs BodyMap time. End with the literal line PHASE 2 DONE.
