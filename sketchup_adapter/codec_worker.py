"""Private length-framed JSON codec. No model/app access and no networking."""
import json,pickle,struct,sys
source=sys.stdin.buffer;target=sys.stdout.buffer
def read(size):
    out=bytearray()
    while len(out)<size:
        data=source.read(size-len(out))
        if not data:raise EOFError
        out.extend(data)
    return bytes(out)
while True:
    try:
        operation=read(1);size=struct.unpack('<Q',read(8))[0];payload=read(size)
    except EOFError:break
    try:
        if operation==b'D':result=pickle.dumps(json.loads(payload),protocol=4)
        elif operation==b'E':result=(json.dumps(pickle.loads(payload),separators=(',',':'),allow_nan=False)+'\n').encode('utf-8')
        else:raise ValueError('Unknown codec operation')
        status=b'Y'
    except Exception as error:status=b'N';result=(type(error).__name__+': '+str(error)).encode('utf-8')
    target.write(status+struct.pack('<Q',len(result))+result);target.flush()
