"""Orient closed shells, including nested voids; preserve open surfaces."""
from collections import defaultdict


def _shell_candidates(shells):
    """Index shell bounds so disjoint parts do not require all-pairs scans."""
    if not shells:
        return lambda shell: ()
    axis=max(range(3),key=lambda i:max(s['bounds'][i][0] for s in shells)-min(s['bounds'][i][0] for s in shells))
    ordered=sorted(shells,key=lambda s:s['bounds'][axis][0])
    def build(start,end):
        if start>=end:return None
        middle=(start+end)//2;item=ordered[middle]
        left=build(start,middle);right=build(middle+1,end)
        high=max(item['bounds'][axis][1],left[3] if left else float('-inf'),right[3] if right else float('-inf'))
        return item,left,right,high
    tree=build(0,len(ordered))
    def candidates(shell):
        lo,hi=shell['bounds'][axis];pending=[tree]
        while pending:
            node=pending.pop()
            if node is None or node[3]<hi-1e-9:continue
            item,left,right,_=node
            if left is not None:pending.append(left)
            if item['bounds'][axis][0]<=lo+1e-9:
                if item['bounds'][axis][1]>=hi-1e-9:yield item
                if right is not None:pending.append(right)
    return candidates


def _inside_shell(point,shell):
    """Odd ray crossings, independent of the shell's current winding."""
    direction=(0.3713906763541037,0.5570860145311556,0.7427813527082074)
    def sub(a,b):return tuple(x-y for x,y in zip(a,b))
    def dot(a,b):return sum(x*y for x,y in zip(a,b))
    def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
    if 'triangles' not in shell:
        shell['triangles']=[tuple(p.toTuple() for p in triangle) for face in shell['faces'] for triangle in face.triangulate()]
    hits=[]
    for a,b,c in shell['triangles']:
        edge1,edge2=sub(b,a),sub(c,a);h=cross(direction,edge2);det=dot(edge1,h)
        if abs(det)<1e-18:continue
        offset=sub(point,a);u=dot(offset,h)/det
        if u < -1e-9 or u > 1+1e-9:continue
        q=cross(offset,edge1);v=dot(direction,q)/det
        if v < -1e-9 or u+v > 1+1e-9:continue
        distance=dot(edge2,q)/det
        if abs(distance)<1e-9:return False  # touching boundaries are not a void
        if distance>0:hits.append(distance)
    distinct=[]
    for distance in sorted(hits):
        if not distinct or abs(distance-distinct[-1])>1e-8:distinct.append(distance)
    return len(distinct)%2==1


def orient_solids(mesh):
    directions = defaultdict(list)
    face_edges = defaultdict(list)
    for face in mesh.faces:
        for loop in (face.loop, *face.hole_loops):
            for i, a in enumerate(loop):
                b = loop[(i+1) % len(loop)]
                ia, ib = id(a), id(b)
                if ia == ib:
                    continue
                key = tuple(sorted((ia, ib)))
                directions[key].append((face, ia < ib))
                face_edges[face].append(key)
    remaining = set(mesh.faces)
    repaired = 0
    shells=[]
    while remaining:
        seed = remaining.pop()
        queue = [seed]
        flags = {seed: False}
        closed = True
        coherent = True
        for face in queue:
            for key in face_edges[face]:
                uses = directions[key]
                if len(uses) != 2:
                    closed = False
                here = next((direction for f, direction in uses if f is face), False)
                for other, direction in uses:
                    if other is face:
                        continue
                    wanted = flags[face] ^ (here == direction)
                    if other in flags:
                        if flags[other] != wanted:
                            coherent = False
                    else:
                        flags[other] = wanted
                        queue.append(other)
                        remaining.discard(other)
        if not closed or not coherent:
            continue
        # Translation-relative double precision avoids signed-volume error on
        # small parts far from the model origin. Hole loops already oppose
        # the outer loop, so their signed fans subtract the void.
        origin = seed.loop[0].position.toTuple()
        volume = 0.0
        for face in queue:
            value = 0.0
            for loop in (face.loop, *face.hole_loops):
                points = [tuple(p-c for p,c in zip(v.position.toTuple(),origin)) for v in loop]
                a = points[0]
                for b,c in zip(points[1:-1], points[2:]):
                    value += (a[0]*(b[1]*c[2]-b[2]*c[1]) +
                              a[1]*(b[2]*c[0]-b[0]*c[2]) +
                              a[2]*(b[0]*c[1]-b[1]*c[0])) / 6
            volume += -value if flags[face] else value
        if abs(volume) < 1e-18:
            continue
        points=[v.position.toTuple() for face in queue for v in face.loop]
        bounds=tuple((min(p[i] for p in points),max(p[i] for p in points)) for i in range(3))
        shells.append(dict(faces=queue,flags=flags,volume=volume,bounds=bounds,point=origin))
    candidates=_shell_candidates(shells)
    for shell in shells:
        depth=0
        for other in candidates(shell):
            if other is shell:continue
            if not all(a>=c-1e-9 and b<=d+1e-9 for (a,b),(c,d) in zip(shell['bounds'],other['bounds'])):continue
            if _inside_shell(shell['point'],other):depth+=1
        # Alternating nested boundaries enclose a void, then an island, etc.
        # Making every connected shell outward would fill an interior cavity.
        inward=depth%2==1
        for face in shell['faces']:
            if shell['flags'][face] ^ (shell['volume'] < 0) ^ inward:
                face.loop.reverse()
                for loop in face.hole_loops:
                    loop.reverse()
                repaired += 1
    if repaired:
        mesh._chunk_dirty = True
    return repaired
