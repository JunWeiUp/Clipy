package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun SyncDiagnosticsPage(manager: NativeSyncManager, back: () -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val state by manager.state.collectAsStateWithLifecycle()
    val records by manager.diagnostics.records.collectAsStateWithLifecycle()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val active = LocalPageActive.current
    LaunchedEffect(active) { while (active) { now = System.currentTimeMillis(); delay(2000) } }
    val ids = records.keys + state.settings.authorizedPeers + state.connectedPeerIds + state.pending.keys
    val peers = state.peers.associateBy { it.peerId }
    val rows = ids.map { records[it] ?: NativePeerDiagnostics(it) }
        .sortedWith(compareByDescending<NativePeerDiagnostics> { it.peerId in state.connectedPeerIds }.thenBy { (it.name ?: peers[it.peerId]?.name ?: it.peerId).lowercase() })
    fun time(timestamp: Long?): String {
        if (timestamp == null) return "—"
        val seconds = ((now - timestamp) / 1000).coerceAtLeast(0)
        return when {
            seconds < 60 -> s.syncDiagnosticsSecondsAgo(seconds)
            seconds < 3600 -> s.syncDiagnosticsMinutesAgo(seconds / 60)
            seconds < 86400 -> s.syncDiagnosticsHoursAgo(seconds / 3600)
            else -> SimpleDateFormat("MM-dd HH:mm", Locale.US).format(Date(timestamp))
        }
    }
    Scaffold(containerColor = colors.background, topBar = {
        SecondaryAppBar(s.syncDiagnosticsTitle, back) {
            IconButton(onClick = manager.diagnostics::reset) { ClipyIcon(ClipyIcons.delete_sweep_rounded, color = colors.onSurface, description = s.syncDiagnosticsReset) }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (rows.isEmpty()) ClipyEmptyState(ClipyIcons.monitor_heart_outlined, s.syncDiagnosticsEmpty, s.syncDiagnosticsHint)
            else LazyColumn(contentPadding = PaddingValues(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 24.dp)) {
                item { Text(s.syncDiagnosticsHint, Modifier.padding(start = 4.dp, end = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall) }
                items(rows, key = { it.peerId }) { record ->
                    val online = record.peerId in state.connectedPeerIds
                    val count = state.pending[record.peerId] ?: 0
                    Surface(Modifier.fillMaxWidth().padding(bottom = 10.dp), color = colors.surface, shape = RoundedCornerShape(24.dp)) {
                        Column(Modifier.padding(14.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.size(10.dp).background(if (online) Color(0xFF4CAF50) else colors.outline, CircleShape))
                                Spacer(Modifier.width(8.dp))
                                Text(record.name ?: peers[record.peerId]?.name ?: record.peerId.take(8), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(if (online) s.syncDiagnosticsOnline else s.syncDiagnosticsOffline, style = MaterialTheme.typography.bodySmall)
                                if (record.peerId !in state.settings.authorizedPeers) { Spacer(Modifier.width(8.dp)); Text(s.syncDiagnosticsNotAuthorized, style = MaterialTheme.typography.bodySmall) }
                            }
                            Spacer(Modifier.height(6.dp))
                            Text(s.syncDiagnosticsPending(count), style = MaterialTheme.typography.bodySmall.copy(
                                color = if (count > 0) Color(0xFFFF9800) else colors.onSurface, fontWeight = if (count > 0) FontWeight.SemiBold else FontWeight.Normal))
                            Spacer(Modifier.height(4.dp))
                            val details = buildList {
                                record.host?.let { add(it) }; add(record.peerId.take(8))
                                if (online) add("${s.syncDiagnosticsSessionUp} ${time(record.sessionUpAt)}")
                                else record.sessionDownAt?.let { add("${s.syncDiagnosticsSessionDown} ${time(it)}") }
                                add("${s.syncDiagnosticsLastSent} ${time(record.lastSentAt)}")
                                add("${s.syncDiagnosticsLastAck} ${time(record.lastAckAt)}")
                                add("${s.syncDiagnosticsLastReceived} ${time(record.lastReceivedAt)}")
                            }
                            SelectionContainer(Modifier.padding(end = 3.dp)) { Text(details.joinToString(" · "), style = MaterialTheme.typography.bodySmall) }
                            record.lastError?.let { error ->
                                Spacer(Modifier.height(4.dp))
                                SelectionContainer(Modifier.padding(end = 3.dp)) { Text("${s.syncDiagnosticsLastError}: $error · ${time(record.lastErrorAt)}", style = MaterialTheme.typography.bodySmall, color = colors.error) }
                            }
                        }
                    }
                }
            }
        }
    }
}
