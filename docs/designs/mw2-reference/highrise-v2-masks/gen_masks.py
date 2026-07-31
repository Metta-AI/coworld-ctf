import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from collections import deque
import math

W, H = 1400, 700
CX, CY = W//2, H//2          # engine-forced center (700,350)
FLAG_RING = 70

def R(x,y,w,h): return ("rect",(x,y,w,h))
def D(cx,cy,r): return ("disc",(cx,cy,r))
def DG(x0,y0,x1,y1,t): return ("diag",(x0,y0,x1,y1,t))
def DM(cx,cy,r): return ("diam",(cx,cy,r))

# ---------------- BOUNDARY (out-of-bounds solid) ----------------
BOUNDARY = [
 ("border N", R(0,0,W,12)), ("border S", R(0,688,W,12)),
 ("border W", R(0,0,16,H)), ("border E", R(1384,0,16,H)),
 ("north solid above corridor", R(346,12,75,48)),
 ("north solid W (city drop)",  R(421,12,240,90)),
 ("north solid above gantry",   R(646,12,264,45)),
 ("north solid E (city drop)",  R(895,12,204,90)),
 ("NE corner solid",            R(1099,12,45,132)),
 ("east tower N band",          R(1144,12,240,27)),
 ("raised roof (sealed balcony)", R(1207,39,135,72)),
 ("raised roof NE plant",       R(1321,39,63,120)),
 ("SW void under west tower wall", R(16,681,405,19)),
 ("W parapet tie-back S",       R(16,516,42,24)),
 ("W parapet tie-back N",       R(16,270,41,24)),
 ("solid above landing",        R(421,102,33,33)),
 ("void strip W of rig bay",    R(466,615,165,48)),
 ("void strip E of rig bay",    R(922,615,162,48)),
 ("void under rig bay",         R(646,663,261,37)),
 ("void under girder walk",     R(418,687,766,13)),
]
# ---------------- WALLS (structure walls, opaque) ----------------
WALLS = [
 # west tower
 ("corridor W wall a", R(346,60,12,30)), ("corridor W wall b", R(346,120,12,108)),
 ("corridor top",      R(346,60,75,12)),
 ("corridor E wall",   R(409,60,12,177)),
 ("landing N wall",    R(406,135,63,12)),
 ("deck W wall upper", R(454,102,12,48)),
 ("deck W wall lower", R(454,225,12,270)),
 ("machine rm N a",    R(259,228,81,12)),
 ("machine rm N b",    R(406,228,63,12)),
 ("mach door stub W",  R(322,213,39,12)), ("mach door stub E", R(388,213,36,12)),
 ("machine rm W wall", R(262,228,12,195)),
 ("machine rm S stub", R(259,408,54,12)),
 ("mach interior stub A", R(325,261,12,81)),
 ("mach interior stub B", R(325,372,12,51)),
 ("suite N wall",      R(103,399,168,12)),
 ("suite W wall",      R(106,399,12,189)),
 ("suite stub NW",     R(103,435,36,12)),
 ("suite mid wall a",  R(160,435,12,186)), ("suite mid wall b", R(160,648,12,33)),
 ("suite bar 1",       R(157,456,45,12)), ("suite bar 2", R(238,456,39,12)),
 ("suite bar 3",       R(178,471,150,12)),("suite bar 4", R(178,486,87,12)),
 ("suite bar 5",       R(157,513,171,12)),("suite bar 6", R(238,537,90,12)),
 ("suite S wall",      R(157,585,177,12)),
 ("suite E wall dbl",  R(316,438,12,117)),("suite E wall low", R(319,561,12,39)),
 ("SW deck W wall",    R(31,570,12,111)),
 ("SW deck N wall",    R(31,573,111,12)),
 ("suite/deck E wall a", R(409,477,12,138)), ("suite/deck E wall b", R(409,645,12,36)),
 ("W tower S wall",    R(28,669,393,12)),
 # mid deck north + gantry + seam
 ("deck N wall W",     R(454,102,207,12)),
 ("gantry N wall",     R(643,57,270,12)),
 ("gantry W wall",     R(646,57,12,57)),
 ("gantry E wall",     R(895,57,12,57)),
 ("deck N wall E",     R(892,102,207,12)),
 ("seam W wall a",     R(742,57,12,33)), ("seam W wall b", R(742,120,12,156)),
 ("seam E wall a",     R(817,57,12,33)), ("seam E wall b", R(817,120,12,66)),
 ("seam E wall c",     R(817,213,12,126)),
 ("seam SE lip",       R(770,324,59,12)),
 ("stairhead block",   R(829,150,39,69)),
 # central penthouse (the offices)
 ("penthouse N a",     R(544,423,174,12)), ("penthouse N b", R(760,423,111,12)),
 ("penthouse N c",     R(901,423,108,12)),
 ("penthouse NW chamfer", DG(544,429,520,462,12)),
 ("penthouse SW chamfer", DG(496,525,541,555,12)),
 ("W tip W wall",      R(484,462,12,63)),
 ("W tip N wall",      R(484,462,78,12)), ("W tip S wall", R(484,513,78,12)),
 ("W tip E wall a",    R(550,462,12,18)), ("W tip E wall b", R(550,507,12,18)),
 ("penthouse S a",     R(541,540,219,12)), ("penthouse S b", R(784,540,228,12)),
 ("inner N wall a",    R(781,441,60,12)), ("inner N wall b", R(868,441,108,12)),
 ("inner S wall a",    R(763,513,66,12)), ("inner S wall b", R(856,513,120,12)),
 ("inner W wall a",    R(676,435,12,33)), ("inner W wall b", R(676,498,12,42)),
 ("inner mid wall a",  R(784,453,12,18)), ("inner mid wall b", R(784,501,12,12)),
 ("E tip N chevron",   DG(1012,429,1036,477,12)),
 ("E tip S chevron",   DG(1012,552,1036,507,12)),
 ("E tip inner wall",  R(964,441,12,84)),
 # NE quadrant
 ("NE long wall",      R(910,156,12,198)),
 # deck south + rig bay
 ("parapet wall W",    R(454,603,207,12)),
 ("parapet wall E",    R(892,603,207,12)),
 ("rig bay W wall",    R(646,603,12,24)),
 ("rig bay E wall",    R(895,603,12,24)),
 ("rig bay S wall",    R(643,651,270,12)),
 # east tower
 ("tower N wall",      R(1129,39,93,12)),
 ("vestibule N wall",  R(1081,132,66,12)),
 ("tower W wall upper",R(1084,99,16,45)),
 ("tower W wall main", R(1087,225,12,264)),
 ("vestibule S wall",  R(1081,228,87,12)),
 ("tower long wall N a", R(1132,36,12,132)), ("tower long wall N b", R(1132,195,12,99)),
 ("tower long wall S a", R(1132,420,12,75)), ("tower long wall S b", R(1132,522,12,60)),
 ("alcove wall 2",     R(1081,324,66,12)),
 ("alcove wall 3",     R(1081,384,66,12)),
 ("alcove wall 4",     R(1081,480,66,12)),
 ("office N wall a",   R(1162,228,120,12)), ("office N wall b", R(1306,228,78,12)),
 ("office W corr a",   R(1171,279,12,90)),  ("office W corr b", R(1171,393,12,33)),
 ("atrium N wall",     R(1204,261,48,12)),
 ("atrium W wall",     R(1240,258,12,57)),
 ("office S wall a",   R(1168,411,48,12)),  ("office S wall b", R(1243,411,63,12)),
 ("S room wall W",     R(1273,372,12,51)),  ("S room wall E", R(1333,372,12,51)),
 ("helipad N wall a",  R(1174,444,144,12)), ("helipad N wall b", R(1342,444,27,12)),
 ("helipad W wall",    R(1177,441,12,141)),
 ("S junction wall",   R(1081,570,111,12)),
 ("S junction W wall", R(1084,570,12,48)),
 ("helipad parapet a", R(1192,663,84,12)),  ("helipad parapet b", R(1306,663,78,12)),
]
# ---------------- GLASS (window: true) ----------------
GLASS = [
 ("tilted skylight",   DG(610,255,682,185,34)),
 ("penthouse skylight",R(580,453,78,48)),
 ("NE skylight box",   R(937,252,120,66)),
 ("atrium well",       R(1270,261,96,120)),
]
# ---------------- FIXTURES (freestanding cover) ----------------
FIXTURES = [
 ("vent housing",      R(487,114,64,105)),
 ("AC pair",           R(532,321,72,45)),
 ("AC pipe",           R(598,336,30,12)),
 ("planter (moved)",   R(652,252,48,24)),
 ("planter W",          R(466,336,24,36)),
 ("NE vent row",       R(907,114,90,78)),
 ("NE rack",           R(880,276,45,96)),
 ("small dorito",      DM(827,207,15)),
 ("boiler big",        D(376,322,15)),
 ("boiler small",      D(378,404,12)),
 ("suite rack",        R(127,483,27,48)),
 ("water tank",        D(923,481,16)),
 ("tank barrel",       D(949,502,10)),
 ("crane mast (on void, art)", R(560,621,44,42)),
 ("crane counterweight (art)", R(516,627,38,30)),
 ("crane pad",          DM(520,392,16)),
 ("pallet stack",       R(575,382,30,22)),
 ("desk island",       R(1168,333,42,27)),
 ("curved desk a",     DG(1216,150,1246,168,10)),
 ("curved desk b",     DG(1244,166,1264,198,12)),
 ("scaffold",          DG(1150,621,1180,651,12)),
 ("exhaust housing",    R(800,552,36,51)),
 ("hoist crate",        R(936,368,40,55)),
 ("skylight housing",   R(57,423,46,48)),
]
TRENCHES = [
 ("seam tunnel trench",   (757,132,54,138)),
 ("court joint trench",   (573,300,84,54)),
 ("walk foxhole",         (1100,618,45,45)),
 ("NE deck foxhole",      (996,352,54,54)),
]
RED_HOME  = (244,552)
BLUE_HOME = (1205,390)
RED_SPAWN  = (75,45,150,150)
BLUE_SPAWN = (1195,500,150,150)
MEDKITS = [(782,200),(770,585)]

def render(shapes):
    im = Image.new("L",(W,H),0); d = ImageDraw.Draw(im)
    for name,(k,p) in shapes:
        if k=="rect": x,y,w,h=p; d.rectangle([x,y,x+w-1,y+h-1],fill=255)
        elif k=="disc": cx,cy,r=p; d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=255)
        elif k=="diam": cx,cy,r=p; d.polygon([(cx,cy-r),(cx+r,cy),(cx,cy+r),(cx-r,cy)],fill=255)
        elif k=="diag": x0,y0,x1,y1,t=p; d.line([x0,y0,x1,y1],fill=255,width=t)
    return im

mb = render(BOUNDARY); mw = render(WALLS); mg = render(GLASS); mf = render(FIXTURES)
for nm,im in [("boundary",mb),("walls",mw),("glass",mg),("fixtures",mf)]:
    print(nm, "white px:", int((np.asarray(im)>0).sum()))

solid = (np.asarray(mb)>0)|(np.asarray(mw)>0)|(np.asarray(mf)>0)
blockw = solid|(np.asarray(mg)>0)   # glass blocks walking
floor = ~blockw

# flag ring clearance
yy,xx = np.mgrid[0:H,0:W]
ring = (xx-CX)**2+(yy-CY)**2 <= FLAG_RING**2
print("solid px inside flag ring:", int((solid&ring).sum()), " glass:", int(((np.asarray(mg)>0)&ring).sum()))

# connectivity / sealed pockets
lab,n = ndimage.label(floor)
sizes = ndimage.sum(floor,lab,range(1,n+1))
main = 1+int(np.argmax(sizes))
print("floor components:", n, "sizes:", sorted([int(s) for s in sizes],reverse=True)[:8])
def comp(p): return lab[p[1],p[0]]
pts = {"redHome":RED_HOME,"blueHome":BLUE_HOME,"center":(CX,CY),
       "medkit1":MEDKITS[0],"medkit2":MEDKITS[1],
       "redSpawnC":(RED_SPAWN[0]+75,RED_SPAWN[1]+75),"blueSpawnC":(BLUE_SPAWN[0]+75,BLUE_SPAWN[1]+75),
       "girder walk W":(550,675),"girder walk E":(1000,675),"gantry bay":(775,85),"seam mid":(785,220),
       "penthouse int":(730,480),"rig bay":(750,630),"helipad":(1284,566),
       "machine rm":(350,290),"E office":(1155,255)}
for k,p in pts.items():
    print(f"  {k}: comp {comp(p)} {'OK' if comp(p)==main else 'NOT-MAIN!'}")

# BFS walk distances
def bfs(src):
    dist = np.full((H,W),-1,np.int32); q=deque()
    if not floor[src[1],src[0]]: return None
    dist[src[1],src[0]]=0; q.append(src)
    while q:
        x,y=q.popleft()
        for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
            nx,ny=x+dx,y+dy
            if 0<=nx<W and 0<=ny<H and floor[ny,nx] and dist[ny,nx]<0:
                dist[ny,nx]=dist[y,x]+1; q.append((nx,ny))
    return dist
dr = bfs(RED_HOME); db = bfs(BLUE_HOME)
print("walk red home -> center:", dr[CY,CX], " blue home -> center:", db[CY,CX])
print("walk red -> blue home:", dr[BLUE_HOME[1],BLUE_HOME[0]])
print("walk redSpawnC -> center:", bfs((RED_SPAWN[0]+75,RED_SPAWN[1]+75))[CY,CX],
      " blueSpawnC -> center:", bfs((BLUE_SPAWN[0]+75,BLUE_SPAWN[1]+75))[CY,CX])

# open-row / open-col check (full-width open lines through playable area)
maxrun=0; worst=0
for y in range(12,688):
    row = solid[y,16:1384]
    runs = np.diff(np.where(np.concatenate(([1],row,[1])))[0])-1
    r = runs.max() if len(runs) else 0
    if r>maxrun: maxrun, worst = r, y
print("longest open row segment:", maxrun, "at y=",worst)
maxc=0; worstc=0
for x in range(16,1384):
    col = solid[12:688,x]
    runs = np.diff(np.where(np.concatenate(([1],col,[1])))[0])-1
    r = runs.max() if len(runs) else 0
    if r>maxc: maxc,worstc=r,x
print("longest open col segment:", maxc, "at x=",worstc)

# mirror-asymmetry: IoU of solid left half vs flipped right half
L = solid[:,:W//2]; Rh = solid[:,W//2:][:, ::-1]
inter = (L&Rh).sum(); union=(L|Rh).sum()
print(f"mirror IoU {inter/union:.3f}  -> asymmetry {(1-inter/union)*100:.1f}%")

# medkit clearance
dist_to_wall = ndimage.distance_transform_edt(~blockw)
for i,(mx,my) in enumerate(MEDKITS):
    print(f"medkit{i+1} clearance: {dist_to_wall[my,mx]:.0f}px")
print(f"center clearance: {dist_to_wall[CY,CX]:.0f}px")

# save masks
import os
HERE = os.path.dirname(os.path.abspath(__file__))
mb.save(os.path.join(HERE,"boundary.png")); mw.save(os.path.join(HERE,"walls.png"))
mg.save(os.path.join(HERE,"glass.png")); mf.save(os.path.join(HERE,"fixtures.png"))

# plan view
pv = Image.new("RGB",(W,H),(52,54,58))
arr = np.zeros((H,W,3),np.uint8); arr[...] = (70,72,76)          # deck floor
arr[np.asarray(mb)>0] = (24,26,30)                                # void/oob
arr[np.asarray(mw)>0] = (235,235,230)                             # walls
arr[np.asarray(mg)>0] = (110,190,230)                             # glass
arr[np.asarray(mf)>0] = (200,160,80)                              # fixtures
pv = Image.fromarray(arr); d = ImageDraw.Draw(pv)
for nm,(x,y,w,h) in TRENCHES: d.rectangle([x,y,x+w,y+h],outline=(120,90,60),width=3)
d.ellipse([CX-FLAG_RING,CY-FLAG_RING,CX+FLAG_RING,CY+FLAG_RING],outline=(80,200,255),width=2)
for (hx,hy),c in [(RED_HOME,(255,80,80)),(BLUE_HOME,(90,120,255))]:
    d.ellipse([hx-8,hy-8,hx+8,hy+8],outline=c,width=3)
for (sx,sy,sw,sh),c in [(RED_SPAWN,(255,80,80)),(BLUE_SPAWN,(90,120,255))]:
    d.rectangle([sx,sy,sx+sw,sy+sh],outline=c,width=2)
for mx,my in MEDKITS: d.ellipse([mx-6,my-6,mx+6,my+6],outline=(90,230,120),width=3)
d.ellipse([1284-72,566-72,1284+72,566+72],outline=(180,180,180),width=2)  # helipad art
d.text((1272,552),"H",fill=(220,220,220))
labels = [(120,120,"RED SPAWN DECK"),(300,320,"MACHINE RM"),(200,450,"OFFICE SUITE"),
          (370,90,"corr"),(560,250,"MID DECK W"),(770,85,"GANTRY"),(778,230,"SEAM"),
          (660,380,"FLAG COURT"),(740,485,"OFFICES PENTHOUSE"),(960,370,"NE DECK"),
          (740,630,"RIG BAY"),(700,672,"GIRDER WALK"),(1240,300,"E OFFICES"),
          (1280,560,"HELIPAD"),(1310,315,"atrium")]
for x,y,t in labels: d.text((x,y),t,fill=(255,220,120))
pv.convert("RGB").save("/tmp/highrise_plan_view.jpg",quality=90)
print("saved masks + plan view")
