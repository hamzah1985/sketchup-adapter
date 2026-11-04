"""Collision for Alex: floors, walls, stairs and the follow camera, all by
rays against the visible model. A port of Model Viewer 2's
walkthrough/world.rb, in metres.

Every ray goes through ``Viewport.ray_distance`` — the same visible-face
index the built-in Walk and First Person tools use, so hidden objects and
hidden layers are not there to bump into. The ground plane (z = 0) is a
floor too, as in IngeTrazo's own walkthrough: an empty model can be walked."""
from __future__ import annotations

import math

from PySide6.QtGui import QVector3D

RADIUS = 0.26          # body capsule radius
HEIGHT = 1.74          # head clearance
STEP = 0.22            # tallest riser climbed without jumping
SKIN = 0.015
MIN_WALKABLE_NZ = 0.52  # floor normal's z: steeper is a wall (~58°)
#: Horizontal feelers run above the tallest step, so a riser or a ramp is
#: climbed by the floor follow instead of stopping the body.
FEELER_HEIGHTS = (0.3, 0.9, 1.5)

_DOWN = QVector3D(0.0, 0.0, -1.0)
_UP = QVector3D(0.0, 0.0, 1.0)


class World:
    def __init__(self, viewport) -> None:
        self.viewport = viewport

    # ---- Rays ---------------------------------------------------------------
    def hit(self, origin: QVector3D, direction: QVector3D, distance: float):
        """Distance to the first visible face within ``distance``, or None."""
        if distance <= 1e-4:
            return None
        d = QVector3D(direction)
        if d.lengthSquared() < 1e-18:
            return None
        t = self.viewport.ray_distance(origin, d.normalized())
        return t if t is not None and t <= distance else None

    def _floor_z(self, x: float, y: float, top: float, depth: float):
        t = self.hit(QVector3D(x, y, top), _DOWN, depth)
        z = None if t is None else top - t
        # The ground plane is a floor wherever the model has none above it.
        if top >= 0.0 >= top - depth and (z is None or z < 0.0):
            z = 0.0
        return z

    def ground(self, x: float, y: float, z: float, above: float,
               below: float):
        """Z of the walkable floor under ``(x, y)`` between ``z + above`` and
        ``z - below``, or None. The slope is read from two neighbouring
        rays; a face too steep to stand on is not a floor."""
        top = z + above
        depth = above + below
        fz = self._floor_z(x, y, top, depth)
        if fz is None:
            return None
        e = 0.05
        zx = self._floor_z(x + e, y, top, depth + e * 2)
        zy = self._floor_z(x, y + e, top, depth + e * 2)
        if zx is not None and zy is not None:
            dzx, dzy = zx - fz, zy - fz
            nz = e * e / math.sqrt((dzx * e) ** 2 + (dzy * e) ** 2 + e ** 4)
            if nz < MIN_WALKABLE_NZ:
                return None
        return fz

    def headroom(self, x: float, y: float, z: float) -> bool:
        return self.hit(QVector3D(x, y, z + STEP + SKIN), _UP,
                        HEIGHT - STEP - SKIN) is None

    def clear(self, x: float, y: float, z: float) -> bool:
        """Room for the body standing at ``(x, y, z)``: no wall within the
        radius all around, nothing overhead."""
        for h in FEELER_HEIGHTS:
            origin = QVector3D(x, y, z + h)
            for i in range(8):
                a = i * math.pi / 4
                if self.hit(origin, QVector3D(math.cos(a), math.sin(a), 0.0),
                            RADIUS) is not None:
                    return False
        return self.headroom(x, y, z)

    def passage(self, x: float, y: float, z: float, dx: float,
                dy: float) -> bool:
        """Can the body sweep ``(dx, dy)`` from ``(x, y, z)``? Feelers at
        three heights, at the centre and both sides, keep thin walls from
        being tunnelled through."""
        length = math.hypot(dx, dy)
        if length < 1e-6:
            return True
        ux, uy = dx / length, dy / length
        direction = QVector3D(ux, uy, 0.0)
        for h in FEELER_HEIGHTS:
            for side in (-RADIUS, 0.0, RADIUS):
                origin = QVector3D(x - uy * side, y + ux * side, z + h)
                if self.hit(origin, direction, length + RADIUS) is not None:
                    return False
        return self.headroom(x + dx, y + dy, z)

    # ---- Camera -------------------------------------------------------------
    def camera_distance(self, target: QVector3D, direction: QVector3D,
                        desired: float) -> float:
        """How far the follow camera may sit behind ``target`` along
        ``direction`` before a wall is in the way (a small cross of rays
        keeps it from grazing one)."""
        best = desired
        for ox, oy in ((0, 0), (0.16, 0), (-0.16, 0), (0, 0.16), (0, -0.16)):
            origin = QVector3D(target.x() + ox, target.y() + oy, target.z())
            t = self.hit(origin, direction, desired)
            if t is not None:
                best = min(best, max(t - 0.2, 0.08))
        return best
