"""Serve the coworld DAU report as a live page.

Computes on demand from the league API (cached 5 min) so nobody has to re-run a
script or trust a stale screenshot.

  PY=~/projects/coworld-players/coworld-cogherence-player/.venv/bin/python
  cd tools/ladder && PYTHONPATH=. $PY dau_server.py [--port 8931] [--league <id>]

Then open http://localhost:8931/ — or /data.json for the raw report.
"""
import argparse
import datetime as dt
import http.server
import json
import socketserver
import threading

import dau

_lock = threading.Lock()
_cache = {"at": None, "report": None}
CACHE_S = 300


def report(league, div, days, force=False):
    with _lock:
        now = dt.datetime.now(dt.timezone.utc)
        fresh = (_cache["at"] and not force
                 and (now - _cache["at"]).total_seconds() < CACHE_S)
        if not fresh:
            _cache["report"] = dau.build(league, div, days)
            _cache["at"] = now
        return _cache["report"]


PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Active Users — __NAME__</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Merriweather:wght@400;700&family=Merriweather+Sans:wght@400;600;700&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#fffdf4; --surface:#fffaf0; --surface-alt:#f8f6ef;
  --fg:#111827; --fg-subtle:#555; --fg-muted:#999;
  --ink-navy:#1a3875; --ink-silver:#8a8a8a; --ink-terracotta:#b36e4e;
  --border:#e4dac8; --border-strong:#d4c9b5; --border-subtle:#f0ebe1;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  background:var(--bg); color:var(--fg);
  font-family:"Merriweather Sans",system-ui,sans-serif;
  font-size:14px; line-height:1.62;
  -webkit-font-smoothing:antialiased;
}
main{max-width:760px; margin:0 auto; padding:56px 28px 72px}
.eyebrow{
  font-size:10px; font-weight:700; text-transform:uppercase;
  letter-spacing:.14em; color:var(--fg-subtle); margin:0 0 10px;
}
h1{
  font-family:Merriweather,Georgia,serif; font-weight:700;
  font-size:38px; line-height:1.12; letter-spacing:-.01em; margin:0;
}
.dateline{
  font-size:11.5px; color:var(--fg-muted); margin:10px 0 0;
  padding-bottom:18px; border-bottom:2px solid var(--border-strong);
  font-variant-numeric:tabular-nums;
}
h2{
  font-family:Merriweather,Georgia,serif; font-weight:700;
  font-size:12px; text-transform:uppercase; letter-spacing:.12em;
  color:var(--ink-navy); margin:52px 0 14px;
}
p{margin:0 0 15px; max-width:64ch}
.lead{font-size:16.5px; line-height:1.66; margin-top:34px}
.hero{
  font-family:Merriweather,Georgia,serif; font-weight:700;
  font-size:82px; line-height:.86; letter-spacing:-.03em;
  color:var(--ink-navy); font-variant-numeric:tabular-nums;
  float:left; margin:2px 22px 0 0;
}
/* own formatting context: the text sits BESIDE the figure and self-clears,
   instead of wrapping under it at some widths and not others. */
.hero-ctx{font-size:13.5px; color:var(--fg-subtle); margin:0 0 8px;
          overflow:hidden; min-height:72px}
strong{font-weight:700}
em{font-style:italic; color:var(--fg-subtle)}
.num{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
     font-variant-numeric:tabular-nums;}

figure{margin:0}
figcaption{
  font-size:12px; color:var(--fg-subtle); margin-top:12px;
  font-style:italic; max-width:60ch;
}
.legend{display:flex; gap:20px; align-items:center; margin:0 0 12px;
        font-size:11px; color:var(--fg-subtle)}
.legend span{display:flex; gap:7px; align-items:center}
.sw{width:11px; height:11px; border-radius:2px; display:inline-block}
svg{display:block; width:100%; height:auto; overflow:visible}

table{border-collapse:collapse; width:100%; font-size:13px; margin:6px 0 4px}
th{
  text-align:left; font-size:10px; font-weight:700; text-transform:uppercase;
  letter-spacing:.1em; color:var(--fg-subtle); padding:0 10px 7px 0;
  border-bottom:1px solid var(--border);
}
th.r,td.r{text-align:right}
td{padding:9px 10px 9px 0; border-bottom:1px solid var(--border-subtle);
   vertical-align:baseline}
td.r{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
     font-variant-numeric:tabular-nums; white-space:nowrap}
tr.now td{font-weight:700}
tr.now td.r{color:var(--ink-navy)}
td .note{color:var(--fg-muted); font-size:11.5px}

dl{margin:0}
dt{font-weight:700; font-size:13px; margin:16px 0 3px}
dt:first-child{margin-top:4px}
dd{margin:0; color:var(--fg-subtle); font-size:13px; max-width:62ch}
dd code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
        font-size:12px; background:var(--surface-alt); padding:1px 5px;
        border-radius:3px}

.caveat{
  border-left:3px solid var(--ink-terracotta);
  background:rgba(179,110,78,.06); padding:14px 18px; margin:18px 0 0;
}
.caveat p{margin:0; font-size:13px; max-width:60ch}
footer{
  margin-top:56px; padding-top:16px; border-top:1px solid var(--border);
  font-size:11px; color:var(--fg-muted);
}
#tip{
  position:fixed; pointer-events:none; opacity:0; transition:opacity .1s;
  background:var(--fg); color:var(--bg); font-size:11.5px; line-height:1.5;
  padding:7px 10px; border-radius:3px; max-width:250px; z-index:9;
}
#tip b{color:var(--bg)}
@media (max-width:640px){
  main{padding:34px 18px 56px} h1{font-size:29px}
  .lead{font-size:15px}
  /* no room to set a figure beside text at this width — stack it */
  .hero{float:none; font-size:62px; display:block; margin:4px 0 2px}
  .hero-ctx{overflow:visible; min-height:0}
  table{display:block; overflow-x:auto}
  /* the viewBox would scale 10px axis labels down to ~4px here — scroll the
     chart at a legible size instead of shrinking it into illegibility. */
  .chartwrap{overflow-x:auto; margin:0 -18px; padding:0 18px}
  .chartwrap svg{min-width:580px}
  .legend{flex-wrap:wrap; gap:8px 16px}
}
</style></head><body>
<main>
  <p class="eyebrow">Softmax &middot; Coworld Metrics</p>
  <h1>Who actually uses __NAME__?</h1>
  <p class="dateline">__SPAN__ &middot; generated __GEN__ UTC</p>

  <p class="lead" id="lead"></p>
  <span class="hero" id="hero"></span>
  <p class="hero-ctx" id="heroctx"></p>

  <h2>Daily active users, by day</h2>
  <figure>
    <div class="legend">
      <span><i class="sw" style="background:#1a3875"></i> A person shipped</span>
      <span><i class="sw" style="background:#8a8a8a"></i> Unattended loop only</span>
      <span style="color:var(--fg-muted)">Shaded columns are weekends</span>
    </div>
    <div class="chartwrap">
      <svg id="chart" viewBox="0 0 760 250" role="img"
           aria-labelledby="charttitle"><title id="charttitle"></title></svg>
    </div>
    <figcaption id="cap"></figcaption>
  </figure>

  <h2>What the obvious numbers say</h2>
  <table>
    <thead><tr><th>Where you'd naturally look</th><th class="r">Says</th>
      <th>Why it misleads</th></tr></thead>
    <tbody id="naive"></tbody>
  </table>

  <h2>The proposed definition</h2>
  <dl id="defn"></dl>

  <h2>What this cannot see yet</h2>
  <div class="caveat"><p id="caveat"></p></div>

  <footer id="foot"></footer>
</main>
<div id="tip"></div>
<script>
const D = __DATA__;
const XP = D.experience;
const $ = s => document.querySelector(s);
const WD = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
const wd = iso => { const d = new Date(iso+"T12:00:00Z"); return (d.getUTCDay()+6)%7; };
const isWknd = iso => wd(iso) >= 5;
const plural = (n,s,p) => n===1 ? s : (p||s+"s");

// ---- lead -----------------------------------------------------------------
const today = D.attended[D.attended.length-1];
const nv = D.naive;
$("#hero").textContent = D.dau_today;
$("#lead").innerHTML =
  `Over its first ${D.attended.length} days, <strong>${D.league.name}</strong> was used by `
  + `an average of <strong>${D.dau_mean.toFixed(1)} people a day</strong>. `
  + `Today it was used by:`;
$("#heroctx").innerHTML =
  `${plural(D.dau_today,"person","people")} &mdash; ${today.who.join(", ") || "no one yet"}. `
  + `The number you would normally reach for &mdash; players whose policy appeared in the `
  + `latest round &mdash; is <strong>${nv.fielded_one_round}</strong>, `
  + `and it has never once gone down.`;

// ---- chart ----------------------------------------------------------------
const W=760,H=250, L=30,R=6,T=16,B=42;
const n=D.attended.length, iw=W-L-R, ih=H-T-B;
const tot = D.attended.map((a,i)=>a.dau + D.unattended[i].dau);
const ymax = Math.max(4, ...tot) + 1;
const bw = iw/n, gap = 2, w = bw-gap*2;
const y = v => T + ih - (v/ymax)*ih;
const svg=$("#chart"); const NS="http://www.w3.org/2000/svg";
const el=(t,a)=>{const e=document.createElementNS(NS,t);
  for(const k in a) e.setAttribute(k,a[k]); return e;};
svg.querySelector("title").textContent =
  `Daily active users of ${D.league.name}, ${D.attended[0].date} to ${today.date}`;

// hatch for the de-emphasised (unattended) series — secondary encoding so the
// two are separable without relying on color.
const defs=el("defs");
defs.innerHTML = `<pattern id="hatch" width="5" height="5"
  patternTransform="rotate(45)" patternUnits="userSpaceOnUse">
  <rect width="5" height="5" fill="#8a8a8a"/>
  <line x1="0" y1="0" x2="0" y2="5" stroke="#fffdf4" stroke-width="2"/></pattern>`;
svg.appendChild(defs);

// weekend bands (data, not decoration: the weekend story is the finding)
D.attended.forEach((a,i)=>{ if(!isWknd(a.date)) return;
  svg.appendChild(el("rect",{x:L+i*bw, y:T-6, width:bw, height:ih+6,
    fill:"#f8f6ef"})); });

// recessive gridlines + y labels
for(let v=0; v<=ymax; v+=Math.ceil(ymax/4)){
  svg.appendChild(el("line",{x1:L,x2:L+iw,y1:y(v),y2:y(v),
    stroke:v?"#f0ebe1":"#d4c9b5","stroke-width":1}));
  const t=el("text",{x:L-8,y:y(v)+4,"text-anchor":"end",
    "font-size":10,fill:"#999"}); t.textContent=v; svg.appendChild(t);
}

// bars: square-footed, 4px rounded data-end, 2px surface gap between segments
function bar(x,yTop,h,fill,round){
  if(h<=0) return;
  const r=Math.min(4,h);
  const d = round
    ? `M${x},${yTop+h} L${x},${yTop+r} Q${x},${yTop} ${x+r},${yTop}
       L${x+w-r},${yTop} Q${x+w},${yTop} ${x+w},${yTop+r} L${x+w},${yTop+h} Z`
    : `M${x},${yTop+h} L${x},${yTop} L${x+w},${yTop} L${x+w},${yTop+h} Z`;
  svg.appendChild(el("path",{d,fill}));
}
D.attended.forEach((a,i)=>{
  const x=L+i*bw+gap, u=D.unattended[i].dau;
  const hA=(a.dau/ymax)*ih, hU=(u/ymax)*ih;
  bar(x, y(a.dau), hA, "#1a3875", u===0);
  if(u>0) bar(x, y(a.dau+u)  , hU-2, "url(#hatch)", true);

  const lab=el("text",{x:x+w/2, y:H-B+16, "text-anchor":"middle",
    "font-size":10, fill: isWknd(a.date)?"#555":"#999"});
  lab.textContent = a.date.slice(8);
  svg.appendChild(lab);
  if(i===0 || wd(a.date)===0){
    const m=el("text",{x:x+w/2,y:H-B+29,"text-anchor":"middle",
      "font-size":9,fill:"#999"}); m.textContent=WD[wd(a.date)];
    svg.appendChild(m);
  }
  // selective direct labels: only today and the peak carry a number
  if(i===n-1 || a.dau===Math.max(...D.attended.map(z=>z.dau))){
    const v=el("text",{x:x+w/2,y:y(a.dau+u)-8,"text-anchor":"middle",
      "font-size":11,"font-weight":700,fill:"#1a3875"});
    v.textContent=a.dau; svg.appendChild(v);
  }
  // hover target spans the full column
  const hit=el("rect",{x:L+i*bw,y:T,width:bw,height:ih,fill:"transparent"});
  hit.addEventListener("mousemove",ev=>{
    const t=$("#tip");
    t.innerHTML = `<b>${WD[wd(a.date)]} ${a.date}</b><br>`
      + `${a.dau} ${plural(a.dau,"person","people")}`
      + (u? ` + ${u} unattended loop`:"")
      + `<br>${a.ships} ${plural(a.ships,"upload")}`
      + (a.who.length? `<br>${a.who.join(", ")}`:"");
    t.style.opacity=1;
    t.style.left=Math.min(ev.clientX+14, innerWidth-262)+"px";
    t.style.top=(ev.clientY+14)+"px";
  });
  hit.addEventListener("mouseleave",()=>$("#tip").style.opacity=0);
  svg.appendChild(hit);
});

const wk = D.attended.filter(a=>isWknd(a.date));
const rng = v => v[0]===v[1] ? `${v[0]} both days` : `${Math.min(...v)}–${Math.max(...v)}`;
if(wk.length>=4){
  const a=wk.slice(0,2).map(z=>z.dau), b=wk.slice(-2).map(z=>z.dau);
  $("#cap").textContent =
    `Both weekends are shaded. The first fell to ${rng(a)}; the most recent `
    + `held at ${rng(b)}. Every other count on this page reads identically `
    + `across the two.`;
}

// ---- naive table ----------------------------------------------------------
[["Players fielded in one round",`${nv.fielded_one_round}`,
  `Measured on round ${nv.round} (${nv.episodes} episodes). Those policies play every ~12 minutes with nobody watching.`],
 ["Leaderboard entrants",`${nv.leaderboard}`,
  "Everyone who ever entered, ranked. Flat whether or not a person is here."],
 ["Lifetime submitters",`${nv.lifetime}`,
  "Monotonic by construction — it can only ever go up."],
 ["This definition",`${D.dau_mean.toFixed(1)}`,
  "Counts people, not processes. Fell to 2 on the first weekend, recovered."],
].forEach(([k,v,why],i,arr)=>{
  const tr=document.createElement("tr");
  if(i===arr.length-1) tr.className="now";
  tr.innerHTML=`<td>${k}</td><td class="r">${v}</td>`
    +`<td><span class="note">${why}</span></td>`;
  $("#naive").appendChild(tr);
});

// ---- definition -----------------------------------------------------------
const auto = D.auto_players.length
  ? D.auto_players.join(", ")
  : "none found";
[["A user is active on a day if they took at least one deliberate action on that coworld.",
  `Two are visible: shipping a policy version (keyed to a <em>league</em>, named by `
  + `Player) and paying for a hosted evaluation (keyed to a <em>coworld</em>, named by `
  + `User &mdash; ${XP.events} of them here). The second is what lets this metric cover `
  + `a coworld with no league at all. One action is enough to count for the day; a `
  + `hundred is still one day.`],
 ["Repeat actions are capped, so volume cannot buy activity.",
  `At most <code>${3}</code> count per person per day. One player opened 229 memberships `
  + `in a single day; that is one active day, not 229.`],
 ["Machine cadence is excluded, and reported separately rather than deleted.",
  `Excluded here: <strong>${auto}</strong>. An auto-improvement loop uploading every `
  + `2.1 minutes is not a person &mdash; but it is also not nothing, so it gets its own `
  + `column instead of being silently merged or silently dropped.`],
 ["Compare coworlds on their own loop period, not on a calendar day.",
  `${D.league.name} re-ships every <code>${D.tau_hours.toFixed(1)}h</code> at the median. `
  + (D.tau_subdaily
     ? `That is faster than a day, so a daily count is already the right unit here. `
       + `A coworld with a multi-day training loop needs the longer window or it reads as dead.`
     : `That is longer than a day, so the daily count must be read against that window.`)],
].forEach(([t,d])=>{
  const dt_=document.createElement("dt"); dt_.textContent=t;
  const dd=document.createElement("dd"); dd.innerHTML=d;
  $("#defn").append(dt_,dd);
});

$("#caveat").innerHTML =
  `Two kinds of human action are visible: shipping a policy, and paying for a hosted `
  + `evaluation. The second is <strong>caller-scoped</strong> &mdash; only `
  + `${XP.requesters_visible.length} requester is visible to this credential, so every `
  + `other user's evaluations are missing. Page views and replay downloads are not `
  + `exposed at all. Someone who reads replays every morning and ships once a week still `
  + `counts as inactive, so <strong>${D.dau_mean.toFixed(1)} is a lower bound, not the `
  + `truth</strong>. Closing it needs a metrics read scope on `
  + `<code>/v2/experience-requests</code> first, then an event log with `
  + `<code>(user_id, coworld_id, timestamp, action, credential_type)</code>. The formula `
  + `does not change; it just gets more to count.`;

$("#foot").innerHTML =
  `${D.span.events} upload events since ${D.span.first.slice(0,10)} &middot; `
  + `${D.eligible} people have ever shipped here, ${D.wau.length} in the last 7 days`
  + `<br>League <span class="num">${D.league.id}</span> &middot; `
  + `recomputed from the league API every 5 minutes by `
  + `<span class="num">tools/ladder/dau.py</span>`;
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    args = None

    def _send(self, body, ctype):
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        a = self.args
        try:
            r = report(a.league, a.div, a.days, force="refresh" in self.path)
        except Exception as e:  # noqa: BLE001 — surface it in the page, not a 500
            self._send(f"<pre>report failed: {type(e).__name__}: {e}</pre>",
                       "text/html; charset=utf-8")
            return
        if self.path.startswith("/data.json"):
            self._send(json.dumps(r, indent=1), "application/json")
            return
        span = (f"{r['span']['first'][:10]} to {r['span']['last'][:10]}"
                if r["span"]["first"] else "no data")
        html = (PAGE.replace("__DATA__", json.dumps(r))
                    .replace("__NAME__", r["league"]["name"] or "this coworld")
                    .replace("__LEAGUE__", r["league"]["id"][:26] + "…")
                    .replace("__SPAN__", span)
                    .replace("__GEN__", r["generated_at"][:16].replace("T", " ")))
        self._send(html, "text/html; charset=utf-8")

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--league", default=dau.PAINTBOT)
    ap.add_argument("--div", default=dau.PAINTBOT_DIV)
    ap.add_argument("--days", type=int, default=12)
    ap.add_argument("--port", type=int, default=8931)
    a = ap.parse_args()
    Handler.args = a
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", a.port), Handler) as httpd:
        print(f"DAU dashboard  →  http://localhost:{a.port}/")
        print(f"raw JSON       →  http://localhost:{a.port}/data.json")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
