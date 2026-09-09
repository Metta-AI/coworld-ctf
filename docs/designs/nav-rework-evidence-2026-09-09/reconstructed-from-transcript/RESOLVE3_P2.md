RESOLVE3 P2: scope the coverage proof to navigable components; do not represent unreachable islands.

Facts that decide it. `validateGoal` (body_map.nim) resolves a requested goal ONLY inside the requester's own pixel component, and BodyMap builds validator tables ONLY for components that contain a spawn point (`buildValidatorTables(spawnPoints)`). A cog starts in a spawn component and cannot leave it (pixel components are exactly the walkable-connected regions). Therefore a pixel component with no spawn point can never contain a cog, a ValidatedGoal, or a route endpoint. Components 2 (72 px) and 3 (7 px) on br-gen-20184 are such islands.

Ruling:
1. The exhaustive coverage proof applies to every standable pixel of every VALIDATOR component (a component with a validator table). For those components the existing rule stands unchanged: a <=32 px exact connector to an anchored node (coarse cell, or a fine pocket point already in the index), and graph connectivity iff pixel-component equality.
2. Standable pixels in non-validator components are counted and reported per map (columns: unreachable_components, unreachable_px) and are NOT an activation failure. No fine-only component representation is added; do not extend BodyPocketConnector for them.
3. Activation asserts, for each validator component, that at least one anchored coarse cell exists and that the spawn points' cells are anchored; failure names map and component.
4. Phase 3 endpoint attach must assert `goal.goalComponent` has a validator table and fail typed (brfGoalAttach) otherwise; this cannot happen for a real ValidatedGoal, so it is a guard, not a path.
5. If a VALIDATOR component still has pixels with no connector under the fixed caps, that remains a real failure and stops the phase as before.

Do not raise the 32 px / 256-pop caps. Commit the scoping as its own checkpoint, rerun the full qualification (64 published + arena + colossal), and finish Phase 2 as planned with the per-map rows. End with the literal line PHASE 2 DONE.
