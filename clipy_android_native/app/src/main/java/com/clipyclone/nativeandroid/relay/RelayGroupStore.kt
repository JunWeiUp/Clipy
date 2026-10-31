package com.clipyclone.nativeandroid.relay

import android.content.Context
import android.util.Base64
import io.github.junweiup.commonrelay.Crypto
import io.github.junweiup.commonrelay.RelayGroups
import io.github.junweiup.commonrelay.InvitationLinks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal class RelayGroupStore(context: Context, val secure: RelaySecureStore) {
    val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val policy = RelayEndpointPolicy.from(context)
    private fun client(config: JSONObject): RelayGroups {
        require(policy.accepts(config.getString("url"))) { "WSS required" }
        return RelayGroups(config, policy.allowLocalTest)
    }
    private val mutex = Mutex()
    suspend fun <T> serial(block: suspend () -> T): T = mutex.withLock { withContext(Dispatchers.IO) { block() } }
    suspend fun load(): RelayGroups {
        val raw = secure.read("commonRelayConfig")
        val config = if (raw.isEmpty()) JSONObject() else JSONObject(raw)
        val configured = prefs.getString("flutter.syncRelayURL", "")?.trim().orEmpty()
        config.put("url", configured.ifEmpty { config.optString("url").trim().ifEmpty { "wss://eglish.top/relay/v1/ws" } })
        return client(config)
    }
    suspend fun persist(groups: RelayGroups) {
        val raw = secure.read("commonRelayConfig")
        if (raw.isNotEmpty()) {
            val current = JSONObject(raw)
            check(listOf("device", "group", "token", "secret_key").all { current.opt(it) == groups.config.opt(it) }) { "Configuration changed during request" }
            val oldEntry = current.optJSONObject("group_entry")
            val newEntry = groups.config.optJSONObject("group_entry")
            if (oldEntry != null && newEntry != null && RelayGroups.unpack(oldEntry).getInt("revision") > RelayGroups.unpack(newEntry).getInt("revision")) return
        }
        val value = JSONObject(groups.config.toString())
        value.remove("enrollment_invitation"); value.remove("enrollment_name"); value.remove("creation_draft")
        secure.write("commonRelayConfig", value.toString())
    }
    suspend fun pending(): RelayGroups? {
        val raw = secure.read("commonRelayGroupDraft")
        return if (raw.isEmpty()) null else client(JSONObject(raw))
    }
    suspend fun savePending(groups: RelayGroups) = secure.write("commonRelayGroupDraft", groups.config.toString())
    suspend fun clearPending() = secure.write("commonRelayGroupDraft", "")
    suspend fun creation(title: String, name: String, lanPeer: String): RelayGroups {
        val existing = load()
        check(!existing.config.has("token")) { "Already enrolled" }
        pending()?.let {
            check(it.config.has("pending_create") || it.config.optBoolean("creation_draft")) { "Finish pending invitation first" }
            return it
        }
        val identity = secure.identity()
        val config = JSONObject().put("url", existing.config.getString("url")).put("app", "clipy")
            .put("device", prefs.getString("flutter.syncRelayDeviceId", lanPeer))
            .put("secret_key", identity.getString("secret_key")).put("public_key", identity.getString("public_key"))
        return client(config).also { it.prepareCreate(title, name); it.config.put("creation_draft", true); savePending(it) }
    }
    suspend fun joining(invitation: JSONObject, lanPeer: String): RelayGroups {
        pending()?.let { saved ->
            val marker = saved.config.optJSONObject("enrollment_invitation")
            if (marker != null && marker.optString("group") == invitation.optString("group") && marker.optString("url") == invitation.optString("url") &&
                ((invitation.has("id") && marker.optString("id") == invitation.optString("id") && marker.optString("secret") == invitation.optString("secret")) ||
                    (invitation.has("bootstrap") && marker.optString("bootstrap") == invitation.optString("bootstrap")))) return saved
        }
        val current = load()
        check(!current.config.has("group_entry")) { "Already enrolled" }
        if (current.config.has("token")) check(current.config.optString("group") == invitation.optString("group") &&
            (!invitation.has("url") || current.config.optString("url") == invitation.optString("url"))) { "Existing identity belongs to another group" }
        val config = JSONObject(current.config.toString())
        val identity = secure.identity()
        config.put("secret_key", identity.getString("secret_key")).put("public_key", identity.getString("public_key"))
        if (!config.has("device")) config.put("device", prefs.getString("flutter.syncRelayDeviceId", lanPeer))
        config.put("app", "clipy").put("group", invitation.getString("group"))
        if (invitation.has("url")) config.put("url", invitation.getString("url"))
        if (!config.has("trusted_peers")) config.put("trusted_peers", JSONObject())
        if (!config.has("token")) config.put("token", Crypto.hex(Crypto.random(32)))
        return client(config)
    }
    suspend fun resolveInvitation(text: String): JSONObject {
        val raw = text.trim()
        if (raw.startsWith("common-relay://") && !raw.startsWith("common-relay://join#")) {
            require(policy.accepts(InvitationLinks.parse(raw, policy.allowLocalTest).url)) { "WSS required" }
            val groups = load(); groups.config.put("app", "clipy")
            return groups.resolveInvitation(raw)
        }
        require(raw.length <= 8192) { "Invitation too large" }
        val json = if (raw.startsWith("common-relay://join#")) String(Base64.decode(raw.substringAfter('#'), Base64.URL_SAFE), Charsets.UTF_8) else raw
        return JSONObject(json).also { require(it.optInt("version") == 1 && it.optString("app") == "clipy" && it.opt("group") is String) { "Invalid Clipy invitation" } }
    }
    suspend fun exit(disband: Boolean) {
        val current = load()
        var saved = secure.read("commonRelayGroupExit").takeIf { it.isNotEmpty() }?.let(::JSONObject)
        if (saved != null && listOf("device", "group", "token", "url").any { saved!!.opt(it) != current.config.opt(it) }) {
            secure.write("commonRelayGroupExit", ""); saved = null
        }
        val groups = if (saved == null) current else client(saved)
        if (saved != null) check(groups.config.optBoolean("exit_disband") == disband) { "Retry pending exit" }
        groups.prepareExit(disband); groups.config.put("exit_disband", disband)
        secure.write("commonRelayGroupExit", groups.config.toString())
        try { groups.exit() } catch (error: Exception) {
            if (error.message?.contains("409") == true) secure.write("commonRelayGroupExit", groups.config.toString())
            throw error
        }
    }
    suspend fun clearEnrollment() {
        check(prefs.edit().putBoolean("flutter.syncRelayEnabled", false)
            .putString("flutter.syncRelayDeviceId", Crypto.hex(Crypto.random(16))).commit())
        secure.write("commonRelayConfig", ""); clearPending()
        secure.write("commonRelayGroupInvitation", ""); secure.write("commonRelayGroupExit", "")
    }
    companion object {
        fun invitationText(value: JSONObject): String = value.optString("short_link").ifEmpty {
            "common-relay://join#" + Base64.encodeToString(value.toString().toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP)
        }
        fun verification(request: JSONObject): String = RelayGroups.digest(RelayGroups.payload(request)).take(12).uppercase().chunked(4).joinToString(" ")
    }
}
