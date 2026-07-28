## AUTO-GENERATED for -d:prePos (defensive pre-positioning, comms-018 consumer).
## Source: per-policy-version enemy-gathering mine, task 1216936850383184.
## Rivals mined: ctf-h050:v1 (invader; table derived from it) + beacon:v28
## (confirmed never on our half - the invader latch keeps this table unused
## against it). Corpus: 54 eps/rival, R1740-R1772 minus incident R1759-64,
## 108/108 hash-clean. Derivation + regeneration procedure:
## cogamer cogames/ctf/team/analysis/2026-07-28-prepos-heatmap/derive_lane_table.py
##
## PrePosLaneY[phase][lane] = lane-y an idle latched phalanx pair holds
## (phases: 0 opening <1400, 1 mid 1400-3400, 2 late >=3400 - the late table
## only governs the ownStolen/stale-fix posture, pushOut disables the phalanx
## branch otherwise). Order-preserved, min-gap 90px, shift-capped +-110px.
## y is side-symmetric (arena mirrors left-right only): no runtime mirroring.
## PrePosActive[0] is false: opening our-half cells failed the side-split
## stability check (noise), and the h050 invasion onset is ~gt1240 anyway.

const
  PrePosActive: array[3, bool] = [false, true, true]
  PrePosLaneY: array[3, array[3, float]] = [
    [66.0, 329.5, 593.0],   # opening: doctrine (inactive)
    [96.5, 338.7, 549.0],   # mid
    [96.3, 364.2, 540.0],   # late (ownStolen posture only)
  ]
