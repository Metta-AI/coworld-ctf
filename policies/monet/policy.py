#!/usr/bin/env python3
"""MONET: the house test policy. Field-reading, duo-tight, political.

Fourth persona on the starter seam and the painter after Picasso. The three
starters each embody one instinct; MONET carries the measured doctrine of the
whole research program, translated to the play-calling layer:

* the summary carries BOTH the partner's state and the kill feed (the two
  observables the doctrine actually keys on),
* four model turns spread across the match arc (opening / consolidation /
  mid / endgame) instead of a burst of early re-calls,
* ``adjust_entries`` enforces the non-negotiables structurally: FIRE
  DISCIPLINE -- the duo partner (own team) is on the never-list whether or
  not the model remembered (a partner tag is -60g). GV59 (engine tree decb97fd,
  live build 0.7.347+; sim.nim downFriendly ~2580-2601) repriced
  a pact-ally tag onto the SAME -60g dTeamKill class as a partner tag --
  previously an honorable kill; that repricing is unaffected by v55 below,
  and still fully prices any pact-ally tag whether or not target_law holds
  it off. TRUCE HONOR -- the old structural mirror of every pact's
  partners into every target_law never-list -- is DROPPED as of v55 (GV17
  ace/pact read, n=63: 25/63 formed pacts paid ~nothing -- dJointAct
  0.08/formed-ep, dAssist/dRescue 0 field-wide, median glory identical --
  while the unconditional never-target hold on the 36 confirmed partner
  relationships cost ~0.56 forgone tags/ep, 2x our realized kill rate:
  0/36 partners ever engaged, 0/36 ever tagged us [the betrayal risk the
  hold existed to avoid never materialized], 35/36 died anyway to someone
  else). ``CONFIRMED_PACT_REASONS`` is now empty, so no pact partner ever
  reaches target_law.never. Pacts are still declared, re-affirmed on
  kickoff/final4/maintenance, capped at 5, and `onBetrayal: returnFire`
  still answers an actual betrayal in kind -- only the standing,
  full-episode hold-fire guarantee is gone; targets among live pact
  partners are now chosen on merit like any other seat, weighing the
  still-live dTeamKill price of tagging one. CONVERSION -- a supply_run
  rung is guaranteed in every ladder, because the lineage's oldest
  measured failure is winning the fight and never banking the life,
* ``extra_summary`` appends a one-line AWARENESS digest to every model turn:
  ring in/out + shrink clock, partner state (hp TREND across turns, falling
  hp attributed UNDER FIRE vs zone-burning by rect), fresh-vs-stale threat
  census with nearest bearing, incoming fire, near items -- numbers, not
  prose, because summary tokens are sidecar cost.
"""

from __future__ import annotations

import math
import pathlib
import re
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "starters" / "common"))

import starter_harness  # noqa: E402
from starter_harness import Persona  # noqa: E402

# Duo fields pair seat k with k+teamCount and team is k % teamCount; see
# _neighbor_duo below for how teamCount is now derived (OBSERVED per call,
# never a fixed divisor -- the field has flipped shape seven times in 72
# hours and 16 was never safe to assume even before that).

# The guaranteed conversion rung. hp is a small absolute number on this
# engine (a bodyguard peels at 2-3). Manifest max hp moved 3->4 at build
# 0.7.348 (PR #439, "TTK arm E"); whenHpBelow is view.self.hp <
# params.whenHpBelow (play_sdk/reference/supply_run.nim:50), a pure
# self-hp resupply gate -- re-anchored 3->4 here so a seat still detours
# to supply after ONE marker under the new max, not two.
SUPPLY_DEFAULTS = {"whenHpBelow": 4, "detourMax": 300, "contested": "avoid"}
# NOTE: SUPPLY_DEFAULTS only feeds the "insert if the model omitted
# supply_run entirely" rung below and the offline canned turns -- it never
# touched a supply_run entry the model DID submit. Measured 2026-09-08:
# whenHpBelow read 4 in only 12/55 (21.8%) live installs, because plays.py's
# manifest still states "default 3" (the pre-0.7.348, hp-max-3 value) to the
# model. adjust_entries below now actively clamps whenHpBelow on every
# submitted supply_run entry to this same 4, same fix class as
# FIRE_SUPERIORITY_PRESS_RANGE/FIRE_SUPERIORITY_FINISH_RANGE above.

# The guaranteed armament rung. self.hasGun/hasHopper are never exposed to
# a policy (only the human broadcast HUD sees them), so this cannot gate on
# "am I armed" -- it is the same blind loot the three starters already run
# unconditionally, never fighting anyone for it (medkits stay off; that
# family is supply_run's job).
LOOT_DEFAULTS = {"detourMax": 400, "contested": "avoid"}

# A pact with no partners is dropped by the generic repair BEFORE the hook
# runs (partners is required), so a canned pact carries team 0's duo as a
# placeholder that survives cleaning; adjust_entries re-aims it at the
# actual neighboring duo. Also re-aimed: any pact naming our own duo (which
# includes the placeholder when we ARE team 0).
PACT_PLACEHOLDER = {"seat:0", "seat:16"}

# v46 field-measured fix (n=84, score-ratio 0.76 [0.67,1.17] vs v44's 1.00
# while pact FORMED sits at 2%): the never-target mirror below used to
# treat every SOLO partner the same, including unilateral FALLBACK/RETRY
# picks -- 2 nearest live rivals WE chose with zero evidence they want a
# pact with us. That silently held our own fire on rivals who keep
# shooting us, for the entire episode, on a guess. v46 narrowed the
# no-fire guarantee to only a seat that had actually named US back in chat
# ("invited"/"reciprocate"), leaving fallback/retry named on the wire (so a
# genuine mutual sim pact could still form) but off target_law.never.
#
# v55 (GV17 ace/pact economy read, n=63 episodes, `ACE_PACT.md` Q2):
# narrowing wasn't enough -- even the strictest tier, mutually FORMED
# pacts, still doesn't pay. 25/63 formed pacts produced 36 distinct
# (episode, confirmed-partner) relationships; we held fire on 36/36 (100%)
# and it bought nothing measurable (dJointAct 0.08/formed-ep, dAssist/
# dRescue 0 field-wide, median final_glory identical to no-pact episodes)
# while it cost real kills: 0/36 partners were ever engaged, 0/36 ever
# tagged us back (the betrayal risk the hold exists to prevent never
# materialized in this window), and 35/36 (97%) died anyway to some OTHER
# seat -- 35 kills' worth of glory over 63 episodes (~0.56/ep, ~2x our
# realized ~0.24 dHonorableKill/ep baseline) forgone for partners who were
# never going to survive our restraint regardless. Emptying this set drops
# every pact partner out of target_law.never -- `onBetrayal: returnFire`
# still does the defensive job the hold was protecting, at zero measured
# cost, without the 0.56 tags/ep the unconditional hold was giving away.
# Pact declare/reciprocate/cap/re-emit mechanics below are UNCHANGED.
CONFIRMED_PACT_REASONS = frozenset()

# v47b (owner direction 2026-09-09): more FORMED pacts is the lever for more
# JointAct / pact-stack / revive opportunities (GV15 made JointAct pact-only
# -- see doctrine ledger ctf-joint-action-pays-without-a-pact.md, OBSOLETE at
# GV15). Raising the partner cap 3 -> 5 does not by itself remove more
# targets from fire: it is a pure pact-formation/declaration lever, wholly
# separate from CONFIRMED_PACT_REASONS above (v55: empty, so ZERO partners
# of any reason ever reach target_law.never, no matter how high this cap
# goes). Checked for a lower
# limiter before picking 5: src/ctf/sim.nim declarePactPartners
# (~lines 915-969) encodes partners as a uint16 BITMASK over the Team enum
# (sim_types.nim Team, TeamPoolWidth=16) -- no numeric per-declaration cap
# in the engine itself, bounded only by team count (up to 15 rivals).
# policies/starters/common/plays.py's "pact" play schema caps
# partners at max_items=8 -- also >= 5. Neither src-side limiter sits below
# 5, so 5 is used as directed. Schema-default-creep lesson (doctrine
# ledger ctf-schema-default-creep-press-range.md): plays.py's max_items=8
# is looser than our house number, so a genuine model submission could
# legally carry 6-8 raw seats -- this house cap is enforced explicitly in
# adjust_entries below, never left to the model or to the wire schema
# alone.
PACT_PARTNER_CAP = 5


def _seat_num(ref):
    """'seat:7' -> 7, else None."""
    if not isinstance(ref, str) or not ref.startswith("seat:"):
        return None
    digits = ref.split(":", 1)[1]
    return int(digits) if digits.isdigit() else None

# Formation floors: below these the duo is stacked and tags itself.
MIN_LEASH = 100
MIN_SPACING = 120

# COMBAT-CLOSE floor (measured revive protocol, 28 leader tag-backs: revives
# succeed when the duo is ALREADY within ~40px at the down -- 27/28
# zero-travel, median separation 0-15px, successes cluster under 100px).
# MIN_LEASH's 100px anti-stack floor is right for a quiet field but too
# loose to land inside that window once a fight (or a wounded/downed
# partner) is live. This is a SECOND, narrower floor for the entry_id
# "shield-close" rung only -- applying MIN_LEASH here instead would invert
# the deliberately tighter band (max(leash[0], 100) drags a [40,120] pair
# back up to [100,120]), which is exactly the generic-sorter trap this
# floor exists to avoid. Held at 40, not the literal 20px stacking floor:
# fire_superiority's withinFireCone exclusion (a0854837) only screens OUR
# OWN press-target choice, not a stranger partner's fire, so closer
# spacing still raises cluster-fire exposure -- 40 is the value this lane
# can defend (inside the <100px success cluster, clear margin off the
# literal stack floor) over the more aggressive [20,100] the measured data
# would also support.
MIN_LEASH_COMBAT = 40

# The bodyguard two-entry split, MECHANICAL now, not prose (v15). v14's
# prompt DIRECTED the model to submit two literal entries -- "shield-close"
# (leash [40,120]) and "shield" (leash [100,150]). Measured on the v14
# qualification episode (b6798f78, 2026-09-04): across 52 bodyguard
# call-entries from 15 agents, entry ids were `ride` 37, `shield-close` 10,
# `shield` 3, `spring` 2 -- the directed pair landed barely a quarter of the
# time, and where the model self-named instead (`ride` dominant), the band
# it chose WIDENED to [110,280] (v13 was [110,150]) -- drifting away from
# combat-close, not converging on it. Prompt escalation is diminishing
# returns; adjust_entries below (see _normalize_bodyguard) now enforces the
# split structurally, the same way it already enforces truce honor and fire
# discipline: whatever the model calls bodyguard, however it names it,
# however many entries it sends, only these two canonical ids ever exist
# from here on -- never a third, never a self-named survivor. That pair is
# the WANTED ladder, not the wire: gate_open (starter_harness.py) keeps
# "shield-close" and "shield" mutually exclusive by construction, so a
# single call carries at most one live band, never both at once.
BODYGUARD_LEASH = {"shield-close": [MIN_LEASH_COMBAT, 120],
                    "shield": [MIN_LEASH, 150]}

# Jackal doctrine: leave with the profit. A second tag is allowed, a third
# is greed the attrition ledger punishes.
JACKAL_MAX_KILLS = 2

# JOINACT WIRE FIX (measured 2026-09-07, ladder rounds 4344-4362, wire_commit
# read of the COMMITTED 0xA1 line, n=46 non-truncated F4-crossing finalist
# samples): joinWhen=bothWeakened IS live (39/46 at crossing, 41/46 ever in
# the F4 window) because play_notes["jackal"] below names it explicitly by
# value ("joinWhen bothWeakened") -- the model reliably reproduces a value
# it is actually told. earshot's v10 RE-ARM (450->550, see the consolidation/
# mid canned_turns entries and their comments) was NEVER stated in
# play_notes/system_prompt.md, only in this file's canned_turns dict and
# code comments -- pure prose the live (non-canned) bedrock-backed policy
# never reads. Measured result: earshot committed live reads exactly 500
# (the jackal manifest's own schema default) in 44/46 samples, 550 in
# 0/46. adjust_entries below now ENFORCES the floor and the join-timing
# value on every jackal entry the model submits, and installs one with
# these values when the model/turn omits jackal entirely (mirroring the
# supply_run/loot auto-insert pattern and the marquee-window
# fire_superiority override already in this function) -- a wire mechanism,
# not a prompt hint that can silently go unread.
JACKAL_MIN_EARSHOT = 550
JACKAL_JOIN_WHEN = "bothWeakened"

# FIRE_SUPERIORITY WIRE FIX (bug hunt 2026-09-08, ladder round 4457, 30
# fresh policy logs decoded on the server-COMMITTED 0xA1 line, n=102
# installs/22 episodes): pressRange never reached the wire at ITS DOCTRINE
# AT THE TIME -- 220 (the raw plays.py schema default) landed 102/102
# instead of the then-doctrine 400/340 -- and finishRange's endgame
# tightening (140->120) was 0/102. Same root cause as JACKAL_MIN_EARSHOT
# above: plays.py's playbook_brief states the schema default in the
# model's own system prompt and the model reliably reproduces it; nothing
# in adjust_entries clamped fire_superiority the way jackal's
# earshot/joinWhen already were. v42 shipped a clamp enforcing 400/340 and
# was rolled back after a ladder read: score-ratio 1.20->0.67 (p=.0009),
# trade rate 18->30% -- the wider press band bought more exposure to
# third seats, not more finishes. v44 keeps the clamp mechanism (never
# trust the model to reproduce a value correctly) but repoints pressRange
# doctrine at the value that was already living on the wire, 220, in
# every phase: the accidental default becomes the deliberate, pinned
# doctrine, so it cannot drift upward again either. finishRange doctrine
# is unchanged (140 default, 120 endgame) -- that lever's ladder read was
# never implicated. Phase is read from the live zone clock, not a turn
# index (_in_marquee_zone_window, the same predicate the MARQUEE CLOCK
# BAND block below already uses for woundedPct); the clamp still
# collapses to two buckets, endgame and everything else, even though
# pressRange no longer differs between them, so a future doctrine split
# only needs a constant change, not a new branch.
FIRE_SUPERIORITY_PRESS_RANGE = {"default": 220, "endgame": 220}
FIRE_SUPERIORITY_FINISH_RANGE = {"default": 140, "endgame": 120}

# FIRE_SUPERIORITY ENGAGE_DIST WIRE FIX (v53, GloryVersion 17 economy read,
# /tmp/monet_gv17_econ/GV17_ECONOMY.md, n=63 paired same-lobby episodes vs
# docxology/softmaxclaudius-t2/pawchuck): under GV17's catalog-v3 re-price
# (dHonorableKill x2.2, dLongshotKill x6, dAceTag x9, placement lumps
# dFinal8/dFinal4 zeroed) the paired gap is engagement VOLUME, not range --
# our shots_fired/episode (2.38) is under half docxology's (5.04) and our
# longshot-tag rate (1.6% of episodes) trails docxology's (10.7%) 6x, while
# our own mean first-shot distance (707) and max shot distance (827)
# already match or exceed every leader's. engageDist (the fresh-enemy-track
# radius that counts as "a live gun" for fire_superiority's press/break
# arithmetic, plays/fire_superiority.nim's `ally`/target-count branch) sat
# at the schema default of 600 -- BELOW our own average engagement range --
# so a real fraction of engagements we are geometrically capable of reached
# were structurally ungated before fire_superiority ever counted them.
# Raised to 750 (just under our observed 707-827 mean/max shot-distance
# band) in BOTH phase buckets, same "doctrine, not schema drift" pin class
# as FIRE_SUPERIORITY_PRESS_RANGE above: pressRange (220/220) and
# finishRange (140/120) are UNCHANGED by this change -- this is the
# activation gate, not the press-vs-finish bands, and v42's press-range
# rollback (wider 400/340 traded away score-ratio under the pre-GV17
# economy) is a different lever, left alone (one lever at a time).
FIRE_SUPERIORITY_ENGAGE_DIST = {"default": 750, "endgame": 750}

# FINAL FOUR (F4) DETOUR CEILING (F4 initiative, /tmp/monet_f4_0909/
# F4_INITIATIVE.md, pooled v45+v46 n=202 GV15-era episodes): once caught
# first at F4, Monet dies inside 5s 88.9% of the time vs 16.7% when it fires
# first, and engaged-first share collapsed 54%->33% post-GV15. The
# separator is play SELECTION, not fire_superiority's numbers (pressRange/
# engageDist are flat between the two groups): the last-committed play was
# `loot` in 53% of caught-first cases vs 28% of fired-first ones -- an
# ambush-while-looting pattern. 150 is not a new number: it is the SAME
# doctrine value the endgame canned turn's most-aggressive supply_run rung
# already ships (see the "bank" rung's params a few hundred lines below,
# `detourMax: 150`) -- reused here, not invented, so a wandering loot/
# supply detour is capped the instant only 4 teams remain, on every
# SUBMITTED entry (model or canned), not just the canned endgame turn.
FINAL4_DETOUR_MAX = 150
# The engine's own placement ladder prices dFinal4 at exactly this boundary
# (glory.nim RecutClassTable's 8/4/2-teams-left trio; see system_prompt.md
# and selfcheck.py's placement-trio checks) -- "final four" already means
# "<=4 teams alive" to the engine, so this mirrors it rather than inventing
# a new threshold.
FINAL4_TEAM_THRESHOLD = 4

# HEAT-CHAIN TARGET PRIORITY (owner directive 2026-09-06, source-verified
# against src/ctf/glory.nim + play_sdk/reference/target_law.nim): heat is
# the one scaling axis still unexploited by the whole field. +1 ember per
# heat-paying deed (ALL FOUR commons tag types pay heat even though they
# price at class 1 alone), ladder [1,2,4,8], multiplier SAMPLED BEFORE the
# deed's own increment, so a chain only starts paying from its 3rd tag.
#   LIVE (GV56, coworld 0.7.341): thresholds [2,5,10], decay -2 embers per
#   45 ticks = 1.875s -- effectively unreachable, 99.5% of mints land 1x.
#   MAIN, not yet deployed (GV57): thresholds [1,2,4], decay -2 per 270
#   ticks = 11.25s -- a 5-tag chain inside 11.25s gaps pays
#   1x2x4x4x8 = 256x. Ticks run 24/s in both eras.
# These figures live HERE, not in system_prompt.md: no PlayContext/PlayView
# field surfaces a game/coworld version to a policy (checked every wire
# schema under src/shell/schemas/ -- none carries one), so a policy cannot
# detect the cutover and a prompt sentence naming "1.875s" goes silently
# wrong the moment GV57 ships. The prompt says "land the next tag while the
# streak is still hot" instead -- true under either constant set.
#
# combat_policy's closed schema (src/shell/schemas/combat_policy.schema.json)
# has no field for timing, chains, or heat at all. The only lever it gives
# over target CHOICE is target_law's `prefer`: an ORDERED tie-break among
# currently-tracked candidates (weakened/isolated/revenge/bounty), compared
# index-by-index BEFORE base engagement score
# (src/shell/body.nim:compareScoredCombat) -- so whichever tag ranks first
# decides who we shoot whenever more than one candidate is live, including
# the reacquisition moment right after a kill, which is exactly when chain
# speed is decided. "weakened" (lowest known hp) is the only one of the
# four tags that is itself a proxy for "fastest to finish"; ranking it
# first means we close out an already-damaged target NOW instead of
# pivoting onto a full-health "better" (revenge/bounty) one and losing the
# gap. This is the closest the closed vocabulary can express "sequencing
# beats selection" -- it cannot say "chain" or "heat" or a tick figure at
# all, and reordering it does not touch WHEN we fire (hold_fire is never
# set here, so target_law never withholds a shot waiting for a preferred
# tag either).
TARGET_LAW_PREFER = ("weakened", "revenge", "bounty", "isolated")

# Awareness digest: a track older than this is a memory, not a threat (the
# harness's own 10-s freshness/aggressor window). An item further than
# NEAR_ITEM_PX is a detour, not "near".
FRESH_TICKS = 240
NEAR_ITEM_PX = 500

# T22 (IMPROVE-QUEUE #3, SOURCE-VERIFIED against origin/main ac1d5f91,
# coworld 0.7.337): the exact clock band the ENGINE mints ClosingTime/
# LastLight on -- not "the endgame canned turn", a ~30s-cadence GUESS at
# when the ring gets there. `killDeed`'s marquee band (src/ctf/sim.nim
# ~2751-2779, GLORY v13, armed by `gloryMultiplierRecut` -- ARMED on the
# live battle-royale-s2 flagship, coworld_manifest_paintbot.json) reads
# `recutZonePhase` (src/ctf/glory.nim ~2484): `final` is true for the
# WHOLE last authored zone phase -- its wait, its shrink, and the
# hold-forever after -- which prices dLastLight x4 and always outranks
# dClosingTime when both would apply (same one-deed-per-kill law
# `killDeed` uses everywhere else); `closing` is true while any EARLIER
# phase is actively shrinking, which prices dClosingTime x2.
#
# The wire mirrors both facts directly, no reconstruction needed:
# `world.zone.phase` IS the engine's own 1-indexed `firstLightZonePhase`
# (src/ctf/server.nim) -- it climbs 1..N over the match and then holds at
# N forever, so `phase >= N` is exactly `final`, no separate flag to miss.
# `world.zone.ticks_to_shrink` is `ticksToNextZoneShrink` (same file): 0
# exactly while a shrink is actively running, a positive countdown during
# a wait. N = 6 for the live battle-royale-s2 zonePhases schedule (z
# 0.75/0.55/0.35/0.2/0.08/0.001) -- re-count this if that schedule is ever
# retuned, the same care every other manifest-fit constant here already
# gets (ArcFireRangePx, MIN_LEASH, ...).
TOTAL_ZONE_PHASES = 6


def _in_marquee_zone_window(view):
    """True the instant the REAL zone clock is inside the window that
    prices ClosingTime or LastLight (see TOTAL_ZONE_PHASES's own comment
    for the exact source predicate this mirrors). Missing or malformed
    zone data -- a pre-BR fixture, an early tick before the first view
    lands, a stripped test view -- reads False, never a guess."""
    zone = (view.get("world") or {}).get("zone")
    if not isinstance(zone, dict):
        return False
    phase = zone.get("phase")
    if not isinstance(phase, int):
        return False
    if phase >= TOTAL_ZONE_PHASES:
        return True
    ticks = zone.get("ticks_to_shrink")
    return isinstance(ticks, (int, float)) and ticks <= 0


def _final4(view):
    """True once alive rival teams + us <= FINAL4_TEAM_THRESHOLD (4).

    SIGNAL: ``view["world"]["alive_teams"]`` -- the same raw, engine-owned
    counter starter_harness.py already reads for its own awareness lines
    and ``match_phase`` label (_vital_lines/summarize/match_phase all key
    off this exact field; match_phase even calls <=3 "ENDGAME" in its own
    label text). This is the explicit engine signal the F4 initiative asked
    to prefer over reconstructing alive-count from the kill feed or the
    0xB0 roster: it is already a total-teams-remaining count, not something
    this policy has to infer. There is no separate "final four"/placement
    LABEL on the view (only the achievement-side dFinal4/dFinal8/dFinal2
    placement trio the engine mints internally, per glory.nim's
    RecutClassTable and system_prompt.md's own citation of it) -- 4 is
    reused here because it is that same engine boundary, not a new one.

    FAILURE MODES (fails to False, never a guess, same convention as
    _in_marquee_zone_window):
    * missing/malformed ``world``/``alive_teams`` (pre-BR fixture, a tick
      before the first real view lands, a stripped self-check view) reads
      False -- never misread as "only 4 teams," which would wrongly clamp
      a mid-match detour.
    * ``alive_teams`` is the engine's own team-elimination counter, not an
      independently derived one; if the engine's bookkeeping ever lags an
      actual last-seat death by a tick, this reads exactly as stale as
      every other consumer of the same field (match_phase, the awareness
      lines) -- there is no independent kill-feed cross-check here, because
      alive_teams is already authoritative, not inferred.
    * it counts TEAMS, not "us plus rivals with a living seat" as a
      duo-pair concept -- on a solo-reshaped field (SOLO GUARD above) a
      "team" is one seat, so the boundary still lands on "4 entities left,"
      which is what the F4 initiative measured against.
    """
    world = view.get("world")
    if not isinstance(world, dict):
        return False
    alive_teams = world.get("alive_teams")
    return (isinstance(alive_teams, (int, float))
            and alive_teams <= FINAL4_TEAM_THRESHOLD)


def apply_phase_clamps(entries, view, pact_state, source=None):
    """The ONE clamp point for every ENDGAME-DOCTRINE pin this persona owns
    -- fire_superiority.pressRange/finishRange/engageDist, supply_run.
    whenHpBelow, and the final-four detour ceiling (FINAL4_DETOUR_MAX) --
    every entries list
    about to reach the wire must pass through this before it is sent,
    whether it came from a real model call, one of the two harness reemit
    helpers, or a maintenance resend.

    HISTORY (v51, ereq_99f472a2, episode's ~700 exposed ticks): v50 put the
    final-four clamp inline inside adjust_entries, keyed off a local
    `final4` variable computed partway through that function. Two gaps
    fell out of that placement, both silent because neither is a
    model-authored mistake -- they are wire values the model never even
    had a chance to submit:

    1. adjust_entries's own CONVERSION/ARMAMENT steps auto-insert a bare
       supply_run/loot rung (SUPPLY_DEFAULTS/LOOT_DEFAULTS: detourMax
       300/400) when the model's own entries omit them -- but that insert
       ran AFTER the old inline clamp's per-entry loop, so an
       auto-inserted rung during final4 shipped at the raw default,
       uncapped, even on a real model-authored call.
    2. starter_harness._live_loop's ladder-maintenance resend (~line 1941:
       `gate_and_build(seat, available)`) never calls adjust_entries at
       all -- it re-derives a wire payload straight from the cached
       `seat.wanted_entries`, so a ladder committed BEFORE final4 became
       true (detourMax=300) could sit on the wire, re-sent verbatim every
       ~2s, for as long as the maintenance gate kept re-opening with no
       fresh model/reemit call to pass back through adjust_entries and
       re-clamp it -- measured ~700 ticks past the final-four phase line
       in ereq_99f472a2.

    v52 (PIN_BYPASS_AUDIT, flagged by the v51 builder): the SAME structural
    gap exists for the OTHER endgame-doctrine pins that used to live only
    in adjust_entries's per-entry loop -- fire_superiority's
    pressRange/finishRange wire fix (FIRE_SUPERIORITY_PRESS_RANGE/
    FIRE_SUPERIORITY_FINISH_RANGE) and supply_run's whenHpBelow re-anchor
    (SUPPLY_DEFAULTS["whenHpBelow"]). fire_superiority is a GATED_PLAY, so
    the maintenance resend can re-install it straight from
    `seat.wanted_entries` without ever passing back through
    adjust_entries, exactly like the final-four leak. Both pins move here
    so every wire send -- model call, either reemit helper, or a
    maintenance resend -- shares ONE implementation instead of a copy that
    can drift out of sync with adjust_entries again.

    v53 (GV17 economy, engagement volume): a THIRD fire_superiority field,
    engageDist (FIRE_SUPERIORITY_ENGAGE_DIST), joins pressRange/finishRange
    in the SAME per-entry loop below -- same GATED_PLAY maintenance-bypass
    risk, same fix. engageDist is not final4-gated, exactly like pressRange/
    finishRange: it pins to doctrine (750/750) on every entry, every send
    path, unconditionally.

    Calling this SAME function from both adjust_entries (after its own
    CONVERSION/ARMAMENT inserts) and from the maintenance resend path
    closes all these gaps with one implementation instead of separate
    copies that can drift apart again.

    Mutates `entries` in place (same contract as adjust_entries's other
    internal steps) and returns True iff ANY clamp in this function
    actually changed something on this call (informational only).

    `pact_state` is the SAME persisted dict every final4 mechanism already
    shares (`seat.pact_state`, aliased as `context["_pact_state"]` inside
    adjust_entries) -- `final4_committed`/`final4_logged` on it are the
    mutual-exclusion/dedup flags so a duplicate resend from any source
    never re-clamps what is already clamped and never re-logs the phase
    line twice.

    `source` tags where this call came from, log wording only: None for a
    real model call (v50/v44's original plain wording, unchanged), the
    string "final4-reemit" for maybe_final4_reemit's synthetic resend
    (v50's original "reason=final4-reemit" suffix, unchanged), and the
    string "maintenance" for starter_harness's ladder-maintenance resend
    -- logged as e.g. ``clamp fire_superiority.pressRange (maintenance)
    <old> -> 220 phase=<phase>`` or ``final4 clamp (maintenance):
    <play>.detourMax <old> -> 150`` so a maintenance-triggered clamp is
    distinguishable in the log from a model-authored one. Real calls get
    the exact same log text adjust_entries always produced (tag/suffix
    both empty), so this move is behaviour-identical for that path.
    """
    pstate = pact_state if pact_state is not None else {}
    if source == "maintenance":
        tag, suffix = " (maintenance)", ""
    elif source == "final4-reemit":
        tag, suffix = "", " reason=final4-reemit"
    else:
        tag, suffix = "", ""
    fired = False

    # FIRE_SUPERIORITY WIRE FIX (v44, moved here v52 -- see module docstring
    # above FIRE_SUPERIORITY_PRESS_RANGE/FIRE_SUPERIORITY_FINISH_RANGE):
    # pin all three levers to the doctrine value for the CURRENT
    # live-zone-clock phase on every entry about to be sent, on every path
    # -- never trust the model, a stale cached ladder, or a gated resend to
    # have carried the right value. pressRange happens to be the SAME
    # doctrine number in both phase buckets today (220/220), which is what
    # makes it read as "always pinned"; finishRange still tightens 140 ->
    # 120 in the zone-timer endgame window (_in_marquee_zone_window),
    # unchanged from v44. engageDist (v53, FIRE_SUPERIORITY_ENGAGE_DIST,
    # GV17 economy engagement-volume fix) is ALSO flat across both phase
    # buckets (750/750) -- same "always pinned" shape as pressRange, added
    # to this SAME loop rather than a new one so it shares the identical
    # clamp/log/maintenance-bypass-closing mechanism.
    phase = "endgame" if _in_marquee_zone_window(view) else "default"
    for entry in entries:
        if entry.get("play") != "fire_superiority":
            continue
        params = entry.setdefault("params", {})
        for field, doctrine_by_phase in (
                ("pressRange", FIRE_SUPERIORITY_PRESS_RANGE),
                ("finishRange", FIRE_SUPERIORITY_FINISH_RANGE),
                ("engageDist", FIRE_SUPERIORITY_ENGAGE_DIST)):
            doctrine = doctrine_by_phase[phase]
            old = params.get(field)
            if old != doctrine:
                starter_harness._log(
                    PERSONA,
                    f"clamp fire_superiority.{field}{tag} {old!r}->{doctrine} "
                    f"phase={phase}{suffix}")
                fired = True
            params[field] = doctrine

    # SUPPLY_RUN whenHpBelow re-anchor (moved here v52, same fix class as
    # above -- see SUPPLY_DEFAULTS's own note): pin to doctrine on every
    # submitted supply_run entry, not just the insert-if-missing rung.
    for entry in entries:
        if entry.get("play") != "supply_run":
            continue
        params = entry.setdefault("params", {})
        doctrine = SUPPLY_DEFAULTS["whenHpBelow"]
        old = params.get("whenHpBelow")
        if old != doctrine:
            starter_harness._log(
                PERSONA,
                f"clamp supply_run.whenHpBelow{tag} {old!r}->{doctrine}{suffix}")
            fired = True
        params["whenHpBelow"] = doctrine

    # FINAL FOUR (v50/v51, unchanged logic): only the detour ceiling is
    # gated on _final4(view) -- the two pins above are NOT final4-gated,
    # they apply on every call regardless of alive_teams.
    if _final4(view):
        # FINAL4_COMMITTED (v50, unchanged): set on every final4-true turn
        # (synthetic or real) so starter_harness.maybe_final4_reemit --
        # which shares this SAME persisted dict via seat.pact_state -- can
        # see a clamp already landed at alive_teams<=4 and skip its own
        # one-shot synthetic resend (no double commit).
        pstate["final4_committed"] = True
        if not pstate.get("final4_logged"):
            pstate["final4_logged"] = True
            alive = (view.get("world") or {}).get("alive_teams")
            phase_suffix = (" reason=final4-reemit"
                            if source == "final4-reemit" else "")
            starter_harness._log(
                PERSONA, f"final4: alive_teams={alive!r}{phase_suffix}")
        for entry in entries:
            play = entry.get("play")
            if play not in ("supply_run", "loot"):
                continue
            params = entry.setdefault("params", {})
            old_detour = params.get("detourMax")
            new_detour = (min(old_detour, FINAL4_DETOUR_MAX)
                          if isinstance(old_detour, (int, float))
                          else FINAL4_DETOUR_MAX)
            if old_detour != new_detour:
                starter_harness._log(
                    PERSONA,
                    f"final4 clamp{tag}: {play}.detourMax {old_detour!r} "
                    f"-> {FINAL4_DETOUR_MAX}{suffix}")
                fired = True
            params["detourMax"] = new_detour
    return fired


def _normalize_bodyguard(entries):
    """Collapse every bodyguard entry the model submitted -- one, several,
    self-named or canonical -- into exactly the canonical pair from
    BODYGUARD_LEASH, interpose true, at the position of the first one.

    The model keeps the WHEN (whether it calls bodyguard at all this turn)
    and the WHOM (ward): the first entry that set `ward` or `peelHp` wins,
    since "shield-close" and "shield" are the SAME protection intent split
    across two range bands, never two different targets. Code owns only
    the mechanical id + leash-band split -- entry_id, leash and interpose
    are always overwritten, never trusted from the wire.

    Idempotent by construction: run this again on an already-canonical
    pair and it extracts the same ward/peelHp from those same two entries
    and re-emits the same two entries at the same position -- never a
    third, never a duplicate.
    """
    positions = [i for i, e in enumerate(entries) if e.get("play") == "bodyguard"]
    if not positions:
        return entries
    ward = peel_hp = None
    for i in positions:
        params = entries[i].get("params") or {}
        if ward is None and params.get("ward") is not None:
            ward = params["ward"]
        if peel_hp is None and params.get("peelHp") is not None:
            peel_hp = params["peelHp"]
    canonical = []
    for entry_id, leash in BODYGUARD_LEASH.items():
        params = {"leash": list(leash), "interpose": True}
        if ward is not None:
            params["ward"] = ward
        if peel_hp is not None:
            params["peelHp"] = peel_hp
        canonical.append({"play": "bodyguard", "entry_id": entry_id,
                          "params": params})
    result = list(entries)
    for i in reversed(positions):
        del result[i]
    result[positions[0]:positions[0]] = canonical
    return result


# Per-play entry_id memoization (generalizes the trick above to every OTHER
# play). The engine only warm-reconfigures a live rung when the new call
# matches it on entry_id + play + module hash (src/shell/replacement.nim
# replacementKeyMatches); anything else reads as a brand-new entry and
# cold-restarts it (raStartAbsent), and MaxInitsPerTick=2 means that can
# strand the ladder on the engine default for several ticks right after a
# kill or taking fire -- exactly when the named-deed press matters most. The
# model renames a play's entry_id turn over turn (loot "arm" -> "loot",
# supply_run "bank" -> "heal", ...); bodyguard alone is immune, because
# _normalize_bodyguard above always overwrites its entry_id to one of the
# two fixed BODYGUARD_LEASH ids regardless of what the model called it.
# This is the same fix for every other play: whichever entry_id a play
# first ships with THIS match is the one every later call is forced back
# onto, however the model renames it. Module-level and keyed by play name
# -- one process drives exactly one seat for exactly one match (see
# starter_harness.run's single `with _connect_with_retry(...)` seat loop),
# so this never leaks across matches or seats.
_ENTRY_ID_MEMO: dict = {}


def _stabilize_entry_ids(entries):
    """Force every non-bodyguard play's entry_id to the id it first shipped
    with this match. WHICH plays are called and their params are untouched
    -- only entry_id. Bodyguard is exempt: it already gets a fixed id from
    _normalize_bodyguard, and memoizing it here by play name alone would
    collapse its two distinct bands ("shield-close" / "shield") onto
    whichever one is seen first."""
    for entry in entries:
        play = entry.get("play")
        entry_id = entry.get("entry_id")
        if play == "bodyguard" or not isinstance(play, str) \
                or not isinstance(entry_id, str):
            continue
        remembered = _ENTRY_ID_MEMO.setdefault(play, entry_id)
        if entry_id != remembered:
            entry["entry_id"] = remembered
    return entries


def _neighbor_duo(context):
    """The next team's duo seats -- team size DERIVED from OBSERVED state
    at THIS call, never a fixed divisor off a seat/roster count. Under the
    2-per-team layout (seat k pairs with k+teamCount) the offset between
    our own seat and our own duo_partner IS teamCount, read straight off
    the same self-facts the SOLO GUARD above already keys on, not guessed
    from len(roster) // 2 -- that guess is exactly what silently treated
    two unrelated SOLO seats as one team once the field reshaped to 16
    solo entrants (confirmed realized 2026-09-05: 36/36 episodes across
    r4003-4005 read 16 distinct teams, zero repeats).

    SOLO (duo_partner missing or equal to our own seat) is the DEFAULT
    branch here too -- there is no coherent "neighboring duo" to name when
    there is no duo, so this returns None and callers fall through to
    their own no-neighbor path. DUO is retained as an explicit, labeled
    FALLBACK: the instant a real, distinct duo_partner reappears (this
    reshape has already flipped seven times in ~72 hours) the
    offset-derived team size resumes exactly as before, no code change
    required.
    """
    self_facts = context.get("self") or {}
    seat = self_facts.get("seat")
    partner = self_facts.get("duo_partner")
    if not isinstance(seat, int):
        return None
    if not isinstance(partner, int) or partner == seat:
        return None  # SOLO: no genuine partner observed, no duo to name.
    team_count = abs(partner - seat)
    team = seat % team_count
    nt = (team + 1) % team_count
    return (nt, nt + team_count)


# ── SOLO pact naming (OWNER DIRECTIVE, GV15/#467 era) ───────────────────────
# _neighbor_duo answers None in 16-solo (no duo exists), so the UNAIMABLE
# branch below used to drop the pact entry outright -- confirmed root cause
# of MEASURE.md's 4/37 declared, 0/37 formed: the huddle transcript is heard
# by the harness (seat.chat, poc_policy.PlaySeat._file "lobby_chat" branch)
# but was never threaded to adjust_entries at all (repair_call only passed
# seat.context/seat.view; grep for invit|reciproc in this file was zero
# hits before this change). starter_harness.repair_call now hands us that
# transcript at context["_chat"] (list of {"seat","text"}), the episode's
# kill history at context["_kill_feed"] (same schema as view["kill_feed"]:
# tick/victim_seat/killer_team -- team IS seat in 16-solo, PERCEPTION.md
# (b)/(c)), and a persistent per-episode scratchpad at context["_pact_state"]
# (the same dict object every call, owned by the seat, so state survives
# turn to turn exactly like a live match -- see repair_call).
# v46 (RECIPROCITY.md #3): widened for documentation/advisory context --
# real reciprocation lines routinely use NONE of these tokens ("softmaxwell
# -- orange reciprocates. hold fire on seat:12, we hold on you" carries only
# "reciprocates"/"hold fire", not "pact"/"truce"; "name us back and we do
# not fire on you" carries neither). _parse_pact_invites below no longer
# gates on this tuple at all -- naming our seat/name in a chat line is
# sufficient on its own (see its docstring) -- this list is kept as the
# vocabulary reference the naming-only design supersedes, not a live gate.
_PACT_KEYWORDS = ("pact", "truce", "non-aggression", "nonaggression",
                   "reciprocate", "reciprocates", "reciprocated",
                   "hold fire", "hold on you", "locked in", "name us back",
                   "no fire", "non-aggro")


def _named_seats(context, text):
    """Every seat `text` names: a literal seat:N / seat N token, or a
    roster display name substring (longest name checked first so a short
    name cannot shadow-match inside a longer one)."""
    hits = {int(m) for m in re.findall(r"seat[:\s]*(\d+)", text, re.IGNORECASE)}
    roster = [r for r in (context.get("roster") or []) if isinstance(r, dict)]
    low = text.lower()
    for row in sorted(roster, key=lambda r: -len(str(r.get("name") or ""))):
        name, seat = row.get("name"), row.get("seat")
        if (isinstance(name, str) and name and isinstance(seat, int)
                and name.lower() in low):
            hits.add(seat)
    return hits


def _parse_pact_invites(context):
    """Live seats that named US in the lobby/live chat -- v46 (RECIPROCITY.md
    #3): naming us is sufficient ON ITS OWN, no keyword required. The old
    keyword+us-mention gate silently dropped real reciprocation lines that
    carry no _PACT_KEYWORDS token at all, e.g. "softmaxwell -- orange
    reciprocates. hold fire on seat:12, we hold on you. yellow in?" (only
    "reciprocates"/"hold fire") and "seat 13 here... name us back and we do
    not fire on you" (neither word). The 0xB2 broadcast carries only the
    sender's own seat, so a bare us-mention on one message already
    identifies who is proposing/reciprocating with us -- no cross-
    referencing, and no keyword, needed."""
    self_facts = context.get("self") or {}
    my_seat = self_facts.get("seat")
    invites = set()
    for msg in context.get("_chat") or []:
        if not isinstance(msg, dict):
            continue
        sender, text = msg.get("seat"), msg.get("text")
        if not isinstance(sender, int) or sender == my_seat:
            continue
        if not isinstance(text, str):
            continue
        if isinstance(my_seat, int) and my_seat in _named_seats(context, text):
            invites.add(sender)
    return invites


def _excluded_pact_seats(context):
    """Seats to never name: whoever tagged us, and whoever we tagged, this
    episode. kill_feed carries killer_team, not killer_seat (PERCEPTION.md
    (b)) -- exact in 16-solo, where team == seat."""
    self_facts = context.get("self") or {}
    my_seat = self_facts.get("seat")
    my_team = self_facts.get("team", my_seat)
    excluded = set()
    for kill in context.get("_kill_feed") or []:
        if not isinstance(kill, dict):
            continue
        victim, killer_team = kill.get("victim_seat"), kill.get("killer_team")
        if victim == my_seat and isinstance(killer_team, int):
            excluded.add(killer_team)
        elif (killer_team == my_team and isinstance(victim, int)
              and victim != my_seat):
            excluded.add(victim)
    return excluded


def _is_xy(value) -> bool:
    return (isinstance(value, (list, tuple)) and len(value) == 2
            and all(isinstance(v, (int, float)) for v in value))


def _nearest_live_rivals(context, view, exclude, limit):
    """Deterministic nearest-N rival seats by straight-line distance from
    our own position, tie-broken by seat id. Before the first play_view
    (the pre-call, before any tick has landed) there is no position to
    rank by; fall back to roster order so a pact is still named something
    real on turn one, never left empty."""
    self_facts = context.get("self") or {}
    my_seat = self_facts.get("seat")
    my_team = self_facts.get("team", my_seat)
    exclude = set(exclude) | {my_seat}
    my_pos = ((view or {}).get("self") or {}).get("pos")
    if not _is_xy(my_pos):
        roster = sorted((r for r in (context.get("roster") or [])
                         if isinstance(r, dict) and isinstance(r.get("seat"), int)),
                        key=lambda r: r["seat"])
        return [r["seat"] for r in roster
                if r["seat"] not in exclude
                and r.get("team", r["seat"]) != my_team][:limit]
    ranked = []
    for track in (view or {}).get("tracks", []):
        if not isinstance(track, dict):
            continue
        seat = track.get("seat")
        if (not isinstance(seat, int) or seat in exclude
                or track.get("team", seat) == my_team or track.get("downed")):
            continue
        pos = track.get("pos")
        if not _is_xy(pos):
            continue
        ranked.append((math.hypot(pos[0] - my_pos[0], pos[1] - my_pos[1]), seat))
    ranked.sort(key=lambda pair: (pair[0], pair[1]))
    return [seat for _, seat in ranked[:limit]]


def _resolve_solo_pact_partners(context, view):
    """The SOLO named-partner mechanism: named, live rival seats only,
    never the placeholder, never dropped. State persists turn to turn in
    context["_pact_state"] (see repair_call -- it is the same dict object
    every call for one seat's one episode). Returns
    (partner_seat_ints, {seat: reason}, event) -- `event` is None when
    nothing new happened this call, else the reason THIS call is worth
    re-committing to the wire ("invited"/"reciprocate"/"fallback"/"retry"/
    "kickoff")."""
    state = context.setdefault("_pact_state", {})
    partners = state.setdefault("partners", [])
    reasons = state.setdefault("reasons", {})
    state["calls"] = state.get("calls", 0) + 1
    event = None

    excluded = _excluded_pact_seats(context)

    # BETRAYAL: drop a current partner who has since tagged us; never
    # re-add them. onBetrayal="returnFire" (below) is the in-match
    # response -- this is the never-list/never-re-propose side of it.
    for s in [p for p in partners if p in excluded]:
        partners.remove(s)
        reasons.pop(s, None)

    # RECIPROCATE -- and the very first AIM, which is the same operation
    # on the turn partners is still empty: any live seat that named us in
    # the huddle, not already a partner, not excluded. v46: this now also
    # runs on turns AFTER the first real partners exist (see the loosened
    # `adjust_entries` guard below), which is what makes a late namer
    # (change 3) reachable at all.
    invited_now = sorted(_parse_pact_invites(context) - excluded)
    gained_invite = False
    for s in invited_now:
        if s in partners or len(partners) >= PACT_PARTNER_CAP:
            continue
        reasons[s] = "invited" if not partners else "reciprocate"
        partners.append(s)
        gained_invite = True
        event = reasons[s]

    # FALLBACK (v47b: 2 -> 3): nobody has ever invited us -- name the 3
    # nearest live rivals, computed once (not re-picked every turn, so it
    # cannot churn as positions move). More named partners is more surface
    # for a genuine mutual pact to form (owner direction 2026-09-09).
    if not partners and not state.get("fallback_done"):
        state["fallback_done"] = True
        for s in _nearest_live_rivals(context, view, excluded, 3):
            reasons[s] = "fallback"
            partners.append(s)
        event = event or "fallback"

    # RETRY (v47b: +1 -> +2): we have no perception of the sim's mutual-pact
    # bit at all (PERCEPTION.md (a)) -- "not mutual by the next turn" is
    # read as "no one has named us back yet". Re-declare once, same seats
    # plus up to 2 new nearest seats, capped at PACT_PARTNER_CAP total.
    # v47b fix (surfaced by the raised cap): only spend the one-shot
    # `retried` flag and the `retry` event tag when a candidate is actually
    # FOUND -- with cap=3 this branch was naturally starved shut once the
    # 3 invited-partner cap was already hit (see the KICKOFF test, which
    # commits exactly 3 invited partners then expects a clean
    # reason=kickoff on the next call); with cap=5, `len(partners) < 5`
    # stays true past that same 3-partner state, so an empty-view call
    # (no visible rivals yet) would otherwise burn the retry attempt AND
    # steal the kickoff call's own event tag for nothing. Leaving `retried`
    # unset when nothing was found means a later call with real track data
    # can still retry -- never a worse outcome than the old one-shot.
    if (partners and not gained_invite and not state.get("retried")
            and state.get("calls", 0) >= 2 and len(partners) < PACT_PARTNER_CAP):
        retry_room = PACT_PARTNER_CAP - len(partners)
        retry_picks = _nearest_live_rivals(
            context, view, excluded | set(partners), min(2, retry_room))
        if retry_picks:
            state["retried"] = True
            for s in retry_picks:
                reasons[s] = "retry"
                partners.append(s)
            event = event or "retry"

    # KICKOFF RE-AFFIRM (v46, RECIPROCITY.md ranked fix #1): the first call
    # whose `view` carries a real tick is the first call at/after the sim's
    # Playing phase begins -- starter_harness._in_spawn_phase's own comment
    # ("the views start when the match does") is the harness's own existing
    # proof that seat.view is empty for every lobby/huddle turn and first
    # becomes populated exactly when Playing starts. Our wire installs land
    # at tick 235-531 (still lobby, view still empty) while sim.nim's
    # declarePactPartners only registers a declare once sim.phase==Playing
    # (tick 768-1759 observed), so a lobby-only commit is invisible to the
    # sim in 46/47 measured episodes. Re-commit here, once, with whatever
    # partners are already resolved (even if unchanged this call), so a
    # wire call naming them lands AFTER Playing has begun.
    # v47a (RECIPROCITY.md first-round read of v46: kickoff fired 2/3
    # episodes -- the third made only 1-3 model calls total, none after
    # Playing began, so this branch never got a turn to run at all).
    # starter_harness.maybe_kickoff_reemit drives the SAME re-commit through
    # this SAME function, from the harness's own turn loop, with NO model
    # call -- it flags the synthetic trigger via
    # context["_synthetic_trigger"] so the wire-committed line is tagged
    # kickoff-reemit instead of kickoff (still resolves the SAME partners,
    # same never-target mirror -- only the reason string differs, so a
    # reader can tell which path produced a given commit).
    if (partners and isinstance(view.get("tick"), int)
            and not state.get("kickoff_committed")):
        state["kickoff_committed"] = True
        if event is None:
            event = ("kickoff-reemit"
                      if context.get("_synthetic_trigger") == "kickoff-reemit"
                      else "kickoff")

    partners[:] = partners[:PACT_PARTNER_CAP]
    return (list(partners), {s: reasons[s] for s in partners if s in reasons},
            event)


def _log_pact_aim(partners, reasons, event=None):
    tagged = ", ".join(f"seat:{s}={reasons.get(s, '?')}" for s in partners)
    suffix = f" reason={event}" if event else ""
    print(f"[monet] pact aim: partners=[{tagged}]{suffix}", flush=True)


def adjust_entries(entries, context, view):
    self_facts = context.get("self") or {}
    partner = self_facts.get("duo_partner")
    seat = self_facts.get("seat")
    own_duo = {f"seat:{s}" for s in (seat, partner) if isinstance(s, int)}

    # SOLO GUARD (16-solo BR reshape, confirmed realized on the field
    # 2026-09-05 -- 36/36 episodes across r4003-4005 read 16 distinct
    # teams, zero repeats): a missing or self-referential duo_partner means
    # this seat has no partner this match. gate_open already refuses to
    # open bodyguard or medic when partner is None (selfcheck's "gate
    # medic CLOSED: no partner" pins this), so neither rung can ever
    # actually fire -- but leaving them on the WANTED ladder still spends
    # two of wire.MAX_LADDER_ENTRIES' limited slots (bodyguard normalizes
    # to a canonical PAIR, see BODYGUARD_LEASH) on rungs that can only ever
    # sit gated shut. Strip them here instead of trusting the gate alone
    # to make them inert. FALLBACK, not deletion: the instant a live
    # duo_partner reappears (this reshape has already flipped seven times
    # in 72 hours) this block is a no-op and every duo rung below installs
    # exactly as before, no code change required to restore it.
    if partner is None or partner == seat:
        entries = [e for e in entries
                   if e.get("play") not in ("bodyguard", "medic")]

    # Re-aim placeholder or self-referential pacts at the neighboring duo;
    # keep a model's real choice of partners. Betrayal is answered in kind.
    # `confirmed_seats` (v46) used to be the subset of `pact_seats` that
    # earned the target_law never-target guarantee -- as of v55,
    # CONFIRMED_PACT_REASONS is empty, so this is always []; kept as the
    # same computed set (not deleted) so the reason-classification logic
    # (invited/reciprocate/fallback/retry) and onBetrayal/params handling
    # below stay a single shared path instead of forking one off.
    pact_seats = []
    confirmed_seats = []

    # v48 (r4535 1/3 reemit coverage fix): `entries` (this call's wire
    # ladder) and `_pact_state["partners"]` (the persisted commitment) are
    # independently mutated -- the ladder drifts pact-less the instant the
    # model's own proposal for THIS call omits "play":"pact", even though
    # the persisted partners are still live. starter_harness.py's
    # maybe_kickoff_reemit trusts the LADDER snapshot (seat.wanted_entries),
    # not the persisted state, so a pact-less ladder silently burns the
    # one-shot reemit flag with nothing ever sent (r4535 episodes 1 and 3,
    # 1/3 coverage). Re-inject a synthetic pact entry here -- SOLO path
    # only (_neighbor_duo(context) is None); DUO pact entries are a
    # different, untouched mechanism and are never synthesized here. The
    # loop below then re-derives partners from persisted state via
    # _resolve_solo_pact_partners, applying the PACT_PARTNER_CAP clamp and
    # the confirmed-only never-target gate exactly as for a genuine
    # submission.
    if (not any(e.get("play") == "pact" for e in entries)
            and _neighbor_duo(context) is None
            and (context.get("_pact_state") or {}).get("partners")):
        entries = list(entries) + [
            {"entry_id": "truce", "play": "pact", "params": {"partners": []}}
        ]
        print(
            "[monet] pact ladder re-sync: partners="
            + str(list((context.get("_pact_state") or {}).get("partners") or [])),
            flush=True,
        )

    for entry in list(entries):
        if entry.get("play") != "pact":
            continue
        pstate_flag = context.setdefault("_pact_state", {})
        if not pstate_flag.get("holds_disabled_logged"):
            pstate_flag["holds_disabled_logged"] = True
            print("[monet] pact holds: disabled (v55)", flush=True)
        params = entry.setdefault("params", {})
        partners = [p for p in params.get("partners", []) if isinstance(p, str)]
        entry_confirmed = []
        unaimed = (not partners or set(partners) == PACT_PLACEHOLDER
                   or set(partners) & own_duo)
        if unaimed:
            neighbors = _neighbor_duo(context)
            if neighbors is not None:
                partners = [f"seat:{n}" for n in neighbors]
                # DUO neighbor-aim is a different, untouched mechanism (a
                # designed rival-duo targeting convention, not a unilateral
                # guess) -- always confirmed, exactly as before v46.
                entry_confirmed = list(partners)
            else:
                # SOLO / no genuine duo this match (missing or
                # self-referential duo_partner). Previously DROPPED the
                # entry outright (IMPROVE queue #1, tick 15, fixed
                # 2026-09-05) because there was nothing real to name --
                # confirmed by MEASURE.md as the dominant cause of the
                # 4/37 declared, 0/37 formed pact record: an unaimed pact
                # is now named at real, live rival seats instead (invited
                # -> reciprocate -> fallback -> retry; see
                # _resolve_solo_pact_partners) and never dropped.
                resolved, reasons, event = _resolve_solo_pact_partners(
                    context, view)
                if resolved:
                    partners = [f"seat:{s}" for s in resolved]
                    _log_pact_aim(resolved, reasons, event or "resolve")
                    entry_confirmed = [f"seat:{s}" for s in resolved
                                       if reasons.get(s)
                                       in CONFIRMED_PACT_REASONS]
                # else: truly nothing to name (empty roster/view) -- leave
                # the incoming (placeholder) partners as they are rather
                # than ship an invalid empty-partners call (and nothing to
                # confirm: entry_confirmed stays empty).
        elif _neighbor_duo(context) is None:
            # v46 (RECIPROCITY.md #3): SOLO episodes used to stop calling
            # _resolve_solo_pact_partners forever the instant `partners`
            # held real, non-placeholder seats -- `unaimed` above goes
            # False on that turn and stays False every later turn once the
            # model echoes its own already-committed partners back (46/47
            # declared-but-never-registered episodes measured this way).
            # That made kickoff re-affirm, late reciprocation, and retry
            # all unreachable a second time. Seed the persisted state from
            # THIS call's real (possibly model-authored) partners first --
            # so a genuine model choice (the one episode that formed a
            # pact, round 4519 480898f1, was exactly a model re-declare
            # like this) is the truth the resolver builds on, never
            # silently replaced by a stale fallback pick -- then let the
            # resolver run for kickoff-reaffirm/late-invite/retry. Only
            # override the submitted entry when the resolver reports a
            # real event this call (`event` truthy); otherwise the
            # model/canned submission passes through completely untouched,
            # exactly as before.
            pstate = context.setdefault("_pact_state", {})
            if not pstate.get("partners") and partners:
                seeded = sorted({int(p.split(":", 1)[1]) for p in partners
                                  if p.split(":", 1)[1].isdigit()})
                pstate["partners"] = seeded
                pstate.setdefault("reasons", {})
                for s in seeded:
                    pstate["reasons"].setdefault(s, "named")
            resolved, reasons, event = _resolve_solo_pact_partners(
                context, view)
            if resolved and event:
                partners = [f"seat:{s}" for s in resolved]
                _log_pact_aim(resolved, reasons, event)
            # Confirmed status reflects the PERSISTED reasons regardless of
            # whether this particular call changed anything -- a seat named
            # "invited"/"reciprocate" on an earlier turn stays confirmed on
            # every later turn too, it does not need to re-earn it.
            entry_confirmed = [p for p in partners
                               if reasons.get(_seat_num(p))
                               in CONFIRMED_PACT_REASONS]
        else:
            # Real DUO submission, already aimed at genuine partners (not
            # placeholder, not self-referential) -- untouched mechanism,
            # always confirmed, exactly as before v46.
            entry_confirmed = list(partners)
        # v47b house cap enforcement (schema-default-creep lesson): clamp
        # HERE, unconditionally, for every branch above -- including a
        # genuine model submission, which the wire schema alone would let
        # through with up to 8 raw seats (plays.py "pact" max_items=8).
        # The number is never left to the model.
        partners = partners[:PACT_PARTNER_CAP]
        entry_confirmed = [p for p in entry_confirmed if p in partners]
        params["partners"] = partners
        params["onBetrayal"] = "returnFire"
        pact_seats.extend(partners)
        confirmed_seats.extend(entry_confirmed)

    # FIRE DISCIPLINE (own duo only, v55): the never-list is derived, not
    # trusted, for the one relationship it still covers -- our own duo
    # partner, added unconditionally below. Pact partners no longer reach
    # it at all: CONFIRMED_PACT_REASONS is empty (see its definition and
    # ACE_PACT.md Q2 for the field read), so `confirmed_seats` above is
    # always [] and `law_never` starts empty every call. Pacts are still
    # declared/re-affirmed and `onBetrayal: returnFire` still fires on an
    # actual betrayal -- only the standing, unconditional hold is gone.
    law_never = list(confirmed_seats)
    if partner is not None and f"seat:{partner}" not in law_never:
        law_never.append(f"seat:{partner}")
    law = next((e for e in entries if e.get("play") == "target_law"), None)
    if law is None and law_never:
        law = {"play": "target_law", "entry_id": "law",
               "params": {"prefer": list(TARGET_LAW_PREFER)}}
        entries.insert(0, law)
    if law is not None:
        params = law.setdefault("params", {})
        never = [p for p in params.get("never", []) if isinstance(p, str)]
        for seat in law_never:
            if seat not in never:
                never.append(seat)
        if never:
            params["never"] = never

    # BODYGUARD SPLIT: mechanical, not prose -- see BODYGUARD_LEASH and
    # _normalize_bodyguard above. Runs before the anti-stack floor below so
    # that loop only ever sees the two canonical entries (whose bands
    # already clear their own floors -- a harmless no-op there).
    entries = _normalize_bodyguard(entries)

    # PHASE CLAMPS (see FIRE_SUPERIORITY_PRESS_RANGE/FIRE_SUPERIORITY_
    # FINISH_RANGE/FIRE_SUPERIORITY_ENGAGE_DIST/SUPPLY_DEFAULTS/
    # FINAL4_DETOUR_MAX/apply_phase_clamps above): v51 (ereq_99f472a2, ~700
    # exposed ticks) moved the final-four detour clamp into
    # apply_phase_clamps, called once at the END of this function (after
    # the CONVERSION/ARMAMENT auto-insert below), so an auto-inserted
    # supply_run/loot rung the model never named this turn is clamped too
    # -- the OLD inline-only clamp here ran BEFORE that insert and never
    # saw those rungs at all. v52 (PIN_BYPASS_AUDIT) moved fire_superiority's
    # pressRange/finishRange wire fix and supply_run's whenHpBelow
    # re-anchor into the SAME function for the SAME reason; v53 added
    # fire_superiority's engageDist to that same field loop:
    # starter_harness's ladder-maintenance resend bypasses this whole
    # function (calls gate_and_build directly on a cached wanted ladder,
    # never adjust_entries), so a stale/model-wrong value on any of these
    # levers could otherwise sit on the wire, re-sent verbatim, for
    # as long as the maintenance gate kept re-opening with no fresh
    # model/reemit call. apply_phase_clamps is the ONE implementation this
    # function and that resend path now share for all three pins. See
    # apply_phase_clamps's own docstring for the full history.

    for entry in entries:
        if entry.get("play") == "jackal":
            params = entry.setdefault("params", {})
            exit_after = params.get("exitAfter")
            if (isinstance(exit_after, dict)
                    and isinstance(exit_after.get("kills"), int)):
                exit_after["kills"] = min(exit_after["kills"],
                                          JACKAL_MAX_KILLS)
            # JOINACT WIRE FIX (see JACKAL_MIN_EARSHOT/JACKAL_JOIN_WHEN
            # above): a submitted earshot below the v10 re-arm is raised to
            # it, never lowered (a model-chosen WIDER loiter net is still
            # honored); joinWhen is pinned to bothWeakened outright -- the
            # afterKill branch's "arrive after a fight starts, tag a fresh
            # uncontested seat" behavior is never what this persona wants,
            # so there is no honest wider value to preserve the way earshot
            # has one.
            current_earshot = params.get("earshot")
            floor = (current_earshot if isinstance(current_earshot, int)
                     else 0)
            params["earshot"] = max(floor, JACKAL_MIN_EARSHOT)
            params["joinWhen"] = JACKAL_JOIN_WHEN
        elif entry.get("play") == "bodyguard":
            # ANTI-STACK: a leash floor keeps the duo off each other's
            # pixel -- stacked duos tag each other by accident. The
            # combat-close rung (entry_id "shield-close") gets its OWN,
            # lower floor: applying the quiet-phase MIN_LEASH here would
            # invert that deliberately tighter band (see MIN_LEASH_COMBAT's
            # comment above) -- lift BOTH ends off the right floor for the
            # band, never the same floor for every bodyguard entry.
            leash = entry.setdefault("params", {}).get("leash")
            if (isinstance(leash, list) and len(leash) == 2
                    and isinstance(leash[0], int)):
                floor = (MIN_LEASH_COMBAT
                         if entry.get("entry_id") == "shield-close"
                         else MIN_LEASH)
                leash[0] = max(leash[0], floor)
                leash[1] = max(leash[1], leash[0])
        elif entry.get("play") == "crossfire":
            spacing = entry.setdefault("params", {}).get("spacing")
            if (isinstance(spacing, list) and len(spacing) == 2
                    and isinstance(spacing[0], int)):
                spacing[0] = max(spacing[0], MIN_SPACING)
                spacing[1] = max(spacing[1], spacing[0])
        # fire_superiority's pressRange/finishRange wire fix and
        # supply_run's whenHpBelow re-anchor: moved to apply_phase_clamps
        # (v52), called once at the end of this function -- see the PHASE
        # CLAMPS comment above for why (auto-inserted rungs, maintenance
        # bypass). Same call site also still owns the final4 detourMax
        # clamp (v51).

    # MARQUEE CLOCK BAND (T22): the v10 fix -- woundedPct zeroed so "ANY
    # numeric parity or better now PRESSES instead of holding" -- was
    # scoped to the endgame CANNED TURN, a fixed guess at when the ring
    # gets there. The window that actually prices ClosingTime/LastLight is
    # a fact of the live zone clock, not the recall schedule: a
    # slow-opening match can reach it while still on the mid turn's
    # woundedPct=50 (which stalls an even fight at cover -- the exact
    # standoff v10 killed, just on a different turn), and a fast one can
    # still be running consolidation. Force the proven never-stall posture
    # onto whichever fire_superiority entry THIS turn already called the
    # instant the real clock says we are in the window, never inventing a
    # press controller on a turn that did not call one.
    if _in_marquee_zone_window(view):
        for entry in entries:
            if entry.get("play") == "fire_superiority":
                entry.setdefault("params", {})["woundedPct"] = 0

    # JOINACT PATIENCE: jackal is this persona's base_play (see PERSONA
    # below), so starter_harness.layer_ladder ALWAYS puts a jackal entry on
    # the wire -- but if THIS turn's entries omit jackal entirely (the
    # canned endgame turn does; a live model call can too), layer_ladder's
    # own fallback fills it from the play's bare manifest DEFAULTS
    # (earshot 500, joinWhen afterKill, exitAfter {"kills":1}), silently
    # discarding this persona's join-window tuning for exactly the
    # recall(s) that omitted it -- the same class of gap the loop above
    # fixes when jackal IS present. Install the tuned entry here instead of
    # trusting every future turn/model call to keep naming it (mirrors the
    # supply_run/loot auto-insert immediately below).
    if not any(e.get("play") == "jackal" for e in entries):
        entries.append({"play": "jackal", "entry_id": "third",
                         "params": {"earshot": JACKAL_MIN_EARSHOT,
                                    "joinWhen": JACKAL_JOIN_WHEN,
                                    "exitAfter": {"kills": JACKAL_MAX_KILLS}}})

    # CONVERSION: every ladder banks the life. The rung sits above the
    # rotation controller (wounded beats rotating) and below any fight
    # controller already chosen (never turn your back on a live gun).
    if not any(e.get("play") == "supply_run" for e in entries):
        rung = {"play": "supply_run", "entry_id": "bank",
                "params": dict(SUPPLY_DEFAULTS)}
        for i, entry in enumerate(entries):
            if entry.get("play") == "edge_ride":
                entries.insert(i, rung)
                break
        else:
            entries.append(rung)

    # ARMAMENT: the lineage cannot tag from range, cluster streaks, or
    # avenge a partner with empty hands, and lootStart makes "empty hands"
    # the default spawn state -- the marker and its hopper are two separate
    # one-shot crates, gated 12px like every pickup. self.hasGun/hasHopper
    # and the crates' own item kind are never exposed to a policy
    # (src/shell/body.nim, play_sdk/play.nim), so this cannot key off "am I
    # armed" -- but the SDK view DOES carry grenade/shield/spray/barrier
    # item kind and position, and on every live BR map (0 of the 64 br_s2
    # + 11 br pool maps author a separate weaponSpawns pool) the gun crate
    # lands on exactly the resolved grenade-spawn points
    # (sim.nim:resetLootCrates) -- so walking to the nearest grenade is,
    # today, walking to the gun. aggressive/cautious/collaborative all
    # guarantee this rung already; MONET never did. Sits below the
    # conversion rung (recovery is still the first call) and above
    # rotation, same slot as supply_run.
    if not any(e.get("play") == "loot" for e in entries):
        rung = {"play": "loot", "entry_id": "arm",
                "params": dict(LOOT_DEFAULTS)}
        for i, entry in enumerate(entries):
            if entry.get("play") == "edge_ride":
                entries.insert(i, rung)
                break
        else:
            entries.append(rung)

    # FINAL FOUR CLAMP (v51, ereq_99f472a2): applied HERE, after CONVERSION
    # and ARMAMENT above have had their chance to auto-insert a bare-default
    # supply_run/loot rung (SUPPLY_DEFAULTS/LOOT_DEFAULTS: detourMax
    # 300/400) -- an entry inserted BEFORE this point would never have been
    # visited by a clamp that ran earlier in the function (v50's bug: the
    # old inline clamp lived in the per-entry loop above, which runs before
    # these inserts). `context["_pact_state"]` is the same persistent
    # object as `seat.pact_state` (see repair_call); `_synthetic_trigger`
    # tags which harness path is resending (None = real model call,
    # "final4-reemit" = maybe_final4_reemit's synthetic resend).
    apply_phase_clamps(entries, view, context.setdefault("_pact_state", {}),
                       source=context.get("_synthetic_trigger"))

    # Stabilize entry_id LAST, after every insert above (CONVERSION,
    # ARMAMENT, the pact/law rewrites) so whatever plays actually make it
    # onto this turn's ladder -- model-named or code-inserted -- all lock
    # onto their match-first id. See _stabilize_entry_ids.
    entries = _stabilize_entry_ids(entries)
    return entries


def awareness_lines(seat):
    """MONET's per-turn awareness digest: ONE dense numeric line -- ring
    (in current? in next? shrink clock), partner (hp with a TREND across
    model turns, distance, dead/unseen honestly stated), fresh-vs-stale
    threat census with the nearest bearing, incoming fire, near items.

    The common state block carries the prose; this is the glanceable strip
    the doctrine keys on, numbers not sentences (summary tokens are sidecar
    cost). Partner dist/pos DO arrive: the duo partner rides its own
    unconditional grant row (view.nim partnerTelemetry, landed 9511b240),
    a separate channel from the ordinary same-team-excluded track loop the
    harness's _view_facts note still correctly describes for enemies. hp
    stays genuinely absent on that row by design (body.nim: hp withheld
    even from the partner grant), so the trend machinery below only ever
    arms once hp itself is exposed some other way -- distance/bearing are
    live today. A falling partner hp is attributed by rect: inside the
    safe zone it reads UNDER FIRE, outside it reads zone-burning."""
    view = seat.view or {}
    me = view.get("self") or {}
    pos = me.get("pos")
    if not view or not starter_harness._is_pos(pos):
        return None
    _dist = starter_harness._dist
    _bearing = starter_harness._bearing
    context = seat.context or {}
    self_facts = context.get("self") or {}
    my_seat = self_facts.get("seat")
    my_team = self_facts.get("team")
    partner = self_facts.get("duo_partner")
    tick = view.get("tick", 0)
    parts = []

    zone = (view.get("world") or {}).get("zone") or {}
    cur, nxt = zone.get("current"), zone.get("next")
    if isinstance(cur, list) and len(cur) == 4:
        ring = ("ring IN cur" if starter_harness._inside(pos, cur)
                else "ring OUT of cur (burning)")
        if isinstance(nxt, list) and len(nxt) == 4:
            if starter_harness._inside(pos, nxt):
                ring += ", IN next"
            else:
                center = starter_harness._rect_center(nxt)
                ring += (f", OUT of next ({int(_dist(pos, center))}px "
                         f"{_bearing(pos, center)} to center)")
        tts = zone.get("ticks_to_shrink")
        if isinstance(tts, (int, float)):
            ring += f", shrink {int(tts)}t (~{int(tts) // 24}s)"
        parts.append(ring)

    if partner is not None:
        label = f"partner s{partner}"
        if any(k.get("victim_seat") == partner for k in seat.kill_feed):
            parts.append(label + " DOWN -- you are solo")
        else:
            track = next(
                (t for t in view.get("tracks", [])
                 if isinstance(t, dict) and t.get("seat") == partner
                 and starter_harness._is_pos(t.get("pos"))), None)
            if track is None:
                parts.append(label + " alive, unseen")
            else:
                hp = track.get("hp")
                last = getattr(seat, "_monet_partner_hp", None)
                trend = ""
                if isinstance(hp, int) and isinstance(last, int) and hp < last:
                    in_cur = (isinstance(cur, list) and len(cur) == 4
                              and starter_harness._inside(track["pos"], cur))
                    trend = (f" FALLING {last}->{hp} "
                             + ("(UNDER FIRE)" if in_cur else "(zone-burning)"))
                if isinstance(hp, int):
                    seat._monet_partner_hp = hp
                parts.append(f"{label} hp {hp}{trend}, "
                             f"{int(_dist(pos, track['pos']))}px "
                             f"{_bearing(pos, track['pos'])}")

    fresh, stale = [], 0
    for track in view.get("tracks", []):
        if (not isinstance(track, dict)
                or not starter_harness._is_pos(track.get("pos"))
                or track.get("seat") in (my_seat, partner)
                or (my_team is not None and track.get("team") == my_team)):
            continue
        age = (tick - track["fresh_tick"]
               if isinstance(track.get("fresh_tick"), int) else None)
        if age is not None and age <= FRESH_TICKS:
            fresh.append(track)
        else:
            stale += 1
    stale_note = f" (+{stale} stale)" if stale else ""
    if fresh:
        fresh.sort(key=lambda t: _dist(pos, t["pos"]))
        near = fresh[0]
        parts.append(f"threats {len(fresh)} fresh{stale_note}, nearest "
                     f"{int(_dist(pos, near['pos']))}px "
                     f"{_bearing(pos, near['pos'])} hp {near.get('hp', '?')}")
    else:
        parts.append("threats 0 fresh" + stale_note)

    shots = sum(1 for a in view.get("aggressors", [])
                if isinstance(a, dict) and isinstance(a.get("tick"), int)
                and tick - a["tick"] <= FRESH_TICKS)
    if shots:
        parts.append(f"shot at x{shots} in 10s")

    items = [i for i in view.get("items", [])
             if isinstance(i, dict) and i.get("present", True)
             and starter_harness._is_pos(i.get("pos"))
             and _dist(pos, i["pos"]) <= NEAR_ITEM_PX]
    items.sort(key=lambda i: _dist(pos, i["pos"]))
    if items:
        parts.append("items " + ", ".join(
            f"{i.get('kind', '?')} {int(_dist(pos, i['pos']))}px "
            f"{_bearing(pos, i['pos'])}" for i in items[:2]))

    return ["AWARENESS: " + " | ".join(parts) + "."]


def extra_chat(context, turn):
    """One deliberate line per turn: politics first, then the partner."""
    partner = (context.get("self") or {}).get("duo_partner")
    neighbors = _neighbor_duo(context)
    if turn == 1 and neighbors is not None:
        return (f"seats {neighbors[0]} and {neighbors[1]}: MONET offers a "
                "truce -- neither duo tags the other while the field is "
                "crowded. We both outlive the brawlers.")
    if partner is None:
        return None
    if turn == 2:
        return (f"seat {partner}: hold the spacing band off my shoulder and "
                "watch the feed -- we move on the first fight we can third.")
    if turn == 3:
        return (f"seat {partner}: arrive third, tag the weakened, leave "
                "paid. No detours while a gun is on us.")
    return (f"seat {partner}: field is thin -- truces are over, range over "
            "brawl, and we finish what we start.")


PERSONA = Persona(
    name="monet",
    prompt_intro=(_HERE / "system_prompt.md").read_text(encoding="utf-8"),
    play_notes={
        "pact": ("pact is your political weapon, not a comfort blanket: "
                 "offer it in chat FIRST, then call it with the other duo's "
                 "seats (seat:N form only). A pact nobody heard is not a "
                 "truce. Keep it in every call while it stands -- dropping "
                 "it IS the betrayal, so say so when you do. Solo matches "
                 "have no duo to name: if you propose or answer a truce in "
                 "chat, NAME the seat explicitly (\"seat:N\") -- the "
                 "harness aims an unnamed solo pact at whoever named you "
                 "back, so your own chat naming them first is what makes "
                 "it mutual."),
        "target_law": ("target_law: prefer weakened, revenge, bounty, "
                       "isolated -- all four, weakened FIRST. This is your "
                       "only lever over WHO you shoot next among live "
                       "candidates, and it decides the instant right after "
                       "a kill -- exactly when a heat chain lives or dies: "
                       "closing an already-damaged target keeps the next "
                       "tag landing NOW, where chasing a fresher revenge or "
                       "bounty mark instead costs the gap a chain cannot "
                       "survive. Sequencing beats selection -- any tag open "
                       "to you now usually outscores waiting for a better "
                       "one. The harness mirrors only your own duo partner "
                       "into never automatically; pact partners are NOT "
                       "held off the never-list -- pick targets among them "
                       "on merit like any other live seat (weigh the "
                       "dTeamKill friendly-fire price of tagging one, but "
                       "the code will not stop you). Set a holdTrigger "
                       "only for a planned endgame release: a released "
                       "hold LATCHES and can never re-arm."),
        "edge_ride": ("edge_ride: the native escape reflex outranks every "
                      "play at the wall, and calling a rotation REPLACES "
                      "the default one. Call it only with a specific "
                      "positional read; margin is depth inside the safe "
                      "zone (deeper = safer) if you do -- and under "
                      "late-phase dps set enterLead 300 or more: starting "
                      "the rotation late is how seats die to an "
                      "uncontested wall."),
        "supply_run": ("supply_run is the conversion play this lineage "
                       "always skipped: after a fight, bank the life. The "
                       "harness guarantees the rung; you tune it. Doctrine "
                       "whenHpBelow is 4, NOT the playbook's stated default "
                       "of 3 -- this hp era's max is 4, and detouring only "
                       "after a SECOND marker wastes the resupply window a "
                       "single marker already opens. Avoid contested kits "
                       "unless your pact gives you the numbers to race."),
        "loot": ("loot is how you get a gun in your hands at all: you "
                 "spawn empty-handed, the marker and its hopper are two "
                 "separate pickups, and a paint can none of us ever finds "
                 "is a paint can that never tags anyone. The harness "
                 "guarantees the rung and gates it -- it only walks when "
                 "the field is calm and something is in reach, never "
                 "fights anyone over a contested crate. You cannot see "
                 "which crate is which, so do not call it looking for a "
                 "specific item; tune detourMax if you want it to reach "
                 "further, nothing more."),
        "bodyguard": ("bodyguard is BOTH the formation spring and the "
                      "shield: on a calm field ride it with leash "
                      "[110, 280] and interpose false so the duo is held "
                      "apart, never stacked (the harness floors the "
                      "leash). But your partner alive is worth more than "
                      "any tag -- every turn you shield them, submit TWO "
                      "simultaneous bodyguard entries, never one "
                      "self-named entry: entry_id \"shield-close\" with "
                      "leash [40, 120] and interpose true (measured "
                      "revive protocol: real tag-back revives land from "
                      "~40px, not 150), and entry_id \"shield\" with "
                      "leash [100, 150] and interpose true "
                      "(medic-conversion audit floor). Use those exact "
                      "two literal entry_id strings, always both, every "
                      "turn bodyguard shields your partner -- the "
                      "harness reads its own facts about live enemies "
                      "and wounded/downed/under-fire state to pick which "
                      "one actually opens and hands back to the other, "
                      "same as the canned consolidation/mid turns wire "
                      "it. You are not judging that state yourself, and "
                      "must never merge the two into one renamed entry: "
                      "the auto-switch and warm-reconfigure both key off "
                      "the literal id, so any other name (like the "
                      "generic \"ride\" example) drops the whole band."),
        "crossfire": ("crossfire is the duo's fighting shape: a spacing "
                      "band wide enough that no line crosses your partner, "
                      "minAngle real. You see your partner only through "
                      "your own fog tracks -- hold formation where you can "
                      "see each other."),
        "hold_vs_gun": ("hold_vs_gun is the Picasso lever: never turn "
                        "your back on a live gun. Keep it a GUARDED rung "
                        "above jackal and supply_run -- when the proximity "
                        "guard passes it owns movement and stands its "
                        "ground facing the threat; when the field is calm "
                        "the guard fails and the rungs below drive. Never "
                        "call it unguarded as your only controller: on a "
                        "calm field it just stands still."),
        "fire_superiority": ("fire_superiority is press-vs-break: count "
                             "the guns you can SEE, and treat unknown hp "
                             "as healthy -- never reason about invisible "
                             "state. Superior means press -- to the FAR "
                             "band against a fresh or full-health target "
                             "(a longshot tag mints 2.5x a point-blank "
                             "one; never brawl one), but ALL THE WAY IN "
                             "(finishRange) against a target you already "
                             "know is wounded -- the accuracy penalty up "
                             "close is a risk against a live gun, not a "
                             "finishing tag on someone this close to done; "
                             "outgunned means break to facing cover. Keep "
                             "it guarded on enemy contact: it is how a "
                             "winning fight gets FINISHED instead of "
                             "drawn, and a draw pays nobody. Your partner "
                             "only counts as a second gun when they are "
                             "close enough to THIS fight to matter -- "
                             "alive-but-distant is not a 1v1 flipped to a "
                             "2v1. Among targets you could press, the play "
                             "already steers off any line that would catch "
                             "your partner, and off any spot that would "
                             "put you in theirs. It is gated on a tracked "
                             "enemy -- naming it in your OPENING call costs "
                             "nothing on a quiet field and is already armed "
                             "the instant a fight starts; do not wait for "
                             "consolidation to call it the first time. "
                             "Doctrine pressRange is 220 in every phase, "
                             "same as the playbook's stated default -- a "
                             "2026-09-08 ladder read showed a wider "
                             "400/340 band traded away score-ratio (1.20 "
                             "-> 0.67) and raised the trade rate (18% -> "
                             "30%) by buying more exposure to third seats, "
                             "so 220 is now the deliberate floor-and-"
                             "ceiling, not schema-default drift: the clamp "
                             "pins it so it cannot creep in either "
                             "direction. finishRange stays 140, tightening "
                             "to 120 in the endgame window: closer to the "
                             "target once the field is small. Doctrine "
                             "engageDist is 750 in every phase (v53, "
                             "GloryVersion 17 economy): the schema default "
                             "of 600 sat below our own observed mean "
                             "engagement range, so real fights we could "
                             "already reach were never counted as guns in "
                             "the press/break math -- widening the gate to "
                             "750 raises engagement volume, the measured "
                             "gap vs the field's shots-fired/episode, "
                             "without touching pressRange or finishRange. "
                             "The clamp pins engageDist the same way it "
                             "pins pressRange: it cannot creep back to the "
                             "schema default."),
        "ring_walker": ("ring_walker is survival rule zero: the ring is "
                        "a schedule, not a surprise -- leave the building "
                        "BEFORE the walk turns into an escape, and only "
                        "ever toward reachable ground (the play routes "
                        "every target through the engine's reachability "
                        "query, so it never beelines into a wall pocket). "
                        "Keep it above every fight rung: no tag is worth "
                        "being cornered by the storm."),
        "medic": ("medic is the pickup: a downed partner is not a loss "
                  "-- it is 48 ticks of walking; go get them. Your gun "
                  "stays free while you stand the revive, so the only "
                  "real choices are the honest refusals: do not walk a "
                  "nearly-dead body into a camped ghost, and do not stand "
                  "over one lying on ground the ring has already taken -- "
                  "out there the pickup cannot land at all, however long "
                  "you hold it, and nothing will tell you so. Below "
                  "ring_walker, above every fight rung: you cannot revive "
                  "if the ring kills you, and no tag outranks a pickup "
                  "that can still land."),
        "jackal": ("jackal is your signature tag source, wired to join "
                   "WHILE the fight is still live (joinWhen bothWeakened): "
                   "it loiters at earshot until every tracked seat near "
                   "the target reads weakened, then joins -- your hit "
                   "lands inside the SAME 120-tick window as whoever "
                   "already opened the fight, which is the actual "
                   "co-engagement trigger for the Fibonacci stack, not "
                   "just a chat line about it. Stay for TWO -- clustered "
                   "tags in one fight multiply the glory (x2, x4, x8 as "
                   "the streak climbs); scattered pokes never do. Leave "
                   "when the second tag banks or your hp says the streak "
                   "is over. The feed only says a fight HAPPENED, not "
                   "where; move on fights your own tracks can place."),
    },
    canned_turns=[
        {
            # Opening: politics only. The liveness probe proved the native
            # zone-escape reflex + default rotation OUTPLACE any rotation
            # controller we call, so movement is deliberately left to them;
            # the ladder carries what actually bites -- targeting law,
            # truce, and the hp-gated conversion rung. The pact carries the
            # placeholder duo (see PACT_PLACEHOLDER); adjust_entries re-aims
            # it and derives the law's never-list.
            "chat": "Truce first, tags later. Partner, spread on me -- one "
                    "gun always up.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": list(TARGET_LAW_PREFER)}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "spring",
                 # peelHp RAISED (v10) 2->3: shield the ward at half of a
                 # 6-hp seat, not just the last quarter -- the duo-shared
                 # OR-gate (claimAchievement, sim.nim:273-310) means a live
                 # partner mints for BOTH of us every episode, win or lose
                 # (Amendment 6, 774ab1d4); protecting proactively rather
                 # than reactively is a bet that pays under either glory
                 # rule, since it only moves WHEN we shield, never whether.
                 "params": {"leash": [110, 280], "interpose": False,
                            "peelHp": 3}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 4, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Consolidation: NO LONGER minimal -- v11 adds a press-capable
            # controller here (leader-template finding, 9/3: the top two
            # standings' entire edge over ours is an EARLY credit stack --
            # dFirstBlood + 2 early dClosingTime hits landing ~ticks
            # 2098-2458 (8-19% into the match) -- a 27x head-multiplier on
            # their chain vs our 3x. dFirstBlood is the episode's single
            # first kill: jackal cannot claim it (it only JOINS a fight
            # after someone else's tag already landed), so the fix is not
            # "join more fights", it is "stop being structurally unable to
            # FINISH one" -- fire_superiority (press-vs-break) was installed
            # starting at the mid turn only; opening/consolidation ran
            # hold_vs_gun alone, which holds against a gun on us but never
            # presses to close one out. That gap sits exactly across the
            # leader's observed window (turn 2 fires ~30-60s+ under the
            # normal recall cadence, extending into the 87-102s window
            # above). Same structural shape as the endgame standoff bug
            # (75ccf920): a controller that would convert a winnable
            # encounter simply was not on the ladder yet, not a
            # threshold mistuned. Fix: install fire_superiority one turn
            # early, with mid's OWN already-vetted cautious parameters
            # (breakDeficit 2 PARKED, woundedPct 50 -- NOT the endgame's
            # zeroed 0, since a full field of undamaged duos is a genuinely
            # riskier bar to press than a thinned endgame) -- this is
            # widening WHEN the proven mid posture is available, never
            # making it more aggressive than mid already is. jackal rides
            # along for the same reason it rides at mid: it cannot win
            # dFirstBlood, but an early second/third tag in a fight fire_
            # superiority (or the enemy) already opened is still an early
            # dClosingTime candidate, and jackal never initiates on its
            # own -- both its afterKill and bothWeakened triggers require
            # an existing tracked fight, so it adds no early-game risk of
            # its own beyond what a fight already in progress carries.
            "chat": "Holding the truce. We rotate with cover, press what "
                    "we can finish, and bank every life.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": list(TARGET_LAW_PREFER)}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v11 EARLY CREDIT STACK: same cautious params as the mid
                 # turn (see that entry's comment for the breakDeficit/
                 # woundedPct rationale) -- deliberately NOT copying
                 # endgame's woundedPct=0, because the field is still near
                 # full strength here and a parity fight is a genuinely
                 # different bet than the endgame's thinned field.
                 # engageDist 600->750 (v53, FIRE_SUPERIORITY_ENGAGE_DIST):
                 # written literal matches doctrine, same as pressRange/
                 # finishRange -- apply_phase_clamps repins this every send
                 # regardless, but the source stays honest.
                 "params": {"breakDeficit": 2, "coverMax": 260,
                            "engageDist": 750, "finishRange": 140,
                            "pressRange": 220, "woundedPct": 50}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield-close",
                 # COMBAT-CLOSE band (measured revive protocol, 28 leader
                 # tag-backs): revives succeed when the duo is ALREADY
                 # within ~40px at the down (27/28 zero-travel, median
                 # separation 0-15px, successes cluster under 100px) -- the
                 # [100,150] "shield" band below is right for a quiet field
                 # but too loose to land inside that window. Mutually
                 # exclusive with "shield" by entry_id (see gate_open's
                 # bodyguard branch in starter_harness.py): opens only when
                 # either seat has a live enemy tracked or the partner
                 # reads wounded/downed/under fire, hands back to the wider
                 # band the instant the field goes quiet -- the wire ladder
                 # never carries both at once. [40,120] chosen over the
                 # more aggressive [20,100] the data would also support:
                 # fire_superiority's withinFireCone exclusion (a0854837)
                 # only screens OUR OWN press-target choice, not a
                 # stranger partner's fire, so tighter spacing still raises
                 # cluster-fire exposure -- 40 clears the literal 20px
                 # stacking floor with real margin. PARTIAL closure only:
                 # medic's own movement priority still starves behind
                 # ladder.nim's nativeBase branch (see "shield" below), so
                 # a tighter leash is not expected to reach leader parity
                 # on its own.
                 "params": {"leash": [40, 120], "interpose": True,
                            "peelHp": 3}},
                {"play": "bodyguard", "entry_id": "shield",
                 # leashMax TIGHTENED (medic-conversion audit) 200->150:
                 # medic converted 0/96 revivable downs (partner upright at
                 # down) despite being installed+called every turn below
                 # ring_walker -- ladder.nim's nativeBase branch (line ~600)
                 # runs the native zone-escape/default-rotation reflex
                 # INSTEAD OF the whole controller loop whenever it is
                 # armed, so medic's own priority cannot outrank it (this
                 # matches the edge_ride doctrine note above: the native
                 # reflex "outranks every play at the wall"). Direct replay
                 # evidence: the reviver closed >20px toward the ghost in
                 # only 11/96 cases and never got within 60px in 86/96 --
                 # medic's navigate intent is essentially never executed as
                 # movement once a partner is down. zoneReach (only 5-8/96
                 # over-budget) and abortHpFloor (2/96) are NOT the binding
                 # gates. The lever that IS ours to pull: separation AT
                 # down-time. Break-even distance to still land a revive in
                 # the dominant zone-bleedout window (median 103 ticks,
                 # 74/96 of revivable downs) is StandInPx(26) + (103-48
                 # channel ticks) * MaxSpeed/MotionScale (704/256 px/tick)
                 # = ~177px -- but measured separation at down-time medians
                 # 210-217px, ABOVE break-even, with only 52/96 geometrically
                 # reachable even under a zero-latency straight-line walk.
                 # leashMax 150 (< 177px, with margin for pathing/latency)
                 # keeps steady-state duo separation under the break-even
                 # line during the two turns covering 75% of revivable
                 # downs (zone phase z=0.55/0.35), so a down more often
                 # starts inside medic's reach instead of requiring a
                 # cross-zone chase. leashMin held at 100 (selfcheck floors
                 # it) -- tightening the floor risks the friendly-fire loss
                 # mode, a documented worse failure than an unrevived down.
                 # This never fights zone routing: bodyguard's own call
                 # guard already refuses to run outside the safe rect (the
                 # anchored-outside-the-rect disaster, 48% early-mid deaths
                 # in the v8 miner), so tightening the leash only changes
                 # in-zone spacing, never asks anyone to chase into the
                 # storm.
                 "params": {"leash": [100, 150], "interpose": True,
                            "peelHp": 3}},
                {"play": "jackal", "entry_id": "third",
                 # v11 EARLY CREDIT STACK: rides with fire_superiority above
                 # (see that entry's comment) -- same mid-turn params.
                 # v16 ALLY-STACK FIX (measured 2026-09-06, 6-episode v30
                 # decode): named-deed mints sat at 0-2/episode, flat vs the
                 # v27 baseline -- v29's prose doctrine (co-engagement,
                 # Fibonacci stack) registered in the model's OWN reasoning
                 # but never moved a mint, because a deed's class is
                 # ENGINE-DETERMINED by the circumstances of the kill, not
                 # declarable in chat. joinWhen=afterKill is the actual
                 # culprit: per play_sdk/reference/jackal.nim's jwAfterKill
                 # branch, it only joins once `freshKill` fires nearby --
                 # by then the original damager's target is dead and the
                 # survivor is a FRESH, uncontested seat, so our tag lands
                 # solo (k=1, stack x1) no matter how the prompt narrates
                 # "arrive after a fight starts, tag the weakened". Switched
                 # to bothWeakened (jwBothWeakened branch): joins the moment
                 # every known-hp track near the candidate reads weakened,
                 # i.e. WHILE the fight is still trading damage -- our hit
                 # lands inside the SAME 120-tick incident window as
                 # whoever already opened it, which is the literal k>=2
                 # co-engagement trigger for the Fibonacci stack
                 # (recutStackMult, src/ctf/glory.nim). Still gated on an
                 # existing fight in progress (candidate.found required),
                 # so this adds no unprovoked-initiation risk beyond what
                 # afterKill already carried -- it only moves WHEN inside
                 # that fight we join, not whether we hunt alone.
                 "params": {"earshot": 550, "joinWhen": "bothWeakened",
                            "exitAfter": {"kills": 2}}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 4, "detourMax": 350,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Mid: same fire_superiority + jackal ladder the consolidation
            # turn now also carries (v11) -- kill conversion is where monet
            # already led the field; everything else stays with the
            # reflex/default movement.
            "chat": "Feed is ticking. We arrive third, tag the weakened, "
                    "leave paid.",
            "call": {"entries": [
                {"play": "pact", "entry_id": "truce",
                 "params": {"partners": ["seat:0", "seat:16"],
                            "protect": False, "onBetrayal": "returnFire"}},
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": list(TARGET_LAW_PREFER)}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v10: breakDeficit STAYS PARKED at 2 -- "keep fighting
                 # while outgunned" trades win probability for size, and a
                 # self tag-out forfeits the rest of THIS episode's minting
                 # under either glory rule (old hard-win-gate, or Amendment
                 # 6's every-episode-banks -- 774ab1d4 dropping `and
                 # playerWon` at roster.nim:1017): negative sign both ways,
                 # so not re-armed. finishRange is NEW (v10, see
                 # fire_superiority.nim): closes to a tight band ONLY on a
                 # target already known wounded, aimed at the measured 3x
                 # dPointBlankKill gap without breakDeficit's downside.
                 # engageDist 600->750 (v53, FIRE_SUPERIORITY_ENGAGE_DIST):
                 # see the constant's own comment for the GV17 economy
                 # engagement-volume rationale.
                 "params": {"breakDeficit": 2, "coverMax": 260,
                            "engageDist": 750, "finishRange": 140,
                            "pressRange": 220, "woundedPct": 50}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 "params": {"calmTicks": 48, "coverMax": 260,
                            "engageDist": 500}},
                {"play": "bodyguard", "entry_id": "shield-close",
                 # COMBAT-CLOSE band: same rationale and [40,120] band as
                 # the consolidation turn's shield-close entry above --
                 # this is the OTHER turn covering the dominant
                 # zone-bleedout phase (z=0.55/0.35, 75% of revivable
                 # downs). Mutually exclusive with "shield" below by
                 # entry_id.
                 "params": {"leash": [40, 120], "interpose": True,
                            "peelHp": 3}},
                {"play": "bodyguard", "entry_id": "shield",
                 # leashMax TIGHTENED (medic-conversion audit) 200->150: same
                 # break-even rationale as the consolidation turn's shield
                 # entry above -- this is the OTHER turn covering the
                 # dominant zone-bleedout phase (z=0.55/0.35, 75% of
                 # revivable downs).
                 "params": {"leash": [100, 150], "interpose": True,
                            "peelHp": 3}},
                {"play": "jackal", "entry_id": "third",
                 # earshot RE-ARMED (v10) 450->550: a wider loiter net joins
                 # more fights. Under Amendment 6 every joined fight mints
                 # deeds in ALL ~20 episodes/round, not just the ~5 we win --
                 # a clear gain. Under the OLD hard-win-gate rule it is still
                 # a fair bet on its own: earshot only widens WHERE we
                 # loiter, it does not touch exitAfter's 2-kill leash or ask
                 # us to fight outgunned, so unlike breakDeficit it does not
                 # trade away win probability to get there.
                 # v16 ALLY-STACK FIX: joinWhen afterKill->bothWeakened,
                 # same measured rationale as the consolidation turn's
                 # jackal entry above -- this is the OTHER turn that gets
                 # the most fight-loiter time, so it carries the same fix.
                 "params": {"earshot": 550, "joinWhen": "bothWeakened",
                            "exitAfter": {"kills": 2}}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 4, "detourMax": 250,
                            "contested": "avoid"}},
            ]},
        },
        {
            # Endgame: the pact is DROPPED -- said out loud -- so the law
            # releases the truce seats on this same call. fire_superiority
            # is the DRIVING controller on contact -- press-vs-break is how
            # a winning fight gets finished (the engine's own bots stall at
            # full health and let the ring decide; a draw pays nobody) --
            # with crossfire beneath it owning the duo's shape off contact.
            "chat": "Field is thin: our truce ends here, no hard feelings. "
                    "Partner, on me -- we finish.",
            "call": {"entries": [
                {"play": "target_law", "entry_id": "law",
                 "params": {"prefer": list(TARGET_LAW_PREFER)}},
                {"play": "ring_walker", "entry_id": "ring",
                 "params": {"inset": 64, "leadTicks": 240}},
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 160->0. The v10 note below is SUPERSEDED, not
                 # deleted, because its conclusion still holds and its
                 # reasoning no longer reaches it: v10 shrank the storm-dip
                 # budget in the endgame only, ranking "alive at Last Light"
                 # above "partner down-then-revived". zoneBlocksRevive
                 # (armed 0.7.323, r3965) settles it in every phase -- a
                 # ghost on ground the ring has taken cannot be revived at
                 # all, so a dip buys nothing anywhere and the budget is 0
                 # in all four turns. It is no longer a ranking call.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # v10 AMENDMENT (owner field report 2026-09-02): woundedPct
                 # ZEROED 25->0 for the ENDGAME TURN ONLY -- kills the exact
                 # standoff the owner watched happen live: a tied, fully-
                 # healthy fight (ourGuns == theirGuns, nobody wounded) fell
                 # through fire_superiority.nim's own "Even: hold at cover"
                 # branch (the play's last fallback when neither `superior`
                 # nor `inferior` fires) and just stood there, paint can in
                 # hand, until the ring decided it for us. `superior` reads
                 # `ourGuns > theirGuns or (ourGuns >= theirGuns and
                 # wounded*100 >= woundedPct*theirGuns)`; at woundedPct=0 the
                 # wounded clause is trivially true, so ANY numeric parity or
                 # better now PRESSES instead of holding. This does NOT touch
                 # `inferior` (theirGuns - ourGuns >= breakDeficit) at all --
                 # a fight we are actually behind in still breaks to cover
                 # unchanged, so this is "take the fight we can already win,"
                 # never "brawl while outgunned." Press still respects the
                 # point-blank inversion: an unknown/healthy target keeps the
                 # wider pressRange band, only a CONFIRMED-wounded target
                 # (hp<=2) gets closed to finishRange. Scoped to the endgame
                 # turn alone (mid-turn keeps woundedPct 50) because this is
                 # specifically the small-zone, few-duos-left failure mode
                 # the report described, not a general license to brawl
                 # early. breakDeficit STAYS PARKED at 2 (see the mid-turn
                 # note -- negative sign under either glory rule, and
                 # orthogonal to this fix: the standoff was an EVEN fight,
                 # never an outgunned one, so the break threshold was never
                 # the lever that needed to move). finishRange NEW (v10),
                 # tighter than mid's 140: fewer duos left means less flank
                 # risk while closing on a target already known wounded.
                 # engageDist 600->750 (v53, FIRE_SUPERIORITY_ENGAGE_DIST):
                 # see the constant's own comment for the GV17 economy
                 # engagement-volume rationale; flat 750 in endgame too,
                 # same as default -- this lever is not phase-split.
                 "params": {"breakDeficit": 2, "coverMax": 200,
                            "engageDist": 750, "finishRange": 120,
                            "pressRange": 220, "woundedPct": 0}},
                {"play": "crossfire", "entry_id": "shape",
                 "params": {"spacing": [120, 280], "minAngle": 36}},
                {"play": "supply_run", "entry_id": "bank",
                 "params": {"whenHpBelow": 4, "detourMax": 150,
                            "contested": "avoid"}},
            ]},
        },
    ],
    recall_count=5,
    recall_seconds=30.0,
    # Awareness-audit cadence: a lost/downed partner or an imminent ring
    # while exposed may cut the recall gap to 5s. Budget (max_calls) is
    # untouched -- these are rare edge events, not extra spend.
    priority_recall_floor=5.0,
    # Upstream's own measurement note (layer_ladder): hold-until-fight-heard
    # plus the zone reflex out-survives active riding, and it matches this
    # persona's doctrine -- jackal IS monet's patience.
    base_play="jackal",
    include_kill_feed=True,
    partner_focus=True,
    adjust_entries=adjust_entries,
    apply_phase_clamps=apply_phase_clamps,
    extra_chat=extra_chat,
    extra_summary=awareness_lines,
)

if __name__ == "__main__":
    sys.exit(starter_harness.main(PERSONA))
