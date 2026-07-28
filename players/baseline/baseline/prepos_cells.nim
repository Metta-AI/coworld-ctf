## AUTO-GENERATED for -d:prePos (defensive pre-positioning, comms-018 consumer).
## PLACEHOLDER — regenerated from the per-policy-version enemy-gathering mine
## before any build is judged. Provenance and derivation script:
## cogamer cogames/ctf/team/analysis/2026-07-28-prepos-heatmap/.
##
## PrePosLaneY[phase][lane] = the y the idle phalanx pair of that lane holds
## once the opponent is latched an invader (phases: 0 opening <1400,
## 1 mid 1400-3400, 2 late >=3400, elapsed from Playing start). Values are
## derived OFFLINE from mined our-half enemy dwell with: per-pair shift cap,
## order preserved (top < mid < bottom) and a minimum 90px gap between
## adjusted lanes so stations never stack. y is side-symmetric (the arena is
## mirrored left-right only), so no runtime mirroring is needed.
## PrePosActive[phase] = false when the mine shows no our-half signal above
## the noise floor for that phase (pairs then hold doctrine lanes).

const
  PrePosActive: array[3, bool] = [false, false, false]
  PrePosLaneY: array[3, array[3, float]] = [
    [66.0, 329.5, 593.0],   # opening: doctrine lanes (placeholder)
    [66.0, 329.5, 593.0],   # mid:     doctrine lanes (placeholder)
    [66.0, 329.5, 593.0],   # late:    doctrine lanes (placeholder)
  ]
