#!/usr/bin/env python3
"""Builds docs/pool-review.html: a self-contained, zoomable review page for
the curated terrain pool. Reads the PNGs + manifest.json produced by
tools/render_map_pool.nim and inlines everything (base64), so the page works
from a file:// open or any static host.

Usage:
  nim c -r tools/gen_map_pool.nim            # (only when re-curating seeds)
  nim c -r tools/render_map_pool.nim pool-preview
  python3 tools/build_pool_review.py [renderDir] [outHtml]

Defaults: renderDir=pool-preview, outHtml=docs/pool-review.html.
"""
import base64
import json
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
render_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "pool-preview"
out_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else repo / "docs" / "pool-review.html"

manifest = json.loads((render_dir / "manifest.json").read_text())

# Widths of the HEX size classes (ctf/hex.nim HexSizes). The board is a regular
# hexagon inscribed in width x height, portrait, so these replaced the old
# rectangular 1050/1235/1606/2223/3211 set outright. `colossal` is
# override-only and never appears in a random pool draw, but it is listed so an
# override-built pool still labels correctly.
SIZE_NAMES = {824: "small", 969: "standard", 1260: "large",
              1744: "huge", 2519: "giant", 5039: "colossal"}
SIZE_ORDER = ["small", "standard", "large", "huge", "giant", "colossal"]
# Wire tokens from mapSpecJson. `mirror` is the legacy spelling the loader
# still accepts, so an older manifest keeps rendering under the right chip.
SYMMETRIES = ["mirrorHex", "rot180", "rot120", "rot60", "klein4", "mirror"]


def size_name(width):
    """Never KeyError on an unknown width. The old dict raised, which turned a
    board-size change into a crash in a review page — exactly what happened at
    the hex conversion. An unrecognised width is a fact worth SHOWING."""
    return SIZE_NAMES.get(width, f"{width}px")


cards = []
for m in manifest:
    b64 = base64.b64encode((render_dir / m["file"]).read_bytes()).decode()
    size = size_name(m["width"])
    kits = ", ".join(f"({x},{y})" for x, y in m["medKitSpawns"])
    # Every hex endzone is a disc; the variety is in radius and base depth.
    endzone = m.get("endzone", "disc")
    zone_note = f"{endzone} r{m['endzoneRadius']} home x{m['homeX']}"
    if "homeDepth" in m:
        zone_note += f" depth {m['homeDepth']}‰"
    # The pool is curated BY SCORE, so the score is on the card. Interior
    # fraction rides beside it with the control's own figure, because that is
    # the one number the fitness harness measured every pre-ranking pool map
    # as failing (9.9-17.9% against the arena's 32.5% on the square board).
    score_note = ""
    if "score" in m:
        interior = m.get("interiorFrac", 0) * 100
        control_interior = m.get("controlInteriorFrac", 0) * 100
        verdict = "ge" if interior >= control_interior else "lt"
        score_note = (
            f'<span class="chip chip-score">score {m["score"] * 100:.0f}</span>'
            f'<span class="chip chip-{verdict}">interior {interior:.0f}% '
            f'vs arena {control_interior:.0f}%</span>')
    cards.append(f'''
<article class="card" data-size="{size}" data-sym="{m['symmetry']}" data-endzone="{endzone}">
  <header class="card-head">
    <span class="idx">#{m['index']:02d}</span>
    <span class="seed">seed {m['seed']}</span>
    <span class="chip chip-{size}">{size} {m['width']}&times;{m['height']}</span>
    <span class="chip chip-sym">{m['symmetry']}</span>
    <span class="chip chip-sym">{zone_note}</span>
    {score_note}
    <span class="meta">{m['obstacles']} left-half shapes &middot; {m.get('trenches', 0)} trenches &middot; kits {kits}</span>
  </header>
  <div class="viewer" tabindex="0">
    <img src="data:image/png;base64,{b64}" alt="pool map {m['index']} seed {m['seed']}" draggable="false">
  </div>
</article>''')

counts = {}
for m in manifest:
    for key in (size_name(m["width"]), m["symmetry"], m.get("endzone", "disc")):
        counts[key] = counts.get(key, 0) + 1


def tally(keys):
    """Only the buckets that actually occur, in a stable order. A fixed dict of
    every possible bucket had to be edited in lockstep with the enums, and
    missing one raised."""
    return " / ".join(f"{counts[k]} {k}" for k in keys if counts.get(k))


sizes_present = [k for k in SIZE_ORDER if counts.get(k)]
sizes_present += sorted(
    k for k in counts if k not in SIZE_ORDER and k.endswith("px"))
syms_present = [k for k in SYMMETRIES if counts.get(k)]
zones_present = sorted(k for k in counts
                       if k not in SIZE_ORDER and k not in SYMMETRIES
                       and not k.endswith("px"))
summary = " &middot; ".join(part for part in (
    tally(sizes_present), tally(syms_present),
    tally(zones_present) + " endzones" if zones_present else "") if part)

# The headline the curation change has to answer for: how many of these
# maps are at least as ENCLOSED as the arena. Pre-ranking the answer was
# zero — every pool map measured flatter than the control.
score_summary = ""
scored = [m for m in manifest if "score" in m]
if scored:
    beats = sum(1 for m in scored
                if m.get("interiorFrac", 0) >= m.get("controlInteriorFrac", 1))
    lo = min(m["score"] for m in scored) * 100
    hi = max(m["score"] for m in scored) * 100
    score_summary = (f" &middot; score {lo:.0f}&ndash;{hi:.0f} vs the arena "
                     f"&middot; {beats}/{len(scored)} at least as enclosed "
                     f"as the arena")
filter_buttons = "\n    ".join(
    f'<button data-f="{group}:{name}" aria-pressed="false">{name}</button>'
    for group, names in (("size", sizes_present), ("sym", syms_present),
                         ("endzone", zones_present))
    for name in names)

html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CTF Terrain Pool</title>
<style>
:root {{
  --ground:#1a1410; --panel:#241c15; --line:#3a2e21;
  --ink:#e8dcc8; --muted:#9a8a70;
  --glass:#50dcff; --red:#d24238; --blue:#4a78dc;
}}
* {{ box-sizing:border-box; }}
body {{ background:var(--ground); color:var(--ink);
  font:15px/1.5 system-ui,-apple-system,sans-serif; margin:0; padding:0 0 4rem; }}
.wrap {{ max-width:1500px; margin:0 auto; padding:0 1.25rem; }}
header.top {{ position:sticky; top:0; z-index:5; background:color-mix(in srgb,var(--ground) 92%,transparent);
  backdrop-filter:blur(6px); border-bottom:1px solid var(--line); padding:.7rem 0 .6rem; margin-bottom:1.2rem; }}
h1 {{ font-size:1.05rem; margin:0; letter-spacing:.02em; display:inline; }}
h1 .gv {{ color:var(--glass); }}
.sub {{ color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin-left:.8rem; }}
.filters {{ float:right; display:flex; gap:.4rem; }}
.filters button {{ background:var(--panel); color:var(--ink); border:1px solid var(--line);
  border-radius:3px; font:12px ui-monospace,Menlo,monospace; padding:.25rem .6rem; cursor:pointer; }}
.filters button[aria-pressed="true"] {{ border-color:var(--glass); color:var(--glass); }}
.legend {{ display:flex; flex-wrap:wrap; gap:1rem; font:12px ui-monospace,Menlo,monospace;
  color:var(--muted); margin:0 0 1.2rem; }}
.legend b {{ display:inline-block; width:11px; height:11px; margin-right:.35rem; vertical-align:-1px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(620px,1fr)); gap:1.2rem; }}
.card {{ background:var(--panel); border:1px solid var(--line); border-radius:4px; overflow:hidden; }}
.card.hidden {{ display:none; }}
.card-head {{ display:flex; align-items:baseline; gap:.65rem; padding:.5rem .75rem;
  font:12px ui-monospace,Menlo,monospace; border-bottom:1px solid var(--line); flex-wrap:wrap; }}
.idx {{ color:var(--glass); font-weight:700; }}
.seed {{ font-weight:700; }}
.chip {{ border:1px solid var(--line); border-radius:2px; padding:0 .4rem; color:var(--muted); }}
.chip-sym {{ color:var(--ink); }}
.chip-score {{ color:var(--ink); font-weight:700; }}
/* Interior fraction against the CONTROL's own reading: the discriminator
   the fitness harness measured every pre-ranking pool map as failing. */
.chip-ge {{ color:#7fbf7f; border-color:#7fbf7f; }}
.chip-lt {{ color:#c98a5a; border-color:#c98a5a; }}
.meta {{ color:var(--muted); margin-left:auto; }}
.viewer {{ position:relative; height:420px; overflow:hidden; cursor:grab; background:#0f0b08; }}
.viewer:active {{ cursor:grabbing; }}
.viewer img {{ position:absolute; transform-origin:0 0; image-rendering:pixelated;
  user-select:none; -webkit-user-drag:none; }}
.hint {{ text-align:center; color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin:.9rem 0 1.1rem; }}
</style>
</head>
<body>
<div class="wrap">
<header class="top"><div>
  <h1>CTF terrain pool <span class="gv">config-gated (mapPath "pool")</span></h1>
  <span class="sub">{len(manifest)} maps &middot; {summary}{score_summary}</span>
  <span class="filters">
    {filter_buttons}
  </span>
</div></header>
<p class="hint">scroll to zoom &middot; drag to pan &middot; double-click to reset &middot; filters narrow the grid &middot; regenerate: tools/render_map_pool.nim + tools/build_pool_review.py</p>
<div class="legend">
  <span><b style="background:#40301f"></b>stone</span>
  <span><b style="background:#50dcff"></b>glass window (blocks movement/fire, fog sees through)</span>
  <span><b style="background:#40301f"></b>the six corners outside the hexagonal hull (permanent void, collided as stone)</span>
  <span><b style="background:#e2cdac"></b>protected floor (never carved: the center ring + each team's endzone DISC around a base set back from the hull)</span>
  <span><b style="background:#d24238"></b>active med-kit pair / red pedestal</span>
  <span><b style="background:#78644e"></b>idle med-kit candidates</span>
  <span><b style="background:#4a78dc"></b>blue pedestal</span>
</div>
<div class="grid">
{''.join(cards)}
</div>
</div>
<script>
document.querySelectorAll('.viewer').forEach(v => {{
  const img = v.querySelector('img');
  let s, tx, ty, dragging = false, lx = 0, ly = 0;
  function fit() {{
    const iw = img.naturalWidth, ih = img.naturalHeight;
    s = Math.min(v.clientWidth / iw, v.clientHeight / ih);
    tx = (v.clientWidth - iw * s) / 2; ty = (v.clientHeight - ih * s) / 2;
    apply();
  }}
  function apply() {{
    img.style.transform = `translate(${{tx}}px,${{ty}}px) scale(${{s}})`;
  }}
  if (img.complete) fit(); else img.onload = fit;
  window.addEventListener('resize', fit);
  v.addEventListener('dblclick', fit);
  v.addEventListener('wheel', e => {{
    e.preventDefault();
    const r = v.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const k = Math.exp(-e.deltaY * 0.0015);
    const ns = Math.min(Math.max(s * k, 0.1), 12);
    tx = mx - (mx - tx) * (ns / s); ty = my - (my - ty) * (ns / s);
    s = ns; apply();
  }}, {{ passive: false }});
  v.addEventListener('pointerdown', e => {{
    dragging = true; lx = e.clientX; ly = e.clientY; v.setPointerCapture(e.pointerId);
  }});
  v.addEventListener('pointermove', e => {{
    if (!dragging) return;
    tx += e.clientX - lx; ty += e.clientY - ly; lx = e.clientX; ly = e.clientY; apply();
  }});
  v.addEventListener('pointerup', () => dragging = false);
}});
const active = {{ size: null, sym: null, endzone: null }};
document.querySelectorAll('.filters button').forEach(b => {{
  b.addEventListener('click', () => {{
    const [k, val] = b.dataset.f.split(':');
    active[k] = active[k] === val ? null : val;
    document.querySelectorAll('.filters button').forEach(o => {{
      const [ok, ov] = o.dataset.f.split(':');
      o.setAttribute('aria-pressed', String(active[ok] === ov));
    }});
    document.querySelectorAll('.card').forEach(c => {{
      const okSize = !active.size || c.dataset.size === active.size;
      const okSym = !active.sym || c.dataset.sym === active.sym;
      const okZone = !active.endzone || c.dataset.endzone === active.endzone;
      c.classList.toggle('hidden', !(okSize && okSym && okZone));
    }});
  }});
}});
</script>
</body>
</html>
'''
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(html)
print(f"wrote {out_path} ({len(html)} bytes, {len(manifest)} maps)")
