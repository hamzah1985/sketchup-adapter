"""Walk With Alex — Model Viewer 2's native walkthrough figure, ported
from the SketchUp plugin by Bogdan Demchenko (the browser export is not
part of this port).

Extensions ▸ Walk With Alex, then click a floor. See tool.py for the
controls. AlexTool installs the textured preview compatibility renderer
when the native viewport does not consume animated triangle previews."""
from pathlib import Path

from tools.base import Tool


class WalkWithAlex(Tool):
    """The Extensions-menu entry. Menu tools are one-shot, so this hands the
    viewport a live walking tool, which then owns keys, mouse and camera
    until Esc or another tool is picked."""
    name = "Walk With Alex"
    shortcut = None
    #: Model Viewer 2's walk logo: the menu icon and the Extensions toolbar
    #: button.
    icon_path = str(Path(__file__).resolve().parent / "walk.svg")

    def on_activate(self, viewport) -> None:
        from .tool import AlexTool
        viewport.set_active_tool(AlexTool())
        window = viewport.window()
        label = getattr(window, "_tool_label", None)
        if label is not None:
            label.setText("Tool: Walk With Alex")

    def on_deactivate(self, viewport) -> None:
        pass
