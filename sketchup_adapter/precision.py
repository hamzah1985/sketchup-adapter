"""Retain SketchUp-sized details without changing other IngeTrazo meshes.

The stock 0.1 mm weld merges nearby corners of small hardware faces. Only
adapter meshes use a 1 micrometre grid. A format extension records that choice
on the mesh block, including shared prototypes and binary native documents.
"""
from functools import wraps
from types import FunctionType

_detail_class = None


def detail_mesh_class():
    global _detail_class
    if _detail_class is not None:
        return _detail_class
    from core.mesh import Mesh

    def key(p):
        return tuple(round(v * 1_000_000) for v in p.toTuple())

    methods = {}
    for name, member in vars(Mesh).items():
        if not isinstance(member, FunctionType):
            continue
        if not {'_key', '_KEY_DECIMALS', '_KEY_SCALE'}.intersection(member.__code__.co_names):
            continue
        namespace = dict(member.__globals__, _key=key, _KEY_DECIMALS=6, _KEY_SCALE=1_000_000.0)
        function = FunctionType(member.__code__, namespace, member.__name__,
                                member.__defaults__, member.__closure__)
        function.__kwdefaults__ = member.__kwdefaults__
        methods[name] = function
    _detail_class = type('BogdanDetailMesh', (Mesh,), methods)
    return _detail_class


def install_persistence():
    from formats import igz
    if getattr(igz._load_mesh, '_bogdan_precision', False):
        return
    write = igz._mesh_json
    read = igz._load_mesh

    @wraps(write)
    def write_mesh(mesh, *args, **kwargs):
        payload = write(mesh, *args, **kwargs)
        if isinstance(mesh, detail_mesh_class()):
            payload['bogdan_weld_decimals'] = 6
        return payload

    @wraps(read)
    def read_mesh(mesh, payload, *args, **kwargs):
        if payload.get('bogdan_weld_decimals') == 6:
            mesh.__class__ = detail_mesh_class()
        return read(mesh, payload, *args, **kwargs)

    read_mesh._bogdan_precision = True
    igz._mesh_json = write_mesh
    igz._load_mesh = read_mesh
