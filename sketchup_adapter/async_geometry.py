"""Ordered decoding/preparation without blocking the GUI or splitting undo."""
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import json
import math
from PySide6.QtCore import QObject,Signal


class PreparationQueue(QObject):
    completed=Signal(object,object,object)
    progress=Signal(object,object)

    def __init__(self,host):
        super().__init__(host)
        self.host=host
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='Bogdan geometry')
        from .codec import Codec
        self.codec=Codec()
        self.raw=deque();self.decoding=False;self.preparing=False;self.closed=False
        self._decode_token=None;self._geometry_token=None
        self.document=(host.app.scene,host.app.scene.loose_mesh)
        self.generation=0
        self.completed.connect(self._complete)
        self.progress.connect(self._progress)
        host.app.window.destroyed.connect(self.close)

    def close(self,*_):
        self.closed=True;self.raw.clear();self.generation+=1
        self.pool.shutdown(wait=False,cancel_futures=True)
        self.codec.close()

    def document_changed(self, force=False):
        current=(self.host.app.scene,self.host.app.scene.loose_mesh)
        if not force and current[0] is self.document[0] and current[1] is self.document[1]:return False
        self.document=current;self.generation+=1
        # A decoded synchronous Ruby service call may be queued behind a
        # rejected edit. Ruby cannot consume the reset until it gets a reply.
        pending_calls=[msg.get('id') for msg in self.host._inbox
                       if isinstance(msg,dict) and msg.get('op') == 'call' and msg.get('id') is not None]
        self.host._batch.clear();self.host._inbox.clear();self.host._sync_depth=0
        self.host._prepared_groups.clear()
        self.host._managed_guides={}
        self.host._native_history_key=None
        self.host._native_live_uids=None
        self.host.group_of_rid.clear();self.host.rid_of_uid.clear()
        self.host._edge_targets={};self.host._surface_targets={};self.host._face_tokens={}
        self.host._surface_fragments={}
        getattr(self.host,'_pick_snapshots_sent',set()).clear();self.host._last_sel_key=None
        self.host._overlay_primitives=[]
        self.host._extension_tool=None;self.host._extension_tool_id=None
        self.host.activity.tool();self.host.activity.clear()
        self.host._placing=None
        self.host._document_reset_waiting=True
        self.host._outgoing.queue.clear()
        for call_id in pending_calls:
            self.host.send({'op':'reply','id':call_id,'value':None})
        activate=getattr(self.host.app.window,'_activate_tool',None)
        if callable(activate):activate('select')
        self.host.send({'op':'document_reset'})
        return True

    def _submit(self,token,function,*args):
        future=self.pool.submit(function,*args)
        def done(result):
            try:value,error=result.result(),None
            except Exception as exc:value,error=None,exc
            if self.closed:return
            try:self.completed.emit(token,value,error)
            except RuntimeError:pass  # the owning window was closed
        future.add_done_callback(done)

    def receive(self,line):
        self.raw.append(line);self.decode()

    def _decode_failure(self,raw,error,worker):
        # Ruby may be blocked waiting for the reply to this very frame. Recover
        # only a strictly parsed top-level call ID; never guess from raw text.
        if getattr(self.host,'proc',None) is not worker:return
        safe=True;identifier=None
        try:
            if len(raw)>16*1024*1024:raise ValueError('Failed frame exceeds recovery limit')
            def pairs(items):
                result={}
                for key,value in items:
                    if key in result:raise ValueError('Duplicate JSON key')
                    result[key]=value
                return result
            def constant(_value):raise ValueError('Non-finite JSON number')
            def finite_float(value):
                number=float(value)
                if not math.isfinite(number):raise ValueError('Non-finite JSON number')
                return number
            message=json.loads(raw,object_pairs_hook=pairs,parse_constant=constant,parse_float=finite_float)
            if not isinstance(message,dict) or not isinstance(message.get('op'),str):
                raise ValueError('Invalid protocol frame')
            if message['op']=='call':
                identifier=message.get('id')
                if isinstance(identifier,bool) or not isinstance(identifier,int) or identifier<=0:
                    raise ValueError('Invalid synchronous call identifier')
        except Exception:
            safe=False
        waiting=self.host._document_reset_waiting
        if safe and identifier is not None:
            if waiting:
                # The already queued reset cannot be processed until this
                # call returns. Do not queue a second uncorrelated reset.
                self.host._inbox[:]=[msg for msg in self.host._inbox if not
                    (isinstance(msg,dict) and msg.get('op')=='call' and msg.get('id')==identifier)]
                self.host.send({'op':'reply','id':identifier,'value':None})
            elif not any(isinstance(msg,dict) and msg.get('op')=='call' and msg.get('id')==identifier
                         for msg in self.host._inbox):
                self.host._inbox.append(message)
        if not waiting:self.document_changed(force=True)
        if safe:
            self.host._geometry_failure(error)
        else:
            # An unidentifiable frame could be a blocked call; only terminate
            # this adapter-owned worker. Native model edits are not touched.
            self.raw.clear()
            self.host._geometry_failure(RuntimeError('Extension frame could not be recovered; restart IngeTrazo.'))
            if worker is not None:
                try:worker.kill()
                except Exception:pass

    def decode(self):
        if self.decoding or self.closed:return
        while self.raw:
            raw=self.raw.popleft()
            if len(raw)>256*1024:
                self.host.activity.update('decoding')
                self.decoding=True
                token=('decode',self.generation,raw,getattr(self.host,'proc',None));self._decode_token=token
                try:self._submit(token,self.codec.decode,raw)
                except Exception as error:
                    self.decoding=False;self._decode_token=None
                    self._decode_failure(raw,error,token[3])
                    continue
                return
            try:self.host._inbox.append(json.loads(raw))
            except (ValueError,UnicodeError):continue
        self.host._on_stdout_drain()

    def prepare(self,message):
        try:
            if id(message) in self.host._prepared_groups or message.get('op') not in ('place','upsert'):return False
            if self.host._document_reset_waiting:return False
            payload=message.get('payload') or {}
            if sum(len(p.get('faces',())) for p in payload.get('protos',()))<128:return False
            from .prepare_geometry import prepare
            self.preparing=True
            generation=self.generation
            def report(*args):
                if not self.closed:self.progress.emit(generation,args)
            token=('geometry',generation,message);self._geometry_token=token
            self._submit(token,prepare,payload,type(self.host.app.viewport),report)
        except Exception as error:
            self.preparing=False;self._geometry_token=None
            self.document_changed(force=True)
            self.host._geometry_failure(error)
            return True
        return True

    def _progress(self,generation,args):
        self.document_changed()
        if generation==self.generation and not self.closed and not self.host._document_reset_waiting:
            self.host.activity.update(*args)

    def _complete(self,token,value,error):
        if self.closed:return
        kind,generation=token[:2]
        self.document_changed()
        if kind=='decode':
            if token is not self._decode_token:return
            self._decode_token=None
            self.decoding=False
            # Decode messages after a reset too: synchronous Ruby calls still
            # need replies so that the worker can reach its reset acknowledgement.
            if error is None:
                if generation==self.generation:self.host._inbox.append(value)
                elif (getattr(self.host,'proc',None) is token[3] and isinstance(value,dict)
                      and value.get('op')=='call' and isinstance(value.get('id'),int)
                      and not isinstance(value.get('id'),bool) and value['id']>0):
                    self.host.send({'op':'reply','id':value['id'],'value':None})
            else:
                self._decode_failure(token[2],error,token[3])
            self.decode();self.host._on_stdout_drain();return
        if token is not self._geometry_token:return
        self._geometry_token=None;self.preparing=False
        if generation==self.generation and not self.host._document_reset_waiting:
            if error is None:
                try:
                    from .prepare_geometry import install
                    message=token[2];self.host._prepared_groups[id(message)]=install(self.host.app.viewport,value)
                    self.host._inbox.insert(0,message)
                except Exception as failure:
                    self.document_changed(force=True)
                    self.host._geometry_failure(failure)
            else:
                self.document_changed(force=True)
                self.host._geometry_failure(error)
        self.host._on_stdout_drain()
