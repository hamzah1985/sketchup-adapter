"""Build an explicit source-only experimental release; never package user profiles."""
from pathlib import Path,PurePosixPath
import argparse,hashlib,json,zipfile
EXTENSIONS={'.py','.rb','.svg','.md'}
def build_release(root,output,compatibility=None):
    root=Path(root).resolve();output=Path(output).resolve()
    approved=json.loads((root/'public_files.json').read_text())['runtime']
    current={p.relative_to(root).as_posix() for p in (root/'sketchup_adapter').rglob('*')
        if p.is_file() and '__pycache__' not in p.parts and p.suffix.lower() in EXTENSIONS
        and not p.is_relative_to(root/'sketchup_adapter/native_walk/assets')}
    if set(approved)!=current:raise ValueError('Public runtime inventory needs review')
    package={name:root/name for name in approved}
    readme=root/'PUBLIC_README.md' if (root/'PUBLIC_README.md').is_file() else root/'README.md'
    package.update({'LICENSE':root/'LICENSE','install.py':root/'install.py','README.md':readme,
        'build_release.py':root/'build_release.py','public_files.json':root/'public_files.json'})
    for name in ['.gitignore','CONTRIBUTING.md','VALIDATION.md']:
        if (root/name).is_file():package[name]=root/name
    for name in ['test_registry.py','test_diagnostics.py','test_shell_orientation.py','test_release_package.py','test_rendering_options.py','test_surface_preflight.py','test_surface_paint.py','test_camera_sync.py','test_history_notifications.py','test_async_recovery.py','portable_async_recovery_contracts.py','rbs_container_smoke.rb',
        'legacy_api_smoke.rb','topology_smoke.rb','explode_topology_smoke.rb','group_movement_smoke.rb','native_surface_smoke.rb','sweep_smoke.rb','plane_fit_smoke.rb',
        'selection_transform_smoke.rb','module_dependencies_smoke.rb','legacy_modules_smoke.rb',
        'operation_contracts_smoke.rb','downloaded_plugin_contracts.rb','open_source_contracts.rb','geolocation_console_contracts.rb','drawing_material_contracts.rb','rendering_options_smoke.rb','surface_paint_contracts.rb','extension_abort_contracts.rb','native_group_observers.rb','view_observer_contracts.rb','pick_helper_contracts.rb','fragment_lifecycle_contracts.rb','fragment_properties_contracts.rb','placement_binding_contracts.rb','pushpull_through_contracts.rb','timer_due_cancellation_contracts.rb','decimal_length_input_contracts.rb','runtime_evidence.py',
        'open_source_repositories.json','download_open_source_suite.py']:
        if (root/'tests'/name).is_file():package['tests/'+name]=root/'tests'/name
    for path in (root/'examples').glob('*.rb'):package['examples/'+path.name]=path
    for name,path in package.items():
        relative=PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError('Unsafe release member')
        if any(word in name.lower() for word in ['rbs-format-key','activation','/private/','/profiles/','/assets/','.rbe','.rbs']):
            raise ValueError('Private or restricted release member')
    output.parent.mkdir(parents=True,exist_ok=True)
    payload={name:path.read_bytes() for name,path in package.items()}
    if compatibility is not None:payload['COMPATIBILITY.json']=(json.dumps(compatibility,indent=2)+'\n').encode()
    manifest={name:hashlib.sha256(content).hexdigest() for name,content in sorted(payload.items())}
    payload['SOURCE_MANIFEST.json']=(json.dumps(manifest,indent=2)+'\n').encode()
    with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED) as bundle:
        for name,content in sorted(payload.items()):
            info=zipfile.ZipInfo('sketchup-adapter/'+name,(2026,11,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED
            bundle.writestr(info,content)
    with zipfile.ZipFile(output) as bundle:
        assert bundle.testzip() is None
        for name,value in manifest.items():assert hashlib.sha256(bundle.read('sketchup-adapter/'+name)).hexdigest()==value
    return dict(archive=str(output),sha256=hashlib.sha256(output.read_bytes()).hexdigest(),files=len(payload),
        restricted_avatar_assets_included=False,plugin_packages_included=False,private_profiles_included=False)
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path)
    args=parser.parse_args();root=Path(__file__).resolve().parent
    report=root/'verification/public-compatibility.json'
    if not report.is_file():report=root/'COMPATIBILITY.json'
    data=json.loads(report.read_text()) if report.is_file() else None
    print(json.dumps(build_release(root,args.output or root/'dist/sketchup-adapter-0.1.0-experimental.zip',data),indent=2))
