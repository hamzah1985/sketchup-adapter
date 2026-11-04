"""Native display-style snapshots are read-only and emitted only on change."""
import unittest
from types import SimpleNamespace
from sketchup_adapter.rendering_options import snapshot, sync

class RenderingOptionsTest(unittest.TestCase):
    def test_only_supported_colors_and_effective_back_are_sent_when_changed(self):
        style=SimpleNamespace(background=(0.1,0.2,0.3),sky_color=(1,1,1),
                              ground_color=(0.4,0.5,0.6),front_color=(1,1,1),back_color=None)
        scene=SimpleNamespace(display_style=style,back_face_color=(0.3,0.4,0.5))
        sent=[]
        host=SimpleNamespace(ready=True,app=SimpleNamespace(scene=scene),send=sent.append)
        sync(host);sync(host)
        self.assertEqual(1,len(sent))
        self.assertEqual([26,51,76],sent[0]['values']['BackgroundColor'])
        self.assertEqual([76,102,128],sent[0]['values']['FaceBackColor'])
        style.background=(0,0,0);sync(host)
        self.assertEqual(2,len(sent))
        self.assertEqual([0,0,0],sent[-1]['values']['BackgroundColor'])
        self.assertEqual((0.3,0.4,0.5),scene.back_face_color)
    def test_missing_and_invalid_colors_are_ignored(self):
        self.assertEqual({},snapshot(SimpleNamespace()))
        style=SimpleNamespace(background=(float('nan'),0,0),sky_color=None)
        self.assertNotIn('BackgroundColor',snapshot(SimpleNamespace(display_style=style)))

if __name__=='__main__': unittest.main()
