# SPDX-License-Identifier: GPL-3.0-or-later
"""SketchUp extension compatibility runtime for IngeTrazo.

Importing the package never starts Ruby or requires Qt. The manager, CLI and
archive inspection can therefore run without starting IngeTrazo.
"""
__version__ = "0.1.0"
_controller = None


def setup(app):
    global _controller
    from .manager import AdapterController
    _controller = AdapterController(app)
    _controller.setup()


def host():
    return _controller.host if _controller else None


def __getattr__(name):
    if name in {"group_from_payload", "register_materials", "_python_exe"}:
        from . import runtime
        return getattr(runtime, name)
    raise AttributeError(name)
