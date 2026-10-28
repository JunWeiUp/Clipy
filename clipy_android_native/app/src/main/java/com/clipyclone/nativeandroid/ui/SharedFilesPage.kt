package com.clipyclone.nativeandroid.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clipyclone.nativeandroid.sharing.IncomingShare
import com.clipyclone.nativeandroid.sharing.ShareSendSession
import androidx.compose.foundation.shape.RoundedCornerShape
import com.clipyclone.nativeandroid.sync.NativeSyncManager
import com.clipyclone.nativeandroid.sync.SyncPeer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

@Composable
fun SharedFilesPage(share: IncomingShare, sync: NativeSyncManager,
                    sendFile: suspend (File, String) -> Boolean, openDevices: suspend () -> Unit,
                    close: () -> Unit, message: (String) -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val state by sync.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope(); val lifecycle = LocalLifecycleOwner.current
    val active = LocalPageActive.current
    val session = remember(share.id) { ShareSendSession(share) }
    val delivery by session.state.collectAsStateWithLifecycle()
    val sent = delivery.sent; val sending = delivery.sending; val current = delivery.current; val peerId = delivery.peerId
    var refreshing by remember { mutableStateOf(false) }
    val peers = state.peers.filter { it.discovered }
    val scanBusy = refreshing || state.discovery.running
    val selected = peers.firstOrNull { it.peerId == peerId }
    fun refresh(automatic: Boolean) {
        if (sending || refreshing || !sync.state.value.settings.enabled) return
        refreshing = true
        scope.launch {
            try { sync.refreshDiscovery(automatic); if (!automatic) message(s.discoveryFinished(sync.state.value.peers.count { it.discovered })) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { message(s.operationFailed) }
            finally { refreshing = false }
        }
    }
    LaunchedEffect(active, state.settings.enabled) { if (active && state.settings.enabled) refresh(true) }
    val refreshLatest by rememberUpdatedState { if (active) refresh(true) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refreshLatest() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    fun send(peer: SyncPeer) {
        if (sending) return
        scope.launch {
            val result = session.send(peer.peerId, { text, id -> sync.sendText(text, id) }, { file, id -> sendFile(File(file.path), id) }) ?: return@launch
            message(if (result.failed) if (result.textUnconfirmed) s.textDeliveryUnconfirmed else s.sendFailed
                else if (share.text.isNotEmpty()) s.textSentTo(peer.name) else s.fileSentTo(peer.name))
            if (result.complete) close()
        }
    }
    BackHandler(enabled = active && sending) { }
    Scaffold(containerColor = colors.background, topBar = {
        SecondaryAppBar(s.sharedFiles, { if (!sending) close() })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(20.dp)) {
            Text(if (share.text.isNotEmpty()) s.sharedTextHint else s.sharedFilesHint)
            if (share.text.isNotEmpty()) SelectableLongText(share.text, Modifier.padding(vertical = 12.dp).heightIn(max = 240.dp),
                style = MaterialTheme.typography.bodyMedium, onCopyFailed = { message(s.operationFailed) })
            if (share.error.isNotEmpty()) Text(s.shareImportError(share.error), Modifier.padding(vertical = 12.dp), color = colors.error)
            share.files.forEachIndexed { index, file ->
                Row(Modifier.fillMaxWidth().heightIn(min = 72.dp), verticalAlignment = Alignment.CenterVertically) {
                    ClipyIcon(if (index in sent) ClipyIcons.check_circle else ClipyIcons.insert_drive_file_outlined)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) { Text(file.name, style = MaterialTheme.typography.bodyLarge); Text("${file.size} B", style = MaterialTheme.typography.bodyMedium) }
                    if (current == index && active) CircularProgressIndicator(Modifier.size(24.dp))
                }
            }
            if (sending && active) LinearProgressIndicator(Modifier.fillMaxWidth())
            Spacer(Modifier.height(20.dp))
            if (share.itemCount > 0 && sent.size < share.itemCount) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(s.lanDevices, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    IconButton(onClick = { refresh(false) }, enabled = state.settings.enabled && !sending && !scanBusy) { ClipyIcon(ClipyIcons.refresh_rounded, description = s.refreshDevices, color = if (state.settings.enabled && !sending && !scanBusy) colors.onSurfaceVariant else colors.onSurface.copy(alpha = .38f)) }
                }
                if (scanBusy) {
                    if (state.discovery.total > 0) LinearProgressIndicator(progress = { state.discovery.completed.toFloat() / state.discovery.total }, modifier = Modifier.fillMaxWidth())
                    else if (active) LinearProgressIndicator(Modifier.fillMaxWidth())
                    Spacer(Modifier.height(8.dp))
                    Text(s.discoveryScanning(state.discovery.completed, state.discovery.total, peers.size))
                }
                if (peers.isEmpty() && !scanBusy) Text(if (state.settings.enabled) s.shareNoDevices else s.shareSyncDisabled, Modifier.padding(vertical = 12.dp))
                peers.forEach { peer ->
                    Row(Modifier.fillMaxWidth().clickable(enabled = !sending) {
                        session.select(peer.peerId)
                    }.heightIn(min = 72.dp), verticalAlignment = Alignment.CenterVertically) {
                        ClipyIcon(if (peer.peerId == peerId) ClipyIcons.radio_button_checked else ClipyIcons.radio_button_off)
                        Spacer(Modifier.width(16.dp))
                        Column { Text(peer.name, style = MaterialTheme.typography.bodyLarge); Text(peer.host, style = MaterialTheme.typography.bodyMedium) }
                    }
                }
                OutlinedButton(onClick = { scope.launch { openDevices(); refresh(true) } }, enabled = !sending, colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.primary), border = BorderStroke(1.dp, if (sending) colors.onSurface.copy(alpha = .12f) else colors.outline), contentPadding = clipyButtonPadding(icon = true), shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    ClipyButtonIcon(ClipyIcons.settings_ethernet); Spacer(Modifier.width(clipyButtonSpacing())); Text(s.lanDevices)
                }
                Spacer(Modifier.height(12.dp))
                Button(onClick = { selected?.let(::send) }, enabled = !sending && selected != null, contentPadding = clipyButtonPadding(icon = true), shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    ClipyButtonIcon(ClipyIcons.send); Spacer(Modifier.width(clipyButtonSpacing())); Text(if (sent.isEmpty()) s.send else s.retry)
                }
            }
            TextButton(onClick = close, enabled = !sending, modifier = Modifier.fillMaxWidth()) {
                Text(if (sent.size == share.itemCount && sent.isNotEmpty()) s.closeShare else s.cancel)
            }
        }
    }
}
