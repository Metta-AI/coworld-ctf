#!/usr/bin/env python3
"""Builds a self-contained catalog.html: the pool COVERAGE view
(tools/map_catalog.nim's markdown) rendered as HTML tables, with each pool
map's render inlined (base64) from a render dir (tools/render_map_pool.nim's
manifest.json + PNGs). One page, no external assets, works from file:// or any
static host — same inlining approach as tools/build_pool_review.py.

This is the "map of maps" coverage page the board preview serves: which
archetype x size x playtype cells the curated pool actually delivers, and which
are still empty. It is a REPORTING artifact, not part of the server.

Usage:
  nim c -d:release -r tools/map_catalog.nim > catalog.md
  nim c -d:release -r tools/render_map_pool.nim pool-preview
  python3 tools/build_catalog_html.py catalog.md pool-preview catalog.html

Defaults: catalogMd=catalog.md, renderDir=pool-preview, out=catalog.html.
"""
import base64
import html
import json
import pathlib
import re
import sys

catalog_md = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("catalog.md")
render_dir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path("pool-preview")
out_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else pathlib.Path("catalog.html")

md = catalog_md.read_text()
manifest = json.loads((render_dir / "manifest.json").read_text())

# The tasks#49 seed-hunt additions, kept in two classes so the page reports
# them the way the judge asked: the siege/rush fills counted as the primary
# deliverable, the overwatch/skirmish fills listed SEPARATELY as bonus.
PRIMARY_SEEDS = {1306: "siege", 1256: "rush", 1946: "rush"}
BONUS_SEEDS = {2974: "overwatch", 2902: "overwatch", 1783: "skirmish"}
HUNT_SEEDS = {**PRIMARY_SEEDS, **BONUS_SEEDS}


def render_md_tables(text):
    """Minimal GitHub-markdown -> HTML for exactly what map_catalog emits:
    ## / ### / #### headings, | tables |, **bold**, and - lists. Deliberately
    small — the catalog's output is a fixed shape, not arbitrary markdown."""
    out = []
    lines = text.splitlines()
    i = 0
    in_table = False

    def close_table():
        nonlocal in_table
        if in_table:
            out.append("</tbody></table>")
            in_table = False

    def fmt_inline(s):
        s = html.escape(s)
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
        return s

    while i < len(lines):
        line = lines[i]
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            # separator row like |---|---|
            if all(set(c) <= set("-: ") and c for c in cells):
                i += 1
                continue
            if not in_table:
                out.append('<table class="cat"><thead><tr>')
                out.append("".join(f"<th>{fmt_inline(c)}</th>" for c in cells))
                out.append("</tr></thead><tbody>")
                in_table = True
            else:
                # highlight the tasks#49 seed-hunt rows: primary (siege/rush)
                # and bonus (overwatch/skirmish) get distinct classes.
                rowcls = ""
                seed0 = None
                if cells and cells[0].lstrip("-").isdigit():
                    seed0 = int(cells[0])
                if seed0 in PRIMARY_SEEDS:
                    rowcls = ' class="new primary"'
                elif seed0 in BONUS_SEEDS:
                    rowcls = ' class="new bonus"'
                out.append(f"<tr{rowcls}>" +
                           "".join(f"<td>{fmt_inline(c)}</td>" for c in cells) +
                           "</tr>")
            i += 1
            continue
        close_table()
        if line.startswith("#### "):
            out.append(f"<h4>{fmt_inline(line[5:])}</h4>")
        elif line.startswith("### "):
            out.append(f"<h3>{fmt_inline(line[4:])}</h3>")
        elif line.startswith("## "):
            out.append(f"<h2>{fmt_inline(line[3:])}</h2>")
        elif line.startswith("- "):
            out.append(f'<div class="li">{fmt_inline(line[2:])}</div>')
        elif line.strip():
            out.append(f"<p>{fmt_inline(line)}</p>")
        i += 1
    close_table()
    return "\n".join(out)


def img_tag(entry):
    png = (render_dir / entry["file"]).read_bytes()
    b64 = base64.b64encode(png).decode()
    seed = entry["seed"]
    if seed in PRIMARY_SEEDS:
        badge = f'<span class="badge">tasks#49 · {PRIMARY_SEEDS[seed]}</span>'
        cls = "card new primary"
    elif seed in BONUS_SEEDS:
        badge = f'<span class="badge bonus">tasks#49 bonus · {BONUS_SEEDS[seed]}</span>'
        cls = "card new bonus"
    else:
        badge = ""
        cls = "card"
    return (f'<figure class="{cls}">'
            f'<img src="data:image/png;base64,{b64}" loading="lazy" '
            f'alt="pool {entry["index"]} seed {seed}">'
            f'<figcaption>#{entry["index"]:02d} · seed {seed}{badge}</figcaption>'
            f'</figure>')


tables_html = render_md_tables(md)
cards_html = "\n".join(img_tag(e) for e in manifest)

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CTF map-of-maps — pool catalog</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.5 -apple-system, system-ui, sans-serif;
         margin: 0 auto; max-width: 1100px; padding: 24px;
         background: #faf8f4; color: #1c1a17; }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #17150f; color: #ece7dc; }}
    code {{ background: #2a2620; }}
    table.cat th, table.cat td {{ border-color: #3a352c; }}
    .card {{ background: #201d16; }}
  }}
  h1 {{ font-size: 22px; }}
  h2 {{ margin-top: 32px; border-bottom: 2px solid currentColor; padding-bottom: 4px; }}
  code {{ background: #ece7dc; padding: 1px 4px; border-radius: 3px; }}
  table.cat {{ border-collapse: collapse; margin: 12px 0; font-size: 13px; }}
  table.cat th, table.cat td {{ border: 1px solid #d8d0c2; padding: 4px 8px; text-align: right; }}
  table.cat td:first-child, table.cat th:first-child {{ text-align: left; }}
  tr.new.primary td {{ background: rgba(210,140,40,.24); font-weight: 600; }}
  tr.new.bonus td {{ background: rgba(90,150,200,.20); font-weight: 600; }}
  .li {{ margin: 2px 0 2px 16px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(320px,1fr));
           gap: 16px; margin-top: 16px; }}
  figure.card {{ margin: 0; background: #fff; border-radius: 8px; overflow: hidden;
                 box-shadow: 0 1px 3px rgba(0,0,0,.15); }}
  figure.card.new.primary {{ outline: 3px solid rgba(210,140,40,.85); }}
  figure.card.new.bonus {{ outline: 3px solid rgba(90,150,200,.75); }}
  figure.card img {{ width: 100%; display: block; }}
  figcaption {{ font-size: 12px; padding: 6px 8px; }}
  .badge {{ background: #d2853c; color: #fff; border-radius: 4px;
            padding: 1px 6px; margin-left: 6px; font-size: 10px; }}
  .badge.bonus {{ background: #4f86b3; }}
  .note {{ font-size: 13px; opacity: .8; }}
  .legend {{ font-size: 12px; margin: 8px 0; }}
  .swatch {{ display: inline-block; width: 10px; height: 10px; border-radius: 2px;
             margin: 0 4px 0 12px; vertical-align: middle; }}
</style></head><body>
<h1>CTF map-of-maps — curated pool catalog</h1>
<p class="note">Coverage view of the {len(manifest)} <code>MapPoolSeeds</code>: which
archetype × size × playtype cells the pool delivers, and which are empty. Generated from
<code>tools/map_catalog.nim</code> + <code>tools/render_map_pool.nim</code>.</p>
<p class="legend">tasks#49 seed-hunt additions:
<span class="swatch" style="background:#d2853c"></span><strong>primary</strong> — the
siege + rush fills (the empty-cell target: 1306 siege, 1256/1946 rush);
<span class="swatch" style="background:#4f86b3"></span><strong>bonus</strong> — extra
fills of the thinnest reachable playtype (2974/2902 overwatch, 1783 skirmish), counted
separately from the siege/rush deliverable.</p>
{tables_html}
<h2>Pool renders</h2>
<div class="grid">
{cards_html}
</div>
</body></html>
"""

out_path.write_text(page)
print(f"wrote {out_path} ({len(page)} bytes, {len(manifest)} maps)")
