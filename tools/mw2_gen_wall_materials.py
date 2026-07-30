"""Procedural top-down cover materials, tiling seamlessly at 256x256.
Wrap-aware everywhere (np.roll / modular coords) so edges match exactly."""
import numpy as np
from PIL import Image
N=256
def noise(scale,seed,octaves=4):
    rng=np.random.default_rng(seed); out=np.zeros((N,N))
    amp=1.0; tot=0
    for o in range(octaves):
        s=max(2,int(scale/(2**o)))
        g=rng.random((s,s))
        # tile-safe upsample: wrap by sampling modulo s
        yi=(np.arange(N)*s//N)%s; xi=(np.arange(N)*s//N)%s
        layer=g[np.ix_(yi,xi)]
        # smooth with a wrap-safe box blur
        for _ in range(3):
            layer=(layer+np.roll(layer,1,0)+np.roll(layer,-1,0)
                   +np.roll(layer,1,1)+np.roll(layer,-1,1))/5.0
        out+=layer*amp; tot+=amp; amp*=0.5
    return out/tot

def norm(a): return (a-a.min())/max(float(np.ptp(a)),1e-6)

def build(name, base, spec):
    y,x=np.mgrid[0:N,0:N]
    v=norm(noise(*spec['noise']))
    if spec.get('ribs'):            # corrugated sheeting
        p=spec['ribs']; v=v*0.45+0.55*(0.5+0.5*np.sin(2*np.pi*x*p/N))
    if spec.get('panels'):          # panel seams + rivet rows
        p=spec['panels']
        seam=((x%p<2)|(y%(p*2)<2)).astype(float)
        v=v*0.85-seam*0.22
        if spec.get('rivets'):
            r=(((x+p//2)%p==0)&((y+p//2)%(p//2)==0)).astype(float)
            v=v+r*0.18
    if spec.get('courses'):         # block/brick coursing, staggered
        ch,cw=spec['courses']
        row=(y//ch); off=(row%2)*(cw//2)
        m=(((x+off)%cw)<2)|((y%ch)<2)
        v=v*0.88-m.astype(float)*0.20
    if spec.get('cracks'):          # rock fissures
        c=norm(noise(spec['cracks'],spec['noise'][1]+7,3))
        v=v-0.30*np.exp(-((c-0.5)**2)/0.0009)
    v=np.clip(v,0,1)
    v=0.5+(v-v.mean())*spec.get('contrast',0.55)
    img=np.stack([np.clip(base[i]*(0.62+0.76*v),0,255) for i in range(3)],-1)
    Image.fromarray(img.astype(np.uint8)).save(
        f'data/{name}_wall.png')
    g=img.mean(2)
    print(f"{name:10} lum={g.mean():5.1f} std={g.std():4.1f}")

build('rust',(105,67,43),  dict(noise=(24,1),ribs=16,contrast=0.85))
build('terminal',(150,151,148),dict(noise=(28,2),panels=32,rivets=False,contrast=0.5))
build('highrise',(96,96,95),dict(noise=(20,3),panels=64,contrast=0.55))
build('favela',(198,142,109), dict(noise=(18,4),courses=(26,52),contrast=0.8))
build('afghan',(149,128,98),dict(noise=(16,5),cracks=22,contrast=0.75))
build('scrapyard',(156,158,158),dict(noise=(30,6),panels=40,rivets=True,contrast=0.6))
