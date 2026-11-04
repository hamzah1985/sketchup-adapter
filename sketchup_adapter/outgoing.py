"""Ordered selection snapshots and bounded JSON encoding off the GUI thread."""
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import json
from PySide6.QtCore import QObject,Signal,QTimer


class OutgoingQueue(QObject):
    completed=Signal(object,object,object)
    def __init__(self,host):
        super().__init__(host);self.host=host;self.queue=deque();self.running=False;self.closed=False
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix='Bogdan snapshots')
        from .codec import Codec
        self.codec=Codec()
        self.completed.connect(self._complete);host.app.window.destroyed.connect(self.close)

    def close(self,*_):
        self.closed=True;self.queue.clear();self.pool.shutdown(wait=False,cancel_futures=True)
        self.codec.close()

    def send(self,message):
        if self.closed:return
        if message.get('op')=='reply':
            self.host._write_message((json.dumps(message)+'\n').encode('utf-8'));return
        self.queue.append(message);self.drain()

    def drain(self):
        if self.closed or self.running:return
        while self.queue:
            message=self.queue[0]
            if any('_group_reference' in item for item in message.get('items',())) or '_pick_group_reference' in (message.get('input') or {}):
                scene=self.host.app.scene
                token=(message,scene,scene.loose_mesh,scene.version)
                recipes=dict(scene.plugin_data.get(self.host._data_key,{}))
                self.running=True
                from .snapshot import selection_message
                future=self.pool.submit(lambda:self.codec.encode(selection_message(message,recipes)))
                def done(future):
                    try:value,error=future.result(),None
                    except Exception as exc:value,error=None,exc
                    if self.closed:return
                    try:self.completed.emit(token,value,error)
                    except RuntimeError:pass
                future.add_done_callback(done);return
            self.queue.popleft()
            self.host._write_message((json.dumps(message,separators=(',',':'))+'\n').encode('utf-8'))

    def _complete(self,token,value,error):
        if self.closed:return
        self.running=False
        message,scene,mesh,version=token
        if not self.queue or self.queue[0] is not message:return self.drain()
        current=self.host.app.scene
        if current is not scene or current.loose_mesh is not mesh:
            self.queue.popleft();self.drain();return
        if current.version!=version:
            from core.purge import iter_groups
            groups={g.uid:g for g in iter_groups(current.groups)}
            if 'items' in message:
                message['items']=[item for item in message['items'] if '_group_reference' not in item or item['_group_reference'].uid in groups]
            for item in message.get('items',()):
                if '_group_reference' in item:
                    group=groups[item['_group_reference'].uid]
                    item['_group_reference']=group
                    item['xform']=list(group.xform.data()) if group.xform is not None else None
                    item['hidden']=bool(group.hidden)
            data=message.get('input') or {}
            if '_pick_group_reference' in data:
                group=groups.get(data['_pick_group_reference'].uid)
                if group is None:
                    self.queue.popleft();self.host._pick_snapshots_sent.clear();self.drain();return
                data['_pick_group_reference']=group
            # Never send a snapshot assembled across an edit. Retry after the
            # GUI operation finishes, retaining message/command FIFO order.
            QTimer.singleShot(20,self.drain);return
        self.queue.popleft()
        if error is not None:
            # A command queued behind this selection must never run against
            # the preceding selection after a failed snapshot.
            self.queue.clear();self.host._last_sel_key=None
            self.host._pick_snapshots_sent.clear()
            self.host._geometry_failure(error)
        else:self.host._write_message(value)
        self.drain()
