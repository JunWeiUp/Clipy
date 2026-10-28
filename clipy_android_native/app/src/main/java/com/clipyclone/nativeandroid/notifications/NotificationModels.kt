package com.clipyclone.nativeandroid.notifications

import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class NotificationEntry(
    val id: String, val notificationKey: String?, val packageName: String, val appName: String,
    val title: String, val subtitle: String?, val body: String, val postTime: Long,
    val groupKey: String? = null, val isClearable: Boolean = true, val isArchived: Boolean = false,
    val syncState: Int = 0, val extras: Map<String, String> = emptyMap(),
) {
    fun json(): JSONObject = JSONObject().put("id", id).put("notificationKey", notificationKey ?: JSONObject.NULL)
        .put("packageName", packageName).put("appName", appName).put("title", title)
        .put("subtitle", subtitle ?: JSONObject.NULL).put("body", body).put("postTime", postTime)
        .put("groupKey", groupKey ?: JSONObject.NULL).put("isClearable", isClearable)
        .put("isArchived", isArchived).put("extras", JSONObject(extras))
    fun detailText(): String = buildList {
        add("App: $appName"); add("Package: $packageName"); add("Title: $title")
        if (!subtitle.isNullOrEmpty()) add("Subtitle: $subtitle")
        if (body.isNotEmpty()) add("Body: $body")
        add("Time: ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(postTime))}")
        if (!notificationKey.isNullOrEmpty()) add("Key: $notificationKey")
        if (!groupKey.isNullOrEmpty()) add("Group: $groupKey")
        if (isArchived) add("Archived: yes (WeChat history snapshot)")
        if (extras.isNotEmpty()) { add(""); add("Extras:"); extras.toSortedMap().forEach { (key, value) -> if (value.trim().isNotEmpty()) add("$key: ${value.trim()}") } }
    }.joinToString("\n")
    companion object {
        fun fromJson(value: JSONObject): NotificationEntry {
            fun optional(key: String) = if (value.isNull(key)) null else value.opt(key) as? String
            val extras = value.optJSONObject("extras")?.let { obj -> obj.keys().asSequence().associateWith { obj.opt(it)?.takeUnless { v -> v == JSONObject.NULL }?.toString() ?: "" } } ?: emptyMap()
            return NotificationEntry(value.getString("id"), optional("notificationKey"), value.getString("packageName"), value.getString("appName"),
                value.getString("title"), optional("subtitle"), value.optString("body", ""), value.optLong("postTime", System.currentTimeMillis()),
                optional("groupKey"), value.optBoolean("isClearable", true), value.optBoolean("isArchived", false) || extras["clipyArchived"] == "true", extras = extras)
        }
    }
}
data class NotificationGroup(val packageName: String, val appName: String, val count: Int, val latest: Long)
data class NotificationSnapshot(val count: Int, val packageCount: Int, val groups: List<NotificationGroup>, val expanded: Map<String, List<NotificationEntry>>)
data class InstalledNotificationApp(val packageName: String, val name: String, val system: Boolean)
data class ListenerStatus(val permission: Boolean, val connected: Boolean, val activeCount: Int)
enum class NotificationHealthIssue { NONE, PERMISSION, DISCONNECTED, BATTERY, STALE }
data class NotificationState(
    val initialized: Boolean = false, val enabled: Boolean = false,
    val collected: Set<String> = emptySet(), val synced: Set<String> = emptySet(),
    val listener: ListenerStatus = ListenerStatus(false, false, 0),
    val batteryExempt: Boolean = true, val notificationsAllowed: Boolean = true,
    val healthIssue: NotificationHealthIssue = NotificationHealthIssue.NONE,
    val lastNotificationAt: Long? = null, val monitoringStartedAt: Long = System.currentTimeMillis(),
)
