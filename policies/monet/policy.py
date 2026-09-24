#!/usr/bin/env python3
"""MONET: the house test policy. Field-reading, duo-tight, political.

Fourth persona on the starter seam and the painter after Picasso. The three
starters each embody one instinct; MONET carries the measured doctrine of the
whole research program, translated to the play-calling layer:

* the summary carries BOTH the partner's state and the kill feed (the two
  observables the doctrine actually keys on),
* four model turns spread across the match arc (opening / consolidation /
  mid / endgame) instead of a burst of early re-calls,
* ``adjust_entries`` enforces the three non-negotiables structurally:
  TRUCE HONOR -- every pact's partners are mirrored into every target_law
  never-list, so betrayal requires explicitly dropping the pact and can
  never be an accident of aim; FIRE DISCIPLINE -- the duo partner is on the
  never-list whether or not the model remembered (a partner tag is -60g).
  GV59 (engine tree decb97fd, live build 0.7.347+; sim.nim
  downFriendly ~2580-2601) repriced a pact-ally tag onto the SAME -60g dTeamKill class
  as a partner tag -- previously an honorable kill. TRUCE HONOR was built
  for politics before that repricing existed, and needed no code change to
  become the correct fire-discipline mechanism for it too: mirroring pact
  partners into never already keeps target_law off them, so this
  mechanism (not new prose) is what actually protects the score now;
  CONVERSION -- a supply_run rung is guaranteed in every ladder, because the
  lineage's oldest measured failure is winning the fight and never banking
  the life,
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

# v59 RETURN FIRE (owner brief §30 2026-09-21): opt Monet, and only Monet,
# into hold_vs_gun's aggressor-only gate (starter_harness.gate_open) --
# module-level assignment on the shared `starter_harness` module, same
# scoping pattern `PERSONA` already relies on for `_log`. The three starter
# personas (aggressive/cautious/collaborative) never import this module, so
# their copy of the flag stays at starter_harness's own default (False).
starter_harness.HOLD_VS_GUN_AGGRESSOR_GATE = True

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
# shooting us, for the entire episode, on a guess. Only a seat that has
# actually named US back in chat ("invited" -- they proposed first;
# "reciprocate" -- they named us on a later turn) is confirmed enough to
# earn the no-fire guarantee; fallback/retry stay named on the wire (so a
# genuine mutual sim pact can still form if THEY also name us) but do not
# reach target_law.never until confirmed.
CONFIRMED_PACT_REASONS = {"invited", "reciprocate"}

# v47b (owner direction 2026-09-09): more FORMED pacts is the lever for more
# JointAct / pact-stack / revive opportunities (GV15 made JointAct pact-only
# -- see doctrine ledger ctf-joint-action-pays-without-a-pact.md, OBSOLETE at
# GV15). Raising the partner cap 3 -> 5 does not by itself remove more
# targets from fire, because the confirmed-only never-list gate above is
# untouched: only "invited"/"reciprocate" partners ever reach
# target_law.never, no matter how high this cap goes. Checked for a lower
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

# FIRE_SUPERIORITY BREAK_DEFICIT WIRE FIX (v62, FOUR DIGITS lane,
# 2026-09-23): the fourth field folded into the SAME per-entry pin loop as
# PRESS_RANGE/FINISH_RANGE/ENGAGE_DIST above (search "breakDeficit (v62" in
# apply_phase_clamps). W2 (four-digits/w2-v61-persist, 480530f9) raised
# fire_superiority.nim's OWN manifest/readParams default 2->4
# (RaisedBreakDeficit) and updated the 3 canned_turns literals that used to
# pin an explicit 2. The turn-wire read (2026-09-23,
# ~/.ctf/handoff/2026-09-23-xp-turn-wire.md) found this ALREADY correct on
# 100% of hosted fs-present sent calls (0/422 wrong) -- so this pin is a
# belt-and-suspenders addition, not a fix for an observed leak: it closes
# the same GATED_PLAY maintenance-bypass class PIN_BYPASS_AUDIT (v52)
# fixed for pressRange/finishRange/engageDist so a future drift back to 2
# (a stale cached ladder, a model turn that copies an old value) still
# cannot silently reach the wire. Flat 4 in both phase buckets, same shape
# as PRESS_RANGE/ENGAGE_DIST above (not phase-split; kept as a dict for the
# same future-proofing reason those two are).
FIRE_SUPERIORITY_BREAK_DEFICIT = {"default": 4, "endgame": 4}

# FIRE_SUPERIORITY WHEN GUARD (W11, FOUR DIGITS lane v63, 2026-09-23/24,
# ctf-fire-superiority-is-the-passing-controller-only-a-fifth-of-the-match):
# the STRUCTURAL fix v62's own NOFIGHTPIN comment deferred to a sibling
# worker -- "the engine's real per-tick dynamic-yield mechanism is a
# wire-level `when` guard ... but starter_harness.layer_ladder
# unconditionally strips `when` ... so this lever cannot reach it without
# editing policies/starters/common/ (shared, off-limits for this lane)."
# This lever edits that shared file (see starter_harness.KEEP_WHEN_PLAYS,
# a mutable opt-in set that module now exposes for exactly this) and pairs
# it with a `when` value here. v62's FIGHT PIN block above already solved
# CANDIDATE presence (fire_superiority reliably lands in the PRE-gate
# `entries`, ranked above ring_walker, on the call path) -- this lever is
# what lets that candidate survive layer_ladder's send-time gate_open
# snapshot AT ALL: a fire_superiority entry carrying `when` and opted into
# KEEP_WHEN_PLAYS bypasses that snapshot entirely in layer_ladder, landing
# on the WIRE unconditionally, while the ENGINE's own per-tick guard
# (ladder.nim:377-382 guardPasses, evaluated fresh every tick from
# src/shell/episode.nim:526-596 playGuardContext -- NOT
# players/onepage/onepage.nim, a different consumer of the same
# policy_page.nim expression VM serving the unrelated LLM one-page-policy
# path) decides whether it actually STEPS this tick. This is what makes
# fire_superiority's WIRE presence (not just its wanted-ladder candidacy)
# stop tracking the ~21% send-time snapshot and start tracking the ~67%
# any-enemy-in-view figure instead, without the monopolization risk
# NOFIGHTPIN's own comment correctly flagged for an all-sources INSERT
# (this lever changes nothing about insertion -- FIGHT PIN still owns
# that, still call-path-only -- only about whether an entry ALREADY on
# the list, from any source including a maintenance resend, keeps its
# `when` and is trusted by the engine to yield on its own).
#
# playGuardContext's `world.nearest_enemy_dist` (px to the nearest track
# this seat's own body-level memory holds; -1 sentinel if none --
# src/ctf/policy_page.nim DefaultPaths) is the closest available proxy for
# fire_superiority.nim's own internal "their guns" gate
# (fire_superiority.nim:415-438: a fresh track within engageDist) -- not
# byte-identical (the engine's own track memory carries no exposed
# per-tick freshness predicate the way the wasm's internal FreshGunTicks=60
# window does), but `world.enemy_count > 0` is an exact presence check
# (episode.nim increments it once per non-ally track, unconditionally).
#
# GUARD VARIANTS (W12, FOUR DIGITS lane v64, 2026-09-24, ~/.ctf/handoff/
# 2026-09-22-four-digits-lane.md "W11 FINAL"/D25): the rig proved v63's own
# guard (v0 below, <=750 = FIRE_SUPERIORITY_ENGAGE_DIST, the params clamp
# the WIRE FIX loop pins onto the entry) raised fire_superiority's passing
# share 21%->49-67%, but ring_walker/jackal got ~0 ticks in 2 of 3 seeds:
# not a lockout (172 ticks/seed where fs had no track and another
# controller stepped) but genuine contention -- fs wins first-match
# whenever ANY track sits within 750px, which is wider than the wasm's own
# engage band. Two tighter variants, both cheap under GuardDepthMax=4 /
# GuardNodeMax=64 (src/shell/types.nim:461-462) and both built from paths
# already in src/ctf/policy_page.nim's DefaultPaths (world.in_zone is
# pkBool, so `["get","world.in_zone"]` is a legal bare AND-term -- see
# policy_page.nim:594/616-624 -- no comparison wrapper needed):
#   V1 "tight": engageDist 750->500. 500 is NOT FIRE_SUPERIORITY_ENGAGE_DIST
#     (that constant, and the params clamp it feeds, are untouched by this
#     lever) -- it is hold_vs_gun.nim's own engageDist default
#     (policies/monet/plays/hold_vs_gun.nim:117, "{...engageDist":{"default":
#     500...) -- the wasm's actual stand-and-fight engage band, tighter
#     than fire_superiority's own 600 default and much tighter than the
#     750 doctrine clamp. Closing the guard to the band the wasm itself
#     fights at should shed the widest, weakest tail of contention.
#   V2 "tight+zone": V1 AND `world.in_zone` -- fs never holds the seat
#     while outside the CURRENT zone rect, so ring_walker (whose whole job
#     is getting back inside before the native 72-tick hazard reflex fires,
#     src/shell/episode.nim) gets first claim on the seat out-of-zone, and
#     fs still owns it the instant a fight is on AND we're already safe.
#   V3 "tight+zone+hp": V2 AND `self.hp_frac > FS_WHEN_GUARD_HP_FLOOR` --
#     cheap (one more AND term, well under both caps) so included per the
#     brief's "only if cheap" -- yields the seat below the floor so a
#     downed-adjacent seat doesn't stand and trade instead of disengaging.
#     Not the recommended default (see FS_WHEN_GUARD_VARIANT below): no rig
#     evidence yet that low-hp standoffs are a real loss driver here, and
#     it is one more term than the rig table was built to distinguish.
FS_WHEN_GUARD_DIST_TIGHT = 500  # hold_vs_gun.nim's own engageDist default,
                                # NOT FIRE_SUPERIORITY_ENGAGE_DIST (stays 750
                                # for the params clamp below, untouched).
FS_WHEN_GUARD_HP_FLOOR = 0.25   # V3 only; a bare guess, not yet rig-tuned.

FS_WHEN_GUARD_V0_750 = ["and",
                        [">", ["get", "world.enemy_count"], 0],
                        ["<=", ["get", "world.nearest_enemy_dist"],
                         FIRE_SUPERIORITY_ENGAGE_DIST["default"]]]
# v63 as-shipped, kept byte-identical for the rig's own A/B baseline and as
# an instant rollback target via FS_WHEN_GUARD_VARIANT below.

FS_WHEN_GUARD_V1_TIGHT500 = ["and",
                             [">", ["get", "world.enemy_count"], 0],
                             ["<=", ["get", "world.nearest_enemy_dist"],
                              FS_WHEN_GUARD_DIST_TIGHT]]

FS_WHEN_GUARD_V2_TIGHT_ZONE = ["and",
                               [">", ["get", "world.enemy_count"], 0],
                               ["<=", ["get", "world.nearest_enemy_dist"],
                                FS_WHEN_GUARD_DIST_TIGHT],
                               ["get", "world.in_zone"]]

FS_WHEN_GUARD_V3_TIGHT_ZONE_HP = ["and",
                                  [">", ["get", "world.enemy_count"], 0],
                                  ["<=", ["get", "world.nearest_enemy_dist"],
                                   FS_WHEN_GUARD_DIST_TIGHT],
                                  ["get", "world.in_zone"],
                                  [">", ["get", "self.hp_frac"],
                                   FS_WHEN_GUARD_HP_FLOOR]]

FS_WHEN_GUARD_VARIANTS = {
    "v0_750": FS_WHEN_GUARD_V0_750,
    "v1_tight500": FS_WHEN_GUARD_V1_TIGHT500,
    "v2_tight_zone": FS_WHEN_GUARD_V2_TIGHT_ZONE,
    "v3_tight_zone_hp": FS_WHEN_GUARD_V3_TIGHT_ZONE_HP,
}

# DEFAULT (W12 rig recommendation, 3 seeds/variant, eval_mapspec_r5733,
# aggregate_tickshare.py's passing-controller share -- see this branch's
# handoff report for the full table): "v1_tight500", NOT "v2_tight_zone" --
# the zone term was the pre-rig hypothesis but the MEASURED numbers argue
# against it. Overall passing share: v0 fs=52.4% rw+jk=2.29% native=32.7%;
# v1 fs=44.5% rw+jk=2.66% native=35.9%; v2 fs=48.5% rw+jk=1.43% native=
# 37.5%. Restricted to ticks with a confirmed live track (trackHit==1,
# "after first contact"): v0 rw+jk=0.00%, v1=1.07%, v2=0.63%. On every
# measured axis v1 beats v2: higher rw+jk (both instruments), lower native
# share regression vs v0 (+3.2pp vs +4.7pp), and v1 alone already improves
# kills/seat (1.42->2.25 mean) and median death tick (1356->2652) over v0
# with no downside. Likely why: FIGHT PIN (v62) ranks fire_superiority
# ABOVE ring_walker on the wire (asserted in selfcheck.py), so ticks fs
# yields go first to whatever OTHER guarded engage play sits between them
# (hold_vs_gun measured at 15-22% of contact ticks in this rig) before
# ring_walker ever sees them -- adding world.in_zone to the guard does not
# change that ordering, it only changes WHEN fs itself yields, so it
# redistributed share toward native/hold_vs_gun rather than ring_walker.
# NONE of the three variants clear the ≥10% rw+jk-after-contact target on
# this rig (v1's 1.07% is the closest) -- that gap looks like a ladder-
# ORDERING question (fire_superiority vs ring_walker priority), not a
# guard-tightness question, and reordering FIGHT PIN's own priority is out
# of this build's scope (v62's ordering is deliberate, asserted by its own
# selfcheck). Flagging for a follow-up, not fixing here. Flip this string
# (never a container env var, matching NOFSWHEN's own house rule) to
# rollback to "v0_750" or try "v2_tight_zone"/"v3_tight_zone_hp".
#
# v65 ORDER FOLLOW-UP (FOUR DIGITS lane, 2026-09-24): the ladder-ORDERING
# fix flagged above landed here, NOT as a rename of FIGHT PIN's own
# fs-vs-ring_walker priority (unchanged -- a live fight with a track still
# beats ring_walker, per W3's invariant) but as RING CONTROL's own reorder
# scope: ring_walker used to reorder below BOTH fire_superiority AND
# hold_vs_gun (treating them as one "engage" tier); it now reorders below
# fire_superiority ONLY, and a new, separate pin holds hold_vs_gun below
# ring_walker on every send path. Considered (and rejected) giving
# hold_vs_gun the SAME `when` guard as fire_superiority: hold_vs_gun's
# whole job (mechanism (B), see the module-level RETURN FIRE comment) is
# returning fire from an aggressor BEARING with no track at all, and the
# engine's guard vocabulary (playGuardContext) has no aggressor-freshness
# term to express that precondition -- FS_WHEN_GUARD reused verbatim would
# gate hold_vs_gun on a TRACK existing, defeating the no-track case it
# exists to cover. A reorder changes nothing about whether hold_vs_gun
# fires, only which controller wins the seat first when both are
# candidates.
FS_WHEN_GUARD_VARIANT = "v1_tight500"

FS_WHEN_GUARD = FS_WHEN_GUARD_VARIANTS[FS_WHEN_GUARD_VARIANT]
# Every downstream consumer (the three canned-turn literals, and the
# apply_phase_clamps when-pin loop below that repins it on every model/
# reemit/maintenance send) reads `FS_WHEN_GUARD` itself, never a variant
# constant directly -- so selecting a variant here is the ONLY edit needed
# to change what ships; nothing else in this file names a variant by name.

NOFSWHEN = False  # opt-out kill switch (never armed via container env, per
                  # house rule, orthogonal to NOFIGHTPIN/NORINGCONTROL/
                  # NOFIREPERSIST/NOCLOSEBIAS -- flipping this one alone
                  # must not silently disable any of the others) -- flip
                  # True to fall back to byte-identical pre-lever
                  # behaviour: fire_superiority carries no `when`,
                  # starter_harness.KEEP_WHEN_PLAYS never gains
                  # "fire_superiority", and its python-side gate_open
                  # send-time snapshot governs wire presence exactly as
                  # before this lever existed (FIGHT PIN's own candidacy
                  # guarantee is unaffected either way).
if not NOFSWHEN:
    # Opt into starter_harness's KEEP_WHEN_PLAYS (see that module's own
    # comment on the set): a fire_superiority entry that carries `when`
    # keeps it through layer_ladder's strip AND skips gate_open's own
    # snapshot there, in favour of the engine's per-tick guard above. A
    # shared, Monet-set module attribute -- same pattern as
    # HOLD_VS_GUN_AGGRESSOR_GATE above -- so this is a no-op for any other
    # persona's process, which never imports this module.
    starter_harness.KEEP_WHEN_PLAYS.add("fire_superiority")

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

# ISOLATED-FIRST OPENING PREFER (v61 lever C, FOUR DIGITS lane, branch
# four-digits/w2-v61-persist, pre-registered 2026-09-22): TARGET_LAW_PREFER
# above optimizes CHAIN SPEED once a fight is already live -- every token
# but "isolated" (weakened/revenge/bounty) requires a fight already in
# progress, so in the OPENING, before any of our tags have landed, it is a
# coin-flip among candidates none of which can carry those tags yet.
# jordan-decode-tables.md: Jordan's first-blood rate is 8.33% (12/144) vs
# our 4.86% (7/144) -- the gap this lever targets is P(1st paying tag), a
# DIFFERENT metric from the conditional-chain-length gap TARGET_LAW_PREFER's
# own ordering already addresses (see that constant's comment above), so
# this reorders WHO we pick first without touching who we pick once a
# fight is running.
#
# PHASE WINDOW: reuses OPENING_HUNTER's (v57) own proven predicate --
# tick < OPENING_TICKS AND our team has landed no kill yet this episode --
# via the SAME persisted latch (_update_opening_hunter,
# pact_state["_first_kill_tick"]), not a second copy of it. That predicate
# is read in `apply_phase_clamps`, the ONE clamp point every wire send
# shares (model call, either reemit helper, or a maintenance resend --
# see that function's own docstring), the exact place the v57/v58/v59/v60
# phase-scoped constants above already prove out this wire precedence: a
# clamp written there overrides whatever a canned_turns literal, a
# model-authored call, or a stale cached ladder proposed, on every path,
# not just the one that happened to run first. So the five
# `list(TARGET_LAW_PREFER)` literals below (opening/consolidation/mid/
# endgame canned turns plus the law_never fallback-creation branch) are
# left untouched as their own byte-identical seed values -- this lever
# does not edit them -- because the clamp in apply_phase_clamps rewrites
# every target_law entry's `prefer` field on its way to the wire
# regardless of which literal produced it, the same mechanism that already
# pins fire_superiority's pressRange/finishRange/engageDist over a model's
# or a canned turn's own proposed value.
#
# emit_validator.nim:146-184 (parseCombatPolicy's "prefer" case) checks
# membership/no-dup/count<=4 only -- order is never validated, so this
# reorder is schema-legal by construction, the same wire-precedence fact
# the module comment above TARGET_LAW_PREFER already established.
#
# NOOPENPREFER is a plain kill switch, same convention as OPENING_HUNTER/
# HEAT_HUNTER/RETURN_FIRE/RETURN_FIRE_RANGE: set True to fall back to
# byte-identical TARGET_LAW_PREFER ordering in the opening too, without
# removing this block. Never read from a container env var (owner ruling
# on arming levers) -- a plain module constant only.
NOOPENPREFER = False
ISOLATED_FIRST_PREFER = ("isolated", "weakened", "revenge", "bounty")

# HEAT-WINDOW AGGRESSION LOCK (v56, cap-decomp n=14 read: 0/14 cap-hitters
# won their round, 11/14 had no pact -- the driver is the HEAT ladder, and
# the measured gap is CONDITIONAL FOLLOW-THROUGH: our P(2nd heat-paying
# deed | 1st, within the decay window) is 14.3% vs 28.6% for the best
# opponent sampled, while our P(1st) is already at parity. This does not
# chase more opening kills; it keeps the seat in contact after the FIRST
# one so a second can land before the ember clock resets.
#
# WINDOW: 270 ticks mirrors HeatDecayTicks (src/ctf/glory.nim:1093 pinned
# by the WHY brief) -- the exact quiet-tick span before heatCool
# (sim.nim:254-259) subtracts embers. No wire field surfaces the live
# ember/heat state itself (checked play_view.schema.json in full: no
# "heat"/"ember" key anywhere), so this is NOT a direct heat-state read --
# it is a proxy trigger on the nearest observable that pays heat: a KILL
# credited to our own team. kill_feed (schema $comment: "window 240 ticks,
# <=32 most recent first") carries killer_team + tick per entry, and
# EVERY kill deed (including the class-x1 commons four the WHY brief
# names) has nonzero drama and so pays heat -- so "our team is credited as
# killer_team in kill_feed" is a sound, source-grounded stand-in for "a
# heat-paying deed landed," even though it necessarily misses a heat-
# paying ASSIST that never itself produces a kill_feed row (kill_feed has
# no assist field -- see RISKS in the ship report).
HEAT_WINDOW_TICKS = 270
# Deliberately tighter than FINAL4_DETOUR_MAX (150): the final-four clamp
# is a standing endgame posture, this is a short, self-clearing lock meant
# to hold the seat IN CONTACT immediately after a kill, when a wandering
# detour is most costly. Not the same lever, not the same constant --
# BINDING CONSTRAINT 4 leaves FINAL4_DETOUR_MAX itself untouched.
HEAT_WINDOW_DETOUR_MAX = 100

# OPENING HUNTER (v57, pre-registered lever, owner brief §8 2026-09-18,
# WIN ANATOMY replay read n=33 wins/25 losses SUM-era): the opening CALL is
# byte-identical in wins and losses -- pact + target_law + scatter -- but
# winners then run Monet's own winning recipe (one early weighted-class
# kill that lights heat, then the multiplied second) while our losses
# NEVER reach heat rung 1 (0/25). scatter's own manifest brief says
# plainly what it does: walk away from the nearest tracked enemy (or
# toward zone centre with nothing tracked) for the opening ticks -- an
# EVASIVE posture, the opposite of the press this lineage needs to ever
# reach the HEAT ladder's first rung. This is ONE lever, isolated: while
# the match is still inside the opening window and our team has not yet
# banked a kill, swap the play, not the numbers -- fire_superiority's own
# pins (FIRE_SUPERIORITY_PRESS_RANGE/FINISH_RANGE/ENGAGE_DIST, unchanged
# by this block) still decide press/finish/engage, so the read isolates
# the play swap alone.
#
# WINDOW: 1500 ticks (62.5s at 24 ticks/s) is a generous read of "the
# opening" against the win-anatomy sample's death-tick medians (1421 wins /
# 1347 losses) -- long enough to cover the first engagement window measured
# there without reaching into the mid-match. PRIMARY metric (pre-registered
# BEFORE this build): per-episode P(win), baseline 4.91% (33/672,
# r5519-r5581); KEEP if >= 6.5%, ROLL BACK if < 4.0% or a guardrail trips
# (see the owner brief for the full guardrail list -- shots/1000 alive
# ticks, P(>=1 kill), weighted-class kills/ep, P(heat rung>=1)).
#
# KILL LATCH, not a recurring window (unlike HEAT_WINDOW_TICKS above): "our
# team has landed no kill yet in this episode" is a ONE-TIME gate -- once
# true, permanently false for the rest of the match, even though kill_feed
# itself is only a 240-tick trailing window (schema $comment) that would
# otherwise let a kill scroll back out of view. See _update_opening_hunter,
# which persists the fact onto pact_state (the SAME dict _update_heat_window
# shares) exactly once, and never clears it.
#
# OPENING_HUNTER is a plain kill switch: flip to False to fall back to
# byte-identical v56 behaviour without removing this block.
OPENING_TICKS = 1500
OPENING_HUNTER = True

# HEAT-WINDOW HUNTER (v58, pre-registered lever, owner brief §23
# 2026-09-20, card 242c7af8/epic 3e44d582): OPENING_HUNTER above only
# holds the press until our team's FIRST kill of the episode -- after
# that it never fires again, even while heat is still lit, and the seat
# falls back to jackal-loiter on every later contact. The measured gap
# is CONDITIONAL FOLLOW-THROUGH: our P(2nd heat-paying deed | 1st,
# within the 270-tick decay window) is 28.1% vs the leader's ~37%, while
# our P(1st) is already near parity. This lever re-arms the SAME
# play-swap (strip scatter, force fire_superiority; doctrine numbers
# untouched) for HEAT_WINDOW_TICKS after EVERY kill our team is
# credited, not just the first -- reusing the exact recurring clock
# `_update_heat_window` already tracks for the v56 AGGRESSION LOCK
# detourMax pin below, not a second window or a new constant.
#
# PRIMARY metric (pre-registered BEFORE this build): per-episode
# P(win), baseline 6.87% [5.48,8.57] vs v57 (late third 5.36%). KEEP if
# >= 8.0% or CI floor > 6.5%; ROLL BACK if < 5.0% or a guardrail trips
# (death tick median, tracebacks, wire clamp/window agreement -- see the
# owner brief for the full list).
#
# HEAT_HUNTER is a plain kill switch, same convention as OPENING_HUNTER:
# flip to False to fall back to byte-identical v57 behaviour (opening
# latch only, no re-arm after later kills) without removing this block.
# It gates ONLY the play-swap use of the heat-window clock below; the
# v56 AGGRESSION LOCK's own detourMax pin stays keyed on the raw
# predicate, unconditional on this switch -- see apply_phase_clamps.
# v61: a2fa8551 base behaviour; later levers off pending a powered read.
HEAT_HUNTER = False

# RETURN FIRE (v59, pre-registered lever, owner brief §30 2026-09-21, from
# the FIRST-FIGHT ANATOMY read, handoff §29, n=1,171 seat-episode rows):
# OPENING_HUNTER/HEAT_HUNTER above both press once a live enemy TRACK is in
# view -- fire_superiority's own gate needs one (starter_harness.gate_open,
# `facts["enemies"]`). The measured gap sits one step earlier: when the
# ENEMY fires first, we land the first tag only 8.9% [5.4,14.4] of the time
# (14/157) vs 15.9% [12.5,20.2] pooled for the three measured leaders
# (55/345, p=0.034) -- under fire first we stalemate (33.8%) or die (38.9%)
# instead. Cause on the wire: an attacker who has hit us but never entered
# our tracked-enemy list leaves fire_superiority's gate closed (it has
# nothing to press toward) and jackal ("join only when cheap") driving,
# so the seat eats hits with no return posture at all.
#
# SCHEMA EVIDENCE (src/shell/schemas/play_view.schema.json): `aggressors`
# (lines ~266-290) is victim-private hit feedback against SELF, window 120
# ticks, <=16 rows, each `{tick, dir_brads, seat?}` -- `seat` omitted when
# the shooter was not visible at the moment of the hit, and there is NO
# position field at all, ever (bearing only). `tracks` (lines ~173-226,
# what fire_superiority.nim and hold_vs_gun's OWN track-distance branch
# both read) requires `{seat, team, pos, fresh_tick}` -- a real 2D point.
# So an aggressor row can never be turned into a synthetic track entry:
# fire_superiority.nim's press/break arithmetic (policies/monet/plays/
# fire_superiority.nim `play_step`) needs `track.pos` for every distSq/
# projectFrom call and never reads `decoded.aggressors` at all -- forcing
# its harness gate open with no real point would just hand it nothing to
# navigate toward (`theirGuns == 0` immediately holds). Mechanism (A) from
# the owner brief is DEAD on the wire for this reason and was not used.
#
# MECHANISM CHOSEN (B): hold_vs_gun (policies/monet/plays/hold_vs_gun.nim)
# is Monet's OTHER custom controller, built for exactly this degraded case
# -- its own header says so directly: "Aggressor rows carry a bearing, not
# a position (SdkAggressor.dirBrads) ... under fire the play stands its
# ground facing the threat (body-side owns facing/fire) and will only
# reposition to cover that keeps a sightline on the gun; it never
# navigates directly away from the freshest aggressor bearing" (never
# turn-your-back doctrine, ported from Picasso). Its `play_step` reads
# `decoded.aggressors` directly (hold_vs_gun.nim ~lines 309-330) and needs
# no track at all. The one gap: hold_vs_gun's own HARNESS gate
# (starter_harness.gate_open) was ALSO track-distance-only
# (`facts["nearest_enemy"] <= engageDist`), so forcing it into `entries`
# alone would still get it stripped by layer_ladder with no track in view
# -- closed by HOLD_VS_GUN_AGGRESSOR_GATE (persona-scoped harness change,
# see the import-time flag above and gate_open's hold_vs_gun branch).
#
# RETURN_FIRE_TICKS: how long the forced hold_vs_gun entry persists in
# `entries` after the LAST incoming hit (see _update_return_fire, same
# monotonic-latch shape as _update_heat_window). 120 mirrors the wire's
# own `aggressors` window (schema $comment: "window 120 ticks") -- the
# harness gate (AGGRESSOR_FRESH_TICKS, starter_harness.py) uses the exact
# same number so the two windows never disagree about whether we are
# still "under fire."
#
# MUTUAL EXCLUSION with fire_superiority (fixture ii): the trigger below
# only inserts hold_vs_gun when fire_superiority's OWN gate
# (`starter_harness.gate_open`) would NOT open on this call -- i.e. no
# live track. When a track IS in view, fire_superiority (via OPENING_
# HUNTER/HEAT_HUNTER or the model's own choice) already owns the
# engagement and hold_vs_gun is never inserted, so the wire is unchanged
# from v58 whenever a track exists. engageDist/pressRange/finishRange, the
# opening/heat hunter blocks, and the detour clamps are all untouched by
# this lever.
#
# RETURN_FIRE is a plain kill switch, same convention as OPENING_HUNTER/
# HEAT_HUNTER: flip to False to fall back to byte-identical v58 behaviour
# without removing this block (see apply_phase_clamps).
# v61: a2fa8551 base behaviour; later levers off pending a powered read.
RETURN_FIRE_TICKS = 120
RETURN_FIRE = False

# RETURN FIRE FROM RANGE (v60, pre-registered lever, owner brief §37
# 2026-09-21, from UNDER-FIRE DIAG READ handoff §36, n=24 eps / 839 [diag]
# lines): the block above only ever fires when fire_superiority's OWN gate
# is CLOSED (no live track). But 67.1% of under-fire states with the gate
# OPEN (a live track exists) still never return fire, because the nearest
# tracked enemy sits beyond fire_superiority's own pressRange (220px):
# P(fire within 120t) is 22.8% at <=220px vs 2.5% at 220-750px -- read
# `fire_superiority.nim play_step`: `if bestDistSq <= sq(band): return
# emitHoldIfChanged()` is the ONLY path that holds/fires; outside band it
# always emits a Navigate("press") goal instead, so the body never gets to
# finish the engagement from where we already stand while taking hits.
#
# MECHANISM CHOSEN (A), not (B): `hold_vs_gun.nim play_step` has no
# equivalent close-in step anywhere in it -- every branch (hot/aggressor,
# not-hot/tracked-enemy-shadow, calm fallback) resolves to
# emitHoldIfChanged() or a facing/cover move that explicitly never
# advances toward the enemy (`movesAwayFromGun`/`advancesAcrossOpen` both
# forbid it). That is its whole design ("never turn your back on a live
# gun," ported from Picasso) -- it returns fire from wherever we already
# stand, at ANY range, by construction. So this block installs hold_vs_gun
# AHEAD of fire_superiority rather than raising fire_superiority's own
# pressRange (mechanism (B), unused -- RANGE_RETURN_PRESS is kept defined
# per the pre-registered lever spec but the pin loop below never reads it).
# hold_vs_gun's own harness gate is already open here (this predicate
# REQUIRES a live track, i.e. fire_superiority_open True, so
# starter_harness.gate_open's ordinary track-distance branch for
# hold_vs_gun opens on its own engageDist, and/or the v59 aggressor-gate
# OR-clause is already open too, since we are under fire) -- nothing new
# needed on the harness side.
#
# ORDERING: starter_harness.layer_ladder's `gated` bucket is built by
# scanning `entries` ONCE, in order, appending whichever gated play's own
# gate_open() is True -- so `entries` INPUT ORDER is exactly the final
# wire ladder order among gated plays (verified by reading layer_ladder
# directly, not assumed). Unlike the RETURN_FIRE block above -- where
# fire_superiority_open is guaranteed False whenever it fires, so ordering
# never mattered -- this predicate requires fire_superiority_open True,
# meaning BOTH gates can be open on the same call. So this block always
# INSERTS hold_vs_gun at entries[0] (never appends) to guarantee it
# precedes every fire_superiority entry already on the list, however it
# got there (model call, opening/heat-hunter install, or a prior turn's
# own return-fire-range call).
#
# RETURN_FIRE_RANGE is a plain kill switch, same convention as
# RETURN_FIRE/OPENING_HUNTER/HEAT_HUNTER: flip to False to fall back to
# byte-identical v59.1 behaviour without removing this block.
# v61: a2fa8551 base behaviour; later levers off pending a powered read.
RETURN_FIRE_RANGE = False
RANGE_RETURN_PRESS = 500

# FOUR DIGITS lane (W1, plan-4digits.md lever 2, 2026-09-22): three
# ring_walker/proactive-recenter variants, each a plain kill switch in the
# SAME convention as RETURN_FIRE/OPENING_HUNTER/HEAT_HUNTER above -- default
# OFF (byte-identical to v60/control), armed one at a time IN CODE (never
# via container env, per house rule) for the local tick-share instrument
# read (src/shell/ladder.nim -d:tickShareProbe). Ceiling story (plan-
# architect, 22:50Z): the server-native zone-escape reflex
# (ladder.nim stepSeat's nativeBase.isSome branch) owns ~78% of ticks,
# armed whenever `zoneTicksUntilOutside(selfPos) <= 72`
# (ReflexZoneTriggerTicks, src/shell/reflexes.nim:22) -- ring_walker's OWN
# gate (starter_harness.gate_open, ~888-906) already tries to walk back
# 240 ticks ahead of the shrink (leadTicks doctrine below), so the fix
# tried here is not "make ring_walker fire more" but "make it land further
# from the 72-tick hazard line once it does fire" (inset) or fire earlier
# (leadTicks) or fire on a wider, Monet-only proactive trigger that does
# not touch the shared starter_harness.py gate predicate at all (every
# other persona reuses that file; keeping the experiment out of it is the
# whole point of implementing these as apply_phase_clamps pins instead of
# a starter_harness.py edit).
#
# RING_LEAD_WIDE: pins every ring_walker entry's leadTicks doctrine value
# UP from the canned-turn default (240) to RING_LEAD_WIDE_TICKS, so the
# anti-corner walk starts noticeably earlier relative to the shrink clock.
RING_LEAD_WIDE = False
RING_LEAD_WIDE_TICKS = 400          # max legal is 720 (ring_walker manifest)

# RING_INSET_WIDE: pins every ring_walker entry's inset doctrine value UP
# from 64 to RING_INSET_WIDE_PX, so the walk-to point sits further inside
# the next rect (more buffer against the 72-tick native trigger once
# ring_walker's own walk lands).
RING_INSET_WIDE = False
RING_INSET_WIDE_PX = 160            # max legal is 256 (ring_walker manifest)

# PROACTIVE_RECENTER: a Monet-only widened trigger, independent of the
# other two -- while ticks_to_shrink is inside PROACTIVE_RECENTER_TICKS
# (deliberately wider than any leadTicks doctrine above) AND we are not
# already inside the next rect, boost BOTH inset and leadTicks to the
# PROACTIVE_RECENTER_* values for that window only, same clamp-and-log
# shape as the HEAT_WINDOW/FINAL_FOUR pins elsewhere in this function --
# implemented here (apply_phase_clamps), not in starter_harness.py's
# shared gate_open, so aggressive/cautious/collaborative are untouched.
# DEFAULT FLIPPED TRUE (W3, RING CONTROL lane, 2026-09-22): W1's own local
# read (4 seeds, eval_mapspec_r5733.json) showed this ALONE cuts native
# (server zone-escape reflex) tick share 41.95%->35.4% overall (mid
# -8.2pp, endgame -7.2pp) with no collapse toward map center -- folded in
# as this lever's default rather than left as a separate opt-in, gated by
# the SAME NORINGCONTROL kill switch below (see its own comment) so one
# flag turns off the whole ring-control lever, this included.
PROACTIVE_RECENTER = True
PROACTIVE_RECENTER_TICKS = 480
PROACTIVE_RECENTER_LEAD = 480
PROACTIVE_RECENTER_INSET = 200

# RING CONTROL (W3, FOUR DIGITS lane, 2026-09-22): make ring_walker a
# first-class, ALWAYS-ON lever instead of a flat-parameter play that
# happens to sit in every canned turn. Facts this is built on (read
# directly off this branch's code, not the brief's paraphrase):
#   * ring_walker IS already an entry in all four of Monet's canned turns
#     (policy.py canned_turns, entry_id "ring") -- so on the LOCAL canned-
#     brain instrument (run_series.sh, no model credentials) it was never
#     "missing from the wire" in the way the peer brief's live-field read
#     described. What IS true on both paths: its two params (inset,
#     leadTicks) sat FLAT at the same literal (64, 240) in every phase,
#     never scheduled: no Monet mechanism re-asserts its PRESENCE if a
#     live model call (which does NOT run through canned_turns at all --
#     see PersonaCannedBrain vs a real brain) simply omits the entry, the
#     way apply_phase_clamps already guarantees fire_superiority/
#     hold_vs_gun/supply_run are never silently dropped by a model turn.
#   * The engine's native zone-escape reflex (ladder.nim stepSeat,
#     `input.nativeBase.isSome`) is checked BEFORE the controller loop and
#     overrides it OUTRIGHT whenever armed (`zoneTicksUntilOutside(self)
#     <= 72`, ReflexZoneTriggerTicks) -- no play on the wire, however
#     ordered, can act during that window. ring_walker's own gate
#     (starter_harness.gate_open) opens at `ticks_to_shrink < leadTicks`,
#     so leadTicks IS the runway available before that hard override; a
#     flat 240 gives only 168 ticks (240-72) of controller-loop time to
#     reach the next rect before native takes over regardless.
#   * jackal is Monet's `base_play` (starter_harness.layer_ladder,
#     `elif play == base_play: base.append(entry)` -- checked BEFORE the
#     GATED_PLAYS branch, so jackal is unconditionally "live" every tick,
#     gate_open bypassed entirely) -- on any tick where no GATED_PLAYS
#     entry's own gate is open (ring_walker's included), jackal just HOLDS
#     (SPAWN_HOLD_PLAYS) with nothing to chase. Between shrinks, absent a
#     live threat, Monet does not proactively reposition at all.
#   * Jordan (jordan-ctf-candidate:v164, pv 6c500d28, unchanged since
#     9/11) runs a DIFFERENT play for this, `edge_ride` (margin/enterLead/
#     coverBias), phase-scheduled: wide in the opening, tightening at his
#     tick-760 recall, staying tight but more conservative (coverBias 0.9)
#     from his tick-1500 recall on (mechanism/schedule read from his own
#     public recipe file, adapted -- not copied verbatim, no public
#     citation per house rule). We do NOT wire edge_ride: it is not in
#     GATED_PLAYS, so an entry for it would land in `layer_ladder`'s
#     `base` list, and `base.sort(key=lambda e: e.get("play") !=
#     base_play)` always sorts jackal (base_play) first regardless of
#     entries order -- an edge_ride base entry could never outrank an IDLE
#     jackal hold without either changing Monet's base_play (a much
#     larger, previously-measured-against change: "jackal IS monet's
#     patience", see base_play= below) or editing starter_harness.py's
#     shared GATED_PLAYS/gate_open (which every other persona reuses).
#     ring_walker is ALREADY a GATED_PLAYS member, so whenever its own
#     gate is open it lands in `gated`, which `layer_ladder`'s own
#     `return overlays + gated + base` ALWAYS places ahead of `base` --
#     "above jackal" with no shared-file edit, structurally, already.
#     margin/enterLead map onto ring_walker's inset/leadTicks (same
#     physical concepts: how deep inside the safe boundary to sit, how
#     many ticks before the shrink to start reacting), proportionally
#     rescaled from edge_ride's ranges ([40,600]px / [0,600]ticks) onto
#     ring_walker's own manifest bounds ([16,256]px / [24,720]ticks) --
#     his literal numbers (420/320, 240/160) are out of range for our
#     play and would be silently REJECTED whole-call by ring_walker.nim's
#     own strict reader (readParams marks the entire params blob invalid
#     outside [16,256]/[24,720], not just clamps it). coverBias has NO
#     ring_walker equivalent -- ring_walker.nim's walkTargets always tries
#     a fixed, ~50%-center-biased point before the raw clamped one; there
#     is no tunable knob. Approximated here by pushing `inset` toward its
#     own max in the late-phase entry (a deeper stance is the same
#     DIRECTION his coverBias 0.9 asks for -- more conservative, more
#     central -- not a literal port of his parameter).
#   * Ordering: reordered ring_walker's canned-turn position (and its
#     apply_phase_clamps insert-if-missing slot) to come AFTER
#     fire_superiority/hold_vs_gun so a live engagement still wins
#     first-match when a fresh track is inside engage range -- previously
#     ring_walker sat BEFORE them, which would have pulled a seat OFF an
#     already-open fight the instant the shrink clock also qualified.
NORINGCONTROL = False  # opt-out kill switch (never armed via container
                       # env, per house rule) -- flip True to fall back to
                       # byte-identical pre-lever behaviour: flat
                       # inset=64/leadTicks=240 every phase, no insert-if-
                       # missing, no reorder, PROACTIVE_RECENTER off too.

# Schedule boundaries mirror Jordan's own two recall ticks (760, 1500).
# Values are ring_walker-unit translations of his margin/enterLead numbers
# (see the block comment above for the exact scaling and the coverBias
# non-equivalence) -- NOT literal copies.
RING_CONTROL_PHASE_TICKS = (760, 1500)
RING_CONTROL_SCHEDULE = {
    # opening: margin 420, enterLead 320 (his OPENING_CALL)
    "opening": {"leadTicks": 384, "inset": 179},
    # mid (tick 760-1499): margin 240, enterLead 160 (his tick-760 recall)
    # -- leadTicks does NOT drop to the enterLead-scaled 192 his numbers
    # would give: measured (2nd rig read, 2026-09-22, 6 seeds, the
    # mechanism-bug already fixed) that 192 REGRESSES native share vs
    # the pre-lever flat 240 baseline (mid 50.65%->51.51%, endgame
    # 14.01%->22.08%) -- ring_walker's `leadTicks` gates WHETHER the
    # controller-loop play fires at all (`ticks_to_shrink < leadTicks`
    # in starter_harness.gate_open), unlike edge_ride's enterLead, which
    # only tunes HOW early an always-eligible base controller starts
    # riding. Narrowing our own gate's own window directly hands MORE of
    # the pre-shrink tail to the engine's fixed 72-tick native override
    # (ReflexZoneTriggerTicks) -- worse the SMALLER leadTicks is relative
    # to that fixed floor, which is why endgame (already the tightest
    # zone) regressed hardest. Kept ABOVE the 240 baseline in every
    # phase; inset still narrows (safe -- it only changes WHERE the walk
    # lands once armed, never WHETHER it arms).
    "mid": {"leadTicks": 280, "inset": 102},
    # late (tick >=1500): endgame needs the MOST runway, not the least --
    # same reasoning as mid, widened further since the 72-tick native
    # floor is a bigger fraction of a smaller endgame zone's travel
    # distances. inset pushed toward its own max as the closest available
    # stand-in for his coverBias 0.9 (see the module comment -- no
    # ring_walker equivalent exists).
    "late": {"leadTicks": 320, "inset": 230},
}


def _ring_control_phase(tick):
    """Opening / mid / late per RING_CONTROL_PHASE_TICKS -- tick is match
    progress (wall-clock ticks since kickoff), NOT ticks-to-shrink; a
    different axis from ring_walker's own gate (which reacts to the zone
    clock). Non-numeric/missing tick reads "opening" (the safe, widest
    doctrine), never a guess toward the narrower late posture."""
    if not isinstance(tick, (int, float)):
        return "opening"
    t760, t1500 = RING_CONTROL_PHASE_TICKS
    if tick < t760:
        return "opening"
    if tick < t1500:
        return "mid"
    return "late"


# RING WHEN GUARD (W16, FOUR DIGITS lane v67, 2026-09-24): the same
# treatment fire_superiority got in v63 (see FS_WHEN_GUARD's own module
# comment for the mechanism this reuses verbatim) -- opting a play into
# starter_harness.KEEP_WHEN_PLAYS makes layer_ladder trust an entry's
# `when` clause instead of re-running its OWN gate_open() snapshot, on
# every send path INCLUDING maintenance. RING CONTROL above already
# guarantees a ring_walker entry exists on the call path; once that entry
# also carries `when` and "ring_walker" is in KEEP_WHEN_PLAYS, it rides
# every subsequent maintenance resend unconditionally too (layer_ladder's
# `keep_when` bypass is checked inside the SAME function gate_and_build
# calls on the maintenance path, not just the call path -- confirmed by
# reading gate_and_build/_live_loop directly, not assumed), and the
# ENGINE's own per-tick guardPasses (ladder.nim:377-382, over
# src/shell/episode.nim:526-596 playGuardContext) decides moment-to-moment
# whether it actually steps -- not the harness's own ~2s-cadence
# client-side snapshot. Measured need (W13 FINAL, this same rig): whenever
# fire_superiority yields, ring_walker is absent from the sent ladder most
# ticks (its own harness gate_open is a ~2s snapshot on client facts), and
# supply_run/native pick up the idle ticks instead.
#
# GUARD DERIVATION -- REJECTED the literal ["or", ["not",["get",
# "world.in_zone"]], ["<=",["get","world.zone_dist"],<lead px>]] shape a
# naive port of ring_walker's own two-part harness gate (`not in_zone OR
# (not in_next_zone AND ticks_to_shrink<leadTicks)`) suggests. Read against
# src/shell/episode.nim:569-570 (`zoneDist = if hasZone:
# rectEdgeDistancePx(...) else: 0.0`; `inZone = zoneDist <= 0.0`) and the
# registry's own sentinel comment (src/ctf/policy_page.nim:188, "0 if
# inside"), world.zone_dist is PINNED TO 0 the instant in_zone is true --
# so the second OR-term (`zone_dist <= lead`) is TRUE for ANY lead>=0
# whenever in_zone is true, and the whole OR collapses to an unconditional
# True. That is not a tightened guard, it is exactly the "unguarded/
# always-true entry" monopolization risk the W9 finding (and this module's
# own FIGHT PIN safety comment, below) warns an always-true guard creates.
# No in-vocabulary substitute exists either: playGuardContext (episode.
# nim:526-596) only ever reads `facts.currentZone` for zone_dist --
# `facts.nextZone` exists on BrDefaultFacts (src/shell/default_play.nim:24)
# but is never threaded into playGuardContext, and there is no tick-count
# term at all (ticks_to_shrink is a harness-side-only fact, not in
# DefaultPaths) -- the ANTICIPATORY half of ring_walker's own harness gate
# cannot be mirrored at the engine level with the fixed guard vocabulary;
# only the REACTIVE half (not in_zone) can.
#
# GUARD ADOPTED: `not in_zone` alone -- the reactive half of ring_walker's
# own harness gate, using the one zone term that is both engine-evaluable
# and non-degenerate. SAFE by construction, not just by inspection:
# ring_walker.nim's own play_step (policies/monet/plays/ring_walker.nim:
# 181-209) computes `outsideCurrent` from the IDENTICAL physical fact
# (self position vs the CURRENT zone rect) the engine's world.in_zone is
# computed from -- so whenever this guard is true, `outsideCurrent` is
# necessarily also true in the wasm's own view, `outsideCurrent or
# nextPressure` is true, and play_step takes the walk branch (a genuine
# emitNavigateController decision), never its emitHoldIfChanged() "nothing
# to walk" branch (ring_walker.nim:186-198, own comment: "Inside the
# schedule: nothing to walk"). A guard that is true only when the wasm
# provably has a real walk to make cannot produce the sticky-hold
# monopolization an always-true (or merely loose) guard risks (instance.
# nim lastAccepted: a live entry that has EVER emitted stays the passing
# controller until faulted or replaced -- see the FIGHT PIN safety note
# below for the full citation of that mechanic).
RING_WHEN_GUARD = ["not", ["get", "world.in_zone"]]

# RIG RESULT (W16, v67, 2026-09-24, 3 seeds/arm, eval_mapspec_r5733.json,
# control=four-digits/v66-press vs treatment=this branch): the guard above
# is SAFE (never monopolizes -- no crash, no stuck-seat symptom, confirmed
# below) but PROVABLY DEAD, not merely "tight": read against ladder.nim:
# 747 (`if input.nativeBase.isSome: ... else: ... livePassingController`
# -- an if/else, the controller loop NEVER RUNS AT ALL when native is
# armed) and reflexes.nim's `zoneActive` (`zoneTicksUntilOutside(selfPos)
# <= ReflexZoneTriggerTicks(72)`), whose own `zoneTicksUntilOutside`
# (episode.nim:909-920) returns EXACTLY 0 -- always <=72, always armed --
# the INSTANT `selfPos` is outside the current zone rect. So "not in_zone"
# (this guard's only true condition) is a mathematical SUBSET of "native
# is already armed and has already pre-empted the controller loop entirely
# for this tick" -- there is no tick on which this guard is true AND the
# controller loop still runs. Confirmed empirically, not just by proof:
# the rig's `controller=` tick-share probe shows ring_walker at 0.00%
# passing share in the treatment arm (9740 samples, 3 seeds) vs 2.30% in
# control (7425 samples) -- CONTROL's non-zero share comes entirely from
# the harness's own OLD gate_open (the ANTICIPATORY half, `not
# in_next_zone AND ticks_to_shrink<leadTicks`, which fires BEFORE the seat
# ever leaves the zone, while native is still unarmed) riding un-guarded
# on the wire between harness resends -- a mechanism this lever's `when`
# guard cannot reproduce, because (per the module comment above)
# playGuardContext exposes no next-zone/tick-count term at all. Net
# measured effect: native share went UP (32.04%->33.64%), not down -- the
# opposite of this build's own target. No in-vocabulary fix exists (see
# the derivation comment above): ANY predicate built from world.in_zone/
# world.zone_dist that tries to catch "near the boundary" is either
# degenerate (zone_dist pinned to 0 whenever in_zone) or, like this one,
# provably a subset of native's own trigger. Closing this gap for real
# needs a next-zone or ticks-to-shrink term added to playGuardContext/
# DefaultPaths (src/shell/episode.nim, src/ctf/policy_page.nim) -- a
# shared engine change, out of this lane's scope. DEFAULTED OFF (see
# NORINGWHEN below) rather than shipped as dead weight with a measured
# adverse signal on the metric it exists to move; mechanism, tests, and
# investigation kept intact (armable via NORINGWHEN=False) for whoever
# picks up the engine-side follow-up.
NORINGWHEN = True  # DEFAULT FLIPPED (see RIG RESULT above) -- the ONE
                    # lever in this KEEP_WHEN_PLAYS family that defaults
                    # OFF, unlike its NOFSWHEN/NOFIGHTPIN/NORINGCONTROL
                    # siblings (all default False="armed"): this guard is
                    # rig-proven structurally dead (see above), not merely
                    # unproven, so shipping it armed by default would add
                    # wire bytes and pin-loop cost for zero benefit and a
                    # measured native-share regression. Never armed via
                    # container env, per house rule, same as every sibling
                    # switch -- orthogonal to NORINGCONTROL/NOFSWHEN/
                    # NOFIGHTPIN; flipping this one alone must not silently
                    # disable any of the others. Flip False to arm the
                    # mechanism (e.g. once a next-zone/ticks-to-shrink
                    # guard term exists engine-side): ring_walker then
                    # carries RING_WHEN_GUARD and opts into starter_
                    # harness.KEEP_WHEN_PLAYS exactly as v63's fire_
                    # superiority sibling does today. True (the default)
                    # is byte-identical to pre-lever behaviour: ring_walker
                    # carries no `when`, starter_harness.KEEP_WHEN_PLAYS
                    # never gains "ring_walker", and its python-side
                    # gate_open send-time snapshot governs wire presence
                    # exactly as before this lever existed (RING CONTROL's
                    # own presence/ordering guarantee, and its own
                    # NORINGCONTROL switch, are unaffected either way).
if not NORINGWHEN:
    # Opt into starter_harness's KEEP_WHEN_PLAYS (see that module's own
    # comment on the set, and FS_WHEN_GUARD's identical opt-in above): a
    # shared, Monet-set module attribute -- a no-op for any other
    # persona's process, which never imports this module. Confirmed this
    # is the only place any persona populates the set today besides
    # FS_WHEN_GUARD's own "fire_superiority" add a few hundred lines up --
    # the set itself (starter_harness.KEEP_WHEN_PLAYS) stays the shared
    # empty default for every persona that never imports policies/monet/
    # policy.py.
    starter_harness.KEEP_WHEN_PLAYS.add("ring_walker")


# FIGHT PIN / FS PRESENCE (v62, FOUR DIGITS lane, 2026-09-23): guarantee
# fire_superiority is present and correctly ordered ahead of ring_walker on
# the CALL path (a real model call, or either reemit helper) -- the same
# class of fix RING CONTROL (W3, just above) made for ring_walker's
# presence -- see this module's own apply_phase_clamps block (search
# "FIGHT PIN" there) for the mechanism.
#
# WHY, ROUND 1 (xp-behaviour-liveness, 2026-09-23, ~/.ctf/handoff/2026-09-
# 23-xp-behaviour-liveness.md): a paired hosted XP read (60 episodes, v61
# vs v60, same 14-champion opponent pool per episode) found v61's
# toward-enemy share and shots-after-own-hit BOTH pinned at v60's own
# baseline despite W5's rig read (byte-identical wasm) showing the same
# levers firing hundreds of times against the rig's canned opening. D17's
# hypothesis: live model turns and maintenance resends of a cached ladder
# can omit fire_superiority (or resend stale params) in a way no
# canned-turn-only rig read could ever see.
#
# WHY, ROUND 2 (xp-turn-wire, 2026-09-23, ~/.ctf/handoff/2026-09-23-xp-
# turn-wire.md): READ THE HOSTED WIRE DIRECTLY and REFUTED the param half
# of D17 -- breakDeficit is 4 on 100% of hosted fs-present sent calls
# (0/422 wrong), and lever A/B (NOFIREPERSIST/NOCLOSEBIAS) are compile-time
# Nim consts a model turn cannot touch at all. The REAL finding: fire_
# superiority is the sent/active controller only ~21% of tick-time in BOTH
# v61 and v60 (identical) -- it is a GATED_PLAY that only enters the ladder
# when starter_harness.gate_open sees a trackable enemy, and that is rare
# relative to how often an enemy is merely nearby (~67% of alive time
# within 500px) -- so the levers act on a fifth of the match and cannot
# show up in an aggregate read either way. This is a PRESENCE gap, not a
# param-correctness gap.
#
# WHY THIS BUILD IS SCOPED TO THE CALL PATH ONLY (safety check, this same
# session, before any wasm change): an earlier draft tried to guarantee
# presence on EVERY send path, including maintenance resends, "never
# dropped." Read against src/shell/ladder.nim (stepSeat ~692-763,
# livePassingController ~572-579) and src/shell/instance.nim (invokeStep
# ~499-522), that shape is UNSAFE, not merely redundant: the engine has no
# per-tick "this live entry has nothing to do, try the next one" fallback
# -- only a FAULTED entry causes it to advance past; a live entry counts as
# "passing" the moment it has EVER emitted anything, and
# fire_superiority.nim:520-522's own "no live contact" branch
# (`return emitHoldIfChanged()`) IS a real emitted decision, not a yield.
# That decision is sticky (instance.nim `lastAccepted` never reverts to
# none short of a fault or a fresh `play_init`) for as long as the entry is
# never dropped from the ladder -- so "always present, ranked above
# jackal/ring_walker" would monopolize the seat the first time it ever
# emits anything and never let jackal or ring_walker act again for the
# rest of the match. The engine's real per-tick dynamic-yield mechanism is
# a wire-level `when` guard (ladder.nim `guardPasses`, ~377-382, evaluated
# fresh every tick via IntentContext) -- but starter_harness.layer_ladder
# unconditionally strips `when` (`entry.pop("when", None)`) before sending,
# so this lever cannot reach it without editing policies/starters/common/
# (shared, off-limits for this lane; see this build's own report for the
# file:line a sibling worker would need to build that fix on shared code).
# Scoped to the CALL path only, below, which carries none of that risk:
# `entries` there is still the PRE-gate wanted ladder, so inserting
# fire_superiority only makes it a CANDIDATE that the real gate_open()
# still filters honestly a moment later in layer_ladder -- the exact same
# safe argument RING CONTROL's own insert-if-missing already relies on.
#
# Independent kill switch: NOFIGHTPIN is its own opt-out, separate from
# NORINGCONTROL (ring_walker's own lever) and separate from
# NOFIREPERSIST/NOCLOSEBIAS (compile-time Nim consts inside
# fire_superiority.nim itself, unreachable from policy.py) -- flipping any
# one of the three must not silently disable the others, same
# orthogonality convention as OPENING_HUNTER vs NOOPENPREFER above. Default
# False (lever armed); never armed via a container env var, per house rule.
NOFIGHTPIN = False

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


def _update_heat_window(pact_state, view):
    """Advance/read the heat-window lock's own persisted clock.

    `apply_phase_clamps` never receives `context`, so it cannot itself
    read `context["self"]["team"]` -- `adjust_entries` stashes it into
    `pact_state["_my_team"]` before every call into this module (see its
    own call site) so this function, and therefore every send path
    (model call, either reemit helper, and the maintenance resend, which
    calls straight into `apply_phase_clamps` with `seat.pact_state`), sees
    the same team identity without widening `apply_phase_clamps`'s
    signature -- the maintenance call site in starter_harness.py is
    shared infra this lever does not touch.

    kill_feed is a 240-tick trailing window (schema $comment), refreshed
    far more often than that (the maintenance loop alone polls every
    MAINTENANCE_SECONDS), so folding each call's fresh rows into a
    monotonic `_last_heat_tick` in `pact_state` (never regressing) is
    sufficient to track "most recent tick our team was credited a kill"
    across the whole episode, not just this one call's window.

    Returns True iff a heat-paying deed by our team landed within
    HEAT_WINDOW_TICKS of the CURRENT tick (False on any missing/malformed
    data -- same never-a-guess convention as `_final4`/
    `_in_marquee_zone_window`).
    """
    my_team = pact_state.get("_my_team")
    tick = view.get("tick")
    if not isinstance(my_team, str) or not isinstance(tick, (int, float)):
        return False
    for kill in view.get("kill_feed") or []:
        if not isinstance(kill, dict) or kill.get("killer_team") != my_team:
            continue
        kill_tick = kill.get("tick")
        if not isinstance(kill_tick, (int, float)):
            continue
        if kill_tick > pact_state.get("_last_heat_tick", -1):
            pact_state["_last_heat_tick"] = kill_tick
    last_heat_tick = pact_state.get("_last_heat_tick")
    return (isinstance(last_heat_tick, (int, float))
            and 0 <= tick - last_heat_tick <= HEAT_WINDOW_TICKS)


def _update_opening_hunter(pact_state, view):
    """Advance/read the OPENING HUNTER lever's own persisted latch.

    Same plumbing as `_update_heat_window` (same `pact_state["_my_team"]`
    stash, same never-a-guess convention: missing/malformed `_my_team` or
    a non-numeric `tick` reads False, never a guess) but a DIFFERENT
    predicate shape -- this is a ONE-TIME LATCH, not a recurring window.
    kill_feed is only a 240-tick trailing view (schema $comment), so a
    kill credited to our team early in the match would otherwise scroll
    back out of sight long before OPENING_TICKS (1500) elapses; persisting
    `_first_kill_tick` onto `pact_state` the first time such a row is ever
    seen, and never clearing it, is what keeps "our team has landed no
    kill yet" true for the rest of the episode once it goes false -- it
    never flips back on.

    Returns True iff `OPENING_TICKS` has not yet elapsed AND our team has
    never been credited a kill in `kill_feed` across any call this episode.
    """
    my_team = pact_state.get("_my_team")
    tick = view.get("tick")
    if not isinstance(my_team, str) or not isinstance(tick, (int, float)):
        return False
    if pact_state.get("_first_kill_tick") is None:
        for kill in view.get("kill_feed") or []:
            if not isinstance(kill, dict) or kill.get("killer_team") != my_team:
                continue
            kill_tick = kill.get("tick")
            if not isinstance(kill_tick, (int, float)):
                continue
            pact_state["_first_kill_tick"] = kill_tick
            break
    return pact_state.get("_first_kill_tick") is None and tick < OPENING_TICKS


def _update_return_fire(pact_state, view):
    """Advance/read the v59 RETURN FIRE lever's own persisted clock.

    Unlike `_update_heat_window`/`_update_opening_hunter`, this needs no
    `pact_state["_my_team"]` stash -- `aggressors` rows are already
    victim-private (play_view.schema.json $comment: "hit feedback against
    SELF"), scoped to us by the engine before we ever see them, so there is
    no killer-team filter to apply.

    Persists the freshest `tick` seen across any aggressor row into
    `pact_state["_last_hit_tick"]` (monotonic, never regresses), the same
    shape as `_update_heat_window`'s `_last_heat_tick` -- so "we are under
    fire" stays true for RETURN_FIRE_TICKS after the LAST incoming hit even
    on a call whose own `view["aggressors"]` has already aged that specific
    row out of the wire's own 120-tick window.

    Returns True iff an aggressor tick landed within RETURN_FIRE_TICKS of
    the current tick (False on any missing/malformed data, same
    never-a-guess convention as the other _update_* helpers here).
    """
    tick = view.get("tick")
    if not isinstance(tick, (int, float)):
        return False
    for row in view.get("aggressors") or []:
        if not isinstance(row, dict):
            continue
        row_tick = row.get("tick")
        if not isinstance(row_tick, (int, float)):
            continue
        if row_tick > pact_state.get("_last_hit_tick", -1):
            pact_state["_last_hit_tick"] = row_tick
    last_hit_tick = pact_state.get("_last_hit_tick")
    return (isinstance(last_hit_tick, (int, float))
            and 0 <= tick - last_hit_tick <= RETURN_FIRE_TICKS)


def apply_phase_clamps(entries, view, pact_state, source=None):
    """The ONE clamp point for every ENDGAME-DOCTRINE pin this persona owns
    -- fire_superiority.pressRange/finishRange/engageDist, supply_run.
    whenHpBelow, the final-four detour ceiling (FINAL4_DETOUR_MAX), and
    (v56) the heat-window detour ceiling (HEAT_WINDOW_DETOUR_MAX) --
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

    v56 (HEAT-WINDOW AGGRESSION LOCK, cap-decomp n=14 read): a NEW pin,
    same GATED_PLAY maintenance-bypass class as the final-four clamp --
    supply_run/loot detourMax clamped to HEAT_WINDOW_DETOUR_MAX for
    HEAT_WINDOW_TICKS after our team is credited a kill in kill_feed (see
    _update_heat_window and the HEAT_WINDOW_TICKS/HEAT_WINDOW_DETOUR_MAX
    module comment for the full WHY/observable citation). Independent
    predicate from _final4 -- both can be true at once, and the shared
    min()-against-current-value clamp on both blocks means whichever is
    tighter always wins, on every send path, exactly like final-four.

    v57 (OPENING HUNTER, pre-registered owner brief §8): a different SHAPE
    of pin -- the others above overwrite a param on an entry the model (or
    a stale ladder) already proposed; this one rewrites which PLAYS are on
    the list, on the same list every send path shares (see
    _update_opening_hunter and the OPENING_TICKS/OPENING_HUNTER module
    comment). It runs first, before the FIRE_SUPERIORITY WIRE FIX loop
    just below, so any fire_superiority entry it installs is pinned to the
    exact same doctrine numbers as one the model named itself -- one
    mechanism, not two copies of pressRange/finishRange/engageDist.

    v58 (HEAT-WINDOW HUNTER, pre-registered owner brief §23): the SAME
    play-swap block as v57, now re-armed by a SECOND, independent
    predicate -- the recurring HEAT_WINDOW_TICKS clock `_update_heat_window`
    already tracks for the AGGRESSION LOCK detourMax pin further down (see
    HEAT_HUNTER module comment). That clock's own state-mutating call
    (`pact_state["_last_heat_tick"]`) runs exactly ONCE per
    apply_phase_clamps call, cached as `heat_window_state`, so the two
    consumers -- this play-swap block and the AGGRESSION LOCK block --
    always agree on whether the window is open on this call. HEAT_HUNTER
    gates only the play-swap use; the AGGRESSION LOCK's own detourMax pin
    stays keyed on the raw `heat_window_state`, unconditional on this
    switch, exactly as it was before this lever existed. The opening
    latch and the heat window cannot both be true on the same call (a
    kill permanently trips the opening latch false, and only a kill can
    make the heat window true), so the log tag below is an if/elif in
    substance even though it reads as a single ternary.

    v59 (RETURN FIRE, pre-registered owner brief §30): a DIFFERENT play
    (hold_vs_gun, not fire_superiority) for a case neither v57 nor v58
    reaches -- an attacker who has hit us but never entered a live track,
    so fire_superiority's own gate stays closed no matter how many times
    this function forces it onto the list. See RETURN_FIRE_TICKS/
    RETURN_FIRE and _update_return_fire for the full WHY, schema evidence,
    and why mechanism (A) (opening fire_superiority's own gate on aggressor
    data) is dead on the wire. Independent clock from `_last_heat_tick`
    (`pact_state["_last_hit_tick"]`); independent trigger from the opening/
    heat-hunter block above (aggressor-hit, not kill-credit); mutually
    exclusive with fire_superiority by construction, not by a shared flag,
    since it only ever fires when fire_superiority's gate is closed.

    v61 (ISOLATED-FIRST OPENING PREFER, FOUR DIGITS lane, pre-registered
    2026-09-22): a param pin, same class as the FIRE_SUPERIORITY WIRE FIX
    loop below, but on target_law's `prefer` instead of fire_superiority's
    range fields -- reuses opening_window (this call's OPENING_HUNTER
    predicate) under its own kill switch (NOOPENPREFER) so every
    target_law entry on the list converges on ISOLATED_FIRST_PREFER while
    the opening is live and TARGET_LAW_PREFER once it ends, regardless of
    which canned_turns literal or model call proposed a different order.
    See the module-level ISOLATED_FIRST_PREFER/NOOPENPREFER comment above
    TARGET_LAW_PREFER for the full WHY.

    v62 (FIGHT PIN / FS PRESENCE, FOUR DIGITS lane, 2026-09-23): closes the
    SAME class of gap PIN_BYPASS_AUDIT (v52) closed for pressRange/
    finishRange/engageDist, but one level up -- those three (plus, as of
    this version, breakDeficit, folded into that same loop) only ever
    pinned params on a fire_superiority entry that already made it onto
    the list; nothing guaranteed the entry itself was there, or that it
    out-ranked ring_walker, on a live model turn or a reemit. Scoped to the
    CALL path only (source != "maintenance" -- a real model call, pre-call,
    kickoff-reemit, or final4-reemit, all of which route through
    adjust_entries) -- NOT the maintenance resend path, unlike every other
    clamp in this function -- after a safety check found that guaranteeing
    presence on every path would be unsafe at the engine level (see the
    module-level NOFIGHTPIN comment for the full read-the-source WHY). Runs
    right after RETURN
    FIRE FROM RANGE and before the FIRE_SUPERIORITY WIRE FIX loop (own
    kill switch NOFIGHTPIN) so a freshly-installed entry gets that loop's
    pressRange/finishRange/engageDist/breakDeficit doctrine for free.

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

    # v59.1 DIAGNOSTIC (owner brief 2026-09-21 EOD, aggressor-wire-audit
    # §34): hoisted the RETURN FIRE block's own `facts`/gate computation up
    # here, UNCONDITIONAL, so it runs on every call regardless of whether
    # RETURN FIRE (or anything else in this function) actually fires --
    # both starter_harness._view_facts and gate_open are pure reads with no
    # side effects, so evaluating them on every call is behaviour-neutral;
    # the RETURN FIRE block below now reuses these same two values instead
    # of recomputing them, one implementation, not two. This is what feeds
    # the one unconditional `[diag]` line emitted at the end of this
    # function, below.
    tick = (view or {}).get("tick", 0) or 0
    facts = starter_harness._view_facts(
        view, {"self": {"team": pstate.get("_my_team")}}, [])
    fire_superiority_open = starter_harness.gate_open(
        {"play": "fire_superiority", "params": {}}, facts)
    # v60: hoisted up from the FIRE_SUPERIORITY WIRE FIX loop below (same
    # discipline as the v59.1 hoist above) so the RETURN FIRE FROM RANGE
    # block can read the current phase's own pressRange doctrine instead
    # of a second, possibly-drifting copy of "220" -- one computation, one
    # doctrine table, reused by both the gate below and the pin loop.
    phase = "endgame" if _in_marquee_zone_window(view) else "default"

    # OPENING/HEAT-WINDOW HUNTER (v57 opening latch + v58 heat-window
    # re-arm, see OPENING_TICKS/OPENING_HUNTER and HEAT_HUNTER module
    # comments for the full WHY/citations): while EITHER the opening
    # window is live and our team has landed no kill yet this episode
    # (_update_opening_hunter, a one-time latch), OR a heat-paying kill
    # by our team landed within HEAT_WINDOW_TICKS of now (the SAME
    # recurring clock the AGGRESSION LOCK block below reads -- evaluated
    # ONCE here, cached in `heat_window_state`, and reused down there so
    # both blocks always agree), strip every scatter entry and guarantee
    # a fire_superiority entry is on the list -- runs BEFORE the
    # FIRE_SUPERIORITY WIRE FIX loop just below so a freshly-installed
    # entry gets the SAME doctrine params (pressRange/finishRange/
    # engageDist) as any model-authored one, one mechanism, never a
    # second copy of those numbers. This block changes WHICH play is on
    # the ladder, never fire_superiority's own numbers -- the read
    # isolates the play swap, same discipline as every other pin in this
    # function. HEAT_HUNTER gates only this use of the clock; see the
    # AGGRESSION LOCK block below for the unconditional v56 use.
    heat_window_state = _update_heat_window(pstate, view)
    opening_window = _update_opening_hunter(pstate, view)
    opening_active = OPENING_HUNTER and opening_window
    heat_hunter_active = HEAT_HUNTER and heat_window_state
    # v61 lever C: isolated-first opening prefer shares OPENING_HUNTER's
    # own predicate (opening_window) but its OWN kill switch
    # (NOOPENPREFER) -- flipping OPENING_HUNTER off (the play-swap lever)
    # must not silently disable this one too, and vice versa.
    isolated_first_active = (not NOOPENPREFER) and opening_window
    if opening_active or heat_hunter_active:
        window_tag = "opening" if opening_active else "heat"
        before_count = len(entries)
        entries[:] = [e for e in entries if e.get("play") != "scatter"]
        stripped = before_count - len(entries)
        if stripped:
            starter_harness._log(
                PERSONA,
                f"{window_tag}-hunter clamp{tag}: scatter stripped "
                f"({stripped} {'entry' if stripped == 1 else 'entries'}){suffix}")
            fired = True
        if not any(e.get("play") == "fire_superiority" for e in entries):
            entries.append({"play": "fire_superiority",
                            "entry_id": f"{window_tag}_hunter", "params": {}})
            starter_harness._log(
                PERSONA,
                f"{window_tag}-hunter clamp{tag}: fire_superiority installed{suffix}")
            fired = True

    # ISOLATED-FIRST OPENING PREFER (v61 lever C, see the module-level
    # ISOLATED_FIRST_PREFER/NOOPENPREFER comment above TARGET_LAW_PREFER
    # for the full WHY): every target_law entry carrying the CANONICAL
    # house order verbatim -- whichever canned_turns literal produced it
    # (all five emit `list(TARGET_LAW_PREFER)` unmodified), or the
    # law_never fallback-creation branch above (same literal), or a
    # maintenance resend of either -- gets reordered to
    # ISOLATED_FIRST_PREFER while isolated_first_active, and back to
    # TARGET_LAW_PREFER once the opening window ends or our team banks a
    # kill (opening_window is the SAME one-time latch the OPENING/
    # HEAT-WINDOW HUNTER block above reads, so both always agree on
    # whether the opening is still live on this call). Deliberately NARROW
    # -- unlike the FIRE_SUPERIORITY WIRE FIX loop below, which always pins
    # pressRange/finishRange/engageDist regardless of the incoming value,
    # this only touches a `prefer` that is missing or byte-identical to
    # the untouched house default: a model call (or a test fixture) that
    # deliberately submitted its OWN subset/order -- schema-legal per
    # emit_validator.nim:146-184 (membership/no-dup/count<=4, never a
    # specific set or order) -- is left alone, never bulldozed back to a
    # 4-tag list it never asked for.
    prefer_doctrine = (ISOLATED_FIRST_PREFER if isolated_first_active
                        else TARGET_LAW_PREFER)
    house_default = list(TARGET_LAW_PREFER)
    ours_default = list(ISOLATED_FIRST_PREFER)
    for entry in entries:
        if entry.get("play") != "target_law":
            continue
        params = entry.setdefault("params", {})
        old = params.get("prefer")
        if old != house_default and old != ours_default:
            # Missing, or a deliberate non-default/non-ours order
            # (model-authored or a test/diagnostic fixture) -- not ours to
            # touch. `old == ours_default` matters for a REVERT: a
            # maintenance resend replays the SAME cached
            # `seat.wanted_entries` object a prior call already reordered
            # to ISOLATED_FIRST_PREFER (repair_call's own docstring: the
            # wanted ladder is what maintenance re-derives from), so once
            # the opening window closes mid-episode this needs to still
            # match and flip back to TARGET_LAW_PREFER -- checking only
            # `== house_default` would silently skip that entry forever
            # once it had been touched once.
            continue
        new = list(prefer_doctrine)
        if old != new:
            starter_harness._log(
                PERSONA,
                f"clamp target_law.prefer{tag} {old!r}->{new!r} "
                f"opening={isolated_first_active}{suffix}")
            fired = True
        params["prefer"] = new

    # RETURN FIRE (v59, see the module-level RETURN_FIRE_TICKS/RETURN_FIRE
    # comment for the full WHY, schema citations, and why fire_superiority
    # itself cannot take this case): while we are under fire (a fresh
    # aggressor row landed within RETURN_FIRE_TICKS -- _update_return_fire,
    # a recurring monotonic clock, same shape as _update_heat_window) AND
    # no live track currently opens fire_superiority's own gate
    # (starter_harness.gate_open, evaluated fresh from THIS call's view --
    # an untracked attacker by definition cannot open it, since its
    # aggressor row carries no position), guarantee a hold_vs_gun entry is
    # on the list. Mutually exclusive with fire_superiority by construction
    # (fixture ii): whenever a track IS in view, fire_superiority's gate
    # opens and this block never fires, so the wire is byte-identical to
    # v58 whenever a track exists.
    return_fire_active = RETURN_FIRE and _update_return_fire(pstate, view)
    if return_fire_active:
        # `facts`/`fire_superiority_open` are the SAME values computed once,
        # unconditionally, above (v59.1 DIAGNOSTIC) -- reused here rather
        # than recomputed, so there is exactly one call to _view_facts/
        # gate_open per apply_phase_clamps call, not two.
        if not fire_superiority_open and not any(
                e.get("play") == "hold_vs_gun" for e in entries):
            entries.append({"play": "hold_vs_gun",
                            "entry_id": "return_fire", "params": {}})
            starter_harness._log(
                PERSONA,
                f"return-fire clamp{tag}: hold_vs_gun installed{suffix}")
            fired = True

    # RETURN FIRE FROM RANGE (v60, see the module-level RETURN_FIRE_RANGE/
    # RANGE_RETURN_PRESS comment above for the full WHY, code evidence, and
    # why mechanism (A) not (B)): the mirror-image case of the block just
    # above -- while under fire (`return_fire_active`, the SAME
    # RETURN_FIRE_TICKS clock, reused rather than recomputed) AND
    # fire_superiority's OWN gate IS open (a live track exists) AND the
    # nearest tracked enemy sits beyond fire_superiority's own pressRange
    # for this phase, guarantee hold_vs_gun is on the ladder AHEAD of any
    # fire_superiority entry (INSERT at entries[0], never append -- see the
    # ORDERING note above). For fs_open=False this predicate is always
    # False (short-circuits on fire_superiority_open), so v59/v59.1's own
    # RETURN FIRE block above owns that case exactly as it always has.
    return_fire_range_active = bool(
        RETURN_FIRE_RANGE and return_fire_active and fire_superiority_open
        and isinstance(facts["nearest_enemy"], (int, float))
        and facts["nearest_enemy"] > FIRE_SUPERIORITY_PRESS_RANGE[phase])
    if return_fire_range_active:
        if not any(e.get("play") == "hold_vs_gun" for e in entries):
            entries.insert(0, {"play": "hold_vs_gun",
                               "entry_id": "return_fire_range", "params": {}})
            starter_harness._log(
                PERSONA,
                f"return-fire-range clamp{tag}: hold_vs_gun ahead{suffix}")
            fired = True

    # FIGHT PIN / FS PRESENCE (v62, FOUR DIGITS lane, 2026-09-23): guarantee
    # fire_superiority is PRESENT and correctly ordered ahead of ring_walker
    # on the CALL path (a real model call, or either reemit helper) -- the
    # same class of gap RING CONTROL (W3) closed for ring_walker's presence.
    # See the module-level NOFIGHTPIN comment above for the full WHY
    # (xp-behaviour-liveness D17) and a SAFETY CORRECTION this v62 build
    # made to its own original brief: an EARLIER draft of this lever tried
    # to guarantee presence on EVERY send path including maintenance
    # resends, "never dropped." Read against src/shell/ladder.nim
    # (stepSeat/livePassingController) and src/shell/instance.nim
    # (invokeStep's sticky `lastAccepted`), that shape is UNSAFE: the engine
    # has no per-tick "this live entry has nothing to do, try the next one"
    # fallback -- only a FAULTED entry causes it to advance past; a live
    # entry that simply has no target still counts as "passing" the moment
    # it has EVER emitted anything (fire_superiority.nim:520-522's own
    # "no live contact" branch calls `emitHoldIfChanged()`, a REAL decision,
    # not a yield), and that decision is sticky (instance.nim `lastAccepted`
    # never reverts to none short of a fault or a fresh `play_init`) for as
    # long as the entry is never dropped from the ladder. An entry that is
    # NEVER dropped therefore never gets a fresh instance either -- so
    # "always present, ranked above jackal/ring_walker" would monopolize the
    # seat the FIRST time it ever emits anything and never let jackal or
    # ring_walker act again for the rest of the match. The engine's real
    # per-tick dynamic-yield mechanism is a wire-level `when` guard
    # (`ladder.nim` `guardPasses`, evaluated fresh every tick) -- but
    # `starter_harness.layer_ladder` unconditionally strips `when`
    # (`entry.pop("when", None)`) before sending, so this lever cannot reach
    # it without editing policies/starters/common/ (shared, off-limits for
    # this lane). Scoped down to the CALL path only, below, which carries
    # none of that risk (see its own comment).
    if not NOFIGHTPIN:
        # Insert-if-missing: source != "maintenance" ONLY -- EXACTLY RING
        # CONTROL's own discipline (see that block's comment below for the
        # full argument, and note its own exclusion is what actually
        # produces its 60/60-hosted-episode presence figure: an "at least
        # once per episode" measure driven by the ~4 model calls + 2 reemit
        # helpers per episode, not by every maintenance tick). entries on
        # the maintenance path is ALREADY the post-gate wire ladder
        # (gate_and_build's gate_open() already ran), so an absent
        # fire_superiority there most of the time is that gate correctly
        # saying "no live track right now," not the gap this guards -- and,
        # per the safety note above, unconditionally re-adding it there
        # would mean it is never dropped and therefore never reinitialized.
        # On the CALL path (source != "maintenance" -- a real model call,
        # pre-call, kickoff-reemit, or final4-reemit, all of which route
        # through adjust_entries), entries is
        # still the PRE-gate wanted ladder, so inserting here only makes
        # fire_superiority a CANDIDATE that the real gate_open()
        # (facts["enemies"] non-empty, in zone) still filters honestly a
        # moment later in layer_ladder -- the same safe argument RING
        # CONTROL's own insert-if-missing relies on.
        if source != "maintenance" and not any(
                e.get("play") == "fire_superiority" for e in entries):
            existing_ring = [i for i, e in enumerate(entries)
                             if e.get("play") == "ring_walker"]
            insert_at = min(existing_ring) if existing_ring else len(entries)
            entries.insert(insert_at, {"play": "fire_superiority",
                                       "entry_id": "fight_pin", "params": {}})
            starter_harness._log(
                PERSONA,
                f"clamp fight_pin{tag}: fire_superiority installed "
                f"phase={phase} tick={tick}{suffix}")
            fired = True
        # Reorder: any fire_superiority entry sitting AT OR AFTER a
        # ring_walker entry must move above it -- layer_ladder's `gated`
        # bucket preserves `entries`' own input order among simultaneously
        # open gates (first-match-wins at the engine, the same fact RING
        # CONTROL's own reorder below relies on), so this is what actually
        # keeps "a live fight still wins over a zone-repositioning walk"
        # true on the wire, on every source (including maintenance, where
        # an already-present fire_superiority entry can still be misordered
        # by a stale cached ladder) -- reordering an EXISTING entry carries
        # none of the presence/monopolization risk discussed above, only
        # insert-if-missing does, so this half is unconditional on source.
        fs_positions = [i for i, e in enumerate(entries)
                        if e.get("play") == "fire_superiority"]
        ring_positions = [i for i, e in enumerate(entries)
                          if e.get("play") == "ring_walker"]
        if (fs_positions and ring_positions
                and max(fs_positions) >= min(ring_positions)):
            moved = [entries.pop(i) for i in sorted(fs_positions, reverse=True)]
            ring_positions = [i for i, e in enumerate(entries)
                              if e.get("play") == "ring_walker"]
            insert_at = min(ring_positions)
            for offset, moved_entry in enumerate(reversed(moved)):
                entries.insert(insert_at + offset, moved_entry)
            starter_harness._log(
                PERSONA,
                f"clamp fight_pin{tag}: fire_superiority reordered above "
                f"ring_walker (was index {fs_positions}){suffix}")
            fired = True

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
    # clamp/log/maintenance-bypass-closing mechanism. `phase` itself is
    # computed once, above (v60 hoist), and reused here.
    #
    # breakDeficit (v62, FOUR DIGITS lane, belt-and-suspenders): the
    # turn-wire read (2026-09-23, ~/.ctf/handoff/2026-09-23-xp-turn-wire.md)
    # found breakDeficit already correct on 100% of hosted fs-present sent
    # calls (0/422 wrong) -- W2's canned-turn literal bump (2->4) and the
    # Nim-side manifest default bump already close this in practice. Added
    # to the SAME per-entry loop as a cheap, unconditional pin anyway (one
    # more field, not a new mechanism) so a future drift back to 2 -- a
    # stale cached ladder, a model turn that copies an old value -- cannot
    # silently reach the wire either.
    for entry in entries:
        if entry.get("play") != "fire_superiority":
            continue
        params = entry.setdefault("params", {})
        for field, doctrine_by_phase in (
                ("pressRange", FIRE_SUPERIORITY_PRESS_RANGE),
                ("finishRange", FIRE_SUPERIORITY_FINISH_RANGE),
                ("engageDist", FIRE_SUPERIORITY_ENGAGE_DIST),
                ("breakDeficit", FIRE_SUPERIORITY_BREAK_DEFICIT)):
            doctrine = doctrine_by_phase[phase]
            old = params.get(field)
            if old != doctrine:
                starter_harness._log(
                    PERSONA,
                    f"clamp fire_superiority.{field}{tag} {old!r}->{doctrine} "
                    f"phase={phase}{suffix}")
                fired = True
            params[field] = doctrine

    # FIRE_SUPERIORITY WHEN GUARD -- pin only (W11, FOUR DIGITS lane v63,
    # 2026-09-23/24): see the module-level FS_WHEN_GUARD/NOFSWHEN comment
    # for the full WHY. Deliberately NOT another insert-if-missing -- FIGHT
    # PIN just above already owns candidate presence/ordering on the call
    # path (that mechanism, and its own NOFIGHTPIN kill switch, are
    # untouched by this lever). This is a PIN only, same "every fire_
    # superiority entry already on the list, every send path including
    # maintenance" discipline as the pressRange/finishRange/engageDist/
    # breakDeficit loop just above: whatever put the entry there --
    # FIGHT PIN's insert, a canned turn, a model call, or a maintenance
    # resend carrying a stale/missing value -- gets the SAME guard
    # expression, so `when` is never the one field this doctrine forgets to
    # re-assert on any path.
    if not NOFSWHEN:
        for entry in entries:
            if entry.get("play") != "fire_superiority":
                continue
            old_when = entry.get("when")
            if old_when != FS_WHEN_GUARD:
                starter_harness._log(
                    PERSONA,
                    f"clamp fire_superiority.when{tag} "
                    f"{'set' if old_when is None else 'changed'}{suffix}")
                fired = True
            entry["when"] = FS_WHEN_GUARD

    # RING CONTROL (W3, FOUR DIGITS lane, 2026-09-22): make ring_walker's
    # wire presence, ladder position, and params a guaranteed, phase-
    # scheduled doctrine instead of whatever a model turn happened to
    # submit (or omit). See the module-level NORINGCONTROL/
    # RING_CONTROL_SCHEDULE comment above for the full WHY, the
    # edge_ride-vs-ring_walker decision, and the margin/enterLead->
    # inset/leadTicks mapping. Disabled in one flag (NORINGCONTROL) for a
    # clean rollback to pre-lever behaviour (this block becomes a no-op;
    # the canned-turn literals' own ring_walker ENTRY still exists and
    # still sits after the engage plays -- that reorder is a structural
    # correctness fix, not part of what NORINGCONTROL rolls back).
    if not NORINGCONTROL:
        ring_phase = _ring_control_phase(tick)
        ring_doctrine = RING_CONTROL_SCHEDULE[ring_phase]
        # v65 ORDER (FOUR DIGITS lane, 2026-09-24, ~/.ctf/handoff/
        # 2026-09-22-four-digits-lane.md "W12 FINAL"): `engage_positions`
        # used to include hold_vs_gun alongside fire_superiority, so
        # ring_walker was reordered below BOTH -- but v62's FIGHT PIN only
        # ever reorders fire_superiority above ring_walker, never
        # hold_vs_gun, so on the rig (v64, 3 seeds, eval_mapspec_r5733)
        # every tick fire_superiority's engine `when` guard yielded (no
        # live track) went first to hold_vs_gun's own unguarded calm-
        # fallback branch (15-22% of contact ticks) -- ring_walker never
        # got a look (rw+jk after contact 1.07%, target >=10%). Scoped to
        # fire_superiority ONLY here: ring_walker now reorders to sit
        # right after fire_superiority (still below a live fight) but
        # ahead of hold_vs_gun. The mirror pin just below (HOLD_VS_GUN
        # BELOW RING_WALKER) is what keeps hold_vs_gun's own position
        # honest relative to ring_walker on every path -- a reorder, not a
        # matching `when` guard, because hold_vs_gun's whole job (see the
        # module-level RETURN FIRE / mechanism (B) comment) is returning
        # fire from an aggressor BEARING with NO track at all, and the
        # engine's guard vocabulary (playGuardContext: world.enemy_count/
        # nearest_enemy_dist/in_zone/zone_dist, self.hp_frac, intent.*,
        # partner.*) has no aggressor-freshness term -- reusing
        # FS_WHEN_GUARD verbatim on hold_vs_gun would gate it on a TRACK
        # existing, exactly the case it exists to cover when one does not.
        engage_positions = [i for i, e in enumerate(entries)
                           if e.get("play") == "fire_superiority"]
        ring_positions = [i for i, e in enumerate(entries)
                         if e.get("play") == "ring_walker"]
        # Reorder: a ring_walker entry sitting AT OR BEFORE the last
        # fire_superiority entry must move below it -- layer_ladder's
        # `gated` bucket preserves `entries`' own input order among
        # simultaneously-open gates (first-match-wins at the engine), so
        # this is what actually makes "a live fight still takes
        # precedence when a fresh track is inside engage range" true on
        # the wire, not just in doctrine prose.
        if (engage_positions and ring_positions
                and min(ring_positions) <= max(engage_positions)):
            moved = [entries.pop(i) for i in sorted(ring_positions, reverse=True)]
            insert_at = max(i for i, e in enumerate(entries)
                           if e.get("play") == "fire_superiority") + 1
            for offset, moved_entry in enumerate(reversed(moved)):
                entries.insert(insert_at + offset, moved_entry)
            starter_harness._log(
                PERSONA,
                f"ring_control clamp{tag}: ring_walker reordered below "
                f"fire_superiority (was index {ring_positions}){suffix}")
            fired = True

        # HOLD_VS_GUN BELOW RING_WALKER (v65, FOUR DIGITS lane,
        # 2026-09-24): the other half of the same fix -- any hold_vs_gun
        # entry sitting AT OR BEFORE a ring_walker entry must move below
        # it, same layer_ladder input-order argument as every other
        # reorder pin in this function. Unconditional on source (like
        # FIGHT PIN's own fs-above-ring reorder): this only ever reorders
        # EXISTING entries, never inserts one, so it carries none of the
        # maintenance-path monopolization risk that gates the insert-if-
        # missing rung below to source != "maintenance".
        holdgun_positions = [i for i, e in enumerate(entries)
                             if e.get("play") == "hold_vs_gun"]
        ring_positions_now = [i for i, e in enumerate(entries)
                              if e.get("play") == "ring_walker"]
        if (holdgun_positions and ring_positions_now
                and min(holdgun_positions) <= max(ring_positions_now)):
            moved = [entries.pop(i)
                     for i in sorted(holdgun_positions, reverse=True)]
            ring_positions_now = [i for i, e in enumerate(entries)
                                  if e.get("play") == "ring_walker"]
            insert_at = max(ring_positions_now) + 1
            for offset, moved_entry in enumerate(reversed(moved)):
                entries.insert(insert_at + offset, moved_entry)
            starter_harness._log(
                PERSONA,
                f"ring_control clamp{tag}: hold_vs_gun reordered below "
                f"ring_walker (was index {holdgun_positions}){suffix}")
            fired = True
        # Insert-if-missing: guarantee an entry exists, positioned right
        # after the last engage entry (or at the end if none is present
        # -- still ahead of jackal: jackal is Monet's base_play, always
        # lands in `base`, and `layer_ladder` returns `overlays + gated +
        # base`, so `base` is behind `gated` regardless of `entries`
        # order). This is the guarantee a live model turn omitting
        # ring_walker entirely (the peer brief's field read: "Monet calls
        # no zone/ring play at all") cannot defeat.
        #
        # source != "maintenance" ONLY: `entries` on the maintenance path
        # (starter_harness._live_loop, ~line 1988) is ALREADY the
        # POST-gate wire ladder (`gate_and_build`'s own `gate_open()` ran
        # first) -- ring_walker being absent there most of the time is
        # NOT the gap this guards; it is ring_walker's OWN gate
        # (`not in_next_zone and ticks_to_shrink < leadTicks`) correctly
        # saying "nothing to walk right now". Inserting unconditionally
        # on THAT path would make ring_walker win first-match over
        # jackal on literally every maintenance tick (~every 2s, the
        # large majority of a ~25000-tick episode) regardless of its own
        # gate -- caught empirically: a first treatment run showed 4863
        # insert events across 6 seeds/48 seats, an order of magnitude
        # more than the handful of real model/canned calls per episode,
        # which starves jackal's own play_step (afterKill/bothWeakened
        # join logic) of ever running while ring_walker holds. On the
        # CALL path (source is None or "final4-reemit", both via
        # `repair_call`->`adjust_entries`, called BEFORE `gate_and_build`
        # -- see repair_call's own body), `entries` is still the PRE-gate
        # wanted ladder, so inserting here only makes ring_walker a
        # CANDIDATE that the real `gate_open()` still filters honestly a
        # moment later in `layer_ladder` -- that is the actual "a live
        # model call cannot drop it" guarantee, and it is safe.
        if source != "maintenance" and not any(
                e.get("play") == "ring_walker" for e in entries):
            # v65 ORDER: still after fire_superiority (if any), but now
            # also BEFORE hold_vs_gun (if any and no fire_superiority is
            # present to anchor on -- e.g. the opening canned turn, which
            # carries hold_vs_gun with no fire_superiority entry at all)
            # rather than defaulting to end-of-list, which used to land
            # ring_walker AFTER hold_vs_gun in exactly that case.
            if engage_positions:
                insert_at = max(engage_positions) + 1
            else:
                _holdgun_only = [i for i, e in enumerate(entries)
                                 if e.get("play") == "hold_vs_gun"]
                insert_at = min(_holdgun_only) if _holdgun_only else len(entries)
            entries.insert(insert_at, {"play": "ring_walker",
                                       "entry_id": "ring", "params": {}})
            starter_harness._log(
                PERSONA,
                f"ring_control clamp{tag}: ring_walker installed "
                f"phase={ring_phase} tick={tick}{suffix}")
            fired = True
        # Phase-scheduled doctrine pin: every ring_walker entry now on the
        # list (freshly inserted above, or one already there) gets the
        # current phase's inset/leadTicks, same unconditional-pin
        # discipline as fire_superiority's pressRange/finishRange/
        # engageDist above -- a model-submitted value is always
        # overwritten, never merely defaulted.
        for entry in entries:
            if entry.get("play") != "ring_walker":
                continue
            params = entry.setdefault("params", {})
            old_lead = params.get("leadTicks")
            old_inset = params.get("inset")
            new_lead = ring_doctrine["leadTicks"]
            new_inset = ring_doctrine["inset"]
            if old_lead != new_lead or old_inset != new_inset:
                starter_harness._log(
                    PERSONA,
                    f"ring_control clamp{tag}: ring_walker leadTicks "
                    f"{old_lead!r}->{new_lead} inset {old_inset!r}->"
                    f"{new_inset} phase={ring_phase} tick={tick}{suffix}")
                fired = True
            params["leadTicks"] = new_lead
            params["inset"] = new_inset

    # RING WHEN GUARD -- pin only (W16, FOUR DIGITS lane v67, 2026-09-24):
    # see the module-level RING_WHEN_GUARD/NORINGWHEN comment for the full
    # WHY and the guard-derivation rejection. Deliberately NOT another
    # insert-if-missing -- RING CONTROL just above already owns candidate
    # presence/ordering on both the call path (its own insert-if-missing)
    # and, via that entry's `when` plus KEEP_WHEN_PLAYS membership, the
    # maintenance path too (layer_ladder's `keep_when` bypass runs inside
    # gate_and_build on that path exactly as it does on the call path --
    # confirmed by reading gate_and_build/_live_loop directly). This block
    # is a PIN ONLY, same "every ring_walker entry already on the list,
    # every send path including maintenance" discipline as FS_WHEN_GUARD's
    # own pin loop: whatever put the entry there -- RING CONTROL's insert,
    # a canned turn, a model call, or a maintenance resend carrying a
    # stale/missing value -- gets the same guard expression, so `when` is
    # never the one field this doctrine forgets to re-assert on any path.
    # Independent of NORINGCONTROL: this loop only touches entries already
    # present (from ANY source, RING CONTROL included or not), so it stays
    # live even if NORINGCONTROL is flipped True to disable that other
    # lever's own insert/reorder/schedule behaviour.
    if not NORINGWHEN:
        for entry in entries:
            if entry.get("play") != "ring_walker":
                continue
            old_when = entry.get("when")
            if old_when != RING_WHEN_GUARD:
                starter_harness._log(
                    PERSONA,
                    f"ring_control clamp{tag}: ring_walker when="
                    f"{'set' if old_when is None else 'changed'} "
                    f"phase={phase} tick={tick}{suffix}")
                fired = True
            entry["when"] = RING_WHEN_GUARD

    # FOUR DIGITS lane (W1, 2026-09-22): RING_LEAD_WIDE / RING_INSET_WIDE
    # doctrine pins, same clamp/log mechanism as the loop just above --
    # default False (both), so with neither armed this loop is a no-op and
    # the wire stays byte-identical to control (inset=64/leadTicks=240,
    # the canned-turn literals). Armed one at a time for the local
    # tick-share instrument's variant reads; never both variants at once
    # (that would conflate two levers in one read).
    if RING_LEAD_WIDE or RING_INSET_WIDE:
        for entry in entries:
            if entry.get("play") != "ring_walker":
                continue
            params = entry.setdefault("params", {})
            if RING_LEAD_WIDE:
                old = params.get("leadTicks")
                if old != RING_LEAD_WIDE_TICKS:
                    starter_harness._log(
                        PERSONA,
                        f"clamp ring_walker.leadTicks{tag} {old!r}->"
                        f"{RING_LEAD_WIDE_TICKS}{suffix}")
                    fired = True
                params["leadTicks"] = RING_LEAD_WIDE_TICKS
            if RING_INSET_WIDE:
                old = params.get("inset")
                if old != RING_INSET_WIDE_PX:
                    starter_harness._log(
                        PERSONA,
                        f"clamp ring_walker.inset{tag} {old!r}->"
                        f"{RING_INSET_WIDE_PX}{suffix}")
                    fired = True
                params["inset"] = RING_INSET_WIDE_PX

    # FOUR DIGITS lane (W1, 2026-09-22): PROACTIVE_RECENTER -- a wider,
    # Monet-only proactive-recenter trigger. Reuses `facts`/`phase` already
    # computed unconditionally above (v59.1/v60 hoists); condition mirrors
    # gate_open's own ring_walker predicate (starter_harness.py ~895-906)
    # but with a WIDER window (PROACTIVE_RECENTER_TICKS, doctrine-larger
    # than any leadTicks value above) so the boost can arm before
    # ring_walker's own gate would otherwise open on the doctrine leadTicks
    # value. Boosts inset+leadTicks together for that window only; default
    # False, so with PROACTIVE_RECENTER unset this block never runs and the
    # wire stays byte-identical to control.
    if PROACTIVE_RECENTER and not NORINGCONTROL:
        ticks_to_shrink = facts.get("ticks_to_shrink")
        proactive_open = bool(
            not facts.get("in_next_zone", True)
            and ticks_to_shrink is not None
            and ticks_to_shrink < PROACTIVE_RECENTER_TICKS)
        if proactive_open:
            for entry in entries:
                if entry.get("play") != "ring_walker":
                    continue
                params = entry.setdefault("params", {})
                old_lead = params.get("leadTicks")
                old_inset = params.get("inset")
                if (old_lead != PROACTIVE_RECENTER_LEAD
                        or old_inset != PROACTIVE_RECENTER_INSET):
                    starter_harness._log(
                        PERSONA,
                        f"proactive-recenter clamp{tag}: ring_walker "
                        f"leadTicks {old_lead!r}->{PROACTIVE_RECENTER_LEAD} "
                        f"inset {old_inset!r}->{PROACTIVE_RECENTER_INSET} "
                        f"tts={ticks_to_shrink}{suffix}")
                    fired = True
                params["leadTicks"] = PROACTIVE_RECENTER_LEAD
                params["inset"] = PROACTIVE_RECENTER_INSET

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

    # HEAT-WINDOW AGGRESSION LOCK (v56, see HEAT_WINDOW_TICKS/
    # HEAT_WINDOW_DETOUR_MAX module comment for the WHY and the source
    # citations): same shape as the FINAL FOUR clamp just above -- gated
    # on its own predicate (`heat_window_state`, computed once above by
    # the OPENING/HEAT-WINDOW HUNTER block -- not a second call into
    # _update_heat_window, and not _final4), same two plays (supply_run/
    # loot), same min()-against-whatever's-on-the-wire clamp so it
    # composes correctly with the final-four clamp above (and with each
    # other on repeated calls) regardless of call order -- never a raw
    # overwrite. Independent of _final4: a heat-paying kill early in a
    # round (alive_teams > 4) locks the window exactly the same as one at
    # final four, where both predicates being true just means both clamps
    # agree (min() already makes the tighter one win). Unconditional on
    # HEAT_HUNTER (v58's kill switch) -- that switch only gates the
    # play-swap use of this same clock above, never this pin.
    if heat_window_state:
        for entry in entries:
            play = entry.get("play")
            if play not in ("supply_run", "loot"):
                continue
            params = entry.setdefault("params", {})
            old_detour = params.get("detourMax")
            new_detour = (min(old_detour, HEAT_WINDOW_DETOUR_MAX)
                          if isinstance(old_detour, (int, float))
                          else HEAT_WINDOW_DETOUR_MAX)
            if old_detour != new_detour:
                starter_harness._log(
                    PERSONA,
                    f"heat-window clamp{tag}: {play}.detourMax {old_detour!r} "
                    f"-> {HEAT_WINDOW_DETOUR_MAX}{suffix}")
                fired = True
            params["detourMax"] = new_detour

    # v59.1 DIAGNOSTIC (owner brief 2026-09-21 EOD): ONE unconditional line
    # per call, independent of whether ANY clamp above fired -- the
    # aggressor-wire audit (handoff §34) found the return-fire clamp
    # 0/12 on the live wire with no "aggressor" token in any log, and the
    # clamp lines above only log on an actual insert/strip, so there was no
    # way to see WHY (stale/no track vs. no aggressor at all vs. gate
    # already open) without this. Same logger/style as the clamp lines;
    # read-only, no new constant, no flow change. `aggr_n`/`aggr_age` come
    # from the raw view (facts has no raw aggressor list, only the derived
    # aggressor_hot bool the RETURN FIRE gate reads); `track_age` is the
    # freshest fresh_tick among `facts["enemies"]`, same set the RETURN
    # FIRE/opening/heat blocks above already read. `plays` is the entries
    # list as it stands at this point -- the last mutation site in this
    # function, so it is the fullest ladder any wire send path (real call,
    # reemit, or maintenance-resend-on-already-gated-entries) has seen by
    # the time it reaches us. `rfr` (v60) is `return_fire_range_active`
    # itself, 1/0 rather than True/False so a grep/count over raw log text
    # never has to special-case Python bool spelling.
    aggressors = (view or {}).get("aggressors", []) or []
    aggr_ticks = [a["tick"] for a in aggressors
                  if isinstance(a, dict) and isinstance(a.get("tick"), int)]
    aggr_age = (tick - max(aggr_ticks)) if aggr_ticks else None
    enemy_ticks = [e["fresh_tick"] for e in facts["enemies"]
                   if isinstance(e.get("fresh_tick"), int)]
    track_age = (tick - max(enemy_ticks)) if enemy_ticks else None
    nearest_px = facts["nearest_enemy"]
    if isinstance(nearest_px, (int, float)):
        nearest_px = round(nearest_px)
    hp = facts["hp_frac"]
    if isinstance(hp, (int, float)):
        hp = round(hp, 2)
    # `plays` is the one unbounded field (wire.MAX_LADDER_ENTRIES=16, and
    # this function sees entries BEFORE that cap on the adjust_entries
    # path) -- clip it so a full ladder can never push the line past the
    # ~200-char budget the rest of the fields already fit comfortably
    # inside.
    plays_str = ",".join(e.get("play") for e in entries)
    if len(plays_str) > 60:
        plays_str = plays_str[:57] + "..."
    starter_harness._log(
        PERSONA,
        f"[diag] tick={tick} src={source or 'call'} aggr_n={len(aggressors)} "
        f"aggr_age={aggr_age} fs_open={fire_superiority_open} "
        f"rfr={int(return_fire_range_active)} "
        f"enemies_n={len(facts['enemies'])} track_age={track_age} "
        f"nearest_px={nearest_px} hp={hp} plays={plays_str}")
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
    # `confirmed_seats` (v46) is the subset of `pact_seats` that has earned
    # the target_law never-target guarantee -- see CONFIRMED_PACT_REASONS.
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

    # TRUCE HONOR + FIRE DISCIPLINE: the never-list is derived, not trusted.
    # Ending a truce means dropping the pact entry -- the law then releases
    # those seats on the same call, and never sooner. v46: only CONFIRMED
    # partners (named us back, or the untouched DUO/real-submission paths)
    # earn the no-fire guarantee -- unilateral fallback/retry picks stay
    # named on the wire (pact_seats, used above for onBetrayal/params only)
    # but do NOT reach target_law.never until confirmed (see
    # CONFIRMED_PACT_REASONS; field-measured motive at that constant).
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
    pstate = context.setdefault("_pact_state", {})
    # v56 (HEAT-WINDOW LOCK): apply_phase_clamps only ever receives `view`,
    # never `context` (see its own docstring/_update_heat_window) -- the
    # maintenance resend call site in starter_harness.py passes it
    # `seat.pact_state` directly with no context in scope at all. Stash our
    # own team color (`self_facts` already computed at the top of this
    # function) into the SAME persisted dict every send path shares, once
    # per real/reemit call, so it is already there by the time the
    # maintenance loop's first iteration runs (run() always makes a seed
    # and an opening repair_call, both through here, before _live_loop's
    # maintenance block ever executes).
    my_team = self_facts.get("team")
    if isinstance(my_team, str):
        pstate["_my_team"] = my_team
    apply_phase_clamps(entries, view, pstate,
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
                       "one. The harness mirrors your partner and every "
                       "pact seat into never; you release seats by dropping "
                       "the pact, never by editing the list. Set a "
                       "holdTrigger only for a planned endgame release: a "
                       "released hold LATCHES and can never re-arm."),
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
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "ring_walker", "entry_id": "ring",
                 # RING CONTROL (W3, 2026-09-22) + v65 ORDER (FOUR
                 # DIGITS lane, 2026-09-24): moved BELOW fire_superiority
                 # but ABOVE hold_vs_gun (was above both) --
                 # apply_phase_clamps' own reorder pins enforce this on
                 # every send path regardless, but the source stays
                 # honest, same convention as the doctrine literals
                 # elsewhere in this file. Params are the "opening"
                 # doctrine (RING_CONTROL_SCHEDULE) -- apply_phase_
                 # clamps repins them every send too. No `when` here: W16
                 # FOUR DIGITS v67's RING_WHEN_GUARD defaults OFF
                 # (NORINGWHEN=True, rig-proven dead -- see the
                 # module-level RING_WHEN_GUARD comment's "RIG RESULT"),
                 # so the source stays honest with the shipped default:
                 # ring_walker carries no `when` unless a future worker
                 # arms NORINGWHEN=False.
                 "params": {"inset": 179, "leadTicks": 384}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 # v65 ORDER (FOUR DIGITS lane, 2026-09-24): moved BELOW
                 # ring_walker -- see the module-level FS_WHEN_GUARD
                 # comment's "W12 FINAL"/v65 note and apply_phase_
                 # clamps' own hold-vs-gun-below-ring-walker reorder pin
                 # (the mirror of FIGHT PIN's fs-above-ring reorder) for
                 # the full WHY, including why this is a reorder and not
                 # a matching `when` guard: hold_vs_gun's whole job is
                 # firing back with NO track, which the guard vocabulary
                 # cannot express without breaking that case.
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
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # W11 FOUR DIGITS v63: `when` (see the module-level
                 # FS_WHEN_GUARD comment) is written here to match doctrine
                 # for source honesty -- apply_phase_clamps' when-pin loop
                 # repins it on every send regardless.
                 "when": FS_WHEN_GUARD,
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
                 # v61 (FOUR DIGITS lane, fire persistence): breakDeficit
                 # 2->4, matching fire_superiority.nim's own raised default
                 # (RaisedBreakDeficit). Supersedes the v10 "STAYS PARKED"
                 # ruling below -- that ruling weighed an unconditional,
                 # blanket "keep fighting while outgunned"; v61 pairs this
                 # wire bump with the Nim-side no-break WINDOW (only
                 # suppresses BREAK for FirePersistTicks after we land a
                 # tag on a target still alive and tracked inside
                 # engageDist, never an unconditional license to brawl), so
                 # the negative-EV case v10 flagged (tag out with nothing to
                 # show for it) is the one case this lever does NOT reach.
                 "params": {"breakDeficit": 4, "coverMax": 260,
                            "engageDist": 750, "finishRange": 140,
                            "pressRange": 220, "woundedPct": 50}},
                {"play": "ring_walker", "entry_id": "ring",
                 # RING CONTROL (W3, 2026-09-22) + v65 ORDER (FOUR
                 # DIGITS lane, 2026-09-24): moved BELOW fire_superiority
                 # but ABOVE hold_vs_gun -- see the opening turn's
                 # ring_walker entry for the full note. Params are the
                 # "mid" doctrine (RING_CONTROL_SCHEDULE); apply_phase_
                 # clamps repins every send regardless. No `when` here:
                 # W16 v67's RING_WHEN_GUARD defaults OFF (NORINGWHEN=
                 # True, rig-proven dead -- see the module-level comment).
                 "params": {"inset": 102, "leadTicks": 280}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 # v65 ORDER (FOUR DIGITS lane, 2026-09-24): moved BELOW
                 # ring_walker -- see the opening turn's hold_vs_gun
                 # entry for the full note and apply_phase_clamps' own
                 # reorder pin.
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
                {"play": "medic", "entry_id": "pickup",
                 # zoneReach 220->0 (zoneBlocksRevive armed 0.7.323): the
                 # dip this budget paid for walks into exactly the band
                 # where the revive channel silently cannot advance.
                 "params": {"abortHpFloor": 1, "zoneReach": 0}},
                {"play": "fire_superiority", "entry_id": "pressbreak",
                 # W11 FOUR DIGITS v63: `when` (see the module-level
                 # FS_WHEN_GUARD comment) is written here to match doctrine
                 # for source honesty -- apply_phase_clamps' when-pin loop
                 # repins it on every send regardless.
                 "when": FS_WHEN_GUARD,
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
                 # v61 (FOUR DIGITS lane, fire persistence, FIRST occurrence
                 # of this wire pin -- consolidation carries the same
                 # rationale, see that entry): breakDeficit 2->4. This
                 # SUPERSEDES the v10 ruling directly above -- v10 weighed
                 # an unconditional deficit bump ("keep fighting while
                 # outgunned" full stop); v61 pairs the bump with a
                 # Nim-side no-break WINDOW that only suppresses BREAK for
                 # FirePersistTicks (~240 ticks) after landing a tag on a
                 # target still alive and still tracked inside engageDist
                 # (fire_superiority.nim persistHolds), so the exact
                 # negative-EV shape v10 flagged -- tag out for nothing --
                 # is the one case this lever is built NOT to reach; Jordan
                 # fires 3.38 shots/1k alive ticks vs our 2.44
                 # (jordan-decode-tables.md) by staying in fights we
                 # already started, not by brawling into new ones.
                 "params": {"breakDeficit": 4, "coverMax": 260,
                            "engageDist": 750, "finishRange": 140,
                            "pressRange": 220, "woundedPct": 50}},
                {"play": "ring_walker", "entry_id": "ring",
                 # RING CONTROL (W3, 2026-09-22) + v65 ORDER (FOUR
                 # DIGITS lane, 2026-09-24): moved BELOW fire_superiority
                 # but ABOVE hold_vs_gun -- see the opening turn's
                 # ring_walker entry for the full note. Params are the
                 # "mid" doctrine (RING_CONTROL_SCHEDULE); apply_phase_
                 # clamps repins every send regardless. No `when` here:
                 # W16 v67's RING_WHEN_GUARD defaults OFF (NORINGWHEN=
                 # True, rig-proven dead -- see the module-level comment).
                 "params": {"inset": 102, "leadTicks": 280}},
                {"play": "hold_vs_gun", "entry_id": "holdgun",
                 # v65 ORDER (FOUR DIGITS lane, 2026-09-24): moved BELOW
                 # ring_walker -- see the opening turn's hold_vs_gun
                 # entry for the full note and apply_phase_clamps' own
                 # reorder pin.
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
                 # W11 FOUR DIGITS v63: `when` (see the module-level
                 # FS_WHEN_GUARD comment) is written here to match doctrine
                 # for source honesty -- apply_phase_clamps' when-pin loop
                 # repins it on every send regardless.
                 "when": FS_WHEN_GUARD,
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
                 # v61 (FOUR DIGITS lane, fire persistence): breakDeficit
                 # 2->4, same supersession of the v10/mid-turn "PARKED"
                 # ruling as the other two occurrences (see the mid-turn
                 # entry's v61 comment for the full WHY) -- paired with the
                 # Nim-side no-break window, not an unconditional bump.
                 "params": {"breakDeficit": 4, "coverMax": 200,
                            "engageDist": 750, "finishRange": 120,
                            "pressRange": 220, "woundedPct": 0}},
                {"play": "ring_walker", "entry_id": "ring",
                 # RING CONTROL (W3, 2026-09-22): moved BELOW
                 # fire_superiority -- see the opening turn's ring_walker
                 # entry for the full note. Params are the "late" doctrine
                 # (RING_CONTROL_SCHEDULE); apply_phase_clamps repins
                 # every send regardless. No `when` here: W16 v67's
                 # RING_WHEN_GUARD defaults OFF (NORINGWHEN=True,
                 # rig-proven dead -- see the module-level comment).
                 "params": {"inset": 230, "leadTicks": 320}},
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
