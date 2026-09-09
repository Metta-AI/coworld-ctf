#!/usr/bin/env python3
"""gloryscore — score the glory economy over REAL league play, offline.

The calibration question this answers: are the glory systems TOO EASY?
Sixteen copies of the baseline bot mirror-matching each other cannot answer
it — a curriculum every policy sweeps at the same rate discriminates nothing.
So this runs the glory reducer over the scout cache's re-simulated REAL
episodes (relh, Ron, richard, daveey, our Picasso — the actual field) and
reports, per system, the numbers the design carries as calibration targets:

  levels        P(L1 | a cog that killed or stole) ~ 0.9
                L3+ cogs per team per episode      ~ 1-2
                L5 cogs per EPISODE (all teams)    <= 1-2
  achievements  claims/team/episode out of 40; tier histogram; and the
                DISCRIMINATION check — winners must out-claim losers, or the
                curriculum is participation candy (a gate must DISCRIMINATE,
                not just hit). Split T1-T2 (mechanics) vs T3-T5
                (tactics/mastery) to test whether the pooled gap is hiding a
                low-tier no-op.
  rung order    claim RATE per (tree, tier) across the field — flags any tree
                where a higher tier out-claims a lower one, a mis-ordered
                curriculum rung (tier I should be the ceiling, V the floor)
  sweep budget  total achievement glory vs the MEDIAN WINNER's episode glory
                — the real denominator AchievementSweepBudgetPct has been
                waiting for (the shipped 15 is uncalibrated by design), now
                WIPE-CORRECTED (see dWipe below) since most winners never
                fire a capture event at all
  heat          fraction of playing ticks each team spends at x2/x4/x8
                (Muster's scar: the whole server pinned at max = too easy)
  glory itself  winner-vs-loser separation (does glory track winning, or
                does everyone get rich?)

⚠️ MEASUREMENT MIRROR, NOT SOURCE. `src/ctf/glory.nim` is the single source
of truth for every number; the tables and `satisfied()` below are a
hand-checked copy pinned to GLORY_VERSION, verified at startup by
`check_glory_version()` — it parses `GloryVersion*= <n>` straight out of
glory.nim and REFUSES TO RUN if the two have drifted. A silently-stale mirror
(this file sat two curriculum rewrites behind glory.nim before this pass,
still implementing deleted pickup rungs and a per-tick Clean Sheet poll) is
the exact defect class that guard exists to end.

⚡ EXTENSION 4 (this pass): the tier-2 stream now carries `Achievement`/
`GloryDeed`/`LevelUp` rows (`extract_events.nim` commit c70907d) — glory.nim's
OWN mints, verbatim, off the wire. Wherever an episode's event file has them,
`score_episode()` reads glory/achievement claims/deeds STRAIGHT FROM THOSE
ROWS instead of re-deriving them by walking damage/kill/pickup events through
this file's hand-copied pricing tables (`score_episode_stream`, below) — this
is what makes the achievement side of this mirror un-driftable going forward:
a claim it reports is glory.nim's own claim, not a guess at one. Heat
occupancy, xp peaks and the level ladder still come from the full per-tick
walk (`score_episode_derived`) either way, because xp values and heat embers
never ride the wire — only the CLAIMS/MINTS half of the report gets the
direct read. Every printed number is silent about which path produced it
UNLESS you read the MIRROR PATH section in the output; today's
`~/.ctf/scout` cache predates c70907d entirely, so every episode currently
scores via the derivation fallback — the direct-read path is live code
waiting for the cache to catch up, not yet exercised in practice.

This mirror prices deeds over the tier-2 event stream, so a few
context bits the live sim knows first-hand are approximated or dropped in
the RE-DERIVATION fallback (the STREAM path above needs none of these —
it reads glory.nim's own resolved deed, not a reconstruction of one):
  - dRunDown / dRevengeKill: victim velocity and killer-of-killer windows are
    not derivable offline -> those kills price as whatever the rest of the
    precedence chain finds (escort, weapon-class, or the honorable floor).
  - dEscortKill (glory.nim v4): DERIVABLE, unlike the two above — a
    teammate's live `carrying` flag is state this file already tracks, so a
    kill landed while a teammate runs the enemy heart is priced as an escort
    the same way the engine does.
  - range (point-blank / longshot): killer position is the LAST event that
    carried one (a shot, throw, or spray), not the true position at the kill
    tick.
  - contested steals (`Hands On`, v3.1): "a live enemy stood within
    ContestedStealPx of the steal" is approximated from the SAME
    last-known-position tracking as the range checks above, so it can miss a
    contest whose enemy hasn't logged a position-carrying event recently —
    another documented UNDER-count, on top of `ContestedStealPx` itself
    being UNCALIBRATED in glory.nim.
  - per-activation multikills (`sprayMultiKills`/`grenadeMultiKills`): the
    engine groups by ONE continuous cone/blast; this file groups by SAME
    SOURCE, SAME WEAPON, and for grenades additionally SAME TICK (a blast
    applies damage to everyone in radius in a single step, so same-tick is
    exact). Spray is DIFFERENT: `PlasmaArcActiveTicks` = 5, so one
    continuous cone can land kills up to 4 ticks apart -- a same-tick-only
    proxy (the v6 and earlier approximation) UNDER-counted it, confirmed
    directly chasing "Double Splash" reading 0.0% at n=240 (GLORY /proof
    E6): of 32 same-cog spray-kill pairs closer than a full recharge cycle
    apart, exactly one sat at a 2-tick gap (inside one activation) with
    every other pair 29+ ticks apart (`PlasmaArcResetTicks`=20 recharge +
    `PlasmaArcActiveTicks`=5 means nothing closer than ~25 ticks can be a
    SEPARATE activation) -- a real signal a same-tick proxy structurally
    cannot see. v7 (GLORY /proof E6) widens spray's grouping to a 4-tick
    window per source (matching `PlasmaArcActiveTicks` - 1, the largest
    possible in-activation gap) while leaving grenade's same-tick grouping
    untouched. Still an UNDER-count in principle (two kills 5+ ticks apart
    within a slow-moving cone sweep are not impossible), just a much
    tighter one than same-tick.
  - team alive-counts (`Uphill`) and peel→steal ordering (`Turnaround`):
    reconstructed from `death`/`respawn`/`kill`/`flag_steal` rows, all of
    which predate the c70907d stream additions and so are present in every
    cached episode regardless of extractor vintage — these two ARE tracked
    live now (the v2 mirror's own comments flagged both as gaps: "needs live
    alive-counts: tracked by caller" and "needs peel->steal ordering: tracked
    by caller" — this pass is that caller).
  - steal→capture delta (`Fast Break`, v8, replaces "Full Run"): the engine
    PINS `capturedFastBreak` once, inside `recordCapture`, off
    `sim.tickCount - stealTickThisLife` read from its own internal clock —
    this mirror has no wire bit to read for that (no tier-2 kind carries it),
    so it recomputes the IDENTICAL formula at the `capture` row itself, off
    `cog.steal_tick_life` (already tracked here for the retired "Full Run"
    check) and that row's own `tick`. Because `check_achievements` fires
    immediately after every event including the capture's own, this lands on
    the same tick pair the engine used — UNLIKE `Uphill`'s divergence (a true
    poll-time re-derivation: `team_alive`/`enemy_alive` are recomputed FRESH
    on every LATER poll too, which is what lets it backdate), this pin cannot
    drift forward in time the same way, since both of its inputs are fixed
    event-tick facts, not live-recomputed roster state. The residual risk is
    generic, not specific to this gate: it trusts the wire `tick` field to
    equal the engine's internal `sim.tickCount` at both the `flag_steal` and
    `capture` instants — the same assumption the n=103 field-fit that
    produced `FastBreakTicks` itself already leaned on. NOT cross-validated
    against a live `capturedFastBreak` sample (the engine does not expose
    that bit to this offline pipeline at all), so flagged honestly rather
    than presumed exact, the same discipline `Uphill`'s own known-divergence
    note holds itself to.
  - the site gradient: pedestals are the FIXED map constants `FIXED_PEDESTAL`
    (v7, GLORY /proof E1) -- known from tick 0 in every episode, not recovered
    per-episode from `flag_steal` coordinates any more (that recovery had a
    real bug: it needed an UNRELATED theft of the SAME team's own flag to
    have already happened first, which under-counted both `dDenial` and the
    home/enemy split for any deed minted before that; see `FIXED_PEDESTAL`'s
    own comment for the traced numbers). `SiteMultNeutralPct` is dead code in
    the real engine regardless (see glory.nim's own comment) -- this mirror
    now reflects that: every positioned deed classifies HOME or ENEMY, never
    NEUTRAL.
  - dWipe: minted by the ENGINE since commit fd6b4ce (`awardWipe`, priced at
    the deciding kill's site) and, wherever the stream carries it, read
    DIRECTLY as a GloryDeed row (weapon="dWipe") by the STREAM path above —
    no inference needed there. The RE-DERIVATION fallback still needs the
    WIPE MINTING block in main(): there is no "team eliminated" tier-2 event
    kind independent of GloryDeed, so a stream-less episode's re-derived
    glory is under-counted by 400 on every wipe ending unless inferred from
    the death ledger, as before.

Usage:
  gloryscore.py [--episodes N] [--min-version 0.7.200]
"""
import argparse
import collections
import glob
import json
import math
import os
import re
import statistics

CACHE = os.path.expanduser("~/.ctf/scout")

# ── glory.nim mirror (pinned) ────────────────────────────────────────────────
GLORY_VERSION = 10
# Path-relative to THIS file, not the cwd: tools/ladder/gloryscore.py ->
# ../../src/ctf/glory.nim. A cwd-relative path would pass by accident when
# run from the repo root and silently skip the guard from anywhere else.
GLORY_NIM_PATH = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "src", "ctf", "glory.nim"))


def check_glory_version(path=GLORY_NIM_PATH, pinned=GLORY_VERSION):
    """Abort loudly if `src/ctf/glory.nim`'s `GloryVersion` has moved past
    what this mirror is hand-synced to. This is the tripwire the module
    docstring promises: the ONLY thing standing between a real re-sync and a
    comment nobody re-reads. It parses the live source rather than trusting
    a copied number, so it cannot itself go stale the way the tables below
    otherwise silently did (GLORY_VERSION sat at 2 through two curriculum
    rewrites before this pass, its own guard nothing but a comment).
    """
    if not os.path.isfile(path):
        raise SystemExit(
            f"gloryscore: cannot find {path} to verify GLORY_VERSION -- "
            f"this mirror refuses to score against an unverifiable source of "
            f"truth. Run from a coworld-ctf checkout (or fix GLORY_NIM_PATH "
            f"if the layout moved).")
    text = open(path, encoding="utf-8").read()
    m = re.search(r"GloryVersion\*\s*=\s*(\d+)", text)
    if not m:
        raise SystemExit(
            f"gloryscore: could not find 'GloryVersion*= <n>' in {path} -- "
            f"glory.nim's const declaration shape changed under this "
            f"mirror. Fix the regex in check_glory_version() before "
            f"trusting ANY number this file prints.")
    live = int(m.group(1))
    if live != pinned:
        raise SystemExit(
            f"🚨 STALE MIRROR: {path} is at GloryVersion={live}, but "
            f"gloryscore.py is hand-pinned to GLORY_VERSION={pinned}. This "
            f"is precisely the defect class this guard exists to catch -- a "
            f"hand-maintained copy that drifted from its source silently. "
            f"Re-read glory.nim's changelog at the GloryVersion const, "
            f"re-sync DEED_GLORY / DEED_DRAMA / satisfied() / the tier "
            f"tables below to match what shipped, THEN bump GLORY_VERSION "
            f"here. Refusing to score against a table that may no longer "
            f"describe the game.")


# DeedGloryTable / DeedDramaTable, verbatim from glory.nim -- UNCHANGED since
# v4 EXCEPT `clutch_heal` (v9, GLORY LAW E1: zero+tombstoned -- self-heal is
# never above-and-beyond; see the tombstone on `Deed.dClutchHeal` in
# glory.nim) and `level_up` (v10, Maxwell's ruling: leveling pays POWER, not
# the scoreboard -- zero+tombstoned the same way; see the tombstone on
# `Deed.dLevelUp`). dFlagReturn is GONE (retired in v4 -- zero mint sites,
# would double-pay the carrier's death; see the tombstone on `Deed` in
# glory.nim). dRevengeKill/dRunDown/dEscortKill are new since the v2 mirror;
# the first two are still undetected offline in the RE-DERIVATION fallback
# (see the module docstring), but they ARE priced here so the STREAM path
# (which reads them straight off the wire) and the DEEDS report can show
# them.
DEED_GLORY = {
    "first_blood": 12, "honorable_kill": 10, "spray_kill": 12,
    "grenade_kill": 12, "point_blank_kill": 12, "longshot_kill": 30,
    "splash_multikill": 35, "revenge_kill": 18, "run_down": 16,
    "ace_tag": 40, "team_kill": -60,
    "flag_steal": 40, "capture": 250,
    "carrier_kill": 90, "denial": 120, "escort_kill": 14,
    "clutch_heal": 0, "shield_soak": 4, "wipe": 400, "level_up": 0,
}
DEED_DRAMA = {
    "first_blood": 20, "honorable_kill": 10, "spray_kill": 30,
    "grenade_kill": 30, "point_blank_kill": 35, "longshot_kill": 40,
    "splash_multikill": 40, "revenge_kill": 30, "run_down": 20,
    "ace_tag": 30, "team_kill": 0,
    "flag_steal": 25, "capture": 70,
    "carrier_kill": 35, "denial": 45, "escort_kill": 15,
    "clutch_heal": 0, "shield_soak": 0, "wipe": 400, "level_up": 0,
}
HEAT_LADDER = [1, 2, 4, 8]
HEAT_THRESHOLDS = [2, 5, 10]
HEAT_EMBER_CAP = 11
HEAT_EMBER_DECAY = 2
HEAT_DECAY_TICKS = 45

LEVEL_THRESHOLDS = [9, 15, 24, 33, 48]
# Maxwell's ruling: WORK levels, kills do not. Damage / healing / tool
# pickups / flag actions; the carrier kill prices as the RETURN it causes.
# v9 (GLORY LAW E1): RE-FIT -- `XP_HEAL`/`XP_CLUTCH`/`XP_SOAK`/`XP_PICKUP`
# all go to 0 below (self-care buys no levels), which for real shrinks the
# xp pool this ladder is fit against (not a measurement-bug fix like v7's
# was). See glory.nim's own `LevelThresholds` comment for the full
# percentile table (p25:6 p50:9 p75:15 p90:21 p95:27 p98:39 p99:45,
# n=4804/6870 active lives) and cadence verification.
XP_KILL, XP_DAMAGE, XP_CARRIER_KILL = 0, 3, 12
XP_STEAL, XP_CAPTURE, XP_RETURN = 12, 30, 12
XP_TEAM_KILL = -20
XP_SOAK, XP_CLUTCH, XP_HEAL, XP_PICKUP = 0, 0, 0, 0
# v9 (GLORY LAW E1): all four zeroed -- self-care (a shield that protects
# only its wearer; healing yourself) buys no levels. Mint sites in the real
# engine stay wired at 0; this mirror's own `add_xp(t, XP_SOAK * blocked,
# tick)` / heal-branch calls stay in place too, for the same "still fires,
# now for nothing" honesty (see glory.nim's `dClutchHeal` comment).
# XP_PICKUP (v6, GLORY C1): only still fires through the `heal` event path
# below now -- a bare-touch grenade/spray_can/shield pickup pays zero xp in
# the real engine (the `item_pickup` branch that used to price them is
# retired, C10). The med-kit heal's own XP_PICKUP term survives because the
# real engine gates that pickup on already being hurt, so it is never
# actually "bare."
ACE_LEVEL = 3
SUPPLY_XP, SUPPLY_MAX, SUPPLY_COOLDOWN = 20, 4, 90

TIER_GLORY = [9, 11, 14, 18, 23]
FIRST_MULT = 3
FIRST_TIER_ONLY = len(TIER_GLORY) - 1  # v9 (GLORY LAW E4): the race (marker
    # + FIRST_MULT) reaches ONLY this tier index (4, "V") now -- see
    # glory.nim's law 2 comment for the 25%-of-40 ceiling this is sized
    # against. Tiers 0-3 always claim at base price, `first=False`, no
    # exceptions -- enforced at BOTH claim sites below (the per-tick loop
    # and the Clean-Sheet conclusion-only mint), mirroring sim.nim's
    # `claimAchievement` enforcing it once, centrally.
CLUTCH_HP_THRESHOLD = 1     # v9: "at/near clutch hp" -- glory.nim's
    # `ClutchHpThreshold`, shared by the (mirror-undeliverable) supply-drop
    # save gate and the (derivable) menacing/rescue gate below.
ASSIST_WINDOW_TICKS = 120   # v9 (GLORY E3, new, UNCALIBRATED): glory.nim's
    # `AssistWindowTicks`.
RESCUE_WINDOW_TICKS = 120   # v9 (GLORY E3, new, UNCALIBRATED): glory.nim's
    # `RescueWindowTicks`.
SECOND_WIND_TICKS = 120     # v9 (GLORY E3): RE-GATED, not re-measured -- the
    # exact magnitude the pre-v9 self-heal Second Wind used inline, now named
    # (glory.nim's `SecondWindTicks`) and re-pointed at a rescue instead.
SQUAD_VOLLEY_WINDOW_TICKS = 90   # v9 (GLORY E3, new, UNCALIBRATED): glory.
    # nim's `SquadVolleyWindowTicks`.
SQUAD_VOLLEY_MIN_DISTINCT = 3    # glory.nim's `SquadVolleyMinDistinct`.
POINT_BLANK_PX, LONGSHOT_PX, DENIAL_PX = 110, 700, 600
# DENIAL_PX (v6, GLORY C5): field-fit from 220 -- "Doorstep" claimed 0.0% of
# 240 sampled team-episodes at the old value. See glory.nim's `DenialPx`
# comment for the full measurement (157 carrier kills, this arena's home
# pedestals are fixed at (186,329)/(1049,329), p50 kill-to-home distance
# 776px). 600px lands the claim rate at 17.5%.
CONTESTED_STEAL_PX = 300   ## v3.1 `Hands On` gate (glory.nim: UNCALIBRATED).
REVENGE_TICKS = 240        ## `Turnaround`'s peel->steal window.
FAST_BREAK_TICKS = 240     ## `Fast Break` gate (v8): field-fit from 103 real
                           ## steal->capture deltas (p10=210, p25=244,
                           ## p50=358) -- see glory.nim's `FastBreakTicks`
                           ## comment for the full percentile table.

# FIXED_PEDESTAL (v7, GLORY /proof wave E1): the two home pedestals on this
# arena, hardcoded rather than recovered per-episode from `flag_steal`
# coordinates. Confirmed a MAP CONSTANT directly: 236 recovered flag_steal
# (team, x, y) triples across the 120-episode sample give stdev 0.00 on both
# axes for both teams -- (186,329) for team 0, (1049,329) for team 1.
#
# 🚨 THE BUG THIS REPLACES. The old `pedestal = {}` (populated only as
# `flag_steal` events are walked) requires team(t)'s OWN flag to have been
# independently stolen by the enemy SOMEWHERE EARLIER in that same episode
# before `pedestal.get(team(t))` resolves to anything -- an accident of a
# completely UNRELATED theft (a different flag, a different act), not a fact
# about the map. Traced directly: of 56 kills that were true denials by the
# fixed-coordinate standard (below), 44 (78.6%) had `pedestal.get(team(t))`
# still unset at kill time, so `near_home` fell through to False and the kill
# mispriced as a plain `carrier_kill`. This under-counted BOTH `dDenial`
# ("Doorstep") and the site gradient's home/enemy split (`mint()`'s own
# `pedestal.get(t)`/`pedestal.get(1 - t)` pair needs BOTH populated, so any
# deed minted before EITHER team's flag has ever been stolen priced neutral
# regardless of where it actually happened -- the module docstring's old
# "episodes where a flag was never stolen price everything neutral" caveat
# undersold it; it was "before *this* team pair's mutual first steal", a
# stronger and earlier-biased condition). Since the coordinates are a MAP
# CONSTANT, there is no need to wait for any event to learn them.
#
# RECONCILIATION (E1, 2026-08-25): this bug is the reason three Doorstep
# measurements disagreed -- 4.6% (this mirror's `satisfied()`, recovered
# pedestal, pre-fix), 17.5% (the C5 fixed-pedestal script that field-fit
# `DenialPx`, glory.nim's own comment), 34% (a cruder check that, per the
# numbers below, reads as `denials / carrier_kills` -- a PER-KILL rate, 56/157
# = 35.7% -- mistaken for the achievement's own unit, a PER-TEAM-EPISODE
# CLAIM rate; a team-episode only needs ONE denial to claim, so the two units
# diverge sharply once a team banks more than one). Re-measured with this fix
# (same 120-episode selection, same kill-before-same-tick-flag_return sort):
# 42/240 team-episodes claim Doorstep = 17.5%, EXACTLY reproducing the C5
# script's own number -- confirming both that this fix is the correct
# operationalization (it matches sim.nim's `killPlayer`: fixed home pedestal,
# gated on `victim.carryingFlag`) and that `DenialPx`=600 needs no further
# move (17.5% sits comfortably inside the 10-30% tier-II band). See
# glory.nim's `DenialPx` comment for the sim-side half of this reconciliation.
FIXED_PEDESTAL = {0: (186, 329), 1: (1049, 329)}

SITE_HOME, SITE_NEUTRAL, SITE_ENEMY = 100, 120, 150

# Nim's `$deed` / `$tree` on these enums prints the bare identifier -- the
# GloryDeed/Achievement rows on the wire carry EXACTLY these strings (see
# `SimEventKind`'s doc comments in sim.nim). Map them to this file's own
# snake_case keys so the STREAM path (score_episode_stream) and the
# RE-DERIVATION path (score_episode_derived) report through one shared
# vocabulary.
DEED_ENUM_TO_KEY = {
    "dFirstBlood": "first_blood", "dHonorableKill": "honorable_kill",
    "dSprayKill": "spray_kill", "dGrenadeKill": "grenade_kill",
    "dPointBlankKill": "point_blank_kill", "dLongshotKill": "longshot_kill",
    "dSplashMultiKill": "splash_multikill", "dRevengeKill": "revenge_kill",
    "dRunDown": "run_down", "dAceTag": "ace_tag", "dTeamKill": "team_kill",
    "dFlagSteal": "flag_steal", "dCapture": "capture",
    "dCarrierKill": "carrier_kill", "dDenial": "denial",
    "dEscortKill": "escort_kill", "dClutchHeal": "clutch_heal",
    "dShieldSoak": "shield_soak", "dWipe": "wipe", "dLevelUp": "level_up",
}
TREE_ENUM_TO_KEY = {
    "treeGun": "gun", "treeSpray": "spray", "treeGrenade": "nade",
    "treeShield": "shield", "treeMedKit": "med", "treeCarrier": "carrier",
    "treeDefender": "defender", "treeSquad": "squad",
}
STREAM_KINDS = {"achievement", "glory_deed", "level_up"}


def level_for(xp):
    lvl = 0
    for t in LEVEL_THRESHOLDS:
        if xp >= t:
            lvl += 1
        else:
            break
    return lvl


def heat_mult(embers):
    rung = 0
    for t in HEAT_THRESHOLDS:
        if embers >= t:
            rung += 1
        else:
            break
    return HEAT_LADDER[min(rung, len(HEAT_LADDER) - 1)]


class Cog:
    __slots__ = ("xp lvl hp lifemax peak alive pos carrying "
                 "gun_kills spray_kills grenade_kills longshot_kills "
                 "ace_kills spray_kills_pickup spray_multi grenade_multi "
                 "soak clutch_heals clutch_heal_t clutch_carry_heals "
                 "second_wind "
                 "steals contested_steals carry_kills carrier_kills denials "
                 "peel_t steal_tick_life caps team_kills fast_break "
                 "supply_drops supply_credit supply_t "
                 # v9 (GLORY LAW E2/E3): THE PROVIDER + the teamwork tree.
                 # `supply_shared`/`supply_saves` are declared but NEVER
                 # incremented -- see the module docstring's own honest-
                 # divergence note on why they cannot be derived offline
                 # (the wire carries no drop-attribution). The rest ARE
                 # derivable and are wired below.
                 "supply_shared supply_saves "
                 "last_damaged_by last_damaged_by_t "
                 "menacing_t menacing_victim rescued_t "
                 "assists rescues escort_kills").split()

    def __init__(self):
        for f in self.__slots__:
            setattr(self, f, 0)
        self.pos = None
        self.hp = 3
        self.alive = True
        self.supply_t = -10**9
        self.clutch_heal_t = -10**9
        self.peel_t = -10**9
        self.steal_tick_life = -1
        self.last_damaged_by = -1
        self.last_damaged_by_t = -10**9
        self.menacing_t = -10**9
        self.menacing_victim = -1
        self.rescued_t = -10**9

    def reset_life(self):
        # THE anti-snowball rule, mirrored: death forfeits xp, level, the
        # supply drop allowance, and (v4) this life's steal marker -- resetLadder
        # clears `stealTickThisLife` on every death, so a capture needs the
        # SAME life's steal to still be on record (v8: `Fast Break`'s delta
        # depends on this the same way "Full Run" did before it). Every other
        # ACHIEVEMENT COUNTER, `fast_break` included, is per-GAME and survives
        # death untouched, both in sim.nim's `startGame` reset list and here.
        # v9: the E2/E3 counters (`supply_shared`/`assists`/`rescues`/
        # `escort_kills`) are ALSO per-game, same shape -- not reset here,
        # same as `fast_break`. The tick-state fields (`last_damaged_by_t`,
        # `menacing_t`, `rescued_t`) are also left untouched, mirroring
        # sim.nim's own choice not to reset `clutchHealTick`/`peelTick` on
        # death (see those fields' own comments on `Player`).
        self.xp = 0
        self.peak = 0
        self.supply_drops = 0
        self.supply_credit = 0
        self.supply_t = -10**9
        self.hp = 3
        self.steal_tick_life = -1


def dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


# ───────────────────────────────────────────────────────────────────────────
# THE v6 CURRICULUM, mirrored from glory.nim's `satisfiedAchievements`.
# ───────────────────────────────────────────────────────────────────────────
#
# Law 2b's ruling (2026-08-24) bans every pickup/possession/arrival
# requirement from the tree: an act that already pays for itself mechanically
# (a pickup heals or arms you, arrival anywhere is free) is not an
# achievement. v3 deleted "Shake It"/"Pull the Pin"/"Suit Up"/"Field
# Dressing"/"Eyes Back" outright; v3.1 caught `treeCarrier` tier I/II
# ("Hands On"/"Breakaway") missing the same rewrite and re-cut them to a
# CONTESTED steal and a kill made WHILE CARRYING. Nothing below reads a
# `took_X` flag, a live-possession timer, or the bystander-credited
# `returns` counter -- see `resetFlag`'s comment in sim.nim for why
# `returns` is banned as an achievement input for good.
#
# v6 (GLORY /proof wave): three trees reordered on measured claim rates
# (gun IV/V, grenade III/IV/V, carrier II/III -- see each block below);
# "Blast Radius" (nade) now gates on `grenade_multi` alone (C3a); display
# names renamed off borrowed vocabulary (C6) -- this file matches on
# (tree_key, tier index) tuples, never display text, so the renames touch
# only the trailing comments here, not any matching logic.
def satisfied(cog, any_capture, kits, team_alive, enemy_alive):
    s = set()
    kills = cog.gun_kills + cog.spray_kills + cog.grenade_kills

    # gun -- "Trigger Discipline" (any landed hit) is GONE; every tier below
    # is a KILL or a rank. v6: IV/V swapped -- L5 claims 15.4% in the field
    # vs a longshot kill's 8.3% (n=240 team-eps), so Longshot is the real
    # ceiling now.
    if cog.gun_kills >= 1:            s.add(("gun", 0))   # First Tag
    if cog.gun_kills >= 3:            s.add(("gun", 1))   # Marksman
    if cog.ace_kills >= 1:             s.add(("gun", 2))   # Bounty
    if cog.lifemax >= 5:              s.add(("gun", 3))   # Sharpshooter (L5)
    if cog.longshot_kills >= 1:       s.add(("gun", 4))   # Longshot

    # spray -- "Shake It" (pick up a can) is GONE.
    if cog.spray_kills >= 1:          s.add(("spray", 0))  # First Coat
    if cog.spray_kills >= 2:          s.add(("spray", 1))  # Full Coverage
    if cog.spray_kills_pickup >= 2:   s.add(("spray", 2))  # Repainted
    if cog.spray_kills_pickup >= 3:   s.add(("spray", 3))  # The Muralist
    if cog.spray_multi >= 1:          s.add(("spray", 4))  # Double Splash

    # grenade -- "Pull the Pin" (pick up a nade) is GONE. v6: "The
    # Bombardier" (3 grenade kills) moved II->V -- field claim rate 2.1%,
    # the LOWEST of the tree's five (n=240 team-eps), below both multi-kill
    # tiers it used to outrank; "Blast Radius"/"Double Blast" shift down to
    # III/IV. "Blast Radius" also drops the `spray_multi` alternative AND
    # the `grenade_kills >= 1` term (C3a): a SPRAY multi-kill could complete
    # a GRENADE tier, and the kills term was redundant -- every enemy a
    # multi-kill blast catches already counts toward `grenade_kills` on the
    # way to incrementing `grenade_multi`.
    # v7 (GLORY /proof E4): "Double Blast" now needs `grenade_multi >= 2` --
    # the C3a fix above left III and IV gating on the SAME `>= 1` condition,
    # so the two claimed in lockstep (n=7 field, every claim same-tick as
    # its pair). "Double" now means two multi-kill blasts in one game.
    if cog.grenade_kills >= 1:        s.add(("nade", 0))   # Delivery
    if cog.grenade_kills >= 2:        s.add(("nade", 1))   # Splatterbomb
    if cog.grenade_multi >= 1:        s.add(("nade", 2))   # Blast Radius
    if cog.grenade_multi >= 2:        s.add(("nade", 3))   # Double Blast
    if cog.grenade_kills >= 3:        s.add(("nade", 4))   # The Bombardier

    # shield -- v9 (GLORY LAW E3): RE-FOUNDED as the teamwork tree. The old
    # soak-threshold ladder is GONE (a shield protects only its wearer, so
    # soaking was self-benefiting -- see glory.nim's `treeShield` comment).
    # `assists`/`escort_kills`/`rescues` ARE derivable offline (the damage
    # and kill events carry everything sim.nim's own gates need) and are
    # wired at the `damage`/`kill` handlers below. "Squad Volley" (tier 4)
    # is TEAM-WIDE, handled in `check_achievements`, not here.
    if cog.assists >= 1:              s.add(("shield", 0))  # Cover Fire
    if cog.escort_kills >= 1:         s.add(("shield", 1))  # Escort Duty
    if cog.rescues >= 1:              s.add(("shield", 2))  # The Save
    if cog.second_wind:               s.add(("shield", 3))  # Second Wind
                                                              # (re-gated)

    # med kit -- v9 (GLORY LAW E2): RE-FOUNDED as The Provider, gated on
    # `supply_shared`/`supply_saves`. 🚨 KNOWN DIVERGENCE, permanent for this
    # offline mirror, not a bug: neither counter can be derived from the
    # tier-2 event stream. A supply-dropped pickup's `droppedBy` (which
    # veteran's heart produced it) is sim-internal state that never rides
    # the wire -- the `heal`/pickup events this file reads carry only the
    # CONSUMER's own slot, with no way to attribute the drop back to its
    # producer. So every "med" tier below is intentionally NEVER added to
    # `s` -- this tree always reads as 0% claimed in the offline mirror,
    # which is a MIRROR GAP, not evidence the mechanic is unreachable in the
    # real engine (`tests/test_glory_sim.nim` proves it fires end to end).
    # Left as a visible, present-tense gap rather than silently dropping the
    # tree from the curriculum entirely.

    # carrier -- v3.1 re-cut off possession the same way every other tree
    # already was. v6: II/III swapped -- a score claims 18.8% in the field
    # vs a kill-while-carrying's 11.7% (n=240 team-eps), so scoring is
    # easier and Fighting Carry is the harder act.
    #
    # ⚠️ "Uphill" is a KNOWN DIVERGENCE from the real v6 engine as of this
    # sync: sim.nim now pins the outnumbered fact ONCE, at the capture
    # instant (`capturedOutnumbered`, GLORY C3b), specifically to stop a
    # capture made EVEN from backdating into a claim if a teammate dies
    # later. This offline mirror still re-checks `team_alive < enemy_alive`
    # on every poll (the exact poll-time pattern the engine fix retired),
    # because the tier-2 event stream carries no per-capture "was the team
    # behind AT THAT INSTANT" flag to read instead -- reproducing the fix
    # exactly would need a new capture-time alive-count sample this file
    # does not have. Not fixed in this sync; flagged for a future pass.
    if cog.contested_steals >= 1:     s.add(("carrier", 0))  # Hands On
    if cog.caps >= 1:                 s.add(("carrier", 1))  # Delivered
    if cog.carry_kills >= 1:          s.add(("carrier", 2))  # Fighting Carry
    if cog.caps >= 1 and team_alive < enemy_alive:
        s.add(("carrier", 3))                                # Uphill
    # "Fast Break" (v8, replaces "Full Run"): reads the fact pinned at the
    # `capture` event handler above -- see the module docstring's
    # "steal->capture delta" bullet for the known-divergence note.
    if cog.fast_break:                s.add(("carrier", 4))  # Fast Break

    # defender -- "Eyes Back" (a heart return) is GONE: bystander credit,
    # never an individual act.
    if cog.carrier_kills >= 1:        s.add(("defender", 0))  # The Peel
    if cog.denials >= 1:              s.add(("defender", 1))  # Doorstep
    if cog.carrier_kills >= 2:        s.add(("defender", 2))  # Double Peel
    if (cog.peel_t > -10**8 and cog.steal_tick_life > cog.peel_t and
            cog.steal_tick_life - cog.peel_t <= REVENGE_TICKS):
        s.add(("defender", 3))                                # Turnaround
    if cog.denials >= 2:              s.add(("defender", 4))  # Lockdown

    # squad (TEAM tree). Kit tiers read CONVERSION (`team_converted_kits`),
    # never live possession. Tier III (Clean Sheet) is DELIBERATELY absent
    # here -- it is FULL-GAME and conclusion-only; see `clean_sheet_claims`.
    if kits >= 2:                     s.add(("squad", 0))     # Kitted
    if kits >= 3:                     s.add(("squad", 1))     # Full Loadout
    if kits >= 4:                     s.add(("squad", 2))     # Full Kit
    if kits >= 4 and any_capture:     s.add(("squad", 4))     # Victory Lap
    return s


def team_converted_kits(cogs, team_of, t):
    ## Mirrors `teamConvertedKits`: how many of the four kits this team has
    ## CONVERTED -- at least one teammate landed the kit's signature act --
    ## not how many are held right now.
    ## v9 (GLORY LAW E3): `med`/`shield` re-derived off `supply_shared`/
    ## `assists`, same as sim.nim's own fix -- `med` is PERMANENTLY False in
    ## this offline mirror (see `satisfied()`'s own comment: `supply_shared`
    ## cannot be derived from the wire), a known, honest under-count.
    ##
    ## 🚨 CASCADE: since `med` can never be True here, this proc can never
    ## return more than 3 -- `("squad", 2)` "Full Kit" (kits>=4) and
    ## `("squad", 4)` "Victory Lap" (kits>=4 and a capture) are therefore
    ## ALSO permanently unreachable in this offline mirror specifically
    ## (confirmed: the field run this comment was written against reads
    ## squad T3/T5 at 0.0% where the pre-v9 mirror read 4.2%/1.2%). Same
    ## mirror-gap class as `med` itself, one level removed -- not a new,
    ## separate bug.
    med = nade = spray = shield = False
    for i, c in enumerate(cogs):
        if team_of(i) != t:
            continue
        if c.supply_shared >= 1: med = True
        if c.grenade_kills >= 1: nade = True
        if c.spray_kills >= 1: spray = True
        if c.assists >= 1: shield = True
    return int(med) + int(nade) + int(spray) + int(shield)


def score_episode_derived(events, n_slots):
    """Re-derive glory/achievements/heat/levels by walking the full event log
    through this file's own hand-copied pricing tables. The FALLBACK path --
    `score_episode()` below prefers reading claims/mints straight off the
    stream when the episode's extraction is new enough to carry them (see the
    module docstring's EXTENSION 4). Always used for heat occupancy, xp peaks
    and the level ladder, which the stream never carries either way.
    """
    team = lambda slot: slot % 2  # scout's own convention on 2-team episodes
    cogs = [Cog() for _ in range(n_slots)]
    glory = [0, 0]
    drama_glory = [0, 0]
    ach_glory = [0, 0]
    embers = [0.0, 0.0]
    last_deed = [-10**9, -10**9]
    last_decay = [-10**9, -10**9]
    heat_ticks = [collections.Counter(), collections.Counter()]
    claimed = [set(), set()]
    claimed_first = {}
    claims = [[], []]
    deeds = collections.Counter()
    # v9 (GLORY LAW E3): "Squad Volley" -- a small per-team recent-kill ring
    # (killerIndex, tick), mirroring sim.nim's `teamKillRing`/
    # `recordTeamKillRing`. `squad_volley_done` is a one-way latch, same
    # shape as `claimed_first`.
    team_kill_ring = [[], []]
    squad_volley_done = [False, False]
    # v7 (GLORY /proof E1): pre-seeded with the FIXED map constants, not
    # discovered per-episode -- see `FIXED_PEDESTAL`'s own comment for why
    # the old empty-dict-plus-flag_steal-recovery approach under-counted
    # both denials and the site gradient. The flag_steal branch below still
    # writes into this dict (now idempotently, same value) rather than being
    # deleted outright, so a future re-arena'd cache self-corrects instead of
    # silently scoring against a stale constant.
    pedestal = dict(FIXED_PEDESTAL)
    first_blood = False
    start_tick = 0
    end_tick = 0
    prev_tick = 0
    levels_seen = []       # (slot, max level this life)
    l5_lives = 0
    l3_lives = [0, 0]
    killed_or_stole = set()
    reached_l1 = set()
    supply_total = [0, 0]
    xp_peaks = []
    deaths_by_slot = collections.Counter()  # wipe inference input
    # v7 (GLORY /proof E6): spray_streak is now (count, last_tick) per source,
    # windowed at SPRAY_ACTIVATION_WINDOW ticks -- NOT cleared just because
    # the global tick advanced (see the module docstring's own multikill
    # note for why same-tick under-counted spray). grenade_streak stays the
    # same-tick-cleared dict it always was; a blast is exact at same-tick.
    spray_streak = {}      # source -> (enemy spray kills this activation, last kill tick)
    grenade_streak = {}    # source -> enemy grenade kills THIS TICK
    multi_streak_tick = None
    SPRAY_ACTIVATION_WINDOW = 4  # PlasmaArcActiveTicks(5) - 1: max in-activation gap

    def heat_tick(tick):
        # decay + occupancy accounting between events. Deltas are clamped:
        # the extractor is not guaranteed to emit strictly tick-sorted rows
        # (a blast and its kills interleave), and one negative delta poisons
        # the whole occupancy table.
        delta = max(0, tick - prev_tick)
        for t in (0, 1):
            if embers[t] > 0:
                quiet = max(last_deed[t], last_decay[t])
                while tick - quiet >= HEAT_DECAY_TICKS and embers[t] > 0:
                    embers[t] = max(0.0, embers[t] - HEAT_EMBER_DECAY)
                    quiet += HEAT_DECAY_TICKS
                    last_decay[t] = quiet
            heat_ticks[t][heat_mult(embers[t])] += delta

    def mint(t, deed, x=None, y=None, times=1):
        nonlocal glory
        base = DEED_GLORY[deed]
        deeds[deed] += times
        if base <= 0:
            glory[t] += base * times
            return
        site = SITE_NEUTRAL
        if x is not None and pedestal:
            own = pedestal.get(t)
            other = pedestal.get(1 - t)
            if own and other:
                site = SITE_HOME if dist((x, y), own) < dist((x, y), other) \
                    else SITE_ENEMY
        amount = base * site // 100
        if DEED_DRAMA[deed] > 0:
            amount *= heat_mult(embers[t])
            embers[t] = min(HEAT_EMBER_CAP, embers[t] + times)
            last_deed[t] = end_tick
            drama_glory[t] += amount * times
        glory[t] += amount * times

    def add_xp(slot, amount, tick):
        c = cogs[slot]
        before = c.lvl
        c.xp = max(0, c.xp + amount)
        c.peak = max(c.peak, c.xp)
        c.lvl = level_for(c.xp)
        c.lifemax = max(c.lifemax, c.lvl)
        if c.lvl > before:
            mint(team(slot), "level_up", times=c.lvl - before)
            if c.lvl >= 1:
                reached_l1.add(slot)
        if amount > 0 and c.lvl >= ACE_LEVEL:
            c.supply_credit += amount
            if (c.supply_drops < SUPPLY_MAX and c.supply_credit >= SUPPLY_XP
                    and tick - c.supply_t >= SUPPLY_COOLDOWN):
                c.supply_credit -= SUPPLY_XP
                c.supply_drops += 1
                c.supply_t = tick
                supply_total[team(slot)] += 1

    def check_achievements(tick):
        any_capture = [any(c.caps > 0 for i, c in enumerate(cogs)
                            if team(i) == t) for t in (0, 1)]
        alive_count = [sum(1 for i, c in enumerate(cogs)
                            if team(i) == t and c.alive) for t in (0, 1)]
        kits = [team_converted_kits(cogs, team, t) for t in (0, 1)]
        newly = [set(), set()]
        for t in (0, 1):
            for i, c in enumerate(cogs):
                if team(i) != t:
                    continue
                newly[t] |= satisfied(c, any_capture[t], kits[t],
                                      alive_count[t], alive_count[1 - t])
            # "Squad Volley" (v9, GLORY LAW E3) is TEAM-WIDE -- not any one
            # cog's fact, so it is not inside `satisfied()` -- pinned once in
            # `squad_volley_done[t]` at the kill handler below.
            if squad_volley_done[t]:
                newly[t].add(("shield", 4))
            newly[t] -= claimed[t]
        # same-tick FIRST ties: judge both teams before any claim lands
        for t in (0, 1):
            for key in newly[t]:
                # v9 (GLORY LAW E4): the race is restricted to tier V
                # (FIRST_TIER_ONLY) -- a tier I-IV claim NEVER reads first
                # and never takes FIRST_MULT, no matter who got there first.
                first = key[1] == FIRST_TIER_ONLY and key not in claimed_first
                claimed[t].add(key)
                amount = TIER_GLORY[key[1]] * (FIRST_MULT if first else 1)
                ach_glory[t] += amount
                glory[t] += amount
                claims[t].append((end_tick, key, first))
        for t in (0, 1):
            for key in newly[t]:
                claimed_first.setdefault(key, t)

    # 🚨 kills sort BEFORE same-tick flag_return/capture. Found while building
    # extension 1: carrier_kill/denial priced ZERO times across the whole
    # 120-episode field despite 236 flag_steal events -- the sim logs a
    # carrier's death and the resulting flag_return at the IDENTICAL tick,
    # flag_return first in the raw file, and a tick-only stable sort
    # preserved it. So by the time the kill handler read `victim.carrying`
    # below, flag_return had already cleared it, and EVERY carrier kill in
    # the field mispriced as a plain honorable/point-blank kill. This is the
    # one ordering fix that matters: nothing else here reads state a
    # same-tick event could invalidate.
    build_kill_index(events)
    for e in sorted(events, key=lambda e: (e.get("tick", 0),
                                            0 if e.get("kind") == "kill" else 1)):
        k = e.get("kind")
        tick = e.get("tick", 0)
        end_tick = tick
        heat_tick(tick)
        prev_tick = tick
        if tick != multi_streak_tick:
            # spray is NOT cleared here any more (v7, GLORY /proof E6) -- it
            # ages out per source at the kill site instead, on its own
            # SPRAY_ACTIVATION_WINDOW. grenade stays same-tick-cleared.
            grenade_streak.clear()
            multi_streak_tick = tick
        if k == "phase" and e.get("weapon") == "playing":
            start_tick = tick
        elif k == "item_pickup":
            # 🚨 RETIRED (GLORY C10 audit): this branch is dead code, not
            # merely stale for the old v0.7.9x cache the module docstring
            # blamed. `item_pickup` is not a `SimEventKind` this engine has
            # EVER carried (see sim.nim's `SimEventKind` enum -- there is no
            # such kind, at any version, for `extract_events.nim` to have
            # emitted it from) -- so every sub-case below was always
            # unreachable, on every cached episode regardless of vintage.
            # The med_kit sub-case (clutch-heal detection, which fed the
            # medkit tree AND the squad tree's kit-conversion count, so
            # "Full Kit"/(the tier formerly "The Parade") could never see a
            # 4th converted kit) is repointed at the `heal` branch below,
            # which reads the event the engine actually emits. The
            # grenade/spray_can/shield sub-cases have nothing left to
            # recover even if a pickup event existed: GLORY C1 zeroed their
            # xp in the real engine (a bare touch is not work), so their
            # correct contribution is zero either way.
            pass
        elif k in ("shot", "spray_use", "grenade_throw", "gun_trigger"):
            s = e.get("source", -1)
            if 0 <= s < n_slots:
                cogs[s].pos = (e["x"], e["y"])
        elif k == "damage":
            s, t = e.get("source", -1), e.get("target", -1)
            if 0 <= t < n_slots:
                cogs[t].hp = max(0, e.get("hp", 0))
                blocked = e.get("blocked", 0)
                if blocked > 0:
                    cogs[t].soak += blocked
                    mint(team(t), "shield_soak", times=blocked)
                    add_xp(t, XP_SOAK * blocked, tick)
            if 0 <= s < n_slots and 0 <= t < n_slots and \
                    team(s) != team(t):
                add_xp(s, XP_DAMAGE * e.get("amount", 1), tick)
                # v9 (GLORY LAW E3): ASSIST/RESCUE plumbing, mirroring
                # sim.nim's own damage-site pin exactly -- gated on the
                # victim SURVIVING this hit (hp > 0 after) so a finishing
                # blow never overwrites `last_damaged_by` with the killer
                # itself (see `Player.lastDamagedBy`'s own comment in
                # sim.nim for why that gate is what makes ASSIST reachable).
                if cogs[t].hp > 0:
                    cogs[t].last_damaged_by = s
                    cogs[t].last_damaged_by_t = tick
                    if cogs[t].hp <= CLUTCH_HP_THRESHOLD:
                        cogs[s].menacing_t = tick
                        cogs[s].menacing_victim = t
        elif k == "heal":
            # v6 (GLORY C10): the clutch-heal/xp read moved here from the
            # dead `item_pickup` branch above -- this is the event
            # sim.nim's `tryPickupMedKits`/`tryPickupSupplyDrops` actually
            # emit (Heal, `amount` = hit points restored, `hp` = the cog's
            # POST-heal hp), for EVERY medkit source, ground or supply-
            # dropped. Mirrors BOTH halves of `tryPickupMedKits`'s formula
            # exactly: `XpPerClutchHeal` when the cog was at 1 hp or less
            # BEFORE this heal (reconstructed as `hp - amount`, since the
            # wire never carries pre-heal hp directly), and `XpPerPickup +
            # XpPerHeal * healed` unconditionally.
            #
            # ⚠️ KNOWN OVER-COUNT vs. the real engine: `tryPickupSupplyDrops`'s
            # med-kit case emits an IDENTICAL Heal event but never awards
            # clutch credit in sim.nim (only the GROUND pickup does) --
            # the wire shape does not distinguish the two sources, so a
            # supply-dropped heal landing at 1 hp counts as clutch here when
            # it would not in-engine. Bounded by how rare a supply drop
            # pickup is (AceLevel only, `SupplyDropCooldownTicks`=90,
            # `SupplyDropMaxPerLife`=4), not eliminated.
            #
            # 🚨 Also fixed here (found chasing why this branch measured
            # ZERO clutch heals against a cache that has 433 real `heal`
            # rows, 199 of them at pre-heal hp<=1): `t` used to read
            # `e.get("target", e.get("source", -1))`, but
            # extract_events.nim's `jsonRow` writes EVERY field
            # unconditionally (`result["target"] = %event.target`), so the
            # key is always PRESENT -- at its default -1 for a Heal event,
            # which never sets a target (sim.nim's `emitEvent` calls for
            # Heal only ever pass `source`). The `.get(...)` fallback could
            # therefore never fire; `t` silently resolved to -1 on every
            # single heal, all along. Reading `source` directly is correct.
            t = e.get("source", -1)
            if 0 <= t < n_slots:
                c = cogs[t]
                amount = e.get("amount", 0)
                post_hp = e.get("hp", 3)
                pre_hp = post_hp - amount
                if amount > 0 and pre_hp <= 1:
                    c.clutch_heals += 1
                    c.clutch_heal_t = tick
                    if c.carrying:
                        c.clutch_carry_heals += 1
                    mint(team(t), "clutch_heal", e.get("x", 0), e.get("y", 0))
                    add_xp(t, XP_CLUTCH, tick)
                if amount > 0:
                    add_xp(t, XP_PICKUP + XP_HEAL * amount, tick)
                c.hp = post_hp
        elif k == "flag_steal":
            s = e["source"]
            if 0 <= s < n_slots:
                c = cogs[s]
                c.carrying = 1
                c.steals += 1
                c.steal_tick_life = tick
                killed_or_stole.add(s)
                # the flag leaves its pedestal AT its pedestal: the stolen
                # flag belongs to the OTHER team
                pedestal[1 - team(s)] = (e["x"], e["y"])
                # v3.1 `Hands On`: contested iff a LIVE enemy's last-known
                # position sat within CONTESTED_STEAL_PX of the steal site.
                # Positions are LAST-EVENT approximations offline (see the
                # range caveat in the module docstring) -- an UNDER-count.
                if any(team(i) != team(s) and cc.alive and cc.pos is not None
                       and dist(cc.pos, (e["x"], e["y"])) <= CONTESTED_STEAL_PX
                       for i, cc in enumerate(cogs)):
                    c.contested_steals += 1
                mint(team(s), "flag_steal", e["x"], e["y"])
                add_xp(s, XP_STEAL, tick)
        elif k == "flag_return":
            s = e.get("source", -1)
            if 0 <= s < n_slots:
                cogs[s].carrying = 0
            # dFlagReturn is RETIRED (glory.nim v4): the carrier's death
            # already priced the peel as dCarrierKill/dDenial -- "the peel
            # IS the return" -- so a second mint here would double-pay one
            # act. No glory, and `returns` is gone too (bystander credit,
            # banned as an achievement input; see `resetFlag`'s comment).
        elif k == "capture":
            s = e["source"]
            if 0 <= s < n_slots:
                cogs[s].caps += 1
                cogs[s].carrying = 0
                # "Fast Break" (v8): pin the steal->capture delta AT THIS
                # EVENT, mirroring `recordCapture`'s own pin -- see the
                # module docstring's "steal->capture delta" bullet for why
                # this is the identical formula, not a poll-time guess.
                if (cogs[s].steal_tick_life >= 0 and
                        tick - cogs[s].steal_tick_life <= FAST_BREAK_TICKS):
                    cogs[s].fast_break = True
                mint(team(s), "capture", e["x"], e["y"])
                add_xp(s, XP_CAPTURE, tick)
        elif k == "kill":
            s, t = e.get("source", -1), e.get("target", -1)
            if not (0 <= s < n_slots and 0 <= t < n_slots):
                continue
            weapon = e.get("weapon", "gun")
            vx, vy = e.get("x", 0), e.get("y", 0)
            friendly = team(s) == team(t)
            killer, victim = cogs[s], cogs[t]
            if not first_blood and not friendly:
                first_blood = True
                mint(team(s), "first_blood", vx, vy)
            if friendly:
                killer.team_kills += 1
                mint(team(s), "team_kill")
                add_xp(s, XP_TEAM_KILL, tick)
            else:
                killed_or_stole.add(s)
                # Read the whole kill CONTEXT before anything decides
                # pricing -- mirrors killPlayer's own discipline.
                r = dist(killer.pos, (vx, vy)) if killer.pos is not None \
                    else None
                own_ped = pedestal.get(team(t))
                near_home = bool(victim.carrying and own_ped and
                                  dist((vx, vy), own_ped) <= DENIAL_PX)
                same_tick_multi = bool(
                    [x for x in events_at.get((tick, s), []) if x != t])
                # Escort = a TEAMMATE (not the killer) is currently running
                # the enemy heart -- derivable from the `carrying` state this
                # file already tracks, unlike revenge/rundown.
                escorted = any(i != s and team(i) == team(s) and c.carrying
                               for i, c in enumerate(cogs))
                # Counters -- UNCONDITIONAL on weapon/range/level/carry/heal
                # facts, exactly as killPlayer increments them, independent
                # of which deed the kill ultimately prices as (an ace tag
                # kill made at longshot range still counts for BOTH gates;
                # see sim.nim's comment on `aceKills`). The old v2
                # mirror only updated these INSIDE the winning deed branch,
                # under-crediting every kill that priced as something else.
                if weapon == "spray":
                    killer.spray_kills += 1
                    killer.spray_kills_pickup += 1
                elif weapon == "grenade":
                    killer.grenade_kills += 1
                else:
                    killer.gun_kills += 1
                if r is not None and r >= LONGSHOT_PX:
                    killer.longshot_kills += 1
                if victim.lifemax >= ACE_LEVEL:
                    killer.ace_kills += 1
                if victim.carrying:
                    killer.carrier_kills += 1
                    killer.peel_t = tick
                    if near_home:
                        killer.denials += 1
                    add_xp(s, XP_CARRIER_KILL, tick)  # the RETURN it causes
                if killer.carrying:
                    killer.carry_kills += 1
                # v9 (GLORY LAW E3): ESCORT DUTY -- `escorted` is already
                # computed above for `dEscortKill`'s own pricing; this is
                # the first achievement reader of the same fact.
                if escorted:
                    killer.escort_kills += 1
                # v9 (GLORY LAW E3): ASSIST -- the victim's last SURVIVED
                # enemy hit (see the `damage` handler's own comment for why
                # a finishing blow can never be the one recorded there), if
                # it landed from a DIFFERENT teammate of the killer inside
                # ASSIST_WINDOW_TICKS, credits THAT teammate.
                vd = victim.last_damaged_by
                if (0 <= vd < n_slots and vd != s and team(vd) == team(s) and
                        victim.last_damaged_by_t > -10**8 and
                        tick - victim.last_damaged_by_t <= ASSIST_WINDOW_TICKS):
                    cogs[vd].assists += 1
                # v9 (GLORY LAW E3): RESCUE -- the victim was RECENTLY
                # menacing one of the killer's OWN TEAMMATES (never the
                # killer's own prior attacker -- that is `dRevengeKill`'s
                # job, a distinct mechanic already priced above). Credits
                # the killer, and pins `rescued_t` on the teammate who was
                # actually in danger.
                if (victim.menacing_t > -10**8 and
                        tick - victim.menacing_t <= RESCUE_WINDOW_TICKS):
                    menaced = victim.menacing_victim
                    if (0 <= menaced < n_slots and menaced != s and
                            team(menaced) == team(s)):
                        killer.rescues += 1
                        cogs[menaced].rescued_t = tick
                # v9 (GLORY LAW E3): SECOND WIND, RE-GATED -- was "heal
                # yourself, then kill inside the window" (self-care); now
                # "get RESCUED (see above), then land a kill of your own
                # inside SECOND_WIND_TICKS." `killer.rescued_t` is read
                # BEFORE this kill's own rescue (if any) could have set it,
                # matching sim.nim's own pre-mutation-snapshot discipline.
                if (killer.rescued_t > -10**8 and
                        tick - killer.rescued_t <= SECOND_WIND_TICKS):
                    killer.second_wind = True
                # v9 (GLORY LAW E3): SQUAD VOLLEY -- record this kill into
                # the killer's team's small recent-kill ring; pins
                # `squad_volley_done[team]` ONCE the ring shows
                # SQUAD_VOLLEY_MIN_DISTINCT+ distinct killers inside
                # SQUAD_VOLLEY_WINDOW_TICKS.
                ring = [e for e in team_kill_ring[team(s)]
                        if tick - e[1] <= SQUAD_VOLLEY_WINDOW_TICKS]
                ring.append((s, tick))
                team_kill_ring[team(s)] = ring
                if not squad_volley_done[team(s)]:
                    if len({killer_idx for killer_idx, _ in ring}) >= \
                            SQUAD_VOLLEY_MIN_DISTINCT:
                        squad_volley_done[team(s)] = True
                # Per-activation, ENEMY-only multikill streak (windowed
                # approximation of an "activation" -- see the module
                # docstring).
                if weapon == "spray":
                    prev_count, prev_tick_s = spray_streak.get(s, (0, -10**9))
                    count = (prev_count + 1
                             if tick - prev_tick_s <= SPRAY_ACTIVATION_WINDOW
                             else 1)
                    spray_streak[s] = (count, tick)
                    if count == 2:
                        killer.spray_multi += 1
                elif weapon == "grenade":
                    grenade_streak[s] = grenade_streak.get(s, 0) + 1
                    if grenade_streak[s] == 2:
                        killer.grenade_multi += 1
                # PRICING -- killDeed's own precedence chain. dRevengeKill/
                # dRunDown cannot be judged offline (victim velocity,
                # killer-of-killer windows); a kill that would have been one
                # falls through to whatever this chain finds next.
                if victim.carrying:
                    deed = "denial" if near_home else "carrier_kill"
                elif victim.lifemax >= ACE_LEVEL:
                    deed = "ace_tag"
                elif same_tick_multi:
                    deed = "splash_multikill"
                elif r is not None and r >= LONGSHOT_PX:
                    deed = "longshot_kill"
                elif r is not None and r <= POINT_BLANK_PX:
                    deed = "point_blank_kill"
                elif escorted:
                    deed = "escort_kill"
                else:
                    deed = {"spray": "spray_kill",
                            "grenade": "grenade_kill"}.get(weapon,
                                                           "honorable_kill")
                mint(team(s), deed, vx, vy)
        elif k == "death":
            t = e.get("source", -1)
            if 0 <= t < n_slots:
                deaths_by_slot[t] += 1  # a life spent; lives-per-cog reads this
                c = cogs[t]
                c.alive = False
                xp_peaks.append(c.peak)
                levels_seen.append(c.lifemax)
                if c.lifemax >= 5:
                    l5_lives += 1
                if c.lifemax >= ACE_LEVEL:
                    l3_lives[team(t)] += 1
                c.carrying = 0
                c.reset_life()
                c.lifemax = 0
        elif k == "respawn":
            s = e.get("source", -1)
            if 0 <= s < n_slots:
                cogs[s].alive = True
        check_achievements(tick)

    # Conclusion-only mint: Clean Sheet (`treeSquad` tier IV, index 3).
    # `satisfied()` never reports ("squad", 3) -- see its comment -- so this
    # is the ONLY site that can claim it, mirroring
    # `evalCleanSheetAtConclusion`'s one-and-only mint site (called once
    # from `finishGame`).
    #
    # v9 (GLORY LAW E4): tier 3 is NOT the FIRST_TIER_ONLY tier (that's
    # index 4, "V") -- Clean Sheet can NEVER race, so this always claims at
    # base price with `first=False`, full stop. The old same-tick-tie
    # `was_untaken` logic is retired with it (there is nothing left to tie
    # for).
    key = ("squad", 3)
    for t in (0, 1):
        clean = all(c.team_kills == 0 for i, c in enumerate(cogs)
                    if team(i) == t)
        if clean and key not in claimed[t]:
            claimed[t].add(key)
            amount = TIER_GLORY[3]
            ach_glory[t] += amount
            glory[t] += amount
            claims[t].append((end_tick, key, False))
            claimed_first.setdefault(key, t)

    # end of episode: surviving cogs' lives count toward the ladder stats
    for i, c in enumerate(cogs):
        xp_peaks.append(c.peak)
        levels_seen.append(c.lifemax)
        if c.lifemax >= 5:
            l5_lives += 1
        if c.lifemax >= ACE_LEVEL:
            l3_lives[team(i)] += 1

    return {
        "glory": glory, "ach_glory": ach_glory, "drama_glory": drama_glory,
        "claims": claims, "deeds": deeds, "heat_ticks": heat_ticks,
        "levels": levels_seen, "l5": l5_lives, "l3": l3_lives,
        "p_l1": (len(reached_l1 & killed_or_stole),
                 len(killed_or_stole)),
        "supply_drops": supply_total, "end_tick": end_tick, "xp_peaks": xp_peaks,
        "deaths_by_slot": deaths_by_slot,
    }


def has_stream_claims(events):
    ## Whether this episode's extraction is new enough to carry glory.nim's
    ## own Achievement/GloryDeed/LevelUp mints directly (c70907d+).
    return any(e.get("kind") in STREAM_KINDS for e in events)


def score_episode_stream(events):
    """Read glory/achievement claims DIRECTLY off the tier-2 event stream
    instead of re-deriving them by walking damage/pickup/kill events through
    this file's OWN hand-copied pricing tables. This is the fix for the
    defect class the whole PERCEPTION audit exists for: a hand mirror can
    drift from glory.nim silently, but an Achievement/GloryDeed row IS
    glory.nim's own mint, verbatim, off the wire -- `killDeed`'s precedence,
    `mintGlory`'s heat/site/carry math, `satisfiedAchievements`'s tier gates,
    ALL already resolved upstream. Only glory/ach_glory/drama_glory/claims/
    deeds come from here -- heat occupancy, xp peaks and the level ladder
    still need the full per-tick walk (xp values and heat embers are never
    on the wire), so `score_episode()` fills those from
    `score_episode_derived()` regardless of which path wins for the rest.

    ⚠️ `deeds` here counts GloryDeed ROWS, not `times` units -- a single
    `dShieldSoak` mint can absorb several hit points in one awardDeed call
    (`times=blocked`), but only one tier-2 row is emitted for it. The
    RE-DERIVATION path counts hp-absorbed instances instead (mirroring
    `deedCounts` exactly), so `shield_soak`'s frequency is not directly
    comparable across the two paths -- everything else is.
    """
    glory = [0, 0]
    ach_glory = [0, 0]
    drama_glory = [0, 0]
    claims = [[], []]
    deeds = collections.Counter()
    for e in events:
        k = e.get("kind")
        if k == "glory_deed":
            t = e.get("target", -1)
            if t not in (0, 1):
                continue
            amount = e.get("amount", 0)
            glory[t] += amount
            key = DEED_ENUM_TO_KEY.get(e.get("weapon", ""))
            if key:
                deeds[key] += 1
                if DEED_DRAMA.get(key, 0) > 0:
                    drama_glory[t] += amount
        elif k == "achievement":
            t = e.get("target", -1)
            if t not in (0, 1):
                continue
            tree_key = TREE_ENUM_TO_KEY.get(e.get("weapon", ""))
            tier = e.get("hp", -1)
            if tree_key is None or tier < 0:
                continue
            amount = e.get("amount", 0)
            first = bool(e.get("blocked", 0))
            glory[t] += amount
            ach_glory[t] += amount
            claims[t].append((e.get("tick", 0), (tree_key, tier), first))
    return {
        "glory": glory, "ach_glory": ach_glory, "drama_glory": drama_glory,
        "claims": claims, "deeds": deeds,
    }


def score_episode(events, n_slots):
    """One episode's full report. Always runs the per-tick RE-DERIVATION
    (`score_episode_derived`) for heat/xp/levels, which the stream never
    carries -- then, wherever the event file has Achievement/GloryDeed/
    LevelUp rows, OVERRIDES the glory/achievement/deed numbers with the
    direct read (`score_episode_stream`), since those are glory.nim's own
    mints and cannot drift the way a re-derivation can. `result["source"]`
    records which path produced the claims/mints half of the report, so
    `main()` can tell you which one actually ran.
    """
    result = score_episode_derived(events, n_slots)
    if has_stream_claims(events):
        stream = score_episode_stream(events)
        result["glory"] = stream["glory"]
        result["ach_glory"] = stream["ach_glory"]
        result["drama_glory"] = stream["drama_glory"]
        result["claims"] = stream["claims"]
        result["deeds"] = stream["deeds"]
        result["source"] = "stream"
    else:
        result["source"] = "derived"
    return result


# multikill same-tick index, built per episode before scoring
events_at = {}


def build_kill_index(events):
    events_at.clear()
    for e in events:
        if e.get("kind") == "kill":
            events_at.setdefault((e.get("tick"), e.get("source")),
                                 []).append(e.get("target"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", type=int, default=400)
    ap.add_argument("--min-version", default="0.7.200")
    args = ap.parse_args()

    # THE STARTUP GUARD. Everything below is worthless if the tables above
    # no longer describe glory.nim -- refuse before doing any work.
    check_glory_version()

    # episode meta: id -> (winner positions, policy per position, version)
    meta = {}
    for rf in glob.glob(f"{CACHE}/rounds/*.json"):
        try:
            eps = json.load(open(rf))
        except Exception:
            continue
        for ep in eps:
            if ep.get("status") != "completed":
                continue
            v = ep.get("coworld_version", "")
            # ⚠️ STRING compare, not numeric: "0.7.95" < "0.7.200" is FALSE in
            # Python (lexical '9' > '2'), so every v0.7.9x episode silently
            # PASSES this filter though it predates v0.7.200 by 100+ builds.
            # Measured effect: the 120-episode field this file scores today
            # is entirely v0.7.95-98. This USED to matter for `item_pickup`
            # events (0 across the whole sample), but GLORY C10's audit found
            # that premise itself was wrong: `item_pickup` is not a
            # `SimEventKind` this engine has EVER carried, at any version --
            # see the retired branch's own comment above -- so a version fix
            # here would not have recovered anything regardless. NOT fixed
            # here: swapping in a numeric (dotted-tuple) compare finds 144
            # real v0.7.207 candidates, but the local scout cache has zero
            # downloaded event files for any of them today -- a numeric fix
            # would print "scoring 0 real episodes", not a better field. Fix
            # belongs with re-fetching the cache at a current version, not
            # with this comparison.
            if v < args.min_version:
                continue
            # 2-TEAM ONLY. The cache mixes 4ffa/4ffa8 episodes, and there
            # team is dealt slot mod 4 -- the mod-2 attribution below would
            # silently scramble every per-team number (the exact bug that
            # once made half our agents statues: a wrong team formula fails
            # quietly, never loudly).
            if "default" not in (ep.get("variant_name") or "").lower():
                continue
            parts = ep.get("participants") or []
            scores = {s["policy_version_id"]: s["score"]
                      for s in (ep.get("scores") or [])}
            slot_policy = {}
            for p in parts:
                slot_policy[p["position"]] = (p.get("policy_name") or "?",
                                              p.get("is_filler", False))
            # winner team: the team whose policies scored +1
            win_team = None
            for p in parts:
                sc = scores.get(p["policy_version_id"])
                if sc is not None and sc > 0:
                    win_team = p["position"] % 2
                    break
            # The events/replay cache files are named by the REPLAY uuid
            # from replay_url, not by episode_id -- joining on episode_id
            # matches zero files and the run silently scores nothing.
            url = ep.get("replay_url") or ""
            if "/replays/" not in url:
                continue
            rid = url.rsplit("/", 1)[-1].split(".")[0]
            meta[rid] = (win_team, slot_policy, v)

    files = []
    for f in glob.glob(f"{CACHE}/events/*.jsonl"):
        eid = os.path.basename(f)[:-6]
        if eid in meta and os.path.getsize(f) > 10000:
            files.append((os.path.getmtime(f), f, eid))
    files.sort(reverse=True)
    files = files[:args.episodes]
    print(f"scoring {len(files)} real episodes "
          f"(cache {len(meta)} attributed, glory v{GLORY_VERSION})")

    agg = collections.defaultdict(list)
    deeds_all = collections.Counter()
    claims_per_team = []
    tier_hist = collections.Counter()
    first_claim_ticks = []
    heat_occ = collections.Counter()
    heat_total = 0
    winner_glory, loser_glory = [], []
    winner_claims, loser_claims = [], []
    winner_ach_share = []
    l3_per_team, l5_per_ep = [], []
    levels_all = []
    p_l1_num = p_l1_den = 0
    supply_drops_all = []
    xp_all = []
    by_policy = collections.defaultdict(lambda: collections.defaultdict(list))
    tree_tier_claims = collections.Counter()   # (tree, tier) -> claims
    n_team_eps = 0                             # denominator: one row per (episode, team)
    winner_claims_lo, loser_claims_lo = [], []  # T1-T2 claims/ep
    winner_claims_hi, loser_claims_hi = [], []  # T3-T5 claims/ep
    episode_records = []                       # wipe-inference input
    sources = collections.Counter()            # extension 4: stream vs derived

    for _, f, eid in files:
        win_team, slot_policy, ver = meta[eid]
        events = []
        for l in open(f):
            try:
                events.append(json.loads(l))
            except Exception:
                pass
        if not events:
            continue
        n_slots = max((max(e.get("source", -1), e.get("target", -1))
                       for e in events), default=-1) + 1
        if n_slots < 2:
            continue
        r = score_episode(events, n_slots)
        sources[r["source"]] += 1

        deeds_all.update(r["deeds"])
        for t in (0, 1):
            n_team_eps += 1
            claims_per_team.append(len(r["claims"][t]))
            for tick, key, first in r["claims"][t]:
                tier_hist[key[1] + 1] += 1
                tree_tier_claims[key] += 1
            if r["claims"][t]:
                first_claim_ticks.append(r["claims"][t][0][0])
            for mult, ticks in r["heat_ticks"][t].items():
                heat_occ[mult] += ticks
                heat_total += ticks
        if win_team is not None:
            winner_glory.append(r["glory"][win_team])
            loser_glory.append(r["glory"][1 - win_team])
            winner_claims.append(len(r["claims"][win_team]))
            loser_claims.append(len(r["claims"][1 - win_team]))
            if r["glory"][win_team] > 0:
                winner_ach_share.append(
                    100 * r["ach_glory"][win_team] / r["glory"][win_team])
            # T1-T2 (tier index 0-1) is a single-condition "touched the kit"
            # claim; T3-T5 (index 2-4) needs a multi-event or cross-stat
            # condition. If the pooled gap lives entirely in T1-T2, the
            # curriculum is measuring who plays MORE, not who plays BETTER.
            lo = lambda t: sum(1 for _, k, _ in r["claims"][t] if k[1] <= 1)
            hi = lambda t: sum(1 for _, k, _ in r["claims"][t] if k[1] >= 2)
            winner_claims_lo.append(lo(win_team))
            loser_claims_lo.append(lo(1 - win_team))
            winner_claims_hi.append(hi(win_team))
            loser_claims_hi.append(hi(1 - win_team))
            # wipe-inference input: "lives-per-cog" is a SAMPLE-WIDE constant
            # (the max deaths ever seen on one slot) -- can't be known until
            # every episode in the run has been read once. Only needed for
            # `source == "derived"` episodes; a "stream" episode's glory
            # already carries any real dWipe mint verbatim.
            episode_records.append({
                "win_team": win_team,
                "glory": list(r["glory"]),
                "ach_glory": list(r["ach_glory"]),
                "captures": r["deeds"].get("capture", 0),
                "deaths_by_slot": r["deaths_by_slot"],
                "n_slots": n_slots,
                "source": r["source"],
            })
            # per-policy attribution (team-level: the policies seated on it)
            for t in (0, 1):
                names = {slot_policy.get(p, ("?", False))[0]
                         for p in range(t, n_slots, 2)
                         if not slot_policy.get(p, ("?", True))[1]}
                for name in names:
                    by_policy[name]["glory"].append(r["glory"][t])
                    by_policy[name]["claims"].append(len(r["claims"][t]))
                    by_policy[name]["won"].append(1 if t == win_team else 0)
        l3_per_team.extend(r["l3"])
        l5_per_ep.append(r["l5"])
        levels_all.extend(r["levels"])
        n, d = r["p_l1"]
        p_l1_num += n
        p_l1_den += d
        supply_drops_all.append(sum(r["supply_drops"]))
        xp_all.extend(r["xp_peaks"])

    # ── WIPE MINTING (re-derivation fallback only) ──────────────────────
    # glory.nim's dWipe (400 glory) mints in-engine since fd6b4ce and is
    # visible directly on the tier-2 stream (a GloryDeed row, weapon="dWipe")
    # wherever that stream is present -- those episodes need no correction,
    # `r["glory"]` already has it. The RE-DERIVATION path has no "team
    # eliminated" tier-2 event kind to read, so it is under-counted by 400 on
    # every wipe-ended, stream-less episode unless inferred from the death
    # ledger. Captures run low (see DEEDS below) -- most winners never fire a
    # single capture event, so they won by wipe or by clock, and only the
    # death ledger tells the two apart.
    #
    # "lives-per-cog" is not in the event stream either, so it is INFERRED,
    # not read: this era runs multiple lives per cog and a slot stops
    # respawning once they're gone, so the LARGEST death count ever seen on
    # any one slot, across the whole sample, is the best available estimate
    # of the true lives-per-cog constant. It is a lower bound in principle
    # (an undercount if no cog in the sample ever fully exhausted its lives)
    # -- labelled here, not asserted as a config read.
    lives_per_cog = 0
    for rec in episode_records:
        if rec["source"] == "derived" and rec["deaths_by_slot"]:
            lives_per_cog = max(lives_per_cog,
                                 max(rec["deaths_by_slot"].values()))

    wipe_eps = time_eps = stream_eps = 0
    winner_glory_wc, winner_ach_share_wc = [], []
    for rec in episode_records:
        w = rec["win_team"]
        g = rec["glory"][w]
        if rec["source"] == "stream":
            # Already causal and verbatim -- applying the inference below
            # would DOUBLE-PAY any real dWipe mint this episode has.
            stream_eps += 1
        elif rec["captures"] == 0 and lives_per_cog > 0:
            team_size = rec["n_slots"] // 2
            losers = 1 - w
            losing_deaths = sum(v for slot, v in rec["deaths_by_slot"].items()
                                 if slot % 2 == losers)
            # every cog on the losing team spent every life it had -> wipe.
            # short of that with zero captures -> the clock ran out.
            if team_size > 0 and losing_deaths >= lives_per_cog * team_size:
                g += DEED_GLORY["wipe"]  # the mint the fallback was missing
                deeds_all["wipe"] += 1
                wipe_eps += 1
            else:
                time_eps += 1
        winner_glory_wc.append(g)
        if g > 0:
            winner_ach_share_wc.append(100 * rec["ach_glory"][w] / g)

    def med(xs):
        return statistics.median(xs) if xs else 0

    print("\n════════ THE CALIBRATION READ ════════\n")

    print("MIRROR PATH  (per episode: read straight off Achievement/"
          "GloryDeed/LevelUp rows when the extraction has them, else "
          "re-derived by walking damage/kill/pickup events through this "
          "file's own pricing copy -- see the module docstring)")
    print(f"  stream (direct read):   {sources.get('stream', 0)}")
    print(f"  derived (re-simulated): {sources.get('derived', 0)}")
    if sources.get("stream", 0) == 0:
        print(f"  -- 0 stream episodes: {CACHE} predates Achievement/"
              f"GloryDeed/LevelUp (extract_events commit c70907d). Every "
              f"number below is RE-DERIVED. Rebuild the scout extractor and "
              f"re-run scout.py to bring the direct-read path online.")

    active = sorted(x for x in xp_all if x > 0)
    if active:
        pct = lambda q: active[min(len(active)-1, int(q*len(active)))]
        print("\nXP PEAKS PER LIFE (active lives only, for threshold tuning)")
        print("  " + "  ".join(f"p{int(q*100)}:{pct(q)}"
                               for q in (.25,.5,.75,.9,.95,.98,.99)))
        print(f"  active lives: {len(active)} of {len(xp_all)}\n")
    lv = collections.Counter(levels_all)
    total_lives = max(1, len(levels_all))
    print("LEVELS  (target: L1|active~0.9, L3+ 1-2/team/ep, L5 <=1-2/ep)")
    print(f"  max level per life: " + "  ".join(
        f"L{l}:{100*lv.get(l,0)//total_lives}%" for l in range(6)))
    print(f"  P(L1+ | cog killed or stole): "
          f"{p_l1_num}/{p_l1_den} = "
          f"{p_l1_num/max(1,p_l1_den):.2f}")
    print(f"  L3+ lives per team-episode: {med(l3_per_team):.1f} median "
          f"(mean {statistics.mean(l3_per_team):.2f})")
    print(f"  L5 lives per episode:       {med(l5_per_ep):.1f} median "
          f"(mean {statistics.mean(l5_per_ep):.2f})")

    print("\nACHIEVEMENTS  (out of 40/team)")
    print(f"  claims/team/episode: median {med(claims_per_team):.0f}, "
          f"mean {statistics.mean(claims_per_team):.1f}, "
          f"p90 {sorted(claims_per_team)[int(.9*len(claims_per_team))]}")
    print(f"  tier histogram: " + "  ".join(
        f"T{t}:{tier_hist.get(t,0)}" for t in range(1, 6)))
    print(f"  first claim at tick: median {med(first_claim_ticks):.0f}")
    print(f"  DISCRIMINATION -- winners {statistics.mean(winner_claims):.1f} "
          f"vs losers {statistics.mean(loser_claims):.1f} claims/ep")
    print(f"    T1-T2 (mechanics)       winners "
          f"{statistics.mean(winner_claims_lo):.1f} vs losers "
          f"{statistics.mean(loser_claims_lo):.1f} claims/ep")
    print(f"    T3-T5 (tactics/mastery) winners "
          f"{statistics.mean(winner_claims_hi):.1f} vs losers "
          f"{statistics.mean(loser_claims_hi):.1f} claims/ep")

    print("\nPER-TREE RUNG ORDER  (claim rate = claims / team-episodes; "
          "tier I should be the ceiling, tier V the floor)")
    tree_order = [("gun", "gun"), ("spray", "spray"), ("nade", "grenade"),
                  ("shield", "shield"), ("med", "medkit"),
                  ("carrier", "carrier"), ("defender", "defender"),
                  ("squad", "squad")]
    print(f"  {'tree':<10}" + "".join(f"{'T'+str(i+1):>8}" for i in range(5))
          + "   inversions")
    total_inversions = 0
    for key, label in tree_order:
        rates = [100 * tree_tier_claims.get((key, tier), 0) / max(1, n_team_eps)
                  for tier in range(5)]
        # flag every (lower tier, higher tier) pair where the HIGHER tier
        # claims MORE often -- the curriculum promises tier V is rarer than
        # tier I, and this is the check that catches it when it isn't.
        pairs = [(i, j) for i in range(5) for j in range(i + 1, 5)
                 if rates[j] > rates[i]]
        total_inversions += len(pairs)
        flag = ",".join(f"T{i+1}<T{j+1}" for i, j in pairs) or "-"
        print(f"  {label:<10}" + "".join(f"{r:7.1f}%" for r in rates)
              + f"   {flag}")
    print(f"  {total_inversions} inverted tier-pair(s) across "
          f"{len(tree_order)} trees x 5 tiers")
    print("  caveat (v3+): no tier below reads a pickup/possession flag any"
          " more (law 2b), so an inversion here is a real curriculum signal,"
          " not the v2-era item_pickup version artifact this comment used to"
          " warn about. `carrier`/`defender` T4 (Uphill/Turnaround) now read"
          " LIVE alive-counts and peel->steal ordering reconstructed from"
          " death/respawn/kill/flag_steal rows -- an approximation (see the"
          " module docstring), no longer the unimplemented gap the v2 mirror"
          " flagged with \"tracked by caller\".")

    print("\nSWEEP BUDGET  (calibrates AchievementSweepBudgetPct, shipped=15)")
    print(f"  median WINNER episode glory: {med(winner_glory):.0f}")
    print(f"  achievement share of winner glory: "
          f"median {med(winner_ach_share):.1f}%")
    full_sweep = sum(TIER_GLORY) * 8
    print(f"  full-sweep base ({full_sweep}) as % of median winner: "
          f"{100*full_sweep/max(1,med(winner_glory)):.1f}%")

    print("\nSWEEP BUDGET, WIPE-CORRECTED  (dWipe minted where the death "
          "ledger says the loser burned every life it had -- derived-path "
          "episodes only; stream-path episodes already carry it)")
    print(f"  inferred lives-per-cog (max deaths on any one slot, "
          f"derived-path sample): {lives_per_cog}")
    zero_cap_eps = wipe_eps + time_eps
    print(f"  zero-capture endings: {wipe_eps} classified WIPE, {time_eps} "
          f"classified TIME, {stream_eps} read directly off the stream (of "
          f"{zero_cap_eps + stream_eps} decided episodes, "
          f"{len(episode_records)} decided episodes total)")
    print(f"  median WINNER episode glory: {med(winner_glory_wc):.0f} "
          f"(was {med(winner_glory):.0f} before the wipe mint)")
    print(f"  achievement share of winner glory: median "
          f"{med(winner_ach_share_wc):.1f}% "
          f"(was {med(winner_ach_share):.1f}%)")
    recommended_pct = 100 * full_sweep / max(1, med(winner_glory_wc))
    print(f"  full-sweep base ({full_sweep}) as % of wipe-corrected median "
          f"winner: {recommended_pct:.1f}%")
    print(f"  RECOMMENDED AchievementSweepBudgetPct: "
          f"{max(1, math.ceil(recommended_pct))}  (shipped=15; "
          f"tests/test_glory.nim only asserts the derived form -- this is "
          f"the number the strict, denominator-based gate should use)")

    print("\nHEAT  (occupancy of playing time; Muster's scar = pinned at max)")
    for m in (1, 2, 4, 8):
        print(f"  x{m}: {100*heat_occ.get(m,0)//max(1,heat_total)}%")

    print("\nGLORY vs WINNING")
    print(f"  winner median {med(winner_glory):.0f}  "
          f"loser median {med(loser_glory):.0f}  "
          f"ratio {med(winner_glory)/max(1,med(loser_glory)):.2f}")
    both = [(w, l) for w, l in zip(winner_glory, loser_glory)]
    inv = sum(1 for w, l in both if l >= w)
    print(f"  loser out-glories winner in {100*inv//max(1,len(both))}% "
          f"of episodes")

    print(f"\nSUPPLY DROPS per episode: median {med(supply_drops_all):.0f}, "
          f"mean {statistics.mean(supply_drops_all):.2f} (cap {SUPPLY_MAX}/cog-life)")

    print("\nDEEDS (per episode averages)")
    n_eps = max(1, len(files))
    for deed, n in deeds_all.most_common(20):
        print(f"  {deed:<18} {n/n_eps:6.2f}")

    print("\nBY POLICY  (teams containing the policy; non-filler seats)")
    rows = []
    for name, d in by_policy.items():
        if len(d["glory"]) < 8:
            continue
        rows.append((name, len(d["glory"]),
                     statistics.mean(d["won"]),
                     statistics.mean(d["glory"]),
                     statistics.mean(d["claims"])))
    rows.sort(key=lambda r: -r[3])
    print(f"  {'policy':<32} {'eps':>4} {'win%':>5} {'glory/ep':>9} "
          f"{'claims/ep':>9}")
    for name, n, won, g, c in rows[:14]:
        print(f"  {name:<32} {n:>4} {100*won:>4.0f}% {g:>9.0f} {c:>9.1f}")


if __name__ == "__main__":
    main()
