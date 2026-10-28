// Adapted from JunWeiUp/common-relay Java SDK, commit 794a2396266ee6f26ab7406f6d6466732a269dbf.
package com.clipyclone.nativeandroid.relay.sdk;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import java.io.IOException;
import org.json.JSONObject;

/** The URL fragment key never goes to HTTP; only a domain-separated read token does. */
public final class InvitationLinks {
    private InvitationLinks() {}
    private static final String PURPOSE="common-relay/invitation-link/v1";
    public static String base64url(byte[] b){return AndroidBase64.urlEncode(b);}
    private static byte[] decode(String s,int n)throws Exception{
        if(s==null||!s.matches("[A-Za-z0-9_-]+"))throw new IOException("Invalid compact invitation");
        byte[] raw=AndroidBase64.urlDecode(s);
        if(raw.length!=n||!base64url(raw).equals(s))throw new IOException("Invalid compact invitation");return raw;
    }
    public static String readToken(byte[] key)throws Exception{
        if(key.length!=32)throw new IOException("Invitation key size");
        byte[] prefix="common-relay/invitation-link/read/v1\0".getBytes(StandardCharsets.UTF_8),raw=Arrays.copyOf(prefix,prefix.length+key.length);System.arraycopy(key,0,raw,prefix.length,key.length);return RelayGroups.digest(raw);
    }
    public static String seal(JSONObject invitation,byte[] key,byte[] nonce)throws Exception{
        if(key.length!=32||nonce.length!=24)throw new IOException("Invitation key/nonce size");
        byte[] raw=new JSONObject().put("version",1).put("purpose",PURPOSE).put("invitation",invitation).toString().getBytes(StandardCharsets.UTF_8),cipher=new byte[raw.length+16];
        Crypto.check(Crypto.S.crypto_secretbox_easy(cipher,raw,raw.length,nonce,key));
        byte[] packet=Arrays.copyOf(nonce,nonce.length+cipher.length);System.arraycopy(cipher,0,packet,nonce.length,cipher.length);return AndroidBase64.encode(packet);
    }
    public static JSONObject open(String packet,byte[] key)throws Exception{
        byte[] raw=AndroidBase64.decode(packet);if(key.length!=32||raw.length<40||raw.length>16384)throw new IOException("Invitation packet size");
        byte[] nonce=Arrays.copyOf(raw,24),cipher=Arrays.copyOfRange(raw,24,raw.length),plain=new byte[cipher.length-16];
        Crypto.check(Crypto.S.crypto_secretbox_open_easy(plain,cipher,cipher.length,nonce,key));
        JSONObject value=new JSONObject(new String(plain,StandardCharsets.UTF_8));
        if(value.getInt("version")!=1||!value.getString("purpose").equals(PURPOSE))throw new IOException("Invitation packet scope");return value.getJSONObject("invitation");
    }
    public static String make(JSONObject invitation,byte[] key)throws Exception{
        URI u=new URI(invitation.getString("url"));return "common-relay://"+u.getRawAuthority()+"/i/"+base64url(Crypto.unhex(invitation.getString("id")))+"#"+base64url(key);
    }
    public static final class Parsed {
        public final String url,id;public final byte[] key;
        Parsed(String url,String id,byte[] key){this.url=url;this.id=id;this.key=key;}
    }
    public static Parsed parse(String text,boolean allowLocalTest)throws Exception{
        if(text.length()>2048)throw new IOException("Invitation too long");URI u=new URI(text);
        if(!"common-relay".equals(u.getScheme())||u.getHost()==null||u.getRawUserInfo()!=null||u.getRawQuery()!=null||!u.getRawPath().matches("/i/[A-Za-z0-9_-]{22}"))throw new IOException("Invalid compact invitation");
        String scheme=allowLocalTest&&u.getHost().equals("127.0.0.1")?"ws":"wss";
        return new Parsed(scheme+"://"+u.getRawAuthority()+"/relay/v1/ws",Crypto.hex(decode(u.getRawPath().substring(3),16)),decode(u.getRawFragment(),32));
    }
}
