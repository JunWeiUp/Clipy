// Adapted from JunWeiUp/common-relay Java SDK, commit 794a2396266ee6f26ab7406f6d6466732a269dbf.
package com.clipyclone.nativeandroid.relay.sdk;

import okhttp3.*;
import okio.ByteString;
import org.json.*;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** One connection lifetime. Reconnects are explicit and never replay streams or control operations. */
public final class RelayClient implements AutoCloseable {
    public interface Listener {
        void onReady();
        void onEvent(JSONObject event);
        void onClosed(Throwable error);
    }
    private static final ScheduledThreadPoolExecutor REQUEST_TIMEOUTS = requestTimeouts();
    private static ScheduledThreadPoolExecutor requestTimeouts(){
        ScheduledThreadPoolExecutor timer=new ScheduledThreadPoolExecutor(1,r->{Thread t=new Thread(r,"relay-request-timeout");t.setDaemon(true);return t;});
        timer.setRemoveOnCancelPolicy(true);return timer;
    }
    private final Crypto crypto;
    private final Listener listener;
    private final OkHttpClient http;
    private final Map<String,CompletableFuture<JSONObject>> pending=new ConcurrentHashMap<>();
    private final Map<String,Stream> streams=new ConcurrentHashMap<>();
    private final AtomicBoolean closed=new AtomicBoolean();
    private WebSocket socket;
    private final RelayJournal journal;
    private ScheduledExecutorService cleaner;
    private String scope(){return crypto.app+"/"+crypto.group+"/"+crypto.device;}
    public void cleanup()throws Exception{if(journal!=null)journal.cleanup();}
    public RelayClient(OkHttpClient http,Crypto crypto,Listener listener){this(http,crypto,listener,null);}
    public RelayClient(OkHttpClient http,Crypto crypto,Listener listener,RelayJournal journal){this.http=http;this.crypto=crypto;this.listener=listener;this.journal=journal;}
    public void connect(String url,String token){connect(url,token,false);}
    public void connect(String url,String token,boolean allowLocalTest){
        java.net.URI uri=java.net.URI.create(url);
        boolean local=allowLocalTest&&"ws".equals(uri.getScheme())&&"127.0.0.1".equals(uri.getHost());
        if((!"wss".equals(uri.getScheme())&&!local)||token.length()<32)throw new IllegalArgumentException("WSS and device credential required");
        if(journal!=null){cleaner=Executors.newSingleThreadScheduledExecutor(r->{Thread t=new Thread(r,"relay-cleanup");t.setDaemon(true);return t;});cleaner.scheduleAtFixedRate(()->{try{cleanup();}catch(Exception e){fail(e);}},1,1,TimeUnit.HOURS);}
        socket=http.newWebSocket(new Request.Builder().url(url).header("Authorization","Bearer "+token).header("Sec-WebSocket-Protocol","common-relay.v1").build(),new WebSocketListener(){
            @Override public void onOpen(WebSocket ws,Response response){if(!"common-relay.v1".equals(response.header("Sec-WebSocket-Protocol")))fail(new IOException("Protocol mismatch"));}
            @Override public void onMessage(WebSocket ws,String text){try{dispatch(new JSONObject(text));}catch(Exception e){fail(e);}}
            @Override public void onMessage(WebSocket ws,ByteString bytes){try{binary(bytes.toByteArray());}catch(Exception e){fail(e);}}
            @Override public void onFailure(WebSocket ws,Throwable error,Response response){fail(error);}
            @Override public void onClosed(WebSocket ws,int code,String reason){fail(new IOException("Connection closed"));}
            @Override public void onClosing(WebSocket ws,int code,String reason){ws.close(code,reason);fail(new IOException("Connection closing"));}
        });
    }
    public void send(JSONObject event)throws IOException {if(closed.get()||socket==null||socket.queueSize()>4<<20||!socket.send(event.toString()))throw new IOException("Connection unavailable or backpressure");}
    public CompletableFuture<JSONObject> request(JSONObject event)throws Exception{
        String id=event.optString("id",UUID.randomUUID().toString().replace("-",""));event.put("id",id);CompletableFuture<JSONObject> result=new CompletableFuture<>();
        if(pending.putIfAbsent(id,result)!=null)throw new IllegalStateException("Request already pending");
        ScheduledFuture<?> timeout=REQUEST_TIMEOUTS.schedule(()->result.completeExceptionally(new TimeoutException("Relay request timed out")),45,TimeUnit.SECONDS);
        result.whenComplete((v,e)->{timeout.cancel(false);pending.remove(id,result);});try{send(event);}catch(Exception e){result.completeExceptionally(e);}return result;
    }
    public CompletableFuture<JSONObject> peers()throws Exception{return request(new JSONObject().put("type","peers"));}
    /** Enqueues an online-only frame. Success is not a server/device/business receipt. No replay. */
    public void sendOnline(String to,byte[] data)throws Exception{
        String id=UUID.randomUUID().toString().replace("-","");
        String body=crypto.seal(to,"message",id,new JSONObject().put("data",AndroidBase64.encode(data)));
        send(new JSONObject().put("type","message").put("id",id).put("to",to).put("body",body).put("offline",false));
    }
    public CompletableFuture<JSONObject> message(String to,byte[] data,boolean offline,String id)throws Exception{
        final String objectId=id==null?UUID.randomUUID().toString().replace("-",""):id;
        String body;long expires=0;
        if(offline){
            if(journal==null)throw new IOException("Persistent state required");
            JSONObject row=journal.prepare(scope(),objectId,to,data,86400,expiry->crypto.seal(to,"message",objectId,new JSONObject().put("data",AndroidBase64.encode(data)).put("expires",expiry)));
            if(row.getString("status").equals("received"))return CompletableFuture.completedFuture(new JSONObject().put("type","received").put("id",objectId));
            body=row.getString("body");expires=row.getLong("expires");
        }else body=crypto.seal(to,"message",objectId,new JSONObject().put("data",AndroidBase64.encode(data)));
        return request(new JSONObject().put("type","message").put("id",objectId).put("to",to).put("body",body).put("offline",offline).put("expires",expires)).thenApply(result->{
            try{if(offline&&result.optString("type").equals("received"))journal.complete(scope(),objectId);return result;}catch(Exception e){throw new CompletionException(e);}
        });
    }
    public CompletableFuture<JSONObject> acknowledge(JSONObject event)throws Exception{
        if(event.optBoolean("offline")&&journal==null)throw new IOException("Persistent state required");
        if(journal!=null)journal.acknowledge(scope(),event.getString("from"),event.getString("id"));
        return request(new JSONObject().put("type","ack").put("id",event.getString("id")).put("from",event.getString("from")));
    }
    public CompletableFuture<Stream> openStream(String peer)throws Exception{
        String id=UUID.randomUUID().toString().replace("-","");Stream stream=new Stream(peer,id,new Crypto.SecretStream());streams.put(id,stream);
        return request(new JSONObject().put("type","stream.open").put("id",id).put("to",peer).put("body",crypto.seal(peer,"stream.open",id,stream.encryptor.descriptor()))).thenApply(event->{try{stream.initializeDecryptor(crypto.open(peer,"stream.accept",id,event.getString("body")));return stream;}catch(Exception e){stream.close();throw new CompletionException(e);}}).whenComplete((v,e)->{if(e!=null)stream.close();});
    }
    public CompletableFuture<Stream> acceptStream(JSONObject event)throws Exception{
        String id=event.getString("id"),peer=event.getString("from");Stream stream=new Stream(peer,id,new Crypto.SecretStream());stream.initializeDecryptor(crypto.open(peer,"stream.open",id,event.getString("body")));streams.put(id,stream);
        return request(new JSONObject().put("type","stream.accept").put("id",id).put("body",crypto.seal(peer,"stream.accept",id,stream.encryptor.descriptor()))).thenApply(v->stream).whenComplete((v,e)->{if(e!=null)stream.close();});
    }
    public void rejectStream(JSONObject event)throws Exception{send(new JSONObject().put("type","stream.close").put("id",event.getString("id")));}
    private void dispatch(JSONObject event)throws Exception{
        String type=event.getString("type"),id=event.optString("id");
        if(type.equals("welcome")){JSONObject d=event.getJSONObject("identity");if(event.getInt("version")!=1||!d.getString("app").equals(crypto.app)||!d.getString("group").equals(crypto.group)||!d.getString("device").equals(crypto.device)||!d.getString("public_key").equals(crypto.publicKey()))throw new IOException("Identity mismatch");listener.onReady();return;}
        if(type.equals("stream.credit")){Stream s=streams.get(id);if(s!=null)s.credit(event.getLong("sequence"));return;}
        if(type.equals("stream.close")){Stream s=streams.remove(id);if(s!=null)s.abort();CompletableFuture<JSONObject> p=pending.remove(id);if(p!=null)p.completeExceptionally(new IOException("Stream closed"));return;}
        if(!type.equals("message")&&!type.equals("stream.open")){CompletableFuture<JSONObject> p=pending.remove(id);if(p!=null){if(type.equals("error"))p.completeExceptionally(new IOException(event.optString("code")));else p.complete(event);return;}}
        if(type.equals("message")){
            if(event.optBoolean("offline")&&journal==null)throw new IOException("Persistent state required for offline reception");
            String from=event.getString("from");JSONObject value=crypto.open(from,"message",id,event.getString("body"));
            if((value.has("expires")&&value.getLong("expires")<=System.currentTimeMillis()/1000)||(journal!=null&&journal.contains(scope(),from,id))){if(event.optBoolean("offline"))send(new JSONObject().put("type","ack").put("id",id).put("from",from));return;}
            event.put("data",value.getString("data"));
        }
        if(type.equals("message")||type.equals("stream.open")||type.equals("peer.up")||type.equals("peer.down")||type.equals("group.changed"))listener.onEvent(event);
    }
    private void binary(byte[] data)throws Exception{if(data.length<26||data.length>65561||data[0]!=1)throw new IOException("Invalid frame");ByteBuffer b=ByteBuffer.wrap(data);b.get();byte[] id=new byte[16];b.get(id);long seq=b.getLong();Stream s=streams.get(Crypto.hex(id));if(s==null)return;if(!s.queue.offer(new Record(seq,Arrays.copyOfRange(data,25,data.length)))){s.close();}}
    private void fail(Throwable error){if(!closed.compareAndSet(false,true))return;if(cleaner!=null)cleaner.shutdownNow();if(socket!=null)socket.cancel();for(Stream s:streams.values())s.abort();streams.clear();for(CompletableFuture<JSONObject> f:pending.values())f.completeExceptionally(error);pending.clear();listener.onClosed(error);}
    @Override public void close(){fail(new IOException("Client stopped"));}
    private static final class Record { final long sequence;final byte[] data;Record(long sequence,byte[] data){this.sequence=sequence;this.data=data;} }
    public final class Stream implements AutoCloseable {
        public final String peer,id;
        private final Crypto.SecretStream encryptor;
        private volatile Crypto.SecretStream decryptor;
        private final BlockingQueue<Record> queue=new ArrayBlockingQueue<>(16);
        private final Semaphore window=new Semaphore(8);
        private final AtomicBoolean stopped=new AtomicBoolean();
        private volatile long tx=0,rx=0,ack=0;
        private Stream(String peer,String id,Crypto.SecretStream enc){this.peer=peer;this.id=id;this.encryptor=enc;}
        private void initializeDecryptor(JSONObject descriptor)throws Exception {
            Crypto.SecretStream value=new Crypto.SecretStream(descriptor);
            if(stopped.get()){value.close();throw new IOException("Stream closed");}
            decryptor=value;
            if(stopped.get()){value.close();throw new IOException("Stream closed");}
        }
        public synchronized void send(byte[] data,boolean last)throws Exception{
            if(stopped.get())throw new IOException("Stream closed");
            for(int offset=0;offset<Math.max(1,data.length);offset+=65519){if(!window.tryAcquire(30,TimeUnit.SECONDS)||stopped.get())throw new IOException("Stream closed or stalled");byte[] part=Arrays.copyOfRange(data,offset,Math.min(data.length,offset+65519));byte[] cipher=encryptor.push(part,crypto.aad(crypto.device,peer,"stream",id,tx),last&&offset+65519>=data.length);ByteBuffer b=ByteBuffer.allocate(25+cipher.length).put((byte)1).put(Crypto.unhex(id)).putLong(tx).put(cipher);tx++;if(!socket.send(ByteString.of(b.array())))throw new IOException("Transport closed");}
        }
        public byte[] receive()throws Exception{if(stopped.get())throw new IOException("Stream interrupted");Record r=queue.take();if(r.sequence<0||stopped.get())throw new IOException("Stream interrupted");if(r.sequence!=rx||decryptor==null)throw new IOException("Invalid sequence");byte[] plain=decryptor.pull(r.data,crypto.aad(peer,crypto.device,"stream",id,rx));rx++;RelayClient.this.send(new JSONObject().put("type","stream.credit").put("id",id).put("sequence",rx));return plain;}
        public boolean receivedFinal(){return decryptor!=null&&decryptor.finished;}
        private void credit(long sequence)throws IOException{if(sequence<ack||sequence>tx)throw new IOException("Invalid credit");window.release((int)(sequence-ack));ack=sequence;}
        private void abort(){if(!stopped.compareAndSet(false,true))return;window.release(8);queue.clear();queue.offer(new Record(-1,null));encryptor.close();if(decryptor!=null)decryptor.close();}
        @Override public void close(){abort();streams.remove(id,this);try{RelayClient.this.send(new JSONObject().put("type","stream.close").put("id",id));}catch(Exception ignored){}}
    }
}
