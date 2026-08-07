"""touch_metrics — the TOUCH-GAP mechanism metrics, from re-simulated events.

The v30 lever is the touch: we reach the enemy heart as often as the field but
convert the touch to a steal far less (71.8% vs 94.9% on the GV26 baseline).
A hosted A/B win count alone sits at the noise floor (~±10 wins), so the A/B
is judged on THESE mechanism metrics, computed from extract_events JSONL files
(the tier-2 sink: one JSON row per SimEvent plus a final summary row carrying
the roster, so attribution never assumes a slot mapping).

CALIBRATION CONTRACT (do not "fix" without re-baselining): every constant and
convention below is pinned to the 2026-07-29 diagnosis that produced the
documented GV26 baseline (71 vs 79 approach eps, 71.8%/94.9% conversion,
445 vs 90 ring deaths, 41 close shots, 70/128 steals, 15/26 captures, 53/123
wins) — reproduced EXACTLY by this module over the 123-episode GV26 cache.
Two conventions matter and are intentional:

1. Events are attributed to the SOURCE slot's side and measured against the
   pedestal that side ATTACKS. For shot/flag_steal the x,y IS the source's
   body position; for damage/kill the x,y is the VICTIM's position (verified
   against sim.nim emit sites) while source is the ATTACKER. So `approach`
   really measures "body presence OR delivered fire inside 40px of the
   attacked heart", and `ring_deaths` counts KILLS SCORED BY the side on
   bodies 60-260px from the heart it attacks (mostly that heart's defenders).
   The plan doc narrates ring_deaths as attacker deaths; the literal
   attacker-victim count is exposed separately as `atk_ring_deaths`
   (baseline would have been 488 ours vs 191 theirs — same story, different
   convention; it is NOT part of the documented baseline).
2. Pedestals use the diagnosis constants (185,329)/(1050,329), 1px off the
   true flagHome() values (186,329)/(1049,329), kept so every number stays
   comparable to the documented baseline (the 41-close-shots figure moves to
   42 on the true coordinates).

Other schema truths honored here: hp == 0 means "never read", not zero
health; Heal records the HEALED player in `source`; shot_impact /
grenade_impact x,y are LANDING points and are never used as positions;
heading_brads exists only on GV26+ extractions.

Usage (module):
    from touch_metrics import tally, episode_metrics
    ours, theirs, used, skipped = tally(paths, our_player="softmaxwell")
    # or, when the caller already knows our seat per file:
    tally(paths, our_team_of={path: "red", ...})

Usage (CLI):
    touch_metrics.py [files...] [--player softmaxwell] [--gv 26]
    # no files -> the whole cached league corpus ~/.ctf/scout/events/*.jsonl
"""
import argparse
import dataclasses
import glob
import json
import math
import os

# Diagnosis pedestal constants (see CALIBRATION CONTRACT note 2). The league
# runs the default arena, 1235x659, hearts on the horizontal midline.
HEARTS = {"red": (185.0, 329.0), "blue": (1050.0, 329.0)}
ENEMY = {"red": "blue", "blue": "red"}

APPROACH_PX = 40.0    # "reached the heart" (pickup radius itself is 12px)
RING_LO = 60.0        # the standoff ring: GrabCommitRing=60 out to the
RING_HI = 260.0       # cover ring the diagnosis measured deaths in
CLOSE_SHOT_PX = 60.0  # a shot fired INSIDE the pocket

# The diagnosis event set: kinds whose x,y is attributed to the SOURCE's side
# (see CALIBRATION CONTRACT note 1 for what that actually measures).
APPROACH_KINDS = ("shot", "damage", "kill", "flag_steal")


@dataclasses.dataclass
class SideMetrics:
    """Touch-gap tallies for ONE side over a set of episodes."""
    eps: int = 0
    wins: int = 0
    approach_eps: int = 0     # eps with an approach <40px of the attacked heart
    steal_eps: int = 0        # approach eps that produced a steal
    steals: int = 0
    captures: int = 0
    ring_deaths: int = 0      # baseline convention: kills BY this side, victim
                              # 60-260px from the heart this side attacks
    atk_ring_deaths: int = 0  # literal convention: this side's OWN deaths
                              # 60-260px from the heart it attacks
    close_shots: int = 0      # this side's shots fired <60px from that heart

    @property
    def winrate(self):
        return self.wins / self.eps if self.eps else 0.0

    @property
    def conversion(self):
        return self.steal_eps / self.approach_eps if self.approach_eps else 0.0

    def add(self, other):
        for f in dataclasses.fields(self):
            setattr(self, f.name, getattr(self, f.name) + getattr(other, f.name))


def load_jsonl(path):
    """(events, summary) from one extraction; summary None if truncated."""
    events, summary = [], None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("type") == "summary":
                summary = row
            else:
                events.append(row)
    return events, summary


def sides_of(summary, our_player=None, our_team=None):
    """slot -> "ours"/"theirs" plus our team, from the summary's own roster.

    Hosted replays record the league player name as "<player>" and
    "<player> (2)".."(8)"; team comes from slot_team. Pass our_team to skip
    name matching (the A/B collector maps seats from the API's participants
    list). Returns (side_of, our_team) or (None, reason).
    """
    addr = summary.get("slot_address") or []
    teams = summary.get("slot_team") or []
    if not addr or not teams:
        return None, "no roster in summary"
    if our_team is None:
        mine = {teams[i] for i, a in enumerate(addr)
                if a.split(" (")[0] == our_player}
        if len(mine) != 1:
            return None, f"player {our_player!r} on {len(mine)} teams"
        our_team = next(iter(mine))
    if our_team not in HEARTS:
        return None, f"unknown team {our_team!r}"
    side_of = {i: ("ours" if teams[i] == our_team else "theirs")
               for i in range(len(teams)) if teams[i] in HEARTS}
    return side_of, our_team


def episode_metrics(path, our_player=None, our_team=None):
    """(ours, theirs) SideMetrics for one episode, or (None, reason)."""
    events, summary = load_jsonl(path)
    if summary is None:
        return None, "no summary row (truncated extraction?)"
    side_of, our_team = sides_of(summary, our_player, our_team)
    if side_of is None:
        return None, our_team
    team_of_side = {"ours": our_team, "theirs": ENEMY[our_team]}
    # The heart each side ATTACKS is the opposing team's pedestal.
    attacked = {s: HEARTS[ENEMY[t]] for s, t in team_of_side.items()}

    out = {"ours": SideMetrics(eps=1), "theirs": SideMetrics(eps=1)}
    winner = summary.get("winner")
    for s, t in team_of_side.items():
        out[s].wins = int(winner == t)

    approached = {"ours": False, "theirs": False}
    stole = {"ours": False, "theirs": False}
    for ev in events:
        kind = ev["kind"]
        side = side_of.get(ev["source"])
        if side is None:
            continue
        hx, hy = attacked[side]
        d = math.hypot(ev["x"] - hx, ev["y"] - hy)
        if kind in APPROACH_KINDS and d < APPROACH_PX:
            approached[side] = True
        if kind == "flag_steal":
            out[side].steals += 1
            stole[side] = True
        elif kind == "capture":
            out[side].captures += 1
        elif kind == "kill":
            # Baseline ring convention: credited to the KILLER's side, victim
            # position vs the heart the KILLER attacks (contract note 1)...
            if RING_LO <= d <= RING_HI:
                out[side].ring_deaths += 1
            # ...and the literal one: the VICTIM's own death in the ring
            # around the heart the VICTIM was attacking.
            vic = side_of.get(ev["target"])
            if vic is not None:
                vx, vy = attacked[vic]
                if RING_LO <= math.hypot(ev["x"] - vx, ev["y"] - vy) <= RING_HI:
                    out[vic].atk_ring_deaths += 1
        elif kind == "shot" and d < CLOSE_SHOT_PX:
            out[side].close_shots += 1
    for s in out:
        out[s].approach_eps = int(approached[s])
        out[s].steal_eps = int(approached[s] and stole[s])
    return out["ours"], out["theirs"]


def tally(paths, our_player=None, our_team_of=None):
    """Aggregate over many episodes.

    our_team_of: optional dict/callable path -> "red"/"blue" for episodes
    where the caller already knows our seat (the A/B collector); otherwise
    the roster name match on our_player decides. Returns (ours, theirs,
    used_paths, skipped) where skipped is [(path, reason)].
    """
    ours, theirs = SideMetrics(), SideMetrics()
    used, skipped = [], []
    for p in paths:
        team = None
        if our_team_of is not None:
            team = our_team_of(p) if callable(our_team_of) else our_team_of.get(p)
        m = episode_metrics(p, our_player=our_player, our_team=team)
        if m[0] is None:
            skipped.append((p, m[1]))
            continue
        ours.add(m[0])
        theirs.add(m[1])
        used.append(p)
    return ours, theirs, used, skipped


def game_version(path):
    """The extractor GameVersion of one JSONL (from its summary row)."""
    _, summary = load_jsonl(path)
    return (summary or {}).get("gameVersion")


def corpus_paths(gv=None, event_dir=None):
    """Cached league corpus, optionally filtered to one GameVersion.

    The summary's gameVersion is baked at extraction time and always equals
    the replay's recorded GV (extraction hash-fails on a mismatch), so this
    filter is safe even though the cache now mixes GV23/24/26/27 entries.
    """
    event_dir = event_dir or os.path.expanduser("~/.ctf/scout/events")
    paths = sorted(glob.glob(f"{event_dir}/*.jsonl"))
    if gv is None:
        return paths
    return [p for p in paths if game_version(p) == str(gv)]


def fmt_pct(x):
    return f"{100.0 * x:5.1f}%"


def metric_rows(ours, theirs):
    """[(name, ours, theirs)] — shared by the CLI and the A/B report."""
    return [
        ("episodes", ours.eps, theirs.eps),
        ("wins", ours.wins, theirs.wins),
        ("winrate", fmt_pct(ours.winrate), fmt_pct(theirs.winrate)),
        (f"approach eps (<{APPROACH_PX:.0f}px)", ours.approach_eps,
         theirs.approach_eps),
        ("steal eps (of approaches)", ours.steal_eps, theirs.steal_eps),
        ("touch conversion", fmt_pct(ours.conversion),
         fmt_pct(theirs.conversion)),
        ("steals", ours.steals, theirs.steals),
        ("captures", ours.captures, theirs.captures),
        (f"ring deaths {RING_LO:.0f}-{RING_HI:.0f}px (baseline conv.)",
         ours.ring_deaths, theirs.ring_deaths),
        ("atk ring deaths (own, literal)", ours.atk_ring_deaths,
         theirs.atk_ring_deaths),
        (f"shots <{CLOSE_SHOT_PX:.0f}px of heart", ours.close_shots,
         theirs.close_shots),
    ]


def report(ours, theirs, used, skipped, label="ours"):
    lines = []
    w = lines.append
    w(f"touch metrics over {len(used)} episodes "
      f"({len(skipped)} skipped)" + (":" if used else " — nothing to report"))
    if used:
        w(f"  {'metric':38} {label:>10} {'theirs':>10}")
        for name, a, b in metric_rows(ours, theirs):
            w(f"  {name:38} {a!s:>10} {b!s:>10}")
    for p, why in skipped[:8]:
        w(f"  skipped {os.path.basename(p)}: {why}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description="touch-gap mechanism metrics from event JSONLs")
    ap.add_argument("files", nargs="*",
                    help="event .jsonl files (default: cached league corpus)")
    ap.add_argument("--player", default="softmaxwell",
                    help="whose slots are 'ours' (roster name match)")
    ap.add_argument("--gv", default="26",
                    help="restrict to this GameVersion; 'any' disables "
                         "(the documented baseline is the GV26 subset)")
    a = ap.parse_args()

    paths = a.files or corpus_paths()
    if a.gv != "any":
        paths = [p for p in paths if game_version(p) == a.gv]
    ours, theirs, used, skipped = tally(paths, our_player=a.player)
    print(report(ours, theirs, used, skipped, label=a.player[:10]))


if __name__ == "__main__":
    main()
