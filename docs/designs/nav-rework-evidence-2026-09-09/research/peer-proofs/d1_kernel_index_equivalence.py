import math
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
checked=0; mismatches=0; outside=0
for r in [42,163]:
    D=2*r+1
    for (ox,oy) in [(0,0),(1000,777),(-5,3)]:
        origin_index_old=(oy-oy+r)*D+(ox-ox+r); origin_index_new=r*D+r
        assert origin_index_old==origin_index_new
        for (dx,dy) in perimeter(r):
            nx,ny=abs(dx),abs(dy); sx=(dx>0)-(dx<0); sy=(dy>0)-(dy<0)
            ix=iy=0; x,y=ox,oy
            decision=ny-nx; dX=2*ny; dY=2*nx
            kstepY=sy*D; k=r*D+r
            while ix<nx or iy<ny:
                if decision==0:
                    sideX=x+sx; sideY=y+sy
                    # side adds use pre-move index
                    for (gx,gy,kk) in [(sideX,y,k+sx),(x,sideY,k+kstepY)]:
                        old=(gy-oy+r)*D+(gx-ox+r); checked+=1
                        if old!=kk: mismatches+=1
                        if not (0<=kk<D*D): outside+=1
                    x=sideX; y=sideY; ix+=1; iy+=1; decision+=dX-dY; k+=sx+kstepY
                elif decision<0:
                    x+=sx; ix+=1; decision+=dX; k+=sx
                else:
                    y+=sy; iy+=1; decision-=dY; k+=kstepY
                old=(y-oy+r)*D+(x-ox+r); checked+=1
                if old!=k: mismatches+=1
                if not (0<=k<D*D): outside+=1
print("checked",checked,"mismatches",mismatches,"indices outside kernel",outside)
