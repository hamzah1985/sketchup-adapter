# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Bogdan Demchenko.
"""Bogdan's SketchUp extensions hosted inside IngeTrazo.

This is not a re-implementation. The vendored Ruby extensions
(``upstream/`` and its plugin folders) run in a Ruby process on a
SketchUp-compatible API shim (``ruby_host/``). A small set of source fixes
is maintained for IngeTrazo-specific compatibility. This package is the
IngeTrazo half:

- each extension's own toolbar and commands, with its own icons;
- each extension's own HTML dialogs in Qt WebEngine, with ``sketchup.*``
  callbacks and ``execute_script`` bridged to the Ruby side;
- selection and model geometry convert between SketchUp and IngeTrazo;
- each geometry batch becomes one IngeTrazo undo step.

Requires Ruby (2.7+) on PATH or in ``C:\\Ruby*\\bin``.
"""
from __future__ import annotations

import glob
import copy
import json
import logging
import os
import shutil
import tempfile
from pathlib import Path

from PySide6.QtCore import QLocale, QObject, QProcess, QSettings, QTimer, Qt, Slot
from PySide6.QtGui import QAction, QIcon, QMatrix4x4, QVector3D
from PySide6.QtWidgets import QMessageBox, QToolBar

log = logging.getLogger("ingetrazo.plugins.sketchup_adapter")

PKG = Path(__file__).resolve().parent
HOST_RB = PKG / "ruby_host" / "host.rb"
DATA_KEY = "sketchup_adapter"
TOOLBAR_KEY = "sketchup_adapter"


def _log_dir() -> Path:
    base = os.environ.get("APPDATA") or str(Path.home() / ".local" / "share")
    d = Path(base) / "ingetrazo" / "sketchup_adapter"
    d.mkdir(parents=True, exist_ok=True)
    return d


def find_ruby() -> str | None:
    exe = shutil.which("ruby")
    if exe:
        return exe
    for pat in (r"C:\Ruby*\bin\ruby.exe", r"C:\tools\ruby*\bin\ruby.exe",
                os.path.expandvars(r"%LOCALAPPDATA%\Programs\Ruby*\bin\ruby.exe")):
        hits = sorted(glob.glob(pat), reverse=True)
        if hits:
            return hits[0]
    return None


# ---------------------------------------------------------------------------
# Payload → IngeTrazo groups
# ---------------------------------------------------------------------------

def _matrix(cols16) -> QMatrix4x4:
    """SketchUp column-major 16 → QMatrix4x4 (row-major constructor)."""
    a = [float(v) for v in cols16]
    return QMatrix4x4(*[a[c * 4 + r] for r in range(4) for c in range(4)])


def _matrix_out(m: QMatrix4x4) -> list:
    return [float(v) for v in m.data()]          # data() is column-major


def _build_mesh(pr, progress=None):
    from .alpha import install
    install()
    from .precision import detail_mesh_class, install_persistence
    install_persistence()
    mesh = detail_mesh_class()()
    for index, (outer, holes, attrs) in enumerate(pr.get("faces", []), 1):
        try:
            face = mesh.add_face([QVector3D(*p) for p in outer],
                                 [[QVector3D(*p) for p in h] for h in holes] or None)
        except Exception as exc:
            raise ValueError("The extension produced a face IngeTrazo could not import; "
                             "the object was not committed.") from exc
        if attrs:
            a = dict(attrs)
            a.pop("wc_attrs", None)
            face.attrs.update(a)
        if progress and (index % 64 == 0 or index == len(pr.get('faces', ()))):
            progress(index)
    for a, b in pr.get("edges", []):
        mesh.add_edge(QVector3D(*a), QVector3D(*b))
    for a, b in pr.get("soft_edges", []):
        va = mesh.vertex_at(QVector3D(*a))
        vb = mesh.vertex_at(QVector3D(*b))
        if va is None or vb is None or va is vb:
            continue
        e = mesh.find_edge(va, vb)
        if e is not None:
            e.soft = True
    from .topology import orient_solids
    mesh._bogdan_repaired_faces = orient_solids(mesh)
    return mesh


def group_from_payload(payload, progress=None):
    """One component instance (with its nested parts) for a Ruby payload."""
    from core.group import Group
    protos = payload["protos"]
    total = sum(len(pr.get('faces', ())) for pr in protos)
    meshes = []
    done = 0
    if progress: progress('building', 0, total)
    for pr in protos:
        offset = done
        meshes.append(_build_mesh(pr, (lambda count: progress('building', offset+count, total)) if progress else None))
        done += len(pr.get('faces', ()))

    def place(idx, xf, depth=0):
        pr = protos[idx]
        g = Group(meshes[idx], name=pr.get("name") or None)
        g.xform = xf
        g.component = False
        g.layer=pr.get('layer')
        g.ext = g.ext or {}
        g.ext["bogdan_bridge"] = {"attrs": {}, "def_attrs": pr.get("def_attrs", {})}
        g.hidden = bool(pr.get("hidden", False))
        if depth < 64:
            children = []
            for k in pr.get("children", []):
                child = place(k["proto"], _matrix(k["xform"]), depth + 1)
                child.hidden = bool(k.get("hidden", False))
                child.component = bool(k.get("component", False))
                child.name = k.get("name") or child.name
                child.layer=k.get('layer')
                child.ext["bogdan_bridge"]["attrs"] = k.get("attrs", {})
                children.append(child)
            g.adopt(children)
        return g

    root = place(payload["root"], _matrix(payload["xform"]))
    root.hidden = bool(payload.get("hidden", False))
    root.name = payload.get("name") or root.name
    root.component = bool(payload.get("component", True))
    root.layer=payload.get('layer')
    root.ext["bogdan_bridge"] = {"attrs": payload.get("attrs", {}),
                                 "def_attrs": payload.get("def_attrs", {})}
    from .section import apply_sections
    apply_sections(root, payload)
    return root


def register_materials(scene, payload):
    try:
        from core.materials import Material, register
    except Exception:                          # noqa: BLE001 — older IngeTrazo
        return
    if getattr(scene, "materials", None) is None:
        scene.materials = {}
    for raw in payload.get("materials") or []:
        if raw.get("name"):
            register(scene.materials, Material.from_dict(raw))


def recipe_of(payload) -> dict:
    return {"attrs": payload.get("attrs") or {},
            "def_attrs": payload.get("def_attrs") or {},
            "name": payload.get("name") or ""}


def share_published_components(group, payload, pool):
    """Keep shared definitions shared across roots in one native edit batch.

    Keys come from this Ruby document and include the exported mesh content.
    The pool expires with the batch; later native edits cannot reuse stale meshes.
    """
    def visit(item, index, component):
        prototype = payload['protos'][index]
        identity = prototype.get('definition_key')
        digest = prototype.get('mesh_digest')
        if component and identity is not None and digest:
            key = (identity, digest)
            item.mesh = pool.setdefault(key, item.mesh)
        for child, record in zip(item.children, prototype.get('children', [])):
            visit(child, record['proto'], bool(record.get('component')))
    visit(group, payload['root'], bool(payload.get('component')))


# ---------------------------------------------------------------------------
# The one undoable edit every Ruby sync becomes
# ---------------------------------------------------------------------------

def _make_command():
    from core.history import Command

    class WindowCrafterEdit(Command):
        """Apply extension geometry changes and recipe data as one undo step."""
        _sketchup_adapter_edit = True

        def __init__(self, adds, replaces, removes, faces, recipes, select):
            self.adds = adds              # [group]
            self.replaces = replaces      # [(old, new)]
            self.removes = removes        # [group]
            self.faces = faces            # [Face] of the loose mesh to erase
            self.recipes = recipes        # {uid: recipe or None}
            self.select = select
            self._before_data = None
            self._mesh_before = None
            self._mesh_after = None
            self._idx = {}
            self._before_selection = None
            self.face_patches = []
            self.edge_patches = []
            self.guide_changes = None
            self.surface_fragments = {}
            self._snapshot_faces = {}
            self._transaction_before = None

        def _snapshot(self, mesh):
            state = mesh.capture_state()
            protected = self._snapshot_faces.get(id(mesh), set())
            if 'fattrs' in state:
                state['fattrs'] = {face: copy.deepcopy(attrs) if face in protected else attrs
                                   for face, attrs in state['fattrs'].items()}
            return state

        def _restore(self, mesh, state):
            # The native restore method shallow-copies attribute dictionaries.
            # Hand it fresh nested values so later in-place edits cannot mutate
            # this command's stored before/after snapshots.
            protected = self._snapshot_faces.get(id(mesh), set())
            if 'fattrs' in state:
                state = dict(state, fattrs={face: copy.deepcopy(attrs) if face in protected else attrs
                                           for face, attrs in state['fattrs'].items()})
            mesh.restore_state(state)

        def do(self, scene):
            # The host history only rolls back the active mesh on failure. An
            # adapter batch may also change other meshes, groups and recipes.
            # Capture all affected owners before any batch mutation.
            groups_before = list(scene.groups)
            selection_before = set(scene.selection)
            guides_before = list(scene.guides)
            had_data = DATA_KEY in scene.plugin_data
            data_before = dict(scene.plugin_data.get(DATA_KEY, {}))
            meshes = []
            for mesh, face in self.faces:
                self._snapshot_faces.setdefault(id(mesh), set()).add(face)
                if not any(mesh is old for old in meshes): meshes.append(mesh)
            for mesh, face, _parts in self.face_patches:
                self._snapshot_faces.setdefault(id(mesh), set()).add(face)
                if not any(mesh is old for old in meshes): meshes.append(mesh)
            for mesh, _edge, _points, _flags, _xf in self.edge_patches:
                if not any(mesh is old for old in meshes): meshes.append(mesh)
            states = [(mesh, self._snapshot(mesh)) for mesh in meshes]
            self._transaction_before = (groups_before, selection_before, guides_before,
                                        had_data, data_before, states)
            try:
                self._apply(scene)
            except Exception:
                self.rollback_failed_commit(scene)
                raise

        def rollback_failed_commit(self, scene):
            if self._transaction_before is None: return
            groups, selection, guides, had_data, data, states = self._transaction_before
            for mesh, state in states: self._restore(mesh, state)
            scene.groups[:] = groups
            scene.guides[:] = guides
            scene.selection.clear(); scene.selection.update(selection)
            if had_data: scene.plugin_data[DATA_KEY] = data
            else: scene.plugin_data.pop(DATA_KEY, None)

        def _apply(self, scene):
            if self._before_selection is None:
                self._before_selection = set(scene.selection)
                self._idx = {id(g): scene.groups.index(g) for g in self.removes
                             if g in scene.groups}
            data = scene.plugin_data.setdefault(DATA_KEY, {})
            if self._before_data is None:
                self._before_data = {u: data.get(u) for u in self.recipes}
            for u, r in self.recipes.items():
                if r is None:
                    data.pop(u, None)
                else:
                    data[u] = json.loads(json.dumps(r))
            for old, new in self.replaces:
                if old in scene.groups:
                    i = scene.groups.index(old)
                    self._idx[id(old)] = i
                    scene.groups[i] = new
                else:
                    scene.groups.append(new)
            for g in self.adds:
                if g not in scene.groups:
                    scene.groups.append(g)
            for g in self.removes:
                if g in scene.groups:
                    scene.groups.remove(g)
                    scene.selection.discard(g)
            if self.faces or self.face_patches or self.edge_patches:
                # (mesh, face): the opening may sit in the loose geometry or
                # inside a group being edited.
                if self._mesh_after is None:
                    self._mesh_before, self._mesh_after = [], []
                    meshes = []
                    for m, _f in self.faces:
                        if not any(m is x for x in meshes):
                            meshes.append(m)
                    for m, _f, _parts in self.face_patches:
                        if not any(m is x for x in meshes):
                            meshes.append(m)
                    for m, _edge, _points, _flags, _xf in self.edge_patches:
                        if not any(m is x for x in meshes):meshes.append(m)
                    for m in meshes:
                        protected=self._snapshot_faces.setdefault(id(m),set())
                        protected.update(f for mm,f in self.faces if mm is m)
                        protected.update(f for mm,f,_parts in self.face_patches if mm is m)
                        self._mesh_before.append((m, self._snapshot(m)))
                        from .native_edges import apply
                        for mm, edge, points, flags, xf in self.edge_patches:
                            if mm is m and points is not None:apply(m,edge,points,flags,xf)
                        for mm, f in self.faces:
                            if mm is m:
                                m.remove_face(f)
                        for mm, original, parts in self.face_patches:
                            if mm is m:
                                # Replacement fragments must not share nested
                                # native data with each other or the old face.
                                attrs = copy.deepcopy(original.attrs)
                                m.remove_face(original)
                                fragments=[]
                                for part in parts:
                                    outer,holes=part[:2]
                                    from .surface_paint import merge_attrs
                                    face_attrs = merge_attrs(attrs, part[3], part[4]) if len(part)>3 else copy.deepcopy(attrs)
                                    face=m.add_face(outer,holes or None);face.attrs.update(face_attrs)
                                    fragments.append(face)
                                    protected.add(face)
                                    if len(part)>2:
                                        from .surface_edges import apply as apply_properties
                                        apply_properties(face,m,part[2])
                                self.surface_fragments[str(id(original))]=(m,fragments)
                        for mm, edge, points, flags, xf in self.edge_patches:
                            if mm is m and points is None:apply(m,edge,None,flags,xf)
                        self._mesh_after.append((m, self._snapshot(m)))
                else:
                    for m, st in self._mesh_after:
                        self._restore(m, st)
            if self.select:
                scene.selection.clear()
                scene.selection.update(g for g in self.select if g in scene.groups)
            if self.guide_changes is not None:
                before,after=self.guide_changes
                for guide in before:
                    if guide in scene.guides:scene.guides.remove(guide)
                for guide in after:
                    if guide not in scene.guides:scene.guides.append(guide)
            scene.version += 1

        def undo(self, scene):
            if self.guide_changes is not None:
                before,after=self.guide_changes
                for guide in after:
                    if guide in scene.guides:scene.guides.remove(guide)
                for guide in before:
                    if guide not in scene.guides:scene.guides.append(guide)
            data = scene.plugin_data.setdefault(DATA_KEY, {})
            for u, r in (self._before_data or {}).items():
                if r is None:
                    data.pop(u, None)
                else:
                    data[u] = r
            for g in sorted(self.removes, key=lambda g: self._idx.get(id(g), len(scene.groups))):
                if g not in scene.groups:
                    scene.groups.insert(self._idx.get(id(g), len(scene.groups)), g)
            for g in self.adds:
                if g in scene.groups:
                    scene.groups.remove(g)
            for old, new in self.replaces:
                if new in scene.groups:
                    scene.groups[scene.groups.index(new)] = old
            for m, st in (self._mesh_before or []):
                self._restore(m, st)
            scene.selection.clear()
            scene.selection.update(self._before_selection or ())
            scene.version += 1

    return WindowCrafterEdit


# ---------------------------------------------------------------------------
# The host process
# ---------------------------------------------------------------------------

class RubyHost(QObject):
    def __init__(self, app, registry=None) -> None:
        super().__init__(app.window)
        self.app = app
        from .registry import Registry
        from .diagnostics import Diagnostics
        self.registry = registry if registry is not None else Registry()
        self.diagnostics = Diagnostics(self.registry.root / "diagnostics")
        self.proc: QProcess | None = None
        self._buf = bytearray()
        self._stdout_scan = 0
        self._busy = False
        self._inbox: list[dict] = []
        self.dialogs: dict[int, object] = {}
        self._console_dialog = None
        self._console_output = None
        self._console_buffer = ''
        self.toolbars: dict[str, QToolBar] = {}
        self.commands: list[dict] = []
        self.rid_of_uid: dict[str, int] = {}
        self.group_of_rid: dict[int, object] = {}
        self._batch: list[dict] = []
        self._face_tokens: dict[str, object] = {}
        self._last_sel_key = None
        self._placing = None
        self._context_menu = None
        self._extension_tool = None
        self._extension_tool_id = None
        self._cancelled_tool_ids = set()
        self._cancel_signal_path = None
        app.window.destroyed.connect(self._clear_cancel_signal)
        self._overlay_primitives: list[dict] = []
        self._pick_snapshots_sent: set[str] = set()
        self._surface_context_epoch = 0
        self.ready = False
        self._dialog_host = None
        self._sent_units = None
        self._sent_rendering_options = None
        self._sent_camera = None
        self._sync_depth = 0
        self._batch_failed = False
        self._document_reset_waiting = False
        self._prepared_groups = {}
        self._data_key = DATA_KEY
        self._logf = open(_log_dir() / "host.log", "a", encoding="utf-8")
        from .activity import Activity
        self.activity = Activity(self)
        from .async_geometry import PreparationQueue
        self._preparation = PreparationQueue(self)
        from .outgoing import OutgoingQueue
        self._outgoing = OutgoingQueue(self)

    # ---- process -----------------------------------------------------------
    def start(self) -> bool:
        ruby = self.registry.settings.get("ruby") or find_ruby()
        if not ruby:
            QMessageBox.warning(self.app.window, "SketchUp Adapter",
                                "SketchUp Adapter needs Ruby (2.7 or newer).\n"
                                "Install it from https://rubyinstaller.org and restart IngeTrazo.")
            return False
        config = self.registry.runtime_config()
        self._loading_count = 0
        self._loading_total = len(config['plugins'])
        if config['plugins']:
            self.activity.update('loading')
        missing = [str(Path(plugin["root"]) / name) for plugin in config["plugins"]
                   for name in plugin["loaders"] if not (Path(plugin["root"]) / name).is_file()]
        if missing:
            self.activity.update('failed', name='Extension files are missing')
            QMessageBox.warning(self.app.window, "SketchUp Adapter",
                                "These extension files are missing:\n" +
                                "\n".join(missing))
            return False
        self.proc = QProcess(self)
        self.proc.setProgram(ruby)
        from .registry import atomic_json
        config_path = self.registry.root / "runtime.json"
        atomic_json(config_path, config)
        self.proc.setArguments([str(HOST_RB), str(self.registry.root), "@" + str(config_path)])
        self.proc.setWorkingDirectory(str(PKG / "ruby_host"))
        env = self.proc.processEnvironment()
        from PySide6.QtCore import QProcessEnvironment
        env = QProcessEnvironment.systemEnvironment()
        env.insert("RUBYOPT", "-EUTF-8:UTF-8")
        env.insert("INGETRAZO_DECIMAL_SEPARATOR", str(QLocale.system().decimalPoint()))
        fd, path = tempfile.mkstemp(prefix='ingetrazo-sketchup-cancel-')
        os.close(fd)
        self._cancel_signal_path = Path(path)
        env.insert('INGETRAZO_SKETCHUP_CANCEL_FILE', path)
        self.proc.setProcessEnvironment(env)
        self.proc.readyReadStandardOutput.connect(self._on_stdout)
        self.proc.readyReadStandardError.connect(self._on_stderr)
        self.proc.finished.connect(self._on_finished)
        self.proc.start()
        started=self.proc.waitForStarted(5000)
        if not started:
            self._clear_cancel_signal()
            self.activity.update('failed', name='Ruby could not start')
        return started

    def _clear_cancel_signal(self,*_):
        path,self._cancel_signal_path=self._cancel_signal_path,None
        if path is not None:
            try:path.unlink(missing_ok=True)
            except OSError:log.warning('Could not remove adapter cancellation signal',exc_info=True)

    def send(self, msg: dict) -> None:
        # A command queued behind document_reset would run against a different
        # Ruby model than the one the user acted on. Reject it until the reset
        # is acknowledged. Replies, reset/quit and dialog cleanup remain live.
        if self._document_reset_waiting and msg.get('op') in (
                'command', 'callback', 'menu_click', 'tool_event', 'placed',
                'place_cancelled', 'selection', 'model_state', 'context_menu',
                'units', 'rendering_options'):
            if msg.get('op') in ('command', 'callback', 'menu_click'):
                self._notify_reset_busy()
            return
        self._outgoing.send(msg)

    def _notify_reset_busy(self) -> None:
        # Called only on an actual refused user action, never by polling.
        from time import monotonic
        now = monotonic()
        if now - getattr(self, '_last_reset_refusal', 0) < 1.0:
            return
        self._last_reset_refusal = now
        flash = getattr(self.app.viewport, 'flash_status', None)
        if callable(flash):
            flash('The extension is recovering; please retry when it is ready.', 4000)

    def _write_message(self, data: bytes) -> None:
        if self.proc is None or self.proc.state() != QProcess.Running:
            return
        self.proc.write(data)

    def _on_stderr(self) -> None:
        text = bytes(self.proc.readAllStandardError()).decode("utf-8", "replace")
        self._logf.write(text)
        self._logf.flush()
        self._console_append(text)
        for line in text.splitlines():
            if line.strip():
                log.info("ruby: %s", line)

    def _on_finished(self, code, _status) -> None:
        log.warning("SketchUp adapter host exited (%s)", code)
        self.ready = False
        self.proc = None
        if self._extension_tool is not None:
            self._extension_tool.on_cancel(self.app.viewport)
        self._clear_cancel_signal()
        self.activity.update('failed', name='Extension host exited')
        if self._dialog_host is not None:
            self._dialog_host.send({"op": "quit"})
            self._dialog_host = None

    def _on_stdout(self) -> None:
        self._buf.extend(bytes(self.proc.readAllStandardOutput()))
        while True:
            end = self._buf.find(b'\n',self._stdout_scan)
            if end<0:
                self._stdout_scan=len(self._buf)
                break
            line=bytes(self._buf[:end]);del self._buf[:end+1];self._stdout_scan=0
            if not line.strip():
                continue
            try:
                self._preparation.receive(line)
            except ValueError:
                log.warning("SketchUp extensions: bad host line %r", line[:200])
        self._on_stdout_drain()

    def _on_stdout_drain(self) -> None:
        if self._busy or self._preparation.preparing:
            return
        self._busy = True
        try:
            while self._inbox:
                msg = self._inbox.pop(0)
                try:
                    if self._preparation.prepare(msg):
                        break
                    self.handle(msg)
                except Exception:                  # noqa: BLE001
                    log.exception("SketchUp extensions: handling %s failed", msg.get("op"))
        finally:
            self._busy = False

    # ---- messages ----------------------------------------------------------
    def _console_append(self, text):
        self._console_buffer=(self._console_buffer + str(text))[-200000:]
        if self._console_output is not None:
            from PySide6.QtGui import QTextCursor
            self._console_output.setPlainText(self._console_buffer)
            self._console_output.moveCursor(QTextCursor.MoveOperation.End)

    def _console_action(self, action):
        if action == 'show' and self._console_dialog is None:
            from PySide6.QtWidgets import QDialog,QPlainTextEdit,QPushButton,QVBoxLayout
            dialog=QDialog(self.app.window);dialog.setWindowTitle('Extension output');dialog.resize(700,400)
            layout=QVBoxLayout(dialog);output=QPlainTextEdit(dialog);output.setReadOnly(True)
            output.setPlainText(self._console_buffer);layout.addWidget(output)
            clear=QPushButton('Clear',dialog);clear.clicked.connect(lambda: self._console_action('clear'));layout.addWidget(clear)
            self._console_dialog,self._console_output=dialog,output
        if action=='show':self._console_dialog.show();self._console_dialog.raise_()
        elif action=='hide' and self._console_dialog is not None:self._console_dialog.hide()
        elif action=='clear':
            self._console_buffer=''
            if self._console_output is not None:self._console_output.clear()

    def handle(self, msg: dict) -> None:
        self.diagnostics.record(msg)
        op = msg.get("op")
        if op == 'console_action':self._console_action(msg.get('action'));return
        if op == 'console_text':self._console_append(msg.get('text',''));return
        if op == 'document_reset_done':
            self._document_reset_waiting = False
            self._sent_rendering_options = None
            self._sent_camera = None
            self._sync_depth = 0
            self.group_of_rid.clear()
            self.rid_of_uid.clear()
            self.sync_selection(force=True)
            return
        if self._document_reset_waiting and op in ('progress', 'activity_done', 'status', 'tooltip',
                                                   'vcb', 'tool_failed', 'tool_reset', 'active_layer',
                                                   'focus_model', 'open_url'):
            return
        if op == 'progress':
            if msg.get('tool') in self._cancelled_tool_ids:return
            self.activity.update(msg.get('phase', 'generating'), msg.get('done'), msg.get('total'), msg.get('name'))
            return
        if op == 'tool_cancelled':
            self.activity.acknowledge_cancel(msg.get('tool'))
            return
        if op == 'tool_cancel_unconfirmed':
            self.activity.acknowledge_cancel(msg.get('tool'), cleaned=False)
            return
        if op == 'extension_abort':
            # The extension stopped its callback. Discard the Ruby-side model
            # and any pending work; previously committed native edits remain.
            if self._document_reset_waiting:
                return
            self._preparation.document_changed(force=True)
            self.activity.update('failed', name='Extension stopped; check the model before retrying')
            log.error('SketchUp extension stopped its %s callback (exit status %s)',
                      msg.get('where'), msg.get('status'))
            flash = getattr(self.app.viewport, 'flash_status', None)
            if callable(flash):
                flash('Extension stopped. Check the model and retry.', 8000)
            return
        if op == 'activity_done':
            self.activity.finish()
            return
        if self._document_reset_waiting and op == 'call':
            # A synchronous request from the old Ruby document must receive
            # a reply so it can return to its event loop and process reset.
            self.send({'op':'reply', 'id':msg.get('id'), 'value':None})
            return
        if self._document_reset_waiting and op in ('upsert','removed','face_erased','surface_patch','edge_patch','guide_patch','place','tool_select','overlay','bind','selection_changed','geometry_batch_begin','geometry_batch_end'):
            return
        if op == 'geometry_batch_begin':
            if not self._sync_depth:self._batch_failed=False
            self._sync_depth += 1
            return
        if op == 'geometry_batch_end':
            self._sync_depth = max(0,self._sync_depth-1)
            if not self._sync_depth:
                if self._batch_failed:self._batch.clear();self._prepared_groups.clear()
                else:self._flush_batch()
                self.activity.finish()
            return
        if op == "ready":
            self.ready = True
            self.activity.clear()
            self._sent_units = None
            self._sent_rendering_options = None
            self._sent_camera = None
            self.sync_units()
            self.commands = msg.get("commands", [])
            self.version = msg.get("version", "")
            self.build = msg.get("build", 0)
            self._make_menu(msg.get("menu", {}))
            self._restore_toolbar_layout()
            self.sync_selection(force=True)
        elif op == "toolbar":
            self._make_toolbar(msg)
        elif op=='toolbar_visibility':
            toolbar=self.toolbars.get(msg.get('name'))
            if toolbar is not None:toolbar.setVisible(bool(msg.get('visible')))
        elif op == "fatal":
            self.activity.update('failed')
            QMessageBox.critical(self.app.window, "SketchUp Adapter",
                                 "The Ruby extension host could not start:\n" + msg.get("message", "") +
                                 "\n\n" + "\n".join(msg.get("trace", [])))
        elif op == "extension_error":
            self.activity.update('failed', name=msg.get('loader'))
            log.error("Bogdan extension %s failed to load: %s\n%s",
                      msg.get("loader", ""), msg.get("message", ""),
                      "\n".join(msg.get("trace", [])))
        elif op == 'extension_loading':
            self._loading_count += 1
            self.activity.update('loading', name=f"{msg.get('name', 'Extension')} ({self._loading_count} of {self._loading_total})")
        elif op=='active_layer':
            name=msg.get('name')
            if name in ('Layer0','Untagged'):name=None
            from core.layers import Layer
            scene=self.app.scene
            if name and not any(layer.name==name for layer in scene.layers):scene.layers.append(Layer(name))
            if scene.active_layer!=name:
                scene.active_layer=name;scene.version+=1
                self.app.viewport.update()
        elif op == "error":
            log.error("SketchUp extensions [%s] %s\n%s", msg.get("where"), msg.get("message"),
                      "\n".join(msg.get("trace", [])))
            if msg.get('tool') not in self._cancelled_tool_ids:
                self.activity.update('failed')
        elif op == "call":
            self.send({"op": "reply", "id": msg["id"], "value": self._call(msg)})
        elif op.startswith("dialog_") or op == "exec_js":
            self.dialog_host().send(msg)
        elif op == "status":
            if msg.get('tool') in self._cancelled_tool_ids:
                return
            vp = self.app.viewport
            if hasattr(vp, "flash_status") and msg.get("text"):
                vp.flash_status(msg["text"], 4000)
            elif not msg.get('text'):
                self.app.window.statusBar().clearMessage()
            self.activity.tool_state['hint'] = msg.get('text', '')
            self.activity.tool()
        elif op == "vcb":
            if self._extension_tool is not None and msg.get("slot") == 1:
                self._extension_tool.vcb_label = msg.get("text")
        elif op == "focus_model":
            self.app.viewport.setFocus()
            self.app.window.activateWindow()
        elif op == "open_url":
            from PySide6.QtGui import QDesktopServices
            from PySide6.QtCore import QUrl
            QDesktopServices.openUrl(QUrl(msg["url"]))
        elif op == "bind":
            if msg.get("uid"):
                self.rid_of_uid[msg["uid"]] = msg["rid"]
                g = self._group_by_uid(msg["uid"])
                if g is not None:
                    self.group_of_rid[msg["rid"]] = g
        elif op in ("upsert", "removed", "face_erased", "surface_patch", "edge_patch", "guide_patch"):
            self._batch.append(msg)
            QTimer.singleShot(0, self._flush_batch)
        elif op == 'selection_changed':
            selected = set()
            for item in msg.get('items', []):
                kind = item.get('kind')
                if kind == 'group':
                    entity = self._group_by_uid(item.get('uid')) if item.get('uid') else self.group_of_rid.get(item.get('rid'))
                else:
                    fragments=getattr(self,'_surface_fragments',{}).get(item.get('token')) if kind=='face' else None
                    if fragments:
                        mesh,faces=fragments
                        selected.update(face for face in faces if face in mesh.faces)
                        continue
                    targets = getattr(self, '_surface_targets' if kind == 'face' else '_edge_targets', {})
                    target = targets.get(item.get('token'))
                    entity = target[1] if target else None
                if entity is not None:
                    selected.add(entity)
            scene = self.app.scene
            scene.selection.clear()
            scene.selection.update(selected)
            self._last_sel_key = (frozenset(id(e) for e in selected), scene.version)
            self.app.viewport.update()
        elif op == "place":
            self._start_placement(msg)
        elif op == "tool_select":
            self._select_extension_tool(msg)
        elif op == "tool_reset":
            self.send({"op": "tool_event", "id": msg.get("id"), "event": "reset"})
        elif op == "overlay":
            if msg.get('tool') != self._extension_tool_id:
                return
            if msg.get('tool_state'):
                self.activity.tool(msg['tool_state'])
            self.activity.tool_state['preview_error'] = bool(msg.get('preview_error'))
            self.activity.tool()
            if msg.get("templates") is not None:
                self._overlay_templates = msg["templates"]
            inference = msg.get("inference")
            if inference and inference.get("tool") == self._extension_tool_id:
                tool = self._extension_tool
                if tool is not None:
                    tool.sync_path_inference(inference.get("state", {}))
            interaction = msg.get("interaction")
            if interaction and interaction.get("tool") == self._extension_tool_id and self._extension_tool is not None:
                self._extension_tool.sync_interaction(interaction.get("state", {}))
            self._overlay_primitives = msg.get("items", [])
            self.app.viewport.update()
        elif op == "invalidate":
            self.app.viewport.update()
        elif op == "tooltip":
            if self._extension_tool is not None:
                self.app.viewport.setToolTip(msg.get("text", ""))
        elif op == 'tool_failed':
            if msg.get('id') == self._extension_tool_id:
                self.activity.tool_state['failed'] = True
                self.activity.tool()
        elif op == "cursor_new":
            from PySide6.QtGui import QCursor,QPixmap
            pixmap=QPixmap(msg['path'])
            if not pixmap.isNull():
                self.__dict__.setdefault('_cursors',{})[int(msg['id'])]=QCursor(pixmap,*msg.get('hotspot',[0,0]))
        elif op == "cursor_set":
            tool=self._extension_tool
            if tool is not None and self.app.viewport.active_tool is tool:
                tool.qt_cursor=getattr(self,'_cursors',{}).get(int(msg['id']),Qt.ArrowCursor)
                self.app.viewport._apply_tool_cursor()
        elif op == "context_menu":
            self._context_menu = msg.get("menu")

    def _select_extension_tool(self, msg: dict) -> None:
        """Mirror SketchUp's Model#select_tool in the IngeTrazo viewport."""
        from tools.base import Tool
        from .interaction import InteractionTool
        tool_id = msg.get("id")
        if tool_id in self._cancelled_tool_ids:
            return
        if tool_id is None:
            self._extension_tool = None
            self._extension_tool_id = None
            self._overlay_primitives = []
            self.app.viewport.setToolTip('')
            self.activity.tool()
            activate = getattr(self.app.window, "_activate_tool", None)
            if callable(activate):
                activate("select")
            else:
                self.app.viewport.set_active_tool(None)
            self.app.viewport.update()
            return
        if tool_id == self._extension_tool_id and self._extension_tool is not None:
            self.send({"op": "tool_event", "id": tool_id, "event": "reset"})
            return

        class RubyExtensionTool(InteractionTool, Tool):
            name = msg.get("title") or msg.get("name") or "Extension Tool"
            icon = None
            uses_snap = True

            def __init__(self, host):
                self.host = host
                self.tool_id = tool_id
                self.claims_ruby_keys = bool(msg.get("claims_keys"))
                self._cancel_sent = False
                self._last_event = None
                self.init_path_inference(msg.get("name") == "BogdanWallCrafter::DrawingTool")

            def on_activate(self, viewport):
                self.host._extension_tool = self
                self.host._extension_tool_id = self.tool_id
                self.host.send({"op": "tool_event", "id": self.tool_id,
                                "event": "activate"})

            def on_deactivate(self, viewport):
                self.on_generic_deactivate(viewport)
                self.path_key(viewport, Qt.Key_Shift, False)
                if not self._cancel_sent:
                    self.host.send({"op": "tool_event", "id": self.tool_id,
                                    "event": "deactivate", "input": self._last_event})
                if self.host._extension_tool is self:
                    self.host._extension_tool = None
                    self.host._extension_tool_id = None
                self.host._overlay_primitives = []
                self.host.activity.tool()
                viewport.setToolTip('')
                self.host.app.window.statusBar().clearMessage()

            def _send(self, event, ctx=None, key=None, modifiers=None):
                # A native Undo/Redo can precede the selection polling timer.
                # Put history and selection ahead of the next tool event in
                # the FIFO, so cached extension rigs see the restored model.
                if self.host.sync_selection() is False:
                    if self.host._document_reset_waiting and event not in ('move', 'key_up'):
                        self.host._notify_reset_busy()
                    elif event not in ('move', 'key_up'):
                        self.host._notify_invalid_selection()
                    return
                data = self.host._tool_input(self, ctx, event)
                if data.get('_adapter_face_context_invalid'):
                    return
                if modifiers is not None:
                    data = dict(data)
                    flags = int(data.get("flags", 0)) & ~(4 | 8 | 32)
                    for modifier, mask in ((Qt.ShiftModifier, 4), (Qt.ControlModifier, 8), (Qt.AltModifier, 32)):
                        if modifiers & modifier:
                            flags |= mask
                    data["flags"] = flags
                self._last_event = data
                if data.get('surface_context'):
                    self.__dict__.setdefault('_surface_tokens', set()).update(
                        row['token'] for row in data['surface_context'])
                if data.get('edge_context'):
                    self.__dict__.setdefault('_edge_tokens',set()).update(row['token'] for row in data['edge_context'] if row['kind']=='edge')
                self.host.send({"op": "tool_event", "id": self.tool_id,
                                "event": event, "input": data, "key": key})

            def on_hover(self, ctx):
                if self._path_inference_enabled:
                    self.hover_point = ctx.world
                self._send("move", ctx)

            def on_click(self, ctx):
                self._send("click", ctx)

            def on_double_click(self, ctx):
                self._send("double_click", ctx)

            def on_release(self, viewport):
                self._send("release")

            def claims_key(self, key, modifiers):
                # Let IngeTrazo retain Escape, delete, Enter, and modifier
                # handling; the extension owns ordinary keys while active.
                from PySide6.QtCore import Qt
                if modifiers & (Qt.ControlModifier | Qt.MetaModifier):
                    return False
                if key in (Qt.Key_Return, Qt.Key_Enter):
                    return self.claims_ruby_keys and not getattr(self.host.app.viewport, "_value_buffer", "")
                if (Qt.Key_0 <= key <= Qt.Key_9 or
                    key in (Qt.Key_Period, Qt.Key_Comma, Qt.Key_Minus, Qt.Key_Plus, Qt.Key_Semicolon)):
                    return False
                return self.claims_ruby_keys and int(key) not in {
                    int(Qt.Key_Escape), int(Qt.Key_Delete), int(Qt.Key_Return),
                    int(Qt.Key_Enter), int(Qt.Key_Shift), int(Qt.Key_Control),
                    int(Qt.Key_Alt), int(Qt.Key_Meta),
                }

            def on_key(self, viewport, key, modifiers):
                if key == Qt.Key_Escape:
                    self.on_cancel(viewport)
                    return True
                self.path_key(viewport, key, True)
                self._send("key", None, self.host._windows_key(int(key)), modifiers)
                return self.claims_key(key, modifiers)

            def on_key_release(self, viewport, key, modifiers=None):
                from PySide6.QtWidgets import QApplication
                if modifiers is None:
                    modifiers = QApplication.keyboardModifiers()
                self.path_key(viewport, key, False)
                self._send("key_up", None, self.host._windows_key(int(key)), modifiers)
                return self.claims_key(key, modifiers)

            def on_focus_out(self, viewport):
                # A release can be delivered to another window after Alt-Tab.
                # Generic Ruby tools need the same unlock as Fence tools.
                self.on_key_release(viewport, Qt.Key_Shift, Qt.NoModifier)

            def on_value(self, viewport, value):
                if self.host.sync_selection() is False:
                    if self.host._document_reset_waiting: self.host._notify_reset_busy()
                    else: self.host._notify_invalid_selection()
                    return True
                text = getattr(viewport, "_value_buffer", "")
                if not text:
                    values = value if isinstance(value, (tuple, list)) else [value]
                    suffix = "" if self.value_is_unitless() else "m"
                    text = ";".join(f"{float(v):.12g}{suffix}" for v in values)
                self.host.send({"op":"tool_event", "id":self.tool_id,
                                "event":"value", "text":text, "input":self._last_event})
                return True

            def value_is_unitless(self):
                label = str(getattr(self, "vcb_label", "")).lower()
                return any(word in label for word in ("rotation", "angle", "degree", "count", "factor"))

            def on_cancel(self, viewport):
                if not self._cancel_sent:
                    self._cancel_sent = True
                    self.host._cancelled_tool_ids.add(self.tool_id)
                    # The Ruby worker may be inside a long synchronous callback
                    # and cannot consume its normal event queue yet.
                    path=self.host._cancel_signal_path
                    if path is not None:
                        try:path.write_text(str(self.tool_id),encoding='ascii')
                        except OSError:log.warning('Could not signal extension cancellation',exc_info=True)
                    self.host.send({"op": "tool_event", "id": self.tool_id,
                                    "event": "cancel", "input": self._last_event})
                    self.host.activity.begin_cancel(self.tool_id, self.host._preparation.preparing)
                # Clear locally before waiting for a vendor callback: even a
                # broken onCancel/draw must not trap the native UI in this tool.
                self.host._overlay_primitives = []
                self.host._extension_tool = None
                self.host._extension_tool_id = None
                self.host.activity.tool()
                if self.host._preparation.preparing:
                    state=self.host.activity.state or {}
                    self.host.activity.update('building',state.get('done'),state.get('total'),
                        'Finishing committed geometry; waiting for tool cancellation')
                viewport.setToolTip('')
                viewport._set_value_buffer('')
                viewport.release_constraints()
                win = self.host.app.window
                activate = getattr(win, "_activate_tool", None)
                if callable(activate):
                    if getattr(viewport, 'active_tool', None) is self:
                        activate('select')
                elif getattr(viewport, 'active_tool', None) is self:
                    viewport.set_active_tool(None)
                viewport.update()

            def draw_overlay(self, viewport, painter):
                self.host._paint_extension_overlay(viewport, painter)

        self._extension_tool = RubyExtensionTool(self)
        self._extension_tool_id = tool_id
        self.app.viewport.set_active_tool(self._extension_tool)
        self.activity.tool({'class': msg.get('name'), 'title': msg.get('title')})
        self.app.viewport.setFocus()

    def _tool_input(self, tool, ctx, event: str) -> dict:
        from PySide6.QtCore import Qt
        from PySide6.QtWidgets import QApplication
        vp = self.app.viewport
        if ctx is not None:
            sx, sy = float(ctx.screen.x()), float(ctx.screen.y())
            world = ctx.world
            modifiers = ctx.modifiers
            snap = getattr(getattr(ctx, "snap", None), "kind", "none")
        else:
            sx, sy = 0.0, 0.0
            world = None
            modifiers = QApplication.keyboardModifiers()
            snap = "none"
        if ctx is None and tool._last_event:
            return tool._last_event
        point = [float(c) * 39.37007874015748 for c in world.toTuple()] if world is not None else [0, 0, 0]
        flags = 0
        if modifiers & Qt.ShiftModifier:
            flags |= 4
        if modifiers & Qt.ControlModifier:
            flags |= 8
        if modifiers & Qt.AltModifier:
            flags |= 32
        buttons = QApplication.mouseButtons()
        if buttons & Qt.LeftButton or event == "click":
            flags |= 1
        if buttons & Qt.RightButton:
            flags |= 2
        hit = {"point": point, "screen": [sx, sy], "flags": flags,
               "modifiers": int(getattr(modifiers, "value", modifiers)), "snap": snap,
               "valid": world is not None}
        try:
            mvp = vp.camera.projection_matrix() * vp.camera.view_matrix()
            hit["mvp"] = [float(v) for v in mvp.data()]
            hit["viewport_size"] = [int(vp.width()), int(vp.height())]
        except Exception:  # noqa: BLE001 — screen projection is optional
            pass
        try:
            origin, direction = vp._pixel_to_ray(sx, sy)
            if origin is not None and direction is not None:
                hit["ray"] = [[float(c) * 39.37007874015748 for c in origin.toTuple()],
                              [float(c) for c in direction.toTuple()]]
        except Exception:  # noqa: BLE001 — a cursor event still has its point
            pass
        try:
            face, placement = vp.pick_face_placement(sx, sy)
            if face is not None:
                mesh, owner_xf = self._entity_owner(face)
                if mesh is not None:
                    token = str(id(face))
                    targets = self.__dict__.setdefault('_surface_targets', {})
                    targets[token] = (mesh, face, QMatrix4x4(owner_xf) if owner_xf is not None else None)
                    hit['face_token'] = token
                    if getattr(tool, '_surface_context_epoch', None) != self._surface_context_epoch:
                        tool._surface_tokens = set()
                        tool._surface_context_epoch = self._surface_context_epoch
                    if token not in tool._surface_tokens:
                        hit['surface_context'] = self.selection_items(entities=[face], reset_tokens=False)
                xf = getattr(placement, "xform", None)
                verts = []
                for p in face.vertices:
                    wp = xf.map(p) if xf is not None else p
                    verts.append([float(c) * 39.37007874015748 for c in wp.toTuple()])
                hit["face"] = verts
                hit["holes"] = []
                for ring in getattr(face, "holes", []):
                    hit["holes"].append([
                        [float(c) * 39.37007874015748 for c in
                         (xf.map(p) if xf is not None else p).toTuple()]
                        for p in ring
                    ])
                if len(verts) >= 3:
                    # Whole-loop normal tolerates collinear boundary vertices.
                    origin_point = QVector3D(*verts[0])
                    normal = QVector3D()
                    for i in range(1, len(verts)-1):
                        normal += QVector3D.crossProduct(QVector3D(*verts[i])-origin_point,
                                                         QVector3D(*verts[i+1])-origin_point)
                    normal.normalize()
                    hit["normal"] = [float(v) for v in normal.toTuple()]
                    # The native working plane can be the ground even when
                    # the cursor is over a wall or raised face. Use that face's
                    # actual ray hit, retaining explicit point/edge snaps.
                    on_face = world is not None and abs(QVector3D.dotProduct(QVector3D(*hit['point'])-origin_point,normal))<0.001
                    if on_face:
                        projected=mvp.map(world)
                        on_face=((projected.x()+1)*vp.width()/2-sx)**2+((1-projected.y())*vp.height()/2-sy)**2<0.75**2
                    if not on_face and snap in ('none', 'on_face', 'face', 'plane') and hit.get('ray'):
                        ro, rd = [QVector3D(*p) for p in hit['ray']]
                        denominator = QVector3D.dotProduct(rd, normal)
                        if abs(denominator) > 1e-8:
                            distance = QVector3D.dotProduct(origin_point-ro, normal)/denominator
                            if distance >= 0:
                                hit['point'] = list((ro+rd*distance).toTuple())
                                hit['snap'] = 'on_face'
                                hit['dof'] = 2
                # Cursor face points above are already in world coordinates.
                # A nonidentity placement transform would apply it twice.
                hit["xform"] = _matrix_out(QMatrix4x4())
                hit["valid"] = True
                uid = getattr(placement, "uid", None)
                if uid:
                    hit["pick_uid"] = uid
                    if uid not in self._pick_snapshots_sent and uid not in self.rid_of_uid:
                        # Keep a read-only reference; the ordered outgoing
                        # worker builds and encodes the expensive snapshot.
                        hit['_pick_group_reference']=placement
                        self._pick_snapshots_sent.add(uid)
        except (ValueError, TypeError) as error:
            # Do not expose a partial face context if its texture coordinates
            # could not be mapped safely. Point-only tools may still operate.
            token = hit.pop('face_token', None)
            hit.pop('surface_context', None)
            hit['_adapter_face_context_invalid'] = True
            if token is not None:
                self._face_tokens.clear()
                self.__dict__.get('_surface_targets', {}).clear()
                self.__dict__.get('_edge_targets', {}).clear()
                self._surface_context_epoch += 1
                tool._surface_tokens = set()
                if getattr(self, '_last_selection_valid', True): self._last_sel_key = None
            if event == 'click':
                vp.setToolTip('Cannot inspect selected geometry: '+str(error))
                flash=getattr(vp, 'flash_status', None)
                if callable(flash): flash('Cannot inspect the selected geometry safely.', 8000)
        except Exception:  # noqa: BLE001 — fallback to point-only input
            log.debug("Bogdan extension pick snapshot failed", exc_info=True)
        from .interaction import enrich_input
        try:
            return enrich_input(self, hit, getattr(ctx, "snap", None) if ctx is not None else None, tool)
        except (ValueError, TypeError) as error:
            hit.pop('face_token', None); hit.pop('surface_context', None); hit.pop('edge_context', None)
            hit['_adapter_face_context_invalid'] = True
            self._face_tokens.clear(); self.__dict__.get('_surface_targets', {}).clear(); self.__dict__.get('_edge_targets', {}).clear()
            self._surface_context_epoch += 1; tool._surface_tokens = set(); tool._edge_tokens = set()
            if getattr(self, '_last_selection_valid', True): self._last_sel_key = None
            if event == 'click':
                vp.setToolTip('Cannot inspect selected geometry: '+str(error))
                self._notify_invalid_selection()
            return hit

    @staticmethod
    def _windows_key(key: int) -> int:
        """Translate Qt key enums to SketchUp's virtual-key values."""
        special = {
            0x01000020: 16, 0x01000021: 17, 0x01000022: 91,
            0x01000023: 18, 0x01000024: 20,
            0x01000000: 27, 0x01000001: 9, 0x01000003: 8,
            0x01000004: 13, 0x01000005: 13, 0x01000007: 46,
            0x01000012: 37, 0x01000013: 38, 0x01000014: 39,
            0x01000015: 40, 0x01000016: 33, 0x01000017: 34,
            0x01000010: 36, 0x01000011: 35, 0x20: 32,
        }
        if key in special:
            return special[key]
        if 0x01000030 <= key <= 0x01000043:  # F1–F20
            return 0x70 + key - 0x01000030
        return key & 0xFFFF

    def _group_snapshot(self, group, depth=0):
        """A one-time cursor proxy so SketchUp PickHelper can find a saved item."""
        from .section import SOURCE_KEY, source_snapshot
        source = (getattr(group, "ext", None) or {}).get(SOURCE_KEY)
        if source:
            return source_snapshot(group, source)
        if depth >= 64:
            raise ValueError("The selected model exceeds the supported nesting depth.")
        faces = []
        for face in getattr(getattr(group, "mesh", None), "faces", []):
            faces.append([[list(p.toTuple()) for p in face.vertices],
                          [[list(p.toTuple()) for p in ring] for ring in face.holes],
                          dict(face.attrs)])
        edges = [[list(edge.a.toTuple()), list(edge.b.toTuple())]
                 for edge in getattr(getattr(group, "mesh", None), "edges", [])
                 if not edge.faces and not edge.hidden]
        soft_edges = [[list(edge.a.toTuple()), list(edge.b.toTuple())]
                      for edge in getattr(getattr(group, "mesh", None), "edges", [])
                      if edge.faces and (edge.soft or edge.hidden)]
        children = []
        for child in getattr(group, "children", []):
            record = self._group_snapshot(child, depth + 1)
            if record:
                record["xform"] = (_matrix_out(child.xform)
                                   if child.xform is not None else None)
                children.append(record)
        uid = getattr(group, "uid", None)
        result = {"uid": uid, "name": group.name or "",
                  "definition_key": str(id(getattr(group, 'mesh', None))),
                  "component": bool(group.is_component()) if hasattr(group, 'is_component') else bool(getattr(group, "component", False)),
                  "xform": (_matrix_out(group.xform) if group.xform is not None else None),
                  "hidden": bool(getattr(group, "hidden", False)), 'layer':getattr(group,'layer',None), "faces": faces,
                  "edges": edges, "soft_edges": soft_edges, "children": children}
        record = (self.app.scene.plugin_data.get(DATA_KEY, {}).get(uid)
                  if uid is not None else None)
        record = record or (getattr(group, "ext", None) or {}).get("bogdan_bridge")
        if record:
            result["attrs"] = record.get("attrs", {})
            result["def_attrs"] = record.get("def_attrs", {})
        return result

    def _paint_extension_overlay(self, viewport, painter) -> None:
        from .overlay import paint
        try:
            paint(self, viewport, painter)
        except Exception:  # overlays must not break native painting
            log.debug("Bogdan extension overlay could not be drawn", exc_info=True)

    def _group_by_uid(self, uid):
        from core.purge import iter_groups
        for g in iter_groups(self.app.scene.groups):
            if getattr(g, "uid", None) == uid:
                return g
        return None

    # ---- synchronous calls from Ruby ------------------------------------------
    def _make_menu(self, tree):
        if getattr(self, "_native_menu", None) is not None:
            return
        add_menu = getattr(self.app, "add_menu", None)
        menu = add_menu("SketchUp Adapter") if callable(add_menu) else None
        if menu is None:
            return
        self._native_menu = menu

        def fill(target, node):
            for entry in node.get("items", []):
                if entry.get("separator"):
                    target.addSeparator()
                elif entry.get("submenu"):
                    child = entry["submenu"]
                    fill(target.addMenu(child.get("name", "")), child)
                elif entry.get("id") is not None:
                    action = target.addAction(entry.get("text", "Command"))
                    action.triggered.connect(lambda _checked=False, cid=entry["id"]: self.run_command(cid))
        fill(menu, tree)
        menu.addSeparator()
        from .repair import repair_selected
        menu.addAction("Repair Selected Model Faces").triggered.connect(lambda: repair_selected(self.app))

    def _call(self, msg):
        fn = msg.get("fn")
        if fn == 'console_visible':return self._console_dialog is not None and self._console_dialog.isVisible()
        if fn in ("scene_snapshot", "load_component", "export_model", "write_image", "native_hide", "native_walkthrough", "scene_raytest", "solid_operation", "geolocation"):
            from .services import call
            return call(self, msg)
        parent = self._active_dialog_widget() or self.app.window
        if fn == "messagebox":
            t = int(msg.get("type", 0)) & 0x0F
            text = msg.get("text", "")
            B = QMessageBox.StandardButton
            buttons = {0: B.Ok, 1: B.Ok | B.Cancel, 2: B.Abort | B.Retry | B.Ignore,
                       3: B.Yes | B.No | B.Cancel, 4: B.Yes | B.No, 5: B.Retry | B.Cancel}.get(t, B.Ok)
            r = QMessageBox.question(parent, "SketchUp Adapter", text, buttons) if t else \
                QMessageBox.information(parent, "SketchUp Adapter", text, buttons)
            return {B.Ok: 1, B.Cancel: 2, B.Abort: 3, B.Retry: 4, B.Ignore: 5,
                    B.Yes: 6, B.No: 7}.get(r, 2)
        if fn == "openpanel":
            from PySide6.QtWidgets import QFileDialog
            flt = _qt_filter(msg.get("filter", ""))
            path, _ = QFileDialog.getOpenFileName(parent, msg.get("title", ""), msg.get("dir", ""), flt)
            return path or None
        if fn == "savepanel":
            from PySide6.QtWidgets import QFileDialog
            start = os.path.join(msg.get("dir", ""), msg.get("name", ""))
            path, _ = QFileDialog.getSaveFileName(parent, msg.get("title", ""), start)
            return path or None
        if fn == "select_directory":
            from PySide6.QtWidgets import QFileDialog
            return QFileDialog.getExistingDirectory(parent, msg.get("title", "")) or None
        if fn == "inputbox":
            from PySide6.QtWidgets import QInputDialog
            out = []
            for i, p in enumerate(msg.get("prompts", [])):
                d = msg.get("defaults", [])
                val, ok = QInputDialog.getText(parent, msg.get("title") or "SketchUp Adapter", p,
                                               text=d[i] if i < len(d) else "")
                if not ok:
                    return None
                out.append(val)
            return out
        return None

    def _active_dialog_widget(self):
        return None

    def dialog_host(self):
        if self._dialog_host is None:
            self._dialog_host = DialogHost(self)
        return self._dialog_host

    # ---- toolbar -----------------------------------------------------------------
    def _restore_toolbar_layout(self) -> None:
        """The Ruby toolbars arrive after the window restored its layout."""
        if getattr(self, "_toolbar_layout_restored", False):
            return
        self._toolbar_layout_restored = True
        if not self.toolbars:
            return
        state = QSettings().value("ui/window_state")
        if state:
            self.app.window.restoreState(state)

    def _make_toolbar(self, msg):
        name = msg.get("name") or "SketchUp Adapter"
        win = self.app.window
        tb = self.toolbars.get(name)
        if tb is None:
            new_tb = getattr(win, "_new_toolbar", None)
            if callable(new_tb):
                tb = new_tb(name, f"{TOOLBAR_KEY}_{len(self.toolbars)}")
            else:
                tb = QToolBar(name, win)
                tb.setObjectName(f"{TOOLBAR_KEY}_{len(self.toolbars)}")
                win.addToolBar(Qt.TopToolBarArea, tb)
            self.toolbars[name] = tb
        tb.clear()
        for it in msg.get("items", []):
            if it.get("separator"):
                tb.addSeparator()
                continue
            icon = QIcon(it.get("large_icon") or it.get("small_icon") or "")
            act = QAction(icon, it.get("text", ""), win)
            act.setToolTip(it.get("tooltip") or it.get("text", ""))
            act.setStatusTip(it.get("status", ""))
            act.triggered.connect(lambda _c=False, cid=it["id"]: self.run_command(cid))
            tb.addAction(act)
        tb.show()

    def run_command(self, cid: int) -> None:
        if self.sync_selection(force=True) is False:
            if self._document_reset_waiting:self._notify_reset_busy()
            elif self.ready and getattr(self, '_last_selection_valid', True) is False:
                self._notify_invalid_selection()
            return
        self.send({"op": "command", "id": int(cid)})

    # ---- selection ------------------------------------------------------------------
    def _notify_invalid_selection(self):
        flash = getattr(self.app.viewport, 'flash_status', None)
        if callable(flash): flash('Cannot inspect the selected geometry safely. Check its geometry, transform, or texture.', 8000)

    def selection_items(self, defer_groups=False, entities=None, reset_tokens=True):
        from core.group import Group
        from core.mesh import Edge, Face
        scene = self.app.scene
        data = scene.plugin_data.get(DATA_KEY, {}) if hasattr(scene, "plugin_data") else {}
        items = []
        context_graphs={}
        context_seen={}
        if reset_tokens:self._face_tokens = {}
        selected=list(scene.selection if entities is None else entities)
        if entities is None and len(selected)>1:
            # Native selection is a set. Its pointer-dependent iteration can
            # turn an edge loop into a bow-tie for legacy tools that enumerate
            # selection vertices. Preserve deterministic native entity order.
            ordered=[*scene.loose_mesh.edges,*scene.loose_mesh.faces,*scene.groups]
            if scene.mesh is not scene.loose_mesh:
                ordered.extend([*scene.mesh.edges,*scene.mesh.faces])
            positions={id(entity):index for index,entity in enumerate(ordered)}
            selected.sort(key=lambda entity:positions.get(id(entity),len(positions)))
        for ent in selected:
            if isinstance(ent, Group):
                uid = getattr(ent, "uid", None)
                if uid in data:
                    rec = data[uid]
                    xf = ent.xform if ent.xform is not None else QMatrix4x4()
                    items.append({"kind": "bogdan", "uid": uid, "rid": self.rid_of_uid.get(uid),
                                  "attrs": rec.get("attrs", {}), "def_attrs": rec.get("def_attrs", {}),
                                  "name": rec.get("name", ""), "inst_name": ent.name or "",
                                  "hidden": bool(getattr(ent, "hidden", False)),
                                  "xform": _matrix_out(xf),
                                  **({"_group_reference":ent} if defer_groups else {"geometry":self._group_snapshot(ent)})})
                else:
                    items.append({"kind": "group", "uid": uid,
                                  **({"_group_reference":ent} if defer_groups else {"geometry":self._group_snapshot(ent)}),
                                  "xform": _matrix_out(ent.xform) if ent.xform is not None else None,
                                  "hidden": bool(getattr(ent, "hidden", False))})
            elif isinstance(ent, Face):
                mesh, mat = self._entity_owner(ent)
                if mesh is None:
                    continue
                token = str(id(ent))
                self._face_tokens[token] = (mesh, ent)
                w = (lambda p: mat.map(p)) if mat is not None else (lambda p: p)
                from .native_edges import world_normal
                n = world_normal(ent, mat)
                from .surface_paint import proxy_attrs
                items.append({"kind": "face", "token": token,
                              "outer": [list(w(p).toTuple()) for p in ent.vertices],
                              "holes": [[list(w(p).toTuple()) for p in h] for h in ent.holes],
                              "attrs": dict(ent.attrs),
                              'proxy_attrs': proxy_attrs(ent.attrs, mat, ent.normal(), QVector3D),
                              'layer':ent.attrs.get('layer'),
                              "normal": [n.x(), n.y(), n.z()]})
                from .native_edges import surface_records
                items[-1]['edge_properties']=surface_records(self,ent,mesh,mat,scene)
                # Surface builders inspect adjacent faces in active_entities,
                # for example the opposite side of a wall. Import their
                # connected context as read-only proxies, not selections.
                targets=self.__dict__.setdefault('_surface_targets',{})
                targets[token]=(mesh,ent,QMatrix4x4(mat) if mat is not None else None)
                graph_key=id(mesh)
                if graph_key not in context_graphs:
                    by_vertex={};face_keys={}
                    for candidate in mesh.faces:
                        keys={tuple(round(float(v),6) for v in p.toTuple()) for ring in
                              [candidate.vertices,*candidate.holes] for p in ring}
                        face_keys[id(candidate)]=keys
                        for key in keys:by_vertex.setdefault(key,[]).append(candidate)
                    context_graphs[graph_key]=(by_vertex,face_keys)
                by_vertex,face_keys=context_graphs[graph_key]
                pending=[ent];visited=context_seen.setdefault(graph_key,set())
                known_tokens={record.get('token') for record in items if record.get('kind')=='face'}
                while pending:
                    candidate=pending.pop();identity=id(candidate)
                    if identity in visited:continue
                    visited.add(identity)
                    for key in face_keys.get(identity,()):
                        pending.extend(face for face in by_vertex[key] if id(face) not in visited)
                    context_token=str(identity)
                    if context_token in known_tokens:continue
                    known_tokens.add(context_token)
                    normal=world_normal(candidate,mat)
                    self._face_tokens[context_token]=(mesh,candidate)
                    targets[context_token]=(mesh,candidate,QMatrix4x4(mat) if mat is not None else None)
                    items.append({'kind':'face','token':context_token,'_context_only':True,
                        'outer':[list(w(p).toTuple()) for p in candidate.vertices],
                        'holes':[[list(w(p).toTuple()) for p in ring] for ring in candidate.holes],
                        'attrs':dict(candidate.attrs),
                        'proxy_attrs':proxy_attrs(candidate.attrs, mat, candidate.normal(), QVector3D),
                        'normal':list(normal.toTuple())})
                    items[-1]['edge_properties']=surface_records(self,candidate,mesh,mat,scene)
            elif isinstance(ent, Edge):
                mesh, mat = self._entity_owner(ent)
                if mesh is None:
                    continue
                from .native_edges import context
                items.extend(context(self,ent,mesh,mat,{id(e) for e in selected}))
        # A selected face may already have arrived as another selected face's
        # context. Keep one proxy per native face and promote its selection.
        result=[];face_records={}
        for record in items:
            if record.get('kind') in ('face','edge'):
                token=(record['kind'],record['token'])
                if token in face_records:
                    if not record.get('_context_only'):face_records[token].pop('_context_only',None)
                    continue
                face_records[token]=record
            result.append(record)
        return result

    def _entity_owner(self, entity):
        """(mesh, world matrix or None) of selected geometry — the loose
        geometry, or the group it lives in when that group is open."""
        from core.mesh import Face
        collection = "faces" if isinstance(entity, Face) else "edges"
        scene = self.app.scene
        loose = scene.loose_mesh
        if any(item is entity for item in getattr(loose, collection)):
            return loose, None
        from core.group import iter_placements
        for top in scene.groups:
            for g, m in iter_placements(top):
                if any(item is entity for item in getattr(g.mesh, collection)):
                    return g.mesh, m
        return None, None

    # IngeTrazo length unit -> SketchUp LengthUnit (0 in, 1 ft, 2 mm, 3 cm, 4 m)
    UNIT_CODES = {"m": 4, "cm": 3, "mm": 2, "in": 0, "in-frac": 0,
                  "ft": 1, "ft-in": 1, "ft-in-frac": 1}

    def sync_units(self) -> None:
        """The project's units (Model Info) drive the dialog, as in SketchUp."""
        if not self.ready:
            return
        units = getattr(self.app.scene, "units", None) or {}
        code = self.UNIT_CODES.get(str(units.get("length", "mm")), 2)
        prec = int(units.get("precision", 0) or 0)
        if self._sent_units == (code, prec):
            return
        self._sent_units = (code, prec)
        self.send({"op": "units", "unit": code, "precision": prec})

    def sync_selection(self, force=False) -> None:
        if not self.ready:
            return False
        if self._preparation.document_changed() or self._document_reset_waiting:
            return False
        self.sync_units()
        from .rendering_options import sync as sync_rendering_options
        sync_rendering_options(self)
        from .camera_sync import sync as sync_camera
        sync_camera(self)
        from .history_sync import sync
        sync(self)
        scene = self.app.scene
        key = (frozenset(id(e) for e in scene.selection), scene.version)
        if not force and key == self._last_sel_key:
            return getattr(self, '_last_selection_valid', True)
        self._last_sel_key = key
        self._surface_context_epoch += 1
        cam = None
        try:
            f = self.app.viewport.camera.forward()
            cam = [f.x(), f.y(), f.z()]
        except Exception:                          # noqa: BLE001
            pass
        try:
            items = self.selection_items(defer_groups=True)
        except (ValueError, TypeError) as error:
            # A malformed or non-invertible native texture map cannot safely
            # be represented in Ruby. Clear old proxies and do not dispatch a
            # command against a stale selection. The cached selection key also
            # prevents repeated errors on every poll of the same bad model.
            self._face_tokens = {}
            self._surface_targets = {}
            self._edge_targets = {}
            self._last_selection_valid = False
            self.send({"op":"selection", "items":[], "camera":cam})
            self.app.viewport.setToolTip('Cannot inspect selected geometry: '+str(error))
            self._notify_invalid_selection()
            return False
        self.send({"op": "selection", "items": items, "camera": cam})
        self._last_selection_valid = True
        # Context-menu callbacks can be expensive (Kitchen Crafter inspects
        # generated assemblies). Refresh the cached tree off the mouse path so
        # showing the user's right-click menu never waits for Ruby.
        self.send({"op": "context_menu"})
        return True

    # ---- geometry from Ruby -----------------------------------------------------------
    def _flush_batch(self) -> None:
        if not self._batch or self._sync_depth:
            return
        scene = self.app.scene
        materials_before = dict(scene.materials) if isinstance(getattr(scene, 'materials', None), dict) else None
        self._flush_committed = False
        try:
            self._flush_batch_inner()
        except Exception as error:
            if not self._flush_committed:
                if materials_before is None: scene.materials = None
                else: scene.materials.clear(); scene.materials.update(materials_before)
            self._preparation.document_changed(force=True)
            self._geometry_failure(error)

    def _flush_batch_inner(self) -> None:
        batch, self._batch = self._batch, []
        from .surface_preflight import StaleSurfaceEdit, validate as validate_surface_batch, validate_edge_transforms
        try:
            batch = validate_surface_batch(batch, getattr(self, '_surface_targets', {}),
                                           self._face_tokens, self.app.scene)
            validate_edge_transforms(batch, getattr(self, '_edge_targets', {}), self.app.scene)
            from .surface_paint import validate_batch as validate_surface_paint, validate_geometry_batch
            validate_geometry_batch(batch)
            validate_surface_paint(batch, getattr(self, '_surface_targets', {}), QVector3D, self.app.scene)
        except StaleSurfaceEdit as error:
            # Keep the native model untouched and discard all work in this
            # batch, including any prepared groups. Reset Ruby's document so
            # tools cannot keep using proxies for the rejected geometry.
            self._preparation.document_changed(force=True)
            self._geometry_failure(error)
            flash = getattr(self.app.viewport, 'flash_status', None)
            if callable(flash):
                flash('Extension edit stopped: ' + str(error) + ' Please retry.', 8000)
            return
        except ValueError as error:
            self._preparation.document_changed(force=True)
            self._geometry_failure(error)
            flash = getattr(self.app.viewport, 'flash_status', None)
            if callable(flash):
                flash('Extension face edit could not be applied safely.', 8000)
            return
        latest = {}
        other = []
        for msg in batch:
            # Group updates are deduplicated by rid, but a face patch attached
            # to an earlier update is an independent edit and must survive.
            if msg.get('op') == 'upsert' and msg.get('surface_patch'):
                other.append(dict(msg['surface_patch'], op='surface_patch'))
            if msg["op"] in ("upsert", "removed"):
                latest[msg["rid"]] = msg
            else:
                other.append(msg)
        batch = list(latest.values()) + other
        scene = self.app.scene
        materials_before = dict(scene.materials) if isinstance(getattr(scene, 'materials', None), dict) else None
        adds, replaces, removes, faces, recipes, select = [], [], [], [], {}, []
        shared_meshes = {}
        patches = []
        patch_bindings = []
        edge_patches = []
        guide_message = None
        for msg in batch:
            op = msg["op"]
            if op=='guide_patch':guide_message=msg
            if op=='edge_patch':
                target=getattr(self,'_edge_targets',{}).get(msg['token'])
                if target:
                    mesh,edge,xf=target
                    edge_patches.append((mesh,edge,msg.get('points'),msg,xf))
            patch = msg if op == 'surface_patch' else None
            if patch:
                target = getattr(self, '_surface_targets', {}).get(patch.get('token'))
                if target:
                    mesh, original, xf = target
                    inverse, valid = xf.inverted() if xf is not None else (QMatrix4x4(), True)
                    if not valid:
                        raise ValueError('Cannot edit a surface through a singular transform.')
                    point = lambda p: inverse.map(QVector3D(*p))
                    parts=[]
                    for outer,holes,attrs in patch.get('faces',[]):
                        properties=[dict(record,points=[list(point(p).toTuple()) for p in record['points']])
                            for record in attrs.get('_sketchup_edge_properties',[])]
                        part=([point(p) for p in outer],[[point(p) for p in h] for h in holes],properties)
                        if '_adapter_paint_edits' in attrs:
                            from .surface_paint import merge_attrs, world_basis
                            basis=world_basis(xf, QVector3D)
                            edits=attrs['_adapter_paint_edits']
                            merge_attrs(original.attrs, edits, basis)  # Validate before native mutation.
                            part += (edits, basis)
                        parts.append(part)
                    patches.append((mesh, original, parts))
                    if patch.get('identity_preserved') is True and len(parts) == 1:
                        patch_bindings.append((patch['token'], mesh, original, xf))
            if op == "upsert":
                rid = msg["rid"]
                payload = msg["payload"]
                register_materials(scene, payload)
                new = self._prepared_groups.pop(id(msg),None) or group_from_payload(payload, self.activity.update)
                share_published_components(new, payload, shared_meshes)
                old = self.group_of_rid.get(rid)
                if old is not None and old in scene.groups:
                    new.uid = old.uid
                    if not payload.get('layer'):new.layer = old.layer
                    replaces.append((old, new))
                else:
                    adds.append(new)
                self.group_of_rid[rid] = new
                self.rid_of_uid[new.uid] = rid
                recipes[new.uid] = recipe_of(payload)
                select.append(new)
            elif op == "removed":
                g = self.group_of_rid.pop(msg["rid"], None)
                if g is not None and g in scene.groups:
                    removes.append(g)
                    recipes[g.uid] = None
            elif op == "face_erased":
                f = self._face_tokens.get(msg.get("token"))
                if f is not None:
                    faces.append(f)
        # An Update that erased an item and built its successor is a replace.
        while removes and adds:
            old, new = removes.pop(0), adds.pop(0)
            temporary_uid = new.uid
            new.uid = old.uid
            new.layer = old.layer
            recipes[new.uid] = recipes.pop(temporary_uid, None)
            rid = self.rid_of_uid.pop(temporary_uid, None)
            if rid is not None:
                self.rid_of_uid[new.uid] = rid
            replaces.append((old, new))
        if not (adds or replaces or removes or faces or patches or edge_patches or guide_message is not None):
            self.activity.finish()
            return
        Cmd = _make_command()
        vp = self.app.viewport
        if patches:
            from .surface_edges import persistence,STATE_KEY
            recipes[STATE_KEY]=persistence(scene,patches)
        command = Cmd(adds, replaces, removes, faces, recipes, select)
        command.face_patches = patches
        command.edge_patches = edge_patches
        if guide_message is not None:
            from core.guide import Guide
            before=[g for g in scene.guides if hasattr(g,'_adapter_key')]
            after={}
            for data in guide_message.get('items',[]):
                guide=Guide(QVector3D(*data['point']),QVector3D(*data['direction']) if data.get('direction') else None,
                            layer=None if data.get('layer') in ('Layer0','Untagged') else data.get('layer'))
                guide._adapter_key=data['id'];after[data['id']]=guide
            command.guide_changes=(before,list(after.values()))
            self._managed_guides=after
        history = vp.history
        # History may raise after command.do succeeds, including after it has
        # appended to undo, truncated the stack, and cleared redo. Preserve
        # those stacks and bookkeeping for the duration of execute.
        undo_before, redo_before = list(history.undo_stack), list(history.redo_stack)
        cache_names = ('paint_cv', 'rows_cv', 'tags_cv', 'groups_cv')
        cache_before = {name: copy.copy(getattr(history, name)) for name in cache_names
                        if hasattr(history, name)}
        missing = object()
        dimension_before = []
        for dim in getattr(scene, 'dimensions', ()) or ():
            fields = {}
            for name in ('_scene', 'anchor_a', 'anchor_b', '_holds'):
                value = getattr(dim, name, missing)
                if name == '_holds' and isinstance(value, dict):
                    value = {key: list(items) for key, items in value.items()}
                fields[name] = value
            dimension_before.append((dim, fields))
        try:
            history.execute(command)
        except Exception:
            command.rollback_failed_commit(scene)
            history.undo_stack[:] = undo_before
            history.redo_stack[:] = redo_before
            for name, value in cache_before.items():
                setattr(history, name, value)
            for dim, fields in dimension_before:
                for name, value in fields.items():
                    if value is missing:
                        if hasattr(dim, name): delattr(dim, name)
                    else:
                        setattr(dim, name, value)
            raise
        if not vp.history.undo_stack or vp.history.undo_stack[-1] is not command:
            # History.execute can catch an exception and return normally. Do
            # not publish bindings or acknowledge geometry in that case.
            command.rollback_failed_commit(scene)
            if materials_before is None:
                scene.materials = None
            else:
                scene.materials.clear(); scene.materials.update(materials_before)
            if command._before_selection is not None:
                scene.selection.clear(); scene.selection.update(command._before_selection)
            detail = getattr(vp.history, 'last_error', None) or getattr(vp.history, 'last_rejected', None) or 'Native history did not commit the extension edit.'
            self._preparation.document_changed(force=True)
            self._geometry_failure(RuntimeError(str(detail)))
            return
        command._transaction_before = None
        self._flush_committed = True
        self.__dict__.setdefault('_surface_fragments',{}).update(command.surface_fragments)
        # A single surviving Ruby proxy still represents the one native face
        # that replaced its original. Rebind only after the native command
        # succeeds; never guess identity for splits or newly created proxies.
        targets = getattr(self, '_surface_targets', {})
        for token, mesh, original, xf in patch_bindings:
            current = targets.get(token)
            replacement = command.surface_fragments.get(str(id(original)))
            if (current and current[0] is mesh and current[1] is original and
                    replacement and replacement[0] is mesh and len(replacement[1]) == 1):
                face = replacement[1][0]
                targets[token] = (mesh, face, xf)
                self._face_tokens[token] = (mesh, face)
                self._surface_fragments[token] = (mesh, [face])
        # Register every published root even when the extension clears its
        # selection. Immediate Undo must retire unselected Ruby roots too.
        for group in [*adds, *(new for _old, new in replaces)]:
            rid = self.rid_of_uid.get(group.uid)
            if rid is not None:
                self.send({'op': 'native_binding', 'uid': group.uid, 'rid': rid})
        notify = getattr(vp, "notify_scene_changed", None)
        if callable(notify):
            notify()
        vp.update()
        self._last_sel_key = None
        self.activity.finish()

    # ---- placement (SketchUp's place_component) ------------------------------------------
    def _start_placement(self, msg):
        from .placement import ExtensionPlaceTool
        payload = msg["payload"]
        # A preview is not a model edit. Register its materials only when the
        # placement commits, so Escape never pollutes the document.
        group = self._prepared_groups.pop(id(msg),None) or group_from_payload(payload, self.activity.update)
        self.activity.finish()
        tool = ExtensionPlaceTool(self, msg["def"], payload, group)
        self._placing = tool
        self.app.viewport.set_active_tool(tool)
        self.app.viewport.setFocus()

    def placement_done(self, tool, group) -> bool:
        scene = self.app.scene
        materials_before = dict(scene.materials) if isinstance(getattr(scene, 'materials', None), dict) else None
        vp = self.app.viewport
        history = vp.history
        command = None
        undo_before, redo_before = list(history.undo_stack), list(history.redo_stack)
        cache_names = ('paint_cv', 'rows_cv', 'tags_cv', 'groups_cv')
        cache_before = {name: copy.copy(getattr(history, name)) for name in cache_names
                        if hasattr(history, name)}
        missing = object()
        dimension_before = []
        try:
            for dim in getattr(scene, 'dimensions', ()) or ():
                fields = {}
                for name in ('_scene', 'anchor_a', 'anchor_b', '_holds'):
                    value = getattr(dim, name, missing)
                    if name == '_holds' and isinstance(value, dict):
                        value = {key: list(items) for key, items in value.items()}
                    fields[name] = value
                dimension_before.append((dim, fields))
            register_materials(scene, tool.payload)
            Cmd = _make_command()
            command = Cmd([group], [], [], [], {group.uid: recipe_of(tool.payload)}, [group])
            history.execute(command)
            if not history.undo_stack or history.undo_stack[-1] is not command:
                detail = getattr(history, 'last_error', None) or getattr(history, 'last_rejected', None) or 'Native history did not commit the placement.'
                raise RuntimeError(str(detail))
        except Exception as error:
            if command is not None:
                command.rollback_failed_commit(scene)
            history.undo_stack[:] = undo_before
            history.redo_stack[:] = redo_before
            for name, value in cache_before.items():
                setattr(history, name, value)
            for dim, fields in dimension_before:
                for name, value in fields.items():
                    if value is missing:
                        if hasattr(dim, name): delattr(dim, name)
                    else:
                        setattr(dim, name, value)
            if materials_before is None: scene.materials = None
            else: scene.materials.clear(); scene.materials.update(materials_before)
            self.placement_cancelled(tool)
            self._geometry_failure(error)
            return False
        command._transaction_before = None
        self.send({"op": "placed", "def": tool.def_id, "xform": _matrix_out(group.xform),
                   "uid": group.uid})
        notify = getattr(vp, "notify_scene_changed", None)
        if callable(notify):
            notify()
        self._placing = None
        return True

    def placement_cancelled(self, tool) -> None:
        self.send({"op": "place_cancelled", "def": tool.def_id})
        self._placing = None

    def _geometry_failure(self, error) -> None:
        log.error('Extension geometry preparation failed: %s',error)
        self._batch.clear()
        self._batch_failed = True
        self.activity.update('failed', name='Geometry could not be prepared')
        self.app.viewport.setToolTip('The extension model could not be prepared: '+str(error))


def _python_exe() -> str:
    """Use the private dialog runtime for a packaged Windows install."""
    import sys
    exe = Path(sys.executable)
    if exe.stem.lower().startswith("python"):
        pyw = exe.with_name("pythonw.exe")
        return str(pyw if pyw.is_file() else exe)
    local_data = Path(os.environ.get("LOCALAPPDATA")
                      or Path.home() / "AppData" / "Local")
    private_python = (local_data / "IngeTrazo" / "window-crafter-runtime"
                      / "Scripts" / "pythonw.exe")
    if private_python.is_file():
        return str(private_python)
    for cand in (exe.parent / "python.exe", exe.parent / "venv" / "Scripts" / "pythonw.exe"):
        if cand.is_file():
            return str(cand)
    return shutil.which("python") or "python"


class DialogHost(QObject):
    """The dialog process (dialog.py): Qt WebEngine kept out of IngeTrazo's
    OpenGL process. Relays page callbacks to Ruby."""

    def __init__(self, host) -> None:
        super().__init__(host)
        self.host = host
        self._buf = b""
        self.proc = QProcess(self)
        self.proc.setProgram(_python_exe())
        hwnd = int(host.app.window.winId())
        self.proc.setArguments([str(PKG / "dialog.py"), str(hwnd)])
        from PySide6.QtCore import QProcessEnvironment
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PYTHONIOENCODING", "utf-8")
        self.proc.setProcessEnvironment(env)
        self.proc.readyReadStandardOutput.connect(self._on_stdout)
        self.proc.readyReadStandardError.connect(
            lambda: host._logf.write(bytes(self.proc.readAllStandardError()).decode("utf-8", "replace"))
            or host._logf.flush())
        self.proc.start()
        if not self.proc.waitForStarted(10000):
            QMessageBox.warning(host.app.window, "SketchUp Adapter",
                                "Could not start the extension dialog process.")

    def send(self, msg: dict) -> None:
        if self.proc.state() == QProcess.Running:
            self.proc.write((json.dumps(msg) + "\n").encode("utf-8"))

    def _on_stdout(self) -> None:
        self._buf += bytes(self.proc.readAllStandardOutput())
        while b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            try:
                msg = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            op = msg.get("op")
            if op == "callback":
                # SketchUp's selection is always live when a callback runs.
                if self.host.sync_selection() is not False:
                    self.host.send(msg)
                elif self.host._document_reset_waiting:
                    self.host._notify_reset_busy()
                else:
                    self.host._notify_invalid_selection()
            elif op in ("dialog_closed", "dialog_resized", "dialog_moved", "dialog_close_requested"):
                self.host.send(msg)


def _qt_filter(sk_filter: str) -> str:
    """SketchUp "Label|*.ext;*.x||" → Qt "Label (*.ext *.x)"."""
    parts = [p for p in (sk_filter or "").split("|") if p]
    out = []
    for i in range(0, len(parts) - 1, 2):
        out.append(f"{parts[i]} ({parts[i + 1].replace(';', ' ')})")
    return ";;".join(out) or "All files (*)"


# ---------------------------------------------------------------------------
# Plugin entry points
# ---------------------------------------------------------------------------

_host: RubyHost | None = None


def host() -> RubyHost | None:
    return _host


def setup(app, registry=None):
    global _host
    from .precision import install_persistence
    install_persistence()
    from .alpha import install
    install()
    from .hide import install_guide_visibility
    install_guide_visibility(app.viewport)
    _host = RubyHost(app, registry)
    if not _host.start():
        return
    # Selection and document changes flow to the extension like SketchUp's
    # SelectionObserver: polled cheaply, sent only when something changed.
    timer = QTimer(app.window)
    timer.setInterval(200)
    timer.timeout.connect(lambda: _host.sync_selection())
    timer.start()
    _host._sel_timer = timer
    app.window.destroyed.connect(lambda *_: _host.send({"op": "quit"}))
    from .context import install_context_menu
    install_context_menu(_host)
    add_overlay = getattr(app, "add_overlay", None)
    if callable(add_overlay):
        add_overlay(lambda vp, painter: _host._paint_extension_overlay(vp, painter))
    return _host


