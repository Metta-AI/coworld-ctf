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


def size_of(entry):
    """The map's size class, named by Nim in the manifest.

    This used to be a width -> name dict living here, which meant the review
    page KeyError'd on any width it had not been told about and a new size
    class could not ship. The canonical table is
    src/ctf/map_rules.nim MapSizeClassTable; tools/render_map_pool.nim reads
    it and writes the resolved name into the manifest, so this file now has
    no map knowledge at all.
    """
    name = entry.get("sizeClass")
    if not name:
        raise SystemExit(
            f"manifest entry {entry.get('index', '?')} has no 'sizeClass'. "
            "Re-render with a current tools/render_map_pool.nim:\n"
            f"  nim c -r tools/render_map_pool.nim {render_dir}")
    return name


# Every class, symmetry and endzone the manifest actually contains — so a class
# added to the Nim table shows up in the summary line and the filter bar
# without touching this file. Sizes order by the width they were rendered at
# (small -> colossal, derived from the data rather than from a list here);
# the rest order alphabetically.
def observed(key_fn, sort_key=None):
    seen = {}
    for entry in manifest:
        value = key_fn(entry)
        seen.setdefault(value, entry)
    order = sort_key or (lambda kv: kv[0])
    return [k for k, _ in sorted(seen.items(), key=order)]


sizes = observed(size_of, sort_key=lambda kv: kv[1]["width"])
symmetries = observed(lambda m: m["symmetry"])
endzones = observed(lambda m: m.get("endzone", "column"))
biomes = observed(lambda m: m.get("biome", "arena"))

cards = []
for m in manifest:
    b64 = base64.b64encode((render_dir / m["file"]).read_bytes()).decode()
    size = size_of(m)
    kits = ", ".join(f"({x},{y})" for x, y in m["medKitSpawns"])
    endzone = m.get("endzone", "column")
    zone_note = (
        f"{endzone} r{m['endzoneRadius']} home x{m['homeX']}"
        if endzone != "column" else f"column home x{m.get('homeX', '?')}")
    # Archetype + biome, defaulted so an older manifest (pre-biome) still
    # renders — the chip just falls back to the historic "arena" concrete.
    archetype = m.get("archetype", "?")
    biome = m.get("biome", "arena")
    cards.append(f'''
<article class="card" data-size="{size}" data-sym="{m['symmetry']}" data-endzone="{endzone}" data-arch="{archetype}" data-biome="{biome}">
  <header class="card-head">
    <span class="idx">#{m['index']:02d}</span>
    <span class="seed">seed {m['seed']}</span>
    <span class="chip chip-{size}">{size} {m['width']}&times;{m['height']}</span>
    <span class="chip chip-sym">{m['symmetry']}</span>
    <span class="chip chip-arch">{archetype} &middot; {biome}</span>
    <span class="chip chip-sym">{zone_note}</span>
    <span class="meta">{m['obstacles']} left-half shapes &middot; {m.get('trenches', 0)} trenches &middot; kits {kits}</span>
  </header>
  <div class="viewer" tabindex="0">
    <img src="data:image/png;base64,{b64}" alt="pool map {m['index']} seed {m['seed']}" draggable="false">
  </div>
</article>''')

counts = {}
for m in manifest:
    for key in (size_of(m), m["symmetry"], m.get("endzone", "column"),
                m.get("biome", "arena")):
        counts[key] = counts.get(key, 0) + 1


def summary(keys, label):
    return " / ".join(f"{counts.get(k, 0)} {k}" for k in keys) + f" {label}"


def filter_buttons(kind, keys):
    return "\n    ".join(
        f'<button data-f="{kind}:{k}" aria-pressed="false">{k}</button>'
        for k in keys)


head_line = " &middot; ".join([
    f"{len(manifest)} maps",
    summary(sizes, "").strip(),
    summary(symmetries, "").strip(),
    summary(endzones, "endzones"),
    summary(biomes, "biomes"),
])
buttons = "\n    ".join([
    filter_buttons("size", sizes),
    filter_buttons("sym", symmetries),
    filter_buttons("endzone", endzones),
    filter_buttons("biome", biomes),
])

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
.chip-arch {{ color:var(--glass); border-color:color-mix(in srgb,var(--glass) 45%,var(--line)); }}
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
  <span class="sub">{head_line}</span>
  <span class="filters">
    {buttons}
  </span>
</div></header>
<p class="hint">scroll to zoom &middot; drag to pan &middot; double-click to reset &middot; filters narrow the grid &middot; regenerate: tools/render_map_pool.nim + tools/build_pool_review.py</p>
<div class="legend">
  <span><b style="background:#40301f"></b>stone</span>
  <span><b style="background:#50dcff"></b>glass window (blocks movement/fire, fog sees through)</span>
  <span><b style="background:#e2cdac"></b>protected floor (never carved: center ring + each team's endzone — a home column, or a disc/square around a base set back from the edge)</span>
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
      const okBiome = !active.biome || c.dataset.biome === active.biome;
      c.classList.toggle('hidden', !(okSize && okSym && okZone && okBiome));
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
