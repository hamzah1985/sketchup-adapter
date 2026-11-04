"""Walk With Alex: place a character on a floor and walk it through the
model in third person. A port of Model Viewer 2's walkthrough/tool.rb
(the native SketchUp figure), without the browser export.

Controls, as games have them: WASD / arrows walk, Shift runs, Space jumps,
left or right drag looks around, the wheel sets the camera distance (all
the way in is first person), V or C switches first/third person, R places
Alex again, Esc stops. While the game runs the keyboard is ALL the game's:
no IngeTrazo shortcut fires, Ctrl ones included. Leaving the tool (Esc or
any other tool) puts the camera back where it was."""
from __future__ import annotations

import math
import time

from PySide6.QtCore import QEvent, QObject, QPointF, Qt
from PySide6.QtGui import QColor, QFont, QVector3D

from tools.base import Tool, ToolContext

from .avatar import Avatar
from .world import HEIGHT, SKIN, STEP, World

EYE_ABOVE_FEET = 1.51    # follow-camera target height on the body
FIRST_PERSON_EYE = 1.62  # Alex's eye level (he is 1.72 m tall)
WALK_SPEED = 1.45        # m/s
RUN_SPEED = 4.6
JUMP_SPEED = 7.4
GRAVITY = 27.0
TICK_MS = 33

HELP = ("WASD/arrows: walk  |  Shift: run  |  Space: jump  |  Drag: look\n"
        "Wheel: distance  |  V: 1st/3rd person  |  R: place again  |  "
        "Esc: stop")
PLACE_HELP = "Click a floor or the ground to place Alex.  Esc cancels."

_FORWARD = (Qt.Key_W, Qt.Key_Up)
_BACK = (Qt.Key_S, Qt.Key_Down)
_LEFT = (Qt.Key_A, Qt.Key_Left)
_RIGHT = (Qt.Key_D, Qt.Key_Right)
_MOVE_KEYS = frozenset(_FORWARD + _BACK + _LEFT + _RIGHT)
_JUMP_KEY = Qt.Key_Space
_VIEW_KEYS = frozenset((Qt.Key_V, Qt.Key_C))
#: Closest third-person distance; the wheel in past it is first person.
MIN_DISTANCE = 1.6


class _WheelFilter(QObject):
    """The viewport has no wheel hook for tools; while Alex is placed the
    wheel sets the follow distance instead of zooming the camera away."""

    def __init__(self, tool) -> None:
        super().__init__()
        self._tool = tool

    def eventFilter(self, obj, ev) -> bool:
        if ev.type() == QEvent.Wheel and self._tool.placed:
            self._tool.on_wheel(ev.angleDelta().y() / 120.0)
            return True
        return False


class AlexTool(Tool):
    name = "Walk With Alex"
    uses_snap = False

    def __init__(self) -> None:
        self._viewport = None
        self._avatar = None
        self._world = None
        self._timer = None
        self._wheel = None
        self._saved_camera = None
        self.held: set[int] = set()
        self._reset_state()

    def _reset_state(self) -> None:
        self._pos = None             # feet, [x, y, z] metres
        self._spawn = None
        self._vx = self._vy = self._vz = 0.0
        self._grounded = True
        self._last_ground = None
        self._jump_until = None
        self._time = 0.0
        self._clip = "Idle"
        self._clip_time = 0.0
        self._cam_target = None

    @property
    def placed(self) -> bool:
        return self._pos is not None

    # ---- Activation ---------------------------------------------------------
    def on_activate(self, viewport) -> None:
        from .textured_preview import install
        install(viewport)
        self._viewport = viewport
        cam = viewport.camera
        self._saved_camera = dict(
            target=QVector3D(cam.target), distance=cam.distance, yaw=cam.yaw,
            pitch=cam.pitch, fov_deg=cam.fov_deg, perspective=cam.perspective,
            two_point=getattr(cam, "two_point", False))
        f = cam.forward()
        self._yaw = math.atan2(f.x(), -f.y())
        self._facing = self._yaw
        self._pitch = 0.28
        self._distance = 4.8
        self._cam_distance = self._distance
        self._first_person = False
        self._reset_state()
        self.held.clear()
        self._world = World(viewport)
        if self._avatar is None:
            self._avatar = Avatar()
        self._wheel = _WheelFilter(self)
        viewport.installEventFilter(self._wheel)
        from PySide6.QtCore import QTimer
        self._timer = QTimer(viewport)
        self._timer.setInterval(TICK_MS)
        self._timer.timeout.connect(self._tick)
        self._last_tick = time.monotonic()
        self._timer.start()
        self._flash(PLACE_HELP)
        viewport.setFocus()
        viewport.update()

    def on_deactivate(self, viewport) -> None:
        if self._timer is not None:
            self._timer.stop()
            self._timer.deleteLater()
            self._timer = None
        if self._wheel is not None:
            viewport.removeEventFilter(self._wheel)
            self._wheel = None
        self.held.clear()
        self._reset_state()
        if self._avatar is not None:
            self._avatar.clear()
        self._restore_camera(viewport)
        self._viewport = None
        viewport.update()

    def _restore_camera(self, viewport) -> None:
        saved = self._saved_camera
        if not saved:
            return
        cam = viewport.camera
        for name, value in saved.items():
            setattr(cam, name, QVector3D(value) if name == "target" else value)

    def _flash(self, text: str) -> None:
        flash = getattr(self._viewport, "flash_status", None)
        if flash is not None:
            flash(text, 6000)

    # ---- Placing ------------------------------------------------------------
    def on_click(self, ctx: ToolContext) -> None:
        if self.placed:
            return
        w = ctx.world
        floor = self._world.ground(w.x(), w.y(), w.z(), 0.3, 0.3)
        if floor is None or not self._world.clear(w.x(), w.y(), floor):
            self._flash("Click an open floor or ground surface with room "
                        "for Alex.")
            return
        self._pos = [w.x(), w.y(), floor]
        self._spawn = list(self._pos)
        self._grounded = True
        self._avatar.update("Idle", 0.0, self._pos, self._facing)
        self._update_camera(1.0)
        self._flash(HELP)
        ctx.viewport.update()

    def _place_again(self) -> None:
        self._reset_state()
        self.held.clear()
        self._avatar.clear()
        self._restore_camera(self._viewport)
        self._flash(PLACE_HELP)
        self._viewport.update()

    # ---- Keys ---------------------------------------------------------------
    def claims_key(self, key: int, modifiers) -> bool:
        """Every key, Ctrl ones included: while the game runs the keyboard
        is the game's, as in any game — no tool or menu shortcut fires
        under a walking player. Esc leaves the game."""
        return True

    def on_key(self, viewport, key: int, modifiers) -> bool:
        if key == Qt.Key_Escape:
            self._stop(viewport)
        elif key in _VIEW_KEYS:
            self._first_person = not self._first_person
        elif key == Qt.Key_R:
            self._place_again()
        elif key == _JUMP_KEY:
            self._jump_until = self._time + 0.16
        elif key in _MOVE_KEYS:
            self.held.add(key)
        return True                       # the rest: swallowed

    def on_key_release(self, viewport, key: int) -> bool:
        self.held.discard(key)
        return True

    def on_focus_out(self, viewport) -> None:
        self.held.clear()

    def on_cancel(self, viewport) -> None:
        self.held.clear()

    def _stop(self, viewport) -> None:
        window = viewport.window()
        activate = getattr(window, "_activate_tool", None)
        if callable(activate):
            activate("select")
        else:
            viewport.set_active_tool(None)

    # ---- Mouse --------------------------------------------------------------
    @property
    def on_look(self):
        """Only once Alex stands somewhere: before that, the left click is
        the placing click (the viewport gives every press to ``on_look``
        when the tool has one)."""
        return self._look if self.placed else None

    def _look(self, viewport, dx: float, dy: float) -> None:
        self._yaw -= dx * 0.0042
        self._pitch = max(-0.78, min(0.92, self._pitch + dy * 0.0032))

    def on_wheel(self, steps: float) -> None:
        """Scroll in to come closer; in past the closest distance is first
        person, and scrolling out from there brings Alex back."""
        if self._first_person:
            if steps < 0:
                self._first_person = False
                self._distance = self._cam_distance = MIN_DISTANCE
            return
        if steps > 0 and self._distance <= MIN_DISTANCE + 1e-6:
            self._first_person = True
            return
        self._distance = max(MIN_DISTANCE,
                             min(7.5, self._distance - steps * 0.3))

    def context_menu(self, viewport, pos) -> bool:
        return True                       # right drag looks; no menu

    # ---- Frame --------------------------------------------------------------
    def _running(self) -> bool:
        from PySide6.QtWidgets import QApplication
        return bool(QApplication.keyboardModifiers() & Qt.ShiftModifier)

    def _tick(self) -> None:
        vp = self._viewport
        if vp is None:
            return
        now = time.monotonic()
        elapsed = now - self._last_tick
        self._last_tick = now
        if elapsed > 0.25:
            self.held.clear()             # the app stalled: no runaway walk
        if not self.placed:
            return
        dt = min(elapsed, 0.05)
        self._time += dt
        for _ in range(2):
            self._physics(dt / 2)
        moving = math.hypot(self._vx, self._vy) > 0.18
        clip = ("Jump" if not self._grounded
                else ("Run" if self._running() else "Walk") if moving
                else "Idle")
        if clip != self._clip:
            self._clip_time = 0.0
        self._clip = clip
        self._clip_time += dt * (1.08 if clip == "Run" else 1.0)
        if not self._first_person:
            self._avatar.update(clip, self._clip_time, self._pos, self._facing)
        self._update_camera(dt)
        vp.update()

    def _physics(self, dt: float) -> None:
        w = self._world
        keys = self.held
        fwd = any(k in keys for k in _FORWARD) - any(k in keys for k in _BACK)
        right = any(k in keys for k in _RIGHT) - any(k in keys for k in _LEFT)
        length = math.hypot(fwd, right)
        speed = RUN_SPEED if self._running() else WALK_SPEED
        # Forward is the camera's heading; right is forward × up (Z up).
        sy, cy = math.sin(self._yaw), math.cos(self._yaw)
        dx = (sy * fwd - cy * right) / length if length else 0.0
        dy = (-cy * fwd - sy * right) / length if length else 0.0
        blend = 1 - math.exp(-(12.0 if self._grounded else 4.2) * dt)
        self._vx += (dx * speed - self._vx) * blend
        self._vy += (dy * speed - self._vy) * blend
        if length:
            angle = math.atan2(dx, -dy) - self._facing
            angle = math.atan2(math.sin(angle), math.cos(angle))
            self._facing += angle * (1 - math.exp(-14 * dt))
        if self._grounded:
            self._last_ground = self._time
        if (self._jump_until is not None and self._jump_until >= self._time
                and self._last_ground is not None
                and self._time - self._last_ground <= 0.12):
            self._vz = JUMP_SPEED
            self._grounded = False
            self._last_ground = None
            self._jump_until = None

        x, y, z = self._pos
        mx, my = self._vx * dt, self._vy * dt
        if abs(mx) + abs(my) > 1e-6:
            if w.passage(x, y, z, mx, my):
                x, y = x + mx, y + my
            elif w.passage(x, y, z, mx, 0.0):     # slide along the wall
                x += mx
            elif w.passage(x, y, z, 0.0, my):
                y += my

        self._vz -= GRAVITY * dt
        next_z = z + self._vz * dt
        if self._vz > 0 and w.hit(QVector3D(x, y, z + HEIGHT),
                                  QVector3D(0, 0, 1),
                                  self._vz * dt + SKIN) is not None:
            self._vz = 0.0                          # head on the ceiling
            next_z = z
        # Look down from one step above the feet: a riser or a ramp ahead
        # is the new floor; a drop is fallen (a short one snapped while
        # walking, so going downstairs does not hop).
        below = max(z - next_z + SKIN, 0.24 if self._grounded else 0.0)
        floor = w.ground(x, y, z, STEP, below)
        if self._vz <= 0 and floor is not None and (
                next_z <= floor + SKIN or self._grounded):
            z = floor
            self._vz = 0.0
            self._grounded = True
        else:
            z = next_z
            self._grounded = False
        self._pos = [x, y, z]
        # Fell out of the model: back to where Alex was placed.
        if not self._grounded and z < self._spawn[2] - 4.0:
            if w.ground(x, y, z, SKIN, 200.0) is None:
                self._pos = list(self._spawn)
                self._vx = self._vy = self._vz = 0.0
                self._grounded = True
                self._cam_target = None

    def _update_camera(self, dt: float) -> None:
        x, y, z = self._pos
        target = QVector3D(x, y, z + EYE_ABOVE_FEET)
        if self._cam_target is not None and not self._first_person:
            a = 1 - math.exp(-18 * dt)
            target = self._cam_target * (1 - a) + target * a
        self._cam_target = target
        cp = math.cos(self._pitch)
        backward = QVector3D(-math.sin(self._yaw) * cp,
                             math.cos(self._yaw) * cp, math.sin(self._pitch))
        cam = self._viewport.camera
        cam.perspective = True
        if hasattr(cam, "two_point"):
            cam.two_point = False
        if self._first_person:
            # Alex's own eyes, not the follow camera's aim point.
            eye = QVector3D(x, y, z + FIRST_PERSON_EYE)
            direction = -backward
            cam.fov_deg = 68.0
            cam.distance = 1.0
        else:
            allowed = self._world.camera_distance(target, backward,
                                                  self._distance)
            if allowed < self._cam_distance:
                self._cam_distance = allowed
            else:
                self._cam_distance += (allowed - self._cam_distance) * (
                    1 - math.exp(-5.5 * dt))
            eye = target + backward * self._cam_distance
            direction = target - eye
            cam.fov_deg = 60.0
            cam.distance = max(self._cam_distance, 0.05)
        cam.look_from(eye, direction)

    # ---- Drawing ------------------------------------------------------------
    def preview_textured_tris(self):
        if (not self.placed or self._first_person
                or self._cam_distance <= 0.6):
            return None
        return self._avatar.triangles()

    def draw_overlay(self, viewport, painter) -> None:
        text = HELP if self.placed else PLACE_HELP
        painter.save()
        font = QFont(painter.font())
        font.setPointSizeF(9.5)
        painter.setFont(font)
        step = painter.fontMetrics().height() + 2
        for i, line in enumerate(text.split("\n")):
            y = 24 + i * step
            painter.setPen(QColor(255, 255, 255, 200))
            painter.drawText(QPointF(19, y + 1), line)
            painter.setPen(QColor(20, 20, 20, 235))
            painter.drawText(QPointF(18, y), line)
        if self.placed and self._first_person:
            # A game's crosshair: dark cross with a light halo, readable on
            # any wall.
            from PySide6.QtGui import QPen
            c = QPointF(viewport.width() / 2.0, viewport.height() / 2.0)
            for color, width in ((QColor(255, 255, 255, 200), 3.5),
                                 (QColor(20, 20, 20, 230), 1.5)):
                painter.setPen(QPen(color, width))
                painter.drawLine(c + QPointF(-9, 0), c + QPointF(-3, 0))
                painter.drawLine(c + QPointF(3, 0), c + QPointF(9, 0))
                painter.drawLine(c + QPointF(0, -9), c + QPointF(0, -3))
                painter.drawLine(c + QPointF(0, 3), c + QPointF(0, 9))
        painter.restore()
