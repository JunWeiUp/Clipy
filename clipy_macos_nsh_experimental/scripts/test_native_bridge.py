#!/usr/bin/env python3
"""Isolated clipboard-format regression; never touches NSPasteboard.general."""
import argparse,base64,json,os,subprocess,tempfile,time
from pathlib import Path

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-nsh-native-test-') as raw:
        root=Path(raw)
        process=subprocess.Popen([args.helper,'--data-dir',raw,'--test-pasteboard'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        sequence=0;events=[]
        def call(method,params=None):
            nonlocal sequence
            sequence+=1;ident=str(sequence);process.stdin.write(json.dumps({'id':ident,'method':method,'params':params or {}})+'\n');process.stdin.flush()
            while True:
                line=process.stdout.readline()
                if not line:raise RuntimeError('Helper exited')
                reply=json.loads(line)
                if 'event' in reply:events.append(reply);continue
                if reply.get('id')==ident:
                    if not reply.get('ok'):raise RuntimeError(str(reply.get('error')))
                    return reply.get('result')
        try:
            call('clipboard.write',{'text':'virtual fixture 世界'});assert call('clipboard.read')['type']=='text'
            for ext,data in [('html',b'<html><body><b>virtual bold</b></body></html>'),('rtf',b'{\\rtf1\\ansi virtual \\b bold\\b0}')]:
                file=root/('rich.'+ext);file.write_bytes(data);call('clipboard.write',{'type':'richText','text':'virtual bold','mediaPath':str(file)})
                result=call('clipboard.read');assert result['type']=='richText';assert Path(result['mediaPath']).read_bytes()==data
                call('clipboard.write',{'type':'richText','text':'virtual bold','mediaPath':result['mediaPath']});assert call('clipboard.read')['type']=='richText'
                call('clipboard.write',{'type':'richText','text':'plain fixture','mediaPath':str(file),'plain':True});assert call('clipboard.read')['type']=='text'
            pdf=root/'fixture.pdf';pdf.write_bytes(b'%PDF-1.4\n1 0 obj <</Type/Catalog>> endobj\n%%EOF')
            call('clipboard.write',{'type':'pdf','mediaPath':str(pdf)});result=call('clipboard.read');assert result['type']=='pdf' and Path(result['mediaPath']).read_bytes()==pdf.read_bytes()
            file=root/'file.txt';file.write_text('fixture')
            call('clipboard.write',{'type':'file','mediaPath':str(file)});assert str(file) in call('clipboard.read')['files']
            image=root/'fixture.png';image.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAI0lEQVR4nGPUqrjDQApgIkk1w6gG4gATkergYFQDMYDkUAIAwn4BnhUQsXAAAAAASUVORK5CYII='))
            call('clipboard.write',{'type':'image','mediaPath':str(image)});result=call('clipboard.read');assert result['type']=='image' and Path(result['mediaPath']).stat().st_size>0
            call('clipboard.write',{'text':'ordinary virtual fixture'})
            old=call('clipboard.read')['changeCount']
            call('clipboard.write',{'text':'next ordinary fixture'})
            assert call('clipboard.concealChange',{'changeCount':old})['concealed'] is False
            assert call('clipboard.readText')=='next ordinary fixture'
            current=call('clipboard.read')['changeCount']
            assert call('clipboard.concealChange',{'changeCount':current})['concealed'] is True
            assert call('clipboard.readText')==''
            call('clipboard.watch',{'enabled':True});call('clipboard.write',{'text':'sensitive virtual fixture','sensitive':True});time.sleep(.8);call('system.info');assert not [e for e in events if e.get('event')=='clipboard.changed']
            call('clipboard.watch',{'enabled':False})
            call('clipboard.write',{'text':'virtual source fixture'})
            bundle=call('clipboard.read').get('bundleId')
            if bundle:
                call('clipboard.watch',{'enabled':True,'excludedApps':[bundle]})
                call('clipboard.write',{'text':'excluded virtual fixture'})
                assert call('clipboard.read').get('excluded') is True
                assert call('clipboard.readText')==''
                call('clipboard.watch',{'enabled':False,'excludedApps':[]})
            print(json.dumps({'isolated_clipboard':'passed','formats':['text','html','rtf','pdf','files','image'],'plain_text_override':True,'sensitive_write_not_recorded':True,'user_clipboard_touched':False}))
        finally:
            process.stdin.close()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
if __name__=='__main__':main()
