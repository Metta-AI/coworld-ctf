import math, sys
def pyround(v):
    lower = math.floor(v); frac = v - lower
    if frac > 0.5 or (frac == 0.5 and lower % 2 == 1): return lower + 1
    return lower
def perimeter(r):
    seen = []; s = set()
    def inc(dx, dy):
        if (dx, dy) not in s: s.add((dx, dy)); seen.append((dx, dy))
    for dx in range(-r, r + 1):
        dy = pyround(math.sqrt(max(0, r*r - dx*dx))); inc(dx, dy); inc(dx, -dy)
    for dy in range(-r, r + 1):
        dx = pyround(math.sqrt(max(0, r*r - dy*dy))); inc(dx, dy); inc(-dx, dy)
    return seen
def walk(dx, dy):
    nx, ny = abs(dx), abs(dy); sx = (dx > 0) - (dx < 0); sy = (dy > 0) - (dy < 0)
    ix = iy = 0; x = y = 0; steps = []
    while ix < nx or iy < ny:
        d = (1 + 2*ix)*ny - (1 + 2*iy)*nx
        if d == 0: x += sx; y += sy; ix += 1; iy += 1; steps.append(('XY', x, y, (x, y - sy), (x - sx, y)))
        elif d < 0: x += sx; ix += 1; steps.append(('X', x, y, None, None))
        else: y += sy; iy += 1; steps.append(('Y', x, y, None, None))
    return steps
for r in [42, 163, 255]:
    per = perimeter(r)
    total = 0; side_adds = 0
    trie = {}  # nested dict keyed by (kind, sx, sy) tuples along the path
    nodes = 0
    cells = set(); cells_with_side = set()
    depth_nodes = {}
    for (dx, dy) in per:
        sx = (dx > 0) - (dx < 0); sy = (dy > 0) - (dy < 0)
        node = trie.setdefault((sx, sy), {})
        st = walk(dx, dy)
        total += len(st)
        for depth, (k, x, y, s1, s2) in enumerate(st):
            cells.add((x, y))
            if k == 'XY': side_adds += 2; cells_with_side.add(s1); cells_with_side.add(s2)
            key = k
            if key not in node:
                node[key] = {}; nodes += 1; depth_nodes[depth] = depth_nodes.get(depth, 0) + 1
            node = node[key]
    disc = sum(1 for x in range(-r, r+1) for y in range(-r, r+1) if x*x + y*y <= r*r)
    # cell multiplicity: how many rays pass through each cell (without walls)
    mult = {}
    for (dx, dy) in per:
        for (k, x, y, s1, s2) in walk(dx, dy): mult[(x, y)] = mult.get((x, y), 0) + 1
    avg_mult = sum(mult.values()) / len(mult)
    # nodes by radial band
    band = {}
    for (dx, dy) in per:
        pass
    print(f"radius {r}: rays {len(per)} total_steps {total} diag_side_adds {side_adds} trie_nodes {nodes} unique_cells {len(cells)} (+side {len(cells_with_side - cells)}) disc_cells {disc} steps/node {total/nodes:.2f} steps/unique_cell {total/len(cells):.2f} nodes/unique_cell {nodes/len(cells):.2f}")
    # sharing by depth: nodes at depth vs rays alive at depth
    alive = {}
    for (dx, dy) in per:
        for depth in range(len(walk(dx, dy))): alive[depth] = alive.get(depth, 0) + 1
    for d in [0, 1, 2, 4, 8, 16, 32, 64, 128, 200]:
        if d in alive: print(f"   depth {d}: rays alive {alive[d]} trie nodes {depth_nodes.get(d,0)}")
