#!/usr/bin/env python3
"""Production helper's real bounded stdio protocol, isolated generated data only."""
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

binary=sys.argv[1]
with tempfile.TemporaryDirectory(prefix='clipy-storage-stdio-') as root:
    env={**os.environ,'CLIPY_STORAGE_TEST':'1'}
    process=subprocess.Popen([binary,'--data-dir',root],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1,env=env)
    messages=queue.Queue()
    threading.Thread(target=lambda:[messages.put(line) for line in process.stdout],daemon=True).start()
    counter=0
    maximum=0
    def call(method,params=None,expect_error=False):
        global counter,maximum
        counter+=1
        identifier=f'storage-test-{counter}'
        wire=json.dumps({'id':identifier,'method':method,'params':params or {}},ensure_ascii=False)
        assert len(wire.encode())<128*1024
        maximum=max(maximum,len(wire.encode()))
        process.stdin.write(wire+'\n');process.stdin.flush()
        while True:
            line=messages.get(timeout=20)
            maximum=max(maximum,len(line.encode()))
            assert len(line.encode())<128*1024
            result=json.loads(line)
            if result.get('id')!=identifier:continue
            if expect_error:
                assert not result.get('ok'),result
                return result
            assert result.get('ok'),result
            return result.get('result')
    def write(key,data):
        start=call('storage.write.begin',{'key':key,'size':len(data)})
        for offset in range(0,len(data),65536):
            call('storage.write.chunk',{'id':start['id'],'offset':offset,'data':base64.b64encode(data[offset:offset+65536]).decode()})
        call('storage.write.commit',{'id':start['id']})
    def read(key):
        start=call('storage.read.begin',{'key':key})
        if not start['exists']:return None
        data=bytearray();offset=0
        while offset<start['size']:
            part=call('storage.read.chunk',{'id':start['id'],'offset':offset,'length':65536})
            block=base64.b64decode(part['data']);data.extend(block);offset=part['nextOffset']
        call('storage.read.end',{'id':start['id']})
        return bytes(data)
    try:
        data=('隔离正文marker\n'*300000).encode()
        assert len(data)>5*1024*1024
        write('large-state',data)
        assert hashlib.sha256(read('large-state')).digest()==hashlib.sha256(data).digest()
        interrupted=call('storage.write.begin',{'key':'large-state','size':10})
        call('storage.write.chunk',{'id':interrupted['id'],'offset':0,'data':base64.b64encode(b'abc').decode()})
        call('storage.write.commit',{'id':interrupted['id']},expect_error=True)
        call('storage.write.cancel',{'id':interrupted['id']})
        assert read('large-state')==data
        call('storage.configure',{'encrypted':True})
        assert read('large-state')==data
        assert b'marker' not in Path(root,'history.sqlite').read_bytes()
        call('storage.configure',{'encrypted':False})
        assert read('large-state')==data
        write('empty',b'');assert read('empty')==b''
        call('storage.testCleanupKey')
        print(f'PASS production stdio: {len(data)} UTF8 bytes roundtrip encrypted/plain, interrupted commit preserves original, max wire line {maximum} bytes')
    finally:
        try:call('system.close')
        except Exception:pass
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=10)
