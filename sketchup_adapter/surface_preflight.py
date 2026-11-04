"""Reject obsolete native-face edits before touching a live document.

This is a safety barrier, not a face-fragment rebinding implementation.
"""

import copy
import math

class StaleSurfaceEdit(RuntimeError):
    pass


_IDENTITY = (1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.,0.,0.,0.,0.,1.)


def _matrix_value(matrix):
    return _IDENTITY if matrix is None else tuple(float(x) for x in matrix.data())


def _validate_patch_transform(matrix, entity='face'):
    """Require a finite affine world-to-local conversion before any edits."""
    if matrix is None:
        return
    try:
        values = _matrix_value(matrix)
        if len(values) != 16 or not all(math.isfinite(value) for value in values):
            raise StaleSurfaceEdit(f'The {entity} owner has an invalid transform; the edit was not applied.')
        if not matrix.isAffine():
            raise StaleSurfaceEdit(f'The {entity} owner has a projective transform; the edit was not applied.')
        inverse, valid = matrix.inverted()
        inverse_values = _matrix_value(inverse)
        if not valid or len(inverse_values) != 16 or not all(math.isfinite(value) for value in inverse_values):
            raise StaleSurfaceEdit(f'The {entity} owner has a singular or invalid transform; the edit was not applied.')
    except StaleSurfaceEdit:
        raise
    except (AttributeError, TypeError, ValueError, OverflowError) as error:
        raise StaleSurfaceEdit(f'The {entity} owner has an invalid transform; the edit was not applied.') from error


def validate_edge_transforms(batch, edge_targets, scene=None, placement_iter=None):
    """Validate conversions for edge movement before native commands mutate.

    Edge deletion does not convert coordinates and retains its existing
    behavior. A requested move without a resolvable target is an error rather
    than an apparent success with no edit.
    """
    owners = None
    for message in batch:
        if message.get('op') != 'edge_patch' or message.get('points') is None:
            continue
        points=message['points']
        if not isinstance(points,(list,tuple)) or len(points)!=2:
            raise StaleSurfaceEdit('An edge edit has invalid endpoints; the edit was not applied.')
        try:
            for point in points:
                if not isinstance(point,(list,tuple)) or len(point)!=3:
                    raise ValueError('Invalid endpoint')
                for value in point:
                    if isinstance(value,bool) or not isinstance(value,(int,float)):
                        raise ValueError('Invalid coordinate')
                    number=float(value)
                    # QVector3D stores float32. A finite Python float can
                    # otherwise overflow to infinity during conversion.
                    if not math.isfinite(number) or abs(number)>3.4028234663852886e38:
                        raise ValueError('Non-finite coordinate')
        except (TypeError,ValueError,OverflowError) as error:
            raise StaleSurfaceEdit('An edge edit has invalid endpoints; the edit was not applied.') from error
        target = edge_targets.get(message.get('token'))
        if not target or len(target) != 3:
            raise StaleSurfaceEdit('An edge edit no longer has a valid native target.')
        mesh, edge, matrix = target
        _validate_patch_transform(matrix, 'edge')
        if scene is not None:
            if owners is None:
                owners = _placements(scene, placement_iter)
            placements = owners.get(id(mesh), ())
            if (len(placements) != 1 or placements[0] != _matrix_value(matrix) or
                    not any(item is edge for item in getattr(mesh, 'edges', ()))):
                raise StaleSurfaceEdit('An edge or its owner changed or is ambiguous; the edit was not applied.')
    return batch


def _placements(scene, placement_iter):
    """Collect every live owner and composed world transform of each mesh."""
    result = {}
    loose = getattr(scene, 'loose_mesh', None)
    if loose is not None:
        result.setdefault(id(loose), []).append(_IDENTITY)
    groups = getattr(scene, 'groups', ()) or ()
    if groups and placement_iter is None:
        from core.group import iter_placements
        placement_iter = iter_placements
    for root in groups:
        for group, matrix in placement_iter(root):
            mesh = getattr(group, 'mesh', None)
            if mesh is not None:
                result.setdefault(id(mesh), []).append(_matrix_value(matrix))
    return result


def validate(batch, surface_targets, face_tokens, scene, placement_iter=None):
    """Validate as one unit and omit erasures already covered by a patch.

    A patch replaces its original face, so the corresponding host-side
    face_erased notification is redundant. Separate and duplicate patches
    to the same native face are ambiguous and are rejected.
    """
    if not any(msg.get('op') in ('surface_patch', 'face_erased') or
               (msg.get('op') == 'upsert' and 'surface_patch' in msg) for msg in batch):
        return batch
    owners = _placements(scene, placement_iter)
    live_faces = {}
    def is_live(mesh, face, matrix):
        placements = owners.get(id(mesh), ())
        if len(placements) != 1 or placements[0] != _matrix_value(matrix):
            return False
        key = id(mesh)
        if key not in live_faces:
            live_faces[key] = {id(item) for item in mesh.faces}
        return id(face) in live_faces[key]
    patches = {}
    targets = set()
    for msg in batch:
        has_patch = msg.get('op') == 'surface_patch' or (msg.get('op') == 'upsert' and 'surface_patch' in msg)
        if not has_patch:
            continue
        patch = msg.get('surface_patch') if msg.get('op') == 'upsert' else msg
        if not isinstance(patch, dict):
            raise StaleSurfaceEdit('The extension sent an invalid face edit.')
        token = patch.get('token')
        target = surface_targets.get(token)
        if not token or not target or len(target) != 3:
            raise StaleSurfaceEdit('A face edit no longer has a valid native target.')
        mesh, face, matrix = target
        if not is_live(mesh, face, matrix):
            raise StaleSurfaceEdit('A face or its owner changed or is ambiguous; the edit was not applied.')
        _validate_patch_transform(matrix)
        try:
            copy.deepcopy(getattr(face, 'attrs', {}))
        except Exception as error:
            raise StaleSurfaceEdit('The face has data that cannot be safely copied; the edit was not applied.') from error
        identity = (id(mesh), id(face))
        if token in patches or identity in targets:
            raise StaleSurfaceEdit('Multiple edits targeted the same face in one operation.')
        patches[token] = (mesh, face)
        targets.add(identity)

    output = []
    erased = set()
    for msg in batch:
        if msg.get('op') != 'face_erased':
            output.append(msg)
            continue
        token = msg.get('token')
        target = face_tokens.get(token)
        if not token or not target or len(target) != 2:
            raise StaleSurfaceEdit('A face deletion no longer has a valid native target.')
        mesh, face = target
        surface_target = surface_targets.get(token)
        if (not surface_target or len(surface_target) != 3 or surface_target[0] is not mesh
                or surface_target[1] is not face or not is_live(mesh, face, surface_target[2])):
            raise StaleSurfaceEdit('A face or its owner changed or is ambiguous; the deletion was not applied.')
        identity = (id(mesh), id(face))
        if identity in erased:
            raise StaleSurfaceEdit('A face was deleted more than once in one operation.')
        erased.add(identity)
        if token in patches:
            if patches[token][0] is not mesh or patches[token][1] is not face:
                raise StaleSurfaceEdit('A face edit and deletion have conflicting targets.')
            continue
        if identity in targets:
            raise StaleSurfaceEdit('A face edit and deletion have conflicting identities.')
        try:
            copy.deepcopy(getattr(face, 'attrs', {}))
        except Exception as error:
            raise StaleSurfaceEdit('The face has data that cannot be safely copied; the deletion was not applied.') from error
        output.append(msg)
    return output
