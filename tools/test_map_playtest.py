#!/usr/bin/env python3
"""Tests for the play-harness measures that a static metric cannot replace.

Run: python3 tools/test_map_playtest.py

The per-pedestal measure exists because of a real, measured failure: on two
4-team boards that score FAIR on every static symmetry metric, an enemy reached
only 2 of the 4 pedestals across three full episodes. The summed form could not
see it — the two contested pedestals carried the total. These tests build
synthetic evidence with that exact shape and assert the measure separates it
from a board where all four objectives are contested.

Static fairness is a claim about GEOMETRY. Reachability in play is a different
claim, and the epic had been treating them as the same thing.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import map_playtest as mp                                    # noqa: E402


def evidence(teams, ring_ticks, gw=9, gh=9, cell=10):
    """Synthetic evidence: `ring_ticks[target][attacker]` seat-ticks on a ring.

    Homes are placed far enough apart that their rings never overlap, so each
    pedestal's count is unambiguous — an overlap would make the test assert
    something the geometry, not the measure, decided.
    """
    corners = [(15, 15), (75, 15), (15, 75), (75, 75)][:teams]
    occ_team = [[0] * (gw * gh) for _ in range(teams)]
    for target, per_attacker in enumerate(ring_ticks):
        hx, hy = corners[target]
        cx, cy = hx // cell, hy // cell
        for attacker, ticks in enumerate(per_attacker):
            if ticks:
                # One cell inside the ring is enough; the measure sums the ring.
                occ_team[attacker][cy * gw + cx] += ticks
    return dict(
        map="synthetic", teams=teams, gw=gw, gh=gh, cell=cell,
        occTeam=occ_team, aliveTicks=10_000, flagRing=cell,
        homes=[{"x": x, "y": y} for x, y in corners])


def check(name, got, want):
    if got != want:
        raise SystemExit(f"FAIL {name}: got {got!r}, want {want!r}")
    print(f"  ok  {name}")


def test_unapproached_pedestal_is_visible_per_seat():
    """The measured failure: 2 of 4 objectives never entered, and the SUM lies.

    Both boards below have the SAME total enemy seat-ticks. Only the per-seat
    form separates them, which is the whole reason the aggregate was replaced.
    """
    # Two pedestals heavily contested, two never touched at all.
    lopsided = mp.pedestal_reach(evidence(4, [
        [0, 200, 200, 200],      # team 0's pedestal: all three enemies came
        [200, 0, 200, 200],      # team 1's pedestal: all three enemies came
        [0, 0, 0, 0],            # team 2's pedestal: NEVER APPROACHED
        [0, 0, 0, 0],            # team 3's pedestal: NEVER APPROACHED
    ]))
    # The same total, spread evenly over all four.
    even = mp.pedestal_reach(evidence(4, [
        [0, 100, 100, 100], [100, 0, 100, 100],
        [100, 100, 0, 100], [100, 100, 100, 0],
    ]))

    check("same total seat-ticks (the aggregate cannot separate these)",
          lopsided["ticks"], even["ticks"])
    check("lopsided: objectives approached", lopsided["reached"], 2)
    check("lopsided: which were never approached",
          lopsided["neverApproached"], [2, 3])
    check("even: objectives approached", even["reached"], 4)
    check("even: none unapproached", even["neverApproached"], [])
    check("even board balances 1.00",
          round(even["pressureBalance"], 2), 1.00)
    if not lopsided["pressureBalance"] < 0.55:
        raise SystemExit(
            f"FAIL lopsided pressure balance {lopsided['pressureBalance']:.2f} "
            "should be far from even")
    print(f"  ok  lopsided balances {lopsided['pressureBalance']:.2f} "
          f"vs even's {even['pressureBalance']:.2f}")


def test_attack_pairs_see_what_reached_cannot():
    """4/4 "reached" can still hide that only one neighbour ever came.

    At 2 teams `reached` and `attackPairs` say the same thing. At 4 they do
    not, and the difference is a board where every team can be attacked but
    only by one specific neighbour — a ring, not an arena.
    """
    ring = mp.pedestal_reach(evidence(4, [
        [0, 50, 0, 0],           # only team 1 ever attacks team 0
        [0, 0, 50, 0],           # only team 2 ever attacks team 1
        [0, 0, 0, 50],           # only team 3 ever attacks team 2
        [50, 0, 0, 0],           # only team 0 ever attacks team 3
    ]))
    check("ring: every objective approached", ring["reached"], 4)
    check("ring: no objective missed", ring["neverApproached"], [])
    check("ring: pressure balance is perfectly even",
          round(ring["pressureBalance"], 2), 1.00)
    # Everything above says the board is fair. This is the one that does not.
    check("ring: attack pairs realised", ring["attackPairs"], 4)
    check("ring: attack pairs possible", ring["possibleAttackPairs"], 12)
    check("ring: enemies per objective",
          [s["attackers"] for s in ring["seats"]], [1, 1, 1, 1])


def test_two_team_shape_still_works():
    """The 2-team case the harness already reported must not have moved."""
    got = mp.pedestal_reach(evidence(2, [[0, 12], [0, 0]]))
    check("2t: one of two reached", got["reached"], 1)
    check("2t: which one", got["neverApproached"], [1])
    check("2t: seat-ticks", got["ticks"], 12)
    check("2t: share of alive time", round(got["share"], 4), 0.0012)
    check("2t: pairs", (got["attackPairs"], got["possibleAttackPairs"]), (1, 2))


def test_baseline_kinds_are_not_interchangeable():
    """A reference point must never present itself as a control."""
    data = {"map": "gen:1020"}
    ref = mp.Baseline(data, "reference")
    ctrl = mp.Baseline({"map": "arena"}, "control")
    check("reference word", ref.word, "reference point")
    check("control word", ctrl.word, "control")
    check("control carries no caveat", ctrl.caveat, "")
    if "NOT a hand-authored control" not in ref.caveat:
        raise SystemExit("FAIL: a reference point's caveat must say so plainly")
    print("  ok  a reference point names itself as one")
    try:
        mp.Baseline(data, "hand-authored")
    except AssertionError:
        print("  ok  no third kind of baseline can be invented")
    else:
        raise SystemExit("FAIL: Baseline accepted an unknown kind")


def test_closest_run_home_merges_as_a_minimum_not_a_sum():
    """`carrierApproachPx` is a distance, and -1 is NOT a short one.

    The metric it replaced, `carrierInZoneTicks`, was a COUNT and merged by
    summing. Carrying that habit over would be wrong in two ways that both
    produce a plausible-looking number: three carry-less episodes would merge
    to -3 and read as a carrier PAST its own line, and a carry-less FIRST
    episode would win the minimum and mask a real run home in a later one.
    """
    def ep(approach, carry_ticks):
        return dict(map="m", gw=9, gh=9, ticks=100, occupancy=[0] * 81,
                    occTeam=[[0] * 81], deaths=[], carries=[], kills=[0],
                    carrierApproachPx=approach, carrierTicks=carry_ticks)

    mixed = mp.merge([ep(837, 865), ep(44, 300), ep(-1, 0)])
    check("closest of three episodes", mixed["carrierApproachPx"], 44)
    check("carry-ticks still SUM", mixed["carrierTicks"], 1165)

    none = mp.merge([ep(-1, 0), ep(-1, 0)])
    check("no carry anywhere stays -1", none["carrierApproachPx"], -1)
    check("...and never sums to -2", none["carrierTicks"], 0)

    late = mp.merge([ep(-1, 0), ep(120, 50)])
    check("a carry-less first episode cannot win the min",
          late["carrierApproachPx"], 120)


def test_zero_conversion_flag_separates_the_three_real_cases():
    """The whole point of the metric: this flag must say WHICH failure it was.

    It used to route the reader to `carrierInZoneTicks`, which is 0 on every
    episode ever measured — including both fixtures that CAPTURED — so its
    advice always resolved to "the objective was never reached" whatever the
    map did. The numbers below are the real fixture ones: gen-colossal-4team
    missed by 756px against a 364px ring, draw-nokill by 837px against a 70px
    ring, and both must read as the same VERDICT despite a 4x board size gap.
    """
    def flag_for(approach, ring, carry_ticks=865, steals=2):
        return mp.zero_conversion_flag(dict(
            steals=steals, captures=0, flagRing=ring,
            carrierApproachPx=approach, carrierTicks=carry_ticks))

    doorstep = flag_for(42, 70)
    for want in ("DOORSTEP", "42px", "RULES or BOT"):
        if want not in doorstep:
            raise SystemExit(f"FAIL: want {want!r} in doorstep: {doorstep}")
    print("  ok  inside the ring reads DIED ON THE DOORSTEP, not a map fault")

    far = flag_for(756, 364, carry_ticks=5346)
    for want in ("NEVER GOT CLOSE", "2.1x", "run home is where this map loses"):
        if want not in far:
            raise SystemExit(f"FAIL: want {want!r} in far miss: {far}")
    print("  ok  outside the ring reads NEVER GOT CLOSE, and IS a map verdict")

    # The verdict is a ring MULTIPLE, so the small board's 837px and the big
    # board's 756px land on opposite sides of nothing — both are far — but the
    # multiple reported differs by the ring, not by the raw px.
    if "12.0x" not in flag_for(837, 70):
        raise SystemExit("FAIL: the ring multiple must track the ring")
    print("  ok  the verdict scales to the ring, not to a px threshold")
    # Same px, bigger ring: a near miss on a big board must not read as a rout.
    if "DOORSTEP" not in flag_for(300, 364):
        raise SystemExit("FAIL: 300px inside a 364px ring is a doorstep")
    print("  ok  ...so 300px is a doorstep on the board whose ring is 364px")

    none = flag_for(-1, 70, carry_ticks=0)
    if "ever became a live carry" not in none:
        raise SystemExit(f"FAIL: -1 is not a distance: {none}")
    if "0px" in none or "-1" in none:
        raise SystemExit(f"FAIL: 'nobody carried' printed a distance: {none}")
    print("  ok  no carry at all is a FIGHT question, never 0px from scoring")


if __name__ == "__main__":
    for fn in (test_unapproached_pedestal_is_visible_per_seat,
               test_attack_pairs_see_what_reached_cannot,
               test_two_team_shape_still_works,
               test_closest_run_home_merges_as_a_minimum_not_a_sum,
               test_zero_conversion_flag_separates_the_three_real_cases,
               test_baseline_kinds_are_not_interchangeable):
        print(fn.__name__)
        fn()
    print("\nall map_playtest measure tests passed")
