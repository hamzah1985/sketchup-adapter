"""Keep fine repeating screen textures filtered when seen from a distance."""
from pathlib import Path


def install():
    from views.viewport import Viewport
    if getattr(Viewport._get_texture, '_bogdan_screen_filter', False):
        return
    original = Viewport._get_texture

    def texture(self, path):
        result = original(self, path)
        # The native foliage heuristic disables mipmapping for sparse alpha.
        # An insect-screen weave repeats hundreds of times across one pane;
        # forcing its top mip makes moire instead of the average fine mesh.
        if result is not None and Path(str(path)).name.endswith('wm_screen_mesh_v2.png'):
            from PySide6.QtOpenGL import QOpenGLTexture
            result.setMinificationFilter(QOpenGLTexture.LinearMipMapLinear)
            result._cutout = False
        return result
    texture._bogdan_screen_filter = True
    Viewport._get_texture = texture
