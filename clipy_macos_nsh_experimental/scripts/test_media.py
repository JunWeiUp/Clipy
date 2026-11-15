#!/usr/bin/env python3
"""Synthetic media-only integration; no screen, microphone or personal files."""
import argparse,json,queue,shutil,subprocess,tempfile,threading
from pathlib import Path

class Native:
    def __init__(self,helper,root):
        self.p=subprocess.Popen([helper,'--data-dir',str(root),'--test-pasteboard'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.q=queue.Queue();self.i=0
        def read():
            for line in self.p.stdout:
                try:self.q.put(json.loads(line))
                except ValueError:pass
        threading.Thread(target=read,daemon=True).start()
    def call(self,method,params=None):
        self.i+=1;ident=str(self.i);self.p.stdin.write(json.dumps({'id':ident,'method':method,'params':params or {}})+'\n');self.p.stdin.flush()
        while True:
            reply=self.q.get(timeout=60)
            if reply.get('id')==ident:
                if not reply.get('ok'):raise RuntimeError(str(reply.get('error')))
                return reply.get('result')
    def close(self):
        self.p.stdin.close()
        try:self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:self.p.terminate();self.p.wait(timeout=5)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);args=parser.parse_args()
    ffmpeg=shutil.which('ffmpeg');ffprobe=shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:raise SystemExit('ffmpeg/ffprobe are required only to generate/inspect synthetic regression fixtures')
    with tempfile.TemporaryDirectory(prefix='clipy-media-') as raw:
        root=Path(raw);source=root/'fixture.mp4'
        subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc=size=160x120:rate=12','-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','2','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-y',str(source)],check=True)
        app=Native(args.helper,root)
        try:
            original=app.call('video.info',{'path':str(source)});assert original['audioTracks']==1
            trimmed=app.call('video.export',{'path':str(source),'start':.25,'end':1.75,'speed':2,'scale':.5,'format':'mp4'})
            info=app.call('video.info',trimmed);assert info['width']==80 and info['height']==60 and abs(info['duration']-.75)<.15 and info['audioTracks']==1,info
            cut=app.call('video.export',{'path':str(source),'format':'mp4','effects':[{'type':'cut','start':.5,'end':1.0}]})
            assert abs(app.call('video.info',cut)['duration']-1.5)<.15
            freeze=app.call('video.export',{'path':str(source),'format':'mp4','effects':[{'type':'freeze','start':.5,'end':.5,'duration':.5}]})
            frozen=app.call('video.info',freeze);assert abs(frozen['duration']-2.5)<.2 and frozen['audioTracks']==1,frozen
            at_end=app.call('video.export',{'path':str(source),'format':'mp4','effects':[{'type':'freeze','start':2.,'end':2.,'duration':.25}]});assert abs(app.call('video.info',at_end)['duration']-2.25)<.2
            visual=app.call('video.export',{'path':str(source),'format':'mp4','effects':[{'type':'mask','start':0.,'end':2.,'x':0.,'y':0.,'width':.5,'height':1.,'mode':'solid'},{'type':'text','start':.2,'end':1.8,'text':'Fixture','fontSize':18}]})
            pixels=subprocess.check_output([ffmpeg,'-hide_banner','-loglevel','error','-i',visual['path'],'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'])
            baseline=subprocess.check_output([ffmpeg,'-hide_banner','-loglevel','error','-i',str(source),'-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'])
            black=next((y*160+x)*3 for y in range(10,110) for x in range(10,70) if max(baseline[(y*160+x)*3:(y*160+x)*3+3])>100);assert max(pixels[black:black+3])<25,'mask did not render into export'
            gif=app.call('video.export',{'path':str(source),'start':0.,'end':1.,'format':'gif','fps':6})
            probe=json.loads(subprocess.check_output([ffprobe,'-v','quiet','-count_frames','-show_streams','-of','json',gif['path']]))
            assert int(probe['streams'][0]['nb_read_frames'])==6
            medium=app.call('video.export',{'path':str(source),'format':'mp4','quality':'medium','scale':.5})
            medium_info=app.call('video.info',medium);assert medium_info['width']==80 and medium_info['height']==60 and medium_info['audioTracks']==1,medium_info
            print(json.dumps({'synthetic_media':'passed','trim_speed_scale':True,'audio_preserved':True,'cut':True,'freeze_with_silent_hold':True,'visual_effect_pixels':True,'gif_frames':6,'bitrate_quality_keeps_dimensions':True,'screen_or_microphone_captured':False}))
        finally:app.close()
if __name__=='__main__':main()
