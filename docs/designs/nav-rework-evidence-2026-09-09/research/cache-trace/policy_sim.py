import sys, glob
sys.path.insert(0, sys.argv[1])
from cache_sim import parse, rebuilds
from collections import OrderedDict
def run(rb, policy, cap):
    total = saved = hits = look = 0
    if policy == 'direct':
        slots = {}
        for sys_id, tick, seat, srcs in rb:
            for cell, steps in srcs:
                x, y = map(int, cell.split(':')); key = (sys_id, cell); total += steps; look += 1
                slot = (x * 73856093 ^ y * 19349663) % cap
                if slots.get(slot) == key: hits += 1; saved += steps
                else: slots[slot] = key
    elif policy == 'fifo':
        ring = OrderedDict()
        for sys_id, tick, seat, srcs in rb:
            for cell, steps in srcs:
                key = (sys_id, cell); total += steps; look += 1
                if key in ring: hits += 1; saved += steps
                else:
                    ring[key] = 1
                    if len(ring) > cap: ring.popitem(last=False)
    elif policy == 'lru':
        ring = OrderedDict()
        for sys_id, tick, seat, srcs in rb:
            for cell, steps in srcs:
                key = (sys_id, cell); total += steps; look += 1
                if key in ring: hits += 1; saved += steps; ring.move_to_end(key)
                else:
                    ring[key] = 1
                    if len(ring) > cap: ring.popitem(last=False)
    return saved / max(1, total), hits, look
for path in sorted(glob.glob(sys.argv[1] + '/runs/*/navsrc.txt')):
    rb = list(rebuilds(parse(path))); name = path.split('/')[-2]
    out = [name]
    for pol, cap in (('lru', 64), ('fifo', 64), ('fifo', 32), ('direct', 64), ('direct', 128), ('direct', 256)):
        r, h, l = run(rb, pol, cap); out.append(f"{pol}{cap}={r:.3f}")
    print(' '.join(out))
