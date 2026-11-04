"""Portable async reset/ordering checks; no Qt, vendor plugins or live app.

Run with python tests/portable_async_recovery_contracts.py. Native integration
and an actual Ruby synchronous-call test still provide necessary coverage.
"""
from collections import deque
from pathlib import Path
from types import SimpleNamespace,ModuleType
from unittest.mock import patch
import importlib
import json
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
class QObject:
    def __init__(self,*args):pass
class Signal:
    def __init__(self,*args):pass
    def connect(self,*args):pass
    def emit(self,*args):pass
qt=ModuleType('PySide6');core=ModuleType('PySide6.QtCore')
core.QObject=QObject;core.Signal=Signal
sys.modules.update({'PySide6':qt,'PySide6.QtCore':core})
async_module=importlib.import_module('sketchup_adapter.async_geometry')
geometry=importlib.import_module('sketchup_adapter.prepare_geometry')

class Activity:
    def __init__(self):self.events=[]
    def tool(self,*a):self.events.append(('tool',a))
    def clear(self):self.events.append(('clear',))
    def update(self,*a):self.events.append(('update',a))
class Worker:
    def __init__(self):self.killed=False
    def kill(self):self.killed=True

class AsyncRecoveryContracts(unittest.TestCase):
    def setUp(self):
        self.messages=[];self.failures=[];self.drains=[];self.tokens=[]
        scene=SimpleNamespace(loose_mesh=object())
        window=SimpleNamespace(_activate_tool=lambda name:None)
        self.host=SimpleNamespace(app=SimpleNamespace(scene=scene,window=window,viewport=SimpleNamespace()),
          _inbox=[],_batch=[],_sync_depth=0,_prepared_groups={},_managed_guides={},
          _native_history_key=None,_native_live_uids=None,group_of_rid={},rid_of_uid={},
          _edge_targets={},_surface_targets={},_face_tokens={},_surface_fragments={},
          _pick_snapshots_sent=set(),_last_sel_key=None,_overlay_primitives=[],
          _extension_tool=None,_extension_tool_id=None,activity=Activity(),_placing=None,
          _document_reset_waiting=False,_outgoing=SimpleNamespace(queue=[]),
          proc=Worker(),
          send=self.messages.append,_geometry_failure=lambda e:self.failures.append(str(e)),
          _on_stdout_drain=lambda:self.drains.append(True))
        q=object.__new__(async_module.PreparationQueue);self.q=q;q.host=self.host
        q.document=(scene,scene.loose_mesh);q.generation=0;q.raw=deque()
        q.decoding=False;q.preparing=False;q.closed=False;q._decode_token=None;q._geometry_token=None
        q.codec=SimpleNamespace(decode=lambda data:data);q.progress=Signal()
        q._submit=lambda token,*args:self.tokens.append(token)
    def message(self):return {'op':'upsert','rid':1,'payload':{'protos':[{'faces':[[] for _ in range(128)]}]}}
    def pending_call(self):
        self.host._inbox.append({'op':'call','id':123,'fn':'messagebox'})
        self.host._batch.append({'op':'surface_patch','token':'old'})
    def assert_reset(self):
        self.assertTrue(self.host._document_reset_waiting)
        self.assertEqual(1,self.q.generation)
        self.assertEqual([],self.host._batch);self.assertEqual([],self.host._inbox)
        self.assertEqual(1,sum(m.get('op')=='reply' and m.get('id')==123 for m in self.messages))
        self.assertEqual(1,sum(m.get('op')=='document_reset' for m in self.messages))
        self.assertTrue(self.failures)
    def test_submit_failure_resets_and_replies_to_pending_call(self):
        self.pending_call();self.q._submit=lambda *a:(_ for _ in ()).throw(RuntimeError('submit'))
        self.assertTrue(self.q.prepare(self.message()));self.assertFalse(self.q.preparing);self.assert_reset()
    def test_malformed_payload_resets_and_replies(self):
        self.pending_call();self.assertTrue(self.q.prepare({'op':'upsert','payload':{'protos':[None]}}))
        self.assertFalse(self.q.preparing);self.assert_reset()
    def test_worker_error_resets_and_discards_pending_batch(self):
        self.pending_call();self.assertTrue(self.q.prepare(self.message()));token=self.tokens[-1]
        self.q._complete(token,None,RuntimeError('worker'))
        self.assertFalse(self.q.preparing);self.assert_reset()
    def test_install_error_resets_and_discards_pending_batch(self):
        self.pending_call();self.assertTrue(self.q.prepare(self.message()));token=self.tokens[-1]
        with patch.object(geometry,'install',side_effect=RuntimeError('install')):
            self.q._complete(token,object(),None)
        self.assertFalse(self.q.preparing);self.assert_reset()
    def test_stale_geometry_completion_does_not_release_new_worker(self):
        def after_submit(token,*args):self.tokens.append(token);raise RuntimeError('after submit')
        self.q._submit=after_submit;self.assertTrue(self.q.prepare(self.message()));old=self.tokens[-1]
        self.assertFalse(self.q.preparing);self.host._document_reset_waiting=False
        self.q._submit=lambda token,*args:self.tokens.append(token)
        self.assertTrue(self.q.prepare(self.message()));new=self.tokens[-1]
        self.q._complete(old,object(),None)
        self.assertTrue(self.q.preparing);self.assertIs(new,self.q._geometry_token)
        self.q._complete(new,None,RuntimeError('new failure'));self.assertFalse(self.q.preparing)
    def test_decode_submit_failure_resets_and_replies(self):
        self.pending_call();self.q._submit=lambda *a:(_ for _ in ()).throw(RuntimeError('decode submit'))
        self.q.receive(b' '*262145);self.assertFalse(self.q.decoding);self.assert_reset()
    def test_decode_worker_error_resets_and_replies(self):
        self.pending_call();self.q.receive(b' '*262145);token=self.tokens[-1]
        self.q._complete(token,None,RuntimeError('decode worker'))
        self.assertFalse(self.q.decoding);self.assert_reset()
    def test_stale_decode_completion_does_not_release_new_decode(self):
        def after_submit(token,*args):self.tokens.append(token);raise RuntimeError('after submit')
        self.q._submit=after_submit;self.q.receive(b' '*262145);old=self.tokens[-1]
        self.host._document_reset_waiting=False;self.q._submit=lambda token,*args:self.tokens.append(token)
        self.q.receive(b' '*262145);new=self.tokens[-1]
        self.q._complete(old,{'op':'old'},None)
        self.assertTrue(self.q.decoding);self.assertIs(new,self.q._decode_token)
        self.assertNotIn({'op':'old'},self.host._inbox)
    def test_reset_invalidates_old_success_without_installing(self):
        self.assertTrue(self.q.prepare(self.message()));old=self.tokens[-1]
        self.q.document_changed(force=True)
        with patch.object(geometry,'install') as install:self.q._complete(old,object(),None)
        install.assert_not_called();self.assertFalse(self.q.preparing)
    def test_success_preserves_exact_message_for_ordered_dispatch(self):
        msg=self.message();self.assertTrue(self.q.prepare(msg));token=self.tokens[-1]
        group=object()
        with patch.object(geometry,'install',return_value=group):self.q._complete(token,object(),None)
        self.assertFalse(self.q.preparing);self.assertEqual([msg],self.host._inbox)
        self.assertIs(group,self.host._prepared_groups[id(msg)])
        self.assertFalse(self.failures)
    def decode_fails_with(self,raw):
        self.q._submit=lambda *a:(_ for _ in ()).throw(RuntimeError('codec failure'))
        self.q.receive(raw)
    def test_large_real_call_gets_exactly_one_reply(self):
        raw=json.dumps({'op':'call','id':77,'padding':'x'*262145}).encode()
        self.decode_fails_with(raw)
        self.assertEqual([77],[m['id'] for m in self.messages if m.get('op')=='reply'])
        self.assertEqual(1,sum(m.get('op')=='document_reset' for m in self.messages))
        self.assertFalse(self.host.proc.killed)
    def test_nested_call_is_not_a_top_level_call(self):
        raw=json.dumps({'op':'upsert','payload':{'op':'call','id':77},'padding':'x'*262145}).encode()
        self.decode_fails_with(raw)
        self.assertFalse(any(m.get('op')=='reply' for m in self.messages))
        self.assertFalse(self.host.proc.killed)
    def test_unidentifiable_frames_stop_only_the_owned_worker(self):
        invalid=[b'{"op":"call","id":77,"id":78,"pad":"'+b'x'*262145+b'"}',
                 b'{"op":"call","id":true,"pad":"'+b'x'*262145+b'"}',
                 b'{"op":"call","id":77,"value":NaN,"pad":"'+b'x'*262145+b'"}',
                 b'{"op":"call","id":77,"value":1e999,"pad":"'+b'x'*262145+b'"}',
                 b'['+b' '*262145+b']',b' '* (16*1024*1024+1)]
        for raw in invalid:
            with self.subTest(prefix=raw[:40]):
                self.setUp();worker=self.host.proc;self.decode_fails_with(raw)
                self.assertTrue(worker.killed)
                self.assertFalse(any(m.get('op')=='reply' for m in self.messages))
    def test_failure_during_existing_reset_replies_without_a_second_reset(self):
        raw=json.dumps({'op':'call','id':77,'padding':'x'*262145}).encode()
        self.q.receive(raw);token=self.tokens[-1]
        self.q.document_changed(force=True)
        self.q._complete(token,None,RuntimeError('codec failure'))
        self.assertEqual([77],[m['id'] for m in self.messages if m.get('op')=='reply'])
        self.assertEqual(1,sum(m.get('op')=='document_reset' for m in self.messages))
        self.assertTrue(self.host._document_reset_waiting);self.assertFalse(self.host.proc.killed)
    def test_failed_old_frame_cannot_kill_a_replacement_worker(self):
        raw=b'['+b' '*262145+b']';self.q.receive(raw);token=self.tokens[-1]
        old=self.host.proc;self.host.proc=Worker()
        self.q._complete(token,None,RuntimeError('old codec failure'))
        self.assertFalse(old.killed);self.assertFalse(self.host.proc.killed)
        self.assertFalse(self.messages)

if __name__=='__main__':unittest.main()
