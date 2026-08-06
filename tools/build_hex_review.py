#!/usr/bin/env python3
"""Builds the zoomable review page for the hexagonal generator sample.

Same shape as tools/build_pool_review.py (self-contained, base64-inlined, works
from a file:// open), but it reviews a STRATIFIED SAMPLE rather than the curated
pool, so it also carries the selection rule, the validator's rejection mix, and
the per-map cover measurements the sheet cannot show.

The legend is written against what tools/render_hex_sheet.nim actually draws --
no protected-floor tint, no med-kit crosses, no sightline rows. A legend that
names an overlay the render does not carry is worse than no legend.

Usage:
  nim c -d:release -r tools/render_hex_sheet.nim hex50
  python3 tools/build_hex_review.py [renderDir] [outHtml]

Defaults: renderDir=hex50, outHtml=hex50/hex-review.html.
"""
import base64
import json
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
render_dir = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "hex50"
out_path = (pathlib.Path(sys.argv[2]) if len(sys.argv) > 2
            else render_dir / "hex-review.html")

manifest = json.loads((render_dir / "manifest.json").read_text())
meta = json.loads((render_dir / "meta.json").read_text())

SIZE_ORDER = ["small", "standard", "large", "huge", "giant", "colossal"]
SYMMETRIES = ["mirrorHex", "rot180", "rot120", "rot60", "klein4", "mirror"]


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))


cards = []
for m in manifest:
    b64 = base64.b64encode((render_dir / m["file"]).read_bytes()).decode()
    size = m.get("sizeName", f"{m['width']}px")
    core = m.get("coverCore", 0)
    overall = m.get("coverOverall", 0)
    ratio = (core / overall) if overall else 0.0
    # A core-vs-overall ratio under 1 means the MIDDLE of the board is emptier
    # than the board. Flagged per map so the claim is auditable one map at a
    # time instead of only in the aggregate.
    flag = "mid-empty" if ratio < 0.8 else "mid-full"
    cards.append(f'''
<article class="card" data-size="{size}" data-sym="{m['symmetry']}" data-mid="{flag}">
  <header class="card-head">
    <span class="idx">#{m['index']:02d}</span>
    <span class="seed">seed {m['seed']}</span>
    <span class="chip chip-size">{size} {m['width']}&times;{m['height']}</span>
    <span class="chip chip-sym">{esc(m['symmetry'])}</span>
    <span class="chip">endzone r{m['endzoneRadius']} &middot; base depth {m.get('homeDepth', 0)}&permil;</span>
    <span class="chip">{m['obstacles']} half-shapes &middot; {m.get('trenches', 0)} pits</span>
    <span class="meta">cover {overall}&permil; &middot; core {core}&permil; &middot;
      lane {m.get('coverLane', 0)}&permil; &middot; flank {m.get('coverFlank', 0)}&permil; &middot;
      apron {m.get('coverApron', 0)}&permil; &middot;
      <b class="{'bad' if ratio < 0.8 else 'ok'}">core/overall {ratio:.2f}</b></span>
  </header>
  <div class="viewer" tabindex="0">
    <img src="data:image/png;base64,{b64}" alt="hex map {m['index']} seed {m['seed']}" draggable="false">
  </div>
</article>''')

counts = {}
for m in manifest:
    for key in (m.get("sizeName", "?"), m["symmetry"]):
        counts[key] = counts.get(key, 0) + 1

sizes_present = [k for k in SIZE_ORDER if counts.get(k)]
syms_present = [k for k in SYMMETRIES if counts.get(k)]
summary = " &middot; ".join(
    " / ".join(f"{counts[k]} {k}" for k in group)
    for group in (sizes_present, syms_present) if group)

filter_buttons = "\n    ".join(
    f'<button data-f="{group}:{name}" aria-pressed="false">{name}</button>'
    for group, names in (("size", sizes_present), ("sym", syms_present),
                         ("mid", ["mid-empty", "mid-full"]))
    for name in names)

rej = meta.get("rejections", [])
if rej:
    rej_rows = "".join(
        f"<li>seed {r['seed']} ({esc(r['size'])} {esc(r['symmetry'])}) &mdash; "
        f"{esc(r['reason'])}</li>" for r in rej)
    rej_block = (f"<p class='note'><b>{len(rej)} validator rejections</b> in the "
                 f"{meta['seedsScanned']} seeds scanned:</p><ul class='rej'>{rej_rows}</ul>")
else:
    rej_block = (f"<p class='note'><b>Zero validator rejections</b> across the "
                 f"{meta['seedsScanned']} seeds scanned "
                 f"(1..{meta['seedRangeHi']}) &mdash; every seed in the sample "
                 f"window passed every rule on its first attempt.</p>")

html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CTF hex generator &mdash; 50-map review</title>
<style>
:root {{
  --ground:#1a1410; --panel:#241c15; --line:#3a2e21;
  --ink:#e8dcc8; --muted:#9a8a70;
  --glass:#50dcff; --red:#e0523a; --blue:#3f7cc4;
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
.filters {{ float:right; display:flex; gap:.4rem; flex-wrap:wrap; }}
.filters button {{ background:var(--panel); color:var(--ink); border:1px solid var(--line);
  border-radius:3px; font:12px ui-monospace,Menlo,monospace; padding:.25rem .6rem; cursor:pointer; }}
.filters button[aria-pressed="true"] {{ border-color:var(--glass); color:var(--glass); }}
.note {{ color:var(--muted); font:12px/1.6 ui-monospace,Menlo,monospace; margin:.2rem 0; }}
.note b {{ color:var(--ink); }}
.rej {{ color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin:.2rem 0 1rem 1rem; }}
.legend {{ display:flex; flex-wrap:wrap; gap:1rem; font:12px ui-monospace,Menlo,monospace;
  color:var(--muted); margin:.6rem 0 1.2rem; }}
.legend b {{ display:inline-block; width:11px; height:11px; margin-right:.35rem; vertical-align:-1px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(620px,1fr)); gap:1.2rem; }}
.card {{ background:var(--panel); border:1px solid var(--line); border-radius:4px; overflow:hidden; }}
.card.hidden {{ display:none; }}
.card-head {{ display:flex; align-items:baseline; gap:.6rem; padding:.5rem .75rem;
  font:12px ui-monospace,Menlo,monospace; border-bottom:1px solid var(--line); flex-wrap:wrap; }}
.idx {{ color:var(--glass); font-weight:700; }}
.seed {{ font-weight:700; }}
.chip {{ border:1px solid var(--line); border-radius:2px; padding:0 .4rem; color:var(--muted); }}
.chip-sym, .chip-size {{ color:var(--ink); }}
.meta {{ color:var(--muted); width:100%; }}
.meta .bad {{ color:#e0894a; }}
.meta .ok {{ color:var(--muted); }}
.viewer {{ position:relative; height:440px; overflow:hidden; cursor:grab; background:#0f0b08; }}
.viewer:active {{ cursor:grabbing; }}
.viewer img {{ position:absolute; transform-origin:0 0; image-rendering:pixelated;
  user-select:none; -webkit-user-drag:none; }}
.hint {{ text-align:center; color:var(--muted); font:12px ui-monospace,Menlo,monospace; margin:.9rem 0 1.1rem; }}
</style>
</head>
<body>
<div class="wrap">
<header class="top"><div>
  <h1>CTF hexagonal generator <span class="gv">50-map stratified sample</span></h1>
  <span class="sub">{summary}</span>
  <span class="filters">
    {filter_buttons}
  </span>
</div></header>
<p class="note"><b>Selection rule:</b> {esc(meta['selectionRule'])}.
  Seeds 1..{meta['seedRangeHi']} were scanned; {meta['selected']} maps kept.</p>
{rej_block}
<p class="hint">scroll to zoom &middot; drag to pan &middot; double-click to reset &middot; filters narrow the grid &middot;
  regenerate: tools/render_hex_sheet.nim + tools/build_hex_review.py</p>
<div class="legend">
  <span><b style="background:#d6bd96"></b>floor</span>
  <span><b style="background:#403022"></b>stone (also the six corners outside the hexagonal hull: permanent void, collided as stone)</span>
  <span><b style="background:#50dcff"></b>glass window (blocks movement and fire, fog sees through)</span>
  <span><b style="background:#78603e"></b>trench / pit</span>
  <span><b style="background:#e0523a"></b>red endzone disc + capture ring &amp; pedestal</span>
  <span><b style="background:#3f7cc4"></b>blue endzone disc + capture ring &amp; pedestal</span>
  <span>no diagnostic overlays are drawn: this is the board, not the validator's view of it</span>
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
const active = {{ size: null, sym: null, mid: null }};
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
      const okMid = !active.mid || c.dataset.mid === active.mid;
      c.classList.toggle('hidden', !(okSize && okSym && okMid));
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
