"""Read-only native viewport camera snapshots for Ruby view observers."""
import math


def snapshot(viewport):
    try:
        camera = viewport.camera
        width, height = int(viewport.width()), int(viewport.height())
        if width <= 0 or height <= 0:
            return None
        vectors = [camera.eye(), camera.target, camera.up_vector()]
        values = [[float(x) for x in vector.toTuple()] for vector in vectors]
        fov, distance = float(camera.fov_deg), float(camera.distance)
        if (any(len(v) != 3 or not all(math.isfinite(x) for x in v) for v in values)
                or not math.isfinite(fov) or not 0 < fov < 180
                or not math.isfinite(distance) or distance <= 0):
            return None
        return {'eye': values[0], 'target': values[1], 'up': values[2],
                'perspective': bool(camera.perspective), 'fov': fov,
                'height': 2 * distance * math.tan(math.radians(fov) / 2),
                'viewport_size': [width, height]}
    except (AttributeError, TypeError, ValueError, OverflowError):
        return None


def sync(host):
    if not host.ready:
        return
    values = snapshot(host.app.viewport)
    if values is None or values == getattr(host, '_sent_camera', None):
        return
    host.send({'op': 'native_camera', 'values': values})
    host._sent_camera = values
