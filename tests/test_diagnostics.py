import json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from sketchup_adapter.diagnostics import Diagnostics

class DiagnosticsTests(unittest.TestCase):
    def test_locked_session_file_does_not_lose_ready_and_next_record_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostics=Diagnostics(Path(directory)/'diagnostics')
            with patch('sketchup_adapter.diagnostics.atomic_json',side_effect=PermissionError('file locked')):
                with self.assertLogs('sketchup_adapter.diagnostics',level='WARNING'):
                    diagnostics.record({'op':'extension_loaded','plugin_id':'qa','status':'loaded'})
                    diagnostics.record({'op':'ready'})
            self.assertTrue(diagnostics.ready)
            self.assertEqual(diagnostics.results['qa']['status'],'loaded')
            self.assertEqual(len(diagnostics.events),2)
            self.assertIsNotNone(diagnostics.write_error)
            diagnostics.record({'op':'warning','message':'writer available again'})
            saved=json.loads((diagnostics.root/'last-session.json').read_text())
            self.assertTrue(saved['ready'])
            self.assertEqual(len(saved['events']),3)
            self.assertIsNone(diagnostics.write_error)

    def test_unavailable_directory_does_not_discard_protocol_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'occupied';path.write_text('not a directory')
            diagnostics=Diagnostics(path)
            with self.assertLogs('sketchup_adapter.diagnostics',level='WARNING'):
                diagnostics.record({'op':'ready'})
            self.assertTrue(diagnostics.ready)
            self.assertEqual(diagnostics.events[-1]['op'],'ready')

if __name__=='__main__':unittest.main()
