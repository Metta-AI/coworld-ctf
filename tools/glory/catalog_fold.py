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
import subprocess
from dataclasses import dataclass

# ── glory.nim constants (verbatim) ──────────────────────────────────────

GLORY_SCALE = 1024
# glory.nim `GlorySCALE* : int64 = 1024`

RECUT_PRODUCT_CAP_DARK = 1 << 62
# glory.nim `RecutProductCap* = int64(1) shl 62`

RECUT_PRODUCT_CAP_ARMED = 1 << 31
# glory.nim `RecutProductCapArmed* = int64(1) shl 31` (2,147,483,648 internal,
# 2,097,152 = 2^21 reported at GLORY_SCALE=1024). GLORY GRADIENT S8
# (CAP-CEILING-S7.md, S2 lead ruling): moved off the S6-era 2^24 (16,777,216)
# to keep this harness a live port of `src/ctf/glory.nim`, not a snapshot.

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
# glory.nim `RecutPlacementRampPct*` (dFinal8/dFinal4/dFinal2 only).
# GLORY GRADIENT S8 PLACEMENT LADDER B (owner decision, 2026-09-10,
# CAP-CEILING-S7.md §Placement): moved off S5/S6's 100/100/130.
RECUT_PLACEMENT_RAMP_PCT = {"dFinal8": 115, "dFinal4": 130, "dFinal2": 160}
# glory.nim `RecutSurvivalCreditPct*` / `RecutSurvivalCreditIntervalTicks*`
# (3134 / 3128): the placement ramp's continuous companion price, x1.02 per
# 720 alive ticks (30 s at 24 ticks/s), compounding -- measured live at 8.49
# firings/episode, ~x1.16 on the team product. See
# `CONTINUOUS_CREDIT_WEAPONS` above for the full semantics and the HANDED
# classification. Recorded, not read by the fold: the wire `amount` already
# carries this percent.
RECUT_SURVIVAL_CREDIT_PCT = 102
RECUT_SURVIVAL_CREDIT_INTERVAL_TICKS = 720
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
        return RECUT_PRODUCT_CAP_ARMED if self.deedMintCaps else RECUT_PRODUCT_CAP_DARK


# The two catalogs actually measured to date (GLORYVERSION-observed, not
# guessed -- see tools/glory/catalog_detect.py for the per-commit manifest
# read that confirms these). GV61 census/README already reconciles 100%
# with deedMintCaps + winAsMultiplier armed and placementRampV3/
# gloryFixedPointScale/catalogV3Reprice all dark; GV62 (S6 SHIP, PR #504+)
# arms all five.
CATALOG_V2 = CatalogSwitches()
CATALOG_V3 = CatalogSwitches(placementRampV3=True, gloryFixedPointScale=True,
                              catalogV3Reprice=True)


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


# ── the whole per-seat-episode fold, v2 and v3 ──────────────────────────

def fold_events_v2(events, cap: int = RECUT_PRODUCT_CAP_ARMED):
    """Byte-identical to `census_decode.py`'s original (pre-S6) inline fold:
    seed 1, `product *= amt` for every `amt > 1`, no floor guard, no scale.
    `events` is an iterable of (weapon, amt) for ONE seat's glory_deed/
    achievement wire events (dTeamKill already filtered out by the caller).
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
SWITCH_KEYS = (
    "gloryMultiplierRecut", "winAsMultiplier", "deedMintCaps",
    "placementRampV3", "gloryFixedPointScale", "catalogV3Reprice",
)


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
    """coworld_version -> "v2"|"v3", one manifest read per DISTINCT commit
    (cached). Raises loudly (KeyError/CalledProcessError) rather than
    defaulting a version it cannot resolve -- an unresolved version must
    fail the run, not silently fold as v2."""
    out = {}
    for version, sha in version_to_sha.items():
        switches = read_manifest_switches(repo_root, sha, manifest_path, variant_id)
        out[version] = switches.label
    return out


def load_catalog_map(path: str) -> dict:
    with open(path) as f:
        return json.load(f)
