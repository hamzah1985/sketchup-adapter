# SPDX-License-Identifier: GPL-3.0-or-later
"""Persistent extension catalog, read-only discovery and bounded RBZ installer."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import zipfile
from dataclasses import asdict, dataclass, field
from pathlib import Path, PurePosixPath


def data_root() -> Path:
    override = os.environ.get("INGETRAZO_SKETCHUP_ADAPTER_HOME")
    if override:
        return Path(override).expanduser().resolve()
    base = Path(os.environ.get("APPDATA", Path.home() / ".local" / "share"))
    return base / "IngeTrazo" / "sketchup_adapter"


def atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def scan_tree(root: Path, loaders: list[str] | None = None) -> dict:
    """Static inspection only: never execute the extension being inspected."""
    root = root.resolve()
    loaders = loaders if loaders is not None else sorted(p.name for p in root.glob("*.rb"))
    files = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
    ruby = [p for p in files if p.suffix.lower() == ".rb"]
    encrypted = [p.relative_to(root).as_posix() for p in files if p.suffix.lower() in {".rbe", ".rbs"}]
    native = [p.relative_to(root).as_posix() for p in files if p.suffix.lower() in {".so", ".dll", ".bundle", ".dylib"}]
    requires, constants = set(), set()
    for path in ruby:
        if path.stat().st_size > 8 * 1024 * 1024:
            continue
        text = path.read_text(encoding="utf-8-sig", errors="replace")
        requires.update(re.findall(r"(?:Sketchup\.)?require(?:_relative)?\s*\(?\s*['\"]([^'\"]+)['\"]", text))
        constants.update(re.findall(r"\b(?:Sketchup|Geom|UI)::[A-Z]\w*", text))
    warnings = []
    if any(name.lower().endswith('.rbe') for name in encrypted):
        warnings.append("RBE execution is not implemented by this adapter.")
    if any(name.lower().endswith('.rbs') for name in encrypted):
        warnings.append("Legacy RBS1.0 code needs the adapter's locally configured format loader; startup and tools require testing.")
    if native:
        warnings.append("Native libraries need a matching Ruby ABI and may depend on SketchUp's process. Runtime loading is unverified.")
    if not loaders:
        warnings.append("No root Ruby loader found. Select a loader or register the containing Plugins directory.")
    return {"ruby_files": len(ruby), "loaders": loaders, "encrypted_files": encrypted,
            "native_libraries": native, "requires": sorted(requires), "api_classes": sorted(constants),
            "warnings": warnings, "status": "not_runtime_tested"}


@dataclass
class Plugin:
    id: str
    name: str
    root: str
    loaders: list[str]
    enabled: bool = False
    dependencies: list[str] = field(default_factory=list)
    priority: int = 100
    source: str = "folder"
    inspection: dict = field(default_factory=dict)


class Registry:
    def __init__(self, root: Path | None = None):
        self.root = Path(root) if root else data_root()
        self.path = self.root / "registry.json"
        self.settings = {"ruby": "", "autostart": True}
        self.plugins: dict[str, Plugin] = {}
        if self.path.exists():
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
            if data.get("schema") != 1:
                raise ValueError("Unsupported adapter registry schema")
            self.settings.update(data.get("settings", {}))
            self.plugins = {item["id"]: Plugin(**item) for item in data.get("plugins", [])}

    def save(self):
        atomic_json(self.path, {"schema": 1, "settings": self.settings,
                                "plugins": [asdict(p) for p in self.plugins.values()]})

    def register_folder(self, folder: Path, *, loader: str | None = None, name: str | None = None) -> list[Plugin]:
        folder = Path(folder).expanduser().resolve(strict=True)
        if not folder.is_dir():
            raise ValueError("Choose a plugin directory")
        candidates = [loader] if loader else sorted(p.name for p in folder.glob("*.rb"))
        if not candidates:
            raise ValueError("No .rb loaders found at the root of this directory")
        result = []
        for entry in candidates:
            relative = PurePosixPath(str(entry).replace("\\", "/"))
            full = (folder / str(relative)).resolve(strict=True)
            if not full.is_relative_to(folder) or full.suffix.lower() != ".rb":
                raise ValueError("Loader must be a Ruby file inside the plugin directory")
            key = hashlib.sha256(str(full).casefold().encode()).hexdigest()[:12]
            plugin_id = re.sub(r"[^a-z0-9_-]+", "_", full.stem.lower()) + "-" + key
            prior = self.plugins.get(plugin_id)
            # Inspect the loader and its conventional support directory, not
            # every sibling plugin for each entry in a large Plugins folder.
            support = folder / full.stem
            inspection = scan_tree(support, [str(relative)]) if support.is_dir() else scan_tree_single(full)
            plugin = Plugin(plugin_id, name or full.stem, str(folder), [str(relative)],
                            enabled=prior.enabled if prior else False,
                            dependencies=prior.dependencies if prior else [],
                            priority=0 if re.search(r"(?:libfredo|tt_lib|library)", full.stem, re.I) else 100,
                            inspection=inspection)
            self.plugins[plugin_id] = plugin
            result.append(plugin)
        self.save()
        return result

    def install_rbz(self, archive: Path) -> Plugin:
        archive = Path(archive).resolve(strict=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        slug = re.sub(r"[^a-z0-9_-]+", "_", archive.stem.lower()).strip("_") or "extension"
        plugin_id = slug + "-" + digest[:12]
        destination = self.root / "packages" / plugin_id
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".install-", dir=destination.parent) as temporary:
            stage = Path(temporary) / "payload"
            stage.mkdir()
            with zipfile.ZipFile(archive) as bundle:
                infos = bundle.infolist()
                if len(infos) > 30000 or sum(i.file_size for i in infos) > 1024**3:
                    raise ValueError("RBZ exceeds the 30,000 file / 1 GiB installation limit")
                names = set()
                for info in infos:
                    raw = info.filename.replace("\\", "/")
                    relative = PurePosixPath(raw)
                    if (not raw or relative.is_absolute() or ".." in relative.parts or
                            any(":" in part or part.rstrip(" .") != part for part in relative.parts) or
                            stat.S_ISLNK(info.external_attr >> 16)):
                        raise ValueError(f"Unsafe RBZ entry: {info.filename}")
                    if any(part.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *[f"COM{i}" for i in range(1,10)], *[f"LPT{i}" for i in range(1,10)]} for part in relative.parts):
                        raise ValueError(f"Reserved Windows path in RBZ: {info.filename}")
                    canonical = str(relative).casefold()
                    if canonical in names:
                        raise ValueError(f"Duplicate RBZ path: {info.filename}")
                    names.add(canonical)
                    target = stage.joinpath(*relative.parts)
                    if not target.resolve().is_relative_to(stage.resolve()):
                        raise ValueError("RBZ entry escapes installation directory")
                    if info.is_dir() or raw.endswith("/"):
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with bundle.open(info) as source, target.open("wb") as output:
                            shutil.copyfileobj(source, output)
            inspection = scan_tree(stage)
            if not inspection["loaders"]:
                raise ValueError("RBZ must contain at least one root .rb loader")
            if not destination.exists():
                os.replace(stage, destination)
        prior = self.plugins.get(plugin_id)
        plugin = Plugin(plugin_id, archive.stem, str(destination), inspection["loaders"],
                        enabled=prior.enabled if prior else False,
                        dependencies=prior.dependencies if prior else [], source=str(archive), inspection=inspection)
        self.plugins[plugin_id] = plugin
        self.save()
        return plugin

    def enable(self, plugin_id: str, enabled=True, with_dependencies=False):
        plugin = self.plugins[plugin_id]
        if enabled:
            visiting = set()
            def activate(item):
                if item.id in visiting:
                    raise ValueError("Dependency cycle: " + item.id)
                visiting.add(item.id)
                for key in item.dependencies:
                    if key not in self.plugins:
                        raise ValueError("Missing dependency: " + key)
                    dependency = self.plugins[key]
                    if not dependency.enabled:
                        if not with_dependencies:
                            raise ValueError("Enable dependency first: " + key)
                        activate(dependency)
                visiting.remove(item.id)
                item.enabled = True
            old = {key: item.enabled for key, item in self.plugins.items()}
            try:
                activate(plugin)
                self.runtime_config()  # validates cycles among already enabled entries
            except Exception:
                for key, value in old.items():
                    self.plugins[key].enabled = value
                raise
        else:
            dependants = [p.name for p in self.plugins.values() if p.enabled and plugin_id in p.dependencies]
            if dependants:
                raise ValueError("Disable dependent plugins first: " + ", ".join(dependants))
            plugin.enabled = False
        self.save()

    def runtime_config(self) -> dict:
        result, state = [], {}
        def visit(plugin):
            if state.get(plugin.id) == 1:
                raise ValueError("Dependency cycle: " + plugin.id)
            if state.get(plugin.id) == 2:
                return
            state[plugin.id] = 1
            for key in plugin.dependencies:
                dependency = self.plugins.get(key)
                if not dependency or not dependency.enabled:
                    raise ValueError(f"{plugin.name} requires enabled dependency {key}")
                visit(dependency)
            state[plugin.id] = 2
            result.append(plugin)
        for plugin in sorted(self.plugins.values(), key=lambda p: (p.priority, p.name.casefold())):
            if plugin.enabled:
                visit(plugin)
        roots = list(dict.fromkeys(p.root for p in result))
        return {"roots": roots, "plugins": [{"id": p.id, "name": p.name, "root": p.root,
                "loaders": p.loaders} for p in result], "data_root": str(self.root),
                "protocol": 1, "adapter_version": "0.1.0"}


def scan_tree_single(path: Path) -> dict:
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    return {"ruby_files": 1, "loaders": [path.name], "encrypted_files": [], "native_libraries": [],
            "requires": re.findall(r"require\s*\(?\s*['\"]([^'\"]+)['\"]", text),
            "api_classes": sorted(set(re.findall(r"\b(?:Sketchup|Geom|UI)::[A-Z]\w*", text))),
            "warnings": [], "status": "not_runtime_tested"}
