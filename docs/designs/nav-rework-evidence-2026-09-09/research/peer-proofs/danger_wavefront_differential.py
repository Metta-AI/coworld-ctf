import math, random, sys, time
def pyround(v):
    lower = math.floor(v); frac = v - lower
    return lower + 1 if (frac > 0.5 or (frac == 0.5 and lower % 2 == 1)) else lower
def perimeter(r):
    seen=[]; s=set()
    def inc(dx,dy):
        if (dx,dy) not in s: s.add((dx,dy)); seen.append((dx,dy))
    for dx in range(-r,r+1):
        dy=pyround(math.sqrt(max(0,r*r-dx*dx))); inc(dx,dy); inc(dx,-dy)
    for dy in range(-r,r+1):
        dx=pyround(math.sqrt(max(0,r*r-dy*dy))); inc(dx,dy); inc(-dx,dy)
    return seen
# ---- exact current visitor (castRay + addVisibleCell stamp semantics), relative coords with a blocked predicate
def exact_visit(per, blocked):
    """blocked(dx,dy) -> True if wall or out of grid. Returns set of added relative cells (excluding origin)."""
    added=set()
    for (dx,dy) in per:
        nx,ny=abs(dx),abs(dy); sx=(dx>0)-(dx<0); sy=(dy>0)-(dy<0)
        ix=iy=0; x=y=0
        while ix<nx or iy<ny:
            d=(1+2*ix)*ny-(1+2*iy)*nx
            if d==0:
                sX=x+sx; sY=y+sy
                if blocked(sX,y) or blocked(x,sY): break
                added.add((sX,y)); added.add((x,sY))
                x=sX; y=sY; ix+=1; iy+=1
            elif d<0: x+=sx; ix+=1
            else: y+=sy; iy+=1
            if blocked(x,y): break
            added.add((x,y))
    return added
# ---- membership precompute: for each relative cell, the set of ray ids that check/visit it (no walls), keyed with Manhattan distance
def memberships(per):
    mem={}  # (dx,dy) -> set(ray ids)
    for rid,(dx,dy) in enumerate(per):
        nx,ny=abs(dx),abs(dy); sx=(dx>0)-(dx<0); sy=(dy>0)-(dy<0)
        ix=iy=0; x=y=0
        while ix<nx or iy<ny:
            d=(1+2*ix)*ny-(1+2*iy)*nx
            if d==0:
                sX=x+sx; sY=y+sy
                mem.setdefault((sX,y),set()).add(rid); mem.setdefault((x,sY),set()).add(rid)
                x=sX; y=sY; ix+=1; iy+=1
            elif d<0: x+=sx; ix+=1
            else: y+=sy; iy+=1
            mem.setdefault((x,y),set()).add(rid)
    return mem
def wavefront(per, mem, blocked):
    active=set(range(len(per)))
    shells={}
    for cell,rays in mem.items(): shells.setdefault(abs(cell[0])+abs(cell[1]),[]).append(cell)
    added=set()
    for D in sorted(shells):
        cells=shells[D]
        # pass 1: remove rays whose check at this distance is blocked
        for c in cells:
            if blocked(*c): active -= mem[c]
        # pass 2: add visible cells with an active member
        for c in cells:
            if not blocked(*c) and (mem[c] & active): added.add(c)
    return added
def make_blocked(walls, W, H, ox, oy):
    def blocked(dx,dy):
        x=ox+dx; y=oy+dy
        if x<0 or x>=W or y<0 or y>=H: return True
        return (x,y) in walls
    return blocked
rng=random.Random(20260909)
report=[]
for r in [42,163]:
    per=perimeter(r); mem=memberships(per)
    t0=time.time()
    trials=0; mismatches=0
    # exhaustive single-wall in a box near origin (all positions within Chebyshev 10 for r=42, 6 for r=163), plus far single walls
    box = 10 if r==42 else 5
    W=H=2*r+40; ox=oy=r+20
    for wx in range(-box,box+1):
        for wy in range(-box,box+1):
            if wx==0 and wy==0: continue
            walls={(ox+wx,oy+wy)}
            b=make_blocked(walls,W,H,ox,oy)
            a=exact_visit(per,b); w=wavefront(per,mem,b); trials+=1
            if a!=w:
                mismatches+=1
                if mismatches<=3: print("MISMATCH single wall r",r,"wall",(wx,wy),"exact-only",sorted(a-w)[:5],"wave-only",sorted(w-a)[:5])
    # random walls, random origins including near the grid edge
    ntr = 300 if r==42 else 25
    for t in range(ntr):
        density=rng.choice([0.02,0.05,0.1,0.2,0.35])
        W=rng.randint(r//2, 2*r+10); H=rng.randint(r//2, 2*r+10)
        walls=set((x,y) for x in range(W) for y in range(H) if rng.random()<density)
        ox=rng.randint(0,W-1); oy=rng.randint(0,H-1); walls.discard((ox,oy))
        b=make_blocked(walls,W,H,ox,oy)
        a=exact_visit(per,b); w=wavefront(per,mem,b); trials+=1
        if a!=w:
            mismatches+=1
            if mismatches<=3: print("MISMATCH random r",r,"W,H",W,H,"origin",(ox,oy),"density",density,"exact-only",sorted(a-w)[:5],"wave-only",sorted(w-a)[:5])
    # membership statistics with angle-sorted ids
    order=sorted(range(len(per)), key=lambda i: math.atan2(per[i][1],per[i][0]))
    rank={rid:k for k,rid in enumerate(order)}
    cells=len(mem); totalmem=sum(len(s) for s in mem.values())
    intervals=0; words=0; maxint=0; maxwords=0
    for c,s in mem.items():
        ks=sorted(rank[i] for i in s)
        iv=1
        for i in range(1,len(ks)):
            if ks[i]!=ks[i-1]+1: iv+=1
        intervals+=iv; maxint=max(maxint,iv)
        wd=len(set(k//64 for k in ks)); words+=wd; maxwords=max(maxwords,wd)
    print(f"radius {r}: rays {len(per)} cells {cells} memberships {totalmem} (avg {totalmem/cells:.2f}/cell) angular intervals total {intervals} (avg {intervals/cells:.2f}, max {maxint}) 64-bit words total {words} (avg {words/cells:.2f}, max {maxwords}) trials {trials} mismatches {mismatches} time {time.time()-t0:.1f}s")
    # memory estimate: per cell 4 B coords + intervals*4 B (two uint16) ; or words*(1+8) B
    print(f"   est bytes: interval encoding {cells*4 + intervals*4:,}; sparse-word encoding {cells*4 + words*9:,}; active bitset {math.ceil(len(per)/64)*8} B per source")
