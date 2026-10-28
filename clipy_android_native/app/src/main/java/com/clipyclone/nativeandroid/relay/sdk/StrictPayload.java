// Adapted from JunWeiUp/common-relay Java SDK, commit 794a2396266ee6f26ab7406f6d6466732a269dbf.
package com.clipyclone.nativeandroid.relay.sdk;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Strict signed-payload scan shared byte for byte with the relay and other SDKs.
 * JSON parsers disagree on duplicate keys, key case, unknown fields, null, number
 * forms and lone surrogates; a signed group record must have exactly one reading
 * everywhere (protocol/README.md, "严格载荷"). Avoids Map.of to stay API 26. */
final class StrictPayload {
    private StrictPayload(){}
    static final Map<String,String> MEMBER=schema("device s","name s","public_key s","signing_key s","manager b");
    static final Map<String,String> STATE=schema("closed b?","name s?","version i","app s","group s","revision i","previous s","members M","invitation s","request_hash s");
    static final Map<String,String> REQUEST=schema("version i","app s","group s","invitation s","member m","token_hash s");
    static final Map<String,String> GRANT=schema("version i","purpose s","mode s","app s","group s","invitation s","expires i","secret_hash s","delegate_key s","anchor_revision i","anchor_hash s");
    @SuppressWarnings("unchecked") static final Map<String,String>[] SCHEMAS=new Map[]{STATE,REQUEST,GRANT};
    // "kind" or "kind?" when optional.
    private static Map<String,String> schema(String... fields){Map<String,String> m=new HashMap<>();for(String f:fields){String[] p=f.split(" ");m.put(p[0],p[1]);}return m;}

    static boolean any(byte[] raw){for(Map<String,String> s:SCHEMAS)if(check(raw,s))return true;return false;}
    static boolean check(byte[] raw,Map<String,String> schema){
        try{StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw));}catch(CharacterCodingException e){return false;}
        Scanner p=new Scanner(raw);return p.object(schema)&&p.ws()==raw.length;
    }
    private static final class Scanner{
        final byte[] b;int i;
        Scanner(byte[] b){this.b=b;}
        int ws(){while(i<b.length&&(b[i]==' '||b[i]=='\t'||b[i]=='\n'||b[i]=='\r'))i++;return i;}
        boolean eat(char c){ws();if(i<b.length&&b[i]==c){i++;return true;}return false;}
        // Keys are compared as raw bytes, so an escaped key never matches the schema.
        boolean object(Map<String,String> schema){
            if(!eat('{'))return false;
            Set<String> seen=new HashSet<>();
            if(!eat('}')){
                while(true){
                    int start=ws();
                    if(!string())return false;
                    String k=new String(b,start+1,i-start-2,StandardCharsets.UTF_8),f=schema.get(k);
                    if(f==null||!seen.add(k)||!eat(':')||!value(f.charAt(0)))return false;
                    if(eat('}'))break;
                    if(!eat(','))return false;
                }
            }
            for(Map.Entry<String,String> e:schema.entrySet())if(!e.getValue().endsWith("?")&&!seen.contains(e.getKey()))return false;
            return true;
        }
        boolean value(char kind){
            ws();
            switch(kind){
                case 's':return string();
                case 'b':return word("true")||word("false");
                case 'i':return integer();
                case 'm':return object(MEMBER);
                default:break;
            }
            if(!eat('['))return false;
            if(eat(']'))return true;
            while(true){
                if(!object(MEMBER))return false;
                if(eat(']'))return true;
                if(!eat(','))return false;
            }
        }
        boolean word(String w){
            if(i+w.length()>b.length)return false;
            for(int j=0;j<w.length();j++)if(b[i+j]!=w.charAt(j))return false;
            i+=w.length();return true;
        }
        // Only 0 or [1-9][0-9]* up to 2^53-1; a fraction or exponent fails at the caller.
        boolean integer(){
            int start=i;
            while(i<b.length&&b[i]>='0'&&b[i]<='9')i++;
            int n=i-start;
            return n>0&&n<=16&&(n==1||b[start]!='0')&&Long.parseLong(new String(b,start,n,StandardCharsets.US_ASCII))<=9007199254740991L;
        }
        boolean string(){
            if(i>=b.length||b[i]!='"')return false;
            for(i++;i<b.length;i++){
                int c=b[i]&0xff;
                if(c=='"'){i++;return true;}
                if(c<0x20)return false;
                if(c=='\\'){
                    if(++i>=b.length)return false;
                    if(b[i]=='u'){
                        if(i+4>=b.length)return false;
                        int n=0;
                        for(int j=1;j<=4;j++){int d=Character.digit(b[i+j],16);if(d<0)return false;n=n*16+d;}
                        if(n>=0xd800&&n<=0xdfff)return false;
                        i+=4;
                    }else if("\"\\/bfnrt".indexOf(b[i])<0)return false;
                }
            }
            return false;
        }
    }
}
