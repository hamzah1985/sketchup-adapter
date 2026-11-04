"""Adapter-owned progress, persistent tool guidance and reliable Escape routing."""
from PySide6.QtCore import QObject, QEvent, Qt, QTimer
from PySide6.QtWidgets import QApplication, QLabel, QProgressBar, QHBoxLayout, QWidget


class Activity(QObject):
    def __init__(self, host):
        super().__init__(host)
        self.host = host
        self.guidance = QLabel(host.app.viewport)
        self.guidance.setTextFormat(Qt.PlainText)
        self.guidance.setAttribute(Qt.WA_TransparentForMouseEvents)
        self.guidance.setWordWrap(True)
        self.guidance.setStyleSheet('QLabel { background: #fffef4; color: #24313a; '
                                   'border: 1px solid #9ba7af; border-radius: 5px; padding: 9px; }')
        self.guidance.hide()
        self.panel = QWidget(host.app.window)
        layout = QHBoxLayout(self.panel)
        layout.setContentsMargins(6, 0, 6, 0)
        self.label = QLabel()
        self.label.setTextFormat(Qt.PlainText)
        self.bar = QProgressBar()
        self.bar.setFixedWidth(130)
        self.bar.setTextVisible(False)
        layout.addWidget(self.label)
        layout.addWidget(self.bar)
        host.app.window.statusBar().addPermanentWidget(self.panel)
        self.panel.hide()
        self.state = None
        self.tool_state = {}
        self._serial = 0
        self._pending_cancel = None
        self._unconfirmed_after_build = False
        self._cancel_wait_ms = 5000
        self.history = []  # bounded activity records for diagnostics and QA
        host.app.viewport.installEventFilter(self)
        QApplication.instance().installEventFilter(self)

    def eventFilter(self, watched, event):
        if watched is self.host.app.viewport and event.type() == QEvent.Resize:
            self._position()
        if (event.type() in (QEvent.ShortcutOverride, QEvent.KeyPress)
                and event.key() == Qt.Key_Escape
                and self.host._extension_tool is not None
                and self.host.app.viewport.active_tool is self.host._extension_tool
                and isinstance(watched, QWidget)
                and watched.window() is self.host.app.window):
            # The native window's Esc QAction runs before Tool.on_key and its
            # cascade can just clear selection. Claim this one tool's shortcut.
            event.accept()
            if event.type() == QEvent.KeyPress:
                self.host._extension_tool.on_cancel(self.host.app.viewport)
            return True
        return False

    def _position(self):
        self.guidance.setFixedWidth(max(120, min(470, self.host.app.viewport.width() - 24)))
        self.guidance.adjustSize()
        self.guidance.move(12, 12)
        self.guidance.raise_()

    def tool(self, state=None):
        if state is not None:
            self.tool_state = state
        if self.host._extension_tool is None:
            self.tool_state = {}
            self.guidance.hide()
            return
        state = self.tool_state
        title = state.get('title') or self.host._extension_tool.name
        stage = state.get('stage')
        name = state.get('class', '')
        hint = state.get('hint') or 'Follow the tool preview and click to continue.'
        if state.get('failed'):
            hint = 'This tool stopped after an error. Press Esc to cancel, then run it again.'
        elif name == 'GH_mdeck':
            hint = {0: 'Select a face for the metal deck.',
                    1: 'Step 1 of 2: Click a start point on the selected face.',
                    2: 'Step 2 of 2: Click in the direction the deck ribs should run.'}.get(stage, hint)
        elif name in ('GH_wopening', 'GH_Opening'):
            hint = {0: 'Click a wall face to start another opening, or press Esc to finish.',
                    1: 'Step 1 of 3: Click a reference point on the wall face.',
                    2: 'Step 2 of 3: Click the horizontal offset, or type a distance and press Enter.',
                    3: 'Step 3 of 3: Click the vertical offset, or type a distance and press Enter.'}.get(stage, hint)
            normal = state.get('normal')
            if normal and abs(normal[2]) > .95:
                hint += '\nFor a wall window, point at a vertical wall face.'
        elif name == 'GH_wframe':
            hint += '\nThis tool frames the selected face outline.'
        if state.get('preview_error') and not state.get('failed'):
            hint += '\nMove the cursor to update the preview, or press Esc to cancel.'
        self.guidance.setText(f'{title}\n{hint}\nEsc: cancel tool')
        self._position()
        self.guidance.show()

    def update(self, phase, done=None, total=None, name=None):
        self._serial += 1
        self.state = dict(phase=phase, done=done, total=total, name=name)
        self.history.append(self.state.copy())
        del self.history[:-512]
        text = {'loading': 'Loading extension', 'generating': 'Generating geometry',
                'decoding': 'Loading geometry', 'building': 'Building geometry',
                'view': 'Preparing view', 'done': 'Geometry ready',
                'cancelling': 'Cancelling extension tool…',
                'cancel_waiting': 'Still cancelling — if this does not finish, save your model and restart IngeTrazo',
                'cancel_unconfirmed': 'The extension changed tools before cancellation completed — check the model',
                'failed': 'Extension stopped', 'cancelled': 'Tool cancelled'}.get(phase, phase)
        if name:
            text += ' — ' + str(name)
        if done is not None:
            suffix=f' / {total:,} faces' if total is not None else ' faces generated' if phase=='generating' else ' faces'
            text += f' — {done:,}' + suffix
        self.label.setText(text)
        self.label.setMinimumWidth(self.label.sizeHint().width())
        self.bar.setRange(0, int(total) if total else 0)
        self.bar.setValue(int(done or 0))
        self.bar.setVisible(phase not in ('done', 'failed', 'cancelled', 'cancel_waiting', 'cancel_unconfirmed'))
        self.panel.show()
        if phase in ('done', 'failed', 'cancelled'):
            serial = self._serial
            QTimer.singleShot(3500, lambda: self.clear() if self._serial == serial else None)

    def finish(self):
        if self._unconfirmed_after_build and self.state and self.state['phase'] == 'building':
            self._unconfirmed_after_build = False
            self.update('cancel_unconfirmed')
            return
        if self._pending_cancel is not None and self.state:
            if self.state['phase'] in ('cancelling', 'cancel_waiting'):
                return
            if self.state['phase'] == 'building':
                self.update('cancelling', name='Geometry completed; waiting for tool cleanup')
                self._wait_cancel(self._pending_cancel)
                return
        if self.state and self.state['phase'] not in ('failed', 'cancelled', 'cancel_unconfirmed', 'done'):
            self.update('done')

    def begin_cancel(self, tool_id, preparing=False):
        self._pending_cancel = tool_id
        self._unconfirmed_after_build = False
        if not preparing:
            self.update('cancelling')
        self._wait_cancel(tool_id)

    def _wait_cancel(self, tool_id):
        def still_waiting():
            if (self._pending_cancel == tool_id and self.state
                    and self.state['phase'] == 'cancelling'):
                self.update('cancel_waiting')
        QTimer.singleShot(self._cancel_wait_ms, still_waiting)

    def acknowledge_cancel(self, tool_id, cleaned=True):
        if self._pending_cancel != tool_id:
            return
        self._pending_cancel = None
        if self.state and self.state['phase'] in ('cancelling', 'cancel_waiting'):
            self.update('cancelled' if cleaned else 'cancel_unconfirmed')
        elif not cleaned and self.state and self.state['phase'] == 'building':
            self._unconfirmed_after_build = True

    def clear(self):
        self._serial += 1
        self._pending_cancel = None
        self._unconfirmed_after_build = False
        self.state = None
        self.panel.hide()
