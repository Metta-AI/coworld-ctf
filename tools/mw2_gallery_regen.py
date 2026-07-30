#!/usr/bin/env python3
"""Rebuilds the MW2 map gallery from the REAL tree.

Renders each pack map's painted board art straight out of src/ctf/sim.nim (via
tools/render_map_art.nim) and writes a review page that puts the acquired 2009
reference beside the result, which is the comparison the work is judged on.

Earlier this script spliced snippets into a scratch copy of src/, because six
agents were authoring maps in parallel and could not share sim.nim. The traced
maps are integrated now (tools/mw2_trace.py -> tools/mw2_integrate.py), so the
gallery reads the real tree and a stale scratch copy can no longer show art that
does not match what ships.

Usage: python3 tools/mw2_gallery_regen.py
Serve with: python3 -m http.server 21600 --directory /tmp/mw2-gallery
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GALLERY = Path("/tmp/mw2-gallery")
NIM = Path.home() / ".local/bin/nim"
RENDER = Path("/tmp/mw2-gallery-render")

MAPS = ["rust", "terminal", "highrise", "favela", "afghan", "scrapyard"]

THEME = {
    "rust": ("Rust", "derrick yard, Afghanistan",
             "The tower decides every fight. Oil tanks in the north-east "
             "corner, pipe runs crossing midfield, sniper huts at the far "
             "corners."),
    "terminal": ("Terminal", "airport concourse, Russia",
                 "The 747 sits at ONE end of the concourse, not the middle — "
                 "that asymmetry is the map. Ticket counters, security "
                 "scanners, Burger Town."),
    "highrise": ("Highrise", "office towers, unknown city",
                 "Twin office cores flank the roof with one bridge between "
                 "them. Helipads at either end, construction area and crane "
                 "base."),
    "favela": ("Favela", "hillside slum, Rio de Janeiro",
               "An alley grid nobody holds for long. Dense shanty blocks, the "
               "market square, the red building."),
    "afghan": ("Afghan", "mountain pass, Afghanistan",
               "The crashed C-130 is the spine of the map. Cave arc to one "
               "side, bunker overlook to the other, rock outcrops forming the "
               "mid lanes."),
    "scrapyard": ("Scrapyard", "aircraft boneyard, Georgia",
                  "Fuselage rows between the hangars. MG nest, control tower, "
                  "scrap piles and containers as loose cover."),
}


def build_renderer():
    r = subprocess.run(
        [str(NIM), "c", "-d:release", "--hints:off", f"-o:{RENDER}",
         "tools/render_map_art.nim"],
        cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return "\n".join((r.stdout + r.stderr).splitlines()[-25:])
    return None


def page(status):
    """The review page. One row per map: reference plate, then the result."""
    rows = []
    for i, name in enumerate(MAPS, 1):
        title, place, blurb = THEME[name]
        e = status["maps"][name]
        if not e.get("landed"):
            body = ('<div class="pending">not rendered — '
                    f'{e.get("error", "pending")}</div>')
        else:
            s = e.get("stats") or {}
            checks = [
                ("sealed pockets", s.get("pockets", "?"),
                 s.get("pockets") == 0),
                ("open firing rows", s.get("openRows", "?"),
                 s.get("openRows") == 0),
                ("area parity", f'{s.get("areaRatio", 0):.3f}',
                 s.get("areaRatio", 0) >= 0.80),
                ("cover parity", f'{s.get("coverRatio", 0):.3f}',
                 s.get("coverRatio", 0) >= 0.60),
                ("midfield parity", f'{s.get("midRatio", 0):.3f}',
                 s.get("midRatio", 0) >= 0.70),
            ]
            authored = (f'{s["authored"]} named structures &rarr; '
                        if s.get("authored") else "")
            chips = "".join(
                f'<span class="chip {"ok" if good else "bad"}">'
                f'{label} <b>{val}</b></span>'
                for label, val, good in checks)
            pl = e.get("play")
            playblock = ""
            if pl:
                pchips = "".join(
                    f'<span class="chip {"ok" if good else "bad"}">'
                    f'{lab} <b>{val}</b></span>' for lab, val, good in [
                        ("midfield lanes",
                         f'{pl["lanes"]} ({pl["lanesUsed"]} used)',
                         pl["lanes"] >= 2),
                        # The objective, which is what a CTF map is FOR. Shown
                        # as the ratio rather than a rate: at ~15 steals an
                        # episode set, a bare percentage reads as more precise
                        # than the sample can support.
                        ("steals converted",
                         f'{pl.get("captures", 0)}/{pl.get("steals", 0)}',
                         pl.get("captures", 0) > 0),
                        ("lanes the flag used",
                         f'{pl.get("carryLanes", 0)} of {pl["lanes"]}',
                         pl.get("carryLanes", 0) >= 2),
                        ("floor never walked", f'{pl["deadPct"]:.0%}',
                         pl["deadPct"] <= 0.35),
                        ("median sightline", f'{pl["medianSight"]:.0f}px',
                         pl["medianSight"] <= 255),
                    ])
                notes = "".join(f"<li>{f}</li>" for f in pl["flags"])
                playblock = f"""
      <div class="play">
        <div class="lbl">how it actually played &mdash;
          {pl.get("episodes", 1)} re-simulated episode(s), warm where players
          spent time, pale where nobody went, rings where they died</div>
        <img src="heat-{name}.png" alt="{title} heatmap">
        <div class="chips">{pchips}</div>
        {f'<ul class="gaps">{notes}</ul>' if notes else ''}
      </div>"""
            body = f"""
      <div class="pair">
        <div class="side">
          <div class="lbl">2009 reference — official minimap, oriented to the field</div>
          <img src="ref-{name}.png" alt="{title} reference">
        </div>
        <div class="side">
          <div class="lbl">result — as the spectator sees it</div>
          <img src="{name}.png" alt="{title} rendered">
        </div>
      </div>
      <div class="chips">{chips}</div>
      <p class="facts">{authored}{s.get("shapes", "?")} emitted shapes &middot;
        {s.get("coverage", 0):.1%} of the field is cover &middot; walk to
        midfield {s.get("midRed", "?")}px red / {s.get("midBlue", "?")}px
        blue</p>{playblock}"""
        rows.append(f"""    <figure>
      <div class="head">
        <span class="num">{i:02d}</span>
        <h2>{title}</h2>
        <span class="theme">{place}</span>
      </div>
      <p class="blurb">{blurb}</p>{body}
    </figure>""")

    done = sum(1 for m in MAPS if status["maps"][m].get("landed"))
    err = status.get("buildError")
    banner = f'<p class="err">BUILD FAILED\n{err}</p>' if err else ""
    return f"""<!doctype html>
<meta charset="utf-8">
<title>MW2 Paintball Map Pack — Coworld CTF</title>
<link rel="icon" href="data:,">
<meta http-equiv="refresh" content="30">
<style>
  :root {{
    --ink: #221c16; --ink-soft: #4a4038; --ghost: #8b8078;
    --paper: #f6f2ea; --rule: #ddd5c8;
    --amber: #b5762a; --green: #4f6b3f; --red: #8c3b2a;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 56px 48px 96px;
    background: var(--paper); color: var(--ink);
    font: 15px/1.6 "Iowan Old Style", Georgia, serif;
  }}
  header {{ max-width: 1320px; margin: 0 auto 52px; }}
  h1 {{ margin: 0 0 8px; font-size: 34px; font-weight: 600;
       letter-spacing: -0.01em; }}
  .sub {{ color: var(--ink-soft); max-width: 70ch; margin: 0 0 20px; }}
  .status {{
    display: flex; align-items: baseline; gap: 22px;
    font: 12px/1.5 ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--ghost); letter-spacing: 0.04em; text-transform: uppercase;
  }}
  .status b {{ color: var(--ink-soft); font-weight: 600; }}
  .live {{ color: var(--green); }}
  main {{ max-width: 1320px; margin: 0 auto; }}
  figure {{ margin: 0 0 64px; }}
  .head {{
    display: flex; align-items: baseline; gap: 14px;
    padding-bottom: 8px; border-bottom: 1px solid var(--rule);
  }}
  .num {{ font: 12px/1 ui-monospace, Menlo, monospace; color: var(--amber);
         letter-spacing: 0.08em; padding-top: 5px; }}
  h2 {{ margin: 0; font-size: 22px; font-weight: 600; }}
  .theme {{ color: var(--ghost); font-size: 14px; font-style: italic; }}
  .blurb {{ color: var(--ink-soft); max-width: 84ch; margin: 12px 0 16px; }}
  .pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 22px; }}
  .side .lbl {{
    font: 11px/1.4 ui-monospace, Menlo, monospace; color: var(--ghost);
    letter-spacing: 0.07em; text-transform: uppercase; margin-bottom: 7px;
  }}
  img {{ width: 100%; height: auto; display: block; }}
  .chips {{ display: flex; flex-wrap: wrap; gap: 8px 16px; margin-top: 14px; }}
  .chip {{
    font: 11px/1.5 ui-monospace, Menlo, monospace; color: var(--ghost);
    letter-spacing: 0.04em; text-transform: uppercase;
  }}
  .chip b {{ font-weight: 600; }}
  .chip.ok b {{ color: var(--green); }}
  .chip.bad, .chip.bad b {{ color: var(--red); }}
  .play {{ margin-top: 26px; }}
  .play img {{ max-width: 760px; }}
  .gaps {{ margin: 10px 0 0; padding-left: 18px; color: var(--red);
          font-size: 14px; }}
  .facts {{ margin: 8px 0 0;
           font: 12px/1.7 ui-monospace, Menlo, monospace; color: var(--ghost); }}
  .pending {{
    display: flex; align-items: center; justify-content: center;
    height: 260px; border: 1px dashed var(--rule); color: var(--ghost);
    font: 12px ui-monospace, Menlo, monospace; letter-spacing: 0.06em;
    text-transform: uppercase; margin-top: 14px;
  }}
  .err {{ font: 12px/1.5 ui-monospace, Menlo, monospace; color: var(--red);
         white-space: pre-wrap; }}
</style>
<header>
  <h1>MW2 Paintball Map Pack</h1>
  <p class="sub">
    Six <i>Call of Duty: Modern Warfare 2</i> (2009) maps recreated as top-down
    paintball capture-the-heart arenas. Every structure is <b>measured off that
    map's official 2009 minimap</b> rather than drawn from memory, and each
    layout is used asymmetrically — mirroring would destroy the very geometry
    that makes a map recognizable. Fairness is therefore asserted by test
    rather than bought by construction.
  </p>
  <p class="status">
    <span class="live">{done} / 6 rendered</span>
    <span><b>engine</b> live src/ctf/sim.nim</span>
    <span><b>field</b> per-map (base 1235 &times; 659)</span>
    <span>page refreshes every 30s</span>
  </p>
  {banner}
</header>
<main>
{chr(10).join(rows)}
</main>
"""


def main():
    GALLERY.mkdir(exist_ok=True)
    status = {"maps": {}}
    err = build_renderer()
    if err:
        status["buildError"] = err
        print("BUILD FAILED:\n" + err)

    play_path = GALLERY / "playtest.json"
    play = json.loads(play_path.read_text()) if play_path.exists() else {}
    stats_path = Path("/tmp/mw2trace_stats.json")
    trace_stats = (json.loads(stats_path.read_text())
                   if stats_path.exists() else {})

    for name in MAPS:
        entry = {"landed": False}
        if not err:
            r = subprocess.run([str(RENDER), f"/tmp/gal-{name}.png", name],
                               cwd=ROOT, capture_output=True, text=True)
            if r.returncode == 0:
                subprocess.run(["sips", "-Z", "1100", f"/tmp/gal-{name}.png",
                                "--out", str(GALLERY / f"{name}.png")],
                               capture_output=True)
                plate = (ROOT / "docs/designs/mw2-reference/prepped" /
                         f"{name}.png")
                if plate.exists():
                    subprocess.run(["sips", "-Z", "1100", str(plate), "--out",
                                    str(GALLERY / f"ref-{name}.png")],
                                   capture_output=True)
                entry = {"landed": True, "stats": trace_stats.get(name, {}),
                         "play": play.get(name)}
            else:
                entry["error"] = (r.stderr or r.stdout).strip()[-300:]
        status["maps"][name] = entry

    (GALLERY / "status.json").write_text(json.dumps(status, indent=1))
    (GALLERY / "index.html").write_text(page(status))
    done = sum(1 for m in MAPS if status["maps"][m]["landed"])
    print(f"gallery updated: {done}/{len(MAPS)} maps rendered -> {GALLERY}")
    return 1 if err else 0


if __name__ == "__main__":
    sys.exit(main())
