package com.clipyclone.nativeandroid.relay.sdk;

/** Android API24-compatible equivalents of the SDK's Java Base64 calls. */
final class AndroidBase64 {
    static String encode(byte[] value) { return android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP); }
    static byte[] decode(String value) {
        // Strict signed payloads require padded standard base64 with no whitespace.
        if(value.length()%4!=0||!value.matches("[A-Za-z0-9+/]*={0,2}"))throw new IllegalArgumentException("Non-canonical base64");
        byte[] decoded=android.util.Base64.decode(value,android.util.Base64.NO_WRAP);
        if(!encode(decoded).equals(value))throw new IllegalArgumentException("Non-canonical base64");
        return decoded;
    }
    static String urlEncode(byte[] value) { return android.util.Base64.encodeToString(value, android.util.Base64.URL_SAFE | android.util.Base64.NO_PADDING | android.util.Base64.NO_WRAP); }
    static byte[] urlDecode(String value) {
        if(!value.matches("[A-Za-z0-9_-]*"))throw new IllegalArgumentException("Non-canonical URL base64");
        byte[] decoded=android.util.Base64.decode(value,android.util.Base64.URL_SAFE|android.util.Base64.NO_WRAP);
        if(!urlEncode(decoded).equals(value))throw new IllegalArgumentException("Non-canonical URL base64");
        return decoded;
    }
}
