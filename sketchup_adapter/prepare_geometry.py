"""Prepare isolated model geometry and CPU render buffers off the UI thread.

No QWidget, OpenGL resource, live mesh, history or document is touched here.
The completed cache transfers to the viewport on the GUI thread.
"""
import inspect
from types import SimpleNamespace


class _CpuViewport:
    def __init__(self, viewport_class):
        self._viewport_class=viewport_class
        self.scene=SimpleNamespace(version=0,mesh=None,edit_group=None)
        self._export_size=None
        self.plano_style=self.style_override=None
        self._chunk_cache_load=self._chunk_cache_save=None
        self._group_chunks={}
        self._proto_wrappers={}

    def __getattr__(self,name):
        raw=inspect.getattr_static(self._viewport_class,name)
        if isinstance(raw,staticmethod):return raw.__func__
        if isinstance(raw,classmethod):return raw.__get__(None,self._viewport_class)
        if inspect.isfunction(raw):return raw.__get__(self,type(self))
        if isinstance(raw,property):raise AttributeError(name)
        return raw


def prepare(payload,viewport_class,progress=None):
    from . import group_from_payload
    from core.group import effective_material
    group=group_from_payload(payload,progress)
    if progress:progress('view',sum(len(p.get('faces',())) for p in payload.get('protos',())))
    baker=_CpuViewport(viewport_class)
    seen=set();pending=[group]
    while pending:
        item=pending.pop()
        paint=effective_material(item)
        from core.materials import material_sig
        key=(id(item.mesh),material_sig(paint))
        if key not in seen:
            seen.add(key)
            baker._proto_base_chunk(item.mesh,paint)
        pending.extend(getattr(item,'children',()) or ())
    return group,baker._proto_wrappers,baker._group_chunks


def install(viewport,prepared):
    group,wrappers,chunks=prepared
    current=getattr(viewport,'_proto_wrappers',None)
    if current is None:viewport._proto_wrappers={}
    current=getattr(viewport,'_group_chunks',None)
    if current is None:viewport._group_chunks={}
    viewport._proto_wrappers.update(wrappers)
    viewport._group_chunks.update(chunks)
    return group
