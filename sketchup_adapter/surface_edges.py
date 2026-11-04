"""Persist SketchUp's extra edge flags on native face attributes, through history."""
KEY='_sketchup_edge_properties'
STATE_KEY='__surface_edge_properties__'
def key(points):return tuple(sorted(tuple(round(float(v),6) for v in p) for p in points))
def face_key(scene,mesh,points):
    import hashlib,json
    owner='loose'
    if mesh is not scene.loose_mesh:
        from core.group import iter_placements
        owner=next((g.uid for top in scene.groups for g,_ in iter_placements(top) if g.mesh is mesh),'unknown')
    return owner+':'+hashlib.sha256(json.dumps(key(points)).encode()).hexdigest()
def records(face,mesh,matrix=None,scene=None):
    annotations=face.attrs.get(KEY,[])
    if not annotations and scene is not None:
        table=scene.plugin_data.get('sketchup_adapter',{}).get(STATE_KEY,{})
        annotations=table.get(face_key(scene,mesh,[p.toTuple() for p in face.vertices]),[])
    saved={key(item['points']):item for item in annotations}
    world=matrix.map if matrix is not None else lambda point:point
    result=[]
    for ring in [face.loop,*face.hole_loops]:
        for a,b in zip(ring,ring[1:]+ring[:1]):
            edge=mesh.find_edge(a,b)
            if edge is None:continue
            points=[list(a.position.toTuple()),list(b.position.toTuple())];extra=saved.get(key(points),{})
            result.append(dict(points=[list(world(v.position).toTuple()) for v in [a,b]],soft=bool(edge.soft),
                hidden=bool(edge.hidden),smooth=bool(extra.get('smooth',edge.soft)),casts_shadows=bool(extra.get('casts_shadows',True))))
    return result
def apply(face,mesh,properties):
    table={key(item['points']):item for item in properties}
    face.attrs[KEY]=properties
    for ring in [face.loop,*face.hole_loops]:
        for a,b in zip(ring,ring[1:]+ring[:1]):
            item=table.get(key([a.position.toTuple(),b.position.toTuple()]));edge=mesh.find_edge(a,b)
            if item is not None and edge is not None:
                edge.soft=bool(item.get('soft'));edge.hidden=bool(item.get('hidden'))
def persistence(scene,patches):
    table=dict(scene.plugin_data.get('sketchup_adapter',{}).get(STATE_KEY,{}))
    for mesh,original,parts in patches:
        table.pop(face_key(scene,mesh,[p.toTuple() for p in original.vertices]),None)
        for part in parts:
            properties=[item for item in part[2] if not item.get('casts_shadows',True) or bool(item.get('smooth'))!=bool(item.get('soft'))] if len(part)>2 else []
            if properties:table[face_key(scene,mesh,[p.toTuple() for p in part[0]])]=properties
    return table
