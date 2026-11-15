#!/usr/bin/env python3
"""Ephemeral signed group creation/auto invitation/join/rename/exit on local relay."""
import argparse,hashlib,json,socket,subprocess,tempfile,time
from pathlib import Path
from test_relay_tunnel import Helper

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--server',required=True);parser.add_argument('--helper',required=True);parser.add_argument('--qr-decoder');args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-nsh-group-test-') as raw:
        root=Path(raw);sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close();password='fixture-group-access'
        access=root/'access';access.write_text(hashlib.sha256(password.encode()).hexdigest());access.chmod(0o600)
        server=subprocess.Popen([args.server,'serve','--data',str(root/'server'),'--listen',f'127.0.0.1:{port}','--disk-reserve','0','--access-password-file',str(access),'--self-service-apps','clipy-tsx-test'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        helpers=[]
        try:
            for _ in range(100):
                try:s=socket.create_connection(('127.0.0.1',port),timeout=.1);s.close();break
                except OSError:time.sleep(.05)
            a=Helper(args.helper,root/'a');helpers.append(a);b=Helper(args.helper,root/'b');helpers.append(b)
            url=f'ws://127.0.0.1:{port}/relay/v1/ws'
            a.call('relay.configure',{'url':url,'app':'clipy-tsx-test','password':password,'device':'a'})
            created=a.call('relay.create',{'name':'Fixture devices','deviceName':'Fixture A'});assert len(created['members'])==1
            invitation=a.call('relay.invite',{'mode':'auto'});assert invitation['short_link'] and 'secret' not in invitation and 'delegate_secret' not in invitation
            assert invitation['qrImage'].startswith('data:image/png;base64,')
            if args.qr_decoder:
                decoded=subprocess.run([args.qr_decoder],input=invitation['qrImage'].split(',',1)[1]+'\n',capture_output=True,text=True,check=True)
                assert invitation['short_link'] in json.loads(decoded.stdout)['payloads']
            assert b.call('relay.status')['configured'] is False
            joined=b.call('relay.join',{'link':invitation['short_link'],'deviceName':'Fixture B'});assert len(joined['members'])==2 and joined['hasPassword'] is True and joined['url']==url
            device_b=joined['device']
            try:state=a.call('relay.refresh')
            except Exception:
                print(json.dumps(a.call('relay.testProbe')));print(json.dumps([e for e in a.events if e.get('event')=='relay.trace']));subprocess.run(['/usr/sbin/lsof','-nP',f'-iTCP:{port}']);raise
            assert len(state['members'])==2
            try:b.call('relay.cancelJoin');raise AssertionError('joined membership was cancelled')
            except RuntimeError as error:assert 'ALREADY_ENROLLED' in str(error)
            b.call('relay.rename',{'device':device_b,'name':'Fixture renamed'})
            for _ in range(50):
                state=a.call('relay.refresh')
                if any(m['device']==device_b and m['name']=='Fixture renamed' for m in state['members']):break
                time.sleep(.05)
            assert any(m['device']==device_b and m['name']=='Fixture renamed' for m in state['members'])
            a.call('relay.disconnect');off=a.call('relay.refresh');assert off['connected'] is False and off['enabled'] is False
            a.call('relay.connect')
            left=b.call('relay.leave');assert not left.get('group') and left['members']==[];assert b.call('relay.refresh')['members']==[];state=a.call('relay.refresh');assert len(state['members'])==1
            manual=a.call('relay.invite',{'mode':'manual'});a.call('relay.disconnect')
            waiting=b.call('relay.join',{'link':manual['short_link'],'deviceName':'Manual fixture'})
            assert waiting['joinPending'] is True
            b.process.stdin.close();b.process.wait(timeout=5)
            b=Helper(args.helper,root/'b');helpers[1]=b
            restored=b.call('relay.connect');assert restored['joinPending'] is True and restored['enabled'] is True and restored['connected'] is False
            pending=a.call('relay.pending');assert pending['pairingCode']==waiting['pairingCode'] and pending['name']=='Manual fixture'
            approved=a.call('relay.approve',{'request':pending['request'],'manager':False});assert approved['connected'] is False and approved['enabled'] is False
            finished=b.call('relay.finish');assert finished['joined'] is True and len(finished['status']['members'])==2
            b.call('relay.leave')
            manual=a.call('relay.invite',{'mode':'manual'})
            waiting=b.call('relay.join',{'link':manual['short_link'],'deviceName':'Cancelled fixture'})
            device=waiting['device'];cancelled=b.call('relay.cancelJoin');assert not cancelled.get('joinPending') and cancelled['device']==device and not cancelled.get('group')
            a.call('relay.cancel')
            closed=a.call('relay.disband');assert not closed.get('group') and closed['members']==[]
            assert not list(root.rglob('*.png')),'QR image was written to disk'
            print(json.dumps({'signed_groups':'passed','create':True,'auto_invitation':True,'qr_roundtrip':bool(args.qr_decoder),'password_carried_by_invitation':True,'join':True,'rename':True,'leave':True,'disband':True,'production_credentials_used':False,'manual_approval':True,'cancel_pending_only':True,'joined_cancellation_rejected':True,'fresh_invitation_join_without_configure':True,'disabled_refresh_keeps_off':True,'pending_restart_restores_intent_without_ws':True,'approval_keeps_disabled_relay_off':True,'qr_png_not_written_to_disk':True}))
        finally:
            for helper in helpers:helper.close()
            server.terminate();server.wait(timeout=5)
if __name__=='__main__':main()
