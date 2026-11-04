"""Read-only native edge context and identity targets for original Ruby editors."""
import math
from PySide6.QtGui import QMatrix4x4, QVector3D

_MAX_OVERLAP_COMPARISONS=250_000


def _guard_overlapping_context(edges, world):
    """Do not import a native edge as only one of several Ruby fragments.

    SketchUp's Ruby tolerance is 0.001 inch. Partially overlapping edges in
    the connected context are split by the Ruby topology importer; it cannot
    currently map the individual fragments back to their native identities.
    Merely marking all fragments as proxies would hide the resulting leak but
    leave subsequent moves or erasures mapped to the wrong native edge.
    """
    tolerance=0.001*0.0254
    tolerance2=tolerance*tolerance
    records=[]
    for edge in edges:
        a,b=world(edge.a),world(edge.b)
        if not all(math.isfinite(v) for p in (a,b) for v in p.toTuple()):
            raise ValueError('Cannot inspect native edges with non-finite coordinates.')
        length_squared=(b-a).lengthSquared()
        if not math.isfinite(length_squared):
            raise ValueError('Cannot inspect native edges with an excessively large extent.')
        if length_squared<=tolerance2:
            raise ValueError('A native edge is too short to inspect safely in the extension.')
        coordinates=[a.toTuple(),b.toTuple()]
        bounds=[(min(p[i] for p in coordinates),max(p[i] for p in coordinates)) for i in range(3)]
        records.append((edge,a,b,bounds))
    if len(records)<2:
        return
    axis=max(range(3),key=lambda i:max(r[3][i][1] for r in records)-min(r[3][i][0] for r in records))
    records.sort(key=lambda r:r[3][axis][0])
    active=[];comparisons=0
    for edge,a,b,bounds in records:
        # Count the broad-phase filtering too, so a dense context cannot hang
        # the UI in a quadratic scan before the narrow-phase budget applies.
        comparisons+=len(active)
        if comparisons>_MAX_OVERLAP_COMPARISONS:
            raise ValueError('Selected native edge context is too complex to check safely.')
        active=[r for r in active if r[3][axis][1]>=bounds[axis][0]-tolerance]
        for other_edge,c,d,other in active:
            if other_edge is edge:
                continue
            if any(bounds[i][1]<other[i][0]-tolerance or other[i][1]<bounds[i][0]-tolerance for i in range(3)):
                continue
            direction=b-a; length=math.sqrt(direction.lengthSquared());unit=direction/length
            distances=(QVector3D.crossProduct(c-a,unit).lengthSquared(),
                       QVector3D.crossProduct(d-a,unit).lengthSquared())
            if not all(math.isfinite(distance) for distance in distances):
                raise ValueError('Cannot inspect native edges with an excessively large extent.')
            if any(distance>tolerance2 for distance in distances):
                continue
            start=QVector3D.dotProduct(c-a,unit);end=QVector3D.dotProduct(d-a,unit)
            if min(length,max(start,end))-max(0,min(start,end))<=tolerance:
                continue
            # Even identical but distinct native edges would collapse onto one
            # Ruby edge and one token; only reuse of the same object is safe.
            raise ValueError('Selected native edge context has overlapping edges that cannot yet be edited safely.')
        active.append((edge,a,b,bounds))


def world_normal(face, matrix):
    """Return the oriented normal of the actual world-space face boundary.

    Mapping a normal as an ordinary direction is incorrect for nonuniform
    scales and reflections. Computing from transformed vertices matches the
    native world mesh, including its winding under mirrored placements.
    """
    if matrix is None:
        return face.normal()
    points=[matrix.map(point) for point in face.vertices]
    if len(points)<3:
        raise ValueError('Cannot inspect a native face without a valid boundary.')
    if not all(math.isfinite(value) for point in points for value in point.toTuple()):
        raise ValueError('Cannot inspect a native face with a non-finite transform.')
    origin=points[0]
    normal=QVector3D()
    for i in range(1,len(points)-1):
        normal+=QVector3D.crossProduct(points[i]-origin,points[i+1]-origin)
    length_squared=normal.lengthSquared()
    if not math.isfinite(length_squared) or length_squared<=0:
        raise ValueError('Cannot inspect a native face collapsed by its transform.')
    return normal.normalized()


def surface_records(host,face,mesh,matrix,scene):
    """Give every imported face boundary its native edge identity."""
    from .surface_edges import records
    result=records(face,mesh,matrix,scene)
    edges=[]
    for ring in [face.loop,*face.hole_loops]:
        for a,b in zip(ring,ring[1:]+ring[:1]):
            edge=mesh.find_edge(a,b)
            if edge is not None:edges.append(edge)
    targets=host.__dict__.setdefault('_edge_targets',{})
    for record,edge in zip(result,edges):
        token=str(id(edge));record['token']=token;targets[token]=(mesh,edge,matrix)
    return result


def context(host, edge, mesh, matrix, selected=None):
    selected=selected or set()
    pending=[edge];seen=set();edges=[];faces=set()
    while pending:
        item=pending.pop()
        if id(item) in seen:continue
        seen.add(id(item));edges.append(item);faces.update(item.faces)
        for vertex in (item.v0,item.v1):
            pending.extend(other for other in vertex.edges if id(other) not in seen)
    order={id(item):index for index,item in enumerate(mesh.edges)}
    edges.sort(key=lambda item:order[id(item)])
    world=matrix.map if matrix is not None else lambda point:point
    _guard_overlapping_context(edges,world)
    targets=host.__dict__.setdefault('_edge_targets',{})
    surface_targets=host.__dict__.setdefault('_surface_targets',{})
    records=[]
    from .surface_paint import proxy_attrs
    for face in mesh.faces:
        if face not in faces:continue
        token=str(id(face));surface_targets[token]=(mesh,face,QMatrix4x4(matrix) if matrix is not None else None)
        host._face_tokens[token]=(mesh,face)
        normal=world_normal(face,matrix)
        records.append(dict(kind='face',token=token,_context_only=True,
            outer=[list(world(p).toTuple()) for p in face.vertices],
            holes=[[list(world(p).toTuple()) for p in ring] for ring in face.holes],
            attrs=dict(face.attrs),
            proxy_attrs=proxy_attrs(face.attrs,matrix,face.normal(),QVector3D),
            normal=list(normal.toTuple())))
        records[-1]['edge_properties']=surface_records(host,face,mesh,matrix,host.app.scene)
    for item in edges:
        token=str(id(item));targets[token]=(mesh,item,matrix)
        records.append(dict(kind='edge',token=token,_context_only=id(item) not in selected,
            a=list(world(item.a).toTuple()),b=list(world(item.b).toTuple()),
            soft=bool(item.soft),hidden=bool(item.hidden),layer=item.layer,curve=getattr(item,'curve',None)))
    return records


def apply(mesh, edge, points, flags, matrix):
    if points is not None:
        from PySide6.QtGui import QVector3D
        inverse,valid=matrix.inverted() if matrix is not None else (QMatrix4x4(),True)
        if not valid:raise ValueError('Cannot edit an edge through a singular transform.')
        # The Ruby endpoints are world coordinates. Move shared native vertices
        # before rebuilding adjacent faces, so their topology follows the edit.
        mesh.place_vertex(edge.v0,inverse.map(QVector3D(*points[0])))
        mesh.place_vertex(edge.v1,inverse.map(QVector3D(*points[1])))
        edge.soft=bool(flags.get('soft',False));edge.hidden=bool(flags.get('hidden',False))
        edge.layer=None if flags.get('layer') in ('Layer0','Untagged') else flags.get('layer')
    elif edge in mesh.edges:
        # Face-context boundaries may have been replaced by a surface patch.
        # Never detach an edge which still supports a surviving native face.
        if not flags.get('surface_boundary') or not edge.faces:mesh.remove_edge(edge)
