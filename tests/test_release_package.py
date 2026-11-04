import json,tempfile,unittest,zipfile
import hashlib
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from build_release import build_release
class ReleasePackageTests(unittest.TestCase):
    def fixture(self,root):
        (root/'sketchup_adapter').mkdir();(root/'sketchup_adapter/__init__.py').write_text('# public')
        (root/'public_files.json').write_text(json.dumps({'runtime':['sketchup_adapter/__init__.py']}))
        for name in ['LICENSE','install.py','PUBLIC_README.md','build_release.py']:(root/name).write_text('# authored fixture')
    def test_source_archive_excludes_private_and_restricted_data_and_roundtrips_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.fixture(root)
            for name in ['sketchup_adapter/native_walk/assets/Idle.bin.gz','verification/private/plugin.rb',
                         'sketchup_adapter/rbs-format-key.bin','profile/registry.json','activation.rbz']:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('private sentinel')
            result=build_release(root,root/'out.zip',{'status':'fixture'})
            with zipfile.ZipFile(result['archive']) as bundle:
                names=bundle.namelist();assert not any('private sentinel' in bundle.read(n).decode() for n in names)
                self.assertIn('sketchup-adapter/COMPATIBILITY.json',names)
                self.assertIn('sketchup-adapter/SOURCE_MANIFEST.json',names)
            self.assertFalse(result['private_profiles_included'])
    def test_unreviewed_runtime_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.fixture(root);(root/'sketchup_adapter/unreviewed.py').write_text('# not approved')
            with self.assertRaisesRegex(ValueError,'inventory'):build_release(root,root/'out.zip')
    def test_repeat_build_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);self.fixture(root)
            first=build_release(root,root/'a.zip');second=build_release(root,root/'b.zip')
            self.assertEqual(first['sha256'],second['sha256'])
    def test_clean_archive_installs_to_an_empty_profile_and_handles_missing_optional_assets(self):
        import importlib.util
        from install import install
        from sketchup_adapter.registry import Registry
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);archive=directory/'release.zip'
            build_release(root,archive,{'status':'authored install fixture'})
            with zipfile.ZipFile(archive) as bundle:bundle.extractall(directory/'unpacked')
            source=directory/'unpacked/sketchup-adapter'
            profile=directory/'profile'
            receipt=install(source,plugin_root=directory/'plugins',registry_root=profile,example=False)
            self.assertEqual({},Registry(profile).plugins)
            spec=importlib.util.spec_from_file_location('public_installer_smoke',receipt['installed'])
            loader=importlib.util.module_from_spec(spec);spec.loader.exec_module(loader)
            self.assertEqual('0.1.0',loader._MODULE.__version__)
            spec=importlib.util.spec_from_file_location('public_optional_service',source/'sketchup_adapter/services.py')
            service=importlib.util.module_from_spec(spec);spec.loader.exec_module(service)
            result=service.call(None,{'fn':'native_walkthrough'})
            self.assertFalse(result['ok']);self.assertIn('optional',result['error'])
    def test_install_backups_and_receipt_cover_all_existing_files(self):
        from install import install
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);profile=directory/'profile';profile.mkdir()
            target=directory/'plugins/sketchup_adapter/__init__.py';target.parent.mkdir(parents=True)
            original={'loader':b'# old loader\r\n',
                      'registry':b'{"schema":1,"settings":{"ruby":"custom"},"plugins":[]}\n',
                      'installation':b'{"old":"receipt"}\n'}
            target.write_bytes(original['loader']);(profile/'registry.json').write_bytes(original['registry'])
            (profile/'installation.json').write_bytes(original['installation'])
            result=install(root,plugin_root=directory/'plugins',registry_root=profile,example=False)
            saved=json.loads(Path(result['backup_receipt']).read_text())
            self.assertEqual('completed',saved['status'])
            for name,data in original.items():
                item=saved['files'][name]
                self.assertTrue(item['before_exists'])
                self.assertEqual(data,Path(item['backup']).read_bytes())
                self.assertEqual(hashlib.sha256(data).hexdigest(),item['before_sha256'])
                self.assertEqual(hashlib.sha256(Path(item['path']).read_bytes()).hexdigest(),item['after_sha256'])
            self.assertEqual(original['registry'],(profile/'registry.json').read_bytes())

    def test_missing_source_or_source_target_alias_leaves_existing_install_untouched(self):
        from install import install
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);profile=directory/'profile';profile.mkdir()
            target=directory/'plugins/sketchup_adapter/__init__.py';target.parent.mkdir(parents=True)
            target.write_bytes(b'original loader')
            with self.assertRaisesRegex(ValueError,'missing'):
                install(directory/'missing',plugin_root=directory/'plugins',registry_root=profile,example=False)
            with self.assertRaisesRegex(ValueError,'overwrite'):
                install(directory/'plugins',plugin_root=directory/'plugins',registry_root=profile,example=False)
            self.assertEqual(b'original loader',target.read_bytes())
            self.assertFalse((profile/'backups').exists())

    def test_failed_example_registration_restores_exact_previous_files(self):
        from install import install
        from unittest.mock import patch
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);profile=directory/'profile';profile.mkdir()
            target=directory/'plugins/sketchup_adapter/__init__.py';target.parent.mkdir(parents=True)
            original={target:b'# old loader\n',profile/'registry.json':b'{"schema":1,"settings":{},"plugins":[]}\n',
                      profile/'installation.json':b'{"old":true}\n'}
            for path,data in original.items():path.write_bytes(data)
            with patch('install.Registry.enable',side_effect=RuntimeError('injected failure')):
                with self.assertRaisesRegex(RuntimeError,'injected failure'):
                    install(root,plugin_root=directory/'plugins',registry_root=profile,example=True)
            for path,data in original.items():self.assertEqual(data,path.read_bytes())
            receipt=next((profile/'backups').glob('*/receipt.json'))
            self.assertEqual('rolled_back',json.loads(receipt.read_text())['status'])

    def test_incomplete_runtime_inventory_is_rejected_before_installation(self):
        from install import install
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);source=directory/'source';(source/'sketchup_adapter').mkdir(parents=True)
            (source/'sketchup_adapter/__init__.py').write_text('# loader')
            (source/'public_files.json').write_text(json.dumps({'runtime':['sketchup_adapter/__init__.py',
                                                                           'sketchup_adapter/missing.py']}))
            profile=directory/'profile';profile.mkdir()
            target=directory/'plugins/sketchup_adapter/__init__.py';target.parent.mkdir(parents=True)
            target.write_bytes(b'original loader')
            with self.assertRaisesRegex(ValueError,'missing or invalid'):
                install(source,plugin_root=directory/'plugins',registry_root=profile,example=False)
            self.assertEqual(b'original loader',target.read_bytes())
            self.assertFalse((profile/'backups').exists())

    def test_receipt_write_failure_rolls_back_loader_and_registry(self):
        import install as installer
        from unittest.mock import patch
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);profile=directory/'profile';profile.mkdir()
            target=directory/'plugins/sketchup_adapter/__init__.py';target.parent.mkdir(parents=True)
            original={target:b'# old loader\n',profile/'registry.json':b'{"schema":1,"settings":{},"plugins":[]}\n',
                      profile/'installation.json':b'{"old":true}\n'}
            for path,data in original.items():path.write_bytes(data)
            real_atomic_json=installer.atomic_json
            def fail_installation(path,value):
                if path==profile/'installation.json':raise OSError('injected receipt failure')
                return real_atomic_json(path,value)
            with patch('install.atomic_json',side_effect=fail_installation):
                with self.assertRaisesRegex(OSError,'injected receipt failure'):
                    installer.install(root,plugin_root=directory/'plugins',registry_root=profile,example=True)
            for path,data in original.items():self.assertEqual(data,path.read_bytes())
            receipt=next((profile/'backups').glob('*/receipt.json'))
            self.assertEqual('rolled_back',json.loads(receipt.read_text())['status'])
if __name__=='__main__':unittest.main()
