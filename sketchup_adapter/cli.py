# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import asdict
from pathlib import Path
from .registry import Registry, atomic_json


def probe(registry: Registry, ids=None, timeout=45):
    if ids:
        chosen = set()
        def include(key):
            if key in chosen:
                return
            chosen.add(key)
            for dependency in registry.plugins[key].dependencies:
                include(dependency)
        for key in ids:
            include(key)
        old = {key: plugin.enabled for key, plugin in registry.plugins.items()}
        try:
            for key, plugin in registry.plugins.items():
                plugin.enabled = key in chosen
            config = registry.runtime_config()
        finally:
            for key, enabled in old.items():
                registry.plugins[key].enabled = enabled
    else:
        config = registry.runtime_config()
    ruby = registry.settings.get("ruby") or shutil.which("ruby")
    if not ruby:
        raise ValueError("Ruby was not found; set it with 'settings --ruby PATH'")
    with tempfile.TemporaryDirectory(prefix="sketchup-adapter-probe-") as temporary:
        environment=os.environ.copy()
        local_key=registry.root / 'rbs-format-key.bin'
        if local_key.is_file():
            environment['SKETCHUP_ADAPTER_RBS_KEY_FILE']=str(local_key.resolve())
        config["data_root"] = temporary  # probes never write real plugin preferences
        path = Path(temporary) / "runtime.json"
        atomic_json(path, config)
        runner = Path(__file__).parent / "ruby_host" / "probe.rb"
        try:
            process = subprocess.run([ruby, "-EUTF-8:UTF-8", str(runner), str(path)],
                capture_output=True, encoding="utf-8", errors="replace", timeout=timeout,
                env=environment,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            output, errors, returncode = process.stdout, process.stderr, process.returncode
            timed_out = False
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ""
            errors = error.stderr or ""
            if isinstance(output, bytes):
                output = output.decode("utf-8", "replace")
            if isinstance(errors, bytes):
                errors = errors.decode("utf-8", "replace")
            returncode, timed_out = None, True
    events = []
    for line in output.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            continue
    report = dict(next((event for event in reversed(events) if event.get("op") == "probe_report"), {}))
    report.update({"returncode": returncode, "timed_out": timed_out,
                   "events": events, "stderr": errors[-40000:],
                   "warning": "This executes extension startup in a disposable process, not a security sandbox. A successful startup does not certify plugin workflows."})
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description="Manage SketchUp extensions for IngeTrazo")
    parser.add_argument("--home", type=Path, help="Use an isolated adapter profile")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    install = commands.add_parser("install")
    install.add_argument("archive", type=Path)
    add = commands.add_parser("add-folder")
    add.add_argument("folder", type=Path)
    add.add_argument("--loader")
    for name in ("enable", "disable"):
        command = commands.add_parser(name)
        command.add_argument("id")
        command.add_argument("--with-dependencies", action="store_true")
    dependencies = commands.add_parser("dependencies")
    dependencies.add_argument("id")
    dependencies.add_argument("requires", nargs="*")
    settings = commands.add_parser("settings")
    settings.add_argument("--ruby")
    test = commands.add_parser("probe")
    test.add_argument("ids", nargs="*")
    test.add_argument("--timeout", type=int, default=45)
    test.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    registry = Registry(args.home)
    try:
        if args.command == "list":
            result = [asdict(plugin) for plugin in registry.plugins.values()]
        elif args.command == "install":
            result = asdict(registry.install_rbz(args.archive))
        elif args.command == "add-folder":
            result = [asdict(plugin) for plugin in registry.register_folder(args.folder, loader=args.loader)]
        elif args.command in {"enable", "disable"}:
            registry.enable(args.id, args.command == "enable", args.with_dependencies)
            result = asdict(registry.plugins[args.id])
        elif args.command == "dependencies":
            if any(key not in registry.plugins for key in args.requires):
                raise ValueError("All dependencies must be registered first")
            registry.plugins[args.id].dependencies = args.requires
            registry.runtime_config()
            registry.save()
            result = asdict(registry.plugins[args.id])
        elif args.command == "settings":
            if args.ruby:
                registry.settings["ruby"] = str(Path(args.ruby).resolve(strict=True))
                registry.save()
            result = registry.settings
        else:
            result = probe(registry, args.ids, args.timeout)
            if args.output:
                atomic_json(args.output, result)
            # The saved report carries full API inventory and raw diagnostics.
            result = {key: value for key, value in result.items() if key not in {"events", "stderr"}}
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except (ValueError, KeyError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
