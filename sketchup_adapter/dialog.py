# SPDX-License-Identifier: GPL-3.0-or-later
"""UI::HtmlDialog for IngeTrazo, in its OWN process.

Qt WebEngine cannot live in IngeTrazo's process: the viewport's OpenGL Core
context is created without ``AA_ShareOpenGLContexts`` and a web view there
turns the whole window black and mirrored. So this file runs as a separate
program (``python dialog.py <owner-hwnd>``) that shows the extension's own
HTML and talks JSON lines with the plugin:

  in  (stdin):  dialog_new / dialog_file / dialog_html / dialog_url /
                dialog_show / dialog_front / dialog_close / dialog_size /
                dialog_pos / exec_js / quit
  out (stdout): callback {dialog,name,args} / dialog_closed / dialog_resized

The window is OWNED by the IngeTrazo main window (Win32 owner), so it stays
above it like SketchUp's STYLE_UTILITY dialog without being on top of every
other application.
"""
from __future__ import annotations

import json
import sys
import threading

from PySide6.QtCore import QByteArray, QFile, QIODevice, QObject, QSettings, Qt, QTimer, QUrl, Signal, Slot
from PySide6.QtWidgets import QApplication, QVBoxLayout, QWidget

STYLE_UTILITY = 2

def register_legacy_scheme():
    from PySide6.QtWebEngineCore import QWebEngineUrlScheme
    scheme = QWebEngineUrlScheme(b"skp")
    scheme.setSyntax(QWebEngineUrlScheme.Syntax.Path)
    QWebEngineUrlScheme.registerScheme(scheme)

_FORM_SNAPSHOT = r"""(function () {
  var values = {};
  document.querySelectorAll('[id],input[name],select[name],textarea[name]').forEach(function (element) {
    var key = element.id || element.name;
    if (key && !(key in values)) values[key] = element.value === undefined ? null : String(element.value);
  });
  return JSON.stringify(values);
})()"""

_SHIM = r"""
(function () {
  if (window.sketchup && window.sketchup.__wcBridge) return;
  var queue = [], target = null;
  function send(name, args) {
    var payload;
    try { payload = JSON.stringify([name, args]); }
    catch (e) { payload = JSON.stringify([name, args.map(function (a) { return String(a); })]); }
    if (target) target.call(payload); else queue.push(payload);
  }
  var api = { __wcBridge: true };
  window.sketchup = new Proxy(api, {
    get: function (obj, name) {
      if (name in obj) return obj[name];
      if (typeof name !== 'string') return undefined;
      return function () { send(name, Array.prototype.slice.call(arguments)); };
    }
  });
  function connect() {
    if (typeof QWebChannel === 'undefined' || !window.qt || !qt.webChannelTransport) {
      return setTimeout(connect, 10);
    }
    new QWebChannel(qt.webChannelTransport, function (ch) {
      target = ch.objects.wc;
      var q = queue; queue = [];
      q.forEach(function (p) { target.call(p); });
    });
  }
  connect();
})();
"""

_out_lock = threading.Lock()


def emit(msg: dict) -> None:
    with _out_lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()


def _qwebchannel_js() -> str:
    f = QFile(":/qtwebchannel/qwebchannel.js")
    if not f.open(QIODevice.ReadOnly):
        sys.stderr.write("qwebchannel.js is not available\n")
        return ""
    data = bytes(f.readAll()).decode("utf-8")
    f.close()
    return data


_foreign = {}


def _set_owner(widget: QWidget, owner_hwnd: int) -> None:
    """Keep ``widget`` above IngeTrazo's main window (an owned window, like
    SketchUp's STYLE_UTILITY dialog) without floating over other apps."""
    if not owner_hwnd:
        return
    try:
        from PySide6.QtGui import QWindow
        owner = _foreign.get(owner_hwnd) or QWindow.fromWinId(owner_hwnd)
        _foreign[owner_hwnd] = owner
        widget.winId()                          # make sure the native window exists
        widget.windowHandle().setTransientParent(owner)
    except Exception as exc:                    # noqa: BLE001
        sys.stderr.write(f"could not set dialog owner: {exc}\n")


def make_classes():
    from PySide6.QtWebChannel import QWebChannel
    from PySide6.QtWebEngineCore import (QWebEnginePage, QWebEngineScript, QWebEngineSettings,
        QWebEngineProfile, QWebEngineUrlSchemeHandler, QWebEngineUrlRequestJob)
    from PySide6.QtWebEngineWidgets import QWebEngineView

    def emit_legacy_callback(page, message):
        if not page._adapter_dialog.callback_allowed():
            return
        def received(value):
            try:
                values = json.loads(value) if isinstance(value, str) else value or {}
            except ValueError:
                values = {}
            emit(dict(message, values=values))
        # Query after Chromium has cancelled the skp: navigation, while the
        # original document is still active.
        QTimer.singleShot(0, lambda: page.runJavaScript(_FORM_SNAPSHOT, received))

    class Page(QWebEnginePage):
        def acceptNavigationRequest(self, url, kind, is_main_frame):  # noqa: N802
            if url.scheme().lower() == "skp":
                from urllib.parse import unquote
                name, _, argument = url.toString()[4:].partition("@")
                message = {"op": "callback", "dialog": self._adapter_dialog.dialog_id,
                           "name": unquote(name), "args": [unquote(argument)]}
                emit_legacy_callback(self, message)
                return False
            if url.scheme().lower() not in ("", "file", "http", "https", "about", "data", "qrc", "blob"):
                return False
            return super().acceptNavigationRequest(url, kind, is_main_frame)

        def javaScriptConsoleMessage(self, level, message, line, source):  # noqa: N802
            sys.stderr.write(f"dialog js [{source.rsplit('/', 1)[-1]}:{line}] {message}\n")

    class Bridge(QObject):
        def __init__(self, dialog) -> None:
            super().__init__(dialog)
            self._dialog = dialog

        @Slot(str)
        def call(self, payload: str) -> None:
            if not self._dialog.callback_allowed():
                return
            try:
                name, args = json.loads(payload)
            except ValueError:
                return
            emit({"op": "callback", "dialog": self._dialog.dialog_id, "name": name, "args": args})

    class LegacySchemeHandler(QWebEngineUrlSchemeHandler):
        def __init__(self, dialog, parent):
            super().__init__(parent)
            self.dialog = dialog

        def requestStarted(self, job):  # noqa: N802
            from urllib.parse import unquote
            name, _, argument = job.requestUrl().toString()[4:].partition("@")
            message = {"op": "callback", "dialog": self.dialog.dialog_id,
                       "name": unquote(name), "args": [unquote(argument)]}
            emit_legacy_callback(self.dialog.view.page(), message)
            job.fail(QWebEngineUrlRequestJob.RequestAborted)

    class WebDialog(QWidget):
        def __init__(self, msg, owner_hwnd) -> None:
            super().__init__(None, Qt.Window | Qt.WindowCloseButtonHint | Qt.WindowTitleHint |
                             Qt.WindowMinMaxButtonsHint)
            self.dialog_id = int(msg["id"])
            self.remote_action_hosts = set()
            self.source_host = ''
            self.pref_key = msg.get("pref_key") or f"dialog{self.dialog_id}"
            self.owner_hwnd = owner_hwnd if int(msg.get("style", 1)) == STYLE_UTILITY else 0
            self._loaded = False
            self._pending_js: list[str] = []
            self._closing_from_ruby = False
            self._owned = False
            self.setWindowTitle(msg.get("title") or "SketchUp Adapter")
            self.setMinimumSize(int(msg.get("min_width") or 0), int(msg.get("min_height") or 0))
            self.setMaximumSize(int(msg.get("max_width") or 16777215), int(msg.get("max_height") or 16777215))
            self.resize(int(msg.get("width") or 400), int(msg.get("height") or 400))
            geo = QSettings("ingetrazo", "sketchup_adapter").value(f"{self.pref_key}/geometry")
            if isinstance(geo, (QByteArray, bytes)):
                self.restoreGeometry(geo)
            if not msg.get("resizable", True):
                self.setFixedSize(self.size())

            lay = QVBoxLayout(self)
            lay.setContentsMargins(0, 0, 0, 0)
            self.view = QWebEngineView(self)
            self.profile = QWebEngineProfile(self)
            self.legacy_handler = LegacySchemeHandler(self, self.profile)
            self.profile.installUrlSchemeHandler(b"skp", self.legacy_handler)
            page = Page(self.profile, self.view)
            page._adapter_dialog = self
            self.view.setPage(page)
            s = page.settings()
            # Legacy plugins use JavaScript location changes for callbacks,
            # including callbacks outside a trusted browser mouse gesture.
            # Page intercepts skp: and rejects other unknown schemes above.
            s.setUnknownUrlSchemePolicy(QWebEngineSettings.AllowAllUnknownUrlSchemes)
            s.setAttribute(QWebEngineSettings.LocalContentCanAccessFileUrls, True)
            s.setAttribute(QWebEngineSettings.LocalContentCanAccessRemoteUrls, True)
            s.setAttribute(QWebEngineSettings.JavascriptCanAccessClipboard, True)
            self.channel = QWebChannel(page)
            self.bridge = Bridge(self)
            self.channel.registerObject("wc", self.bridge)
            page.setWebChannel(self.channel)
            for name, src in (("qwebchannel", _qwebchannel_js()), ("sketchup_shim", _SHIM)):
                sc = QWebEngineScript()
                sc.setName(name)
                sc.setSourceCode(src)
                sc.setInjectionPoint(QWebEngineScript.DocumentCreation)
                sc.setWorldId(QWebEngineScript.MainWorld)
                sc.setRunsOnSubFrames(False)
                page.scripts().insert(sc)
            page.loadFinished.connect(self._on_loaded)
            lay.addWidget(self.view)

        def ensure_owner(self):
            if not self._owned:
                _set_owner(self, self.owner_hwnd)
                self._owned = True

        def callback_allowed(self):
            url = self.view.page().url()
            return url.scheme() not in ('http', 'https') or url.host().lower() in {self.source_host, *self.remote_action_hosts}

        def _on_loaded(self, ok: bool) -> None:
            if not ok:
                return
            self._loaded = True
            pending, self._pending_js = self._pending_js, []
            for js in pending:
                self.view.page().runJavaScript(js)

        def run_js(self, js: str) -> None:
            if self._loaded:
                self.view.page().runJavaScript(js)
            else:
                self._pending_js.append(js)

        def closeEvent(self, ev):  # noqa: N802
            QSettings("ingetrazo", "sketchup_adapter").setValue(f"{self.pref_key}/geometry",
                                                              self.saveGeometry())
            if not self._closing_from_ruby:
                emit({"op": "dialog_close_requested", "dialog": self.dialog_id})
                ev.ignore()
                return
            self._closing_from_ruby = False
            super().closeEvent(ev)

        def moveEvent(self, ev):  # noqa: N802
            super().moveEvent(ev)
            emit({"op": "dialog_moved", "dialog": self.dialog_id,
                  "x": self.x(), "y": self.y()})

        def resizeEvent(self, ev):  # noqa: N802
            super().resizeEvent(ev)
            emit({"op": "dialog_resized", "dialog": self.dialog_id,
                  "w": self.width(), "h": self.height()})

    return WebDialog


class Inbox(QObject):
    message = Signal(object)


def main() -> int:
    owner = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
    QApplication.setAttribute(Qt.AA_ShareOpenGLContexts, True)
    register_legacy_scheme()
    app = QApplication(sys.argv[:1])
    app.setQuitOnLastWindowClosed(False)
    WebDialog = make_classes()
    dialogs: dict[int, QWidget] = {}
    inbox = Inbox()

    def handle(msg):
        op = msg.get("op")
        if op == "quit":
            app.quit()
            return
        did = int(msg.get("id", 0))
        if op == "dialog_new":
            old = dialogs.pop(did, None)
            if old is not None:
                old.deleteLater()
            dialogs[did] = WebDialog(msg, owner)
            return
        dlg = dialogs.get(did)
        if dlg is None:
            return
        if op == "dialog_file":
            dlg.source_host = ''
            dlg._loaded = False
            dlg.view.load(QUrl.fromLocalFile(msg["path"]))
        elif op == "dialog_html":
            dlg.source_host = ''
            dlg._loaded = False
            dlg.view.setHtml(msg["html"], QUrl.fromLocalFile("/"))
        elif op == "dialog_url":
            dlg.source_host = QUrl(msg['url']).host().lower()
            dlg.view.load(QUrl(msg["url"]))
        elif op == 'dialog_allow_host':
            dlg.remote_action_hosts.add(msg['hostname'].lower())
        elif op in ("dialog_show", "dialog_front"):
            dlg.ensure_owner()
            dlg.show()
            dlg.raise_()
            dlg.activateWindow()
        elif op == "dialog_close":
            dlg._closing_from_ruby = True
            dlg.close()
        elif op == "dialog_size":
            dlg.resize(int(msg["w"]), int(msg["h"]))
        elif op == "dialog_pos":
            dlg.move(int(msg["x"]), int(msg["y"]))
        elif op == "dialog_center":
            screen = dlg.screen().availableGeometry()
            dlg.move(screen.center() - dlg.rect().center())
        elif op == "dialog_constraints":
            if "min_width" in msg:
                dlg.setMinimumSize(int(msg["min_width"]), int(msg["min_height"]))
            if "max_width" in msg:
                dlg.setMaximumSize(int(msg["max_width"]), int(msg["max_height"]))
        elif op == "exec_js":
            dlg.run_js(msg["script"])

    inbox.message.connect(handle, Qt.QueuedConnection)

    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                inbox.message.emit(json.loads(line))
            except ValueError:
                continue
        inbox.message.emit({"op": "quit"})

    threading.Thread(target=reader, daemon=True).start()
    emit({"op": "dialog_host_ready"})
    return app.exec()


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8")
    sys.exit(main())
