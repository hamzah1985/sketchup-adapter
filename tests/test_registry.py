import tempfile,unittest,zipfile
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sketchup_adapter.registry import Registry


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.registry=Registry(self.root/'profile')
    def tearDown(self):self.tmp.cleanup()
    def archive(self,entries):
        path=self.root/'test.rbz'
        with zipfile.ZipFile(path,'w') as bundle:
            for name,value in entries:bundle.writestr(name,value)
        return path
    def folder(self):
        path=self.root/'source';path.mkdir()
        (path/'library.rb').write_text('module FixtureLibrary; end')
        (path/'tool.rb').write_text("require 'library.rb'")
        return path
    def test_rbzs_install_disabled_and_idempotently(self):
        path=self.archive([('tool.rb','puts :hello'),('tool/file.rbs','RBS1.0')])
        plugin=self.registry.install_rbz(path)
        self.assertFalse(plugin.enabled)
        self.assertIn('file.rbs',plugin.inspection['encrypted_files'][0])
        self.assertEqual(self.registry.install_rbz(path).id,plugin.id)
        self.assertEqual(len(self.registry.plugins),1)
    def test_traversal_absolute_and_windows_paths_rejected(self):
        for name in ('../escape.rb','/escape.rb','C:/escape.rb','folder/../escape.rb','NUL.rb','folder./evil.rb'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                self.registry.install_rbz(self.archive([('loader.rb',''),(name,'')]))
        self.assertFalse((self.root/'escape.rb').exists())
    def test_case_and_slash_collisions_rejected(self):
        for first,second in [('A.rb','a.rb'),('data/a.txt','data\\a.txt')]:
            with self.subTest(first=first),self.assertRaises(ValueError):
                self.registry.install_rbz(self.archive([(first,''),(second,'')]))
    def test_missing_root_loader_rejected(self):
        with self.assertRaises(ValueError):
            self.registry.install_rbz(self.archive([('nested/tool.rb','')]))
    def test_folder_discovery_does_not_enable_or_modify_source(self):
        source=self.folder();before={p.name:p.read_bytes() for p in source.iterdir()}
        items=self.registry.register_folder(source)
        self.assertEqual(len(items),2)
        self.assertTrue(all(not p.enabled for p in items))
        self.assertEqual(before,{p.name:p.read_bytes() for p in source.iterdir()})
        self.assertEqual(self.registry.runtime_config()['plugins'],[])
    def test_dependencies_load_before_dependent(self):
        items=self.registry.register_folder(self.folder())
        library,tool=items
        tool.dependencies=[library.id]
        with self.assertRaises(ValueError):self.registry.enable(tool.id)
        self.registry.enable(tool.id,with_dependencies=True)
        config=self.registry.runtime_config()
        self.assertEqual([p['id'] for p in config['plugins']],[library.id,tool.id])
        self.assertEqual(len(config['roots']),1)
        with self.assertRaises(ValueError):self.registry.enable(library.id,False)
    def test_cycle_rolls_back_enable(self):
        first,second=self.registry.register_folder(self.folder())
        first.dependencies=[second.id];second.dependencies=[first.id]
        with self.assertRaises(ValueError):self.registry.enable(first.id,with_dependencies=True)
        self.assertFalse(first.enabled);self.assertFalse(second.enabled)
    def test_registry_roundtrip(self):
        items=self.registry.register_folder(self.folder())
        self.registry.enable(items[0].id)
        loaded=Registry(self.registry.root)
        self.assertEqual(loaded.runtime_config(),self.registry.runtime_config())


if __name__=='__main__':unittest.main(verbosity=2)
