import { mount,Text,signal } from 'nsh';
import { Application } from 'nsh/desktop';
import { createNativeStorage } from '../core/native-storage';
import { createAppModel } from '../core/model';
import { DEFAULT_SETTINGS } from '../core/domain';
import { NativeBridge } from '../native/bridge';
import process from 'process';
import { randomUUID } from 'crypto';
import {mkdir,readdir,lstat,unlink,rmdir,writeFile} from 'fs/promises';
async function removeTree(path:string):Promise<void>{for(const name of await readdir(path)){const child=path+'/'+name;const info=await lstat(child);if(info.isDirectory()&&!info.isSymbolicLink())await removeTree(child);else await unlink(child);}await rmdir(path);}
const status=signal('正在验证原生存储适配器…');
async function run(){
 const root=process.dataDir+'/clipy-native-adapter-'+randomUUID();await mkdir(root,{recursive:true});const bridge=new NativeBridge(()=>{const child=process.spawn(process.env.CLIPY_NSH_HELPER!,['--data-dir',root],{stdin:'pipe',lines:true});return {write:(line)=>child.write(line),end:()=>child.end(),kill:()=>child.kill(),onLine:(fn)=>{child.on('stdout',fn);},onExit:(fn)=>{child.on('exit',fn);}};});
 const storage=createNativeStorage(bridge);let key='';let model:ReturnType<typeof createAppModel>|undefined;
 try{
  const seed=createAppModel({storage:{async getItem(){return null;},async setItem(k){key=k;}},host:bridge});await seed.ready;await seed.actions.addHistory({content:'seed'});seed.dispose();
  const history=Array.from({length:40},(_,i)=>({id:'state-'+i,type:'text',content:'界'.repeat(50000)+i,title:'记录'+i,sourceApp:'Fixture',date:Date.now(),isPinned:false}));const snapshot=JSON.stringify({version:1,history,folders:[{id:'default',name:'常用'}],snippets:[],notifications:[],words:[],settings:DEFAULT_SETTINGS});const bytes=new TextEncoder().encode(snapshot).length;if(bytes<=5*1024*1024)throw Error('fixture too small');
  await storage.setItem(key,snapshot);if(await storage.getItem(key)!==snapshot)throw Error('chunked state mismatch');model=createAppModel({storage,host:bridge});await model.ready;if(model.state().history.length!==40||model.state().history[39]?.content!==history[39]?.content)throw Error('model restore mismatch');await model.actions.deleteHistory('state-0');await model.actions.undoDelete();await model.flush();if(model.state().history.length!==40)throw Error('undo restore mismatch');return {ok:true,bytes,historyRows:40,undo:true,nativeAdapter:true};
 }finally{model?.dispose();try{await bridge.call('system.close');}catch{}bridge.close();await removeTree(root);}
}
function Probe(){void run().then(async result=>{status.set('原生存储适配器验证通过');console.log('STORAGE_ADAPTER_PROOF '+JSON.stringify(result));await writeFile(process.dataDir+'/storage-adapter-proof.json',JSON.stringify(result));Application.quit();}).catch(async error=>{status.set(String(error));console.error('STORAGE_ADAPTER_PROOF '+JSON.stringify({ok:false,error:String(error)}));try{await writeFile(process.dataDir+'/storage-adapter-proof.json',JSON.stringify({ok:false,error:String(error)}));}finally{Application.quit();}});return <Text>{status()}</Text>;}
mount(Probe);
