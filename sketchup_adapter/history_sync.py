"""Keep the isolated Ruby document aligned with native undo and redo."""
def sync(host):
    history=getattr(host.app.viewport,'history',None)
    if history is None:return
    scene=host.app.scene
    version=getattr(scene,'version',None)
    cache_key=(id(scene),version) if version is not None else None
    if cache_key is not None and cache_key==getattr(host,'_native_live_cache_key',None):
        live_uids=list(host._native_live_cache)
    else:
        live_uids=[]
        pending=list(scene.groups)
        seen=set()
        while pending:
            group=pending.pop()
            if id(group) in seen:continue
            seen.add(id(group))
            if getattr(group,'uid',None) is not None:live_uids.append(str(group.uid))
            pending.extend(getattr(group,'children',()) or ())
        host._native_live_cache_key=cache_key
        host._native_live_cache=tuple(live_uids)
    live=set(live_uids)
    previous_live=getattr(host,'_native_live_uids',None)
    undo=tuple(id(c) for c in history.undo_stack)
    redo=tuple(id(c) for c in history.redo_stack)
    key=(undo,redo)
    previous=getattr(host,'_native_history_key',None)
    if key==previous:
        host._native_live_uids=live
        return
    host._native_history_key=key
    event=None
    if previous:
        pu,pr=previous
        if len(undo)<len(pu) and pu[-1:] and pu[-1] in redo:event='undo'
        elif len(redo)<len(pr) and pr[-1:] and pr[-1] in undo:event='redo'
        elif any(id(command) not in pu and not getattr(command, '_sketchup_adapter_edit', False)
                 for command in history.undo_stack):
            event='commit'
    items=[]
    for group in host.app.scene.groups:
        rid=host.rid_of_uid.get(group.uid)
        if rid is None:continue
        host.group_of_rid[rid]=group
        item={'uid':group.uid,'rid':rid,'xform':list(group.xform.data()) if group.xform is not None else None,'hidden':bool(group.hidden)}
        if event:item['_group_reference']=group
        items.append(item)
    guides=[{'id':g._adapter_key,'point':list(g.point.toTuple())} for g in host.app.scene.guides if hasattr(g,'_adapter_key')]
    added=sorted(live-previous_live) if event=='commit' and previous_live is not None else []
    removed=sorted(previous_live-live) if event=='commit' and previous_live is not None else []
    host._native_live_uids=live
    host.send({'op':'model_state','items':items,'event':event,'guides':guides,
               'live_uids':live_uids,'added_uids':added,'removed_uids':removed})
