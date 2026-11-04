"""Install a source-linked adapter without modifying the IngeTrazo app bundle."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from sketchup_adapter.registry import Registry, atomic_json


def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _atomic_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(source=None, plugin_root=None, registry_root=None, example=True):
    source = Path(source or Path(__file__).parent).resolve()
    adapter = source / 'sketchup_adapter' / '__init__.py'
    if not adapter.is_file():
        raise ValueError('Adapter source is missing sketchup_adapter/__init__.py')
    if example and not any((source / 'examples').glob('*.rb')):
        raise ValueError('Adapter source has no example Ruby loaders')
    root = Path(plugin_root) if plugin_root else Path(os.environ["APPDATA"]) / "IngeTrazo" / "plugins"
    target = root / "sketchup_adapter" / "__init__.py"
    if target.resolve() == adapter.resolve():
        raise ValueError('The installed loader cannot overwrite the adapter source')
    manifest = source / 'public_files.json'
    if manifest.is_file():
        runtime = json.loads(manifest.read_text(encoding='utf-8-sig')).get('runtime')
        if not isinstance(runtime, list) or not runtime:
            raise ValueError('Adapter source has an invalid runtime inventory')
        for name in runtime:
            if not isinstance(name, str) or '\\' in name:
                raise ValueError('Adapter source has an invalid runtime path')
            relative = PurePosixPath(name)
            path = source.joinpath(*relative.parts)
            if (relative.is_absolute() or '..' in relative.parts or not relative.parts or
                    not path.resolve().is_relative_to(source) or not path.is_file()):
                raise ValueError(f'Adapter runtime file is missing or invalid: {name}')
    elif not all(path.is_file() for path in (source/'sketchup_adapter/registry.py',
                                             source/'sketchup_adapter/ruby_host/host.rb')):
        raise ValueError('Adapter source is missing required runtime files')
    registry = Registry(registry_root)
    installation = registry.root / 'installation.json'
    tracked = {'loader': target, 'registry': registry.path, 'installation': installation}
    for path in tracked.values():
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ValueError(f'Installation target must be a regular file: {path}')
    backups = registry.root / 'backups'
    backups.mkdir(parents=True, exist_ok=True)
    backup_dir = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f-'), dir=backups))
    files = {}
    for name, path in tracked.items():
        before = backup_dir / (name + '-before')
        exists = path.exists()
        if exists:
            shutil.copy2(path, before)
        files[name] = {'path': str(path), 'before_exists': exists,
                       'backup': str(before) if exists else None,
                       'before_sha256': _sha256(before) if exists else None}
    receipt_path = backup_dir / 'receipt.json'
    backup_receipt = {'status': 'prepared', 'files': files}
    atomic_json(receipt_path, backup_receipt)
    code = f'''# Source-linked SketchUp Adapter for IngeTrazo.
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys
_ROOT = Path({str(source / 'sketchup_adapter')!r})
_NAME = "_ingetrazo_universal_sketchup_adapter"
_SPEC = spec_from_file_location(_NAME, _ROOT / "__init__.py", submodule_search_locations=[str(_ROOT)])
_MODULE = module_from_spec(_SPEC)
sys.modules[_NAME] = _MODULE
_SPEC.loader.exec_module(_MODULE)
def setup(app):
    return _MODULE.setup(app)
'''
    try:
        _atomic_bytes(target, code.encode('utf-8'))
        if example:
            for plugin in registry.register_folder(source / "examples"):
                registry.enable(plugin.id)
        receipt = {"installed": str(target), "source": str(source), "backup": files['loader']['backup'],
                   "backup_dir": str(backup_dir), "backup_receipt": str(receipt_path),
                   "sha256": _sha256(target), "registry": str(registry.path),
                   "example_enabled": example, "app_bundle_modified": False,
                   "restart_required": True, "time": datetime.now(timezone.utc).isoformat()}
        atomic_json(installation, receipt)
        for name, path in tracked.items():
            files[name].update(after_exists=path.exists(), after_sha256=_sha256(path) if path.exists() else None)
        backup_receipt['status'] = 'completed'
        atomic_json(receipt_path, backup_receipt)
        return receipt
    except Exception:
        failures = []
        for name, path in tracked.items():
            try:
                if files[name]['before_exists']:
                    if not path.is_file() or _sha256(path) != files[name]['before_sha256']:
                        _atomic_bytes(path, Path(files[name]['backup']).read_bytes())
                elif path.exists():
                    path.unlink()
                files[name].update(after_exists=path.exists(), after_sha256=_sha256(path) if path.exists() else None)
            except Exception as error:
                failures.append(f'{name}: {error}')
        backup_receipt.update(status='rollback_failed' if failures else 'rolled_back', rollback_errors=failures)
        try:
            atomic_json(receipt_path, backup_receipt)
        except Exception as error:
            failures.append(f'backup receipt: {error}')
        if failures:
            raise RuntimeError('Installer rollback was incomplete; inspect ' + str(backup_dir) + ': ' + '; '.join(failures))
        raise


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-example", action="store_true")
    args=parser.parse_args()
    print(json.dumps(install(example=not args.no_example),indent=2))
