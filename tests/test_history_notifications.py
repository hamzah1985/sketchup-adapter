"""Native history notifications reflect actual commits, undo and redo."""
import unittest
from types import SimpleNamespace
from sketchup_adapter.history_sync import sync


class NativeHistoryNotifications(unittest.TestCase):
    def setUp(self):
        self.history=SimpleNamespace(undo_stack=[],redo_stack=[])
        self.scene=SimpleNamespace(groups=[],guides=[])
        self.messages=[]
        self.host=SimpleNamespace(app=SimpleNamespace(viewport=SimpleNamespace(history=self.history),scene=self.scene),
            rid_of_uid={},group_of_rid={},send=self.messages.append)
        sync(self.host)
        self.messages.clear()
    def test_commit_add_delete_and_undo_are_reported_once(self):
        group=SimpleNamespace(uid='one',children=[],xform=None,hidden=False)
        self.scene.groups.append(group)
        command=SimpleNamespace()
        self.history.undo_stack.append(command)
        sync(self.host);sync(self.host)
        self.assertEqual(1,len(self.messages))
        self.assertEqual('commit',self.messages[-1]['event'])
        self.assertEqual(['one'],self.messages[-1]['added_uids'])
        self.scene.groups.clear();self.history.undo_stack.pop();self.history.redo_stack.append(command)
        sync(self.host)
        self.assertEqual('undo',self.messages[-1]['event'])
        self.assertEqual([],self.messages[-1]['live_uids'])
        self.scene.groups.append(group);self.history.redo_stack.pop();self.history.undo_stack.append(command)
        sync(self.host)
        self.assertEqual('redo',self.messages[-1]['event'])
    def test_adapter_generated_history_does_not_duplicate_ruby_commit(self):
        self.history.undo_stack.append(SimpleNamespace(_sketchup_adapter_edit=True))
        sync(self.host)
        self.assertIsNone(self.messages[-1]['event'])
    def test_known_native_groups_are_updated_without_a_history_event(self):
        group=SimpleNamespace(uid='one',children=[],xform=None,hidden=False)
        self.scene.groups.append(group);sync(self.host)
        self.history.undo_stack.append(SimpleNamespace())
        sync(self.host)
        self.assertEqual([],self.messages[-1]['added_uids'])


if __name__=='__main__': unittest.main()
