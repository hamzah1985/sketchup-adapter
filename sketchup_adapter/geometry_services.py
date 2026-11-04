"""Read-only scene rays and off-document solid operations for Ruby."""
import numpy as np
from PySide6.QtGui import QVector3D, QMatrix4x4


def _contains_face(point, face):
    normal=face.normal();drop=max(range(3),key=lambda i:abs(normal.toTuple()[i]))
    axes=[i for i in range(3) if i!=drop]
    px,py=[point.toTuple()[i] for i in axes]
    def ring_state(ring):
        xy=[[p.toTuple()[i] for i in axes] for p in ring];inside=False
        for (ax,ay),(bx,by) in zip(xy,xy[1:]+xy[:1]):
            dx,dy=bx-ax,by-ay
            cross=(px-ax)*dy-(py-ay)*dx
            if abs(cross)<1e-8 and min(ax,bx)-1e-8<=px<=max(ax,bx)+1e-8 and min(ay,by)-1e-8<=py<=max(ay,by)+1e-8:return 2
            if (ay>py)!=(by>py) and px < ax+(py-ay)*dx/(by-ay):inside=not inside
        return 1 if inside else 0
    outer=ring_state(face.vertices)
    if not outer:return False
    return all(ring_state(hole)!=1 for hole in face.holes)


def _face_snapshot(face, transform=None, owner=None):
    point=lambda p:list((transform.map(p) if transform is not None else p).toTuple())
    return {'name':getattr(owner,'name','') or 'Ray hit',
            'faces':[[[point(p) for p in face.vertices],
                      [[point(p) for p in ring] for ring in face.holes],dict(face.attrs)]],
            'edges':[],'children':[],'component':False,'attrs':{}}


def scene_raytest(host,message):
    vp=host.app.viewport
    origin=QVector3D(*message['origin']);direction=QVector3D(*message['direction']).normalized()
    if direction.lengthSquared()<1e-18:raise ValueError('A ray needs a direction')
    idx=vp._pick_index(near=('ray',origin,direction))
    times=vp._ray_hits(idx,origin,direction,idx.ent_vis,reduce_global=False)
    best=None
    if times is not None and len(times):
        i=int(np.argmin(times));distance=float(times[i])
        if np.isfinite(distance):
            face,owner=idx.entities[i]
            pidx=getattr(idx,'ent_place_idx',None)
            placement=(idx.ent_placements[int(pidx[i])] if pidx is not None and pidx[i]>=0 else owner)
            xf=getattr(placement,'xform',None)
            best=(distance,face,xf,placement)
    if not message.get('wysiwyg',True):
        # The normal native index intentionally omits hidden placements.
        from core.group import iter_placements
        from core.snap import face_plane_world
        collections=[(host.app.scene.loose_mesh,QMatrix4x4(),None)]
        for root in host.app.scene.groups:
            collections.extend((group.mesh,xf if xf is not None else QMatrix4x4(),group) for group,xf in iter_placements(root))
        for mesh,xf,group in collections:
            inverse,valid=xf.inverted()
            if not valid:continue
            for face in mesh.faces:
                anchor,normal=face_plane_world(face,xf)
                den=QVector3D.dotProduct(direction,normal)
                if abs(den)<1e-10:continue
                t=QVector3D.dotProduct(anchor-origin,normal)/den
                if t<=1e-8 or best is not None and t>=best[0]:continue
                hit=inverse.map(origin+direction*t)
                if _contains_face(hit,face):best=(t,face,xf,group)
    if best is None:return {'ok':True,'hit':None}
    distance,face,xf,owner=best
    return {'ok':True,'hit':{'point':list((origin+direction*distance).toTuple()),'geometry':_face_snapshot(face,xf,owner)}}


def solid_operation(host,message):
    from . import group_from_payload
    from core import solids
    first=group_from_payload(message['first']);second=group_from_payload(message['second'])
    # Native booleans weld on a 0.1 mm grid. Work in a translated millimetre
    # frame so that grid is 0.1 micrometre in the authored model, then return
    # an inverse placement. Source material/UV attributes stay untouched.
    from core.group import world_mesh
    points=[v.position for g in (first,second) for v in world_mesh(g).vertices]
    center=sum(points,QVector3D())/len(points) if points else QVector3D()
    transform=QMatrix4x4();transform.scale(1000);transform.translate(-center)
    for group in (first,second):group.xform=transform*(group.xform if group.xform is not None else QMatrix4x4())
    try:_,created=solids.run(message['action'],[first,second])
    except solids.SolidError as error:
        if str(error) in ('empty','no overlap'):return {'ok':True,'groups':[]}
        raise
    inverse,valid=transform.inverted()
    if not valid:raise ValueError('Invalid boolean coordinate frame')
    for group in created:group.xform=inverse*(group.xform if group.xform is not None else QMatrix4x4())
    return {'ok':True,'groups':[host._group_snapshot(group) for group in created]}
