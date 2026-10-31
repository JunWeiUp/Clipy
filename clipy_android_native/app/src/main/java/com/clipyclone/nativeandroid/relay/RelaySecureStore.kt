package com.clipyclone.nativeandroid.relay

import android.content.Context
import com.clipyclone.nativeandroid.relay.securestorage.NativeSecureStorageAdapter
import com.clipyclone.nativeandroid.relay.securestorage.SecurePreferencesCallback
import io.github.junweiup.commonrelay.Crypto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Uses the exact existing Android keystore aliases and encrypted preference keys. */
class RelaySecureStore(context: Context) {
    private val delegate = NativeSecureStorageAdapter(context.applicationContext)
    private val mutex = Mutex()
    private var initialized = false
    private suspend fun initialize() {
        if (initialized) return
        suspendCancellableCoroutine<Unit> { continuation ->
            delegate.initializeNative(object : SecurePreferencesCallback<Void> {
                override fun onSuccess(result: Void?) { if (continuation.isActive) continuation.resume(Unit) }
                override fun onError(error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
            })
        }
        initialized = true
    }
    suspend fun read(key: String): String = withContext(Dispatchers.IO) { mutex.withLock { initialize(); delegate.get(key) ?: "" } }
    suspend fun write(key: String, value: String) = withContext(Dispatchers.IO) { mutex.withLock { initialize(); delegate.put(key, value) } }
    suspend fun identity(): JSONObject = withContext(Dispatchers.IO) {
        mutex.withLock {
            initialize()
            val raw = delegate.get("commonRelayIdentity")
            if (raw != null) {
                val identity = JSONObject(raw)
                val derived = Crypto("clipy", "", "", identity.getString("secret_key"), emptyMap()).publicKey()
                check(derived == identity.getString("public_key")) { "Identity key mismatch" }
                identity
            } else {
                for (name in listOf("commonRelayConfig", "commonRelayGroupDraft", "commonRelayGroupExit")) {
                    val candidate = delegate.get(name)?.takeIf { it.isNotEmpty() }?.let(::JSONObject) ?: continue
                    if (!candidate.has("secret_key")) continue
                    val secret = candidate.getString("secret_key")
                    val public = Crypto("clipy", "", "", secret, emptyMap()).publicKey()
                    check(public == candidate.getString("public_key")) { "Existing enrollment identity mismatch" }
                    return@withLock JSONObject().put("secret_key", secret).put("public_key", public).also {
                        delegate.put("commonRelayIdentity", it.toString())
                    }
                }
                val secret = Crypto.hex(Crypto.random(32))
                val public = Crypto("clipy", "", "", secret, emptyMap()).publicKey()
                JSONObject().put("secret_key", secret).put("public_key", public).also { delegate.put("commonRelayIdentity", it.toString()) }
            }
        }
    }
    suspend fun publicInfo(device: String): String {
        require(RelayConfiguration.validDevice(device))
        return JSONObject().put("app", "clipy").put("device", device).put("public_key", identity().getString("public_key")).toString()
    }
}

object RelayConfiguration {
    fun validDevice(value: String) = Regex("^[A-Za-z0-9_-]{1,80}$").matches(value)
    fun validUrl(value: String): Boolean = runCatching {
        val uri = java.net.URI(value)
        uri.scheme == "wss" && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.query == null && uri.fragment == null && uri.path == "/relay/v1/ws"
    }.getOrDefault(false)
    fun lanPeer(relayId: String, presence: JSONObject?): String? {
        val id = presence?.optString("peerId", relayId) ?: relayId
        return id.takeIf { Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").matches(it) }
    }
    fun update(existing: String, device: String, accessKey: String, enrollment: String): JSONObject {
        require(validDevice(device)) { "invalidDevice" }
        val raw = enrollment.ifEmpty { existing }
        val value = if (raw.isEmpty()) JSONObject() else JSONObject(raw)
        if (value.length() == 0) { require(accessKey.isEmpty()) { "enrollmentRequired" }; return value }
        require(enrollment.isEmpty() || value.opt("device") == device) { "deviceMismatch" }
        value.put("device", device)
        if (accessKey.isNotEmpty()) value.put("token", accessKey)
        val group = value.opt("group") as? String
        val token = value.opt("token") as? String
        require(value.opt("app") == "clipy" && group != null && validDevice(group) &&
            token != null && token.length in 32..4096 && value.optJSONObject("trusted_peers") != null) { "invalidConfiguration" }
        return value
    }
}
