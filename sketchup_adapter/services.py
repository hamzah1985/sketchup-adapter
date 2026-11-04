"""Native file services for the Ruby compatibility worker."""
import logging
from pathlib import Path

log = logging.getLogger(__name__)


def call(host, message):
    name = message['fn']
    try:
        if name == 'geolocation':
            import math
            from PySide6.QtGui import QVector3D
            datum = getattr(host.app.scene, 'georef', None)
            if message.get('action') == 'status':
                return {'ok': True, 'georeferenced': datum is not None}
            if datum is None:
                return {'ok': False, 'error': 'Set a geographic location for this model before converting coordinates.'}
            values = [float(x) for x in message.get('values', [])]
            if not all(math.isfinite(x) for x in values):
                raise ValueError('Coordinates must be finite')
            if message['action'] == 'to_local':
                if len(values) not in (2, 3):raise ValueError('Expected longitude, latitude and optional altitude')
                lon, lat = values[:2]
                if not (-180 <= lon <= 180 and -80 <= lat <= 84):raise ValueError('Coordinates are outside supported UTM bounds')
                if (lat < 0 and datum.northern) or (lat > 0 and not datum.northern):
                    raise ValueError('Coordinates crossing the equator from the model location are not supported.')
                # Native UTM uses southern false northing only for lat < 0.
                # At exactly the equator keep the anchor's hemisphere so a
                # southern datum does not jump by ten million metres.
                from georef.datum import utm_forward
                east,north=utm_forward(lat,lon,datum.zone)
                if lat==0 and not datum.northern:north+=10000000.0
                local=datum.utm_to_local(east,north,values[2] if len(values)==3 else 0.0)
                x,y=datum.local_to_grid_xy(local.x(),local.y())
                return {'ok': True,'values':[x,y,local.z()]}
            if message['action'] == 'to_geodetic':
                if len(values)!=3:raise ValueError('Expected three model coordinates')
                x,y=datum.grid_to_local_xy(values[0],values[1])
                lat,lon,alt=datum.local_to_geodetic(QVector3D(x,y,values[2]))
                if abs(lat)<1e-10:lat=0.0
                if (lat < 0 and datum.northern) or (lat > 0 and not datum.northern):
                    raise ValueError('Coordinates crossing the equator from the model location are not supported.')
                return {'ok': True,'values':[lon,lat,alt]}
            raise ValueError('Unknown geolocation operation')
        if name == 'scene_raytest':
            from .geometry_services import scene_raytest
            return scene_raytest(host, message)
        if name == 'solid_operation':
            from .geometry_services import solid_operation
            return solid_operation(host, message)
        if name == 'native_walkthrough':
            if not (Path(__file__).parent/'native_walk/assets/alex.json.gz').is_file():
                return {'ok': False, 'error': 'The optional walkthrough avatar is not included in this distribution.'}
            from .native_walk.tool import AlexTool
            viewport = host.app.viewport
            if isinstance(viewport.active_tool, AlexTool):
                host.app.window._activate_tool('select')
                return {'ok': True, 'active': False}
            viewport.set_active_tool(AlexTool())
            viewport.setFocus()
            return {'ok': True, 'active': True}
        if name == 'scene_snapshot':
            scene = host.app.scene
            from core.group import Group
            loose = Group(scene.loose_mesh, name='Loose geometry')
            context=host.selection_items(entities=[*scene.groups,*scene.loose_mesh.faces,
                *(edge for edge in scene.loose_mesh.edges if not edge.faces)],reset_tokens=False)
            return {'native_context':context,'groups': [host._group_snapshot(g) for g in scene.groups],
                    'loose': host._group_snapshot(loose),
                    'title': getattr(scene, 'title', '')}
        if name == 'native_hide':
            from .hide import call as hide_call
            return hide_call(host, message)
        if name == 'load_component':
            from core.scene import Scene
            from core.group import Group
            from core.mesh import Mesh
            source = Path(message['path'])
            scene = Scene()
            if source.suffix.lower() == '.skp':
                from formats.skp import load_skp
                load_skp(scene, source)
            elif source.suffix.lower() in ('.glb', '.gltf'):
                from formats.glb import load_glb
                load_glb(scene, source)
            else:
                raise ValueError(f'Unsupported component format: {source.suffix}')
            root = Group(Mesh(), name=source.stem)
            children = list(scene.groups)
            if scene.loose_mesh.faces or scene.loose_mesh.edges:
                children.append(Group(scene.loose_mesh, name=source.stem))
            if not children:
                raise ValueError('The component reader returned no geometry.')
            root.adopt(children)
            return {'geometry': host._group_snapshot(root)}
        if name == 'export_model':
            source = Path(message['path'])
            if source.suffix.lower() == '.glb':
                from formats.gltf import save_glb
                save_glb(host.app.scene, source)
            elif source.suffix.lower() == '.skp':
                from formats.skp_out import save_skp
                save_skp(host.app.scene, source)
            else:
                raise ValueError(f'Unsupported model export: {source.suffix}')
            return {'ok': source.is_file() and source.stat().st_size > 0}
        if name == 'write_image':
            if 'groups' in message:
                return render_snapshot(host, message)
            image = host.app.viewport.render_image(int(message.get('width', 512)),
                                                   int(message.get('height', 512)))
            if image is None:
                raise RuntimeError('The native viewport is not ready to render.')
            return {'ok': image.save(str(message['path']))}
    except Exception as exc:
        log.exception('Native extension service %s failed', name)
        return {'ok': False, 'error': f'{type(exc).__name__}: {exc}'}
    return {'ok': False, 'error': f'Unknown native service: {name}'}


def render_snapshot(host, message):
    """Thumbnail the worker's temporary model without altering the document."""
    import math
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QVector3D
    from PySide6.QtWidgets import QApplication
    from views.viewport import Viewport
    from core.style import Style
    from . import group_from_payload, register_materials
    view = Viewport()
    view.style_override = Style(name='Plugin thumbnail',background=(.965,.957,.937),sky=False)
    view.setAttribute(Qt.WA_DontShowOnScreen, True)
    width, height = int(message.get('width') or 512), int(message.get('height') or 512)
    view.resize(width, height)
    for payload in message['groups']:
        register_materials(view.scene, payload)
        view.scene.groups.append(group_from_payload(payload))
    camera = message['camera']
    eye, target = QVector3D(*camera['eye']), QVector3D(*camera['target'])
    offset = eye-target
    view.camera.target = target
    view.camera.distance = max(offset.length(), .005)
    view.camera.yaw = math.atan2(offset.y(), offset.x())
    view.camera.pitch = math.asin(max(-1,min(1,offset.z()/view.camera.distance)))
    view.camera.fov_deg = float(camera.get('fov',35))
    view.camera.perspective = bool(camera.get('perspective',True))
    if not view.camera.perspective:
        view.camera.distance = float(camera.get('height',1)) / (2*math.tan(math.radians(view.camera.fov_deg)/2))
    view.camera.set_aspect(width,height)
    view.scene.show_axes = False
    view.scene.version += 1
    view.show();QApplication.processEvents()
    try:
        image = view.render_image(width,height)
        if image is None or image.isNull():
            raise RuntimeError('Could not render the temporary model thumbnail')
        return {'ok':image.save(str(message['path']))}
    finally:
        view.close();view.deleteLater()
