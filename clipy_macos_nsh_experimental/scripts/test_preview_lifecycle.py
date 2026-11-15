#!/usr/bin/env python3
"""Preview close/cancel/crash cleanup with unknown local files preserved."""
import argparse,base64,concurrent.futures,json,struct,tempfile,time,zlib
from pathlib import Path
from test_relay_tunnel import Helper

def png(path,width,height):
    def chunk(kind,body):return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body)&0xffffffff)
    row=b'\0'+bytes([42,120,220,255])*width
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(row*height,1))+chunk(b'IEND',b''))
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-preview-test-') as raw:
        root=Path(raw)/'native';helper=Helper(args.helper,root)
        try:
            image=root/'source.png';png(image,32,32)
            scene={'imagePath':str(image),'annotations':[],'preview':True}
            first=helper.call('image.render',scene);preview=Path(first['path']);assert preview.exists()
            unknown=preview.parent/'my-notes.txt';unknown.write_text('unknown local fixture')
            helper.call('image.closePreviews');assert not preview.exists() and unknown.exists()
            output=Path(helper.call('image.render',{**scene,'preview':False})['path']);assert output.exists();helper.call('image.releaseOutput',{'path':str(output)});assert not output.exists()
            try:helper.call('image.releaseOutput',{'path':str(unknown)});raise AssertionError('unknown file deleted')
            except RuntimeError as error:assert 'ACCESS_DENIED' in str(error)
            for _ in range(18):helper.call('image.render',{**scene,'preview':False})
            assert len(list(preview.parent.glob('Clipy-*.png')))<=16
            png(image,4000,4000)
            annotations=[{'tool':'solid','points':[{'x':0,'y':0},{'x':4000,'y':4000}],'color':'#112233','opacity':.4} for _ in range(500)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(helper.call,'image.render',{**scene,'annotations':annotations},30)
                time.sleep(.03);helper.call('image.closePreviews')
                try:late=future.result(timeout=10);assert not Path(late['path']).exists(),'late preview survived close'
                except RuntimeError as error:assert 'CANCELLED' in str(error)
            assert not list(preview.parent.glob('Preview-*.png')) and unknown.exists()
            png(image,32,32);crash_output=Path(helper.call('image.render',{**scene,'preview':False})['path']);assert crash_output.exists()
            helper.process.kill();helper.process.wait(timeout=5)
            try:helper.process.stdin.close()
            except BrokenPipeError:pass
            helper=Helper(args.helper,root);helper.call('system.info')
            assert not crash_output.exists(),'owned output survived restart'
            assert unknown.read_text()=='unknown local fixture'
            print(json.dumps({'preview_lifecycle':'passed','close_purges_preview':True,'late_cancelled_preview_removed':True,'explicit_output_release':True,'crash_manifest_cleanup':True,'private_output_count_bounded':True,'unknown_local_file_preserved':True}))
        finally:helper.close()
if __name__=='__main__':main()
