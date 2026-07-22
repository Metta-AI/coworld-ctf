#!/usr/bin/env python3
"""Generate the live interactive cog-rig HTML from /tmp/rig_data.json.

Kinematics (the two fixes):
  1) DIFFERENTIAL: each leg pivots about ITS OWN HIP, not the body hub. The hip
     position is carried by the body rotation (dHead); the leg art is rotated by
     (dHead + swing) about that hip. swing=0 => rigid body turn (hip carried +
     leg rotated by dHead about hip == rotating the whole leg about the hub).
     swing!=0 => the foot ARCS about the hip (inner end pinned) = visible steer.
  2) CASTER SIGN: the tire's long axis is vertical (rolls N/S at rot0). To roll
     toward screen angle wr, the canvas rotation must be +(wr-90) net; drawPart
     negates rotDeg, so pass rotDeg=(wr-90) (NOT -(wr-90)).
Differential drive: swing target is proportional to the heading-vs-travel ERROR
(present throughout a turn), eased so it builds and relaxes.
"""
import json, os

DATA = open("/tmp/rig_data.json").read()

JS = r"""
const DATA=__DATA__;const imgs={};let loaded=0;const need=Object.keys(DATA.parts).length;
for(const k in DATA.parts){const im=new Image();im.onload=()=>loaded++;im.src='data:image/png;base64,'+DATA.parts[k].b64;imgs[k]=im;}
const TURN=256;
function bradsOf(dx,dy){if(!dx&&!dy)return 0;let b=Math.round(Math.atan2(-dy,dx)*(TURN/2)/Math.PI);return((b%TURN)+TURN)%TURN;}
function bdiff(a,b){let d=(((a-b)%TURN)+TURN)%TURN;if(d>TURN/2)d-=TURN;return d;}
function ease(c,t,s){const d=bdiff(t,c);return((c+Math.max(-s,Math.min(s,d)))%TURN+TURN)%TURN;}
function easeF(c,t,s){const d=t-c;return c+Math.max(-s,Math.min(s,d));}
function b2d(b){return b*360/TURN;}
let TUNE={size:0.55,body:4,sw:120,tuck:45,cast:14};
// MANUAL per-leg hip angle (deg) — for dialing rest/turn poses by hand. When manual!=0 it
// OVERRIDES the auto differential for that leg so you can find the exact numbers.
let MANUAL={front_left:0,front_right:0,rear:0,on:false};
const STOP=8,REVMAX=96,COMMIT=12;
const cog={x:0,y:0,vx:0,vy:0,head:0,toe:0,rev:0,w:0,wAvg:0,aim:64,turnAmt:0,inputDir:-1,
           casterDeg:{front_right:90,front_left:90,rear:90},lastFoot:{}};
const cv=document.getElementById('c'),ctx=cv.getContext('2d');
function fit(){cv.width=cv.clientWidth*devicePixelRatio;cv.height=cv.clientHeight*devicePixelRatio;ctx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0);}
addEventListener('resize',fit);fit();
function reset(){cog.x=cv.clientWidth/2;cog.y=cv.clientHeight/2;cog.vx=cog.vy=0;cog.head=64;cog.toe=64;cog.rev=0;cog.aim=64;cog.turnAmt=0;cog.wAvg=0;for(const l in cog.casterDeg)cog.casterDeg[l]=90;cog.lastFoot={};}reset();
let keys={},mouse={x:0,y:0},auto=false,paused=false,bones=false,team='blue',autoT=0,tintCache={};
let carrying=false, hasPlasma=false;   // turret-attachment states (arms show iff carrying)
addEventListener('keydown',e=>{const k=e.key.toLowerCase();keys[k]=true;if(k===' '){paused=!paused;e.preventDefault();}if(k==='r')reset();if(k==='b'){bones=!bones;document.getElementById('tg-bones').classList.toggle('on',bones);}});
addEventListener('keyup',e=>keys[e.key.toLowerCase()]=false);
cv.addEventListener('mousemove',e=>{const r=cv.getBoundingClientRect();mouse.x=e.clientX-r.left;mouse.y=e.clientY-r.top;});
document.getElementById('tg-bones').onclick=e=>{bones=!bones;e.target.classList.toggle('on',bones);};
document.getElementById('tg-auto').onclick=e=>{auto=!auto;e.target.classList.toggle('on',auto);};
document.getElementById('tg-team').onclick=e=>{team=team==='blue'?'red':'blue';e.target.textContent='team: '+team;tintCache={};};
document.getElementById('tg-carry').onclick=e=>{carrying=!carrying;e.target.classList.toggle('on',carrying);e.target.textContent='heart: '+(carrying?'ON':'off');};
document.getElementById('tg-plasma').onclick=e=>{hasPlasma=!hasPlasma;e.target.classList.toggle('on',hasPlasma);e.target.textContent='plasma: '+(hasPlasma?'ON':'off');};
function bind(id,key,f,dec){const el=document.getElementById(id);el.oninput=()=>{TUNE[key]=el.value*f;document.getElementById('v-'+id.slice(2)).textContent=(el.value*f).toFixed(dec);};}
bind('s-size','size',0.01,2);bind('s-body','body',1,0);bind('s-sw','sw',1,0);bind('s-tuck','tuck',1,0);bind('s-cast','cast',1,0);
// manual pose controls
document.getElementById('tg-manual').onclick=e=>{MANUAL.on=!MANUAL.on;e.target.classList.toggle('on',MANUAL.on);e.target.textContent='manual '+(MANUAL.on?'ON':'OFF');};
document.getElementById('tg-pause').onclick=e=>{paused=!paused;e.target.classList.toggle('on',paused);};
for(const[id,key] of [['s-ml','front_left'],['s-mr','front_right'],['s-mrr','rear']]){
  const el=document.getElementById(id);el.oninput=()=>{MANUAL[key]=+el.value;document.getElementById('v-'+id.slice(2)).textContent=el.value;};}
function stepDrive(vx,vy,aim){
  const speed=Math.abs(vx)+Math.abs(vy);
  let err=0;                                  // heading->travel error BEFORE easing
  if(speed<STOP){cog.rev=Math.max(0,cog.rev-1);cog.w=0;}
  else{const travel=bradsOf(vx,vy);
    err=b2d(bdiff(travel,cog.head));          // signed error measured PRE-ease (this is the turn)
    const off=Math.abs(err);const back=off>REVMAX;
    if(back)cog.rev=Math.min(cog.rev+1,COMMIT*2);else cog.rev=Math.max(0,cog.rev-2);
    const committed=cog.rev>=COMMIT;const tgt=(back&&!committed)?cog.head:travel;
    const rate=Math.max(TUNE.body/2,Math.round(TUNE.body*STOP*4/Math.max(speed,STOP*4)));
    const prev=cog.head;cog.head=ease(cog.head,tgt,rate);cog.w=bdiff(cog.head,prev);
    cog.toe=ease(cog.toe,travel,40);}
  // SPLAY ∝ ANGULAR VELOCITY MAGNITUDE (how tight the curve is, right now).
  // cog.w = signed heading change this frame (brads/frame). In a STEADY curve it's a constant
  // nonzero value => constant splay; straight => 0 => narrow; tighter curve => bigger |w| =>
  // wider, up to equilateral at |w|>=WFULL. Smoothed so it reads steady. +w = LEFT/CCW.
  // Decoupled from the body-turn-rate SLIDER: WFULL is a fixed reference (deg/frame), so a slow
  // body still reaches full splay on a tight-enough curve; it just takes a tighter curve.
  const WFULL=3.0;                                   // deg/frame of heading change = full splay
  const tInst=Math.max(-1,Math.min(1, b2d(cog.w)/WFULL));
  cog.wAvg = cog.wAvg*0.7 + tInst*0.3;               // smoothed turn-velocity (holds in a curve)
  cog.turnAmt=easeF(cog.turnAmt, cog.wAvg, 0.12);
}
const ACC=0.6,FRIC=0.86,MAXV=7;
function physics(){let ix=0,iy=0;
  if(auto){autoT+=0.02;ix=Math.cos(autoT)*Math.cos(autoT*0.4);iy=Math.sin(autoT*1.2);}
  else{if(keys['a'])ix-=1;if(keys['d'])ix+=1;if(keys['w'])iy-=1;if(keys['s'])iy+=1;}
  cog.vx=(cog.vx+ix*ACC)*FRIC;cog.vy=(cog.vy+iy*ACC)*FRIC;
  const sp=Math.hypot(cog.vx,cog.vy);if(sp>MAXV){cog.vx*=MAXV/sp;cog.vy*=MAXV/sp;}
  if(Math.abs(cog.vx)<0.04)cog.vx=0;if(Math.abs(cog.vy)<0.04)cog.vy=0;
  cog.x+=cog.vx;cog.y+=cog.vy;const w=cv.clientWidth,h=cv.clientHeight;
  cog.x=Math.max(90,Math.min(w-90,cog.x));cog.y=Math.max(90,Math.min(h-90,cog.y));
  cog.aim=auto?bradsOf(Math.cos(autoT*0.6),Math.sin(autoT*0.6)):bradsOf(mouse.x-cog.x,mouse.y-cog.y);
  // steering INPUT direction (brads) — nonzero + persistent while a turn key is held, unlike
  // travel-vs-heading which collapses once the body catches up. Drives the splay directly.
  cog.inputDir = (ix||iy) ? bradsOf(ix,iy) : -1;
  stepDrive(cog.vx*6,cog.vy*6,cog.aim);
}
function tinted(k){const key=k+team;if(tintCache[key])return tintCache[key];const im=imgs[k];
  const cn=document.createElement('canvas');cn.width=im.width;cn.height=im.height;const cx=cn.getContext('2d');cx.drawImage(im,0,0);
  if(k==='wheel'){tintCache[key]=cn;return cn;}
  const id=cx.getImageData(0,0,cn.width,cn.height),p=id.data,rgb=DATA.teamRGB[team];
  for(let i=0;i<p.length;i+=4){const a=p[i+3];if(a<40)continue;const r=p[i],g=p[i+1],b=p[i+2],mx=Math.max(r,g,b),mn=Math.min(r,g,b);
    if(mx-mn>35&&mx>70){const lum=0.299*r+0.587*g+0.114*b,f=Math.min(1.35,lum/175);p[i]=Math.min(255,f*rgb[0]);p[i+1]=Math.min(255,f*rgb[1]);p[i+2]=Math.min(255,f*rgb[2]);}}
  cx.putImageData(id,0,0);tintCache[key]=cn;return cn;}
// pin `bone`(art px) at (px,py), scale, rotate rotDeg (screen CCW+ => canvas negates)
function drawPart(k,px,py,scale,rotDeg,useTint,boneOverride){
  const im=useTint?tinted(k):imgs[k];const bone=boneOverride||DATA.parts[k].bone;
  ctx.save();ctx.translate(px,py);ctx.rotate(-rotDeg*Math.PI/180);ctx.scale(scale,scale);ctx.drawImage(im,-bone[0],-bone[1]);ctx.restore();}
// rotate art point about artHub by dDeg (screen CCW), scale to screen, offset to cog center
function artToScreen(pt,dDeg,S){const hub=DATA.artHub;const dx=pt[0]-hub[0],dy=pt[1]-hub[1];
  const a=-dDeg*Math.PI/180;const rx=dx*Math.cos(a)-dy*Math.sin(a),ry=dx*Math.sin(a)+dy*Math.cos(a);
  return[cog.x+rx*S,cog.y+ry*S];}
function render(){const w=cv.clientWidth,h=cv.clientHeight;ctx.clearRect(0,0,w,h);
  ctx.strokeStyle='rgba(255,255,255,0.05)';for(let x=0;x<w;x+=40){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke();}
  for(let y=0;y<h;y+=40){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke();}
  if(loaded<need){ctx.fillStyle='#fff';ctx.fillText('loading '+loaded+'/'+need,20,20);return;}
  const S=TUNE.size*DATA.native.legset, wheelS=TUNE.size*DATA.native.wheel, headS=TUNE.size*DATA.native.head;
  const dHead=b2d(cog.head)-DATA.restHeading;
  // ---- ONE-SIDED DIFFERENTIAL (narrow at rest, ONE leg splays to steer) ----
  // Matches the CvC cog: at rest both front legs are TUCKED narrow (wheels parallel, forward).
  // To turn LEFT, ONLY the LEFT leg splays OUT; to turn RIGHT, ONLY the RIGHT leg splays out.
  // The other front leg stays tucked. turnAmt in [-1,1], + = LEFT/CCW.
  // Rest tuck pulls each front leg inward (toward the nose) from its authored art splay; a splay
  // ADDS outward on the steering side only. Sign of the art-rotation: for front_left, +rot
  // swings its foot toward the nose (tuck); we splay it OUTWARD (-rot) when turning LEFT. For
  // front_right, mirrored.
  const t=cog.turnAmt, TUCK=TUNE.tuck, SW=TUNE.sw;
  // IDLE = both front legs tucked inward by TUCK (narrow, wheels forward).
  // TURNING = the steering-side leg SWINGS OUT by up to SW° (the "splay amount" slider), scaled
  // by |turn velocity| t. So: rest width = TUCK (rest tuck slider); max open = SW (splay slider).
  //   front_left  tuck = -rot (toward forward); splay OUT = +rot (away, wider). LEFT turn (t>0).
  //   front_right tuck = +rot; splay OUT = -rot. RIGHT turn (t<0).
  const leftOpen  = Math.max(0, t)  * SW;     // left leg opens this much when turning LEFT
  const rightOpen = Math.max(0, -t) * SW;     // right leg opens this much when turning RIGHT
  const legSwing = MANUAL.on ? {front_left:MANUAL.front_left,front_right:MANUAL.front_right,rear:MANUAL.rear} : {
    front_left:  -TUCK + leftOpen,            // tucked at rest; swing OUT (+) up to SW on LEFT turn
    front_right: +TUCK - rightOpen,           // tucked at rest; swing OUT (−) up to SW on RIGHT turn
    rear: 0
  };
  const hips={},feet={};
  // LEG FEET positions first (needed for per-wheel velocity), pinned at each hip.
  for(const leg of ['front_right','front_left','rear']){
    const hipS=artToScreen(DATA.parts[leg].hip,dHead,S);hips[leg]=hipS;
    const fp=DATA.parts[leg].foot,hp=DATA.parts[leg].hip;
    const rel=[fp[0]-hp[0],fp[1]-hp[1]];const tot=(dHead+legSwing[leg])*Math.PI/180;
    const rx=rel[0]*Math.cos(-tot)-rel[1]*Math.sin(-tot),ry=rel[0]*Math.sin(-tot)+rel[1]*Math.cos(-tot);
    feet[leg]=[hipS[0]+rx*S,hipS[1]+ry*S];
  }
  // ---- WHEELS point along each foot's ACTUAL velocity (translation + rotation + swing) ----
  // finite-difference the foot's screen position vs last frame => true velocity direction, so a
  // pure spin (feet move tangentially) points the wheels tangent, not along body travel.
  for(const leg of ['front_right','front_left','rear']){
    const foot=feet[leg], last=cog.lastFoot[leg];
    let velDeg=cog.casterDeg[leg];
    if(last){const dx=foot[0]-last[0],dy=foot[1]-last[1];
      if(Math.hypot(dx,dy)>0.6) velDeg=b2d(bradsOf(dx,dy));}  // enough motion to trust dir
    cog.casterDeg[leg]=b2d(ease(cog.casterDeg[leg]/360*TURN, velDeg/360*TURN, TUNE.cast/360*TURN));
    drawPart('wheel',foot[0],foot[1],wheelS,(cog.casterDeg[leg]-90),false,DATA.parts.wheel.axle);
    cog.lastFoot[leg]=foot;
  }
  // LEGS — each pinned at ITS OWN HIP (screen pos), rotated by dHead+swing about the hip.
  for(const leg of ['rear','front_left','front_right']){
    drawPart(leg,hips[leg][0],hips[leg][1],S,dHead+legSwing[leg],true,DATA.parts[leg].hip);
  }
  // hub disc (covers leg roots) rotates with heading
  drawPart('hub_disc',cog.x,cog.y,S,dHead,true);
  // ARMS + head: the TURRET group, aims independently (rotates to cog.aim).
  // ⚠️ ARMS ONLY WHEN CARRYING THE HEART (carrier state). No heart => no arms (idle trike +
  // head). Carrying => arms appear cradling the heart out front along the aim ray.
  const aimRot=b2d(cog.aim)-90;
  if(carrying && DATA.parts.arms) drawPart('arms',cog.x,cog.y,headS,aimRot,true);
  drawPart('head',cog.x,cog.y,headS,aimRot,true);
  if(carrying){ // heart cradled forward along aim (CvC carry spec: ~12 map-px fwd)
    const ar=b2d(cog.aim)*Math.PI/180, fwd=42*TUNE.size;
    const hx=cog.x+Math.cos(ar)*fwd, hy=cog.y-Math.sin(ar)*fwd;
    ctx.save();ctx.translate(hx,hy);ctx.fillStyle=team==='blue'?'#c94f4f':'#4f78c9';
    // simple heart glyph as a stand-in (the real heart sprite is emitted by the engine)
    ctx.beginPath();const s2=13*TUNE.size;
    ctx.moveTo(0,s2*0.3);ctx.bezierCurveTo(-s2,-s2*0.6,-s2*0.5,-s2*1.1,0,-s2*0.4);
    ctx.bezierCurveTo(s2*0.5,-s2*1.1,s2,-s2*0.6,0,s2*0.3);ctx.fill();ctx.restore();
  }
  if(bones){
    for(const leg of ['front_right','front_left','rear']){
      const hip=hips[leg],foot=feet[leg];
      ctx.strokeStyle='rgba(255,220,90,0.9)';ctx.lineWidth=3;ctx.beginPath();ctx.moveTo(hip[0],hip[1]);ctx.lineTo(foot[0],foot[1]);ctx.stroke();
      ctx.fillStyle='#e0902a';ctx.beginPath();ctx.arc(hip[0],hip[1],7,0,7);ctx.fill();
      ctx.fillStyle='#2aa7b0';ctx.beginPath();ctx.arc(foot[0],foot[1],6,0,7);ctx.fill();
      const cr=cog.casterDeg[leg]*Math.PI/180;ctx.strokeStyle='#2aa7b0';ctx.lineWidth=2;
      ctx.beginPath();ctx.moveTo(foot[0],foot[1]);ctx.lineTo(foot[0]+Math.cos(cr)*26,foot[1]-Math.sin(cr)*26);ctx.stroke();
    }
    ctx.fillStyle='#b5502f';ctx.beginPath();ctx.arc(cog.x,cog.y,6,0,7);ctx.fill();
    function ray(b,len,col){ctx.strokeStyle=col;ctx.lineWidth=2;const a=b2d(b)*Math.PI/180;ctx.beginPath();ctx.moveTo(cog.x,cog.y);ctx.lineTo(cog.x+Math.cos(a)*len,cog.y-Math.sin(a)*len);ctx.stroke();}
    ray(cog.head,80,'#c9a23a');ray(cog.aim,100,'#2aa7b0');
  }
  document.getElementById('stat').textContent=
    `speed   ${Math.hypot(cog.vx,cog.vy).toFixed(1)}\naim     ${b2d(cog.aim).toFixed(0)}°\nheading ${b2d(cog.head).toFixed(0)}°\n`+
    `turnRate${b2d(cog.w).toFixed(1)}°/f\nturnAmt ${cog.turnAmt.toFixed(2)}\nreverse ${cog.rev}${cog.rev>=COMMIT?' (U-TURN)':''}`;
  const mo=document.getElementById('manualout');
  if(mo)mo.textContent=`legSwing now:\n FL=${legSwing.front_left.toFixed(0)}  FR=${legSwing.front_right.toFixed(0)}  R=${legSwing.rear.toFixed(0)}`;
}
function loop(){if(!paused)physics();render();requestAnimationFrame(loop);}loop();
"""

HTML = r"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Cog rig — live</title>
<style>
:root{--ink:#26231e;--paper:#f4f2ec;--line:#d8d4c8}*{box-sizing:border-box}
body{margin:0;font:13px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;color:var(--ink);background:var(--paper);display:flex;height:100vh;overflow:hidden}
#wrap{flex:1;position:relative}canvas{display:block;width:100%;height:100%;background:#5b5e4b}
#panel{width:310px;padding:14px 16px;border-left:1px solid var(--line);background:#fbfaf6;overflow-y:auto}
h1{font-size:15px;margin:0 0 2px}.sub{color:#7c766a;font-size:12px;margin:0 0 12px}
.k{display:inline-block;min-width:20px;text-align:center;background:#eee;border:1px solid #ccc;border-radius:4px;padding:1px 5px;font:11px ui-monospace,Menlo;margin:1px}
.grp{border:1px solid var(--line);border-radius:8px;padding:9px 11px;margin-bottom:10px;background:#fff}.grp h2{font-size:12px;margin:0 0 7px}
label{display:flex;justify-content:space-between;font-size:11px;color:#6a6459;margin:5px 0 1px}input[type=range]{width:100%}
.row{display:flex;gap:6px;flex-wrap:wrap}button{font:11px inherit;padding:5px 9px;border:1px solid var(--line);border-radius:6px;background:#fff;cursor:pointer}
button.on{background:var(--ink);color:var(--paper);border-color:var(--ink)}.stat{font:11px ui-monospace,Menlo;color:#4a453c;white-space:pre;line-height:1.5}
</style></head><body>
<div id="wrap"><canvas id="c"></canvas></div>
<div id="panel">
<h1>Cog rig — live articulated</h1>
<p class="sub">Legs hinge at HIPS (differential); wheels caster (fixed axis). Drive <span class="k">W</span><span class="k">A</span><span class="k">S</span><span class="k">D</span>; mouse aims head. <span class="k">B</span> bones.</p>
<div class="grp"><h2>Show</h2><div class="row">
<button id="tg-bones">bones</button><button id="tg-auto">auto-drive</button><button id="tg-team">team: blue</button>
<button id="tg-carry">heart: off</button><button id="tg-plasma">plasma: off</button></div>
<div class="sub" style="margin:6px 0 0">arms appear only with the heart; plasma only when armed (both engine-gated).</div></div>
<div class="grp"><h2>Tuning (live)</h2>
<label>rig size <span id="v-size">0.55</span></label><input type="range" id="s-size" min="20" max="120" value="55">
<label>body turn rate <span id="v-body">4</span></label><input type="range" id="s-body" min="2" max="30" value="4">
<label>splay amount° <span id="v-sw">120</span></label><input type="range" id="s-sw" min="0" max="120" value="120">
<label>rest tuck° <span id="v-tuck">45</span></label><input type="range" id="s-tuck" min="0" max="90" value="45">
<label>caster rate <span id="v-cast">14</span></label><input type="range" id="s-cast" min="2" max="60" value="14"></div>
<div class="grp"><h2>Manual pose (dial by hand)</h2>
<div class="row"><button id="tg-manual">manual OFF</button><button id="tg-pause">pause</button></div>
<label>front-left hip° <span id="v-ml">0</span></label><input type="range" id="s-ml" min="-90" max="90" value="0">
<label>front-right hip° <span id="v-mr">0</span></label><input type="range" id="s-mr" min="-90" max="90" value="0">
<label>rear hip° <span id="v-mrr">0</span></label><input type="range" id="s-mrr" min="-90" max="90" value="0">
<div class="stat" id="manualout" style="margin-top:6px"></div></div>
<div class="grp"><h2>State</h2><div class="stat" id="stat"></div></div></div>
<script>
__JS__
</script></body></html>"""

import sys
out = HTML.replace("__JS__", JS).replace("__DATA__", DATA)
# Write BOTH the canonical name and a unique-versioned copy (cache-proof: the browser
# can't serve a stale tab for a never-before-seen URL). Pass a version tag as argv[1].
tag = sys.argv[1] if len(sys.argv) > 1 else "latest"
open("/tmp/cog_anim_final.html", "w").write(out)
vpath = f"/tmp/cog_rig_{tag}.html"
open(vpath, "w").write(out)
print(f"wrote /tmp/cog_anim_final.html + {vpath}  ({len(out)} bytes)")
