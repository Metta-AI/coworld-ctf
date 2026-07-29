#!/usr/bin/env bash
# ANTI-LINE GRENADE A/B (2026-07-29) — isolate the SHIPPED nadeCluster multikill.
#
# The lever: when a line is classified (ScLine) or heard (RpLine), a grenade carrier
# ranks candidates by CLUSTER SIZE (fresh enemies inside one 52px blast) and lobs at
# the FATTEST one — WITHOUT disarming (throw the nade, keep the gun). It has shipped
# ON since 4ceec16 (2026-07-22, the v17 lineage) and has NEVER been isolated. This
# script is the redirected budget from the retired arc-breacher A/B.
#
# ISOLATION SHAPE (the champion-MINUS-lever form, per isolate.sh):
#   candidate slots: SHIPBASE=1 CONTROL_SHIPPED=1 NADECLUSTER=0  (champion - cluster ranking)
#   control  slots:                CONTROL_SHIPPED=1              (full champion, lever ON)
# A NEGATIVE score for the minus-lever side on BOTH seatings => the lever earns its place.
#
# ⭐ TURTLE=1 IS REQUIRED FOR THE ANTI-LINE READ. The plain mirror never forms a line
# (both teams attack), so lineLive fires ~0 and the lever's whole premise is untested —
# exactly why this sat unvalidated. TURTLE=1 posts every control seat as a defender /
# overwatch spread, i.e. a STANDING LINE for the hunter to break: the local h006 proxy.
#
# ⭐ THE NULL MUST BE ~ZERO. A null needs BOTH SHIPBASE=1 AND CONTROL_SHIPPED=1 (champion
# vs champion, same seeds). CONTROL_SHIPPED alone is champion-vs-bare-baseline and fakes a
# large noise floor that inflates every effect size.
#
# Usage: players/baseline/eval/nadeab.sh [GAMES] [SEED] [MAXTICKS]
# Run from the repo root (the engine loads data/ sprite art relative to cwd).
set -uo pipefail
GAMES="${1:-16}"
SEED="${2:-100}"
TICKS="${3:-5000}"
H="players/baseline/eval/harness.out"

RED="0,2,4,6,8,10,12,14"
BLUE="1,3,5,7,9,11,13,15"

# Grep the lines that carry BOTH the verdict (SCORE / results) and the mechanism
# (clusterkil = per-blast multikills, kills/deaths = the attrition currency).
KEEP="SCORE:|results:|clusterkil|kills:|deaths:|K-D diff|grabs:|grab->cap"

run() { # $1=hunter slots  $2..=extra env assignments
  local slots="$1"; shift
  env HUNTER_SLOTS="$slots" SHIPBASE=1 CONTROL_SHIPPED=1 TURTLE=1 "$@" \
    "$H" --games "$GAMES" --seed "$SEED" 2>&1 | grep -E "$KEEP"
}

echo "######## ANTI-LINE A/B: champion MINUS nadeCluster, vs a STANDING LINE (TURTLE=1)"
echo "######## games=$GAMES seed=$SEED maxTicks=$TICKS"
echo ""
echo "=== ARM 1: minus-lever on RED seats (naive-nearest Red vs full-champion line) ==="
run "$RED" NADECLUSTER=0
echo ""
echo "=== ARM 2: minus-lever on BLUE seats (naive-nearest Blue vs full-champion line) ==="
run "$BLUE" NADECLUSTER=0
echo ""
echo "=== NULL RED: champion vs champion, lever ON both sides (the noise floor) ==="
run "$RED"
echo ""
echo "=== NULL BLUE: champion vs champion, lever ON both sides ==="
run "$BLUE"
echo ""
echo "######## READ:"
echo "########  Take the MINUS-LEVER side's SCORE (RED on arm 1, BLUE on arm 2) and"
echo "########  subtract the same seat's NULL score. NEGATIVE on BOTH seatings after"
echo "########  that null subtraction => stripping the cluster ranking HURTS => the"
echo "########  shipped lever earns its place. Cross-check 'clusterkil' — the ON side"
echo "########  should book MORE x2/x3+ blasts, which is the mechanism itself."
