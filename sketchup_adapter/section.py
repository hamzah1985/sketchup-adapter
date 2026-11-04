"""Per-object Plane cutaways, with the intact source retained for removal."""
from PySide6.QtGui import QVector3D, QMatrix4x4
from .precision import detail_mesh_class

SOURCE_KEY = 'bogdan_section_source'


def _dot(a, b):
    return QVector3D.dotProduct(a, b)


def clipped_mesh(mesh, point, normal):
    from core.section import fill_triangles
    import numpy as np
    result = detail_mesh_class()()
    chords = []
    closed = bool(mesh.faces) and all(len(e.faces) == 2 for e in mesh.edges if e.faces)
    for face in mesh.faces:
        distances = [_dot(p - point, normal) for p in face.vertices]
        if all(d <= 1e-8 for d in distances):
            f = result.add_face(face.vertices, face.holes)
            f.attrs.update(face.attrs)
            continue
        if all(d > 1e-8 for d in distances):
            continue
        for triangle in face.triangulate():
            output, crossings = [], []
            for a, b in zip(triangle, (*triangle[1:], triangle[0])):
                da, db = _dot(a - point, normal), _dot(b - point, normal)
                if da <= 1e-8:
                    output.append(a)
                if (da < -1e-8 and db > 1e-8) or (da > 1e-8 and db < -1e-8):
                    cross = a + (b - a) * (da / (da - db))
                    output.append(cross)
                    crossings.append(cross)
            if len(crossings) == 2:
                chords.append([p.toTuple() for p in crossings])
            if len(output) >= 3:
                f = result.add_face(output)
                f.attrs.update(face.attrs)
    for edge in mesh.edges:
        if edge.faces:
            continue
        a, b = edge.a, edge.b
        da, db = _dot(a - point, normal), _dot(b - point, normal)
        if da > 1e-8 and db > 1e-8:
            continue
        if (da > 1e-8) != (db > 1e-8):
            cross = a + (b - a) * (da / (da - db))
            if da > 1e-8: a = cross
            else: b = cross
        if (a - b).lengthSquared() > 1e-16:
            result.add_edge(a, b)
    if closed and chords:
        for triangle in fill_triangles(np.asarray(chords), normal):
            pts = [QVector3D(*p) for p in triangle]
            if _dot(QVector3D.crossProduct(pts[1]-pts[0], pts[2]-pts[0]), normal) < 0:
                pts.reverse()
            result.add_face(pts).attrs.update({'color':[0.35,0.37,0.41]})
    return result


def apply_sections(root, payload):
    protos = payload['protos']
    if not any(p.get('section_planes') for p in protos):
        return
    root.ext[SOURCE_KEY] = payload

    def apply(group, index, inherited):
        own = [(QVector3D(*p['point']), QVector3D(*p['normal']))
               for p in protos[index].get('section_planes', []) if p.get('active')]
        planes = inherited + own
        for point, normal in planes:
            group.mesh = clipped_mesh(group.mesh, point, normal)
        for child, item in zip(group.children, protos[index].get('children', [])):
            transform = child.xform or QMatrix4x4()
            inverse, invertible = transform.inverted()
            if not invertible:
                raise ValueError('Cannot apply a cutaway through a singular transform.')
            transformed = []
            for point, normal in planes:
                n = QVector3D(*[_dot(transform.column(i).toVector3D(), normal) for i in range(3)])
                length = n.length()
                if length > 1e-12:
                    transformed.append((inverse.map(point), n / length))
            apply(child, item['proto'], transformed)
    apply(root, payload['root'], [])


def source_snapshot(group, payload):
    def build(index, instance, depth=0):
        if depth >= 64:
            raise ValueError('Cutaway source exceeds the supported nesting depth.')
        proto = payload['protos'][index]
        return {'name':instance.get('name',proto.get('name','')),
                'component':instance.get('component',False), 'xform':instance.get('xform'),
                'hidden':instance.get('hidden',False), 'faces':proto['faces'],
                'edges':proto.get('edges',[]), 'attrs':instance.get('attrs',{}),
                'def_attrs':proto.get('def_attrs',{}),
                'section_planes':proto.get('section_planes',[]),
                'children':[build(c['proto'],c,depth+1) for c in proto.get('children',[])]}
    result = build(payload['root'],payload)
    result['uid'] = group.uid
    result['xform'] = [float(v) for v in group.xform.data()] if group.xform is not None else None
    result['name'] = group.name
    result['hidden'] = group.hidden
    result['def_attrs'] = payload.get('def_attrs',{})
    return result
