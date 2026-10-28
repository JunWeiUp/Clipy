// Adapted from JunWeiUp/common-relay Java SDK, commit 794a2396266ee6f26ab7406f6d6466732a269dbf.
package com.clipyclone.nativeandroid.relay.sdk;

import org.json.JSONObject;
import org.json.JSONArray;
import okhttp3.*;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.io.*;
import java.util.concurrent.TimeUnit;

/** Call off the UI thread. Persist config privately after every operation.
 * Pin the initial manager via a trusted invitation, never via a relay response. */
public final class RelayGroups {
    public final JSONObject config;
    private static final OkHttpClient SHARED_HTTP=new OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).callTimeout(15,TimeUnit.SECONDS).build();
    private final OkHttpClient http;
    private final String base;
    private final boolean allowLocalTest;
    public RelayGroups(JSONObject config, boolean allowLocalTest) throws Exception {
        this.allowLocalTest=allowLocalTest;this.config=config;URI u=new URI(config.getString("url"));
        if(u.getUserInfo()!=null||u.getQuery()!=null||u.getFragment()!=null||!"/relay/v1/ws".equals(u.getPath())||!("wss".equals(u.getScheme())||(allowLocalTest&&"ws".equals(u.getScheme())&&"127.0.0.1".equals(u.getHost()))))throw new IOException("WSS required");
        base=("wss".equals(u.getScheme())?"https":"http")+"://"+u.getRawAuthority()+"/relay/v1";
        http=SHARED_HTTP;
    }
    private static byte[] bytes(String s){return s.getBytes(StandardCharsets.UTF_8);}
    public static String digest(byte[] b)throws Exception{return Crypto.hex(MessageDigest.getInstance("SHA-256").digest(b));}
    public static byte[] payload(JSONObject e)throws Exception{byte[] b=AndroidBase64.decode(e.getString("payload"));if(b.length>32768)throw new IOException("Payload too large");return b;}
    /** Every signed payload is a state, join request or admission grant. */
    public static JSONObject unpack(JSONObject e)throws Exception{byte[] b=payload(e);if(!StrictPayload.any(b))throw new IOException("Ambiguous signed payload");return new JSONObject(new String(b,StandardCharsets.UTF_8));}
    private byte[][] signing()throws Exception{
        ByteArrayOutputStream out=new ByteArrayOutputStream();out.write(bytes("common-relay/group-signing/v1\0"));out.write(Crypto.unhex(config.getString("secret_key")));
        byte[] pk=new byte[32],sk=new byte[64];Crypto.check(Crypto.S.crypto_sign_seed_keypair(pk,sk,MessageDigest.getInstance("SHA-256").digest(out.toByteArray())));return new byte[][]{pk,sk};
    }
    public JSONObject sign(JSONObject value)throws Exception{byte[][] pair=signing();try{byte[] b=bytes(value.toString()),sig=new byte[64];Crypto.check(Crypto.S.crypto_sign_detached(sig,null,b,b.length,pair[1]));return new JSONObject().put("payload",AndroidBase64.encode(b)).put("signature",Crypto.hex(sig)).put("signer",config.getString("device"));}finally{Arrays.fill(pair[1],(byte)0);}}
    public static void verify(JSONObject e,String key)throws Exception{byte[] b=payload(e),pk=Crypto.unhex(key),sig=Crypto.unhex(e.getString("signature"));if(pk.length!=32||sig.length!=64)throw new IOException("Signature size");Crypto.check(Crypto.S.crypto_sign_verify_detached(sig,b,b.length,pk));}
    public JSONObject member(String name)throws Exception{byte[][] pair=signing();try{return new JSONObject().put("device",config.getString("device")).put("name",name).put("public_key",new Crypto("","","",config.getString("secret_key"),Collections.emptyMap()).publicKey()).put("signing_key",Crypto.hex(pair[0])).put("manager",false);}finally{Arrays.fill(pair[1],(byte)0);}}
    private void validate(JSONObject s)throws Exception{JSONArray ms=s.getJSONArray("members");Set<String> ids=new HashSet<>();boolean manager=false;for(int i=0;i<ms.length();i++){JSONObject m=ms.getJSONObject(i);if(!ids.add(m.getString("device")))throw new IOException("Duplicate member");manager|=m.getBoolean("manager");}if(s.getInt("version")!=1||!s.getString("app").equals(config.getString("app"))||!s.getString("group").equals(config.getString("group"))||(s.optBoolean("closed")?ms.length()!=0:ms.length()<1)||ms.length()>32||(!s.optBoolean("closed")&&!manager))throw new IOException("Membership scope");}
    private static Map<String,JSONObject> members(JSONObject s)throws Exception{Map<String,JSONObject> r=new LinkedHashMap<>();JSONArray a=s.getJSONArray("members");for(int i=0;i<a.length();i++){JSONObject m=a.getJSONObject(i);r.put(m.getString("device"),m);}return r;}
    private static boolean same(JSONObject a,JSONObject b)throws Exception{if(a.length()!=b.length())return false;for(Iterator<String> i=a.keys();i.hasNext();){String k=i.next();if(!a.get(k).equals(b.opt(k)))return false;}return true;}
    public JSONObject advance(JSONObject current,JSONObject entry)throws Exception{
        JSONObject old=unpack(current),next=unpack(entry);validate(next);Map<String,JSONObject> before=members(old),after=members(next);JSONObject actor=before.get(entry.getString("signer"));if(actor==null||old.optBoolean("closed"))throw new IOException("Untrusted manager");if(!entry.has("authorization"))verify(entry,actor.getString("signing_key"));
        if(!next.optString("name").equals(old.optString("name"))||next.getInt("revision")!=old.getInt("revision")+1||!next.getString("previous").equals(digest(payload(current))))throw new IOException("Broken membership chain");
        if(entry.has("authorization")){advanceAuto(current,entry,old,next,actor);return entry;}
        Set<String> renamed=new HashSet<>();Set<String> added=new HashSet<>(after.keySet()),removed=new HashSet<>(before.keySet());added.removeAll(before.keySet());removed.removeAll(after.keySet());for(String k:before.keySet())if(after.containsKey(k)&&!same(before.get(k),after.get(k))){JSONObject p=before.get(k),n=after.get(k),sameName=new JSONObject(p.toString()).put("name",n.getString("name"));if(same(sameName,n)){renamed.add(k);continue;}if(p.getString("signing_key").isEmpty()&&!n.getString("signing_key").isEmpty()&&p.getString("public_key").equals(n.getString("public_key")))added.add(k);else throw new IOException("Identity replacement");}
        if(!renamed.isEmpty()){if(renamed.size()!=1||!added.isEmpty()||!removed.isEmpty()||!next.getString("invitation").isEmpty()||!next.getString("request_hash").isEmpty()||!(actor.getBoolean("manager")||renamed.contains(entry.getString("signer"))))throw new IOException("Invalid rename");return entry;}
        if(!((next.optBoolean("closed")&&actor.getBoolean("manager")&&after.isEmpty()&&next.getString("invitation").isEmpty()&&next.getString("request_hash").isEmpty())||(actor.getBoolean("manager")&&added.size()==1&&removed.isEmpty()&&!next.getString("invitation").isEmpty()&&!next.getString("request_hash").isEmpty())||(removed.size()==1&&added.isEmpty()&&next.getString("invitation").isEmpty()&&next.getString("request_hash").isEmpty()&&(actor.getBoolean("manager")||removed.contains(entry.getString("signer"))))))throw new IOException("Invalid membership transition");return entry;
    }
    public JSONObject call(String method,String path,JSONObject value,String authorization)throws Exception{
        RequestBody body=value==null?null:RequestBody.create(bytes(value.toString()),MediaType.get("application/json"));Request request=new Request.Builder().url(base+path).header("Authorization",authorization==null?"Bearer "+config.optString("token"):authorization).method(method,body).build();
        try(Response r=http.newCall(request).execute()){if(r.code()!=200||r.body()==null)throw new IOException("Group request failed ("+r.code()+")");try(InputStream in=r.body().byteStream();ByteArrayOutputStream out=new ByteArrayOutputStream()){byte[] b=new byte[8192];int n;while((n=in.read(b))!=-1){if(out.size()+n>3*1024*1024)throw new IOException("Response too large");out.write(b,0,n);}return new JSONObject(out.toString("UTF-8"));}}
    }
    public void accept(JSONObject entry)throws Exception{config.put("group_entry",entry);JSONObject peers=new JSONObject();for(JSONObject m:members(unpack(entry)).values())if(!m.getString("device").equals(config.getString("device")))peers.put(m.getString("device"),m.getString("public_key"));config.put("trusted_peers",peers).put("public_key",member("").getString("public_key"));}
    public JSONObject refresh()throws Exception{JSONObject current=config.getJSONObject("group_entry");while(true){JSONObject result=call("GET","/group?after="+unpack(current).getInt("revision"),null,null);JSONArray entries=result.getJSONArray("entries");for(int i=0;i<entries.length();i++)current=advance(current,entries.getJSONObject(i));accept(current);if(entries.length()==0||unpack(current).getInt("revision")>=result.getInt("revision"))return new JSONObject().put("state",unpack(current)).put("online",result.getJSONArray("online"));}}
    public void prepareCreate(String groupName,String deviceName)throws Exception{
        if(config.has("group_entry")||config.has("pending_join"))throw new IOException("Already enrolled or joining");
        if(config.has("pending_create"))return;
        String title=groupName.trim(),name=deviceName.trim();
        if(bytes(title).length<1||bytes(title).length>128||bytes(name).length<1||bytes(name).length>128||config.has("group"))throw new IOException("Invalid name or existing group");
        config.put("group","g-"+Crypto.hex(Crypto.random(32)).substring(0,32));
        if(!config.has("token"))config.put("token",Crypto.hex(Crypto.random(32)));
        JSONObject own=member(name).put("manager",true);
        config.put("pending_create",sign(new JSONObject().put("version",1).put("app",config.getString("app")).put("group",config.getString("group")).put("name",title).put("revision",1).put("previous","").put("members",new JSONArray().put(own)).put("invitation","").put("request_hash","")));
    }
    public void create()throws Exception{JSONObject e=config.getJSONObject("pending_create");call("POST","/group/create",new JSONObject().put("entry",e).put("token_hash",digest(bytes(config.getString("token")))),null);accept(e);config.remove("pending_create");}
    public void bootstrap(JSONObject code,String name)throws Exception{
        if(!code.getString("app").equals(config.getString("app"))||!code.getString("group").equals(config.getString("group")))throw new IOException("Bootstrap scope");if(!config.has("token"))config.put("token",Crypto.hex(Crypto.random(32)));JSONArray ms=new JSONArray().put(member(name).put("manager",true));JSONObject peers=config.optJSONObject("trusted_peers");if(peers!=null)for(Iterator<String> it=peers.keys();it.hasNext();){String id=it.next();if(!id.equals(config.getString("device")))ms.put(new JSONObject().put("device",id).put("name",id).put("public_key",peers.getString(id)).put("signing_key","").put("manager",false));}
        JSONObject e=sign(new JSONObject().put("version",1).put("app",config.getString("app")).put("group",config.getString("group")).put("revision",1).put("previous","").put("members",ms).put("invitation","").put("request_hash",""));call("POST","/group/bootstrap",new JSONObject().put("entry",e).put("token_hash",digest(bytes(config.getString("token")))),"Bootstrap "+code.getString("bootstrap"));accept(e);
    }
    public JSONObject invite()throws Exception{return invite("manual");}
    public JSONObject invite(String mode)throws Exception{return invite(mode,false);}
    public JSONObject invite(String mode,boolean compact)throws Exception{
        if(!mode.equals("manual")&&!mode.equals("auto"))throw new IOException("Unknown invitation mode");
        refresh();JSONObject current=config.getJSONObject("group_entry"),state=unpack(current),own=members(state).get(config.getString("device"));
        if(!own.getBoolean("manager"))throw new IOException("Manager permission required");
        String secret=Crypto.hex(Crypto.random(32));JSONObject data=new JSONObject().put("secret_hash",digest(bytes(secret))),extra=new JSONObject();
        if(mode.equals("auto")){
            String delegate=Crypto.hex(Crypto.random(32));RelayGroups signer=delegateSigner(delegate,config.getString("device"));
            JSONObject grant=sign(new JSONObject().put("version",1).put("purpose","common-relay/admission/v1").put("mode","auto").put("app",config.getString("app")).put("group",config.getString("group")).put("invitation",Crypto.hex(Crypto.random(16))).put("expires",System.currentTimeMillis()/1000+600).put("secret_hash",data.getString("secret_hash")).put("delegate_key",signer.member("").getString("signing_key")).put("anchor_revision",state.getInt("revision")).put("anchor_hash",digest(payload(current))));
            data.put("mode",mode).put("grant",grant);extra.put("grant",grant).put("delegate_secret",delegate);
        }
        JSONObject r=call("POST","/group/invitations",data,null);
        if(mode.equals("auto")){JSONObject grant=unpack(extra.getJSONObject("grant"));if(!mode.equals(r.optString("mode"))||!grant.getString("invitation").equals(r.getString("id"))||grant.getLong("expires")!=r.getLong("expires"))throw new IOException("Automatic admission unsupported");}
        JSONObject invitation=extra.put("version",1).put("mode",mode).put("url",config.getString("url")).put("app",config.getString("app")).put("group",config.getString("group")).put("id",r.getString("id")).put("expires",r.getLong("expires")).put("secret",secret).put("manager",own);
        if(compact)publishInvitation(invitation);return invitation;
    }
    public String publishInvitation(JSONObject invitation)throws Exception{
        byte[] key=Crypto.random(32);try{
            String packet=InvitationLinks.seal(invitation,key,Crypto.random(24));
            call("POST","/group/invitations/"+invitation.getString("id")+"/link",new JSONObject().put("read_hash",digest(bytes(InvitationLinks.readToken(key)))).put("packet",packet),null);
            String link=InvitationLinks.make(invitation,key);invitation.put("short_link",link);return link;
        }finally{Arrays.fill(key,(byte)0);}
    }
    public JSONObject resolveInvitation(String text)throws Exception{
        InvitationLinks.Parsed p=InvitationLinks.parse(text.trim(),allowLocalTest);
        try{
            RelayGroups endpoint=new RelayGroups(new JSONObject().put("url",p.url),allowLocalTest);
            JSONObject result=endpoint.call("GET","/enroll/"+p.id+"/link",null,"InvitationLink "+InvitationLinks.readToken(p.key));
            if(result.getInt("version")!=1)throw new IOException("Invitation packet version");
            JSONObject inv=InvitationLinks.open(result.getString("packet"),p.key);
            if(inv.getInt("version")!=1||!inv.getString("url").equals(p.url)||!inv.getString("id").equals(p.id)||!inv.getString("app").equals(config.getString("app"))||inv.getLong("expires")<=System.currentTimeMillis()/1000)throw new IOException("Invalid or expired invitation scope");return inv;
        }finally{Arrays.fill(p.key,(byte)0);}
    }
    public JSONObject pending(JSONObject inv)throws Exception{JSONObject e=call("GET","/group/invitations/"+inv.getString("id"),null,null).optJSONObject("request");if(e!=null){JSONObject j=unpack(e);verify(e,j.getJSONObject("member").getString("signing_key"));scope(j,inv);if(!e.getString("signer").equals(j.getJSONObject("member").getString("device")))throw new IOException("Signer mismatch");}return e;}
    private void scope(JSONObject j,JSONObject inv)throws Exception{if(!j.getString("invitation").equals(inv.getString("id"))||!j.getString("app").equals(config.getString("app"))||!j.getString("group").equals(config.getString("group")))throw new IOException("Join scope");}
    public void join(JSONObject inv,String name)throws Exception{if(inv.getInt("version")!=1||inv.getLong("expires")<=System.currentTimeMillis()/1000)throw new IOException("Expired invitation");for(String k:new String[]{"url","app","group"})if(!inv.getString(k).equals(config.getString(k)))throw new IOException("Invitation scope");String mode=inv.optString("mode","manual");if(!mode.equals("manual")&&!mode.equals("auto"))throw new IOException("Unknown invitation mode");if(mode.equals("auto"))invitationGrant(inv);if(!config.has("token"))config.put("token",Crypto.hex(Crypto.random(32)));JSONObject e=sign(new JSONObject().put("version",1).put("app",config.getString("app")).put("group",config.getString("group")).put("invitation",inv.getString("id")).put("member",member(name)).put("token_hash",digest(bytes(config.getString("token")))));JSONObject pending=config.optJSONObject("pending_join");if(pending!=null&&pending.getJSONObject("invitation").getString("id").equals(inv.getString("id")))e=pending.getJSONObject("request");config.put("pending_join",new JSONObject().put("invitation",inv).put("request",e));call("POST","/enroll/"+inv.getString("id"),e,"Invitation "+inv.getString("secret"));}
    public boolean finishJoin()throws Exception{JSONObject p=config.getJSONObject("pending_join"),inv=p.getJSONObject("invitation"),request=p.getJSONObject("request");if(inv.optString("mode").equals("auto"))return finishAuto(p);JSONObject e=call("GET","/enroll/"+inv.getString("id"),null,"Claim "+config.getString("token")).optJSONObject("entry");if(e==null)return false;if(e.has("authorization"))throw new IOException("Unexpected delegated approval");verify(e,inv.getJSONObject("manager").getString("signing_key"));JSONObject g=unpack(e);validate(g);JSONObject own=members(g).get(config.getString("device")),expected=unpack(request).getJSONObject("member");if(own==null)throw new IOException("Missing member");expected.put("manager",own.getBoolean("manager"));if(!e.getString("signer").equals(inv.getJSONObject("manager").getString("device"))||!g.getString("invitation").equals(inv.getString("id"))||!g.getString("request_hash").equals(digest(payload(request)))||!same(own,expected))throw new IOException("Approval mismatch");accept(e);config.remove("pending_join");return true;}
    private RelayGroups delegateSigner(String secret,String device)throws Exception{
        return new RelayGroups(new JSONObject(config.toString()).put("secret_key",secret).put("device",device),base.startsWith("http://127.0.0.1:"));
    }
    private static boolean sameEntry(JSONObject a,JSONObject b)throws Exception{
        if(a==null||b==null)return a==b;
        return a.getString("payload").equals(b.getString("payload"))&&a.getString("signature").equals(b.getString("signature"))&&a.getString("signer").equals(b.getString("signer"))&&sameEntry(a.optJSONObject("authorization"),b.optJSONObject("authorization"));
    }
    private JSONObject validateGrant(JSONObject e,JSONObject owner,JSONObject state)throws Exception{
        if(e==null||e.has("authorization")||!owner.getBoolean("manager")||!e.getString("signer").equals(owner.getString("device")))throw new IOException("Invalid admission grant");
        verify(e,owner.getString("signing_key"));JSONObject g=unpack(e);
        if(g.getInt("version")!=1||!g.getString("purpose").equals("common-relay/admission/v1")||!g.getString("mode").equals("auto")||!g.getString("app").equals(state.getString("app"))||!g.getString("group").equals(state.getString("group"))||g.getInt("anchor_revision")<1||g.getInt("anchor_revision")>state.getInt("revision")||g.getLong("expires")<=0)throw new IOException("Admission grant scope");
        for(String k:new String[]{"invitation","secret_hash","delegate_key","anchor_hash"})if(!g.getString(k).matches(k.equals("invitation")?"[0-9a-f]{32}":"[0-9a-f]{64}"))throw new IOException("Admission grant encoding");return g;
    }
    private void advanceAuto(JSONObject current,JSONObject entry,JSONObject old,JSONObject next,JSONObject actor)throws Exception{
        JSONObject grant=validateGrant(entry.getJSONObject("authorization"),actor,old);verify(entry,grant.getString("delegate_key"));
        Map<String,JSONObject> before=members(old),after=members(next);
        if(next.optBoolean("closed")||!next.getString("invitation").equals(grant.getString("invitation"))||!next.getString("request_hash").matches("[0-9a-f]{64}")||after.size()!=before.size()+1)throw new IOException("Invalid automatic admission");
        for(String k:before.keySet())if(!after.containsKey(k)||!same(before.get(k),after.get(k)))throw new IOException("Automatic admission changed member");
        for(String k:after.keySet())if(!before.containsKey(k)&&after.get(k).getBoolean("manager"))throw new IOException("Automatic manager forbidden");
        if(old.getInt("revision")==grant.getInt("anchor_revision")&&!digest(payload(current)).equals(grant.getString("anchor_hash")))throw new IOException("Admission anchor mismatch");
    }
    private JSONObject invitationGrant(JSONObject inv)throws Exception{
        JSONObject g=unpack(inv.getJSONObject("grant"));validateGrant(inv.getJSONObject("grant"),inv.getJSONObject("manager"),new JSONObject().put("app",config.getString("app")).put("group",config.getString("group")).put("revision",g.getInt("anchor_revision")));
        if(!g.getString("invitation").equals(inv.getString("id"))||g.getLong("expires")!=inv.getLong("expires")||!g.getString("secret_hash").equals(digest(bytes(inv.getString("secret"))))||!g.getString("delegate_key").equals(delegateSigner(inv.getString("delegate_secret"),inv.getJSONObject("manager").getString("device")).member("").getString("signing_key")))throw new IOException("Invitation grant mismatch");return g;
    }
    private boolean finishAuto(JSONObject pending)throws Exception{
        JSONObject inv=pending.getJSONObject("invitation"),grant=invitationGrant(inv),request=pending.getJSONObject("request"),req=unpack(request),current=null,result;
        int after=grant.getInt("anchor_revision")-1;
        String path="/enroll/"+inv.getString("id")+"/auto",auth="Claim "+config.getString("token");
        while(true){
            result=call("GET",path+"?after="+after,null,auth);if(result.getInt("revision")<grant.getInt("anchor_revision")||result.getInt("revision")>4096)throw new IOException("Admission revision");JSONArray entries=result.getJSONArray("entries");if(entries.length()==0)throw new IOException("Incomplete admission chain");
            for(int i=0;i<entries.length();i++){JSONObject e=entries.getJSONObject(i);if(current==null){if(!digest(payload(e)).equals(grant.getString("anchor_hash"))||unpack(e).getInt("revision")!=grant.getInt("anchor_revision"))throw new IOException("Admission anchor mismatch");validate(unpack(e));current=e;}else current=advance(current,e);}
            int revision=unpack(current).getInt("revision");if(revision<=after||revision>result.getInt("revision"))throw new IOException("Admission revision");after=revision;if(after==result.getInt("revision"))break;
        }
        JSONObject e;
        if(result.optJSONObject("entry")!=null){if(!sameEntry(current,result.getJSONObject("entry")))throw new IOException("Admission tip mismatch");e=current;}
        else{
            JSONObject g=unpack(current);g.getJSONArray("members").put(req.getJSONObject("member"));g.put("revision",g.getInt("revision")+1).put("previous",digest(payload(current))).put("invitation",inv.getString("id")).put("request_hash",digest(payload(request)));
            e=delegateSigner(inv.getString("delegate_secret"),inv.getJSONObject("manager").getString("device")).sign(g).put("authorization",inv.getJSONObject("grant"));advance(current,e);pending.put("auto_entry",e);
            if(!sameEntry(e,call("POST",path,e,auth)))throw new IOException("Admission response mismatch");
        }
        JSONObject g=unpack(e),own=members(g).get(config.getString("device"));
        if(!sameEntry(e.optJSONObject("authorization"),inv.getJSONObject("grant"))||!g.getString("invitation").equals(inv.getString("id"))||!g.getString("request_hash").equals(digest(payload(request)))||own==null||!same(own,req.getJSONObject("member")))throw new IOException("Automatic approval mismatch");
        accept(e);config.remove("pending_join");return true;
    }
    public void approve(JSONObject inv,JSONObject request,boolean manager)throws Exception{refresh();JSONObject j=unpack(request);verify(request,j.getJSONObject("member").getString("signing_key"));scope(j,inv);JSONObject g=unpack(config.getJSONObject("group_entry"));JSONArray ms=new JSONArray();for(JSONObject m:members(g).values())if(!m.getString("device").equals(j.getJSONObject("member").getString("device")))ms.put(m);ms.put(j.getJSONObject("member").put("manager",manager));g.put("members",ms);g.put("invitation",inv.getString("id")).put("request_hash",digest(payload(request)));change(g);}
    public void remove(String device)throws Exception{if(device.equals(config.getString("device")))throw new IOException("Use exit for yourself");refresh();JSONObject g=unpack(config.getJSONObject("group_entry"));JSONArray a=new JSONArray();for(JSONObject m:members(g).values())if(!device.equals(m.getString("device")))a.put(m);g.put("members",a).put("invitation","").put("request_hash","");change(g);}
    public void rename(String device,String name)throws Exception{
        name=name.trim();if(bytes(name).length<1||bytes(name).length>128)throw new IOException("Name required");refresh();JSONObject g=unpack(config.getJSONObject("group_entry")),m=members(g).get(device);if(m==null)throw new IOException("Member not found");if(m.getString("name").equals(name))return;m.put("name",name);g.put("invitation","").put("request_hash","");change(g);
    }
    public void prepareExit(boolean disband)throws Exception{
        if(config.has("pending_exit"))return;refresh();JSONObject old=config.getJSONObject("group_entry"),g=unpack(old),own=members(g).get(config.getString("device"));
        if(own==null||(disband&&!own.getBoolean("manager")))throw new IOException("Manager permission required");
        JSONArray after=new JSONArray();if(!disband)for(JSONObject m:members(g).values())if(!m.getString("device").equals(config.getString("device")))after.put(m);
        g.put("members",after);if(after.length()==0)g.put("closed",true);
        g.put("invitation","").put("request_hash","").put("revision",g.getInt("revision")+1).put("previous",digest(payload(old)));JSONObject e=sign(g);advance(old,e);config.put("pending_exit",e);
    }
    public void exit()throws Exception{JSONObject e=config.getJSONObject("pending_exit");try{call("POST","/group/exit",e,null);}catch(IOException error){if(error.getMessage().contains("409"))config.remove("pending_exit");throw error;}accept(e);config.remove("pending_exit");}
    public void cancel(JSONObject inv)throws Exception{call("DELETE","/group/invitations/"+inv.getString("id"),null,null);}
    private void change(JSONObject g)throws Exception{JSONObject old=config.getJSONObject("group_entry");g.put("revision",g.getInt("revision")+1).put("previous",digest(payload(old)));JSONObject e=sign(g);advance(old,e);call("PUT","/group",e,null);accept(e);}
}
