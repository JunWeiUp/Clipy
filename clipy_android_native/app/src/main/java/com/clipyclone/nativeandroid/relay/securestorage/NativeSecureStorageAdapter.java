package com.clipyclone.nativeandroid.relay.securestorage;

import android.content.Context;
import java.util.HashMap;

/** Native access to the shipping secure-store format; no Flutter engine, channel, or reset fallback. */
public final class NativeSecureStorageAdapter extends FlutterSecureStorage {
    public NativeSecureStorageAdapter(Context context) { super(context); }
    public void initializeNative(SecurePreferencesCallback<Void> callback) {
        HashMap<String,Object> options=new HashMap<>();
        // Flutter's Dart AndroidOptions supplies OAEP explicitly; Java's fallback
        // is historical PKCS1. Omitting this would re-encrypt existing credentials.
        options.put("keyCipherAlgorithm","RSA_ECB_OAEPwithSHA_256andMGF1Padding");
        options.put("storageCipherAlgorithm","AES_GCM_NoPadding");
        options.put("resetOnError","false");
        options.put("migrateOnAlgorithmChange","true");
        initialize(new FlutterSecureStorageConfig(options),callback);
    }
    public String get(String key)throws Exception{return read(addPrefixToKey(key));}
    public void put(String key,String value)throws Exception{write(addPrefixToKey(key),value);}
}
