"""collect_touch_ab — pull the v30 touch-latch hosted A/B and score it on
the MECHANISM metrics, not the bare win count.

The A/B: Picasso:v30 (touchCommit ON) vs Picasso:v29 (control) against named
opponents, both seat parities, fired as experience-requests by an orchestrator
that appends cells to a state file over time. A ~100-episode arm's win delta
sits at the noise floor, so the verdict rides on touch_metrics (approach ->
conversion -> steals/caps, the standoff ring, close shots) pooled per arm.

Pipeline per xreq cell (every stage caches; re-runs are nearly free):
  1. GET /v2/experience-requests/{id} — carries per-episode participants,
     scores AND replay_url directly (no /episodes sub-endpoint needed).
  2. completed episodes: download replay (public S3, no auth)
     -> ~/.ctf/scout/xreq_replays/<episode_id>.replay
  3. extract with the scout extractor (tier-2 sink)
     -> ~/.ctf/scout/xreq_events/<episode_id>.jsonl
  4. touch_metrics per episode; aggregate per arm/opponent/seat.

Attribution: the arm comes from which Picasso pv sits in the episode's OWN
participants list (a78277b6… = touchON/v30, dbfcd90e… = control/v29) — the
state file's arm/parity fields are cross-checked but NEVER trusted over the
participants. Our team comes from the extraction summary's slot_team at our
participant positions (the replay's own roster, never an assumed mapping).

GV note: xreq episodes record on the LIVE engine (GV27 as of 2026-07-30);
the extractor must match or every extraction fails hash validation. The
report names the extractor GV and any skipped-by-GV counts so a silent
engine bump reads as a diagnosis, not a mystery.

Run (read-only API use; the venv holds the login):
  PYTHONPATH=/Users/maxwellstarr/projects/coworld-ctf/tools/ladder \
    ~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python \
    tools/ladder/collect_touch_ab.py [--limit N] [--workers 6]
"""
import argparse
import collections
import concurrent.futures as futures
import datetime
import json
import os
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ctfapi  # noqa: E402
import touch_metrics as tmx  # noqa: E402

STATE = "/private/tmp/ctf-v30-touch/tools/ladder/touch_ab_xreqs.json"
REPORT = "/private/tmp/ctf-v30-touch/tools/ladder/touch_ab_report.md"
REPLAY_DIR = os.path.expanduser("~/.ctf/scout/xreq_replays")
EVENT_DIR = os.path.expanduser("~/.ctf/scout/xreq_events")
EXTRACT_BIN = os.environ.get(
    "CTF_SCOUT_BIN",
    os.path.expanduser("~/projects/coworld-ctf-scout/bin/extract_events"),
)

# Our two arms, by policy_version_id in the episode's participants list.
OUR_PVS = {
    "a78277b6-7e0e-488e-9fed-c6b46129687b": ("touchON", "Picasso:v30"),
    "dbfcd90e-1c54-45d3-9540-9500676a9f4c": ("control", "Picasso:v29"),
}


def extractor_gv():
    d = os.path.dirname(os.path.dirname(EXTRACT_BIN))
    try:
        with open(f"{d}/src/ctf/sim.nim") as f:
            for line in f:
                if "GameVersion* =" in line:
                    return line.split('"')[1]
    except OSError:
        pass
    return None


def replay_game_version(path):
    """GV from the replay header (magic|fmt|"ctf"|len|version) — cheap, so a
    mismatch reads as 'engine moved' up front, not as N extraction failures."""
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return None
    i = head.find(b"ctf")
    if i < 0 or i + 4 > len(head):
        return None
    n = head[i + 3]
    return head[i + 5:i + 5 + n].decode("ascii", "replace") or None


def fetch_episode(ep, our_gv, notes):
    """Download + extract one completed episode. Returns event path or None."""
    eid = ep["episode_id"]
    out = f"{EVENT_DIR}/{eid}.jsonl"
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return out
    url = ep.get("replay_url")
    if not url:
        notes["no_replay_url"] += 1
        return None
    src = f"{REPLAY_DIR}/{eid}.replay"
    if not (os.path.exists(src) and os.path.getsize(src) > 0):
        try:
            with urllib.request.urlopen(url, timeout=90) as r:
                data = r.read()
            with open(src + ".part", "wb") as f:
                f.write(data)
            os.replace(src + ".part", src)
        except Exception as e:  # noqa: BLE001 — one dead URL must not kill the run
            notes["download_failed"] += 1
            print(f"  download failed {eid[:8]}: {e}", file=sys.stderr)
            return None
    gv = replay_game_version(src)
    if gv and our_gv and gv != our_gv:
        notes[f"gv_mismatch_{gv}"] += 1
        return None
    r = subprocess.run([EXTRACT_BIN, src, "--out", out],
                       capture_output=True, text=True)
    if r.returncode != 0:
        msg = (r.stderr or "").strip().splitlines()
        notes["extract_failed"] += 1
        print(f"  extract failed {eid[:8]}: "
              f"{msg[-1] if msg else 'rc=' + str(r.returncode)}", file=sys.stderr)
        if os.path.exists(out):
            os.remove(out)
        return None
    return out


def episode_attribution(ep):
    """(arm, our_positions, opp_label) from the episode's participants list,
    or (None, reason, None)."""
    parts = ep.get("participants") or []
    ours = collections.defaultdict(list)
    opp = collections.Counter()
    for p in parts:
        pv = p.get("policy_version_id")
        if pv in OUR_PVS:
            ours[pv].append(p["position"])
        else:
            opp[f"{p.get('policy_name')}:v{p.get('version')}"] += 1
    if len(ours) != 1:
        return None, f"{len(ours)} of our pvs present", None
    pv, positions = next(iter(ours.items()))
    label = opp.most_common(1)[0][0] if opp else "?"
    return OUR_PVS[pv][0], sorted(positions), label


def score_win(ep, arm_pv):
    for s in ep.get("scores") or []:
        if s.get("policy_version_id") == arm_pv:
            return s.get("score")
    return None


class Cell:
    """One (xreq) cell's tallies."""

    def __init__(self, xid, arm, opp, parity):
        self.xid = xid
        self.arm = arm
        self.opp = opp
        self.parity = parity
        self.status = "?"
        self.completed = 0
        self.total = 0
        self.extracted = 0
        self.seats = collections.Counter()   # our actual team per episode
        self.ours = tmx.SideMetrics()
        self.theirs = tmx.SideMetrics()
        self.gvs = collections.Counter()
        self.notes = collections.Counter()
        self.mismatch_arm = 0        # participants disagree with state arm
        self.mismatch_score = 0      # re-sim winner disagrees with API score


def collect_cell(spec, our_gv, limit, workers):
    cell = Cell(spec["id"], spec["arm"], spec.get("opp", "?"),
                spec.get("parity"))
    try:
        req = ctfapi.get(f"/v2/experience-requests/{cell.xid}")
    except Exception as e:  # noqa: BLE001 — a dead xreq must not kill the sweep
        cell.status = f"FETCH FAILED: {e}"
        return cell
    cell.status = req.get("status")
    eps = req.get("episodes") or []
    cell.total = len(eps)
    done = [e for e in eps if e.get("status") == "completed"
            and e.get("episode_id")]
    cell.completed = len(done)
    if limit:
        done = done[:limit]

    with futures.ThreadPoolExecutor(max_workers=workers) as pool:
        paths = list(pool.map(
            lambda e: fetch_episode(e, our_gv, cell.notes), done))

    for ep, path in zip(done, paths):
        if not path:
            continue
        arm, positions, opp = episode_attribution(ep)
        if arm is None:
            cell.notes["bad_attribution"] += 1
            continue
        if arm != cell.arm:
            cell.mismatch_arm += 1  # trust participants over the state file
        events, summary = tmx.load_jsonl(path)
        if not summary:
            cell.notes["no_summary"] += 1
            continue
        teams = summary.get("slot_team") or []
        # An empty team string is a seat that never joined (short-handed
        # episode) — real and worth counting, not a parse failure. Derive our
        # team from the seats that DID fill; only bail on a true mix.
        my_teams = {teams[i] for i in positions if i < len(teams) and teams[i]}
        if len(my_teams) != 1:
            cell.notes["mixed_seats"] += 1
            continue
        if any(not t for t in teams):
            cell.notes["short_handed_eps"] += 1
        our_team = next(iter(my_teams))
        m = tmx.episode_metrics(path, our_team=our_team)
        if m[0] is None:
            cell.notes[f"metrics: {m[1]}"] += 1
            continue
        cell.extracted += 1
        cell.seats[our_team] += 1
        cell.gvs[summary.get("gameVersion")] += 1
        cell.ours.add(m[0])
        cell.theirs.add(m[1])
        # Cross-check the re-simulated winner against the API's own score.
        pv = next(k for k, v in OUR_PVS.items() if v[0] == arm)
        sc = score_win(ep, pv)
        if sc is not None and (sc == 1.0) != bool(m[0].wins):
            cell.mismatch_score += 1
    return cell


def rate(n, d):
    return n / d if d else 0.0


def pooled(cells, arm):
    ours, theirs, eps = tmx.SideMetrics(), tmx.SideMetrics(), 0
    for c in cells:
        if c.arm != arm:
            continue
        ours.add(c.ours)
        theirs.add(c.theirs)
        eps += c.extracted
    return ours, theirs, eps


def cell_row(c):
    o = c.ours
    seat = "/".join(f"{t}:{n}" for t, n in sorted(c.seats.items())) or "-"
    return (f"| {c.arm} | {c.opp} | {c.parity} | {seat} | {c.status} "
            f"| {c.extracted}/{c.completed}/{c.total} "
            f"| {o.wins} | {tmx.fmt_pct(o.winrate).strip()} "
            f"| {o.approach_eps} | {tmx.fmt_pct(o.conversion).strip()} "
            f"| {o.steals} | {o.captures} | {o.ring_deaths} "
            f"| {o.atk_ring_deaths} | {o.close_shots} |")


def side_block(title, ours, theirs, eps):
    lines = [f"**{title}** ({eps} episodes)", "",
             "| metric | ours | theirs |", "|---|---|---|"]
    for name, a, b in tmx.metric_rows(ours, theirs):
        lines.append(f"| {name} | {a} | {b} |")
    lines.append("")
    return lines


def delta_block(t_ours, t_eps, c_ours, c_eps):
    lines = ["## Pooled touchON vs control (our side)", "",
             f"touchON n={t_eps} episodes, control n={c_eps} episodes — "
             "counts are per-episode rates so unequal arms compare.", "",
             "| metric | touchON | control | delta |", "|---|---|---|---|"]

    def row(name, a, b, pct=False):
        if pct:
            lines.append(f"| {name} | {100*a:.1f}% | {100*b:.1f}% "
                         f"| {100*(a-b):+.1f}pp |")
        else:
            lines.append(f"| {name} | {a:.3f} | {b:.3f} | {a-b:+.3f} |")

    row("winrate", rate(t_ours.wins, t_eps), rate(c_ours.wins, c_eps), pct=True)
    row("approach rate (eps)", rate(t_ours.approach_eps, t_eps),
        rate(c_ours.approach_eps, c_eps), pct=True)
    row("touch conversion", t_ours.conversion, c_ours.conversion, pct=True)
    row("steals /ep", rate(t_ours.steals, t_eps), rate(c_ours.steals, c_eps))
    row("captures /ep", rate(t_ours.captures, t_eps),
        rate(c_ours.captures, c_eps))
    row("ring deaths /ep (baseline conv.)", rate(t_ours.ring_deaths, t_eps),
        rate(c_ours.ring_deaths, c_eps))
    row("atk ring deaths /ep (own)", rate(t_ours.atk_ring_deaths, t_eps),
        rate(c_ours.atk_ring_deaths, c_eps))
    row("close shots /ep (<60px)", rate(t_ours.close_shots, t_eps),
        rate(c_ours.close_shots, c_eps))
    lines.append("")
    return lines


def build_report(cells, our_gv):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = ["# v30 touch-latch A/B — collector report", "",
             f"Generated {now}. Extractor GV{our_gv}. State: {STATE}",
             f"Cells: {len(cells)}. Arms by episode-participants pv "
             "(a78277b6=touchON/v30, dbfcd90e=control/v29); the state file's "
             "arm/parity are cross-checked only.", ""]

    incomplete = [c for c in cells if c.status != "completed"]
    if incomplete:
        lines.append("**Incomplete xreqs** (numbers below are partial):")
        for c in incomplete:
            lines.append(f"- {c.xid} [{c.arm} vs {c.opp} p{c.parity}]: "
                         f"{c.status}, {c.completed}/{c.total} episodes done")
        lines.append("")

    lines += ["## Per-cell (arm / opponent / seating)", "",
              "eps = extracted/completed/requested; metrics are OUR side.", "",
              "| arm | opp | parity | seat | status | eps | W | wr | app "
              "| conv | stl | cap | ring | aring | cshot |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in sorted(cells, key=lambda c: (c.arm, c.opp, str(c.parity))):
        lines.append(cell_row(c))
    lines.append("")

    for arm in ("touchON", "control"):
        ours, theirs, eps = pooled(cells, arm)
        lines += side_block(f"Arm {arm}", ours, theirs, eps)

    t_ours, _, t_eps = pooled(cells, "touchON")
    c_ours, _, c_eps = pooled(cells, "control")
    lines += delta_block(t_ours, t_eps, c_ours, c_eps)

    quality = collections.Counter()
    for c in cells:
        quality.update(c.notes)
        if c.mismatch_arm:
            quality[f"arm mismatch vs state file ({c.xid[:13]})"] += c.mismatch_arm
        if c.mismatch_score:
            quality[f"re-sim winner != API score ({c.xid[:13]})"] += c.mismatch_score
    gvs = collections.Counter()
    for c in cells:
        gvs.update(c.gvs)
    lines.append("## Data quality")
    lines.append("")
    lines.append(f"- episode GameVersions: "
                 f"{dict(gvs) if gvs else 'none extracted'}")
    if quality:
        for k, v in quality.most_common():
            lines.append(f"- {k}: {v}")
    else:
        lines.append("- no anomalies")
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--limit", type=int,
                    help="cap completed episodes per xreq (smoke test)")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--report", default=REPORT)
    a = ap.parse_args()

    os.makedirs(REPLAY_DIR, exist_ok=True)
    os.makedirs(EVENT_DIR, exist_ok=True)
    if not os.path.exists(EXTRACT_BIN):
        sys.exit(f"extractor not found: {EXTRACT_BIN} (set CTF_SCOUT_BIN)")
    our_gv = extractor_gv()

    with open(STATE) as f:          # read fresh: the orchestrator appends
        specs = json.load(f)
    print(f"{len(specs)} A/B cells in state; extractor GV{our_gv}")

    cells = []
    for spec in specs:
        c = collect_cell(spec, our_gv, a.limit, a.workers)
        cells.append(c)
        print(f"  {c.xid[:18]} {c.arm:8} vs {c.opp:24} p{c.parity} "
              f"[{c.status}] extracted {c.extracted}/{c.completed}")

    report = build_report(cells, our_gv)
    print("\n" + report)
    os.makedirs(os.path.dirname(a.report), exist_ok=True)
    with open(a.report, "w") as f:
        f.write(report)
    print(f"report written: {a.report}")


if __name__ == "__main__":
    main()
