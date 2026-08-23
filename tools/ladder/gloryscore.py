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
of truth for every number; the tables below are a hand-checked copy pinned to
GLORY_VERSION. If glory.nim changes without this file, the version bump is
the tripwire. This mirror prices deeds over the tier-2 event stream, so a few
context bits the live sim knows first-hand are approximated or dropped —
each is labelled at its site, and every one UNDER-counts:
  - dRunDown / dRevengeKill: victim velocity and killer-of-killer windows are
    not derivable offline -> those kills price as their weapon kill.
  - range (point-blank / longshot): killer position is the LAST event that
    carried one (a shot, throw, or spray), not the true position at the kill
    tick.
  - the site gradient: pedestals are recovered from flag_steal coordinates
    (a flag leaves its pedestal AT its pedestal); episodes where a flag was
    never stolen price everything neutral.
  - dWipe: the tier-2 stream carries no "team eliminated" event, so this
    deed was NEVER minted here (the pricing table had it, nothing fired it)
    and every wipe-ended episode under-counted the winner's glory by 400.
    It is now INFERRED from the death ledger — see the WIPE MINTING block in
    main() — and labelled as an inference, not a first-hand read, because it
    is one.

Usage:
  gloryscore.py [--episodes N] [--min-version 0.7.200]
"""
import argparse
import collections
import glob
import json
import math
import os
import statistics

CACHE = os.path.expanduser("~/.ctf/scout")

# ── glory.nim mirror (pinned) ────────────────────────────────────────────────
GLORY_VERSION = 2

DEED_GLORY = {
    "first_blood": 12, "honorable_kill": 10, "spray_kill": 12,
    "grenade_kill": 12, "point_blank_kill": 12, "longshot_kill": 30,
    "splash_multikill": 35, "starfall": 40, "team_kill": -60,
    "flag_steal": 40, "flag_return": 35, "capture": 250,
    "carrier_kill": 90, "denial": 120,
    "clutch_heal": 25, "shield_soak": 4, "wipe": 400, "level_up": 6,
}
DEED_DRAMA = {
    "first_blood": 20, "honorable_kill": 10, "spray_kill": 30,
    "grenade_kill": 30, "point_blank_kill": 35, "longshot_kill": 40,
    "splash_multikill": 40, "starfall": 30, "team_kill": 0,
    "flag_steal": 25, "flag_return": 15, "capture": 70,
    "carrier_kill": 35, "denial": 45,
    "clutch_heal": 30, "shield_soak": 0, "wipe": 400, "level_up": 5,
    # ^ was 80: a mirror drift from glory.nim's DeedDramaTable (400). Harmless
    # until now because "wipe" was never minted by this file (see extension
    # 3) -- caught while wiring the wipe mint up, corrected to match source.
}
HEAT_LADDER = [1, 2, 4, 8]
HEAT_THRESHOLDS = [1, 4, 10]
HEAT_EMBER_CAP = 12
HEAT_EMBER_DECAY = 4
HEAT_DECAY_TICKS = 45

LEVEL_THRESHOLDS = [10, 18, 24, 36, 50]
# Maxwell's ruling: WORK levels, kills do not. Damage / healing / tool
# pickups / flag actions; the carrier kill prices as the RETURN it causes.
XP_KILL, XP_DAMAGE, XP_CARRIER_KILL = 0, 3, 12
XP_STEAL, XP_CAPTURE, XP_RETURN = 12, 30, 12
XP_SOAK, XP_CLUTCH, XP_TEAM_KILL = 2, 6, -20
XP_HEAL, XP_PICKUP = 3, 4
STARFALL_LEVEL = 3
TITHE_XP, TITHE_MAX, TITHE_COOLDOWN = 20, 4, 90

TIER_GLORY = [2, 4, 8, 16, 32]
FIRST_MULT = 3
POINT_BLANK_PX, LONGSHOT_PX, DENIAL_PX = 110, 700, 220

SITE_HOME, SITE_NEUTRAL, SITE_ENEMY = 100, 120, 150


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
    __slots__ = ("xp lvl hp gun spray nade long multi soak clutch clutch_t "
                 "steals returns peels denials caps tk spray_pickup "
                 "took_med took_nade took_spray took_shield carrying pos "
                 "steal_t killed_or_stole lifemax tithes tithe_credit "
                 "tithe_t peak").split()

    def __init__(self):
        for f in self.__slots__:
            setattr(self, f, 0)
        self.pos = None
        self.hp = 3
        self.tithe_t = -10**9
        self.clutch_t = -10**9
        self.steal_t = -10**9

    def reset_life(self):
        # THE anti-snowball rule, mirrored: death forfeits xp, level, and the
        # tithe allowance. Per-game counters (the achievement inputs) survive.
        self.xp = 0
        self.peak = 0
        self.tithes = 0
        self.tithe_credit = 0
        self.hp = 3


# The kit-keyed curriculum, mirrored from glory.nim's satisfiedAchievements.
# Team-level trees (squad) are evaluated on team aggregates.
def satisfied(cog, team_caps, team_kits, tk_free, tick, start_tick):
    s = set()
    kills = cog.gun + cog.spray + cog.nade
    if cog.gun or cog.spray or cog.nade or kills:
        pass
    # gun
    if cog.gun >= 1 or cog.spray >= 1 or cog.nade >= 1:
        s.add(("gun", 0))          # Trigger Discipline ~ landed a hit; a kill implies it
    if cog.gun >= 1:
        s.add(("gun", 1))
    if cog.gun >= 3:
        s.add(("gun", 2))
    if cog.long >= 1:
        s.add(("gun", 3))
    if cog.lifemax >= 5:
        s.add(("gun", 4))
    # spray
    if cog.took_spray:
        s.add(("spray", 0))
    if cog.spray >= 1:
        s.add(("spray", 1))
    if cog.multi >= 1 and cog.spray >= 2:
        s.add(("spray", 2))
    if cog.spray_pickup >= 2:
        s.add(("spray", 3))
    if cog.spray_pickup >= 3:
        s.add(("spray", 4))
    # grenade
    if cog.took_nade:
        s.add(("nade", 0))
    if cog.nade >= 1:
        s.add(("nade", 1))
    if cog.nade >= 2:
        s.add(("nade", 2))
    if cog.nade >= 1 and cog.multi >= 1:
        s.add(("nade", 3))
    if cog.nade >= 3:
        s.add(("nade", 4))
    # shield
    if cog.took_shield:
        s.add(("shield", 0))
    if cog.soak >= 3:
        s.add(("shield", 1))
    if cog.soak >= 6:
        s.add(("shield", 2))
    if cog.soak >= 6 and kills >= 1:
        s.add(("shield", 3))
    if cog.soak >= 12:
        s.add(("shield", 4))
    # med kit
    if cog.took_med:
        s.add(("med", 0))
    if cog.clutch >= 1:
        s.add(("med", 1))
    if cog.clutch >= 2:
        s.add(("med", 2))
    if cog.clutch >= 1 and kills >= 1 and tick - cog.clutch_t <= 120:
        s.add(("med", 3))
    if cog.clutch >= 3:
        s.add(("med", 4))
    # carrier
    if cog.steals >= 1:
        s.add(("carrier", 0))
    if cog.carrying and tick - cog.steal_t >= 120:
        s.add(("carrier", 1))
    if cog.caps >= 1:
        s.add(("carrier", 2))
    # ("carrier",3) Against the Odds needs live alive-counts: tracked by caller
    if cog.caps >= 1 and cog.steal_t > -10**8:
        s.add(("carrier", 4))
    # defender
    if cog.returns >= 1:
        s.add(("defender", 0))
    if cog.peels >= 1:
        s.add(("defender", 1))
    if cog.denials >= 1:
        s.add(("defender", 2))
    if cog.peels >= 1 and cog.steal_t > cog.clutch_t and False:
        pass  # Turnaround needs peel->steal ordering; tracked by caller
    if cog.denials >= 2:
        s.add(("defender", 4))
    # squad (team)
    if team_kits >= 2:
        s.add(("squad", 0))
    if team_kits >= 3:
        s.add(("squad", 1))
    if team_kits >= 4:
        s.add(("squad", 2))
    if tk_free and tick - start_tick >= 600:
        s.add(("squad", 3))
    if team_kits >= 4 and team_caps >= 1:
        s.add(("squad", 4))
    return s


def dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def score_episode(events, n_slots):
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
    pedestal = {}          # team -> (x, y), recovered from flag_steal
    first_blood = False
    start_tick = 0
    end_tick = 0
    prev_tick = 0
    levels_seen = []       # (slot, max level this life)
    l5_lives = 0
    l3_lives = [0, 0]
    killed_or_stole = set()
    reached_l1 = set()
    tithe_total = [0, 0]
    xp_peaks = []
    deaths_by_slot = collections.Counter()  # extension 3: wipe inference input

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
        if amount > 0 and c.lvl >= STARFALL_LEVEL:
            c.tithe_credit += amount
            if (c.tithes < TITHE_MAX and c.tithe_credit >= TITHE_XP
                    and tick - c.tithe_t >= TITHE_COOLDOWN):
                c.tithe_credit -= TITHE_XP
                c.tithes += 1
                c.tithe_t = tick
                tithe_total[team(slot)] += 1

    def check_achievements(tick):
        team_caps = [sum(c.caps for i, c in enumerate(cogs) if team(i) == t)
                     for t in (0, 1)]
        team_tk = [any(c.tk for i, c in enumerate(cogs) if team(i) == t)
                   for t in (0, 1)]
        kits = [0, 0]
        for t in (0, 1):
            k = set()
            for i, c in enumerate(cogs):
                if team(i) != t:
                    continue
                if c.took_med:
                    k.add("m")
                if c.took_nade:
                    k.add("n")
                if c.took_spray:
                    k.add("s")
                if c.took_shield:
                    k.add("h")
            kits[t] = len(k)
        newly = [set(), set()]
        for t in (0, 1):
            for i, c in enumerate(cogs):
                if team(i) != t:
                    continue
                newly[t] |= satisfied(c, team_caps[t], kits[t],
                                      not team_tk[t], tick, start_tick)
            newly[t] -= claimed[t]
        # same-tick FIRST ties: judge both teams before any claim lands
        for t in (0, 1):
            for key in newly[t]:
                first = key not in claimed_first
                claimed[t].add(key)
                amount = TIER_GLORY[key[1]] * (FIRST_MULT if first else 1)
                ach_glory[t] += amount
                glory[t] += amount
                claims[t].append((end_tick, key, first))
        for t in (0, 1):
            for key in newly[t]:
                claimed_first.setdefault(key, t)

    # 🚨 kills sort BEFORE same-tick flag_return/capture. Found while building
    # extension 1 below: carrier_kill/denial priced ZERO times across the
    # whole 120-episode field despite 236 flag_steal events -- the sim logs a
    # carrier's death and the resulting flag_return at the IDENTICAL tick,
    # flag_return first in the raw file (verified in the cache: tick 4961 has
    # ...,"flag_return","source":9 ... "kill","source":6,"target":9 in that
    # order), and a tick-only stable sort preserved it. So by the time the
    # kill handler read `victim.carrying` below, flag_return had already
    # cleared it, and EVERY carrier kill in the field mispriced as a plain
    # honorable/point-blank kill. This is the one ordering fix that matters:
    # nothing else here reads state a same-tick event could invalidate.
    for e in sorted(events, key=lambda e: (e.get("tick", 0),
                                            0 if e.get("kind") == "kill" else 1)):
        k = e.get("kind")
        tick = e.get("tick", 0)
        end_tick = tick
        heat_tick(tick)
        prev_tick = tick
        if k == "phase" and e.get("weapon") == "playing":
            start_tick = tick
        elif k == "item_pickup":
            s = e["source"]
            if s < 0 or s >= n_slots:
                continue
            c = cogs[s]
            item = e.get("item")
            c.pos = (e["x"], e["y"])
            if item == "med_kit":
                c.took_med = 1
                if c.hp <= 1:
                    c.clutch += 1
                    c.clutch_t = tick
                    mint(team(s), "clutch_heal", e["x"], e["y"])
                    add_xp(s, XP_CLUTCH, tick)
                add_xp(s, XP_PICKUP + XP_HEAL * max(0, 3 - c.hp), tick)
                c.hp = 3
            elif item == "grenade":
                c.took_nade = 1
                add_xp(s, XP_PICKUP, tick)
            elif item == "spray_can":
                c.took_spray = 1
                c.spray_pickup = 0
                add_xp(s, XP_PICKUP, tick)
            elif item == "shield":
                c.took_shield = 1
                add_xp(s, XP_PICKUP, tick)
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
        elif k == "heal":
            t = e.get("target", e.get("source", -1))
            if 0 <= t < n_slots:
                cogs[t].hp = e.get("hp", 3)
        elif k == "flag_steal":
            s = e["source"]
            if 0 <= s < n_slots:
                c = cogs[s]
                c.carrying = 1
                c.steals += 1
                c.steal_t = tick
                killed_or_stole.add(s)
                # the flag leaves its pedestal AT its pedestal: the stolen
                # flag belongs to the OTHER team
                pedestal[1 - team(s)] = (e["x"], e["y"])
                mint(team(s), "flag_steal", e["x"], e["y"])
                add_xp(s, XP_STEAL, tick)
        elif k == "flag_return":
            s = e.get("source", -1)
            if 0 <= s < n_slots:
                cogs[s].carrying = 0
            t = team(s) if 0 <= s < n_slots else 0
            for i, c in enumerate(cogs):
                if team(i) == t:
                    c.returns += 1
                    break
            mint(t, "flag_return", e.get("x"), e.get("y"))
        elif k == "capture":
            s = e["source"]
            if 0 <= s < n_slots:
                cogs[s].caps += 1
                cogs[s].carrying = 0
                mint(team(s), "capture", e["x"], e["y"])
                add_xp(s, XP_CAPTURE, tick)
        elif k == "kill":
            s, t = e.get("source", -1), e.get("target", -1)
            if not (0 <= s < n_slots and 0 <= t < n_slots):
                continue
            weapon = e.get("weapon", "gun")
            vx, vy = e.get("x", 0), e.get("y", 0)
            friendly = team(s) == team(t)
            victim = cogs[t]
            if not first_blood and not friendly:
                first_blood = True
                mint(team(s), "first_blood", vx, vy)
            # one kill, one deed — killDeed precedence mirrored
            if friendly:
                cogs[s].tk += 1
                mint(team(s), "team_kill")
                add_xp(s, XP_TEAM_KILL, tick)
            else:
                killed_or_stole.add(s)
                deed = None
                if victim.carrying:
                    own_ped = pedestal.get(team(t))
                    near_home = own_ped and dist((vx, vy), own_ped) <= DENIAL_PX
                    deed = "denial" if near_home else "carrier_kill"
                    cogs[s].peels += 1
                    if deed == "denial":
                        cogs[s].denials += 1
                    add_xp(s, XP_CARRIER_KILL, tick)  # the RETURN it causes
                # a plain kill levels nobody: the damage already did
                if deed is None and victim.lvl >= STARFALL_LEVEL:
                    deed = "starfall"
                if deed is None:
                    # multikill: another kill by the same source at this tick
                    same = [x for x in events_at.get((tick, s), []) if x != t]
                    if same:
                        deed = "splash_multikill"
                        cogs[s].multi = 1
                if deed is None and cogs[s].pos is not None:
                    r = dist(cogs[s].pos, (vx, vy))
                    if r >= LONGSHOT_PX:
                        deed = "longshot_kill"
                        cogs[s].long += 1
                    elif r <= POINT_BLANK_PX:
                        deed = "point_blank_kill"
                if deed is None:
                    deed = {"spray": "spray_kill",
                            "grenade": "grenade_kill"}.get(weapon,
                                                           "honorable_kill")
                mint(team(s), deed, vx, vy)
                if weapon == "spray":
                    cogs[s].spray += 1
                    cogs[s].spray_pickup += 1
                elif weapon == "grenade":
                    cogs[s].nade += 1
                else:
                    cogs[s].gun += 1
        elif k == "death":
            t = e.get("source", -1)
            if 0 <= t < n_slots:
                deaths_by_slot[t] += 1  # a life spent; lives-per-cog reads this
                c = cogs[t]
                xp_peaks.append(c.peak)
                levels_seen.append(c.lifemax)
                if c.lifemax >= 5:
                    l5_lives += 1
                if c.lifemax >= STARFALL_LEVEL:
                    l3_lives[team(t)] += 1
                c.carrying = 0
                c.reset_life()
                c.lifemax = 0
        check_achievements(tick)

    # end of episode: surviving cogs' lives count toward the ladder stats
    for i, c in enumerate(cogs):
        xp_peaks.append(c.peak)
        levels_seen.append(c.lifemax)
        if c.lifemax >= 5:
            l5_lives += 1
        if c.lifemax >= STARFALL_LEVEL:
            l3_lives[team(i)] += 1

    return {
        "glory": glory, "ach_glory": ach_glory, "drama_glory": drama_glory,
        "claims": claims, "deeds": deeds, "heat_ticks": heat_ticks,
        "levels": levels_seen, "l5": l5_lives, "l3": l3_lives,
        "p_l1": (len(reached_l1 & killed_or_stole),
                 len(killed_or_stole)),
        "tithes": tithe_total, "end_tick": end_tick, "xp_peaks": xp_peaks,
        "deaths_by_slot": deaths_by_slot,
    }


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
            # is entirely v0.7.95-98, which ships with NO item_pickup events
            # at all (0 across the whole sample) -- that's why spray/nade/
            # shield/med tier I ("took a kit") can never claim in the PER-TREE
            # RUNG ORDER report below. NOT fixed here: swapping in a numeric
            # (dotted-tuple) compare finds 144 real v0.7.207 candidates, but
            # the local scout cache has zero downloaded event files for any
            # of them today -- a numeric fix would print "scoring 0 real
            # episodes", not a better field. Fix belongs with re-fetching the
            # cache at a current version, not with this comparison.
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
    tithes_all = []
    xp_all = []
    by_policy = collections.defaultdict(lambda: collections.defaultdict(list))
    tree_tier_claims = collections.Counter()   # extension 1: (tree, tier) -> claims
    n_team_eps = 0                             # denominator: one row per (episode, team)
    winner_claims_lo, loser_claims_lo = [], []  # extension 2: T1-T2 claims/ep
    winner_claims_hi, loser_claims_hi = [], []  # extension 2: T3-T5 claims/ep
    episode_records = []                       # extension 3: wipe-inference input

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
        build_kill_index(events)
        r = score_episode(events, n_slots)

        deeds_all.update(r["deeds"])
        for t in (0, 1):
            n_team_eps += 1
            claims_per_team.append(len(r["claims"][t]))
            for tick, key, first in r["claims"][t]:
                tier_hist[key[1] + 1] += 1
                tree_tier_claims[key] += 1  # extension 1: key is (tree, tier)
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
            # extension 2: split the discrimination check by tier band. T1-T2
            # (tier index 0-1) is a single-condition "touched the kit" claim;
            # T3-T5 (index 2-4) needs a multi-event or cross-stat condition.
            # If the pooled 8.6-vs-6.7 gap lives entirely in T1-T2, the
            # curriculum is measuring who plays MORE, not who plays BETTER.
            lo = lambda t: sum(1 for _, k, _ in r["claims"][t] if k[1] <= 1)
            hi = lambda t: sum(1 for _, k, _ in r["claims"][t] if k[1] >= 2)
            winner_claims_lo.append(lo(win_team))
            loser_claims_lo.append(lo(1 - win_team))
            winner_claims_hi.append(hi(win_team))
            loser_claims_hi.append(hi(1 - win_team))
            # extension 3: stash what the wipe inference needs. Deferred to a
            # second pass because "lives-per-cog" is a SAMPLE-WIDE constant
            # (the max deaths ever seen on one slot) -- it can't be known
            # until every episode in the run has been read once.
            episode_records.append({
                "win_team": win_team,
                "glory": list(r["glory"]),
                "ach_glory": list(r["ach_glory"]),
                "captures": r["deeds"].get("capture", 0),
                "deaths_by_slot": r["deaths_by_slot"],
                "n_slots": n_slots,
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
        tithes_all.append(sum(r["tithes"]))
        xp_all.extend(r["xp_peaks"])

    # ── extension 3: WIPE MINTING ────────────────────────────────────────
    # glory.nim's dWipe (400 glory) fires when the sim eliminates a team; the
    # tier-2 event stream this file reads has no such event, so every
    # wipe-ended episode has under-counted the winner's glory by 400 in every
    # number above. Captures run 0.38/ep (see DEEDS below) -- most winners
    # never fire a single capture event, so they won by wipe or by clock, and
    # only the death ledger tells the two apart.
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
        if rec["deaths_by_slot"]:
            lives_per_cog = max(lives_per_cog,
                                 max(rec["deaths_by_slot"].values()))

    wipe_eps = time_eps = 0
    winner_glory_wc, winner_ach_share_wc = [], []
    for rec in episode_records:
        w = rec["win_team"]
        g = rec["glory"][w]
        if rec["captures"] == 0 and lives_per_cog > 0:
            team_size = rec["n_slots"] // 2
            losers = 1 - w
            losing_deaths = sum(v for slot, v in rec["deaths_by_slot"].items()
                                 if slot % 2 == losers)
            # every cog on the losing team spent every life it had -> wipe.
            # short of that with zero captures -> the clock ran out.
            if team_size > 0 and losing_deaths >= lives_per_cog * team_size:
                g += DEED_GLORY["wipe"]  # the mint this file was missing
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
    active = sorted(x for x in xp_all if x > 0)
    if active:
        pct = lambda q: active[min(len(active)-1, int(q*len(active)))]
        print("XP PEAKS PER LIFE (active lives only, for threshold tuning)")
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
    print("  caveat: spray/nade/shield/med/squad all key off item_pickup"
          " (took_X or team kit-count) and this field has ZERO pickups (see"
          " --min-version comment in main()) -- their inversions are a"
          " VERSION artifact, not a proven curriculum defect. gun's T4<T5 is"
          " real (longshot kills ARE rarer than reaching L5 in this field);"
          " carrier's T4 is a known mirror gap (\"Against the Odds\" needs"
          " live alive-counts satisfied() never got -- see its comment).")

    print("\nSWEEP BUDGET  (calibrates AchievementSweepBudgetPct, shipped=15)")
    print(f"  median WINNER episode glory: {med(winner_glory):.0f}")
    print(f"  achievement share of winner glory: "
          f"median {med(winner_ach_share):.1f}%")
    full_sweep = sum(TIER_GLORY) * 8
    print(f"  full-sweep base ({full_sweep}) as % of median winner: "
          f"{100*full_sweep/max(1,med(winner_glory)):.1f}%")

    print("\nSWEEP BUDGET, WIPE-CORRECTED  (extension 3: dWipe minted where "
          "the death ledger says the loser burned every life it had)")
    print(f"  inferred lives-per-cog (max deaths on any one slot, "
          f"sample-wide): {lives_per_cog}")
    zero_cap_eps = wipe_eps + time_eps
    print(f"  zero-capture endings: {wipe_eps} classified WIPE, {time_eps} "
          f"classified TIME (of {zero_cap_eps} zero-capture decided "
          f"episodes, {len(episode_records)} decided episodes total)")
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

    print(f"\nTITHES per episode: median {med(tithes_all):.0f}, "
          f"mean {statistics.mean(tithes_all):.2f} (cap {TITHE_MAX}/cog-life)")

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
