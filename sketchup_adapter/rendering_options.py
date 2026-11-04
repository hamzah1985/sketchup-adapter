"""Read-only, bounded translation of IngeTrazo's display style for Ruby observers."""
import math

def _rgb(value):
    try:
        components = [float(v) for v in value[:3]]
        if len(components) != 3 or not all(math.isfinite(v) for v in components):
            return None
        return [round(max(0.0, min(1.0, v)) * 255) for v in components]
    except (TypeError, ValueError, OverflowError):
        return None

def snapshot(scene):
    style = getattr(scene, 'display_style', None)
    if style is None:
        return {}
    back = getattr(style, 'back_color', None)
    if back is None:
        back = getattr(scene, 'back_face_color', None)
    if back is None:
        try:
            from core.style import DEFAULT_BACK_COLOR
            back = DEFAULT_BACK_COLOR
        except ImportError:
            back = None
    values = {'BackgroundColor': getattr(style, 'background', None),
              'SkyColor': getattr(style, 'sky_color', None),
              'GroundColor': getattr(style, 'ground_color', None),
              'FaceFrontColor': getattr(style, 'front_color', None),
              'FaceBackColor': back}
    return {name: color for name, raw in values.items() if (color := _rgb(raw)) is not None}

def sync(host):
    if not host.ready:
        return
    values = snapshot(host.app.scene)
    if not values or values == getattr(host, '_sent_rendering_options', None):
        return
    host.send({'op': 'rendering_options', 'values': values})
    host._sent_rendering_options = values
