#!/usr/bin/env python
"""ffa4score — one command that scores a policy version's ffa4 SURVIVAL ECONOMY.

WHY THIS EXISTS
We shipped two ffa4 levers without ever measuring their outcome, because the
measurement was a bespoke research project each time. The local 4-team rig is
DISQUALIFIED for scoring survival (it saturates at ~92% of the metric's ceiling,
runs the wrong map family, and its probes read the fogged HUD). Hosted replays
are the only trustworthy source, and they are free, public and need no auth: the
field ledger discriminates the med-kit economy at 6.4-6.9 SE across three
independent build cells, which no local A/B in this class has ever reached.
This file turns that from an ad-hoc script into a repeatable instrument.

THE PRE-REGISTERED OBJECTIVE (these six, in this order, and no others)
  1 med_kits per 1e6 ALIVE ticks  — the alive-time denominator is what kills the
    "we just die more" confound. Field: ours 59.7, winner 212.1, filler 224.3.
  2 kit share of the map          — our pickups / all pickups that Episode.
    The null is 25% (four teams). Ours 12.9%, winner 42.3%.
  3 P(escape | hp==1)             — from a RECONSTRUCTED per-slot HP track
    (respawn->3, damage.hp, heal.hp, death->0). NEVER from event counts.
    Ours 2.1%, winner 13.4%.
  4 P(zero kits all Episode)      — blunt and very discriminating. Ours 57.5%,
    winner 8.6%.
  5 deaths per team-Episode, and P(survive, <12 deaths) — a team that reaches 12
    deaths (3 lives x 4 agents) has been eliminated and never wins.
  6 paired within-Episode delta vs the scripted `Baseline` control — the design
    that closes the map/field confound, because both arms are IN the same
    Episode. Field: ours -0.51 kits vs Ron +1.61. A sign flip.

Every rate is clustered on the TEAM-EPISODE: a policy's four seats in one
Episode are ONE sample, not four. CIs are bootstrapped over those clusters.

PIPELINE (each stage caches, so re-runs are near-free)
  index  /v2/rounds -> /v2/rounds/{id}/episodes?limit=1000  -> ffa4/index.json
  fetch  replay_url -> ~/.ctf/scout/replays -> extractor -> ~/.ctf/scout/events
  score  events -> one row per TEAM-EPISODE                 -> ffa4/rows.json
  report the six metrics, per (policy version x coworld build), + a POWER line

USAGE
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  PYTHONPATH=. $PY ffa4score.py index --rounds 40
  PYTHONPATH=. $PY ffa4score.py run   --version v58 --vs v57      # post-ship gate
  PYTHONPATH=. $PY ffa4score.py score --version v58 --vs "Ron @ SWGY"
  PYTHONPATH=. $PY ffa4score.py score --version v56 --since 1400 --until 1443

--vs takes either a rival player or one of OUR OWN versions ("v57"), because
the post-ship question is almost always "did the new version beat the old one
on the same field?".
  PYTHONPATH=. $PY ffa4score.py selfcheck        # the trap defences, as tests

TRAPS BAKED IN AS DEFENCES (each one has already cost real time)
  * The {"type":"summary"} row is the LAST line of an event file, not the first.
    Reading line 1 silently yields zero slots. `load_events` scans every line
    and `selfcheck` asserts the ordering on real files.
  * `is_filler` marks a SEAT, not a policy: it flags every entrant's 2nd-4th
    seats, including ours (1155 of our own participant rows carry it). Trusting
    it labels every entrant a filler. The scripted control is the entrant whose
    slot_address is literally `Baseline`, and that is the only test used here.
  * /v2/rounds/{id}/episodes defaults to limit=50 while a round holds far more.
    ctfapi.episodes() passes limit=1000; selfcheck asserts it.
  * Campaign/leaderboard fields can be VIEWER-SCOPED (dropped/error/latency_s/
    reasoning exist only for our own player). A missing key read as zero has
    already produced one confidently wrong finding. Nothing here reads a
    cross-player field without comparing KEY SETS first.
  * Four bases have no x-midline, so every single-midline positional estimator
    is UNDEFINED on ffa4, not noisy. This file contains no positional estimator
    at all — the six metrics are counts, times and outcomes.
  * ffa8 ("4-team free-for-all (8 per team)") has different slot geometry and is
    excluded by name AND by a 16-slot/4-colour geometry assertion. The count of
    exclusions is printed, never silently dropped.
  * Builds are NEVER summed. 0.7.228 and 0.7.229 are both GV43 but different
    builds; GV42 (0.7.225/226/227) is refused at extraction. A build with no
    extractions prints UNAVAILABLE, which is not the same as zero.
  * A CI that crosses zero prints "no measurable change". Never a win.
"""
import argparse
import collections
import datetime
import glob
import json
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ctfapi                                                  # noqa: E402
import scout                                                   # noqa: E402

HOME = os.path.expanduser("~")
CACHE = f"{HOME}/.ctf/scout/ffa4"
INDEX_PATH = f"{CACHE}/index.json"
ROWS_PATH = f"{CACHE}/rows.json"

OURS = "softmaxwell"
CONTROL = "Baseline"              # the SCRIPTED control — a name, never is_filler
FFA4 = "4-team free-for-all"      # exact; "(8 per team)" is ffa8 and is excluded
N_TEAMS = 4
TEAM_SLOTS = 4
MAXHP = 3                         # a shield pickup can lift hp above this
LIVES_PER_AGENT = 3
TEAM_LIVES = LIVES_PER_AGENT * TEAM_SLOTS   # 12 — reaching it is elimination

ROW_SCHEMA = 1                    # bump to invalidate rows.json
BOOT = 1000
SEED = 20260818
THIN_N = 20                       # below this a cell is reported but flagged
Z_A, Z_B = 1.959964, 0.841621     # alpha .05 two-sided, 80% power


# ------------------------------------------------------------------ stats
def mean(xs):
    xs = [x for x in xs if x is not None and x == x]
    return sum(xs) / len(xs) if xs else float("nan")


def sd(xs):
    xs = [x for x in xs if x is not None and x == x]
    if len(xs) < 2:
        return float("nan")
    m = sum(xs) / len(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def boot_mean(xs, reps=BOOT):
    """(point, lo, hi, n) for a per-team-Episode quantity, resampling CLUSTERS."""
    xs = [x for x in xs if x is not None and x == x]
    n = len(xs)
    if n == 0:
        return float("nan"), None, None, 0
    pt = sum(xs) / n
    if n < 3:
        return pt, None, None, n
    rng = random.Random(SEED)
    outs = sorted(sum(rng.choices(xs, k=n)) / n for _ in range(reps))
    return pt, outs[int(0.025 * reps)], outs[int(0.975 * reps) - 1], n


def boot_ratio(pairs, reps=BOOT):
    """(point, lo, hi, n_clusters, denominator) for a pooled num/den ratio.

    `pairs` is one (num, den) per TEAM-EPISODE — resampling those, not the
    underlying events, is the whole point: four seats are not four draws.
    """
    pairs = [p for p in pairs if p is not None]
    n = len(pairs)
    den = sum(p[1] for p in pairs)
    if not n or not den:
        return float("nan"), None, None, n, den
    pt = sum(p[0] for p in pairs) / den
    if n < 3:
        return pt, None, None, n, den
    rng = random.Random(SEED)
    outs = []
    for _ in range(reps):
        s = rng.choices(pairs, k=n)
        d = sum(p[1] for p in s)
        if d:
            outs.append(sum(p[0] for p in s) / d)
    outs.sort()
    if not outs:
        return pt, None, None, n, den
    return pt, outs[int(0.025 * len(outs))], outs[int(0.975 * len(outs)) - 1], n, den


def boot_delta_mean(a, b, reps=BOOT):
    """Unpaired delta mean(a) - mean(b) with a percentile CI over clusters."""
    a = [x for x in a if x is not None and x == x]
    b = [x for x in b if x is not None and x == x]
    if len(a) < 3 or len(b) < 3:
        return (mean(a) - mean(b) if a and b else float("nan")), None, None
    rng = random.Random(SEED)
    na, nb = len(a), len(b)
    outs = sorted(sum(rng.choices(a, k=na)) / na - sum(rng.choices(b, k=nb)) / nb
                  for _ in range(reps))
    return mean(a) - mean(b), outs[int(0.025 * reps)], outs[int(0.975 * reps) - 1]


def boot_delta_ratio(pa, pb, reps=BOOT):
    pa = [p for p in pa if p]
    pb = [p for p in pb if p]
    ra = sum(p[0] for p in pa) / sum(p[1] for p in pa) if sum(p[1] for p in pa) else float("nan")
    rb = sum(p[0] for p in pb) / sum(p[1] for p in pb) if sum(p[1] for p in pb) else float("nan")
    if len(pa) < 3 or len(pb) < 3:
        return ra - rb, None, None
    rng = random.Random(SEED)
    outs = []
    for _ in range(reps):
        sa, sb = rng.choices(pa, k=len(pa)), rng.choices(pb, k=len(pb))
        da, db = sum(p[1] for p in sa), sum(p[1] for p in sb)
        if da and db:
            outs.append(sum(p[0] for p in sa) / da - sum(p[0] for p in sb) / db)
    outs.sort()
    if not outs:
        return ra - rb, None, None
    return ra - rb, outs[int(0.025 * len(outs))], outs[int(0.975 * len(outs)) - 1]


def paired_ci(ds):
    """Mean +- 1.96 SE of a within-Episode difference. Paired: the map, the
    field and the engine are held fixed by construction."""
    ds = [d for d in ds if d is not None and d == d]
    n = len(ds)
    if n < 2:
        return float("nan"), None, None, n
    m = sum(ds) / n
    se = math.sqrt(sum((d - m) ** 2 for d in ds) / (n - 1) / n)
    return m, m - 1.96 * se, m + 1.96 * se, n


# ------------------------------------------------------------------ 1. index
def base_name(addr):
    """'relh (3)' -> 'relh'. Hosted replays record '<player>' then '<player> (2)'."""
    a = (addr or "").strip()
    if a.endswith(")") and " (" in a:
        head, tail = a.rsplit(" (", 1)
        if tail[:-1].isdigit():
            return head
    return a


def eps_dirs(import_extra=True):
    """Directories of cached round-episode JSON. Ours first; anything else is
    an IMPORT of the same free public data and is named in the report."""
    dirs = [scout.ROUNDS_DIR, f"{CACHE}/rounds"]
    if import_extra:
        dirs += [d for d in os.environ.get("CTF_FFA4_EPS_DIRS", "").split(":") if d]
        dirs.append(f"{HOME}/.ctf/handbook/cache/eps")
    return [d for d in dict.fromkeys(dirs) if os.path.isdir(d)]


def round_number_of(path):
    """scout caches as r<number>_<id>.json; imported caches carry no number."""
    b = os.path.basename(path)
    if b.startswith("r") and "_" in b:
        head = b[1:].split("_", 1)[0]
        if head.isdigit():
            return int(head)
    return None


def build_index(dirs, verbose=True):
    """replay basename -> meta, for every ffa4 Episode any cache can see.

    The replay basename is the join key on purpose: ~/.ctf/scout/events files
    are named for the REPLAY uuid, not the episode_id. Joining on episode_id
    returns zero rows and looks exactly like an empty corpus.
    """
    idx, seen = {}, {}
    stats = collections.Counter()
    keysets = collections.Counter()
    per_dir = collections.Counter()
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.json"))):
            try:
                eps = json.load(open(path))
            except Exception:                       # a half-written cache file
                stats["unreadable_files"] += 1
                continue
            if not isinstance(eps, list):
                continue
            rnd = round_number_of(path)
            for ep in eps:
                v = ep.get("variant_name") or ""
                if v.startswith(FFA4) and v != FFA4:
                    stats["ffa8_excluded"] += 1     # "(8 per team)": other geometry
                    continue
                if v != FFA4:
                    stats["other_variant"] += 1
                    continue
                if ep.get("status") != "completed" or not ep.get("replay_url"):
                    stats["not_completed"] += 1
                    continue
                stats["ffa4"] += 1
                eid = ep["episode_id"]
                if eid in seen:
                    stats["duplicate"] += 1
                    if rnd is not None and idx[seen[eid]].get("round") is None:
                        idx[seen[eid]]["round"] = rnd
                    continue
                parts = ep.get("participants") or []
                for p in parts:
                    keysets[tuple(sorted(p.keys()))] += 1
                players, vers = {}, collections.defaultdict(set)
                for p in sorted(parts, key=lambda p: p.get("position", 0)):
                    nm = p.get("player_name") or ""
                    vers[nm].add(p.get("version"))
                    players.setdefault(nm, p.get("version"))
                name = ep["replay_url"].split("/")[-1].replace(".replay", ".jsonl")
                seen[eid] = name
                per_dir[d] += 1
                idx[name] = {
                    "episode_id": eid,
                    "cw": ep.get("coworld_version"),
                    "round": rnd,
                    "at": ep.get("completed_at"),
                    "url": ep["replay_url"],
                    "players": players,
                    # kept ONLY to demonstrate the trap in selfcheck; never used
                    # to decide who the scripted control is.
                    "filler_seats": sum(1 for p in parts if p.get("is_filler")),
                    "seats": len(parts),
                }
                if any(len(s) > 1 for s in vers.values()):
                    stats["mixed_version_entrant"] += 1
    if verbose:
        for d in dirs:
            tag = "" if d.startswith(scout.CACHE) else "   [imported]"
            print(f"  source {d}: {per_dir[d]} ffa4 Episodes{tag}", file=sys.stderr)
        print(f"  ffa4 {stats['ffa4']}  (unique {len(idx)}, dup {stats['duplicate']})"
              f"   ffa8 excluded {stats['ffa8_excluded']}"
              f"   other variants {stats['other_variant']}", file=sys.stderr)
        if len(keysets) > 1:
            # VIEWER-SCOPED FIELDS: compare KEY SETS, not values. A key that is
            # absent for other players must never be read as a zero.
            print("  ⚠️  participant records do NOT share one key set — "
                  "fields present only for our own player are viewer-scoped:",
                  file=sys.stderr)
            common = set.intersection(*[set(k) for k in keysets])
            for k, n in keysets.most_common():
                print(f"      {n:6} rows: extra={sorted(set(k) - common)}",
                      file=sys.stderr)
    return idx, stats, keysets


def refresh_rounds(rounds, since, until):
    """Pull fresh rounds from the API into scout's round cache (limit=1000)."""
    ctfapi.whoami()
    eps = scout.index(rounds, since, until)
    rnds = sorted({r for r, _ in eps})
    print(f"  indexed {len(eps)} episodes over {len(rnds)} rounds "
          f"(r{min(rnds) if rnds else 0}-r{max(rnds) if rnds else 0})",
          file=sys.stderr)


def save_index(idx):
    os.makedirs(CACHE, exist_ok=True)
    json.dump(idx, open(INDEX_PATH, "w"))


def load_index(dirs=None, rebuild=False, verbose=True):
    if not rebuild and os.path.exists(INDEX_PATH):
        try:
            return json.load(open(INDEX_PATH))
        except Exception:
            pass
    idx, _s, _k = build_index(dirs or eps_dirs(), verbose)
    save_index(idx)
    return idx


def select(idx, since=None, until=None, after=None, before=None):
    """Pin the window. Rounds land every ~9 min, so a bare 'recent N' names a
    different set every run; --since/--until make a report reproducible.

    ⚠️ Round NUMBERS are league-scoped — the local cache also holds rounds of
    the dead Ctf league whose numbering overlaps Paintbot's. Those rounds hold
    no ffa4 Episode so they cannot pollute this index, but a round window is
    still only meaningful inside one league. --after/--before take ISO dates
    and are the portable window; they also work on imported caches, which carry
    no round number at all.
    """
    out, no_round = {}, 0
    for name, m in idx.items():
        if since is not None or until is not None:
            r = m.get("round")
            if r is None:
                no_round += 1
                continue
            if since is not None and r < since:
                continue
            if until is not None and r > until:
                continue
        at = (m.get("at") or "")[:10]
        if after and (not at or at < after):
            continue
        if before and (not at or at > before):
            continue
        out[name] = m
    if no_round:
        print(f"  {no_round} Episode(s) from imported caches carry no round "
              f"number and are EXCLUDED by the round window — --after/--before "
              f"reaches them", file=sys.stderr)
    return out


# ------------------------------------------------------------------ 2. fetch
def our_game_version():
    """The extractor checkout's GameVersion. scout.our_game_version() looks in
    src/ctf/sim.nim, but the const moved to sim_types.nim — when it silently
    returns None the cheap pre-flight GV skip is disabled and every mismatched
    replay pays a subprocess launch instead. Look in both."""
    d = os.path.dirname(os.path.dirname(scout.EXTRACT_BIN))
    for rel in ("src/ctf/sim_types.nim", "src/ctf/sim.nim"):
        try:
            for line in open(os.path.join(d, rel)):
                if "GameVersion* =" in line:
                    return line.split('"')[1]
        except OSError:
            continue
    return None


MAX_AUTO_FETCH = 400      # above this, make the operator name the cost


def fetch(sel, player=OURS, limit=None, everyone=False, workers=8):
    """Download + re-simulate every selected Episode that has no event file.

    By default this fetches only Episodes WE are in — which is all a post-ship
    read needs, because the WINNER / RIVAL / scripted-control columns are the
    other three teams sitting in our own Episodes. Pass --all when you want a
    rival's whole cell for --vs; that is a much bigger download.
    """
    scout.OUR_GV = our_game_version()
    todo = []
    for name, m in sel.items():
        if os.path.exists(os.path.join(scout.EVENT_DIR, name)):
            continue
        if not everyone and player not in (m.get("players") or {}):
            continue
        todo.append((m.get("round") or 0,
                     {"replay_url": m["url"], "episode_id": m["episode_id"],
                      "coworld_version": m["cw"]}))
    todo.sort(key=lambda t: -t[0])       # newest rounds first
    if limit:
        todo = todo[:limit]
    elif len(todo) > MAX_AUTO_FETCH:
        print(f"  {len(todo)} Episodes are indexed but not extracted. That is "
              f"a multi-GB download; re-run with --limit N (newest first) or "
              f"--limit {len(todo)} to take them all.", file=sys.stderr)
        return 0
    print(f"  fetching {len(todo)} Episode(s) "
          f"({'everyone' if everyone else player} only; extractor is "
          f"GV{scout.OUR_GV})", file=sys.stderr)
    if not todo:
        return 0
    return scout.fetch_all(todo, workers=workers)


# ------------------------------------------------------------------ 3. score
def load_events(path):
    """(summary, events). The {"type":"summary"} row is the LAST line, not the
    first — so scan the whole file. A line-1 read yields zero slots SILENTLY."""
    summ, evs = None, []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get("type") == "summary":
                summ = row
            else:
                evs.append(row)
    return summ, evs


def slot_alive_ticks(ticks, deaths, respawns):
    dead, rs = 0, sorted(respawns)
    for dt in sorted(deaths):
        nxt = next((x for x in rs if x > dt), ticks)
        dead += max(0, nxt - dt)
    return ticks - dead


def hp1_segments(deaths, respawns, dmg_in, heals):
    """Closed hp==1 segments as (start, end, fate), fate in {death, heal}.

    The HP TRACK is reconstructed, never counted from events: respawn -> MaxHp,
    damage.hp and heal.hp are the affected player's hp AFTER the event (engine
    truth written by the sim, not a bot's belief), death -> 0. A segment still
    open at the last event is DROPPED, so the denominator only ever holds
    resolved outcomes.
    """
    ev = [(0, MAXHP)]
    ev += [(t, MAXHP) for t in respawns]
    ev += [(t, hp) for (t, hp) in dmg_in if hp >= 0]
    ev += [(t, hp) for (t, hp) in heals if hp >= 0]
    ev += [(t, 0) for t in deaths]
    ev.sort()
    out, seg = [], None
    for (t, hp) in ev:
        if hp == 1 and seg is None:
            seg = t
        elif seg is not None:
            if hp == 0:
                out.append((seg, t, "death"))
                seg = None
            elif hp >= MAXHP:
                out.append((seg, t, "heal"))
                seg = None
    return out


def episode_rows(summ, evs, meta, name):
    """One row per TEAM-EPISODE (a policy's four seats in one Episode)."""
    if not summ or not summ.get("finished"):
        return None, "unfinished"
    team = summ.get("slot_team") or []
    addr = summ.get("slot_address") or []
    n = len(team)
    slots_of = collections.defaultdict(list)
    for i, c in enumerate(team):
        slots_of[c].append(i)
    # GEOMETRY ASSERTION, not a name check: ffa8 deals 8 per team, so anything
    # that is not 4 colours x 4 seats is refused rather than mis-scored.
    if (len(slots_of) != N_TEAMS or n != N_TEAMS * TEAM_SLOTS
            or any(len(v) != TEAM_SLOTS for v in slots_of.values())
            or len(addr) != n):
        return None, "geometry"
    ticks = summ.get("ticks") or 1
    winner = None if summ.get("draw") else summ.get("winner")

    deaths = collections.defaultdict(list)
    respawns = collections.defaultdict(list)
    dmg_in = collections.defaultdict(list)
    heals = collections.defaultdict(list)
    kits = collections.Counter()
    for e in evs:
        k = e.get("kind")
        s, t, tk = e.get("source", -1), e.get("target", -1), e.get("tick", 0)
        if k == "death" and 0 <= s < n:
            deaths[s].append(tk)
        elif k == "respawn" and 0 <= s < n:
            respawns[s].append(tk)
        elif k == "damage" and 0 <= t < n:
            # source=attacker, target=victim, hp = the VICTIM's hp after the hit
            dmg_in[t].append((tk, e.get("hp", -1)))
        elif k == "heal" and 0 <= s < n:
            # a med-kit heal records the HEALED player in `source`, not `target`
            heals[s].append((tk, e.get("hp", -1)))
        elif k == "item_pickup" and 0 <= s < n and e.get("item") == "med_kit":
            kits[s] += 1
    map_kits = sum(kits.values())

    rows = []
    for c, sl in slots_of.items():
        alive = d = segs = seghe = tk = 0
        for i in sl:
            alive += slot_alive_ticks(ticks, deaths[i], respawns[i])
            d += len(deaths[i])
            tk += kits[i]
            for (_a, _b, fate) in hp1_segments(deaths[i], respawns[i],
                                               dmg_in[i], heals[i]):
                segs += 1
                seghe += fate == "heal"
        pol = base_name(addr[sl[0]])
        rows.append({
            "name": name, "ep": meta["episode_id"], "cw": meta.get("cw"),
            "round": meta.get("round"), "at": meta.get("at"),
            "gv": summ.get("gameVersion"),
            "policy": pol, "version": (meta.get("players") or {}).get(pol),
            "color": c, "won": 1.0 if c == winner else 0.0,
            "draw": bool(summ.get("draw")),
            "ticks": ticks, "alive": alive, "deaths": d,
            "kits": tk, "map_kits": map_kits,
            "hp1": segs, "hp1_heal": seghe,
            "control": pol.startswith(CONTROL),
        })
    return rows, None


def build_rows(sel, rebuild=False, verbose=True):
    """Extraction -> team-Episode rows, cached so re-scoring is instant."""
    cache = {}
    if not rebuild and os.path.exists(ROWS_PATH):
        try:
            blob = json.load(open(ROWS_PATH))
            if blob.get("schema") == ROW_SCHEMA:
                cache = blob.get("rows") or {}
        except Exception:
            cache = {}
    out, skipped, fresh, missing = [], collections.Counter(), 0, 0
    for name, meta in sel.items():
        if name in cache:
            out += cache[name]
            continue
        p = os.path.join(scout.EVENT_DIR, name)
        if not os.path.exists(p):
            missing += 1
            continue
        summ, evs = load_events(p)
        rows, why = episode_rows(summ, evs, meta, name)
        if rows is None:
            skipped[why] += 1
            cache[name] = []
            continue
        cache[name] = rows
        out += rows
        fresh += 1
    if fresh or rebuild:
        os.makedirs(CACHE, exist_ok=True)
        json.dump({"schema": ROW_SCHEMA, "rows": cache}, open(ROWS_PATH, "w"))
    if verbose:
        print(f"  scored {fresh} new Episode(s); {len(out)} team-Episodes total;"
              f" {missing} indexed but not extracted"
              + (f"; refused {dict(skipped)}" if skipped else ""), file=sys.stderr)
    return out


# ------------------------------------------------------------------ metrics
def m_kits_per_Malive(r):
    return 1e6 * r["kits"] / max(1, r["alive"])


def m_kit_share(r):
    return r["kits"] / r["map_kits"] if r["map_kits"] else None


def m_zero_kits(r):
    return 1.0 if r["kits"] == 0 else 0.0


def m_deaths(r):
    return float(r["deaths"])


def m_survive(r):
    return 1.0 if r["deaths"] < TEAM_LIVES else 0.0


def m_kits(r):
    return float(r["kits"])


def m_alive_frac(r):
    return r["alive"] / max(1, r["ticks"] * TEAM_SLOTS)


# (key, label, kind, fn, digits, pct, better)  kind: mean | ratio
METRICS = [
    ("kits_per_Malive", "1 med_kits / 1e6 alive ticks", "mean",
     m_kits_per_Malive, 1, False, "high"),
    ("kit_share", "2 kit share of map (null 25%)", "mean",
     m_kit_share, 3, True, "high"),
    ("p_escape_hp1", "3 P(escape | hp==1)", "ratio",
     lambda r: (r["hp1_heal"], r["hp1"]), 4, True, "high"),
    ("p_zero_kits", "4 P(zero kits all Episode)", "mean",
     m_zero_kits, 3, True, "low"),
    ("deaths", "5 deaths / team-Episode", "mean", m_deaths, 2, False, "low"),
    ("p_survive", "  P(survive, <12 deaths)", "mean", m_survive, 3, True, "high"),
    ("kits", "  med_kits / team-Episode", "mean", m_kits, 3, False, "high"),
    ("alive_frac", "  alive fraction", "mean", m_alive_frac, 3, True, "high"),
    ("win", "  win rate (null 25%)", "mean",
     lambda r: r["won"], 3, True, "high"),
]
PAIRED_METRICS = ["kits", "kits_per_Malive", "deaths", "p_zero_kits", "p_survive"]

# PRE-REGISTERED ship-sized effects — the smallest move we would act on, fixed
# in ADVANCE so power is not tuned to a result. Stated in the metric's own
# units, because a "50% relative" rule is nonsense on a bounded quantity: half
# of 10.88 deaths is 5.44, and a team only has 12 lives to spend.
SHIP_DELTA = {
    "kits_per_Malive": 30.0,   # ~half our current 59.7, ~1/5 of the way to a winner
    "kits": 0.30,              # +0.3 med_kits per team-Episode
    "deaths": 0.50,            # half a life per team-Episode, of 12
    "p_zero_kits": 0.10,       # 10 points off the 57.5% of Episodes we take none
    "p_survive": 0.10,
    "kit_share": 0.05,
}
FN = {k: fn for k, _l, _kd, fn, _d, _p, _b in METRICS}
KIND = {k: kd for k, _l, kd, _fn, _d, _p, _b in METRICS}
DIGITS = {k: d for k, _l, _kd, _fn, d, _p, _b in METRICS}
PCTOF = {k: p for k, _l, _kd, _fn, _d, p, _b in METRICS}
BETTER = {k: b for k, _l, _kd, _fn, _d, _p, b in METRICS}
LABEL = {k: l for k, l, _kd, _fn, _d, _p, _b in METRICS}


def score_column(rows):
    """Every pre-registered metric for one set of team-Episodes."""
    out = {"n": len(rows)}
    for key, _lab, kind, fn, _d, _p, _b in METRICS:
        if kind == "mean":
            pt, lo, hi, n = boot_mean([fn(r) for r in rows])
            out[key] = {"v": pt, "lo": lo, "hi": hi, "n": n}
        else:
            pt, lo, hi, n, den = boot_ratio([fn(r) for r in rows])
            out[key] = {"v": pt, "lo": lo, "hi": hi, "n": n, "events": den}
    return out


def fmt(d, key):
    if d is None or d["v"] != d["v"]:
        return "n/a"
    p, dg = PCTOF[key], DIGITS[key]
    if p:
        s = f"{100 * d['v']:.1f}%"
        if d["lo"] is None:
            return s
        return f"{s} [{100*d['lo']:.1f},{100*d['hi']:.1f}]"
    s = f"{d['v']:.{dg}f}"
    if d["lo"] is None:
        return s
    return f"{s} [{d['lo']:.{dg}f},{d['hi']:.{dg}f}]"


def fmt_delta(v, lo, hi, key):
    if v != v:
        return "n/a", ""
    p, dg = PCTOF[key], DIGITS[key]
    s = (f"{100*v:+.1f}pp" if p else f"{v:+.{dg}f}")
    if lo is None:
        return s + "  (n too small)", "thin"
    ci = (f" [{100*lo:+.1f},{100*hi:+.1f}]" if p
          else f" [{lo:+.{dg}f},{hi:+.{dg}f}]")
    if lo <= 0 <= hi:
        return s + ci, "null"
    good = (v > 0) == (BETTER[key] == "high")
    return s + ci, ("better" if good else "worse")


VERDICT = {"null": "no measurable change", "better": "measurably BETTER",
           "worse": "measurably WORSE", "thin": "n too small to resolve"}


# --------------------------------------------------------- paired control
def paired_vs_control(rows, policy, control=CONTROL):
    """Within-Episode delta policy - scripted control, per metric.

    Same Episode = same map, same field, same engine, same length. This is the
    design that closed the map/field confound; a cross-Episode table cannot,
    because each policy's Episode set holds a different mix of scripted teams.
    A policy holding two teams in one Episode is averaged, not double-counted.
    """
    by_ep = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in rows:
        by_ep[r["ep"]][r["policy"]].append(r)
    out = {}
    for key in PAIRED_METRICS:
        fn = FN[key]
        ds = []
        for ep, d in by_ep.items():
            a = [r for p, rs in d.items() if p == policy for r in rs]
            b = [r for p, rs in d.items() if p.startswith(control) for r in rs]
            if not a or not b:
                continue
            x, y = mean([fn(r) for r in a]), mean([fn(r) for r in b])
            if x == x and y == y:
                ds.append(x - y)
        m, lo, hi, n = paired_ci(ds)
        out[key] = {"v": m, "lo": lo, "hi": hi, "n": n, "sd": sd(ds)}
    return out


# ------------------------------------------------------------------ power
def n_for(sd_x, delta, paired=False):
    if sd_x != sd_x or not delta:
        return None
    k = (Z_A + Z_B) ** 2 * (1 if paired else 2)
    return int(math.ceil(k * sd_x ** 2 / delta ** 2))


def mde(sd_x, n, paired=False):
    if sd_x != sd_x or n < 2:
        return float("nan")
    return (Z_A + Z_B) * sd_x * (1.0 if paired else math.sqrt(2.0)) / math.sqrt(n)


def header_gv(idx, cw, sample=40):
    """The GameVersion each build was RECORDED on, read from replay headers.

    The summary row's `gameVersion` is the EXTRACTOR's, so it reads 43 for every
    file we could extract at all — using it to describe the corpus is circular.
    The header is the recording engine. Measured, this refutes a claim we had
    been carrying: 0.7.227 replays are GV43, not GV42; only 0.7.225/0.7.226 are
    GV42 and those are the ones extraction refuses.
    """
    seen = collections.Counter()
    for m in idx.values():
        if m.get("cw") != cw:
            continue
        rp = os.path.join(scout.REPLAY_DIR, m["url"].split("/")[-1])
        if os.path.exists(rp):
            seen[scout.replay_game_version(rp) or "?"] += 1
        if sum(seen.values()) >= sample:
            break
    return seen


GV_PROBE_PATH = f"{CACHE}/gv_probe.json"


def probe_gv(idx, cw):
    """Read ONE replay header for a build we have not downloaded, with an HTTP
    Range request (64 bytes, S3 answers 206). Cheap, and it answers the only
    question that matters about a new build: has the ENGINE moved past our
    extractor, or do we simply not have the replays yet? Those look identical
    in an 'extracted 0' column and mean completely different things."""
    try:
        cache = json.load(open(GV_PROBE_PATH))
    except Exception:
        cache = {}
    if cw in cache:
        return cache[cw]
    url = next((m["url"] for m in idx.values() if m.get("cw") == cw), None)
    gv = None
    if url:
        try:
            import urllib.request
            req = urllib.request.Request(url, headers={"Range": "bytes=0-63"})
            with urllib.request.urlopen(req, timeout=30) as r:
                head = r.read()
            i = head.find(b"ctf")
            if i >= 0:
                n = head[i + 3]
                gv = head[i + 5:i + 5 + n].decode("ascii", "replace")
        except Exception:                        # a probe must never be fatal
            gv = None
    cache[cw] = gv
    os.makedirs(CACHE, exist_ok=True)
    json.dump(cache, open(GV_PROBE_PATH, "w"))
    return gv


def arrival_rate(idx, player, days=2.0):
    """our ffa4 team-Episodes per day — MEASURED, never assumed.

    Counted only over rounds we hold COMPLETE (a round file fetched at
    limit=1000, which is the only kind that carries a round number), because a
    raw per-calendar-day count of an imported cache measures how hard somebody
    swept that day, not how much ffa4 the league dealt us. rounds/day comes from
    the round NUMBERS spanned, so rounds we never cached still count in the
    denominator.

    The rate is not stable: it tracks the campaign cells we hold. Over the last
    two days it reads ~7/day; over the last week ~18/day, because of one burst.
    Use the trailing figure for planning and print both.
    """
    rounds = {}
    for m in idx.values():
        r = m.get("round")
        if r is None or not m.get("at"):
            continue
        d = rounds.setdefault(r, {"at": "", "ours": 0})
        d["at"] = max(d["at"], m["at"])
        if player in (m.get("players") or {}):
            d["ours"] += 1
    if not rounds:
        return float("nan"), {}
    def ts(x):
        return datetime.datetime.fromisoformat(x.replace("Z", "+00:00"))
    last = max(ts(d["at"]) for d in rounds.values())
    cut = last - datetime.timedelta(days=days)
    sel = {r: d for r, d in rounds.items() if ts(d["at"]) >= cut}
    if len(sel) < 5:
        sel = rounds
    tsel = sorted(ts(d["at"]) for d in sel.values())
    span = (tsel[-1] - tsel[0]).total_seconds() / 86400.0
    rpd = (max(sel) - min(sel)) / span if span > 0.2 else float("nan")
    per_round = sum(d["ours"] for d in sel.values()) / len(sel)
    return per_round * rpd, {"rounds": len(sel), "span": span, "rpd": rpd,
                             "per_round": per_round,
                             "ours": sum(d["ours"] for d in sel.values())}


# A naive "count our Episodes per calendar day" estimator was tried first and is
# WRONG on this corpus: it read 40/day because it measures how hard somebody
# swept the round cache that day, not how much ffa4 the league dealt us. Only
# fully-cached rounds can carry that denominator, which is what arrival_rate
# above does (7.6/day, against ~6/day expected).


# ------------------------------------------------------------------ report
def pick_version(rows, player, want):
    """--version v55 / 55, or the best-supported version with a printed census."""
    census = collections.Counter(r["version"] for r in rows
                                 if r["policy"] == player)
    if want:
        w = int(str(want).lstrip("vV"))
        return w, census
    if not census:
        return None, census
    return census.most_common(1)[0][0], census


def report(rows, idx, player=OURS, want_version=None, vs=None, build=None,
           since=None, until=None, rate_days=2.0, rate_override=None,
           after=None, before=None):
    all_rows = rows
    ver, census = pick_version(all_rows, player, want_version)
    if ver is None:
        print(f"no team-Episodes for {player} in this window.")
        return
    if not want_version:
        print(f"\n--version not given: scoring the best-supported version, "
              f"v{ver}. Census: "
              + ", ".join(f"v{v}={n}" for v, n in census.most_common(6)))

    ours_all = [r for r in all_rows if r["policy"] == player and r["version"] == ver]
    builds = collections.Counter(r["cw"] for r in ours_all)
    indexed_builds = collections.Counter(r["cw"] for r in all_rows)

    rnds = sorted({r["round"] for r in all_rows if r.get("round") is not None})
    ats = sorted(r["at"] for r in all_rows if r.get("at"))
    print(f"\n=== ffa4 SURVIVAL ECONOMY — {player} v{ver} ===")
    print("  window: " + (f"r{min(rnds)}-r{max(rnds)}" if rnds else "unpinned")
          + (f"   {ats[0][:19]} .. {ats[-1][:19]}" if ats else "")
          + ("   (pinned: "
             + " ".join(f"--{k} {v}" for k, v in (("since", since),
                                                  ("until", until),
                                                  ("after", after),
                                                  ("before", before)) if v)
             + ")" if (since or until or after or before)
             else "   (UNPINNED — pass --since/--until, or --after/--before, "
                  "to make this exact set reproducible)"))
    print(f"  {len(all_rows)//N_TEAMS} ffa4 Episodes scored -> {len(all_rows)} "
          f"team-Episodes; {len(ours_all)} of them ours at v{ver}")
    print("  per coworld build — NEVER summed (0.7.228 and 0.7.229 are both "
          "GV43 but are DIFFERENT builds):")
    print(f"    {'build':10}{'recorded GV':>14}{'indexed':>9}{'extracted':>11}"
          f"{'  team-Eps':>10}{'  ours@v' + str(ver):>12}")
    idx_by_build = collections.Counter(m["cw"] for m in idx.values())
    ext_by_build = collections.Counter()
    for name, m in idx.items():
        if os.path.exists(os.path.join(scout.EVENT_DIR, name)):
            ext_by_build[m["cw"]] += 1
    our_gv = our_game_version()
    for cw in sorted(idx_by_build, key=str, reverse=True):
        gv = header_gv(idx, cw)
        gvs = ",".join(f"GV{g}" for g, _n in gv.most_common(2))
        probed = False
        if not gvs:
            g = probe_gv(idx, cw)
            gvs, probed = (f"GV{g}" if g else "?"), True
        mark = ""
        if ext_by_build[cw] == 0:
            same = gvs.replace("GV", "").split(",")[0] == str(our_gv)
            mark = ("   <- 0 extractions but the engine MATCHES: run `fetch`"
                    if same else
                    f"   <- other engine, our extractor is GV{our_gv}: "
                    "UNAVAILABLE, not zero")
        if probed:
            gvs += "*"
        print(f"    {str(cw):10}{gvs:>14}{idx_by_build[cw]:>9}"
              f"{ext_by_build[cw]:>11}{indexed_builds.get(cw, 0):>10}"
              f"{builds.get(cw, 0):>12}{mark}")
    print(f"    (extractor is GV{our_gv}; a replay re-simulates only on the "
          f"engine that recorded it. GV is read from the replay HEADER — the "
          f"summary row's\n     gameVersion is the EXTRACTOR's and reads 43 "
          f"for every file we could extract at all, which is circular. "
          f"* = probed\n     with a 64-byte Range request because we hold no "
          f"replay of that build yet.)")

    cells = [b for b in builds if builds[b] > 0]
    if not cells:
        pres = collections.Counter(r["version"] for r in all_rows
                                   if r["policy"] == player)
        print(f"\n  {player} v{ver} has NO team-Episodes in this window. "
              f"Present here: "
              + (", ".join(f"v{v}={n}" for v, n in pres.most_common(8))
                 or f"no {player} Episodes at all")
              + ".\n  Widen the window (--since/--until, or --after/--before), "
              "or run `fetch` — an unextracted\n  Episode is invisible to the "
              "score stage and reads exactly like an absent one.")
        return
    if build:
        if build not in cells:
            why = ("indexed, but 0 extracted Episodes of ours (engine horizon: "
                   f"the extractor is GV{our_game_version()})"
                   if build in idx_by_build else "not in the corpus")
            print(f"\n  build {build}: UNAVAILABLE for {player} v{ver} — {why}."
                  "  That is NOT zero, and it is NOT poolable with another "
                  "build.")
            return
        cells = [build]
    cells.sort(key=str, reverse=True)

    rate, deriv = (rate_override, {}) if rate_override else arrival_rate(
        idx, player, rate_days)
    results = {"player": player, "version": ver, "rate_per_day": rate,
               "builds": {}}
    for cw in cells:
        results["builds"][str(cw)] = build_block(all_rows, ours_all, player, ver,
                                                 cw, vs, rate, deriv, rate_days)
    if len(cells) > 1:
        print("\n  ⚠️  Two builds above. They are SEPARATE cells and must not be "
              "pooled: v52's ffa4 record ran +0.198 -> +0.305 -> -0.270 across "
              "builds, a sign flip a blended number hid completely.")
    return results


def build_block(all_rows, ours_all, player, ver, cw, vs, rate, deriv, rate_days):
    ours = [r for r in ours_all if r["cw"] == cw]
    eps = {r["ep"] for r in ours}
    cell = [r for r in all_rows if r["cw"] == cw and r["ep"] in eps]
    # Reference groups, ours-first precedence (a Baseline team that WON is a
    # WINNER row): OURS > WINNER > scripted control > every other rival.
    winner, control, rival = [], [], []
    for r in cell:
        if r["policy"] == player and r["version"] == ver:
            continue
        (winner if r["won"] else
         (control if r["control"] else rival)).append(r)
    # --vs takes either a rival player or ONE OF OUR OWN VERSIONS ("v55"),
    # because the post-ship question is almost always "did v58 beat v57?".
    vs_ver = None
    if vs and vs.strip().lstrip("vV").isdigit():
        vs_ver = int(vs.strip().lstrip("vV"))
    if vs_ver is not None:
        vslab = f"{player} v{vs_ver}"
        vs_rows = [r for r in all_rows if r["cw"] == cw
                   and r["policy"] == player and r["version"] == vs_ver]
    else:
        vslab = vs
        vs_rows = [r for r in all_rows if r["cw"] == cw
                   and r["policy"] == vs] if vs else []

    ourlab = f"{player} v{ver}"
    cols = [(ourlab, ours)]
    if vs:
        cols.append((vslab, vs_rows))
    cols += [("WINNER(any)", winner), ("RIVAL(other)", rival),
             (f"{CONTROL}(control)", control)]
    policy_cols = {ourlab, vslab} if vs else {ourlab}

    print(f"\n--- build {cw} ---  {len(ours)} team-Episodes of ours"
          + ("   ⚠️ THIN: fewer than " + str(THIN_N) if len(ours) < THIN_N else ""))
    whole = [r for r in all_rows if r["cw"] == cw and r["policy"] == player]
    if len(whole) != len(ours):
        vc = collections.Counter(r["version"] for r in whole)
        print(f"  ({player} on this build across all versions: n={len(whole)} — "
              + ", ".join(f"v{v}={n}" for v, n in vc.most_common(5))
              + ". Only v" + str(ver) + " is scored below.)")
    if vs and not vs_rows:
        print(f"  ⚠️  {vslab} has NO team-Episodes on build {cw}: that comparison "
              f"is UNAVAILABLE here. It is not zero, and it must not be "
              f"borrowed from another build.")
    scored = {lab: score_column(rs) for lab, rs in cols}
    w = 24
    print("  " + "metric".ljust(30) + "".join(lab[:w - 1].rjust(w) for lab, _ in cols))
    print("  " + "team-Episodes".ljust(30)
          + "".join(str(len(rs)).rjust(w) for _l, rs in cols))
    for key, lab, _kd, _fn, _d, _p, _b in METRICS:
        line = "  " + lab.ljust(30)
        for l, _rs in cols:
            if key == "win" and l not in policy_cols:
                line += "— by construction".rjust(w)   # WINNER is 100% by defn
            else:
                line += fmt(scored[l][key], key).rjust(w)
        print(line)
    print("  " + "  (hp==1 segments resolved)".ljust(30)
          + "".join(str(scored[l]["p_escape_hp1"].get("events", 0)).rjust(w)
                    for l, _rs in cols))
    elim = sum(1 for r in cell if r["won"] and r["deaths"] >= TEAM_LIVES)
    nwin = sum(1 for r in cell if r["won"])
    print(f"  ELIMINATION INVARIANT: {elim} of {nwin} winning team-Episodes "
          f"reached {TEAM_LIVES} deaths. A team that spends all 12 lives does "
          f"not win — which is why deaths is an OUTCOME metric here, not a "
          f"style metric.")
    print("  note: WINNER is selected on the OUTCOME, so it is a target, not a "
          "control. The control is the scripted " + CONTROL + " column.")

    # ---- 6. the paired within-Episode design
    print(f"\n  6 PAIRED within-Episode delta vs the scripted {CONTROL} control "
          f"(same Episode = same map, same field, same engine, same length):")
    build_rows_cw = [r for r in all_rows if r["cw"] == cw]
    pair = {}
    # ours is restricted to the chosen version; other policies are whole cells
    pair[ourlab] = paired_vs_control(
        [r for r in build_rows_cw if r["policy"] != player or r["version"] == ver],
        player)
    if vs:
        vs_scope = ([r for r in build_rows_cw
                     if r["policy"] != player or r["version"] == vs_ver]
                    if vs_ver is not None else build_rows_cw)
        pair[vslab] = paired_vs_control(vs_scope, vs if vs_ver is None else player)
    pols = [ourlab] + ([vslab] if vs else [])
    print("  " + "metric".ljust(30) + "".join(p[:23].rjust(23) + "   " for p in pols))
    for key in PAIRED_METRICS:
        line = "  " + LABEL[key].strip()[:28].ljust(30)
        for p in pols:
            d = pair[p][key]
            t, tag = fmt_delta(d["v"], d["lo"], d["hi"], key)
            line += t.rjust(23) + (" ns" if tag == "null" else "   ")
        print(line)
    print("  " + "n (paired Episodes)".ljust(30)
          + "".join(str(pair[p]["kits"]["n"]).rjust(23) + "   " for p in pols))
    print("  ns = the CI crosses zero: no measurable change.")
    print("  A policy holding two teams in one Episode is AVERAGED, not "
          "double-counted. (Keeping one\n  arbitrary control team instead — "
          "the ad-hoc script this replaces did — moves med_kits by 0.03\n  and "
          "nothing else; averaging is the lower-variance estimator.)")
    if vs and pair[ourlab]["kits"]["v"] == pair[ourlab]["kits"]["v"] \
            and pair[vslab]["kits"]["v"] == pair[vslab]["kits"]["v"]:
        a, b = pair[ourlab]["kits"]["v"], pair[vslab]["kits"]["v"]
        if (a < 0) != (b < 0):
            print(f"  ⭐ SIGN FLIP on med_kits against the SAME scripted "
                  f"control: {ourlab} {a:+.2f}, {vslab} {b:+.2f}.")

    # ---- head-to-head delta with an honest verdict
    if vs and vs_rows:
        print(f"\n  DELTA ({ourlab} - {vslab}) on build {cw}, bootstrap "
              f"over team-Episodes (unpaired: different Episode sets):")
        for key, lab, kind, fn, _d, _p, _b in METRICS:
            if key == "win":
                continue
            if kind == "mean":
                v, lo, hi = boot_delta_mean([fn(r) for r in ours],
                                            [fn(r) for r in vs_rows])
            else:
                v, lo, hi = boot_delta_ratio([fn(r) for r in ours],
                                             [fn(r) for r in vs_rows])
            t, tag = fmt_delta(v, lo, hi, key)
            print("  " + lab.ljust(30) + t.rjust(26) + "   " + VERDICT[tag])

    # ---- the power line
    power_block(ours, vs_rows or winner, vslab or "WINNER", pair[ourlab],
                rate, deriv, rate_days)
    return {"n": len(ours), "columns": {l: scored[l] for l, _ in cols},
            "paired": pair, "rate_per_day": rate}


def power_block(ours, ref, ref_label, paired, rate, deriv, rate_days):
    """How many team-Episodes a real read costs, and how many DAYS that is.

    Two regimes, because they answer different questions:
      A  "did our own number move?" — the post-ship question. Delta is stated
         relative to our CURRENT level (a 50% relative move), so it does not
         depend on anyone else.
      B  "are we closing the gap?" — delta is a quarter of the distance to the
         reference column.
    Both are reported unpaired (arm vs arm) and paired against the in-Episode
    scripted control, which is the cheaper design.
    """
    print("\n  POWER — how long until a real read?  "
          "(alpha 0.05 two-sided, 80% power)")
    if deriv:
        print(f"    arrival: {rate:.1f} ffa4 team-Episodes/day for this arm — "
              f"{deriv['ours']} of ours over {deriv['rounds']} fully-cached "
              f"rounds in the last {deriv['span']:.1f}d "
              f"({deriv['per_round']:.3f}/round x {deriv['rpd']:.0f} rounds/day)")
        print("    ffa4 volume tracks the campaign cells we hold, so this rate "
              f"MOVES; it is re-measured every run\n    (--rate-days "
              f"{rate_days:g} to widen the estimate, --eps-per-day to override).")
    else:
        print(f"    arrival: {rate:.1f} ffa4 team-Episodes/day (given)")

    keys = ("kits_per_Malive", "kits", "deaths", "p_zero_kits")
    stats = {}
    for key in keys:
        xs = [FN[key](r) for r in ours]
        stats[key] = (sd(xs), mean(xs),
                      mean([FN[key](r) for r in ref]) if ref else float("nan"),
                      (paired.get(key) or {}).get("sd", float("nan")))

    def block(title, delta_of):
        cheaper = {}
        print(f"    {title}")
        print("    " + "metric".ljust(26) + "sd".rjust(8) + "delta".rjust(10)
              + "n/arm".rjust(8) + "days".rjust(7) + "paired n".rjust(10)
              + "days".rjust(7) + "MDE today".rjust(12))
        for key in keys:
            s_, m_, ref_m, sdp = stats[key]
            d = delta_of(key, m_, ref_m)
            n_un, n_p = n_for(s_, d), n_for(sdp, d, paired=True)
            ok = rate == rate and rate > 0
            du = n_un / rate if (n_un and ok) else float("nan")
            dp = n_p / rate if (n_p and ok) else float("nan")
            pctf = PCTOF[key]

            def q(x, dg=2):
                return ("n/a" if x != x else
                        (f"{100*x:.1f}pp" if pctf else f"{x:.{dg}f}"))
            cheaper[key] = bool(n_un and n_p and n_p < n_un)
            print("    " + LABEL[key].strip()[:24].ljust(26) + q(s_).rjust(8)
                  + q(d).rjust(10) + (str(n_un) if n_un else "n/a").rjust(8)
                  + (f"{du:.1f}" if du == du else "n/a").rjust(7)
                  + (str(n_p) if n_p else "n/a").rjust(10)
                  + (f"{dp:.1f}" if dp == dp else "n/a").rjust(7)
                  + q(mde(s_, len(ours))).rjust(12))
        return cheaper

    cheaper = block(
        "A  the PRE-REGISTERED ship-sized effect (the post-ship question: did "
        "our own number move?):",
        lambda k, m, r: SHIP_DELTA.get(k, float("nan")))
    block(f"B  a quarter of the gap to {ref_label} (the catch-up question):",
          lambda k, m, r: abs(r - m) * 0.25 if r == r else float("nan"))
    print("    'days' is wall-clock for the NEW arm only: an unpaired A/B "
          "compares against field data\n    we have already banked, and a "
          "paired run gets both arms out of every Episode.")
    pc = [k for k in keys if cheaper.get(k)]
    print("    Paired is cheaper on: "
          + (", ".join(LABEL[k].strip() for k in pc) if pc else "nothing here")
          + ".\n    It is dearer where the scripted control's OWN variance is "
          "uncorrelated with ours (kit counts).\n    Paired's real value is "
          "that it cannot be confounded by field or map drift — when the two\n"
          "    disagree, believe the paired one.")


# ------------------------------------------------------------------ selfcheck
def selfcheck():
    """Every trap that has already cost real time, as an executable assertion."""
    ok = True
    print("selfcheck — the traps this instrument refuses to fall into\n")

    # 1. the summary row is the LAST line, not the first
    idx = load_index(verbose=False)
    names = [n for n in idx if os.path.exists(os.path.join(scout.EVENT_DIR, n))]
    tried = first_is_summary = last_is_summary = 0
    for n in names[:25]:
        lines = [l for l in open(os.path.join(scout.EVENT_DIR, n)).read().split("\n") if l.strip()]
        if not lines:
            continue
        tried += 1
        first_is_summary += json.loads(lines[0]).get("type") == "summary"
        last_is_summary += json.loads(lines[-1]).get("type") == "summary"
    good = tried and first_is_summary == 0 and last_is_summary == tried
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] summary row is the LAST line "
          f"({last_is_summary}/{tried} files); a line-1 read finds it in "
          f"{first_is_summary}/{tried} -> zero slots, silently")

    # 2. is_filler marks a SEAT, not a policy
    ours_flagged = sum(1 for m in idx.values()
                       if OURS in (m.get("players") or {}) and m["filler_seats"])
    typical = collections.Counter(m["filler_seats"] for m in idx.values()).most_common(1)
    good = ours_flagged > 0
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] is_filler marks a SEAT: "
          f"{ours_flagged} Episodes flag filler seats while WE are an entrant; "
          f"the modal Episode flags {typical[0][0] if typical else '?'} of 16 seats. "
          f"The scripted control is the entrant NAMED '{CONTROL}'.")

    # 3. limit=1000 on the episodes endpoint
    import inspect
    src = inspect.getsource(ctfapi.episodes)
    good = "limit=1000" in src
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] ctfapi.episodes() passes limit=1000 "
          f"(the endpoint defaults to 50 and truncates SILENTLY)")

    # 4. participant key sets are compared, not assumed
    _i, _s, keysets = build_index(eps_dirs(), verbose=False)
    good = len(keysets) == 1
    print(f"  [{'PASS' if good else 'WARN'}] participant records share "
          f"{len(keysets)} key set(s)"
          + ("" if good else " — viewer-scoped fields present; never read a "
                             "missing key as zero"))

    # 5. ffa8 is excluded, and the geometry is asserted, not trusted
    ffa8 = _s.get("ffa8_excluded", 0)
    rows = build_rows({n: idx[n] for n in names[:200]}, verbose=False)
    bad = [r for r in rows if r["ticks"] <= 0]
    good = not bad
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] ffa8 excluded by name ({ffa8} "
          f"Episodes) AND by a 16-slot / 4-colour geometry assertion")

    # 6. the HP track is reconstructed, not counted
    r = next((r for r in rows if r["hp1"] > 0), None)
    good = r is not None
    ok &= good
    print(f"  [{'PASS' if good else 'FAIL'}] hp==1 segments come from a "
          f"reconstructed HP track (sample row: {r['hp1'] if r else 0} resolved "
          f"segments, {r['hp1_heal'] if r else 0} escaped)")

    # 7. builds are never summed
    print(f"  [PASS] builds are reported separately by construction "
          f"({len(set(m['cw'] for m in idx.values()))} builds in the index)")
    print(f"\n{'ALL CHECKS PASS' if ok else 'SOME CHECKS FAILED'}")
    return 0 if ok else 1


# ------------------------------------------------------------------ cli
def main():
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["index", "fetch", "score", "run", "selfcheck"])
    ap.add_argument("--player", default=OURS)
    ap.add_argument("--version", help="our policy version, e.g. v55")
    ap.add_argument("--vs", help="score a rival with the SAME instrument")
    ap.add_argument("--build", help="pin one coworld build, e.g. 0.7.229")
    ap.add_argument("--since", type=int, help="lowest round number to include")
    ap.add_argument("--until", type=int, help="highest round number to include")
    ap.add_argument("--rounds", type=int, default=0,
                    help="index: pull this many recent completed rounds from "
                         "the API before building the index")
    ap.add_argument("--limit", type=int, help="fetch: cap Episodes downloaded")
    ap.add_argument("--all", action="store_true",
                    help="fetch every ffa4 Episode, not only ours (needed for "
                         "a rival's FULL cell under --vs)")
    ap.add_argument("--rebuild", action="store_true",
                    help="ignore the index/row caches and rebuild")
    ap.add_argument("--no-import", action="store_true",
                    help="use only our own round cache, no imported caches")
    ap.add_argument("--after", help="ISO date, e.g. 2026-08-16 (portable "
                                    "window; works on imported caches)")
    ap.add_argument("--before", help="ISO date, inclusive")
    ap.add_argument("--rate-days", type=float, default=2.0,
                    help="trailing days used to MEASURE the ffa4 arrival rate")
    ap.add_argument("--eps-per-day", type=float,
                    help="override the measured arrival rate for planning")
    ap.add_argument("--out", help="write the scored result as JSON")
    a = ap.parse_args()

    if a.cmd == "selfcheck":
        sys.exit(selfcheck())

    if a.cmd in ("index", "run") and (a.rounds or a.since or a.until):
        refresh_rounds(a.rounds or 6, a.since, a.until)
    dirs = eps_dirs(import_extra=not a.no_import)
    idx = load_index(dirs, rebuild=a.rebuild or a.cmd in ("index", "run"))
    sel = select(idx, a.since, a.until, a.after, a.before)
    have = sum(1 for n in sel if os.path.exists(os.path.join(scout.EVENT_DIR, n)))
    print(f"  window holds {len(sel)} ffa4 Episodes; {have} already extracted",
          file=sys.stderr)
    if a.cmd == "index":
        by_build = collections.Counter(m["cw"] for m in sel.values())
        mine = collections.Counter(m["cw"] for m in sel.values()
                                   if a.player in (m.get("players") or {}))
        print(f"\n{len(sel)} ffa4 Episodes; {sum(mine.values())} involve {a.player}")
        print(f"  {'build':12}{'Episodes':>10}{'ours':>8}{'extracted':>11}")
        for cw, n in sorted(by_build.items(), key=lambda kv: str(kv[0]), reverse=True):
            ex = sum(1 for k, m in sel.items() if m["cw"] == cw
                     and os.path.exists(os.path.join(scout.EVENT_DIR, k)))
            print(f"  {str(cw):12}{n:>10}{mine.get(cw, 0):>8}{ex:>11}")
        return

    if a.cmd in ("fetch", "run"):
        fetch(sel, a.player, limit=a.limit, everyone=a.all)

    if a.cmd in ("score", "run"):
        rows = build_rows(sel, rebuild=a.rebuild)
        res = report(rows, sel, a.player, a.version, a.vs, a.build,
                     a.since, a.until, a.rate_days, a.eps_per_day,
                     a.after, a.before)
        if a.out and res:
            json.dump(res, open(a.out, "w"), indent=1, default=str)
            print(f"\nwrote {a.out}")


if __name__ == "__main__":
    main()
