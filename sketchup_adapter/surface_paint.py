"""Merge explicit surface-paint edits without touching unrelated native attributes."""
import copy
import math

PAINT_KEYS = ('mat', 'color', 'opacity', 'texture')

def validate_geometry_batch(batch):
    """Reject malformed face geometry before any native batch side effects."""
    for message in batch:
        patch = (message.get('surface_patch') if message.get('op') == 'upsert'
                 else message if message.get('op') == 'surface_patch' else None)
        if patch is None:
            continue
        if not isinstance(patch, dict) or not isinstance(patch.get('faces'), list):
            raise ValueError('Invalid extension face geometry.')
        for face in patch['faces']:
            if not isinstance(face, (list, tuple)) or len(face) != 3:
                raise ValueError('Invalid extension face geometry.')
            outer, holes, attrs = face
            if not isinstance(holes, (list, tuple)) or not isinstance(attrs, dict):
                raise ValueError('Invalid extension face geometry.')
            for ring in (outer, *holes):
                if not isinstance(ring, (list, tuple)) or len(ring) < 3:
                    raise ValueError('Invalid extension face boundary.')
                for point in ring:
                    if not isinstance(point, (list, tuple)) or len(point) != 3:
                        raise ValueError('Invalid extension face point.')
                    for value in point:
                        if (isinstance(value, bool) or not isinstance(value, (int, float)) or
                                abs(value) > 3.4028234663852886e38 or not math.isfinite(value)):
                            raise ValueError('Invalid extension face coordinate.')

def world_basis(transform, vector):
    if transform is not None:
        if not transform.isAffine() or not transform.inverted()[1]:
            raise ValueError('Cannot paint a face through a singular or projective transform')
        world = transform.map
    else:
        world = lambda point: point
    zero = world(vector(0, 0, 0))
    basis = [list(zero.toTuple())] + [list((world(vector(*axis)) - zero).toTuple()) for axis in
                                      ((1,0,0),(0,1,0),(0,0,1))]
    if not all(math.isfinite(value) for part in basis for value in part):
        raise ValueError('Invalid face transform')
    return basis

def proxy_attrs(original, transform, normal, vector):
    """Create world-space texture maps for read-only Ruby face proxies."""
    result = copy.deepcopy(original)
    sides = (result, result.get('back'))
    if not any(isinstance(side, dict) and isinstance(side.get('texture'), dict) for side in sides):
        return result
    inverse = None
    if transform is not None:
        if not transform.isAffine():
            raise ValueError('Cannot inspect a face through a projective transform')
        inverse, ok = transform.inverted()
        if not ok:
            raise ValueError('Cannot inspect a face through a singular transform')
    basis = world_basis(inverse, vector)
    for side in sides:
        if not isinstance(side, dict) or not isinstance(side.get('texture'), dict):
            continue
        texture = side['texture']
        uvw = texture.get('uvw')
        if uvw is None:
            # Native faces without an explicit map use the renderer's planar
            # projection in their own mesh coordinates.
            from core.texture import face_uv_axes
            gu, cu, gv, cv = face_uv_axes(texture, normal)
            uvw = [*gu.toTuple(), cu, *gv.toTuple(), cv]
        texture['uvw'] = local_uvw(uvw, basis)
    return result

def validate_batch(batch, targets, vector, scene):
    """Validate every proposed paint change before any batch side effects."""
    for message in batch:
        patch = (message.get('surface_patch') if message.get('op') == 'upsert'
                 else message if message.get('op') == 'surface_patch' else None)
        if not patch:
            continue
        for _outer, _holes, attrs in patch.get('faces', []):
            if '_adapter_paint_edits' not in attrs:
                continue
            target = targets.get(patch.get('token'))
            if target is None:
                raise ValueError('Cannot paint a face that no longer exists')
            mesh, original, transform = target
            if mesh is not scene.loose_mesh:
                from core.group import iter_placements
                owners = [g for top in scene.groups for g, _ in iter_placements(top) if g.mesh is mesh]
                if len(owners) != 1:
                    raise ValueError('Cannot paint a face with ambiguous shared component ownership')
            merge_attrs(original.attrs, attrs['_adapter_paint_edits'], world_basis(transform, vector))

def local_uvw(uvw, basis):
    """Compose world-space affine UV coefficients with local-to-world basis."""
    if not isinstance(uvw, (list, tuple)) or len(uvw) != 8:
        raise ValueError('Invalid texture UV mapping on an edited native face')
    values = [float(x) for x in uvw]
    if not all(math.isfinite(x) for x in values):
        raise ValueError('Invalid texture UV mapping on an edited native face')
    origin, axes = basis[0], basis[1:]
    result = []
    for j in (0, 4):
        g = values[j:j+3]
        result.extend(sum(g[k] * axis[k] for k in range(3)) for axis in axes)
        result.append(values[j+3] + sum(g[k] * origin[k] for k in range(3)))
    return result

def merge_attrs(original, edits, basis):
    result = copy.deepcopy(original)
    if not isinstance(edits, dict) or not set(edits).issubset({'front', 'back'}):
        raise ValueError('Invalid surface paint edit')
    for side, payload in edits.items():
        if not isinstance(payload, dict) or set(payload) - {'value', 'preserve_uvw'} or 'value' not in payload:
            raise ValueError('Invalid surface paint edit')
        paint = payload['value']
        if paint is not None and not isinstance(paint, dict):
            raise ValueError('Invalid surface paint')
        target = copy.deepcopy(paint) if paint is not None else None
        if target is not None and set(target) - set(PAINT_KEYS):
            raise ValueError('Unsupported surface paint data')
        if target is not None:
            if 'mat' in target and not isinstance(target['mat'], str):
                raise ValueError('Invalid material name')
            if 'color' in target:
                color = target['color']
                if not isinstance(color, (list, tuple)) or len(color) != 3 or not all(
                        isinstance(v, (int, float)) and math.isfinite(v) and 0 <= v <= 1 for v in color):
                    raise ValueError('Invalid face color')
            if 'opacity' in target and (not isinstance(target['opacity'], (int, float)) or
                    not math.isfinite(target['opacity']) or not 0 <= target['opacity'] <= 1):
                raise ValueError('Invalid face opacity')
        if target is not None and 'texture' in target:
            texture = target['texture']
            if not isinstance(texture, dict):
                raise ValueError('Texture mapping unavailable for edited native face')
            if not isinstance(texture.get('path'), str) or not texture['path']:
                raise ValueError('Invalid texture path')
            for key in ('sw', 'sh'):
                if key in texture and (not isinstance(texture[key], (int, float)) or
                        not math.isfinite(texture[key]) or texture[key] <= 0):
                    raise ValueError('Invalid texture scale')
            if payload.get('preserve_uvw'):
                old_side = original if side == 'front' else original.get('back', {})
                old_texture = old_side.get('texture', {}) if isinstance(old_side, dict) else {}
                if 'uvw' in old_texture:
                    texture['uvw'] = copy.deepcopy(old_texture['uvw'])
                else:
                    texture.pop('uvw', None)
            else:
                if 'uvw' not in texture:
                    raise ValueError('Texture mapping unavailable for edited native face')
                texture['uvw'] = local_uvw(texture['uvw'], basis)
        if side == 'front':
            for key in PAINT_KEYS:
                result.pop(key, None)
            if target:
                result.update(target)
        else:
            existing = result.get('back')
            back = copy.deepcopy(existing) if isinstance(existing, dict) else {}
            for key in PAINT_KEYS:
                back.pop(key, None)
            if target:
                back.update(target)
            if back:
                result['back'] = back
            else:
                result.pop('back', None)
    return result
