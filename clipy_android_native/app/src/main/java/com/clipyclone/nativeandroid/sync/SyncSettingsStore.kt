package com.clipyclone.nativeandroid.sync

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.*
import java.util.UUID

/** Encodings written by shared_preferences_android's legacy and current list codecs. */
object FlutterStringLists {
    const val PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
    const val JSON_PREFIX = PREFIX + "!"
    fun encode(values: Collection<String>): String = JSON_PREFIX + JSONArray(values).toString()
    fun decode(raw: Any?): List<String>? {
        if (raw == null) return null
        if (raw is Set<*>) return raw.map { it as String }
        require(raw is String && raw.length <= 1024 * 1024) { "Invalid stored string list" }
        val values: List<*> = when {
            raw.startsWith(JSON_PREFIX) -> {
                val json = JSONArray(raw.removePrefix(JSON_PREFIX))
                List(json.length()) { json.get(it) }
            }
            raw.startsWith(PREFIX) -> {
                val input = object : ObjectInputStream(ByteArrayInputStream(Base64.decode(raw.removePrefix(PREFIX), Base64.DEFAULT))) {
                    override fun resolveClass(desc: ObjectStreamClass): Class<*> {
                        require(desc.name in setOf("java.util.ArrayList", "java.util.Arrays\$ArrayList", "[Ljava.lang.String;"))
                        return super.resolveClass(desc)
                    }
                }
                input.use { it.readObject() as List<*> }
            }
            else -> throw IllegalArgumentException("Unknown stored string-list encoding")
        }
        require(values.size <= 10000 && values.all { it is String })
        return values.map { it as String }
    }
}

data class SyncSettings(val peerId: String, val name: String, val port: Int, val enabled: Boolean,
                        val clipboardPeers: Set<String>, val notificationPeers: Set<String>) {
    val authorizedPeers: Set<String> get() = clipboardPeers + notificationPeers
}

data class PeerEndpoint(val peerId: String, val name: String, val host: String, val port: Int, val timestamp: Double)

/** Disk access belongs on the sync IO owner; commits preserve every unrelated Flutter key. */
class SyncSettingsStore(private val prefs: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE))
    companion object {
        private const val P = "flutter."
        private val uuid = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        const val ENDPOINTS = "clipy.peerEndpoints.v2"
    }
    private fun strings(key: String) = FlutterStringLists.decode(prefs.all[P + key])
    private fun number(key: String, default: Int): Int = (prefs.all[P + key] as? Number)?.toInt() ?: default
    private fun commit(editor: SharedPreferences.Editor) { check(editor.commit()) { "Could not persist sync settings" } }

    @Synchronized fun initialize(clearOldEncodedFrames: () -> Unit): SyncSettings {
        val original = prefs.getString(P + "peerId", "") ?: ""
        val id = original.takeIf { uuid.matches(it) } ?: UUID.randomUUID().toString()
        val legacy = strings("authorizedPeerIds") ?: emptyList()
        val clipboard = strings("clipboardSyncPeerIds") ?: if (!prefs.getBoolean(P + "dualSyncAuthMigrated", false)) legacy else emptyList()
        val notifications = strings("notificationSyncPeerIds") ?: if (!prefs.getBoolean(P + "dualSyncAuthMigrated", false)) legacy else emptyList()
        fun valid(values: List<String>) = values.filter { uuid.matches(it) && (original == id || it != original) }.distinct()
        val clip = valid(clipboard); val notif = valid(notifications)
        val editor = prefs.edit().putString(P + "peerId", id)
            .putString(P + "clipboardSyncPeerIds", FlutterStringLists.encode(clip))
            .putString(P + "notificationSyncPeerIds", FlutterStringLists.encode(notif))
            .putString(P + "authorizedPeerIds", FlutterStringLists.encode((clip + notif).distinct()))
            .putBoolean(P + "dualSyncAuthMigrated", true).putBoolean(P + "authorizedPeerIdsMigrated", true)
            .remove(P + "authorizedDevices")
        if (number("lanDefaultKeyVersion", 0) != 1 || number("clipy.sync.transportVersion", 0) != SYNC_VERSION) {
            // Must finish before listeners start; a crash can only repeat this migration, not drop live sends.
            clearOldEncodedFrames()
            editor.putLong(P + "lanDefaultKeyVersion", 1).putLong(P + "clipy.sync.transportVersion", SYNC_VERSION.toLong())
                .remove(P + "clipy.sync.pairingSecret")
        }
        commit(editor)
        return read()
    }

    @Synchronized fun read(): SyncSettings = SyncSettings(
        peerId = prefs.getString(P + "peerId", "") ?: "", name = prefs.getString(P + "deviceName", "Android") ?: "Android",
        port = number("syncPort", 5566).takeIf { it in 1..65535 } ?: 5566,
        enabled = prefs.getBoolean(P + "syncEnabled", false), clipboardPeers = strings("clipboardSyncPeerIds")?.toSet() ?: emptySet(),
        notificationPeers = strings("notificationSyncPeerIds")?.toSet() ?: emptySet())

    @Synchronized fun saveConnection(name: String, port: Int): Boolean {
        require(name.trim().isNotEmpty() && port in 1..65535)
        val current = read()
        if (current.name == name.trim() && current.port == port) return false
        commit(prefs.edit().putString(P + "deviceName", name.trim()).putLong(P + "syncPort", port.toLong()))
        return true
    }
    @Synchronized fun setEnabled(enabled: Boolean) = commit(prefs.edit().putBoolean(P + "syncEnabled", enabled))
    @Synchronized fun setCapabilities(peer: String, clipboard: Boolean, notifications: Boolean) {
        require(uuid.matches(peer))
        val current = read()
        val clips = current.clipboardPeers.toMutableSet().apply { if (clipboard) add(peer) else remove(peer) }
        val notifs = current.notificationPeers.toMutableSet().apply { if (notifications) add(peer) else remove(peer) }
        commit(prefs.edit().putString(P + "clipboardSyncPeerIds", FlutterStringLists.encode(clips.sorted()))
            .putString(P + "notificationSyncPeerIds", FlutterStringLists.encode(notifs.sorted()))
            .putString(P + "authorizedPeerIds", FlutterStringLists.encode((clips + notifs).sorted())))
    }
    @Synchronized fun manualPeers(): List<String> = strings("manualSyncPeers") ?: emptyList()
    @Synchronized fun addManualPeer(host: String, port: Int) {
        require(validIPv4(host) && port in 1..65535)
        val values = manualPeers().toMutableList()
        val endpoint = "$host:$port"
        if (endpoint !in values) values.add(endpoint)
        commit(prefs.edit().putString(P + "manualSyncPeers", FlutterStringLists.encode(values)))
    }
    @Synchronized fun removeManualPeer(endpoint: String) = commit(prefs.edit().putString(P + "manualSyncPeers", FlutterStringLists.encode(manualPeers().filter { it != endpoint })))

    @Synchronized fun endpoints(now: Double = System.currentTimeMillis() / 1000.0): List<PeerEndpoint> {
        val json = try { JSONArray(prefs.getString(P + ENDPOINTS, "[]")) } catch (_: Exception) { return emptyList() }
        return (0 until json.length()).mapNotNull { i ->
            try {
                val e = json.getJSONObject(i)
                PeerEndpoint(e.getString("peerId"), e.optString("name", e.getString("peerId")), e.getString("host"), e.getInt("port"), e.optDouble("ts", 0.0))
                    .takeIf { it.timestamp >= now - 24 * 3600 && it.port in 1..65535 && !it.host.startsWith("relay:") }
            } catch (_: Exception) { null }
        }
    }
    @Synchronized fun rememberEndpoint(endpoint: PeerEndpoint) {
        val entries = endpoints().filter { it.peerId != endpoint.peerId } + endpoint
        writeEndpoints(entries)
    }
    @Synchronized fun pruneEndpoints(live: List<PeerEndpoint>) {
        val ids = live.map { it.peerId }.toSet()
        writeEndpoints(live + endpoints().filter { it.peerId !in ids && it.peerId in read().authorizedPeers })
    }
    private fun writeEndpoints(entries: List<PeerEndpoint>) {
        val array = JSONArray()
        entries.forEach { e -> array.put(JSONObject().put("peerId", e.peerId).put("name", e.name).put("host", e.host).put("port", e.port).put("ts", e.timestamp)) }
        commit(prefs.edit().putString(P + ENDPOINTS, array.toString()))
    }
}

fun validIPv4(value: String): Boolean {
    val parts = value.split('.')
    return parts.size == 4 && parts.all { it.length in 1..3 && it.all { char -> char in '0'..'9' } && (it.toIntOrNull() ?: -1) in 0..255 }
}
