"""Cursor metadata and inference shared by Ruby extension tools."""
from PySide6.QtCore import Qt
from PySide6.QtGui import QVector3D
from .fence_inference import FenceInference

INCH = 0.0254


class InteractionTool(FenceInference):
    def init_path_inference(self, enabled):
        super().init_path_inference(enabled)
        self._generic_direction = None

    @property
    def magnetic_axis_deg(self):
        return 3.0 if self.start_point is not None and self._path_plane is None else None

    @property
    def screen_axis_px(self):
        return 9.0 if self.magnetic_axis_deg is not None else None

    def sync_interaction(self, state):
        if self._path_inference_enabled:
            return  # Fence owns its rise plane and accepted draft.
        point = state.get('reference')
        self.start_point = QVector3D(*(v*INCH for v in point)) if point is not None else None
        position = state.get('point')
        self.hover_point = QVector3D(*(v*INCH for v in position)) if position is not None else None
        direction = state.get('direction')
        self._generic_direction = direction
        vp = self.host.app.viewport
        vp._shift_lock = ((QVector3D(*direction).normalized(), (.71,.16,.75))
                          if direction is not None and self.start_point is not None else None)

    def on_generic_deactivate(self, viewport):
        if self._generic_direction is not None:
            viewport._shift_lock = None
        self._generic_direction = None

    def rubber_band_lines(self):
        if self._path_inference_enabled:
            return super().rubber_band_lines()
        if self.start_point is not None and self.hover_point is not None:
            return [(self.start_point,self.hover_point)]
        return []


def enrich_input(host, hit, snap=None, tool=None):
    """At most 64 nearby, visible edges; no full-model cursor serialization."""
    vp = host.app.viewport
    x,y = hit['screen']
    hit['linear_mode'] = getattr(vp,'linear_inference_mode','all')
    if snap is not None:
        hit['snap_axis'] = getattr(snap,'axis',None)
        hit['snap_label'] = getattr(snap,'label',None)
        hit['snap_color'] = list(getattr(snap,'color',(.2,.6,.3)))
    records=[]
    edges=[]
    if hasattr(vp,'_nearby_loose_edges'):
        edges += vp._nearby_loose_edges(x,y,16.0,64)
    if hasattr(vp,'_nearby_group_edges'):
        edges += vp._nearby_group_edges(x,y,16.0,64)
    seen=set();candidates=[]
    origin,direction=vp._pixel_to_ray(x,y)
    for edge in edges:
        if getattr(edge,'hidden',False):continue
        a,b=edge.a,edge.b
        if (b-a).lengthSquared()<1e-18:continue
        owner=getattr(edge,'group',None)
        key=(id(owner),tuple(a.toTuple()),tuple(b.toTuple()))
        if key in seen:continue
        seen.add(key)
        pixels=vp._segment_to_pixels(a,b)
        if pixels is None:continue
        (ax,ay),(bx,by)=pixels
        dx,dy=bx-ax,by-ay
        length=dx*dx+dy*dy
        t=max(0,min(1,((x-ax)*dx+(y-ay)*dy)/length)) if length>1e-12 else 0
        distance=((ax+t*dx-x)**2+(ay+t*dy-y)**2)**.5
        if distance>16:continue
        point=a+(b-a)*t
        candidates.append((distance,edge,owner,point))
    candidates.sort(key=lambda row:row[0]);candidates=candidates[:64]
    points=[row[3] for row in candidates]
    try:occluded=vp._occluded_many(points) if points else []
    except Exception:occluded=[vp._is_occluded(p) for p in points]
    for (distance,edge,owner,point),hidden in zip(candidates,occluded):
        if hidden:continue
        xf=getattr(owner,'xform',None)
        inverse,ok=xf.inverted() if xf is not None else (None,True)
        if not ok:continue
        local=lambda p: inverse.map(p) if inverse is not None else p
        endpoints=[[float(v)/INCH for v in local(p).toTuple()] for p in (edge.a,edge.b)]
        record={'kind':'edge','token':str(id(owner))+':'+repr(endpoints),
                'points':endpoints,'distance':distance,
                'depth':(point-origin).length() if origin is not None else 0}
        if owner is None and hasattr(edge,'v0'):
            record['native_token']=str(id(edge))
            if tool is not None:
                if getattr(tool,'_edge_context_epoch',None)!=host._surface_context_epoch:
                    tool._edge_context_epoch=host._surface_context_epoch;tool._edge_tokens=set()
                if record['native_token'] not in tool._edge_tokens and 'edge_context' not in hit:
                    mesh,matrix=host._entity_owner(edge)
                    if mesh is not None:
                        from .native_edges import context
                        hit['edge_context']=context(host,edge,mesh,matrix)
        if xf is not None:
            matrix=list(xf.data());matrix[12:15]=[v/INCH for v in matrix[12:15]]
            record['xform']=matrix
        if owner is not None:
            attrs=(getattr(owner,'ext',None) or {}).get('bogdan_bridge',{}).get('attrs',{})
            record['owner']={'uid':getattr(owner,'uid',None),'name':getattr(owner,'name','') or '', 'attrs':attrs}
        records.append(record)
    if hit.get('face'):
        records.append({'kind':'face','token':hit.get('face_token','cursor-face'),
                        'distance':0,'depth':0})
    hit['hits']=records
    return hit
