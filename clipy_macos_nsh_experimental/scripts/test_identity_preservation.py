#!/usr/bin/env python3
"""Corrupt experimental identity must not generate or overwrite a replacement."""
import argparse,json,tempfile,subprocess
from pathlib import Path
from test_relay_tunnel import Helper

def stop_without_reset(helper):helper.process.stdin.close();helper.process.wait(timeout=5)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='clipy-identity-test-') as raw:
        root=Path(raw)
        native=root/'native';helper=Helper(args.helper,native)
        try:
            first=helper.call('relay.configure',{'url':'ws://127.0.0.1:20001/relay/v1/ws','password':'fixture-password-a'})
            second=helper.call('relay.configure',{'url':'ws://127.0.0.1:20002/relay/v1/ws'})
            assert second['hasPassword'] is False,'password crossed server origin'
            assert helper.call('relay.configure',{'url':'ws://127.0.0.1:20001/relay/v1/ws','password':''})['hasPassword'] is True
            assert helper.call('relay.configure',{'url':'ws://127.0.0.1:20001/relay/v1/ws','clearPassword':True})['hasPassword'] is False
            helper.call('relay.testCorruptIdentity');digest=helper.call('relay.testIdentityDigest');stop_without_reset(helper)
            helper=Helper(args.helper,native)
            assert helper.call('relay.status')['identityError']
            try:helper.call('relay.configure',{'url':'ws://127.0.0.1:20001/relay/v1/ws'});raise AssertionError('corrupt identity overwritten')
            except RuntimeError as error:assert 'IDENTITY_UNAVAILABLE' in str(error)
            assert helper.call('relay.testIdentityDigest')==digest
            assert helper.call('system.info')['platform']=='macos','basic app stopped by relay error'
        finally:helper.close()
        lan=root/'bad-lan';lan.mkdir();identity=lan/'lan-identity.json';original=b'corrupt-fixture-identity';identity.write_bytes(original)
        helper=Helper(args.helper,lan)
        try:
            assert helper.call('system.info')['lanIdentityError']
            try:helper.call('lan.start',{'port':0});raise AssertionError('corrupt LAN identity accepted')
            except RuntimeError as error:assert 'IDENTITY_CORRUPT' in str(error)
            assert identity.read_bytes()==original
            helper.call('storage.set',{'key':'fixture','value':'history still available'})
            assert helper.call('storage.get',{'key':'fixture'})=='history still available'
        finally:helper.close()
        bad=root/'bad-storage';bad.mkdir();database=bad/'history.sqlite';bad_bytes=b'invalid-sqlite-fixture';database.write_bytes(bad_bytes)
        process=subprocess.Popen([args.helper,'--data-dir',str(bad)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        event=json.loads(process.stdout.readline());assert event['event']=='native.startupError' and event['payload']['code']=='HISTORY_STORAGE'
        process.wait(timeout=5);assert process.returncode==78 and database.read_bytes()==bad_bytes
        process.stdin.close()
        print(json.dumps({'identity_preservation':'passed','corrupt_lan_bytes_preserved':True,'corrupt_keychain_entry_preserved':True,'base_history_available':True,'password_bound_to_url':True,'explicit_password_clear':True,'production_identity_used':False,'startup_error_reported':True,'corrupt_database_preserved':True}))
if __name__=='__main__':main()
