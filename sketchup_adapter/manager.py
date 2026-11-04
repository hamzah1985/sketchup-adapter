# SPDX-License-Identifier: GPL-3.0-or-later
"""Native Qt extension manager. Changes to the enabled set apply at startup."""
from __future__ import annotations
import json
from pathlib import Path
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QDialog, QDialogButtonBox,
    QFileDialog, QHBoxLayout, QLabel, QListWidget, QListWidgetItem, QMessageBox,
    QPushButton, QSplitter, QTextEdit, QTreeWidget, QTreeWidgetItem, QVBoxLayout)
from .registry import Registry


class AdapterController:
    def __init__(self, app):
        self.app = app
        self.registry = Registry()
        self.host = None
        self.dialog = None

    def setup(self):
        self.app.add_menu_action("SketchUp Plugin Adapter…", self.show,
            tip="Install RBZ plugins, choose dependencies and inspect compatibility.")
        if self.registry.settings.get("autostart") and any(p.enabled for p in self.registry.plugins.values()):
            QTimer.singleShot(0, self.start)

    def start(self):
        if self.host and self.host.proc:
            return
        try:
            self.registry = Registry(self.registry.root)
            if not self.registry.runtime_config()["plugins"]:
                return
            from . import runtime
            self.host = runtime.setup(self.app, self.registry)
        except Exception as error:
            QMessageBox.warning(self.app.window, "SketchUp Adapter", str(error))

    def show(self):
        if self.dialog is None:
            self.dialog = ManagerDialog(self)
        self.dialog.refresh()
        self.dialog.show()
        self.dialog.raise_()
        self.dialog.activateWindow()


class ManagerDialog(QDialog):
    def __init__(self, controller):
        super().__init__(controller.app.window)
        self.controller = controller
        self._refreshing = False
        self.setWindowTitle("SketchUp Plugin Adapter")
        self.resize(920, 640)
        self.setWindowFlag(Qt.WindowContextHelpButtonHint, False)
        layout = QVBoxLayout(self)
        label = QLabel("Install an RBZ or add a plugin folder, then enable the plugins you want. "
                       "Enabled plugins load when IngeTrazo starts. Source folders are read without modification.")
        label.setWordWrap(True)
        layout.addWidget(label)
        row = QHBoxLayout()
        for title, callback in (("Install RBZ…", self.install), ("Add folder…", self.add_folder),
                                ("Dependencies…", self.dependencies), ("Start enabled plugins", self.start),
                                ("Refresh", self.refresh), ("Export report…", self.export)):
            button = QPushButton(title)
            button.clicked.connect(callback)
            row.addWidget(button)
        layout.addLayout(row)
        splitter = QSplitter(Qt.Vertical)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["Enabled", "Plugin", "Runtime status", "Inspection"])
        self.tree.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree.itemChanged.connect(self.changed)
        self.tree.itemSelectionChanged.connect(self.details)
        self.text = QTextEdit()
        self.text.setReadOnly(True)
        splitter.addWidget(self.tree)
        splitter.addWidget(self.text)
        splitter.setSizes([320,200])
        layout.addWidget(splitter)
        self.status = QLabel()
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.poll = QTimer(self)
        self.poll.setInterval(1000)
        self.poll.timeout.connect(self.update_status)
        self.poll.start()

    @property
    def registry(self):
        return self.controller.registry

    def refresh(self):
        selected = self.selected_id()
        self.controller.registry = Registry(self.registry.root)
        self._refreshing = True
        self.tree.clear()
        for plugin in self.registry.plugins.values():
            warnings = plugin.inspection.get("warnings", [])
            item = QTreeWidgetItem(["", plugin.name, "Not tested", "; ".join(warnings) or "Ruby source"])
            item.setData(0, Qt.UserRole, plugin.id)
            item.setCheckState(0, Qt.Checked if plugin.enabled else Qt.Unchecked)
            self.tree.addTopLevelItem(item)
            if plugin.id == selected:
                self.tree.setCurrentItem(item)
        for column in (0,1,2):
            self.tree.resizeColumnToContents(column)
        self._refreshing = False
        self.update_status()

    def selected_id(self):
        item = self.tree.currentItem()
        return item.data(0, Qt.UserRole) if item else None

    def changed(self, item, column):
        if self._refreshing or column != 0:
            return
        try:
            self.registry.enable(item.data(0, Qt.UserRole), item.checkState(0) == Qt.Checked)
        except Exception as error:
            QMessageBox.warning(self, "Cannot change plugin", str(error))
            self.refresh()
        self.update_status()

    def update_status(self):
        host = self.controller.host
        results = host.diagnostics.results if host else {}
        for index in range(self.tree.topLevelItemCount()):
            item = self.tree.topLevelItem(index)
            result = results.get(item.data(0, Qt.UserRole), {})
            status = result.get("status", "Not tested")
            if status == "loaded":
                status = "Loaded; workflows unverified"
            item.setText(2, status)
        running = bool(host and host.proc)
        enabled = sum(plugin.enabled for plugin in self.registry.plugins.values())
        self.status.setText(f"{enabled} plugins enabled. " +
            ("Worker running. Changes to enabled plugins apply after saving your model and restarting IngeTrazo."
             if running else "Worker idle. Start enabled plugins to load them in this session.") +
            " Legacy RBS1.0 needs the configured format loader. RBE and plugins tied to SketchUp's native binaries remain unsupported.")

    def details(self):
        plugin_id = self.selected_id()
        if not plugin_id:
            return
        from dataclasses import asdict
        data = asdict(self.registry.plugins[plugin_id])
        host = self.controller.host
        if host:
            data["runtime"] = host.diagnostics.results.get(plugin_id, "not tested")
            data["api_gaps"] = [event for event in host.diagnostics.events
                                if event.get("plugin_id") == plugin_id and event.get("op") == "api_gap"]
        self.text.setPlainText(json.dumps(data, indent=2, ensure_ascii=False))

    def install(self):
        path, _ = QFileDialog.getOpenFileName(self, "Install SketchUp extension", "", "SketchUp extensions (*.rbz *.zip)")
        if path:
            try:
                self.registry.install_rbz(Path(path))
                self.refresh()
            except Exception as error:
                QMessageBox.warning(self, "Installation failed", str(error))

    def add_folder(self):
        path = QFileDialog.getExistingDirectory(self, "Select a folder containing root .rb loaders")
        if path:
            try:
                self.registry.register_folder(Path(path))
                self.refresh()
            except Exception as error:
                QMessageBox.warning(self, "Cannot add folder", str(error))

    def dependencies(self):
        key = self.selected_id()
        if not key:
            return
        plugin = self.registry.plugins[key]
        dialog = QDialog(self)
        dialog.setWindowTitle("Dependencies for " + plugin.name)
        layout = QVBoxLayout(dialog)
        choices = QListWidget()
        for dependency in self.registry.plugins.values():
            if dependency.id == key:
                continue
            item = QListWidgetItem(dependency.name, choices)
            item.setData(Qt.UserRole, dependency.id)
            item.setCheckState(Qt.Checked if dependency.id in plugin.dependencies else Qt.Unchecked)
        layout.addWidget(choices)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)
        if dialog.exec() == QDialog.Accepted:
            old = plugin.dependencies
            plugin.dependencies = [choices.item(i).data(Qt.UserRole) for i in range(choices.count())
                                   if choices.item(i).checkState() == Qt.Checked]
            try:
                self.registry.runtime_config()
                self.registry.save()
            except Exception as error:
                plugin.dependencies = old
                QMessageBox.warning(self, "Invalid dependencies", str(error))
            self.details()

    def start(self):
        self.controller.start()
        self.update_status()

    def export(self):
        path, _ = QFileDialog.getSaveFileName(self, "Export compatibility report", "sketchup-adapter-report.json", "JSON (*.json)")
        if path:
            from .registry import atomic_json
            host = self.controller.host
            atomic_json(Path(path), {"config": self.registry.runtime_config(),
                                    "events": host.diagnostics.events if host else [],
                                    "startup_does_not_certify_workflows": True})
