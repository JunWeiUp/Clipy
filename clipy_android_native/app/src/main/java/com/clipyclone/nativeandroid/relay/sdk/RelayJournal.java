package com.clipyclone.nativeandroid.relay.sdk;

import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.function.LongSupplier;

/** API24 java.io port of the common-relay journal; same keys/records as Dart and Java SDKs. */
public final class RelayJournal {
    private static final long RETENTION=7*86400;
    private final File directory;
    private final LongSupplier clock;
    public RelayJournal(File directory)throws Exception{this(directory,()->System.currentTimeMillis()/1000);}
    public RelayJournal(File directory,LongSupplier clock)throws Exception{this.directory=directory;this.clock=clock;if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Journal unavailable");cleanup();}
    private static String digest(byte[] data)throws Exception{return Crypto.hex(MessageDigest.getInstance("SHA-256").digest(data));}
    private File path(String scope,String kind,String sender,String id)throws Exception{return new File(directory,digest(new JSONArray().put(scope).put(kind).put(sender).put(id).toString().replace("\\/","/").getBytes(StandardCharsets.UTF_8))+".json");}
    private JSONObject read(File file)throws Exception{
        if(!file.exists())return null;
        try(InputStream in=new FileInputStream(file);ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] b=new byte[8192];int count;while((count=in.read(b))!=-1)out.write(b,0,count);
            return new JSONObject(new String(out.toByteArray(),StandardCharsets.UTF_8));
        }
    }
    private void write(File file,JSONObject record)throws Exception{
        File temporary=File.createTempFile("journal-",".tmp",directory);
        try{try(FileOutputStream out=new FileOutputStream(temporary)){out.write(record.toString().getBytes(StandardCharsets.UTF_8));out.getFD().sync();}
            if(!temporary.renameTo(file))throw new IOException("Journal publication failed");
        }finally{if(temporary.exists())temporary.delete();}
    }
    public interface Seal {String seal(long expires)throws Exception;}
    synchronized JSONObject prepare(String scope,String id,String to,byte[] data,long ttl,Seal seal)throws Exception{
        if(ttl<1||ttl>86400)throw new IllegalArgumentException("TTL");
        File file=path(scope,"out","",id);long now=clock.getAsLong();String digest=digest(data);JSONObject row=read(file);
        if(row!=null){if(!row.getString("recipient").equals(to)||!row.getString("digest").equals(digest))throw new IOException("Message ID content conflict");if(row.getString("status").equals("received"))return row;if(!row.getString("status").equals("pending")||row.getLong("expires")<=now)throw new IOException("Message expired");return row;}
        long expires=now+ttl;row=new JSONObject().put("recipient",to).put("digest",digest).put("body",seal.seal(expires)).put("expires",expires).put("purge",expires+RETENTION).put("status","pending");write(file,row);return row;
    }
    synchronized void complete(String scope,String id)throws Exception{File file=path(scope,"out","",id);JSONObject row=read(file);if(row!=null){row.remove("body");row.put("status","received").put("purge",clock.getAsLong()+RETENTION);write(file,row);}}
    synchronized boolean contains(String scope,String sender,String id)throws Exception{JSONObject row=read(path(scope,"in",sender,id));return row!=null&&row.getLong("purge")>clock.getAsLong();}
    synchronized void acknowledge(String scope,String sender,String id)throws Exception{File file=path(scope,"in",sender,id);JSONObject row=read(file);if(row==null||row.getLong("purge")<=clock.getAsLong())write(file,new JSONObject().put("purge",clock.getAsLong()+RETENTION));}
    public synchronized void cleanup()throws Exception{
        long now=clock.getAsLong();int changed=0;File[] files=directory.listFiles();if(files==null)return;
        for(File file:files){if(changed>=256)break;if(!file.isFile()||!file.getName().matches("[a-f0-9]{64}\\.json"))continue;JSONObject row=read(file);
            if(row.getLong("purge")<=now){if(file.delete())changed++;}
            else if(row.optString("status").equals("pending")&&row.getLong("expires")<=now){row.remove("body");row.put("status","expired");write(file,row);changed++;}
        }
    }
}
