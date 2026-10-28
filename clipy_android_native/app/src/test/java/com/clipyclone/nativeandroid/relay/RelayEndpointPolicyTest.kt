package com.clipyclone.nativeandroid.relay

import org.junit.Assert.*
import org.junit.Test

class RelayEndpointPolicyTest {
    private val endpoint = "ws://127.0.0.1:63350/relay/v1/ws"
    @Test fun onlyDebuggableIsolatedPreviewPermitsLoopback() {
        assertTrue(RelayEndpointPolicy.forApp(true, "com.clipyclone.clipy_android.nativepreview").allowsCleartext(endpoint))
        for (debug in listOf(false, true)) {
            assertFalse(RelayEndpointPolicy.forApp(debug, "com.clipyclone.clipy_android").allowsCleartext(endpoint))
            assertFalse(RelayEndpointPolicy.forApp(debug, "other.nativepreview").allowsCleartext(endpoint))
        }
        assertFalse(RelayEndpointPolicy.forApp(false, "com.clipyclone.clipy_android.nativepreview").allowsCleartext(endpoint))
    }
    @Test fun rejectsOtherHostsSchemesPathsAndAmbiguousScopes() {
        val policy = RelayEndpointPolicy.forApp(true, "com.clipyclone.clipy_android.nativepreview")
        for (bad in listOf(
            "ws://localhost:63350/relay/v1/ws", "ws://127.0.0.2:63350/relay/v1/ws",
            "ws://10.0.2.2:63350/relay/v1/ws", "ws://example.com:63350/relay/v1/ws",
            "http://127.0.0.1:63350/relay/v1/ws", "wss://127.0.0.1:63350/relay/v1/ws",
            "ws://127.0.0.1:63350/other", "ws://127.0.0.1:63350/relay/v1/ws/",
            "ws://127.0.0.1:63350/relay/v1/%77s", "ws://user@127.0.0.1:63350/relay/v1/ws",
            "ws://127.0.0.1:63350/relay/v1/ws?test=1", "ws://127.0.0.1:63350/relay/v1/ws#test",
            "ws://127.0.0.1/relay/v1/ws", "ws://127.0.0.1:0/relay/v1/ws", "ws://127.0.0.1:65536/relay/v1/ws"
        )) assertFalse(bad, policy.allowsCleartext(bad))
    }
}
