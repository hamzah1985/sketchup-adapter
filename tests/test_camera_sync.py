"""Camera snapshots are read-only and reflect actual native viewport geometry."""
import math
import unittest
from types import SimpleNamespace
from sketchup_adapter.camera_sync import snapshot, sync


class Vector:
    def __init__(self, *values): self.values = values
    def toTuple(self): return self.values


class Viewport:
    def __init__(self):
        self.camera = SimpleNamespace(eye=lambda: Vector(3,4,5), target=Vector(1,2,3),
            up_vector=lambda: Vector(0,0,1), fov_deg=60, distance=4, perspective=True)
    def width(self): return 1000
    def height(self): return 500


class CameraSyncTest(unittest.TestCase):
    def test_sends_actual_camera_only_when_changed(self):
        view = Viewport(); sent = []
        host = SimpleNamespace(ready=True, app=SimpleNamespace(viewport=view), send=sent.append)
        sync(host); sync(host)
        self.assertEqual(1, len(sent))
        data = sent[0]['values']
        self.assertEqual([3,4,5], data['eye'])
        self.assertEqual([1,2,3], data['target'])
        self.assertEqual([1000,500], data['viewport_size'])
        self.assertAlmostEqual(8 * math.tan(math.pi/6), data['height'])
        view.camera.perspective = False; sync(host)
        self.assertEqual(2, len(sent)); self.assertFalse(sent[-1]['values']['perspective'])

    def test_invalid_camera_is_not_published(self):
        view = Viewport(); view.camera.fov_deg = float('nan')
        self.assertIsNone(snapshot(view))
        view.camera.fov_deg = 60; view.camera.distance = 0
        self.assertIsNone(snapshot(view))


if __name__ == '__main__': unittest.main()
