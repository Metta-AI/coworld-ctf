#!/usr/bin/env python3
"""Unit tests for starter_harness.layer_ladder's KEEP_WHEN_PLAYS opt-in
(W11, FOUR DIGITS lane v63, 2026-09-23/24 -- see the module-level
KEEP_WHEN_PLAYS comment in starter_harness.py).

The load-bearing property under test: `layer_ladder` stripping `when` from
every entry, and gating GATED_PLAYS members through `gate_open`'s send-time
snapshot, is a SHARED mechanism every starter persona goes through --
KEEP_WHEN_PLAYS is a mutable opt-in on that shared module, so a change here
must be PROVABLY A NO-OP for any play/persona that never touches it. Every
test below restores KEEP_WHEN_PLAYS to empty afterward (a module-global
mutable set, same footgun class as HOLD_VS_GUN_AGGRESSOR_GATE already
carries) so the no-op tests and the opt-in tests can never leak into each
other regardless of run order.

Run from anywhere: python3 policies/starters/common/test_starter_harness.py
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import starter_harness  # noqa: E402

# A view with no enemy tracks: gate_open("fire_superiority", ...) and
# gate_open("hold_vs_gun", ...) both read False from this (no `enemies`,
# no `aggressor_hot`) -- the control case that proves KEEP_WHEN_PLAYS, not
# an accidentally-open gate, is what keeps an entry on the wire below.
EMPTY_VIEW = {"tick": 100, "self": {"pos": [500, 500], "hp_frac": 1.0},
              "tracks": [], "items": [], "aggressors": []}
CONTEXT = {"self": {"seat": 3, "team": 0}}

FS_ENTRY_NO_WHEN = {"play": "fire_superiority", "entry_id": "pressbreak",
                    "params": {}}
FS_ENTRY_WITH_WHEN = {"play": "fire_superiority", "entry_id": "pressbreak",
                     "when": ["and",
                              [">=", ["get", "world.nearest_enemy_dist"], 0],
                              ["<=", ["get", "world.nearest_enemy_dist"], 750]],
                     "params": {}}

failures = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(("PASS  " if ok else "FAIL  ") + label +
          (f" -- {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


assert starter_harness.KEEP_WHEN_PLAYS == set(), (
    "KEEP_WHEN_PLAYS must start empty; a prior import already mutated it "
    f"before this test ran: {starter_harness.KEEP_WHEN_PLAYS!r}")

def fs_entries(out):
    return [e for e in out if e.get("play") == "fire_superiority"]


def hold_entries(out):
    return [e for e in out if e.get("play") == "hold_vs_gun"]


# ── 1. Default (KEEP_WHEN_PLAYS empty): `when` is stripped, gate_open's own
#      snapshot decides presence -- exactly pre-v63 behaviour. base_play
#      left at its "edge_ride" default (never touched by this lever) so the
#      assertions below can target fire_superiority/hold_vs_gun specifically
#      instead of tripping layer_ladder's own empty-ladder fallback. ───────
out = starter_harness.layer_ladder([FS_ENTRY_WITH_WHEN], EMPTY_VIEW, CONTEXT)
check("no-op: fire_superiority with `when`, KEEP_WHEN_PLAYS empty -> "
      "dropped by gate_open (no enemies) exactly like a `when`-less entry",
      fs_entries(out) == [], str(out))

out_no_when = starter_harness.layer_ladder([FS_ENTRY_NO_WHEN], EMPTY_VIEW, CONTEXT)
check("no-op: fire_superiority without `when`, KEEP_WHEN_PLAYS empty -> "
      "same drop (the control case this test is pinned against)",
      fs_entries(out_no_when) == [], str(out_no_when))

# A second GATED_PLAYS member never added to KEEP_WHEN_PLAYS must never be
# affected by fire_superiority's own future membership -- checked again
# after fire_superiority opts in, below.
HOLD_ENTRY_WITH_WHEN = {"play": "hold_vs_gun", "entry_id": "holdgun",
                        "when": ["get", "partner.alive"], "params": {}}

# ── 2. Opt-in: fire_superiority added to KEEP_WHEN_PLAYS -> `when` survives
#      the strip AND gate_open's snapshot is bypassed (present even though
#      the view has no enemy at all) ────────────────────────────────────────
starter_harness.KEEP_WHEN_PLAYS.add("fire_superiority")
try:
    out = starter_harness.layer_ladder([FS_ENTRY_WITH_WHEN], EMPTY_VIEW, CONTEXT)
    kept = fs_entries(out)
    check("opt-in: fire_superiority with `when` survives + bypasses "
          "gate_open (present with zero enemies in view)",
          len(kept) == 1 and kept[0].get("when") == FS_ENTRY_WITH_WHEN["when"],
          str(out))

    # Opting fire_superiority in must not change a `when`-less fire_
    # superiority entry's fate: KEEP_WHEN_PLAYS membership alone is not
    # enough, the entry itself must still carry a `when` to be kept.
    out2 = starter_harness.layer_ladder([FS_ENTRY_NO_WHEN], EMPTY_VIEW, CONTEXT)
    check("opt-in play, `when`-less entry: still dropped by gate_open "
          "(KEEP_WHEN_PLAYS bypass requires the entry to carry `when`)",
          fs_entries(out2) == [], str(out2))

    # A sibling GATED_PLAYS member never opted in stays on the OLD path
    # even while fire_superiority is opted in -- proves the opt-in is
    # scoped to the named play, not a blanket "trust every `when`" flip.
    out3 = starter_harness.layer_ladder([HOLD_ENTRY_WITH_WHEN], EMPTY_VIEW, CONTEXT)
    check("sibling GATED_PLAYS member (hold_vs_gun, not opted in) still "
          "loses `when` and still goes through gate_open while "
          "fire_superiority is opted in",
          hold_entries(out3) == [], str(out3))
finally:
    starter_harness.KEEP_WHEN_PLAYS.discard("fire_superiority")

# ── 3. Restored to empty: byte-identical to test 1 again (no leakage) ─────
out = starter_harness.layer_ladder([FS_ENTRY_WITH_WHEN], EMPTY_VIEW, CONTEXT)
check("restore: KEEP_WHEN_PLAYS back to empty -> byte-identical to the "
      "pre-opt-in no-op case", fs_entries(out) == [], str(out))
check("restore: KEEP_WHEN_PLAYS is empty again", starter_harness.KEEP_WHEN_PLAYS == set(),
      str(starter_harness.KEEP_WHEN_PLAYS))

# ── 4. build_call's own `when` passthrough (the SECOND strip point: even
#      an entry that survives layer_ladder's KEEP_WHEN_PLAYS bypass was,
#      pre-v63, silently dropped one step later by build_call's entry
#      reconstruction -- "`when` is deliberately NOT forwarded" was a
#      real, separate, documented decision in that function, not an
#      oversight in layer_ladder). Same no-op-by-default / opt-in-only
#      contract, proven the same way. ──────────────────────────────────
AVAILABLE = ["fire_superiority", "hold_vs_gun", "target_law"]

out = starter_harness.build_call(
    {"call": {"entries": [FS_ENTRY_WITH_WHEN]}}, AVAILABLE)[1]
check("no-op: build_call drops `when` from fire_superiority, "
      "KEEP_WHEN_PLAYS empty (pre-v63 behaviour, unchanged by default)",
      "when" not in out[0], str(out))

starter_harness.KEEP_WHEN_PLAYS.add("fire_superiority")
try:
    out = starter_harness.build_call(
        {"call": {"entries": [FS_ENTRY_WITH_WHEN]}}, AVAILABLE)[1]
    check("opt-in: build_call forwards `when` for a play in "
          "KEEP_WHEN_PLAYS whose entry carries one",
          out[0].get("when") == FS_ENTRY_WITH_WHEN["when"], str(out))

    out2 = starter_harness.build_call(
        {"call": {"entries": [HOLD_ENTRY_WITH_WHEN]}}, AVAILABLE)[1]
    check("sibling GATED_PLAYS member (hold_vs_gun, not opted in) still "
          "has `when` dropped by build_call while fire_superiority is "
          "opted in",
          "when" not in out2[0], str(out2))
finally:
    starter_harness.KEEP_WHEN_PLAYS.discard("fire_superiority")

out = starter_harness.build_call(
    {"call": {"entries": [FS_ENTRY_WITH_WHEN]}}, AVAILABLE)[1]
check("restore: build_call back to dropping `when` (no leakage)",
      "when" not in out[0], str(out))

if failures:
    print(f"\n{len(failures)} FAILURE(S): " + "; ".join(failures))
    sys.exit(1)
print("\ntest_starter_harness: all assertions passed")
