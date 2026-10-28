package com.clipyclone.nativeandroid.relay.securestorage;

public interface SecurePreferencesCallback<T> {
    void onSuccess(T result);
    void onError(Exception e);
}
