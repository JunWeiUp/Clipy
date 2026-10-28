package com.clipyclone.nativeandroid.relay.securestorage.ciphers;

import android.content.Context;

import javax.crypto.Cipher;

@FunctionalInterface
interface StorageCipherFunction {
    StorageCipher apply(Context context, KeyCipher keyCipher, Cipher cipher) throws Exception;
}
