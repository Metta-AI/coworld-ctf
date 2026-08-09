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
                # highlight the tasks#49 seed-hunt rows
                rowcls = ""
                if cells and cells[0] in ("1306", "1256", "1946"):
                    rowcls = ' class="new"'
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
    new = seed in (1306, 1256, 1946)
    badge = '<span class="badge">NEW · tasks#49</span>' if new else ""
    cls = "card new" if new else "card"
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
  tr.new td {{ background: rgba(210,140,40,.22); font-weight: 600; }}
  .li {{ margin: 2px 0 2px 16px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(320px,1fr));
           gap: 16px; margin-top: 16px; }}
  figure.card {{ margin: 0; background: #fff; border-radius: 8px; overflow: hidden;
                 box-shadow: 0 1px 3px rgba(0,0,0,.15); }}
  figure.card.new {{ outline: 3px solid rgba(210,140,40,.8); }}
  figure.card img {{ width: 100%; display: block; }}
  figcaption {{ font-size: 12px; padding: 6px 8px; }}
  .badge {{ background: #d2853c; color: #fff; border-radius: 4px;
            padding: 1px 6px; margin-left: 6px; font-size: 10px; }}
  .note {{ font-size: 13px; opacity: .8; }}
</style></head><body>
<h1>CTF map-of-maps — curated pool catalog</h1>
<p class="note">Coverage view of the {len(manifest)} <code>MapPoolSeeds</code>: which
archetype × size × playtype cells the pool delivers, and which are empty. Highlighted
rows/cards are the tasks#49 seed-hunt additions that fill the previously-empty siege and
rush cells. Generated from <code>tools/map_catalog.nim</code> +
<code>tools/render_map_pool.nim</code>.</p>
{tables_html}
<h2>Pool renders</h2>
<div class="grid">
{cards_html}
</div>
</body></html>
"""

out_path.write_text(page)
print(f"wrote {out_path} ({len(page)} bytes, {len(manifest)} maps)")
