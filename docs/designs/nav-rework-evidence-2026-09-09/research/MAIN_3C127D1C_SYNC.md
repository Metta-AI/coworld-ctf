# Main sync after P1

P1 commit09ae4721 was created after fetch exposed a new main commit but before syncing it: the command batch failed to stop on behind=1. Corrected immediately by merging3c127d1c before further source work. Future fetch/state inspection and mutation must be separate tool steps or explicitly assert behind=0.

Main adds the realized-economy/deed broadcast fields and a flatty keyframe field. Its refreshed ninefixtures and captureclaims are used as incoming-main artifacts; they are not navigation qualification. The source merge preserves the nav changelog and all incoming state fields. Main spendsGV63, origin/maxwell/glory-s8-ship claims64, so navigation is renumbered65. This is an unfinished research branch: the handoff requires all nine fixtures at the final selected pop budget; that final recording remains pending, and current incoming fixtures still carry63. Do not report fixture or final gate success. Old experiment evidence stays tied to its savedsource snapshots and hashes.

Rebuild/check viewer for mergedsource and run both server compile shapes plus focused navigation tests. No publish or productionwrite. This local merge is not a shipping milestone.
