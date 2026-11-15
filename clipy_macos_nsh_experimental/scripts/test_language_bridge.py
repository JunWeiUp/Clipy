#!/usr/bin/env python3
"""Loopback Chat Completions and models test, with synthetic text/key only."""
import argparse,concurrent.futures,http.server,json,tempfile,threading,time
from pathlib import Path
from test_relay_tunnel import Helper
class Handler(http.server.BaseHTTPRequestHandler):
    seen=[]
    expected_auth="Bearer fixture-key"
    def log_message(self,*args):pass
    def send_json(self,value):
        data=json.dumps(value,ensure_ascii=False).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        self.seen.append(self.path)
        if self.path=='/redirect/models':self.send_response(307);self.send_header('Location','/forbidden');self.end_headers();return
        assert self.path=='/v1/models';assert self.headers.get('Authorization')==self.expected_auth;self.send_json({'data':[{'id':'fixture-b'},{'id':'fixture-a'}]})
    def do_POST(self):
        self.seen.append(self.path);data=json.loads(self.rfile.read(int(self.headers['Content-Length'])));assert data['stream'] is False
        if self.path=='/slow/chat/completions':time.sleep(2)
        else:assert self.path=='/v1/chat/completions';assert data['messages'][-1]['content']=='fixture\n\n段落'
        self.send_json({'choices':[{'message':{'content':'示例译文\n\n段落'}}]})
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);args=parser.parse_args();server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();other=http.server.ThreadingHTTPServer(('127.0.0.1',0),type('AnonymousHandler',(Handler,),{'expected_auth':None}));threading.Thread(target=other.serve_forever,daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='clipy-language-test-') as raw:
        helper=Helper(args.helper,Path(raw)/'native');base=f'http://127.0.0.1:{server.server_port}'
        try:
            helper.call('model.configure',{'endpoint':base,'model':'fixture-a','key':'fixture-key'})
            assert helper.call('model.models',{'endpoint':base+'/v1/chat/completions'})==['fixture-a','fixture-b']
            other_base=f'http://127.0.0.1:{other.server_port}'
            assert helper.call('model.models',{'endpoint':other_base})==['fixture-a','fixture-b']
            assert helper.call('model.translate',{'endpoint':base,'key':'fixture-key','model':'fixture-a','text':'fixture\n\n段落','target':'简体中文'})['text']=='示例译文\n\n段落'
            try:helper.call('model.models',{'endpoint':'http://example.com'});raise AssertionError('remote HTTP accepted')
            except RuntimeError as error:assert 'INVALID_URL' in str(error)
            try:helper.call('model.models',{'endpoint':base+'/redirect'});raise AssertionError('redirect accepted')
            except RuntimeError as error:assert 'HTTP_ERROR' in str(error)
            assert '/forbidden' not in Handler.seen
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(helper.call,'model.translate',{'endpoint':base+'/slow','model':'fixture','text':'fixture'})
                time.sleep(.2);helper.call('model.cancel')
                try:future.result(timeout=5);raise AssertionError('cancel ignored')
                except RuntimeError:pass
            helper.call('model.configure',{'endpoint':other_base,'model':'fixture-b'})
            assert helper.call('model.status')['hasKey'] is False
            assert helper.call('model.models',{})==['fixture-a','fixture-b']
            print(json.dumps({'language_bridge':'passed','models':True,'translation_paragraphs':True,'remote_http_rejected':True,'redirect_rejected':True,'cancellation':True,'real_api_key_used':False,'saved_key_same_canonical_endpoint_only':True,'different_server_override_anonymous':True,'endpoint_change_without_key_clears_old_key':True}))
        finally:
            try:helper.call('model.testCleanup')
            finally:helper.close();server.shutdown();server.server_close();other.shutdown();other.server_close()
if __name__=='__main__':main()
