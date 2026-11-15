#!/usr/bin/env python3
"""Real private helper pipeline on generated pixels; no desktop, general clipboard or network."""
import argparse, json, selectors, shutil, subprocess, tempfile, uuid
from pathlib import Path

def main():
    args=argparse.ArgumentParser();args.add_argument('--helper',required=True);options=args.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-nsh-capture-pipeline-') as raw:
        root=Path(raw);fixture=root/'fixture.png'
        shutil.copyfile(Path(__file__).resolve().parents[1]/'src/editor/fixtures/red-blue.png',fixture)
        process=subprocess.Popen([options.helper,'--data-dir',raw,'--test-pasteboard'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        seq=0
        def call(method,params=None,expected_error=None,allow_error=False):
            nonlocal seq
            seq+=1;ident=str(seq);process.stdin.write(json.dumps({'id':ident,'method':method,'params':params or {}})+'\n');process.stdin.flush()
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout,selectors.EVENT_READ)
                while True:
                    if not ready.select(35):raise TimeoutError(method)
                    line=process.stdout.readline()
                    if not line:raise RuntimeError('helper exited')
                    result=json.loads(line)
                    if result.get('id')!=ident:continue
                    if expected_error:
                        assert not result.get('ok') and result['error']['code']==expected_error,result
                        return
                    if allow_error and not result.get('ok'):return {'error':result['error']}
                    assert result.get('ok'),result.get('error')
                    return result.get('result')
        try:
            info=call('image.info',{'path':str(fixture)});assert (info['width'],info['height'])==(64,48)
            scene={'imagePath':str(fixture),'annotations':[{'tool':'stamp','imagePath':str(fixture),'points':[{'x':10,'y':8},{'x':30,'y':23}],'opacity':0.5,'imageRotation':90}],'effects':{'beautify':True,'padding':8,'radius':2,'shadow':0,'gradientColors':['#FF000080','#0000FFFF'],'gradientAngle':0}}
            rendered=call('image.render',scene);assert (rendered['width'],rendered['height'])==(80,64)
            composed=call('image.compose',{'paths':[rendered['path'],str(fixture)],'axis':'vertical','gap':4})
            assert (composed['width'],composed['height'])==(80,116)
            media=call('media.import',{'path':composed['path']});lease=call('media.lease',{'id':media['id']})
            assert Path(lease['path']).is_file()
            call('media.consumeSource',{'path':composed['path'],'id':media['id']});assert not Path(composed['path']).exists()
            call('image.releaseOutput',{'path':composed['path']})
            call('media.release',{'leaseId':lease['leaseId']});call('media.abandonImport',{'id':media['id']})
            invalid={**scene,'annotations':[{'tool':'stamp','imagePath':'/etc/passwd','points':[{'x':0,'y':0},{'x':20,'y':20}]}]}
            call('image.render',invalid,expected_error='ACCESS_DENIED')
            call('image.compose',{'paths':[str(fixture),'/etc/passwd']},expected_error='ACCESS_DENIED')
            ocr=call('ocr.recognize',{'path':str(fixture)})
            assert ocr['coordinateSpace']=='source-pixels-top-left' and (ocr['width'],ocr['height'])==(64,48)
            assert isinstance(ocr['rows'],list) and isinstance(ocr['codes'],list)
            call('image.redact',{'imagePath':str(fixture),'categories':['text']})
            assert not list((root/'capture-vision-jobs').glob('*.json'))
            captures=root/'captures';captures.mkdir(exist_ok=True)
            generated=captures/(str(uuid.uuid4())+'.png');shutil.copyfile(fixture,generated)
            call('files.discardCaptureSource',{'path':str(generated)});assert not generated.exists()
            protected=captures/'original.png';shutil.copyfile(fixture,protected)
            call('files.discardCaptureSource',{'path':str(protected)},expected_error='ACCESS_DENIED');assert protected.exists()
            escaped=root/('escape-'+str(uuid.uuid4())+'.png');escaped.symlink_to('/etc/passwd')
            call('image.info',{'path':str(escaped)},expected_error='ACCESS_DENIED')
            system=call('capture.translateLine',{'text':'Good morning.','source':'en','target':'简体中文'},allow_error=True)
            if 'error' in system:assert system['error']['code'] in ['LANGUAGE_NOT_INSTALLED','SYSTEM_TRANSLATION_UNAVAILABLE'],system
            else:assert system.get('provider')=='apple-on-device'
            call('capture.translateLine',{'text':'Good morning.','target':'中文','backend':'automatic'},expected_error='INVALID_ARGUMENT')
            call('capture.translateLine',{'text':'Good morning.','target':'中文','backend':'model'},expected_error='NOT_CONFIGURED')
            call('image.releaseOutput',{'path':rendered['path']})
            print(json.dumps({'system_translation_default':system.get('error',{}).get('code','apple-on-device'),'real_helper':'passed','native_composition':[80,116],'nested_path_rejection':True,'media_lease_and_consume':True,'short_lived_vision':True,'desktop_clipboard_network_touched':False}))
        finally:
            process.stdin.close()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
if __name__=='__main__':main()
