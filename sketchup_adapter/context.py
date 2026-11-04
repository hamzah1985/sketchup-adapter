# SPDX-License-Identifier: GPL-3.0-or-later
"""The extension's own right-click menu (UI.add_context_menu_handler), added
to IngeTrazo's viewport context menu for the current selection."""
from __future__ import annotations

import logging

from PySide6.QtWidgets import QMenu

log = logging.getLogger("ingetrazo.plugins.sketchup_adapter")


def _fill(host, qmenu, tree) -> None:
    for it in tree.get("items", []):
        if it.get("separator"):
            qmenu.addSeparator()
        elif it.get("submenu"):
            sub = qmenu.addMenu(it["submenu"].get("name", ""))
            _fill(host, sub, it["submenu"])
        else:
            act = qmenu.addAction(it.get("text", ""))
            act.setEnabled(bool(it.get("enabled", True)))
            if it.get("checked"):
                act.setCheckable(True)
                act.setChecked(True)
            act.triggered.connect(lambda _c=False, cid=it["id"]: host.send({"op": "menu_click", "id": cid}))


def fetch_menu(host):
    """Return the last asynchronously refreshed menu without blocking Qt."""
    return host._context_menu if host.ready else None


def install_context_menu(host) -> None:
    win = host.app.window
    original = getattr(win, "show_viewport_context_menu", None)
    if not callable(original):
        return

    def wrapped(global_pos, *args, **kwargs):
        tree = fetch_menu(host)
        # Handle whatever arrived meanwhile once the menu is gone.
        if tree and tree.get("items"):
            orig_exec = QMenu.exec

            def exec_with_ours(menu, *a, **k):
                QMenu.exec = orig_exec
                menu.addSeparator()
                _fill(host, menu, tree)
                return orig_exec(menu, *a, **k)

            QMenu.exec = exec_with_ours
            try:
                return original(global_pos, *args, **kwargs)
            finally:
                QMenu.exec = orig_exec
                host._on_stdout_drain()
        result = original(global_pos, *args, **kwargs)
        host._on_stdout_drain()
        return result

    win.show_viewport_context_menu = wrapped
