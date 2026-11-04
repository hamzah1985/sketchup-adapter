"""Read-only native geometry snapshots, safe to validate by scene revision."""
def group_snapshot(group,recipes=None,depth=0):
    from .section import SOURCE_KEY,source_snapshot
    source=(getattr(group,'ext',None) or {}).get(SOURCE_KEY)
    if source:return source_snapshot(group,source)
    if depth>=64:raise ValueError('The selected model exceeds the supported nesting depth.')
    faces=[[[list(p.toTuple()) for p in face.vertices],
            [[list(p.toTuple()) for p in ring] for ring in face.holes],dict(face.attrs)]
           for face in group.mesh.faces]
    edges=[[list(e.a.toTuple()),list(e.b.toTuple())] for e in group.mesh.edges if not e.faces and not e.hidden]
    soft=[[list(e.a.toTuple()),list(e.b.toTuple())] for e in group.mesh.edges if e.faces and (e.soft or e.hidden)]
    result={'uid':getattr(group,'uid',None),'name':group.name or '',
            'definition_key':str(id(group.mesh)),
            'component':bool(group.is_component()) if hasattr(group,'is_component') else bool(getattr(group,'component',False)),
            'xform':list(group.xform.data()) if group.xform is not None else None,
            'hidden':bool(getattr(group,'hidden',False)),'layer':getattr(group,'layer',None),'faces':faces,'edges':edges,
            'soft_edges':soft,'children':[group_snapshot(child,recipes,depth+1) for child in group.children]}
    record=(recipes or {}).get(result['uid']) or (getattr(group,'ext',None) or {}).get('bogdan_bridge')
    if record:result.update(attrs=record.get('attrs',{}),def_attrs=record.get('def_attrs',{}))
    return result


def selection_message(message,recipes):
    if '_pick_group_reference' in (message.get('input') or {}):
        data=dict(message['input']);group=data.pop('_pick_group_reference')
        data['pick']=group_snapshot(group,recipes)
        return dict(message,input=data)
    items=[]
    for item in message['items']:
        copy=dict(item);group=copy.pop('_group_reference',None)
        if group is not None:copy['geometry']=group_snapshot(group,recipes)
        items.append(copy)
    return dict(message,items=items)
