package com.clipyclone.nativeandroid.relay

import android.content.Context
import io.github.junweiup.commonrelay.RelayGroups
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Socket

 data class RelayMember(val device: String, val name: String, val manager: Boolean, val online: Boolean)
data class RelayJoinRequest(val name: String, val device: String, val code: String)
enum class RelayNotice { INVALID_GROUP_NAME, FAILED, REVOKED, RATE_LIMITED, JOINED, CREATED, REQUESTED, WAITING, AUTO_JOINING, AUTO_JOINED, APPROVED, NAME_UPDATED, LEFT, DISBANDED, INVITATION_EXPIRED, NO_REQUEST, LAST_MANAGER }
data class RelayUiState(
    val settingsLoaded: Boolean = false, val settingsSaving: Boolean = false,
    val enabled: Boolean = false, val url: String = "wss://eglish.top/relay/v1/ws", val deviceId: String = "", val configured: Boolean = false,
    val control: RelayControl = RelayControl.DISABLED, val groupLoaded: Boolean = false, val busy: Boolean = false,
    val self: String = "", val groupId: String = "", val groupName: String = "", val managed: Boolean = false, val legacy: Boolean = false,
    val members: List<RelayMember> = emptyList(), val trustedDevices: List<String> = emptyList(), val onlineKnown: Boolean = false,
    val revoked: Boolean = false, val pending: Boolean = false, val pendingAutomatic: Boolean = false, val pendingCode: String = "",
    val creationPending: Boolean = false, val draftGroupName: String = "", val draftDeviceName: String = "", val draftInvitation: String = "",
    val invitationLink: String = "", val invitationAutomatic: Boolean = true, val invitationExpires: Long = 0,
    val request: RelayJoinRequest? = null, val notice: RelayNotice? = null,
) { val canManage: Boolean get() = members.any { it.device == self && it.manager } }

/** Private relay/group owner; UI receives display-only snapshots, never config credentials. */
class NativeRelayController(
    context: Context, ownerScope: CoroutineScope,
    private val local: () -> RelayLocalIdentity,
    hasSession: (String) -> Boolean,
    tryLan: suspend (String, String, Int) -> Unit,
    onSocket: suspend (String, String, Socket, Boolean) -> Boolean,
) {
    private val scope = CoroutineScope(SupervisorJob(ownerScope.coroutineContext[Job]) + Dispatchers.Default)
    private val endpointPolicy = RelayEndpointPolicy.from(context)
    private val secure = RelaySecureStore(context)
    private val groups = RelayGroupStore(context, secure)
    private val mutable = MutableStateFlow(RelayUiState())
    val state = mutable.asStateFlow()
    @Volatile private var invitation: JSONObject? = null
    @Volatile private var request: JSONObject? = null
    @Volatile private var pageOpen = false
    @Volatile private var foreground = true
    @Volatile private var watchStopped = false
    private var watcher: Job? = null
    private val watchLock = Any()
    private val actionLock = Any()
    @Volatile private var syncRunning = false
    private val transport = NativeRelayTransport(scope, File(context.filesDir, "common-relay-journal"),
        config = {
            groups.serial {
                if (!groups.prefs.getBoolean("flutter.syncRelayEnabled", false)) null
                else {
                    val g = groups.load()
                    if (!g.config.has("token")) null else {
                        if (g.config.has("group_entry")) { g.refresh(); groups.persist(g) }
                        JSONObject(g.config.toString())
                    }
                }
            }
        }, local = local, hasSession = hasSession, tryLan = tryLan, adopt = onSocket,
        state = { control -> mutable.update { it.copy(control = control) } }, allowLocalTest = endpointPolicy.allowLocalTest)

    suspend fun start() {
        syncRunning = true
        if (groups.prefs.getBoolean("flutter.syncRelayEnabled", false)) {
            try { loadSettings() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutable.update { it.copy(control = RelayControl.RETRYING) } }
        }
        // Relay credential/network failures must never take down the independently enabled LAN listener.
        transport.start()
    }
    suspend fun stop() { syncRunning = false; transport.stop() }
    suspend fun refresh() = transport.refresh()
    suspend fun ensurePeer(lanPeerId: String) = transport.ensurePeer(lanPeerId)
    suspend fun networkChanged() { if (syncRunning) transport.restart() }

    suspend fun loadSettings() = withContext(Dispatchers.IO) { loadSettingsLocked() }
    private suspend fun loadSettingsLocked() {
        val raw = secure.read("commonRelayConfig")
        val config = if (raw.isEmpty()) JSONObject() else JSONObject(raw)
        val prefs = groups.prefs
        mutable.update { it.copy(settingsLoaded = true, enabled = prefs.getBoolean("flutter.syncRelayEnabled", false),
            url = prefs.getString("flutter.syncRelayURL", "wss://eglish.top/relay/v1/ws").orEmpty(),
            deviceId = prefs.getString("flutter.syncRelayDeviceId", null) ?: config.optString("device").ifEmpty { local().peerId },
            configured = config.length() > 0) }
    }
    suspend fun saveSettings(enabled: Boolean, url: String, device: String, key: String = "", enrollment: String = "") {
        scope.async { saveSettingsOwned(enabled, url, device, key, enrollment) }.await()
    }
    private suspend fun saveSettingsOwned(enabled: Boolean, url: String, device: String, key: String, enrollment: String) {
        mutable.update { it.copy(settingsSaving = true) }
        try {
            groups.serial {
                val address = url.trim(); val id = device.trim()
                require(endpointPolicy.accepts(address)) { "invalidUrl" }
                val existing = secure.read("commonRelayConfig")
                val next = RelayConfiguration.update(existing, id, key.trim(), enrollment.trim())
                if (next.length() != 0) {
                    val identity = secure.identity()
                    require(!(enrollment.isNotBlank() && next.has("secret_key")) && next.optString("public_key") == identity.getString("public_key")) { "publicKeyMismatch" }
                    val trusted = next.getJSONObject("trusted_peers")
                    trusted.keys().forEach { peer -> require(RelayConfiguration.validDevice(peer) && Regex("^[a-fA-F0-9]{64}$").matches(trusted.getString(peer))) { "invalidConfiguration" } }
                    next.put("secret_key", identity.getString("secret_key"))
                }
                require(!enabled || next.length() != 0) { "enrollmentRequired" }
                val prefs = groups.prefs
                val same = prefs.getBoolean("flutter.syncRelayEnabled", false) == enabled &&
                    prefs.getString("flutter.syncRelayURL", "") == address && prefs.getString("flutter.syncRelayDeviceId", local().peerId) == id &&
                    equivalent(existing, if (next.length() == 0) "" else next.toString())
                if (!same) {
                    secure.write("commonRelayConfig", if (next.length() == 0) "" else next.toString())
                    check(prefs.edit().putBoolean("flutter.syncRelayEnabled", enabled).putString("flutter.syncRelayURL", address)
                        .putString("flutter.syncRelayDeviceId", id).remove("flutter.syncRelayToken").commit())
                    if (syncRunning) transport.restart()
                }
                loadSettingsLocked()
            }
        } finally { mutable.update { it.copy(settingsSaving = false) } }
    }
    suspend fun publicInfo(device: String): String = secure.publicInfo(device.trim())
    fun notice(value: RelayNotice?) { mutable.update { it.copy(notice = value) } }
    fun setGroupPageOpen(open: Boolean) { pageOpen = open; scheduleWatch() }
    fun setForeground(value: Boolean) { foreground = value; scheduleWatch() }

    private suspend fun work(automatic: Boolean = false, action: suspend () -> Unit) {
        synchronized(actionLock) {
            if (mutable.value.busy) return
            mutable.update { it.copy(busy = true, notice = if (automatic) it.notice else null) }
            if (!automatic) watchStopped = false
        }
        // Like the existing Dart operation, a submitted group action survives popping the page.
        // The page owns observation/watch scheduling, not the durable enrollment transaction.
        val operation = scope.async {
            try { groups.serial { action() } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                val description = error.message.orEmpty()
                if (automatic && listOf("401", "403", "404", "410").any(description::contains)) watchStopped = true
                val revoked = mutable.value.managed && description.contains("401")
                mutable.update { it.copy(revoked = it.revoked || revoked,
                    notice = if (revoked) RelayNotice.REVOKED else if (description.contains("429")) RelayNotice.RATE_LIMITED else RelayNotice.FAILED) }
            } finally { mutable.update { it.copy(busy = false) }; scheduleWatch() }
        }
        operation.await()
    }
    suspend fun refreshGroups() = work { refreshGroupsLocked() }
    private suspend fun refreshGroupsLocked() {
        val g = groups.load(); val config = g.config
        val valid = config.optString("app") == "clipy" && config.optString("group").isNotEmpty() && config.optString("device").isNotEmpty() &&
            config.optString("token").length >= 32 && config.optString("secret_key").length == 64
        val managed = valid && config.optJSONObject("group_entry") != null
        val cached = if (managed) RelayGroups.unpack(config.getJSONObject("group_entry")) else null
        val pending = groups.pending()
        val creation = pending?.config?.optBoolean("creation_draft") == true
        if (!creation && pending?.config?.has("group_entry") == true && !pending.config.has("pending_join")) {
            // Approval may have completed just as the page closed. Finish the saved activation on reopen.
            activate(pending)
            return
        }
        val pendingInvitation = pending?.config?.optJSONObject("enrollment_invitation")
        val pendingRequest = pending?.config?.optJSONObject("pending_join")?.optJSONObject("request")
        val creatingEntry = pending?.config?.optJSONObject("pending_create") ?: if (creation) pending?.config?.optJSONObject("group_entry") else null
        val creationState = creatingEntry?.let(RelayGroups::unpack)
        invitation = secure.read("commonRelayGroupInvitation").takeIf { it.isNotEmpty() }?.let(::JSONObject)
        if (invitation?.optLong("expires", 0)?.let { it <= System.currentTimeMillis() / 1000 } == true) {
            secure.write("commonRelayGroupInvitation", ""); invitation = null; request = null
        }
        val trusted = config.optJSONObject("trusted_peers")
        mutable.update { it.copy(groupLoaded = true, managed = managed, legacy = valid && !managed,
            self = config.optString("device"), groupId = config.optString("group"), groupName = cached?.optString("name").orEmpty(),
            members = members(cached, emptySet()), onlineKnown = false,
            trustedDevices = trusted?.keys()?.asSequence()?.filter { id -> id != config.optString("device") }?.sorted()?.toList() ?: emptyList(),
            pending = pendingRequest != null && !creation, pendingAutomatic = pendingInvitation?.optString("mode") == "auto",
            pendingCode = pendingRequest?.let(RelayGroupStore::verification).orEmpty(), creationPending = creation,
            draftGroupName = creationState?.optString("name").orEmpty(),
            draftDeviceName = if (creation) creationState?.optJSONArray("members")?.optJSONObject(0)?.optString("name").orEmpty() else pending?.config?.optString("enrollment_name").orEmpty(),
            draftInvitation = pendingInvitation?.let(RelayGroupStore::invitationText).orEmpty()) }
        updateInvitation()
        if (managed) {
            val result = g.refresh(); groups.persist(g)
            val groupState = result.getJSONObject("state")
            val online = result.getJSONArray("online").let { array -> (0 until array.length()).map { array.getString(it) }.toSet() }
            mutable.update { it.copy(members = members(groupState, online), groupName = groupState.optString("name"), onlineKnown = true, revoked = false) }
        }
        loadSettingsLocked()
    }
    private fun members(value: JSONObject?, online: Set<String>): List<RelayMember> {
        val array = value?.optJSONArray("members") ?: return emptyList()
        return (0 until array.length()).map { array.getJSONObject(it) }.map {
            RelayMember(it.getString("device"), it.getString("name"), it.getBoolean("manager"), it.getString("device") in online)
        }
    }
    private fun updateInvitation() {
        val inv = invitation
        val req = request
        val member = req?.let(RelayGroups::unpack)?.optJSONObject("member")
        mutable.update { it.copy(invitationLink = inv?.let(RelayGroupStore::invitationText).orEmpty(),
            invitationAutomatic = inv?.optString("mode") != "manual", invitationExpires = inv?.optLong("expires") ?: 0,
            request = if (req == null || member == null) null else RelayJoinRequest(member.getString("name"), member.getString("device"), RelayGroupStore.verification(req))) }
    }
    private suspend fun activate(groupsValue: RelayGroups) {
        groups.persist(groupsValue)
        val c = groupsValue.config
        check(groups.prefs.edit().putBoolean("flutter.syncRelayEnabled", true).putString("flutter.syncRelayURL", c.getString("url"))
            .putString("flutter.syncRelayDeviceId", c.getString("device")).commit())
        groups.clearPending()
        if (syncRunning) transport.restart()
        mutable.update { it.copy(pending = false, creationPending = false, notice = RelayNotice.JOINED) }
        refreshGroupsLocked()
    }
    suspend fun createGroup(title: String, name: String) = work {
        val g = groups.creation(title.trim(), name.trim(), local().peerId)
        val entry = g.config.optJSONObject("pending_create") ?: g.config.optJSONObject("group_entry")
        val draft = entry?.let(RelayGroups::unpack)
        mutable.update { it.copy(creationPending = true, draftGroupName = draft?.optString("name").orEmpty(),
            draftDeviceName = draft?.optJSONArray("members")?.optJSONObject(0)?.optString("name").orEmpty()) }
        if (!g.config.has("group_entry")) { g.create(); groups.savePending(g) }
        activate(g); notice(RelayNotice.CREATED)
    }
    suspend fun joinGroup(text: String, name: String) = work {
        val invitation = groups.resolveInvitation(text)
        val g = groups.joining(invitation, local().peerId)
        g.config.put("enrollment_invitation", invitation)
        if (!g.config.has("enrollment_name")) g.config.put("enrollment_name", name.trim())
        groups.savePending(g)
        if (invitation.has("bootstrap")) { g.bootstrap(invitation, g.config.getString("enrollment_name")); activate(g) }
        else {
            try { g.join(invitation, g.config.getString("enrollment_name")) } finally { groups.savePending(g) }
            mutable.update { it.copy(pending = true, pendingAutomatic = invitation.optString("mode") == "auto", notice = RelayNotice.REQUESTED) }
            if (invitation.optString("mode") == "auto") finishPendingLocked()
            else refreshGroupsLocked()
        }
    }
    private suspend fun finishPendingLocked() {
        val g = groups.pending() ?: return
        check(g.config.has("pending_join")) { "Retry invitation" }
        val finished = try { g.finishJoin() } finally { groups.savePending(g) }
        if (finished) { if (pageOpen) activate(g) }
        else notice(if (mutable.value.pendingAutomatic) RelayNotice.AUTO_JOINING else RelayNotice.WAITING)
    }
    suspend fun discardRequest() = work { groups.clearPending(); mutable.update { it.copy(pending = false, creationPending = false, draftInvitation = "", pendingCode = "") } }
    suspend fun invite(automatic: Boolean) = work {
        val g = groups.load(); invitation = g.invite(if (automatic) "auto" else "manual", true)
        groups.persist(g); secure.write("commonRelayGroupInvitation", invitation!!.toString()); request = null; updateInvitation()
    }
    suspend fun cancelInvitation() = work {
        invitation?.let { groups.load().cancel(it) }
        secure.write("commonRelayGroupInvitation", ""); invitation = null; request = null; updateInvitation()
    }
    private suspend fun checkInvitationLocked() {
        val inv = invitation ?: return
        val g = groups.load(); val req = g.pending(inv)
        if (inv.optString("mode") == "auto") {
            refreshGroupsLocked()
            if (req != null) {
                val memberId = RelayGroups.unpack(req).getJSONObject("member").getString("device")
                if (mutable.value.members.any { it.device == memberId }) {
                    secure.write("commonRelayGroupInvitation", ""); invitation = null; request = null; updateInvitation(); notice(RelayNotice.AUTO_JOINED)
                }
            }
        } else { request = req; updateInvitation(); if (req == null) notice(RelayNotice.NO_REQUEST) }
    }
    suspend fun approve(grantManager: Boolean) = work {
        val g = groups.load(); g.approve(requireNotNull(invitation), requireNotNull(request), grantManager)
        groups.persist(g); secure.write("commonRelayGroupInvitation", ""); invitation = null; request = null
        refreshGroupsLocked(); notice(RelayNotice.APPROVED)
        if (syncRunning) transport.restart()
    }
    suspend fun removeMember(device: String) = work { val g = groups.load(); g.remove(device); groups.persist(g); refreshGroupsLocked(); if (syncRunning) transport.restart() }
    suspend fun renameMember(device: String, name: String) = work { val g = groups.load(); g.rename(device, name); groups.persist(g); refreshGroupsLocked(); notice(RelayNotice.NAME_UPDATED); if (syncRunning) transport.restart() }
    suspend fun exitGroup(disband: Boolean) = work {
        val snapshot = mutable.value
        if (!disband && !snapshot.revoked && snapshot.canManage && snapshot.members.size > 1 && snapshot.members.count { it.manager } == 1) { notice(RelayNotice.LAST_MANAGER); return@work }
        if (!snapshot.revoked) try { groups.exit(disband) } catch (error: Exception) { if (disband || error.message?.contains("401") != true) throw error }
        groups.clearEnrollment(); invitation = null; request = null
        transport.restart()
        mutable.update { it.copy(managed = false, legacy = false, revoked = false, members = emptyList(), pending = false,
            creationPending = false, invitationLink = "", request = null, draftInvitation = "", draftGroupName = "", draftDeviceName = "") }
        refreshGroupsLocked(); notice(if (disband) RelayNotice.DISBANDED else RelayNotice.LEFT)
    }
    private fun scheduleWatch() = synchronized(watchLock) {
        watcher?.cancel(); watcher = null
        val snapshot = mutable.value
        if (!pageOpen || !foreground || snapshot.busy || snapshot.revoked || watchStopped || (!snapshot.pending && invitation == null)) return@synchronized
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            delay(2000)
            synchronized(watchLock) { if (watcher !== job) return@launch; watcher = null }
            if (!pageOpen || !foreground) return@launch
            work(automatic = true) {
                if (mutable.value.pending) finishPendingLocked()
                else if (invitation != null) {
                    if (invitation!!.getLong("expires") <= System.currentTimeMillis() / 1000) { watchStopped = true; notice(RelayNotice.INVITATION_EXPIRED) }
                    else checkInvitationLocked()
                }
            }
        }
        watcher = job; job.start()
    }
    private fun equivalent(first: String, second: String): Boolean {
        if (first.isEmpty() || second.isEmpty()) return first.isEmpty() && second.isEmpty()
        fun canonical(value: Any?): String = when (value) {
            is JSONObject -> value.keys().asSequence().sorted().joinToString(prefix = "{", postfix = "}") { key -> JSONObject.quote(key) + ":" + canonical(value.opt(key)) }
            is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.opt(it)) }
            is String -> JSONObject.quote(value)
            else -> value.toString()
        }
        return canonical(JSONObject(first)) == canonical(JSONObject(second))
    }
}
