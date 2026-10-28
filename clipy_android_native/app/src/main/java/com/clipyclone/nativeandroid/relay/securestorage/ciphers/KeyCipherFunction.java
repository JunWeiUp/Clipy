package com.clipyclone.nativeandroid.relay.securestorage.ciphers;

import android.content.Context;
import com.clipyclone.nativeandroid.relay.securestorage.FlutterSecureStorageConfig;

@FunctionalInterface
interface KeyCipherFunction {
    KeyCipher apply(Context context, FlutterSecureStorageConfig config) throws Exception;
}
