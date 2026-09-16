"""GLORY GRADIENT S6 — catalog-aware fold math, shared by census_decode.py and
attribution_decompose.py.

The pre-S6 (v2) pipeline folds every `glory_deed`/`achievement` wire
`amount` as a flat WHOLE-INTEGER class factor (`product *= amt`, seed 1, cap
2**24, win factor a flat x8). Catalog v3 (GLORYVERSION 17 / GameVersion 62,
the `battle-royale-s2` flagship variant, all five S6 switches armed:
`catalogV3Reprice`, `gloryFixedPointScale`, `placementRampV3`,
`deedMintCaps`, `winAsMultiplier`) changed what `amount` MEANS: it is now a
PERCENT-SCALED factor (100 = neutral no-op, 160 = x1.60 ...), folded via
`glory.nim`'s `recutFoldPct` against a product seeded at a fixed-point scale
(`GlorySCALE`), gated by a state-dependent floor guard ("GATE RULING 2":
skip folding any `pct < 200` while the unscaled accumulator sits <= 64), and
stripped once at read-out (`recutScoreScaled`).

Every function here is a direct, line-for-line port of `src/ctf/glory.nim`
(cited per function below) and `src/ctf/sim.nim`'s `awardDeed`/
`claimAchievement`/`checkWinCondition` call sites -- verified against real
GV62 wire data (see `tools/glory/test_catalog_fold.py`): the wire `amount`
field for a v3-armed deed/achievement IS ALREADY the fully-folded percent
value (class x heat x carry x stack, or the achievement tier's own percent,
computed engine-side) -- this module never re-derives class/heat/carry/stack
itself for the RECONCILIATION path; it only replays the FOLD STATE MACHINE
(seed, order, floor guard, cap, halving, win factor) against that
already-computed per-event value. `attribution_decompose.py` is the one
consumer that also needs the sub-factor breakdown, and reads it from the
wire event's `content` field (instrumented extractor) with its own
heat-ordering correction -- see that script's own module docstring.
"""
from __future__ import annotations

import functools
import json
import re
import subprocess
from dataclasses import dataclass

# ── ERA KEYING (read this before touching any constant below) ───────────
#
# THIS MODULE IS A LIVE PORT OF `src/ctf/glory.nim`, AND IT IS ALSO A
# BACKWARD DECODER. Those two jobs conflict the moment a ship MOVES a
# constant: HEAD's value decodes HEAD's cohort and silently mis-decodes
# every older one.
#
# That is not hypothetical. GLORY GRADIENT S8 (#538, sha 1b92ec46) moved
# `RecutProductCapArmed` 2**24 -> 2**31 and the placement ramp
# 100/100/130 -> 115/130/160, and repointed the two literals here in the
# same edit. From that commit until this one, re-folding the GV62 (S6)
# cohort reconciled 5,302/5,456 instead of 5,456/5,456: the 154 rows the
# S6-era engine had actually SATURATED at the old ceiling (16,384
# reported) no longer saturated under the new one, so the S6 gate --
# "the harness must reproduce S6 exactly (154 capped, top-decile CHOSEN
# 72.26%)" -- could not be run from main at all.
#
# THE RULE, therefore: every constant a ship moves is ERA-KEYED here, in
# the SAME PR as the ship. Add the new value as its own `_S<n>` literal,
# add the boundary to `GLORY_VERSION_BY_BUILD`, and leave the old literal
# in place forever -- a cohort recorded under it still has to decode.
#
# The era of a row is DERIVED, never typed by the caller:
#   * AUTHORITATIVE: `GloryVersion*` read straight out of
#     `src/ctf/glory.nim` at the exact commit that build was compiled from
#     (`read_glory_version`, a local `git show` -- the same observation
#     mechanism `read_manifest_switches` already uses for the switches).
#     `catalog_detect.py` writes it into the catalog map, so
#     `census_decode.py --catalog auto` gets it per episode.
#   * DERIVED, no extra input: the episode's OWN `coworld_version` (every
#     episode record the tools read carries one) against the era-boundary
#     table below (`glory_version_for_build`). This is what the explicit
#     `--catalog v2|v3` paths use, so the S6 gate needs no new flag.
#   * ESCAPE HATCH ONLY: an explicit `--glory-version N`.

GLORY_VERSION_S6 = 17
# GLORYVERSION 17 = GameVersion 62, the S6 catalog-v3 ship (#504+).

GLORY_VERSION_S8 = 18
# GLORYVERSION 18 = the S8 ship (#538, sha 1b92ec46, build tag
# paintbot-v0.7.397): ceiling 2^21 reported, PLACEMENT LADDER B, S4b armed.

CURRENT_GLORY_VERSION = GLORY_VERSION_S8
# Mirrors `docs/wiki/_era.md`'s **GLORYVERSION** field (and
# `policies/starters/common/era.py`'s `GLORY_VERSION`), which mirrors
# `src/ctf/glory.nim`'s `GloryVersion*`. `test_catalog_fold.py`'s era
# tripwire asserts all three agree, so a GLORYVERSION bump that forgets to
# era-key a moved constant fails a test instead of silently breaking the
# backward decode.

GLORY_VERSION_BY_BUILD = (
    ((0, 0, 0), 13),
    ((0, 7, 342), 14),
    ((0, 7, 361), 15),
    ((0, 7, 369), 16),
    ((0, 7, 377), 17),
    ((0, 7, 397), 18),
)
# build tag -> GLORYVERSION, ordered ASCENDING: a `coworld_version` resolves
# to the LAST row whose build tag is <= it.
#
# EVERY ROW IS OBSERVED, none guessed: each is the first build at which
# `git show <build>:src/ctf/glory.nim` declares that `GloryVersion*`. The
# 14/15/16 boundaries were read from the GV61 cohort's own
# `version_to_sha.json` round shas; 17 and 18 from the `paintbot-v*` git
# tags. `read_glory_version` is the same read, and `catalog_detect.py`
# flags any disagreement between the two.
#
# The first row is open-ended at 13 because that is the oldest build any
# measured cohort reaches (0.7.327, where `RecutProductCapArmed` was still
# 2^26); older than that, `deedMintCaps` is dark and `CatalogSwitches.cap`
# returns `RECUT_PRODUCT_CAP_DARK` regardless of this table.

GLORY_VERSION_RE = re.compile(r"^\s*GloryVersion\*\s*=\s*(\d+)", re.M)
# `src/ctf/glory.nim`'s own `GloryVersion* = 18` declaration.


def parse_build_version(coworld_version: str):
    """`"0.7.383"` -> `(0, 7, 383)`; tolerates a `paintbot-v` prefix and a
    trailing suffix. Returns `None` for anything unparseable (the caller
    decides whether that is fatal -- it never silently picks an era)."""
    if not coworld_version:
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", str(coworld_version))
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


def glory_version_for_build(coworld_version: str) -> int:
    """GLORYVERSION for an episode's own `coworld_version` build tag.

    Raises rather than guessing on an unparseable tag: an era this module
    cannot resolve must fail the run, not silently decode at HEAD's era --
    the exact failure mode #538 shipped."""
    parsed = parse_build_version(coworld_version)
    if parsed is None:
        raise ValueError(
            f"cannot derive GLORYVERSION from coworld_version "
            f"{coworld_version!r} (expected a MAJOR.MINOR.PATCH build tag); "
            f"pass an explicit glory_version instead of guessing")
    return _era_lookup(GLORY_VERSION_BY_BUILD, parsed)


def _era_lookup(table, key):
    """Last row in an ascending `((key, value), ...)` table whose key is
    <= `key`. The one lookup every era-keyed constant below shares."""
    value = table[0][1]
    for boundary, candidate in table:
        if key >= boundary:
            value = candidate
        else:
            break
    return value


# ── glory.nim constants (verbatim) ──────────────────────────────────────

GLORY_SCALE = 1024
# glory.nim `GlorySCALE* : int64 = 1024`

RECUT_PRODUCT_CAP_DARK = 1 << 62
# glory.nim `RecutProductCap* = int64(1) shl 62` -- never moved by a ship.

RECUT_PRODUCT_CAP_ARMED_V13 = 1 << 26
# glory.nim `RecutProductCapArmed* = int64(1) shl 26` (67,108,864) as
# `deedMintCaps` first shipped it, GLORYVERSION 13 (build 0.7.327).

RECUT_PRODUCT_CAP_ARMED_S6 = 1 << 24
# glory.nim `RecutProductCapArmed* = int64(1) shl 24` from GLORYVERSION 14
# ("CAP 2^26 -> 2^24, ruled 25:1x" -- glory.nim's own v14 changelog) through
# GLORYVERSION 17 (16,777,216 internal, 16,384 = 2^14 reported at
# GLORY_SCALE=1024). KEEP THIS: the GV62 cohort's 154 capped rows only
# decode against it.

RECUT_PRODUCT_CAP_ARMED_S8 = 1 << 31
# glory.nim `RecutProductCapArmed* = int64(1) shl 31` from GLORYVERSION 18
# (2,147,483,648 internal, 2,097,152 = 2^21 reported). GLORY GRADIENT S8
# (#538, CAP-CEILING-S7.md, S2 lead ruling).

RECUT_PRODUCT_CAP_ARMED_BY_ERA = (
    (0, RECUT_PRODUCT_CAP_ARMED_V13),
    (14, RECUT_PRODUCT_CAP_ARMED_S6),
    (GLORY_VERSION_S8, RECUT_PRODUCT_CAP_ARMED_S8),
)
# Every row read out of `src/ctf/glory.nim` at a build that shipped it --
# see the sweep recorded in this PR's body. ADD A ROW when a ship moves the
# constant; never edit one.


def recut_product_cap_armed(glory_version: int) -> int:
    """glory.nim `RecutProductCapArmed*` AS OF `glory_version`."""
    return _era_lookup(RECUT_PRODUCT_CAP_ARMED_BY_ERA, glory_version)


RECUT_PRODUCT_CAP_ARMED = recut_product_cap_armed(CURRENT_GLORY_VERSION)
# HEAD ALIAS ONLY -- the value the LIVE engine uses today. Correct for
# "what will the sim do next round"; WRONG for decoding any cohort older
# than `CURRENT_GLORY_VERSION`. Anything that folds recorded wire data must
# go through `recut_product_cap_armed(era)` / `CatalogSwitches.cap`.

RECUT_MIN_ACCUM_FOR_SMALL_PCT = 64
# glory.nim `RecutMinAccumulatorForSmallPct* = 64` -- GATE RULING 2.

RECUT_WIN_FACTOR_BR = 4
RECUT_WIN_FACTOR_BR_SOLO = 8
# glory.nim `RecutWinFactorBR*`/`RecutWinFactorBRSolo*`.

# glory.nim `DeedDramaTable`: paysHeat(deed) = deed != dAchievement and
# DeedDramaTable[deed] > 0. dVictory pays heat classically but is retired
# under `winAsMultiplier` (never mints), so it is listed for completeness,
# not because it appears on an armed-cohort wire.
HEAT_PAYING_DEEDS = frozenset({
    "dFirstBlood", "dHonorableKill", "dSprayKill", "dGrenadeKill",
    "dPointBlankKill", "dLongshotKill", "dSplashMultiKill", "dRevengeKill",
    "dRunDown", "dAceTag", "dFlagSteal", "dCapture", "dCarrierKill",
    "dDenial", "dEscortKill", "dAssist", "dRescue", "dWipe", "dDuoDown",
    "dVictory",
})

# glory.nim `RecutPlacementRampDeeds* = {dFinal8, dFinal4, dFinal2}`.
PLACEMENT_RAMP_DEEDS = frozenset({"dFinal8", "dFinal4", "dFinal2"})

# The placement ramp's CONTINUOUS companion -- the one priced weapon on the
# armed v3 wire that is not a member of glory.nim's `GloryDeed` enum at all,
# which is why it is absent from `RECUT_CLASS_TABLE` below by construction
# rather than by oversight, and why it never appeared in the 31-deed
# catalog. Catalogued here so the catalog is complete.
#
# SEMANTICS, matching the sim exactly (`recutMintSurvivalCredit`,
# sim.nim:8128-8158): every `RecutSurvivalCreditIntervalTicks` boundary an
# ALIVE seat's `aliveTicks` crosses -- 720 ticks, 30 s at the engine's 24
# ticks/s -- it folds `RecutSurvivalCreditPct` (102 = x1.02) into
# `gloryProduct[team]` through the SAME `recutFoldPct` fixed-point path
# every other v3 price uses, compounding, and emits a raw
# `emitEvent(GloryDeed, weapon="survivalCredit", amount=102,
# content="GLORY_SURVIVAL_CREDIT")` that BYPASSES `awardDeed` -- so it
# carries no `shiftedClass|heat|carry|stack` sub-factor tuple, unlike every
# deed that does route through `awardDeed`. Gated on placementRampV3 +
# gloryMultiplierRecut + winAsMultiplier + brMode (all armed live).
#
# THIS IS A RECORD OF THE PRICE, NOT A NEW FOLD INPUT. Because the wire
# `amount` already IS that percent, `fold_events_v3` has always priced
# `survivalCredit` correctly with no table entry (it carries its own
# contribution -- the exact opposite of `achModeLit` below, whose bonus was
# ALREADY embedded in its paired achievement event and so had to be excluded
# from the fold). Nothing on the reconciliation path reads the names below;
# adding them changes no reconciled number.
#
# ATTRIBUTION CLASS -- HANDED (`PLACEMENT_BASE`), a CONSIDERED call, not an
# artifact of the weapon name; do not "fix" it to CONSTANT. Survival credit
# is not paid to every seat equally the way the CONSTANT floor is: it is
# paid in proportion to how long you last, and in a 16-solo battle royale
# "how long you lasted" IS "where you finished", measured continuously. It
# is the placement ladder's continuous twin -- which is why bundling it with
# `dFinal8`/`dFinal4`/`dFinal2` in attribution_decompose.py's
# `V3_PLACEMENT_WEAPONS` (and routing it to `PLACEMENT_BASE` there and in
# cap_sweep.py) is correct.
CONTINUOUS_CREDIT_WEAPONS = frozenset({"survivalCredit"})

# sim.nim emits these `GloryDeed`-kind wire events OUTSIDE the
# awardDeed/claimAchievement fold entirely -- pure informational markers,
# never folded into `gloryProduct` (see sim.nim ~L357/380 `capHit`,
# ~L3184/3194 `pactWipe`/`pactDuoDown`). `dTeamKill` is handled separately
# (it feeds the FF-halving divisor, never a multiplicative fold).
#
# GLORY GRADIENT S8/GV63 FIX (found live: `achievementLightableModes` is
# armed on this era's flagship manifest for the first time, so `achModeLit`
# finally appears on real wire data, not just in source) -- `achModeLit` is
# ALSO a pure marker, not a second independent fold: sim.nim `claimAchievement`
# (~L640-649) computes `bonus`, folds it into `gloryProduct` via
# `recutFoldObserved` ONCE, THEN sets `amount = amount * bonus` (the tier's
# own percent times the whole-integer bonus) BEFORE emitting the paired
# `achievement`-kind event's own `emitEvent` call a few lines later (~L677) --
# so the bonus's multiplicative effect is already fully embedded in that
# achievement event's `amount`. An earlier version of this module treated
# `achModeLit` as an independent WHOLE-INTEGER fold (`WHOLE_INTEGER_MARKUP_
# WEAPONS`, now removed) causing a real, empirically-confirmed 2x
# reconciliation miss whenever the S4b bonus fires (GV18/GameVersion 63
# live cohort, r4828-4833: 3/1440 seat-episodes off by exactly recon/reported
# = 2.0, all three carrying an `achModeLit` mint -- see
# docs/designs/glory/CENSUS-GV18.md). Folding BOTH the marker (x bonus) and
# the achievement event (x pct*bonus, already including bonus) double-counts
# the bonus leg. Excluding `achModeLit` from the fold entirely (same
# treatment as `capHit`/`pactWipe`/`pactDuoDown`) fixes it: only the paired
# achievement event's already-bonus-inclusive `amount` folds.
NON_FOLD_MARKER_WEAPONS = frozenset({
    "capHit", "pactWipe", "pactDuoDown", "achModeLit",
})

# Kept (now empty) so `fold_events_v3`'s `weapon in WHOLE_INTEGER_MARKUP_
# WEAPONS` branch and its two other callers (attribution_decompose.py,
# cap_sweep.py) keep compiling; every former member (`achModeLit`) is now
# filtered out upstream via `NON_FOLD_MARKER_WEAPONS` before reaching this
# check at all three call sites, so this branch is currently unreachable
# dead code, not a live path -- left in place as a documented extension
# point for a FUTURE whole-integer-under-v3 weapon, should one ever exist.
WHOLE_INTEGER_MARKUP_WEAPONS = frozenset()


# ── v3 pricing tables (glory.nim, verbatim -- attribution_decompose.py's
#    sub-factor decomposition only; census_decode.py's reconciliation never
#    needs these, since the wire `amount` already IS the folded value) ────

# glory.nim `RecutClassTableV3Pct*`: `RecutClassTable[deed] * 100`, with the
# named overrides from `reprice_v3.py`'s `NEW_BASE_CLASS`.
RECUT_CLASS_TABLE = {
    "dNone": 1, "dFirstBlood": 2, "dHonorableKill": 1, "dSprayKill": 1,
    "dGrenadeKill": 1, "dPointBlankKill": 1, "dLongshotKill": 3,
    "dSplashMultiKill": 3, "dRevengeKill": 2, "dRunDown": 2, "dAceTag": 4,
    "dTeamKill": 1, "dFlagSteal": 4, "dCapture": 8, "dCarrierKill": 4,
    "dDenial": 6, "dEscortKill": 2, "dAssist": 2, "dRescue": 2,
    "dClutchHeal": 1, "dShieldSoak": 1, "dWipe": 8, "dLevelUp": 1,
    "dAchievement": 1, "dDuoDown": 2, "dClosingTime": 2, "dLastLight": 4,
    "dVictory": 8, "dTagBack": 2, "dJointAct": 2, "dFinal8": 2,
    "dFinal4": 3, "dFinal2": 4,
}
RECUT_CLASS_TABLE_V3_PCT_OVERRIDES = {
    "dHonorableKill": 220, "dShieldSoak": 160, "dClutchHeal": 180,
    "dPointBlankKill": 250, "dFirstBlood": 400, "dLongshotKill": 600,
    "dSplashMultiKill": 600, "dRevengeKill": 400, "dRunDown": 400,
    "dAceTag": 900, "dLastLight": 800, "dClosingTime": 110,
}
RECUT_CLASS_TABLE_V3_PCT = {
    deed: RECUT_CLASS_TABLE_V3_PCT_OVERRIDES.get(deed, base * 100)
    for deed, base in RECUT_CLASS_TABLE.items()
}
RECUT_CLOSING_TIME_WIN_BUMP_V3_PCT = 120

# glory.nim `RecutPlacementRampPct*` (dFinal8/dFinal4/dFinal2 only) -- the
# SECOND live-ported constant #538 (1b92ec46) moved, era-keyed for the same
# reason the cap is: `attribution_decompose.py`/`cap_sweep.py` read it as
# each placement mint's BASE price, so folding a GV62 row against LADDER B
# mis-splits that mint's PLACEMENT_BASE/TERRITORY legs.
RECUT_PLACEMENT_RAMP_PCT_S6 = {"dFinal8": 100, "dFinal4": 100, "dFinal2": 130}
# S5/S6 ladder, live through GLORYVERSION 17.
RECUT_PLACEMENT_RAMP_PCT_S8 = {"dFinal8": 115, "dFinal4": 130, "dFinal2": 160}
# GLORY GRADIENT S8 PLACEMENT LADDER B (owner decision, 2026-09-10,
# CAP-CEILING-S7.md §Placement), live from GLORYVERSION 18.

RECUT_PLACEMENT_RAMP_PCT_BY_ERA = (
    (0, RECUT_PLACEMENT_RAMP_PCT_S6),
    (GLORY_VERSION_S8, RECUT_PLACEMENT_RAMP_PCT_S8),
)
# Open-ended first row: this table is only ever READ while `placementRampV3`
# is armed, which first happened at GLORYVERSION 17 (the S6 ship) -- below
# that the ramp deeds priced off the frozen x2/x3/x4 class ladder and this
# constant is unreachable.


def recut_placement_ramp_pct(glory_version: int) -> dict:
    """glory.nim `RecutPlacementRampPct*` AS OF `glory_version`."""
    return _era_lookup(RECUT_PLACEMENT_RAMP_PCT_BY_ERA, glory_version)


RECUT_PLACEMENT_RAMP_PCT = recut_placement_ramp_pct(CURRENT_GLORY_VERSION)
# HEAD ALIAS ONLY -- same caveat as `RECUT_PRODUCT_CAP_ARMED` above.

# glory.nim `RecutSurvivalCreditPct*` / `RecutSurvivalCreditIntervalTicks*`
# (3134 / 3128): the placement ramp's continuous companion price, x1.02 per
# 720 alive ticks (30 s at 24 ticks/s), compounding. See
# `CONTINUOUS_CREDIT_WEAPONS` above for the full semantics and the HANDED
# classification. Recorded, not read by the fold: the wire `amount` already
# carries this percent.
#
# NOMINAL vs REALIZED -- do not quote the nominal as the effect. Nominal is
# x1.02**n. REALIZED, measured on the live GV18/GameVersion-63 cohort
# (r4828-r4833, 90 episodes / 1,440 seat-episodes, counterfactual: each
# seat's product refolded WITH vs WITHOUT its own survivalCredit events):
# mean x1.0002, median x1.0000, p90 x1.0000, max x1.0612; only 1/1440 seats
# (0.07%) realize as much as x1.05. Score deciles D1-D9 realize EXACTLY
# x1.0000; only D10 moves, and its mean is x1.0017.
#
# WHY, and it is not rounding: `recutFoldPct` SKIPS any factor in
# 100 < pct < 200 outright while the unscaled accumulator sits at or below
# `RecutMinAccumulatorForSmallPct` = 64 (GATE RULING 2 -- glory.nim:3025,
# 3074-3075; `recut_fold_pct` below is the port), so a pct=102 credit is
# IDENTICALLY ZERO until a seat has already climbed past ~64 on real deeds
# -- the dependency sim.nim:8134-8143 names in its own doc comment. 482 of
# the 492 firing seats in that cohort had every one of their folds skipped.
# The other half of the gap is a units error worth naming: the ~8
# firings/EPISODE figure is the total across all 16 seats, so the typical
# seat draws 0.50 firings and the busiest seat in the cohort drew 5 --
# 1.02**8.49 was never a per-seat quantity.
RECUT_SURVIVAL_CREDIT_PCT = 102
RECUT_SURVIVAL_CREDIT_INTERVAL_TICKS = 720
# NOT era-keyed, and that is a positive claim, not an omission: both
# constants have held a single value since `placementRampV3` first armed
# them (GLORYVERSION 17), and #538 did not move either -- see the era
# tripwire in test_catalog_fold.py, which reads glory.nim's HEAD values and
# fails if that stops being true. If a future ship DOES move one, era-key it
# here in the same PR (the checklist line in tools/glory/README.md).

HEAT_LADDER_V3_PCT = (100, 500, 1400, 3600)  # rung 0..3
RECUT_STACK_LADDER_V3_PCT = (100, 500, 750, 1250, 2000, 3250)  # k=1..6+
CARRIER_HOLD_MULT_PCT = 200

# `dJointAct` era-split boundary (CATALOG-V3-DRAFT.md, lead ruling): pact
# formation became the hardest choice on the board starting round r4517 --
# post-boundary firings are CHOSEN (`JOINTACT_CHOSEN`), pre-boundary rows
# stay CONSTANT (`RECIPE_BASE`, unchanged bucket).
JOINTACT_ERA_SPLIT_ROUND = 4517


# ── catalog switches ─────────────────────────────────────────────────────

@dataclass(frozen=True)
class CatalogSwitches:
    gloryMultiplierRecut: bool = True
    winAsMultiplier: bool = True
    deedMintCaps: bool = True
    placementRampV3: bool = False
    gloryFixedPointScale: bool = False
    catalogV3Reprice: bool = False
    brMode: bool = True
    gloryVersion: int = CURRENT_GLORY_VERSION
    #: The era this switch set describes -- the ONLY thing that selects
    #: between two shipped values of the same glory.nim constant. Defaults
    #: to HEAD's era so "what does the sim do next round" keeps working;
    #: every decode of RECORDED data must set it from the episode (see
    #: `for_episode`) rather than take this default.

    @property
    def label(self) -> str:
        """v3 iff EITHER of the two switches that change a deed's wire
        `amount` from a whole-integer factor to a percent are armed
        (`catalogV3Reprice` reprices every non-ramped deed + achievement;
        `placementRampV3` reprices dFinal8/dFinal4/dFinal2 alone) -- see
        sim.nim `awardDeed`'s own `ramped or v3` branch selection."""
        return "v3" if (self.catalogV3Reprice or self.placementRampV3) else "v2"

    @property
    def scale(self) -> int:
        return GLORY_SCALE if self.gloryFixedPointScale else 1

    @property
    def cap(self) -> int:
        """`RecutProductCapArmed` AS OF THIS ROW'S ERA -- not HEAD's."""
        return (recut_product_cap_armed(self.gloryVersion)
                if self.deedMintCaps else RECUT_PRODUCT_CAP_DARK)

    @property
    def placement_ramp_pct(self) -> dict:
        """`RecutPlacementRampPct` AS OF THIS ROW'S ERA -- not HEAD's."""
        return recut_placement_ramp_pct(self.gloryVersion)

    def for_era(self, glory_version: int) -> "CatalogSwitches":
        """Same switches, re-keyed to `glory_version`."""
        if glory_version == self.gloryVersion:
            return self
        return CatalogSwitches(
            gloryMultiplierRecut=self.gloryMultiplierRecut,
            winAsMultiplier=self.winAsMultiplier,
            deedMintCaps=self.deedMintCaps,
            placementRampV3=self.placementRampV3,
            gloryFixedPointScale=self.gloryFixedPointScale,
            catalogV3Reprice=self.catalogV3Reprice,
            brMode=self.brMode,
            gloryVersion=glory_version,
        )

    def for_episode(self, ep) -> "CatalogSwitches":
        """Same switches, re-keyed to the era THIS EPISODE was recorded in,
        derived from its own `coworld_version` field (raises if that field
        is missing or unparseable -- never silently falls back to HEAD)."""
        return self.for_era(glory_version_for_build(ep.get("coworld_version")))


# The two catalogs actually measured to date (GLORYVERSION-observed, not
# guessed -- see tools/glory/catalog_detect.py for the per-commit manifest
# read that confirms these). GV61 census/README already reconciles 100%
# with deedMintCaps + winAsMultiplier armed and placementRampV3/
# gloryFixedPointScale/catalogV3Reprice all dark; GV62 (S6 SHIP, PR #504+)
# arms all five.
#
# NOTE the era on these two module-level singletons is HEAD's. They are
# switch-set TEMPLATES, not decode-ready catalogs: call `.for_episode(ep)`
# (or `.for_era(n)`) before folding recorded data. `census_decode.py` and
# `attribution_decompose.py` both do.
CATALOG_V2 = CatalogSwitches()
CATALOG_V3 = CatalogSwitches(placementRampV3=True, gloryFixedPointScale=True,
                              catalogV3Reprice=True)


def catalog_for(label: str, glory_version: int = CURRENT_GLORY_VERSION) -> CatalogSwitches:
    """`("v3", 17)` -> the S6-era v3 catalog. The one place a `"v2"`/`"v3"`
    label plus an era becomes a decode-ready `CatalogSwitches`."""
    if label not in ("v2", "v3"):
        raise ValueError(f"unknown catalog label {label!r} (expected 'v2'/'v3')")
    template = CATALOG_V3 if label == "v3" else CATALOG_V2
    return template.for_era(glory_version)


# ── fold primitives (glory.nim `recutFold`/`recutFoldPct`/`recutScore`/
#    `recutScoreScaled`/`recutWinFactor`, verbatim) ──────────────────────

def recut_fold(product: int, factor: int, cap: int) -> int:
    """glory.nim `func recutFold*(product, factor, capsArmed)`."""
    if factor <= 1:
        return product
    if product >= cap // factor:
        return cap
    return product * factor


def recut_fold_pct(product: int, pct: int, cap: int, scale: int) -> int:
    """glory.nim `func recutFoldPct*(product, pct, capsArmed, scale)`.
    `pct <= 100` is a true no-op (100 = identity; the placement ramp's
    crushed dFinal8/dFinal4 mints price exactly here). GATE RULING 2: a
    factor `100 < pct < 200` is skipped (not applied-then-truncated) while
    the UNSCALED accumulator (`product` if dark, `product / scale` if
    `gloryFixedPointScale` is armed) sits at or below 64."""
    if pct <= 100:
        return product
    if pct < 200 and product < RECUT_MIN_ACCUM_FOR_SMALL_PCT * scale:
        return product
    if product >= cap // pct:
        return cap
    return (product * pct) // 100


def recut_score(product: int, halvings: int) -> int:
    """glory.nim `func recutScore*(product, halvings)`."""
    if halvings <= 0:
        return product
    if halvings >= 63:
        return 0
    return product // (1 << halvings)


def recut_score_scaled(product: int, halvings: int, scale: int) -> int:
    """glory.nim `func recutScoreScaled*(product, halvings, scale)` -- halve
    FIRST, strip `scale` SECOND (the S5 halving-order invariant)."""
    return recut_score(product, halvings) // scale


def recut_win_factor(br_mode: bool, winner_seats: int) -> int:
    """glory.nim `func recutWinFactor*(brMode, winnerSeats)`."""
    if not br_mode:
        return 1
    return RECUT_WIN_FACTOR_BR_SOLO if winner_seats <= 1 else RECUT_WIN_FACTOR_BR


def deed_rates(total: int, n_episodes: int, n_seat_episodes: int):
    """Both mint rates for one deed, ALWAYS returned as a pair: (per
    EPISODE, per SEAT-EPISODE). Every census table prints both, side by
    side, and none of them may print only one.

    A per-EPISODE rate pools all 16 seats, so it is ~16x the rate any ONE
    seat sees. Quoting it as though it were a per-seat quantity is exactly
    the error that published `survivalCredit` as "roughly x1.16 over a
    typical episode": 8.49 mints/episode is 0.50 mints/SEAT-episode, and
    compounding x1.02 8.49 times describes a seat that never existed (the
    busiest seat in the live GV18 cohort drew 5 credits, and the realized
    per-seat multiplier is x1.0002 -- see `CONTINUOUS_CREDIT_WEAPONS`).
    Pinned by `test_catalog_fold.py`'s `test_deed_rates_reports_both`.
    """
    return (total / n_episodes if n_episodes else 0.0,
            total / n_seat_episodes if n_seat_episodes else 0.0)


# ── the whole per-seat-episode fold, v2 and v3 ──────────────────────────

def fold_events_v2(events, cap: int = RECUT_PRODUCT_CAP_ARMED_S6):
    """Byte-identical to `census_decode.py`'s original (pre-S6) inline fold:
    seed 1, `product *= amt` for every `amt > 1`, no floor guard, no scale.
    `events` is an iterable of (weapon, amt) for ONE seat's glory_deed/
    achievement wire events (dTeamKill already filtered out by the caller).
    The default `cap` is the S6-ERA ceiling, not HEAD's: the v2 catalog only
    ever ran under GLORYVERSION <= 17, so no v2 row can have been folded
    against the S8 ceiling.
    Kept here only so a caller can share one code path; census_decode.py's
    own v2 branch is untouched and does NOT call this (regression safety:
    zero risk of this refactor changing GV61/GV15 output)."""
    product = 1
    for weapon, amt in events:
        if amt and amt > 1:
            product = recut_fold(product, amt, cap)
    return product


def fold_events_v3(events, catalog: CatalogSwitches = CATALOG_V3):
    """Replays the v3 fold state machine over ONE seat's (weapon, amt)
    events (chronological order, dTeamKill/marker weapons already filtered
    by the caller). Every non-excluded event's wire `amt` IS the
    already-computed percent (or, for the rare dark-achModeLit case, whole
    integer) value -- see module docstring."""
    product = catalog.scale if catalog.gloryFixedPointScale else 1
    cap = catalog.cap
    for weapon, amt in events:
        if not amt:
            continue
        if weapon in WHOLE_INTEGER_MARKUP_WEAPONS:
            product = recut_fold(product, amt, cap)
        else:
            product = recut_fold_pct(product, amt, cap, catalog.scale)
    return product


def backsolve_heat_pct_v3(class_pct: int, carry_pct: int, stack_pct: int,
                           amt: int, pays_heat: bool):
    """`attribution_decompose.py`'s only consumer: the private instrumented
    extractor stashes `heatPct` in the wire event's `content` field by
    reading `sim.heatEmbers[team]` AFTER this same deed's own ember bump
    (sim.nim `awardDeed` L556 runs BEFORE the debug block at L577-594, but
    AFTER the real fold at L515-521 already read the PRE-bump value) --
    verified against real GV62 data (round r4611, episode 84d65205, slot 2:
    `dHonorableKill` content `220|500|100|100` but wire `amount=220`, which
    only reproduces at heat=100%/rung0, not the stashed 500%; the very next
    event, `dFirstBlood` `amount=2120`, only reproduces at heat=500%, not
    its own stashed 1400%. Both are consistent with "stashed value = this
    deed's OWN post-bump embers", i.e. one rung ahead of what the real fold
    used). `classPct`/`carryPct`/`stackPct` are NOT affected (embers is the
    only bumped-during-the-call state the debug block reads) -- back-solve
    the real (PRE-bump) heat rung from the four canonical `HeatLadderV3Pct`
    candidates against the one reliable ground truth, the wire `amount`
    itself, instead of trusting the stashed value.

    Returns the correct `HeatLadderV3Pct` percent, or `None` if no
    candidate reproduces `amt` (a genuine, reportable residual -- the
    caller counts these into `UNRESOLVED` rather than guessing).
    """
    candidates = HEAT_LADDER_V3_PCT if pays_heat else (100,)
    for h in candidates:
        num = class_pct * h * carry_pct * stack_pct
        den = 100 * 100 * 100 * 100
        predicted = (num * 100) // den
        if predicted == amt:
            return h
    return None


def score_from_product(product: int, halvings: int, catalog: CatalogSwitches) -> int:
    if catalog.gloryFixedPointScale:
        return recut_score_scaled(product, halvings, catalog.scale)
    return recut_score(product, halvings)


# ── manifest-driven catalog detection (DO item 1) ───────────────────────

FLAGSHIP_VARIANT_ID = "battle-royale-s2"
GLORY_NIM_PATH = "src/ctf/glory.nim"
SWITCH_KEYS = (
    "gloryMultiplierRecut", "winAsMultiplier", "deedMintCaps",
    "placementRampV3", "gloryFixedPointScale", "catalogV3Reprice",
)


@functools.lru_cache(maxsize=None)
def read_glory_version(repo_root: str, commit_sha: str,
                        glory_nim_path: str = GLORY_NIM_PATH) -> int:
    """THE AUTHORITATIVE ERA READ: `GloryVersion*` straight out of
    `src/ctf/glory.nim` at the exact commit a round's build was compiled
    from (`git show <sha>:<path>`, a LOCAL git-object read -- no network).

    Same observation-not-assumption principle as `read_manifest_switches`:
    the era is read from the same source the sim was built from, not
    inferred. `glory_version_for_build` is the no-extra-input fallback for
    callers that have only the episode's `coworld_version`; a test pins the
    two against each other."""
    raw = subprocess.run(
        ["git", "show", f"{commit_sha}:{glory_nim_path}"],
        cwd=repo_root, capture_output=True, text=True, check=True,
    ).stdout
    m = GLORY_VERSION_RE.search(raw)
    if m is None:
        raise KeyError(f"no `GloryVersion* = <n>` in {glory_nim_path} "
                        f"@ {commit_sha}")
    return int(m.group(1))


@functools.lru_cache(maxsize=None)
def read_manifest_switches(repo_root: str, commit_sha: str,
                            manifest_path: str = "coworld_manifest_paintbot.json",
                            variant_id: str = FLAGSHIP_VARIANT_ID) -> CatalogSwitches:
    """Reads the flagship variant's S6 switches straight from the SOURCE
    (`git show <sha>:<manifest_path>`, a LOCAL git-object read -- no
    network) at the exact commit a round's build was compiled from. This is
    what makes catalog selection an OBSERVATION, not an assumption: the
    switches are read from the same manifest the sim actually shipped, not
    inferred from a GameVersion/coworld_version number.

    The returned switch set is ERA-KEYED the same way, from that commit's
    own `GloryVersion*` -- so a catalog resolved here folds against the
    constants that build actually shipped, not HEAD's.
    """
    raw = subprocess.run(
        ["git", "show", f"{commit_sha}:{manifest_path}"],
        cwd=repo_root, capture_output=True, text=True, check=True,
    ).stdout
    manifest = json.loads(raw)
    variant = _find_variant(manifest, variant_id)
    if variant is None:
        raise KeyError(f"variantId={variant_id!r} not found in "
                        f"{manifest_path} @ {commit_sha}")
    kwargs = {k: bool(variant.get(k, False)) for k in SWITCH_KEYS}
    kwargs["gloryVersion"] = read_glory_version(repo_root, commit_sha)
    return CatalogSwitches(**kwargs)


def _find_variant(node, variant_id):
    if isinstance(node, dict):
        if node.get("variantId") == variant_id:
            return node
        for v in node.values():
            found = _find_variant(v, variant_id)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_variant(item, variant_id)
            if found is not None:
                return found
    return None


def build_catalog_map(repo_root: str, version_to_sha: dict,
                       manifest_path: str = "coworld_manifest_paintbot.json",
                       variant_id: str = FLAGSHIP_VARIANT_ID) -> dict:
    """coworld_version -> {"label": "v2"|"v3", "gloryVersion": <int>}, one
    manifest + one glory.nim read per DISTINCT commit (cached). Raises
    loudly (KeyError/CalledProcessError) rather than defaulting a version it
    cannot resolve -- an unresolved version must fail the run, not silently
    fold as v2, and now: not silently fold at HEAD's era either."""
    out = {}
    for version, sha in version_to_sha.items():
        switches = read_manifest_switches(repo_root, sha, manifest_path, variant_id)
        out[version] = {"label": switches.label,
                         "gloryVersion": switches.gloryVersion}
    return out


def normalize_catalog_entry(entry, coworld_version: str = None):
    """A catalog-map value -> `(label, glory_version)`.

    Accepts BOTH shapes: the current `{"label": ..., "gloryVersion": ...}`
    record AND the LEGACY bare `"v2"`/`"v3"` string that maps written
    before this module was era-keyed contain. A legacy entry carries no era,
    so the era falls back to the episode's own `coworld_version`
    (`glory_version_for_build`) -- which is exactly as authoritative for
    the two boundaries this module decodes across, and keeps every map
    already on disk usable."""
    if isinstance(entry, dict):
        label = entry["label"]
        era = entry.get("gloryVersion")
        if era is None:
            era = glory_version_for_build(coworld_version)
        return label, int(era)
    return entry, glory_version_for_build(coworld_version)


def load_catalog_map(path: str) -> dict:
    with open(path) as f:
        return json.load(f)
