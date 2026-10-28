package com.clipyclone.nativeandroid.relay

import android.content.Context
import android.content.pm.ApplicationInfo
import java.net.URI

/** Local fixture transport is only available to the isolated debuggable preview. */
internal class RelayEndpointPolicy private constructor(val allowLocalTest: Boolean) {
    fun allowsCleartext(value: String): Boolean = allowLocalTest && runCatching {
        val uri = URI(value)
        uri.scheme == "ws" && uri.host == "127.0.0.1" && uri.port in 1..65535 &&
            uri.rawPath == "/relay/v1/ws" && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null
    }.getOrDefault(false)

    fun accepts(value: String): Boolean = RelayConfiguration.validUrl(value) || allowsCleartext(value)

    companion object {
        fun forApp(debuggable: Boolean, packageName: String) = RelayEndpointPolicy(
            debuggable && packageName == "com.clipyclone.clipy_android.nativepreview")
        fun from(context: Context) = forApp(
            context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0, context.packageName)
    }
}
