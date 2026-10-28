// Adapted from JunWeiUp/common-relay Java SDK, commit 794a2396266ee6f26ab7406f6d6466732a269dbf.
package com.clipyclone.nativeandroid.relay.sdk;

import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Memory;
import com.sun.jna.Pointer;
import com.sun.jna.ptr.LongByReference;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import java.util.Map;
import java.security.SecureRandom;

/** Keys supplied to this class must have been verified through a trusted pairing channel. */
public final class Crypto {
    public interface Sodium extends Library {
        int sodium_init();
        int crypto_secretbox_easy(byte[] out,byte[] message,long length,byte[] nonce,byte[] key);
        int crypto_secretbox_open_easy(byte[] out,byte[] cipher,long length,byte[] nonce,byte[] key);
        int crypto_sign_seed_keypair(byte[] pk, byte[] sk, byte[] seed);
        int crypto_sign_detached(byte[] sig, LongByReference len, byte[] msg, long n, byte[] sk);
        int crypto_sign_verify_detached(byte[] sig, byte[] msg, long n, byte[] pk);
        int crypto_scalarmult_base(byte[] out, byte[] secret);
        int crypto_box_easy(byte[] out, byte[] message, long length, byte[] nonce, byte[] peer, byte[] secret);
        int crypto_box_open_easy(byte[] out, byte[] cipher, long length, byte[] nonce, byte[] peer, byte[] secret);
        com.sun.jna.NativeLong crypto_secretstream_xchacha20poly1305_statebytes();
        int crypto_secretstream_xchacha20poly1305_init_push(Pointer state, byte[] header, byte[] key);
        int crypto_secretstream_xchacha20poly1305_init_pull(Pointer state, byte[] header, byte[] key);
        int crypto_secretstream_xchacha20poly1305_push(Pointer state, byte[] out, LongByReference len, byte[] plain, long plainLen, byte[] aad, long aadLen, byte tag);
        int crypto_secretstream_xchacha20poly1305_pull(Pointer state, byte[] out, LongByReference len, byte[] tag, byte[] cipher, long cipherLen, byte[] aad, long aadLen);
    }
    static final Sodium S = Native.load("sodium",Sodium.class);
    static { if(S.sodium_init()<0) throw new IllegalStateException("Sodium initialization failed"); }
    public final String app, group, device;
    private final byte[] secret;
    private final Map<String,String> trusted;
    public Crypto(String app,String group,String device,String secret,Map<String,String> trusted) {
        this.app=app;this.group=group;this.device=device;this.secret=unhex(secret);this.trusted=java.util.Collections.unmodifiableMap(new java.util.HashMap<>(trusted));
        if(this.secret.length!=32) throw new IllegalArgumentException("Invalid secret key");
    }
    public static byte[] random(int count) { byte[] b=new byte[count];new SecureRandom().nextBytes(b);return b; }
    public static String hex(byte[] bytes) { StringBuilder s=new StringBuilder();for(byte b:bytes)s.append(String.format("%02x",b&255));return s.toString(); }
    public static byte[] unhex(String value) { if(value.length()%2!=0)throw new IllegalArgumentException("Invalid hex");byte[] b=new byte[value.length()/2];for(int i=0;i<b.length;i++)b[i]=(byte)Integer.parseInt(value.substring(i*2,i*2+2),16);return b; }
    public String publicKey(){byte[] out=new byte[32];check(S.crypto_scalarmult_base(out,secret));return hex(out);}
    private byte[] peer(String name){String key=trusted.get(name);if(key==null)throw new IllegalArgumentException("Untrusted peer");byte[] b=unhex(key);if(b.length!=32)throw new IllegalArgumentException("Invalid peer key");return b;}
    private JSONArray context(String from,String to,String kind,String id) { return new JSONArray().put(1).put(app).put(group).put(from).put(to).put(kind).put(id); }
    public byte[] aad(String from,String to,String kind,String id,long sequence) { return context(from,to,kind,id).put(sequence).toString().getBytes(StandardCharsets.UTF_8); }
    public String seal(String to,String kind,String id,JSONObject value) throws Exception {
        byte[] plain=new JSONObject().put("context",context(device,to,kind,id)).put("value",value).toString().getBytes(StandardCharsets.UTF_8);
        byte[] nonce=random(24),cipher=new byte[plain.length+16];check(S.crypto_box_easy(cipher,plain,plain.length,nonce,peer(to),secret));
        byte[] result=new byte[24+cipher.length];System.arraycopy(nonce,0,result,0,24);System.arraycopy(cipher,0,result,24,cipher.length);return AndroidBase64.encode(result);
    }
    public JSONObject open(String from,String kind,String id,String envelope) throws Exception {
        byte[] raw=AndroidBase64.decode(envelope);if(raw.length<40)throw new IllegalArgumentException("Truncated envelope");byte[] nonce=Arrays.copyOf(raw,24),cipher=Arrays.copyOfRange(raw,24,raw.length),plain=new byte[cipher.length-16];
        check(S.crypto_box_open_easy(plain,cipher,cipher.length,nonce,peer(from),secret));JSONObject parsed=new JSONObject(new String(plain,StandardCharsets.UTF_8));
        if(!parsed.getJSONArray("context").toString().equals(context(from,device,kind,id).toString()))throw new IllegalArgumentException("Context mismatch");return parsed.getJSONObject("value");
    }
    static void check(int result){if(result!=0)throw new IllegalArgumentException("Cryptographic verification failed");}
    public static final class SecretStream implements AutoCloseable {
        private final Memory state=new Memory(S.crypto_secretstream_xchacha20poly1305_statebytes().longValue());
        private final byte[] key,header;
        public volatile boolean finished=false; private boolean closed=false;
        private final boolean writer;
        public SecretStream(){writer=true;key=random(32);header=new byte[24];check(S.crypto_secretstream_xchacha20poly1305_init_push(state,header,key));}
        public SecretStream(JSONObject descriptor)throws Exception{writer=false;key=unhex(descriptor.getString("key"));header=unhex(descriptor.getString("header"));if(key.length!=32||header.length!=24)throw new IllegalArgumentException("Invalid descriptor");check(S.crypto_secretstream_xchacha20poly1305_init_pull(state,header,key));}
        public JSONObject descriptor()throws Exception{return new JSONObject().put("key",hex(key)).put("header",hex(header));}
        public synchronized byte[] push(byte[] plain,byte[] aad,boolean last){if(closed||!writer||finished||plain.length>65519)throw new IllegalStateException("Invalid stream state");byte[] out=new byte[plain.length+17];check(S.crypto_secretstream_xchacha20poly1305_push(state,out,new LongByReference(),plain,plain.length,aad,aad.length,(byte)(last?3:0)));finished=last;return out;}
        public synchronized byte[] pull(byte[] cipher,byte[] aad){if(closed||writer||finished||cipher.length<17||cipher.length>65536)throw new IllegalStateException("Invalid stream state");byte[] out=new byte[cipher.length-17],tag=new byte[1];check(S.crypto_secretstream_xchacha20poly1305_pull(state,out,new LongByReference(),tag,cipher,cipher.length,aad,aad.length));if(tag[0]!=0&&tag[0]!=3)throw new IllegalArgumentException("Unexpected tag");finished=tag[0]==3;return out;}
        public synchronized void close(){if(closed)return;closed=true;state.clear();state.close();Arrays.fill(key,(byte)0);}
    }
}
