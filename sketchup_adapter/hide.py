"""Hide's model-wide actions against the native document, with native undo."""
from core.history import Command
from core.layers import Layer, layer_of, assign_layer

PREFIX = 'Hide · '
CATEGORIES = {'dimension':('Dimensions','dimensions'), 'text':('Text and labels','text_labels'),
              'image':('Images','image_planes')}
VIEWS = {'guides':('Guides','show_guides'), 'axes':('Model axes','show_axes'),
         'section_planes':('Section planes','show_section_planes')}
_viewports=[]


def install_guide_visibility(viewport):
    import weakref
    from views import viewport as module
    from PySide6.QtGui import QOpenGLContext
    _viewports.append(weakref.ref(viewport))
    install_axis_visibility()
    cls=type(viewport)
    if not getattr(cls._draw_guides,'_bogdan_hide_guides',False):
        original_points=cls._draw_guides
        def points(self,painter):
            if self.scene.plugin_data.get('bogdan_hide_view',{}).get('guides_hidden'):
                return
            return original_points(self,painter)
        points._bogdan_hide_guides=True
        cls._draw_guides=points
    if getattr(module._guide_vertices,'_bogdan_hide_guides',False):return
    original=module._guide_vertices
    def draw(guides,*args,**kwargs):
        context=QOpenGLContext.currentContext()
        for ref in _viewports:
            vp=ref()
            # Native renderers may filter guides into a new list before
            # drawing. Match the rendering viewport, not only list identity.
            if vp is not None and (vp.scene.guides is guides or (context is not None and vp.context()==context)) and vp.scene.plugin_data.get('bogdan_hide_view',{}).get('guides_hidden'):
                return original([], *args, **kwargs)
        return original(guides,*args,**kwargs)
    draw._bogdan_hide_guides=True
    module._guide_vertices=draw


def install_axis_visibility():
    """Older native renderers draw axes even when scene.show_axes is false."""
    from views import viewport as module
    from PySide6.QtGui import QOpenGLContext
    if getattr(module._axes_vertices,'_bogdan_hide_axes',False):return
    original_axes=module._axes_vertices
    def axes(*args,**kwargs):
        coords,spans=original_axes(*args,**kwargs)
        context=QOpenGLContext.currentContext()
        for ref in _viewports:
            vp=ref()
            if vp is not None and vp.context()==context and not getattr(vp.scene,'show_axes',True):
                return coords[:0],{key:(0,0) for key in spans}
        return coords,spans
    axes._bogdan_hide_axes=True
    module._axes_vertices=axes


def marker(entity):
    name = layer_of(entity)
    if not name.startswith(PREFIX): return None
    try:
        label, value = name[len(PREFIX):].split(' · ',1)
        flags={'Selection':'selection', **{v[0]:k for k,v in CATEGORIES.items()}}
        return flags[label], value
    except (ValueError, TypeError, KeyError):
        return None


def all_entities(scene):
    from core.group import Group
    seen=set()
    def descend(item):
        if id(item) in seen: return
        seen.add(id(item)); yield item
        if isinstance(item,Group):
            for face in item.mesh.faces: yield from descend(face)
            for edge in item.mesh.edges: yield from descend(edge)
            for child in item.children: yield from descend(child)
    for item in [*scene.groups,*scene.loose_mesh.faces,*scene.loose_mesh.edges,
                 *scene.dimensions,*scene.text_labels,*scene.image_planes]:
        yield from descend(item)


def in_scope(scene, scope):
    if scope != 'selection': return list(all_entities(scene))
    from core.group import Group
    selected=set(scene.selection)
    def contains(entity):
        parent=getattr(entity,'owner',None)
        while parent is not None:
            if parent in selected: return True
            parent=getattr(parent,'owner',None)
        return entity in selected
    return [e for e in all_entities(scene) if contains(e)]


class HideItems(Command):
    def __init__(self, changes, selection, clear=False):
        self.changes=changes
        self.selection=set(selection)
        self.clear=clear
        self.old_layers=None
    def do(self,scene):
        if self.old_layers is None: self.old_layers=list(scene.layers)
        names={l.name for l in scene.layers}
        for entity,before,after in self.changes:
            if after.startswith(PREFIX) and after not in names:
                scene.layers.append(Layer(after,visible=False)); names.add(after)
            assign_layer(entity,after)
        if self.clear: scene.selection.clear()
        scene.version+=1
    def undo(self,scene):
        for entity,before,after in self.changes: assign_layer(entity,before)
        scene.layers[:]=self.old_layers
        scene.selection.clear();scene.selection.update(self.selection)
        scene.version+=1


def state(scene,scope):
    entities=in_scope(scene,scope)
    selected_ids={id(e) for e in entities}
    visible_layers={l.name for l in scene.layers if l.visible}
    categories=[]
    for key,(label,field) in CATEGORIES.items():
        values=[e for e in getattr(scene,field) if id(e) in selected_ids]
        categories.append({'key':key,'label':label,
                           'visible':sum(layer_of(e) in visible_layers and not marker(e) for e in values),
                           'hidden':sum(marker(e) is not None and marker(e)[0]==key for e in values)})
    views=[{'key':k,'label':label,'hidden':scene.plugin_data.get('bogdan_hide_view',{}).get('guides_hidden',False) if k=='guides' else not getattr(scene,field,True)} for k,(label,field) in VIEWS.items()]
    hidden=sum(marker(e) is not None and marker(e)[0]=='selection' for e in entities)
    return {'scope':scope,'categories':categories,'views':views,'selectionCount':len(scene.selection),
            'hiddenBySelection':hidden,'anyHidden':bool(hidden or any(c['hidden'] for c in categories) or any(v['hidden'] for v in views))}


def call(host,msg):
    scene=host.app.scene
    action=msg.get('action','state');scope=msg.get('scope','model')
    if action=='state': return {'state':state(scene,scope)}
    if action=='set_view_hidden':
        label,field=VIEWS[msg['key']]
        setattr(scene,field,not msg['hidden']);scene.version+=1
        if msg['key']=='guides':scene.plugin_data.setdefault('bogdan_hide_view',{})['guides_hidden']=bool(msg['hidden'])
        host.app.viewport.update()
        return {'message':label+(' hidden.' if msg['hidden'] else ' shown.')}
    items=in_scope(scene,scope)
    targets=[];hide=True;flag='selection'
    if action=='set_category_hidden':
        flag=msg['key'];hide=msg['hidden']
        _,field=CATEGORIES[flag]
        ids={id(e) for e in items}
        targets=[e for e in getattr(scene,field) if id(e) in ids]
    elif action=='hide_selected': targets=list(scene.selection)
    elif action=='isolate_selected':
        targets=[e for e in [*scene.groups,*scene.loose_mesh.faces,*scene.loose_mesh.edges] if e not in scene.selection]
    elif action=='show_hidden_selection': hide=False;targets=items
    elif action=='show_everything':
        hide=False;targets=list(all_entities(scene));flag=None
        for _,field in VIEWS.values(): setattr(scene,field,True)
        scene.plugin_data.setdefault('bogdan_hide_view',{})['guides_hidden']=False
    else: raise ValueError('Unknown Hide action: '+action)
    changes=[]
    for entity in targets:
        old=layer_of(entity);record=marker(entity)
        if hide:
            if record or getattr(entity,'hidden',False): continue
            layer=next((l for l in scene.layers if l.name==old),None)
            if layer is not None and not layer.visible: continue
            label='Selection' if flag=='selection' else CATEGORIES[flag][0]
            new=PREFIX+label+' · '+old
        else:
            if record is None or (flag is not None and record[0]!=flag): continue
            new=record[1]
        changes.append((entity,old,new))
    if changes:
        host.app.viewport.history.execute(HideItems(changes,scene.selection,action=='hide_selected'))
    host.app.viewport.update()
    notify=getattr(host.app.viewport,'notify_scene_changed',None)
    if callable(notify):notify()
    return {'message':('Hid ' if hide else 'Showed ')+str(len(changes))+' items.'}
