// V3 UI alignment fixture: generated account card, never external desktop data.
import {mount,View,Text,signal,host} from 'nsh';
import fixture from './fixtures/account-fixture.png';
import {ImageEditor} from './ImageEditor';
import {setLocale} from '../ui/locale';
function Harness(){const result=signal('');const overlay=host.params.overlay===true;const actions={invoke:async(name:string,payload:any)=>{if(name==='image.render'){if(payload.preview)return undefined;result.set(`scene annotations:${payload.annotations.length} · rotation:${payload.rotation} · flipH:${payload.flipH}`);return {path:fixture.url};}if(name==='files.saveCopy')return {path:fixture.url};if(name==='image.commit'){result.set(result()+' · fixture committed');return {committed:true,id:'fixture'};}return true;}};return <View class="flex-1" style={{backgroundColor:overlay?'#E0E7F2':'#FFFFFF'}}><ImageEditor path={fixture.url} initialSize={{width:640,height:360}} defaults={{showGuides:true,beautify:host.params.beautify===true}} overlay={overlay?{selectionRect:host.params.smallSelection?{x:50,y:50,width:320,height:180}:{x:160,y:160,width:640,height:360},displayFrame:{x:0,y:0,width:1280,height:800},scale:1}:undefined} actions={actions} onClose={()=>{}}/><Text>{result()}</Text></View>;}
setLocale(String(host.params.language||'zh-CN'));mount(Harness);
