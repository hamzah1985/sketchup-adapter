"""Connect animated triangle previews to native viewport texture drawing.

Some native releases expose preview_faces but do not consume the animated
preview_textured_tris provider. Install once, reusing the native shader,
texture cache, VAO and VBO rather than adding geometry to the document.
"""
from __future__ import annotations

from functools import wraps


def install(viewport) -> None:
    cls = type(viewport)
    original = cls._draw_preview_faces
    if getattr(original, "_bogdan_textured_preview", False):
        return
    code = getattr(original, "__code__", None)
    if code is not None and "preview_textured_tris" in code.co_names:
        return  # A native implementation already handles the provider.
    from views.viewport import GL_TRIANGLES

    @wraps(original)
    def draw(self):
        original(self)
        provider = getattr(self.active_tool, "preview_textured_tris", None)
        batches = provider() if callable(provider) else None
        self._bogdan_textured_preview_vertices = 0
        if not batches:
            return
        self._program.setUniformValue(self._loc_use_vcolor, 0)
        self._program.setUniformValue(self._loc_use_tex, 1)
        self._program.setUniformValue1f(self._loc_opacity, 1.0)
        self._program.setUniformValue1f(self._loc_shade, 1.0)
        self._preview_tex_vao.bind()
        try:
            for path, buf in batches.items():
                if len(buf) == 0 or len(buf) % 15:
                    continue
                texture = self._get_texture(path)
                if texture is None:
                    continue
                raw = buf.tobytes()
                self._preview_tex_vbo.bind()
                self._preview_tex_vbo.allocate(raw, len(raw))
                self._preview_tex_vbo.release()
                self._program.setUniformValue(
                    self._loc_hard_cutout,
                    1 if getattr(texture, "_cutout", False) else 0)
                texture.bind(0)
                try:
                    self._gl.glDrawArrays(GL_TRIANGLES, 0, len(buf) // 5)
                    self._bogdan_textured_preview_vertices += len(buf) // 5
                finally:
                    texture.release(0)
        finally:
            self._preview_tex_vao.release()
            self._program.setUniformValue(self._loc_use_tex, 0)
            self._program.setUniformValue(self._loc_hard_cutout, 0)
            self._program.setUniformValue1f(self._loc_shade, 1.0)
            self._program.setUniformValue1f(self._loc_opacity, 1.0)

    draw._bogdan_textured_preview = True
    cls._draw_preview_faces = draw
