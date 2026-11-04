# SPDX-License-Identifier: GPL-3.0-or-later
"""SketchUp's ``model.place_component`` for extension component definitions.

The window follows the cursor from its own origin (the bottom-left corner of
the outside face) and glues to walls the way a SketchUp window component
does: over a vertical face its front turns to the face, its depth runs into
the wall. One click places it; Esc cancels (the extension then retires the
unused definition, as it does in SketchUp).
"""
from __future__ import annotations

from PySide6.QtGui import QVector3D

from tools.place_group import PlaceGroupTool
from .component_preview import ComponentPreviewMixin


class ExtensionPlaceTool(ComponentPreviewMixin, PlaceGroupTool):
    name = "Place extension item"

    def __init__(self, host, def_id, payload, group) -> None:
        super().__init__(group, align_to_face=True, anchor=QVector3D(0.0, 0.0, 0.0))
        self.host = host
        self.def_id = def_id
        self.payload = payload
        self._finished = False

    def on_click(self, ctx) -> None:
        if self._group is None:
            return
        self._update_alignment(ctx)
        shift = ctx.world - self._rotate(self._anchor)
        group = self._group
        self._end_component_preview()
        group.xform = self._pose_matrix(shift) * group.xform
        self._group = None
        self._finished = True
        placed = self.host.placement_done(self, group)
        vp = ctx.viewport
        if placed:
            vp.flash_status("Component placed — Move (M) adjusts it")
        else:
            vp.flash_status("Component could not be placed; please retry.", 8000)
        window = vp.window()
        if hasattr(window, "_activate_tool"):
            window._activate_tool("select")
        vp.update()

    def on_cancel(self, viewport) -> None:
        super().on_cancel(viewport)
        self._finish_cancel()
        window = viewport.window()
        if hasattr(window, "_activate_tool"):
            window._activate_tool("select")

    def on_deactivate(self, viewport) -> None:
        super().on_deactivate(viewport)
        self._finish_cancel()

    def _finish_cancel(self) -> None:
        if not self._finished:
            self._finished = True
            self.host.placement_cancelled(self)
