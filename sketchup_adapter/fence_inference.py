"""Native snapping for Fence Crafter's Ruby-owned path draft."""
from PySide6.QtCore import Qt
from PySide6.QtGui import QVector3D


class FenceInference:
    def init_path_inference(self, enabled):
        self._path_inference_enabled = enabled
        self.start_point = self.chain_first_point = self.hover_point = None
        self._path_plane = None

    @property
    def magnetic_axis_deg(self):
        return 3.0 if self._path_inference_enabled and self._path_plane is None else None

    @property
    def screen_axis_px(self):
        return 9.0 if self.magnetic_axis_deg is not None else None

    def sync_path_inference(self, state):
        if not self._path_inference_enabled:
            return
        point = lambda p: QVector3D(*(float(v) * 0.0254 for v in p)) if p is not None else None
        self.start_point = point(state.get('start'))
        self.chain_first_point = point(state.get('first'))
        self.hover_point = point(state.get('cursor'))
        self._path_plane = state.get('plane')
        direction = state.get('shift_direction')
        vp = self.host.app.viewport
        vp._shift_lock = ((QVector3D(*direction).normalized(), (180/255, 40/255, 190/255))
                          if direction is not None and self.start_point is not None else None)

    def path_key(self, viewport, key, pressed):
        if not self._path_inference_enabled or int(key) != int(Qt.Key_Shift):
            return
        viewport._shift_lock = None
        if pressed and self.start_point is not None and self.hover_point is not None:
            direction = self.hover_point - self.start_point
            if direction.lengthSquared() > 1e-12:
                viewport._shift_lock = (direction.normalized(), (180/255, 40/255, 190/255))

    def rubber_band_lines(self):
        if self._path_inference_enabled and self.start_point is not None and self.hover_point is not None:
            return [(self.start_point, self.hover_point)]
        return []
