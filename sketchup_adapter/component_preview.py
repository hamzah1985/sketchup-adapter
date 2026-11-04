# SPDX-License-Identifier: GPL-3.0-or-later
"""Render pending extension components through the native GPU group preview."""
from __future__ import annotations


class ComponentPreviewMixin:
    """Upload off-scene geometry once; hover changes only its pose matrix.

    This retains the base tool's snapping and face alignment, without its
    2,000-edge wireframe fallback. Nothing is inserted until the user clicks.
    """

    def on_activate(self, viewport) -> None:
        super().on_activate(viewport)
        self._component_preview_viewport = None
        if self._group is None:
            return
        if all(callable(getattr(viewport, name, None)) for name in (
                "begin_groups_preview", "set_groups_preview_matrix",
                "end_groups_preview")):
            viewport.begin_groups_preview([self._group], external=True)
            self._component_preview_viewport = viewport
            viewport.set_groups_preview_matrix(self._pose_matrix(self._offset))

    def on_hover(self, ctx) -> None:
        super().on_hover(ctx)
        if getattr(self, "_component_preview_viewport", None) is ctx.viewport:
            ctx.viewport.set_groups_preview_matrix(self._pose_matrix(self._offset))

    def rubber_band_lines(self):
        if getattr(self, "_component_preview_viewport", None) is not None:
            return []
        return super().rubber_band_lines()

    def _end_component_preview(self) -> None:
        viewport = getattr(self, "_component_preview_viewport", None)
        self._component_preview_viewport = None
        if viewport is not None:
            viewport.end_groups_preview()
            viewport.update()

    def on_cancel(self, viewport) -> None:
        self._end_component_preview()
        super().on_cancel(viewport)

    def on_deactivate(self, viewport) -> None:
        self._end_component_preview()
        super().on_deactivate(viewport)
