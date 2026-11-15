#!/usr/bin/env python3
"""Real ephemeral local CommonRelay server -> SDK stream -> v3 text/file tests.
Run with common-relay's Python venv (PyNaCl). Never uses production identities.
"""
import argparse, concurrent.futures, hashlib, json, os, queue, socket, subprocess, tempfile, threading, time
from pathlib import Path
from nacl.public import PrivateKey

class Helper:
    def __init__(self, executable, root):
        self.root=root;root.mkdir(exist_ok=True)
        self.process=subprocess.Popen([executable,'--data-dir',str(root),'--allow-local-relay-test'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.q=queue.Queue();self.events=[];self.replies={};self.seq=0;self.lock=threading.Lock();self.sendLock=threading.Lock()
        def read():
            for line in self.process.stdout:
                try: value=json.loads(line)
                except ValueError:continue
                with self.lock:
                    if 'event' in value:self.events.append(value)
                    else:self.replies[value.get('id')]=value
        threading.Thread(target=read,daemon=True).start()
    def call(self,method,params=None,timeout=30):
        with self.lock:self.seq+=1;ident=str(self.seq)
        with self.sendLock:
            self.process.stdin.write(json.dumps({'id':ident,'method':method,'params':params or {}})+'\n');self.process.stdin.flush()
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            with self.lock:reply=self.replies.pop(ident,None)
            if reply:
                if not reply.get('ok'):
                    if reply.get('error',{}).get('code')=='BUSY' and deadline-time.monotonic()>.3:
                        time.sleep(.15);return self.call(method,params,deadline-time.monotonic())
                    raise RuntimeError(str(reply.get('error')))
                return reply.get('result')
            if self.process.poll() is not None:raise RuntimeError('Helper exited')
            time.sleep(.02)
        raise TimeoutError(method)
    def event(self,name,timeout=20):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            with self.lock:
                for i,item in enumerate(self.events):
                    if item.get('event')==name:return self.events.pop(i)['payload']
            time.sleep(.02)
        raise TimeoutError(name)
    def close(self):
        try:self.call('relay.testCleanup',timeout=5)
        except Exception:pass
        self.process.stdin.close()
        try:self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:self.process.terminate();self.process.wait(timeout=5)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--server',required=True);parser.add_argument('--helper',required=True);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-nsh-relay-test-') as raw:
        root=Path(raw);sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
        password='nsh-local-test-access';access=root/'access';access.write_text(hashlib.sha256(password.encode()).hexdigest());access.chmod(0o600)
        keys={name:PrivateKey.generate() for name in ['a','b']};configs={}
        for name,key in keys.items():
            credential=root/(name+'-credential.json')
            subprocess.run([args.server,'device-add','--data',str(root/'server'),'--app','clipy-tsx-test','--group','local','--device',name,'--public-key',bytes(key.public_key).hex(),'--credential-out',str(credential)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            configs[name]={'url':f'ws://127.0.0.1:{port}/relay/v1/ws','app':'clipy-tsx-test','group':'local','device':name,'secret_key':bytes(key).hex(),'trusted_peers':{n:bytes(k.public_key).hex() for n,k in keys.items() if n!=name},'token':json.loads(credential.read_text())['token'],'password':password}
        server=subprocess.Popen([args.server,'serve','--data',str(root/'server'),'--listen',f'127.0.0.1:{port}','--disk-reserve','0','--access-password-file',str(access)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        helpers=[]
        try:
            for _ in range(100):
                try:connection=socket.create_connection(('127.0.0.1',port),timeout=.1);connection.close();break
                except OSError:time.sleep(.05)
            for name in ['a','b']:
                helper=Helper(args.helper,root/name);helpers.append(helper);helper.call('relay.configure',configs[name]);helper.call('relay.connect')
            a,b=helpers
            for _ in range(200):
                pa=a.call('lan.status')['peers'];pb=b.call('lan.status')['peers']
                if pa and pb:break
                time.sleep(.05)
            assert pa and pb,'v3 tunnels did not handshake'
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(a.call,'lan.sendText',{'peerId':pa[0]['id'],'text':'NSH tunnel fixture 世界'},30)
                event=b.event('lan.history.received');assert event['content']=='NSH tunnel fixture 世界'
                (b.root/'committed-text.json').write_text(json.dumps(event))
                b.call('lan.ack',{'messageId':event['messageId']});receipt=future.result(timeout=10);assert receipt.get('confirmed') is True or receipt.get('acknowledged') is True or receipt.get('ok') is True,receipt
                payload=os.urandom(2*1024*1024+17);source=a.root/'fixture.bin';source.write_bytes(payload)
                future=pool.submit(a.call,'lan.sendFile',{'peerId':pa[0]['id'],'path':str(source)},60)
                event=b.event('lan.file.received',timeout=50);assert hashlib.sha256(Path(event['path']).read_bytes()).digest()==hashlib.sha256(payload).digest()
                (b.root/'committed-file.json').write_text(json.dumps(event));b.call('lan.ack',{'messageId':event['messageId']});result=future.result(timeout=10)
            print(json.dumps({'relay_tunnel':'passed','text':'received-and-committed-before-ack','file_bytes':len(payload),'file_sha256':'matched','transport':pa[0].get('transport'),'production_credentials_used':False}))
        finally:
            for helper in helpers:helper.close()
            server.terminate();server.wait(timeout=5)
if __name__=='__main__':main()
