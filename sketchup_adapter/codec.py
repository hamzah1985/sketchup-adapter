"""Keep whole-document C JSON parsing outside the GUI process's GIL."""
import pickle,struct,subprocess,threading
from pathlib import Path

class Codec:
    def __init__(self):self.process=None;self.lock=threading.Lock()
    def _read(self,size):
        data=bytearray()
        while len(data)<size:
            part=self.process.stdout.read(size-len(data))
            if not part:raise RuntimeError('The private JSON codec exited unexpectedly')
            data.extend(part)
        return bytes(data)
    def _exchange(self,operation,payload):
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                from . import _python_exe
                self.process=subprocess.Popen([_python_exe(),'-u',str(Path(__file__).with_name('codec_worker.py'))],
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            self.process.stdin.write(operation+struct.pack('<Q',len(payload)));self.process.stdin.write(payload);self.process.stdin.flush()
            status=self._read(1);size=struct.unpack('<Q',self._read(8))[0];result=self._read(size)
            if status!=b'Y':raise ValueError(result.decode('utf-8','replace'))
            return result
    def decode(self,raw):return pickle.loads(self._exchange(b'D',raw))
    def encode(self,message):return self._exchange(b'E',pickle.dumps(message,protocol=4))
    def close(self):
        process=self.process
        if process is not None:
            try:process.stdin.close()
            except OSError:pass
            try:process.wait(timeout=1)
            except subprocess.TimeoutExpired:process.terminate()
