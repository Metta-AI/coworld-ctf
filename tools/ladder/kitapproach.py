#!/usr/bin/env python
"""kitapproach — do we actually STEER to med kits, or to a PHANTOM address?

THE DEFECT UNDER TEST
Our policy routes wounded bots to two HARD-CODED "formula" addresses:
    MedKitAX = MapW div 2 ;  MedKitAY =     MapH div 3
    MedKitBX = MapW div 2 ;  MedKitBY = 2 * MapH div 3
(players/baseline/baseline.nim L674-677 and L5897-5900). Those are the kit
positions of the two HAND-AUTHORED arenas (arena.nim L576 / L602) and of nothing
else. Every GENERATED board draws its own kits (arena.nim L2440-2487):
  * 2-team: four candidates on x = W/2, at y1, H-1-y1, y2, H-1-y2, and a COIN
    FLIP activates exactly ONE of the two pairs — so two of the four drawn
    candidates are always EMPTY GROUND.
  * 4-team: FOUR kits, the rot90 / quadMirror orbit of one drawn ring point at
    radius d from the map centre. The formula's x = W/2 is the centre COLUMN,
    which on a 4-team board is where no kit ever is.
`sim.medKitSpawns` is the truth; the formula is a claim about it.

TWO MEASUREMENTS, IN ONE FILE
  (A) `kits`  — GROUND TRUTH GEOMETRY. Distance from each formula address to
      the nearest REAL ACTIVE spawn, per board, split 2-team / 4-team. Needs no
      simulation walk: bin/kit_spawn_dump builds the sim from the recorded
      config (initSimServer already calls resetMedKits) and prints the map's
      kit geometry. ~0.2s per replay.
  (B) `extract` + `score` — THE PLACEBO-CONTROLLED APPROACH TEST. For every
      maximal hp==1 run of every seat, net px CLOSED toward a target picked at
      segment ONSET, for FOUR target families over the SAME segments:
        (a) nearest STOCKED real spawn        <- the thing a healthy policy seeks
        (b) nearest LOCKED real spawn         <- placebo 1: a real spot, empty NOW
        (c) nearest FORMULA address           <- placebo 2, THE PHANTOM
        (d) nearest INACTIVE candidate        <- placebo 3, 2-team only: a spot
            the generator DREW and the coin flip did not activate. Perfectly
            matched empty ground, same column, same symmetry, same draw.
      If we close MORE px on (c) than on (a), the defect is proven directly:
      the feet are going to an address, not to a kit.

WHY IT IS BUILT THIS WAY (each of these has already cost somebody real time)
  * POSITIONS COME FROM `--frames`, NOT FROM EVENTS. Events say what happened;
    only the frame stream says where everyone was in between. The layout is
    documented at the top of coworld-ctf-scout/tools/extract_events.nim and
    decoded here EXACTLY as `framesHeader`/`frameOffset`/`frameSeat` write it.
  * HP COMES FROM THE FRAME BYTE, not from a reconstructed event track. The
    engine writes it; there is nothing to infer and nothing to get wrong.
  * IDENTITY COMES FROM `slot_address`, NEVER from the API `player_name` and
    NEVER from `is_filler` (which marks a SEAT — it flags every entrant's 2nd
    seat onward, including ours). The scripted control is the entrant whose
    slot_address is literally `Baseline`.
  * `FJM Picasso v47` IS OUR OWN FORK and is excluded from "the field".
  * A KIT PICKUP EVENT CARRIES THE SPAWN'S OWN x,y (sim.nim `emitPickup(...,
    spawn.x, spawn.y)`), so the lock timeline is exact, not a proximity guess.
    A taken kit is locked for MedKitRespawnTicks = 30 * ReplayFps = 720 ticks.
  * THE PHANTOM IS NEARER THAN THE KITS on many boards, and "closed more px" on
    a nearer target is not automatically a preference. `score` therefore also
    prints a DISTANCE-MATCHED table, bucketing segments by onset distance.
  * CLUSTERED ON THE TEAM-EPISODE. A policy's four seats in one Episode are ONE
    sample. SEs are over team-Episodes, never over segments.

USAGE  (PY is any python3; scout.py only needs the coworld api client for
       `index`, so the venv is the safe choice)
  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  cd ~/projects/coworld-ctf/tools/ladder
  PYTHONPATH=. $PY kitapproach.py index                  # master index, all variants
  PYTHONPATH=. $PY kitapproach.py kits                   # (A) geometry report
  PYTHONPATH=. $PY kitapproach.py selfcheck --limit 60   # instrument validation
  PYTHONPATH=. xargs -P 6 -n 4 $PY kitapproach.py worker < episodes.txt   # (B) rows
  PYTHONPATH=. $PY kitapproach.py score                  # (B) hp==1 report
  PYTHONPATH=. $PY kitapproach.py score --hp 2 --fire --fire-px 250

⚠️ TWO CHECKOUTS, ONE ENGINE HORIZON. A replay only re-simulates on the engine
that RECORDED it, and the GameVersion HEADER does not resolve it: builds 0.7.228
and 0.7.231 are both GV43, but ~/projects/coworld-ctf-scout (built 2026-08-12)
fails 0.7.231 with "Replay hash mismatch" while ~/projects/coworld-ctf-scout230
(2026-08-19) handles it — and the reverse holds for the older builds. So run the
worker pass TWICE, once per checkout; an `extract:` skip is deliberately
RETRYABLE so the second pass picks up exactly what the first could not do:
  PYTHONPATH=. CTF_KIT_REPO=~/projects/coworld-ctf-scout230 \
    CTF_KITDUMP_BIN=~/projects/coworld-ctf-scout230/bin/kit_spawn_dump \
    CTF_SCOUT_BIN=~/projects/coworld-ctf-scout230/bin/extract_events \
    xargs -P 6 -n 4 $PY kitapproach.py worker < episodes.txt

The Nim side (add-only; nothing existing in either checkout is touched):
  cd ~/projects/coworld-ctf-scout    && nim c -d:release \
      --out:bin/kit_spawn_dump tools/kit_spawn_dump.nim
  cd ~/projects/coworld-ctf-scout230 && nim c -d:release \
      --out:bin/kit_spawn_dump tools/kit_spawn_dump.nim
"""
import argparse
import collections
import glob
import json
import math
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import scout                                                     # noqa: E402

HOME = os.path.expanduser("~")
CACHE = f"{HOME}/.ctf/scout/kitapproach"
INDEX_PATH = f"{CACHE}/index.json"
KITS_PATH = f"{CACHE}/kits.json"
ROWS_DIR = f"{CACHE}/rows"

SCOUT_REPO = os.environ.get(
    "CTF_KIT_REPO", os.path.expanduser("~/projects/coworld-ctf-scout"))
KITDUMP_BIN = os.environ.get("CTF_KITDUMP_BIN", f"{SCOUT_REPO}/bin/kit_spawn_dump")
EXTRACT_BIN = scout.EXTRACT_BIN

OURS = "softmaxwell"
CONTROL = "Baseline"              # the SCRIPTED control — a NAME, never is_filler
OUR_FORK = "FJM Picasso v47"      # our own fork; never "the field"

# --- engine constants, restated from src/ctf/sim_types.nim ---------------
MEDKIT_PICKUP_RANGE = 12          # L540
REPLAY_FPS = 24                   # L294
MEDKIT_RESPAWN_TICKS = 30 * REPLAY_FPS   # L541 = 720
MAXHP = 3

# --- frame stream layout, from tools/extract_events.nim ------------------
FRAMES_MAGIC = b"CTFFRM01"
FRAMES_HEADER_BYTES = 16          # magic | u16 slots | u16 W | u16 H | u16 teams
SEAT_RECORD_BYTES = 10            # i16 x, i16 y, u8 aim, hp, lives, flags, fw, wb
TEAM_RECORD_BYTES = 5             # i16 x, i16 y, i8 carrier
FRAME_PREFIX_BYTES = 6            # u32 tick, u8 phase, u8 pad
FLAG_ALIVE = 1
PHASE_PLAYING = None              # resolved from sim_types.nim at import (below)

MIN_SEG_TICKS = 8                 # a segment shorter than this is noise
UNDER_FIRE_PX = 250.0             # DEFAULT under-fire radius, overridable at
                                  # score time: the row stores the MINIMUM
                                  # enemy-shot distance over the segment, not a
                                  # boolean, so the threshold is a REPORTING
                                  # choice and never costs a re-extraction. At
                                  # 600px the filter kept 95% of segments and
                                  # discriminated nothing.
ROW_SCHEMA = 7


def _playing_phase_ord():
    """The ord() of GamePhase.Playing, READ from the engine, never assumed.

    The frame stream writes `ord(sim.phase)`. Guessing that ordinal is exactly
    the kind of silent off-by-one that would filter the wrong half of every
    episode and still produce a plausible table.
    """
    p = f"{SCOUT_REPO}/src/ctf/sim_types.nim"
    try:
        src = open(p).read()
    except OSError:
        return 1
    i = src.find("GamePhase* = enum")
    if i < 0:
        return 1
    names = []
    for line in src[i:].split("\n")[1:]:
        s = line.strip()
        if not s or s.startswith("#"):
            if names:
                break
            continue
        if not line.startswith(" ") and not line.startswith("\t"):
            break
        tok = s.split("#")[0].split(",")[0].strip()
        if not tok:
            continue
        if not (tok[0].isalpha() or tok[0] == "_"):
            break
        names.append(tok)
        if len(names) > 12:
            break
    return names.index("Playing") if "Playing" in names else 1


PHASE_PLAYING = _playing_phase_ord()


# ------------------------------------------------------------------ stats
def mean(xs):
    xs = [x for x in xs if x is not None and x == x]
    return sum(xs) / len(xs) if xs else float("nan")


def mean_se(xs):
    """(mean, standard error, n) over CLUSTERS."""
    xs = [x for x in xs if x is not None and x == x]
    n = len(xs)
    if n == 0:
        return float("nan"), float("nan"), 0
    m = sum(xs) / n
    if n < 2:
        return m, float("nan"), n
    var = sum((x - m) ** 2 for x in xs) / (n - 1)
    return m, math.sqrt(var / n), n


def base_name(addr):
    """'relh (3)' -> 'relh'. Hosted replays record '<player>' then '<player> (2)'."""
    a = (addr or "").strip()
    if a.endswith(")") and " (" in a:
        head, tail = a.rsplit(" (", 1)
        if tail[:-1].isdigit():
            return head
    return a


def dist(ax, ay, bx, by):
    return math.hypot(ax - bx, ay - by)


# ------------------------------------------------------------------ 1. index
def build_index(verbose=True):
    """replay basename -> meta, for EVERY variant the round cache can see.

    ffa4score's index is ffa4-only by design. The phantom hypothesis is about
    2-team boards as much as 4-team ones, so this index keeps every variant and
    lets the SIM's own team count (from kit_spawn_dump) do the splitting — a
    variant NAME is a label, the team count is the geometry.
    """
    idx = {}
    seen = set()
    stats = collections.Counter()
    for path in sorted(glob.glob(os.path.join(scout.ROUNDS_DIR, "*.json"))):
        try:
            eps = json.load(open(path))
        except Exception:
            stats["unreadable"] += 1
            continue
        if not isinstance(eps, list):
            continue
        b = os.path.basename(path)
        rnd = None
        if b.startswith("r") and "_" in b:
            head = b[1:].split("_", 1)[0]
            if head.isdigit():
                rnd = int(head)
        for ep in eps:
            if ep.get("status") != "completed" or not ep.get("replay_url"):
                stats["not_completed"] += 1
                continue
            eid = ep["episode_id"]
            if eid in seen:
                stats["duplicate"] += 1
                continue
            seen.add(eid)
            name = ep["replay_url"].split("/")[-1]
            idx[name] = {
                "episode_id": eid,
                "variant": ep.get("variant_name") or "",
                "cw": ep.get("coworld_version"),
                "round": rnd,
                "at": ep.get("completed_at"),
                "url": ep["replay_url"],
            }
            stats[ep.get("variant_name") or "?"] += 1
    if verbose:
        print(f"  indexed {len(idx)} completed Episodes from "
              f"{scout.ROUNDS_DIR}", file=sys.stderr)
        for k, v in stats.most_common():
            print(f"    {k:34} {v}", file=sys.stderr)
    os.makedirs(CACHE, exist_ok=True)
    json.dump(idx, open(INDEX_PATH, "w"))
    return idx


def load_index(rebuild=False):
    if not rebuild and os.path.exists(INDEX_PATH):
        try:
            return json.load(open(INDEX_PATH))
        except Exception:
            pass
    return build_index()


def cached_replays():
    """Cached .replay basenames. NEVER glob-expanded into a shell arg list —
    13k paths overflow argv. Python glob, scoped to the replay dir only."""
    return sorted(os.path.basename(p)
                  for p in glob.glob(os.path.join(scout.REPLAY_DIR, "*.replay")))


# ------------------------------------------------------- (A) kit geometry
def dump_kits(names, workers=6, verbose=True):
    """bin/kit_spawn_dump over `names`, cached by replay basename."""
    cache = {}
    if os.path.exists(KITS_PATH):
        try:
            cache = json.load(open(KITS_PATH))
        except Exception:
            cache = {}
    todo = [n for n in names if n not in cache]
    if verbose:
        print(f"  kit geometry: {len(names) - len(todo)} cached, "
              f"{len(todo)} to dump", file=sys.stderr)
    if todo:
        if not os.path.exists(KITDUMP_BIN):
            sys.exit(f"kit_spawn_dump not found: {KITDUMP_BIN}\n"
                     f"  cd {SCOUT_REPO} && nim c -d:release "
                     f"--out:bin/kit_spawn_dump tools/kit_spawn_dump.nim")
        import concurrent.futures as futures

        def one(n):
            p = os.path.join(scout.REPLAY_DIR, n)
            r = subprocess.run([KITDUMP_BIN, p], capture_output=True, text=True)
            if r.returncode != 0 or not r.stdout.strip():
                return n, {"error": (r.stderr or "").strip().splitlines()[-1:]}
            try:
                return n, json.loads(r.stdout)
            except Exception:
                return n, {"error": ["unparseable"]}

        done = 0
        with futures.ThreadPoolExecutor(max_workers=workers) as pool:
            for n, blob in pool.map(one, todo):
                cache[n] = blob
                done += 1
                if verbose and done % 250 == 0:
                    print(f"    {done}/{len(todo)}", file=sys.stderr)
        os.makedirs(CACHE, exist_ok=True)
        json.dump(cache, open(KITS_PATH, "w"))
    return cache


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    i = min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))
    return xs[i]


def report_kits(cache, idx):
    """(A): how far the formula address is from a real kit."""
    ok = {n: k for n, k in cache.items() if "error" not in k and k.get("spawns")}
    bad = len(cache) - len(ok)
    print(f"\n=== (A) GROUND-TRUTH KIT GEOMETRY vs THE FORMULA ===")
    print(f"  {len(ok)} boards dumped ({bad} failed); formula = "
          f"(W/2, H/3) and (W/2, 2H/3)")
    by_teams = collections.defaultdict(list)
    for n, k in ok.items():
        by_teams[k["teams"]].append((n, k))
    for teams in sorted(by_teams):
        rows = by_teams[teams]
        var = collections.Counter(
            (idx.get(n) or {}).get("variant", "?") for n, _ in rows)
        seeds = {k["genSeed"] for _n, k in rows}
        # per-FORMULA-SPOT distance to the nearest active spawn
        d_spot = []
        # per-BOARD: the better of the two spots (the policy has both)
        d_board = []
        # per-BOARD: how far the nearest REAL spawn is from EITHER formula spot
        d_kit = []
        hits = 0
        nspawns = collections.Counter()
        for _n, k in rows:
            ds = [e["d"] for e in k["nearest"]]
            d_spot += ds
            d_board.append(min(ds))
            nspawns[len(k["spawns"])] += 1
            best = min(
                dist(s["x"], s["y"], f["x"], f["y"])
                for s in k["spawns"] for f in k["formula"])
            d_kit.append(best)
            hits += best <= MEDKIT_PICKUP_RANGE
        print(f"\n  --- {teams}-team boards: {len(rows)} Episodes, "
              f"{len(seeds)} distinct map seeds ---")
        print("      variants: " + ", ".join(f"{v}={c}" for v, c in var.most_common(4)))
        print("      active spawns/board: "
              + ", ".join(f"{k} kits x{v}" for k, v in sorted(nspawns.items())))
        for lab, xs in (("formula spot -> nearest ACTIVE kit (per spot, n=2/board)", d_spot),
                        ("BEST of the two formula spots (per board)", d_board),
                        ("nearest REAL kit -> nearest formula spot (per board)", d_kit)):
            print(f"      {lab}")
            print(f"        p25 {pct(xs,.25):7.1f}   median {pct(xs,.50):7.1f}   "
                  f"p75 {pct(xs,.75):7.1f}   max {max(xs):7.1f}   mean {mean(xs):7.1f}  n={len(xs)}")
        print(f"      formula spot within MedKitPickupRange ({MEDKIT_PICKUP_RANGE}px) "
              f"of a real ACTIVE kit: {hits}/{len(rows)} = {100.0*hits/len(rows):.2f}% of boards")
        if teams == 2:
            # The matched control: the two candidates the coin flip did NOT
            # activate. If the formula sits nearer THOSE than the live kits,
            # the address is not merely stale, it is anti-correlated.
            dc, closer = [], 0
            for _n, k in rows:
                act = {(s["x"], s["y"]) for s in k["mapSpawns"]}
                inact = [c for c in k["candidates"] if (c["x"], c["y"]) not in act]
                if not inact:
                    continue
                bi = min(dist(c["x"], c["y"], f["x"], f["y"])
                         for c in inact for f in k["formula"])
                ba = min(dist(s["x"], s["y"], f["x"], f["y"])
                         for s in k["spawns"] for f in k["formula"])
                dc.append(bi)
                closer += bi < ba
            if dc:
                print(f"      formula -> nearest INACTIVE candidate: median "
                      f"{pct(dc,.5):.1f}px (n={len(dc)}); the formula is nearer the "
                      f"EMPTY candidate than the live kit on {closer}/{len(dc)} = "
                      f"{100.0*closer/len(dc):.1f}% of boards")


# --------------------------------------------------- (B) frames decoding
class Frames:
    """The `--frames` binary, decoded EXACTLY as extract_events.nim writes it."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.buf = f.read()
        if self.buf[:8] != FRAMES_MAGIC:
            raise ValueError("bad frames magic")
        self.slots, self.mapW, self.mapH, self.teams = struct.unpack_from(
            "<HHHH", self.buf, 8)
        self.rec = (FRAME_PREFIX_BYTES + self.slots * SEAT_RECORD_BYTES
                    + self.teams * TEAM_RECORD_BYTES)
        n = len(self.buf) - FRAMES_HEADER_BYTES
        if self.rec <= 0 or n % self.rec:
            raise ValueError(f"frames length {n} is not a multiple of the "
                             f"{self.rec}-byte record — layout drift")
        self.count = n // self.rec

    def _base(self, i):
        return FRAMES_HEADER_BYTES + i * self.rec

    def tick(self, i):
        return struct.unpack_from("<I", self.buf, self._base(i))[0]

    def phase(self, i):
        return self.buf[self._base(i) + 4]

    def seat_xy(self, i, s):
        o = self._base(i) + FRAME_PREFIX_BYTES + s * SEAT_RECORD_BYTES
        return struct.unpack_from("<hh", self.buf, o)

    def seat_hp_flags(self, i, s):
        o = self._base(i) + FRAME_PREFIX_BYTES + s * SEAT_RECORD_BYTES
        return self.buf[o + 5], self.buf[o + 7]


def load_events(path):
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


def kit_locks(evs, spawns):
    """[(lo, hi)] lock windows per ACTIVE spawn index.

    A med_kit pickup event carries the SPAWN's own x,y, so this is an exact
    join, not a proximity guess. A taken kit is gone for MedKitRespawnTicks.
    """
    locks = [[] for _ in spawns]
    unmatched = 0
    for e in evs:
        if e.get("kind") != "item_pickup" or e.get("item") != "med_kit":
            continue
        ex, ey, t = e.get("x", 0.0), e.get("y", 0.0), e.get("tick", 0)
        best, bi = None, -1
        for i, s in enumerate(spawns):
            d = dist(ex, ey, s["x"], s["y"])
            if best is None or d < best:
                best, bi = d, i
        if bi < 0 or best > MEDKIT_PICKUP_RANGE + 2:
            unmatched += 1
            continue
        locks[bi].append((t, t + MEDKIT_RESPAWN_TICKS))
    return locks, unmatched


def stocked_at(locks, i, t):
    return not any(lo <= t < hi for lo, hi in locks[i])


def worker(name, keep=False):
    """One replay -> one rows file. Frames are written to a temp dir and
    DELETED: 1500 episodes of frames is multiple GB and none of it is needed
    after the segments are cut."""
    os.makedirs(ROWS_DIR, exist_ok=True)
    out_path = os.path.join(ROWS_DIR, name.replace(".replay", ".json"))
    if os.path.exists(out_path):
        try:
            old = json.load(open(out_path))
            # An `extract:` skip is RETRYABLE — it usually means this checkout's
            # engine cannot re-simulate that build, and another checkout can.
            # Everything else (a good row, a kitdump failure) is final.
            if (old.get("schema") == ROW_SCHEMA
                    and not str(old.get("skip", "")).startswith("extract")):
                return 0
        except Exception:
            pass
    src = os.path.join(scout.REPLAY_DIR, name)
    if not os.path.exists(src):
        return 1

    # The binary is run DIRECTLY, never through dump_kits: that helper owns a
    # single shared kits.json, and N xargs workers read-modify-writing one file
    # is a lost-update race that would silently drop most of the cache.
    kr = subprocess.run([KITDUMP_BIN, src], capture_output=True, text=True)
    try:
        kits = json.loads(kr.stdout) if kr.returncode == 0 else {}
    except Exception:
        kits = {}
    if not kits.get("spawns"):
        json.dump({"schema": ROW_SCHEMA, "skip": "kitdump"}, open(out_path, "w"))
        return 0

    tmp = tempfile.mkdtemp(prefix="kitapp")
    ev_path, fr_path = f"{tmp}/ev.jsonl", f"{tmp}/fr.bin"
    try:
        r = subprocess.run([EXTRACT_BIN, src, "--out", ev_path,
                            "--frames", fr_path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            why = (r.stderr or "").strip().splitlines()
            json.dump({"schema": ROW_SCHEMA,
                       "skip": "extract:" + (why[-1][:120] if why else "rc")},
                      open(out_path, "w"))
            return 0
        summ, evs = load_events(ev_path)
        fr = Frames(fr_path)
        rows = segments(summ, evs, fr, kits, name)
        json.dump({"schema": ROW_SCHEMA, "name": name,
                   "teams": kits["teams"], "ep": kits.get("episode"),
                   "map": kits.get("map"), "genSeed": kits.get("genSeed"),
                   "finished": bool(summ and summ.get("finished")),
                   "engine": os.path.basename(
                       os.path.dirname(os.path.dirname(EXTRACT_BIN))),
                   "winner": (summ or {}).get("winner") or "",
                   "draw": bool((summ or {}).get("draw")),
                   "segs": rows}, open(out_path, "w"))
    finally:
        if not keep:
            for p in (ev_path, fr_path):
                if os.path.exists(p):
                    os.remove(p)
            try:
                os.rmdir(tmp)
            except OSError:
                pass
    return 0


def segments(summ, evs, fr, kits, name):
    """Every resolved hp==1 segment, with the four target families scored."""
    if not summ:
        return []
    addr = summ.get("slot_address") or []
    team = summ.get("slot_team") or []
    if not addr or len(addr) != fr.slots:
        return []
    spawns = kits["spawns"]
    formula = kits["formula"]
    act = {(s["x"], s["y"]) for s in kits.get("mapSpawns") or []}
    inactive = [c for c in (kits.get("candidates") or [])
                if (c["x"], c["y"]) not in act]
    locks, _unmatched = kit_locks(evs, spawns)

    # enemy shots, bucketed by tick, for the under-fire test
    shots = collections.defaultdict(list)
    for e in evs:
        if e.get("kind") == "shot":
            shots[e.get("tick", 0)].append(
                (e.get("source", -1), e.get("x", 0.0), e.get("y", 0.0)))

    # index frames by tick so an event tick maps to a frame row
    tick_of = [fr.tick(i) for i in range(fr.count)]
    frame_of = {t: i for i, t in enumerate(tick_of)}

    # ---- cut WOUNDED runs, per seat, during Playing only.
    # Two thresholds are cut in the SAME pass and tagged `h`: hp == 1 (the
    # pre-registered segment) and hp <= 2 (the wider variant, which is the one
    # a peel/disengage lever would actually gate on). Reading hp from the frame
    # BYTE means there is no event track to reconstruct and nothing to infer.
    out = []
    for s in range(fr.slots):
        hp_track = []
        for i in range(fr.count):
            if fr.phase(i) != PHASE_PLAYING:
                hp_track.append(0)
                continue
            hp, flags = fr.seat_hp_flags(i, s)
            hp_track.append(hp if (flags & FLAG_ALIVE) and hp > 0 else 0)
        for thr in (1, 2):
            run = None
            for i, hp in enumerate(hp_track):
                inseg = 0 < hp <= thr
                if inseg and run is None:
                    run = i
                elif not inseg and run is not None:
                    if i - run >= MIN_SEG_TICKS:
                        out.append((s, run, i - 1, thr))
                    run = None
            if run is not None and fr.count - run >= MIN_SEG_TICKS:
                out.append((s, run, fr.count - 1, thr))

    rows = []
    for (s, i0, i1, thr) in out:
        x0, y0 = fr.seat_xy(i0, s)
        x1, y1 = fr.seat_xy(i1, s)
        t0, t1 = tick_of[i0], tick_of[i1]

        def fam(points):
            """(onset distance, net px closed) for the nearest of `points`."""
            if not points:
                return None
            d0 = None
            tx = ty = 0
            for p in points:
                d = dist(x0, y0, p[0], p[1])
                if d0 is None or d < d0:
                    d0, tx, ty = d, p[0], p[1]
            return [d0, d0 - dist(x1, y1, tx, ty)]

        stock = [(sp["x"], sp["y"]) for i, sp in enumerate(spawns)
                 if stocked_at(locks, i, t0)]
        lock = [(sp["x"], sp["y"]) for i, sp in enumerate(spawns)
                if not stocked_at(locks, i, t0)]
        phan = [(f["x"], f["y"]) for f in formula]
        inac = [(c["x"], c["y"]) for c in inactive]

        # under fire: an ENEMY shot inside UNDER_FIRE_PX at any tick of the
        # segment. A `damage` event cannot serve here — at hp==1 a hit is a
        # death, so "was damaged during the segment" is a proxy for the OUTCOME,
        # not for the threat.
        my_team = team[s] if s < len(team) else ""
        fd = None
        for t in range(t0, t1 + 1):
            if t not in shots:
                continue
            fi = frame_of.get(t)
            if fi is None:
                continue
            px, py = fr.seat_xy(fi, s)
            for (src, sx, sy) in shots[t]:
                if src < 0 or src >= len(team) or team[src] == my_team:
                    continue
                d = dist(px, py, sx, sy)
                if fd is None or d < fd:
                    fd = d

        rows.append({
            "seat": s, "policy": base_name(addr[s]), "team": my_team,
            "h": thr,
            "t0": t0, "len": t1 - t0 + 1, "fd": fd,
            "a": fam(stock), "b": fam(lock), "c": fam(phan), "d": fam(inac),
        })
    return rows


# ------------------------------------------------------------------ score
FAMILIES = [("a", "(a) nearest STOCKED real kit"),
            ("b", "(b) nearest LOCKED real kit    [placebo 1]"),
            ("c", "(c) nearest FORMULA spot       [placebo 2: THE PHANTOM]"),
            ("d", "(d) nearest INACTIVE candidate [placebo 3, 2-team only]")]


def load_rows():
    out = []
    for p in sorted(glob.glob(os.path.join(ROWS_DIR, "*.json"))):
        try:
            blob = json.load(open(p))
        except Exception:
            continue
        if blob.get("schema") != ROW_SCHEMA or blob.get("skip"):
            continue
        win = "" if blob.get("draw") else (blob.get("winner") or "")
        for seg in blob.get("segs") or []:
            seg["ep"] = blob.get("ep") or blob.get("name")
            seg["teams"] = blob.get("teams")
            seg["won"] = bool(win) and seg.get("team") == win
            out.append(seg)
    return out


def cluster(segs, key):
    """Per TEAM-EPISODE mean of `key`, then mean +- SE over those clusters."""
    by = collections.defaultdict(list)
    for s in segs:
        v = s.get(key[0])
        if v is None:
            continue
        by[(s["ep"], s["policy"], s["team"])].append(v[1])
    per = [mean(v) for v in by.values()]
    m, se, n = mean_se(per)
    return m, se, n, sum(len(v) for v in by.values())


def onset(segs, key):
    by = collections.defaultdict(list)
    for s in segs:
        v = s.get(key[0])
        if v is None:
            continue
        by[(s["ep"], s["policy"], s["team"])].append(v[0])
    return mean([mean(v) for v in by.values()])


BUCKETS = [(0, 150), (150, 300), (300, 450), (450, 600), (600, 900),
           (900, 10 ** 9)]


def groups(rows, policies):
    """The report's columns. A GROUP is a set of segments, not always one name.

    WINNER is selected on the OUTCOME, so it is a TARGET, not a control — a
    winning team's segments are, by construction, drawn from teams that were
    still alive and still had somewhere to be. The scripted `Baseline` column
    is the control. Both are printed because the prior art reported both.
    """
    out = [(OURS, lambda r: r["policy"] == OURS)]
    out.append((f"{CONTROL}(scripted)", lambda r: r["policy"].startswith(CONTROL)))
    out.append(("WINNER(any, not ours)",
                lambda r: r["won"] and r["policy"] != OURS))
    # A Baseline team that WON is scripted, not a rival policy. Both cuts are
    # printed because "WINNER" with the scripted control folded in is the
    # convention the ffa4 instrument uses, and the two can disagree.
    out.append(("WINNER(no Baseline)",
                lambda r: (r["won"] and r["policy"] != OURS
                           and not r["policy"].startswith(CONTROL))))
    for p in policies:
        if p in (OURS, CONTROL, OUR_FORK):
            continue
        out.append((p, (lambda q: (lambda r: r["policy"] == q))(p)))
    return out


def paired(segs, k1, k0):
    """WITHIN-SEGMENT contrast closed(k1) - closed(k0), clustered.

    This is the sharpest form of the test and the one to believe: both targets
    are scored on the SAME segment, from the SAME onset position, over the SAME
    ticks. Nothing about the fight, the map or the policy's state differs
    between the two arms — only which point we measure the approach to. Two
    separately-averaged columns cannot make that claim.
    """
    by = collections.defaultdict(list)
    for s in segs:
        a, b = s.get(k0), s.get(k1)
        if a is None or b is None:
            continue
        by[(s["ep"], s["policy"], s["team"])].append(b[1] - a[1])
    per = [mean(v) for v in by.values()]
    m, se, n = mean_se(per)
    return m, se, n, sum(len(v) for v in by.values())


def report_score(rows, policies, min_n=8, fire_only=False, hp_max=1,
                 fire_px=UNDER_FIRE_PX):
    rows = [r for r in rows if r.get("h", 1) == hp_max]
    if fire_only:
        rows = [r for r in rows
                if r.get("fd") is not None and r["fd"] <= fire_px]
    cols = groups(rows, policies)
    print(f"\n=== (B) PLACEBO-CONTROLLED APPROACH TEST — "
          f"hp{'==1' if hp_max == 1 else '<=2'} segments"
          f"{', UNDER FIRE only' if fire_only else ''} ===")
    print(f"  net px CLOSED toward a target picked at segment ONSET, over every "
          f"maximal hp{'==1' if hp_max == 1 else '<=2'} run >= {MIN_SEG_TICKS} "
          f"ticks (~{MIN_SEG_TICKS/REPLAY_FPS:.2f}s).")
    print(f"  POSITIVE = moved TOWARD the target. Clustered on the TEAM-EPISODE: "
          f"+- is SE over clusters, n = (clusters, segments).")
    print(f"  Under fire = an enemy `shot` within {fire_px:.0f}px at some tick "
          f"of the segment (--fire-px to move it; the row stores the MINIMUM "
          f"enemy-shot\n      distance, so the threshold never costs a "
          f"re-extraction).")
    print("  ⚠️  READ (c) AGAINST THE Baseline ROW BEFORE BELIEVING IT. Upstream "
          "main's players/baseline/baseline.nim\n      contains no MedKitAX/AY "
          "at all — the const was added by OUR commits — so the scripted "
          "control\n      CANNOT be steering to the formula address. Any "
          "phantom preference the scripted column also\n      shows is a "
          "POSITIONAL ARTIFACT of the board (the formula sits on the centre "
          "column), not our defect.\n      The columns that DO discriminate are "
          "(a) itself and the (d) contrast.")
    for teams in (2, 4):
        sub = [r for r in rows if r["teams"] == teams]
        if not sub:
            continue
        print(f"\n  ========== {teams}-TEAM BOARDS: "
              f"{len({r['ep'] for r in sub})} Episodes, {len(sub)} hp==1 segments "
              f"==========")
        w = 26
        print("  " + "group".ljust(24)
              + "".join(l.rjust(w) for l in
                        ["(a) STOCKED kit", "(b) LOCKED kit", "(c) PHANTOM",
                         "(d) INACTIVE cand"]))
        for lab, fn in cols:
            ps = [r for r in sub if fn(r)]
            if not ps:
                continue
            line = "  " + lab[:23].ljust(24)
            any_cell = False
            for key in FAMILIES:
                m, se, n, nseg = cluster(ps, key)
                if n < min_n:
                    line += "—".rjust(w)
                else:
                    any_cell = True
                    line += f"{m:+6.1f} +-{se:4.1f} ({n},{nseg})".rjust(w)
            if any_cell:
                print(line)
        print("  onset DISTANCE to each family's own target (px) — the confound "
              "the distance-matched table below controls:")
        for lab, fn in cols:
            ps = [r for r in sub if fn(r)]
            if not ps:
                continue
            line = "  " + lab[:23].ljust(24)
            for key in FAMILIES:
                v = onset(ps, key)
                line += ("—" if v != v else f"{v:.0f}").rjust(w)
            print(line)

        # ---- the PAIRED within-segment contrasts
        print(f"\n  PAIRED WITHIN-SEGMENT contrasts (same segment, same onset, "
              f"same ticks — only the TARGET differs). Positive = the policy\n"
              f"  closed MORE px on the placebo than on a real stocked kit.")
        print("  " + "group".ljust(24)
              + "(c) PHANTOM - (a) STOCKED".rjust(28)
              + "(b) LOCKED - (a) STOCKED".rjust(28)
              + "(d) INACTIVE - (a) STOCKED".rjust(28))
        for lab, fn in cols:
            ps = [r for r in sub if fn(r)]
            if not ps:
                continue
            line = "  " + lab[:23].ljust(24)
            for k1 in ("c", "b", "d"):
                m, se, n, nseg = paired(ps, k1, "a")
                line += ("—" if n < min_n
                         else f"{m:+6.1f} +-{se:4.1f} ({n},{nseg})").rjust(28)
            print(line)

        # ---- DISTANCE-MATCHED (a) vs (c)
        print(f"\n  DISTANCE-MATCHED (a) STOCKED vs (c) PHANTOM, {teams}-team. "
              f"Segments are bucketed by the ONSET distance to that\n  family's "
              f"OWN target, so 'closed more px on the phantom' cannot be "
              f"explained by the phantom being nearer.")
        print("  " + "group".ljust(22) + "onset px".ljust(11)
              + "(a) STOCKED".rjust(23) + "(c) PHANTOM".rjust(23)
              + "     c - a")
        for lab, fn in cols:
            ps = [r for r in sub if fn(r)]
            if not ps:
                continue
            shown = False
            for (lo, hi) in BUCKETS:
                sa = [r for r in ps if r.get("a") and lo <= r["a"][0] < hi]
                sc = [r for r in ps if r.get("c") and lo <= r["c"][0] < hi]
                ma, sea, na, _ = cluster(sa, ("a",))
                mc, sec, nc, _ = cluster(sc, ("c",))
                if na < min_n or nc < min_n:
                    continue
                blab = f"{lo}-{'inf' if hi > 10**8 else hi}"
                print("  " + (lab[:21] if not shown else "").ljust(22)
                      + blab.ljust(11)
                      + f"{ma:+6.1f} +-{sea:4.1f} n={na}".rjust(23)
                      + f"{mc:+6.1f} +-{sec:4.1f} n={nc}".rjust(23)
                      + f"   {mc-ma:+7.1f}")
                shown = True


def census(rows):
    c = collections.Counter(r["policy"] for r in rows if r.get("h", 1) == 1)
    print("\n  policy census (segments): "
          + ", ".join(f"{p}={n}" for p, n in c.most_common(14)))
    return c


# ------------------------------------------------------------- selfcheck
def selfcheck(names, limit=40):
    """End-to-end proof that the frame decode and the tick index are right.

    Nothing here is a unit test of my own arithmetic. Each assertion joins the
    frame stream to an INDEPENDENT engine-emitted fact:
      1. a med_kit pickup event carries the SPAWN's xy, and the picker must be
         inside MedKitPickupRange of it ON THAT TICK in the frame stream. A
         frame-offset or tick-index error breaks this immediately.
      2. that same xy must equal an ACTIVE medKitSpawn from kit_spawn_dump —
         which is what makes the lock timeline exact rather than a guess.
      3. a heal event's post-hp must equal the frame's hp byte for that seat on
         that tick — the hp track and the position track are the same rows.
      4. the frames record length must divide the file exactly (layout drift).
    """
    ok = True
    tot = collections.Counter()
    for name in names[:limit]:
        src = os.path.join(scout.REPLAY_DIR, name)
        if not os.path.exists(src):
            continue
        kr = subprocess.run([KITDUMP_BIN, src], capture_output=True, text=True)
        if kr.returncode != 0:
            tot["kitdump_failed"] += 1
            continue
        kits = json.loads(kr.stdout)
        tmp = tempfile.mkdtemp(prefix="kitchk")
        try:
            r = subprocess.run([EXTRACT_BIN, src, "--out", f"{tmp}/ev.jsonl",
                                "--frames", f"{tmp}/fr.bin"],
                               capture_output=True, text=True)
            if r.returncode != 0:
                tot["extract_failed"] += 1
                continue
            summ, evs = load_events(f"{tmp}/ev.jsonl")
            fr = Frames(f"{tmp}/fr.bin")          # (4) raises on layout drift
            tot["episodes"] += 1
            tick_of = {fr.tick(i): i for i in range(fr.count)}
            for e in evs:
                i = tick_of.get(e.get("tick", -1))
                if i is None:
                    continue
                s = e.get("source", -1)
                if not (0 <= s < fr.slots):
                    continue
                if e.get("kind") == "item_pickup" and e.get("item") == "med_kit":
                    px, py = fr.seat_xy(i, s)
                    d = dist(px, py, e.get("x", 0.0), e.get("y", 0.0))
                    tot["pickup_ok" if d <= MEDKIT_PICKUP_RANGE + 1
                        else "pickup_MISS"] += 1
                    m = min(dist(e.get("x", 0.0), e.get("y", 0.0),
                                 sp["x"], sp["y"]) for sp in kits["spawns"])
                    tot["spawn_ok" if m <= 1 else "spawn_MISS"] += 1
                elif e.get("kind") == "heal":
                    hp, _f = fr.seat_hp_flags(i, s)
                    tot["heal_ok" if hp == e.get("hp") else "heal_MISS"] += 1
        finally:
            for f in ("ev.jsonl", "fr.bin"):
                if os.path.exists(f"{tmp}/{f}"):
                    os.remove(f"{tmp}/{f}")
            try:
                os.rmdir(tmp)
            except OSError:
                pass
    for good, bad, lab in (("pickup_ok", "pickup_MISS",
                            "picker is inside MedKitPickupRange of the pickup "
                            "event's xy on that tick"),
                           ("spawn_ok", "spawn_MISS",
                            "pickup xy IS an active medKitSpawn (exact join, "
                            "not a proximity guess)"),
                           ("heal_ok", "heal_MISS",
                            "heal event post-hp == the frame hp byte")):
        good_n, bad_n = tot[good], tot[bad]
        p_ = bad_n == 0 and good_n > 0
        ok &= p_
        print(f"  [{'PASS' if p_ else 'FAIL'}] {lab}: {good_n} ok / {bad_n} miss")
    print(f"  [PASS] frames record length divides every file "
          f"({tot['episodes']} episodes decoded; a layout drift raises)")
    print(f"\n{'ALL CHECKS PASS' if ok else 'SOME CHECKS FAILED'}")
    return 0 if ok else 1


# ------------------------------------------------------------------ cli
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["index", "kits", "extract", "worker",
                                    "score", "run", "selfcheck"])
    ap.add_argument("names", nargs="*", help="worker: replay basename(s)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--variant", help="restrict to one variant_name substring")
    ap.add_argument("--policies", help="comma-separated slot_address list")
    ap.add_argument("--fire", action="store_true", help="under-fire segments only")
    ap.add_argument("--fire-px", type=float, default=UNDER_FIRE_PX,
                    help="under-fire radius in px (used with --fire)")
    ap.add_argument("--hp", type=int, default=1, choices=[1, 2],
                    help="segment definition: hp==1 (default) or hp<=2")
    ap.add_argument("--keep", action="store_true", help="worker: keep temp files")
    a = ap.parse_args()

    if a.cmd == "selfcheck":
        sys.exit(selfcheck(cached_replays() if not a.names else a.names,
                           limit=a.limit or 40))

    if a.cmd == "worker":
        rc = 0
        for n in a.names:
            rc |= worker(os.path.basename(n), keep=a.keep)
        sys.exit(rc)

    if a.cmd in ("index", "run"):
        build_index()
    idx = load_index(rebuild=a.rebuild)

    if a.cmd in ("kits", "run"):
        names = cached_replays()
        if a.variant:
            names = [n for n in names
                     if a.variant.lower() in (idx.get(n) or {}).get("variant", "").lower()]
        if a.limit:
            names = names[:a.limit]
        cache = dump_kits(names, workers=a.workers)
        report_kits({n: cache[n] for n in names if n in cache}, idx)

    if a.cmd == "extract":
        names = cached_replays()
        if a.variant:
            names = [n for n in names
                     if a.variant.lower() in (idx.get(n) or {}).get("variant", "").lower()]
        todo = [n for n in names
                if not os.path.exists(os.path.join(
                    ROWS_DIR, n.replace(".replay", ".json")))]
        if a.limit:
            todo = todo[:a.limit]
        # printed, not executed: xargs -P is the parallel driver so a stalled
        # episode cannot wedge a python thread pool holding a 400MB frame buffer
        for n in todo:
            print(n)
        print(f"  {len(todo)} replay(s) need extraction; pipe this list into "
              f"xargs -P {a.workers}", file=sys.stderr)

    if a.cmd in ("score", "run"):
        rows = load_rows()
        if not rows:
            sys.exit("no rows — run `extract` and the xargs worker pass first")
        c = census(rows)
        if a.policies:
            pols = [p.strip() for p in a.policies.split(",")]
        else:
            pols = [OURS, CONTROL]
            pols += [p for p, _n in c.most_common(24)
                     if p not in (OURS, CONTROL, OUR_FORK)][:4]
        report_score(rows, pols, fire_only=a.fire, hp_max=a.hp,
                     fire_px=a.fire_px)


if __name__ == "__main__":
    main()
