package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

enum class RelayConnectivity { DISABLED, CONNECTING, READY, RETRYING }

fun syncButtonLabel(s: AppStrings, enabled: Boolean, serverRunning: Boolean, lan: Boolean,
                    relay: Boolean, relayState: RelayConnectivity, scanning: Boolean, busy: Boolean): String = when {
    busy -> if (enabled) s.syncStarting else s.syncStopping
    !enabled -> s.syncStart
    lan && relay -> s.syncMixedConnected
    lan -> s.syncLanConnected
    relay -> s.syncRelayConnected
    !serverRunning -> s.diagServerNotBound
    relayState == RelayConnectivity.CONNECTING -> s.syncRelayConnecting
    relayState == RelayConnectivity.READY -> s.syncRelayReady
    relayState == RelayConnectivity.RETRYING -> s.syncRelayRetrying
    scanning -> s.syncSearching
    else -> s.syncWaiting
}

/** Exact route structure of DevicesPage; business actions are provided by the application owner. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DevicesPage(state: SyncState, toggle: suspend (Boolean) -> Unit, refresh: suspend () -> Int,
                editConnection: () -> Unit, diagnostics: () -> Unit,
                capabilities: suspend (String, Boolean, Boolean) -> Unit,
                sendText: suspend (SyncPeer, String) -> Boolean, sendFile: suspend (SyncPeer) -> Unit,
                addManual: suspend (String, Int) -> Unit, removeManual: suspend (String) -> Unit,
                message: (String) -> Unit, relayState: RelayConnectivity = RelayConnectivity.DISABLED,
                hasRelay: Boolean = false, relayContent: @Composable () -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope()
    var toggling by remember { mutableStateOf(false) }
    var toggleTarget by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var busyPeers by remember { mutableStateOf(emptySet<String>()) }
    var expanded by rememberSaveable { mutableStateOf<String?>(null) }
    val activePage = LocalPageActive.current
    var removing by remember { mutableStateOf<SyncPeer?>(null) }
    var textPeer by remember { mutableStateOf<SyncPeer?>(null) }
    var adding by remember { mutableStateOf(false) }
    var manualBusy by remember { mutableStateOf(false) }
    val scanBusy = refreshing || state.discovery.running
    fun peerAction(peer: String, block: suspend () -> Unit) {
        if (peer in busyPeers) return
        busyPeers = busyPeers + peer
        scope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { message(s.operationFailed) }
            finally { busyPeers = busyPeers - peer }
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 20.dp, top = 4.dp, end = 20.dp, bottom = 28.dp)) {
        Button(contentPadding = clipyButtonPadding(icon = true), onClick = {
            toggleTarget = !state.settings.enabled; toggling = true
            scope.launch {
                try { toggle(toggleTarget) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { message(s.operationFailed) }
                finally { toggling = false }
            }
        }, enabled = !toggling && state.initialized, shape = RoundedCornerShape(16.dp), modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
            if (toggling) ClipySpinner(Modifier.size(20.dp), color = androidx.compose.ui.graphics.Color.White, strokeWidth = 2.dp)
            else ClipyButtonIcon(if (state.settings.enabled) ClipyIcons.sync_rounded else ClipyIcons.sync_disabled_rounded)
            Spacer(Modifier.width(clipyButtonSpacing()))
            Text(syncButtonLabel(s, if (toggling) toggleTarget else state.settings.enabled, state.listening,
                state.hasLanSession, hasRelay, relayState, state.discovery.running, toggling), textAlign = TextAlign.Center,
                style = MaterialTheme.typography.labelLarge.copy(fontSize = 16.sp))
        }
        Spacer(Modifier.height(20.dp))
        if (state.settings.enabled && !toggling) Text(s.syncStopHint, Modifier.fillMaxWidth().padding(bottom = 12.dp), textAlign = TextAlign.Center)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(s.authorizedDevices, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            IconButton(onClick = {
                refreshing = true
                scope.launch {
                    try { message(s.discoveryFinished(refresh())) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { message(s.operationFailed) }
                    finally { refreshing = false }
                }
            }, enabled = state.settings.enabled && !scanBusy) {
                if (scanBusy) ClipySpinner(Modifier.size(20.dp), strokeWidth = 2.dp)
                else ClipyIcon(ClipyIcons.refresh_rounded, color = LocalContentColor.current, description = s.refreshDevices)
            }
        }
        if (scanBusy) Column(Modifier.padding(bottom = 16.dp)) {
            if (state.discovery.total == 0) ClipyIndeterminateBar(Modifier.fillMaxWidth())
            else LinearProgressIndicator(progress = { state.discovery.completed.toFloat() / state.discovery.total }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            Text(s.discoveryScanning(state.discovery.completed, state.discovery.total, state.peers.count { it.discovered }), style = MaterialTheme.typography.bodySmall)
        }
        if (state.peers.isEmpty()) Surface(shape = RoundedCornerShape(24.dp), color = colors.surface) {
            Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                ClipyIconTile(ClipyIcons.devices_other_rounded, 64.dp)
                Spacer(Modifier.height(16.dp)); Text(s.noDevicesFound, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp)); Text(if (state.settings.enabled) s.sameWifiHint else s.diagSyncOff, textAlign = TextAlign.Center)
            }
        }
        state.peers.forEach { peer ->
            val clipboard = peer.peerId in state.settings.clipboardPeers
            val notifications = peer.peerId in state.settings.notificationPeers
            val busy = peer.peerId in busyPeers
            Surface(Modifier.fillMaxWidth().padding(bottom = 8.dp), shape = RoundedCornerShape(24.dp), color = colors.surface) {
                Column {
                    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        ClipyIconTile(ClipyIcons.computer_rounded, 36.dp); Spacer(Modifier.width(16.dp))
                        Column(Modifier.weight(1f)) {
                            Text(peer.name, style = MaterialTheme.typography.bodyLarge)
                            Text(if (!peer.discovered) s.deviceOffline else "${s.deviceOnline} · ${if (peer.host.startsWith("relay:")) s.internetRelay else peer.host}",
                                style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                        }
                        IconButton(onClick = { expanded = if (expanded == peer.peerId) null else peer.peerId }) {
                            ClipyIcon(ClipyIcons.tune_rounded, size = 20.dp, description = s.deviceSyncSettings)
                        }
                    }
                    if (peer.discovered) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    FlowRow(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilledTonalButton(contentPadding = clipyButtonPadding(icon = true), onClick = { textPeer = peer }, enabled = state.settings.enabled && !busy,
                            shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                            ClipyButtonIcon(ClipyIcons.notes_rounded)
                            Spacer(Modifier.width(clipyButtonSpacing())); Text(s.sendText)
                        }
                        OutlinedButton(border = clipyOutlinedBorder(state.settings.enabled && !busy), colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.primary), contentPadding = clipyButtonPadding(icon = true), onClick = { peerAction(peer.peerId) { sendFile(peer) } }, enabled = state.settings.enabled && !busy,
                            shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                            ClipyButtonIcon(ClipyIcons.upload_file_outlined)
                            Spacer(Modifier.width(clipyButtonSpacing())); Text(s.sendFile)
                        }
                    }
                    }
                    if (expanded == peer.peerId) {
                        HorizontalDivider(Modifier.padding(horizontal = 12.dp), color = colors.outlineVariant.copy(alpha = .55f))
                        CapabilitySwitch(s.syncClipboardToDevice, clipboard, !busy) { value -> peerAction(peer.peerId) { capabilities(peer.peerId, value, notifications) } }
                        CapabilitySwitch(s.syncNotificationsToDevice, notifications, !busy) { value -> peerAction(peer.peerId) { capabilities(peer.peerId, clipboard, value) } }
                        if (clipboard || notifications) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                            IconButton(onClick = { removing = peer }, enabled = !busy) { ClipyIcon(ClipyIcons.link_off_rounded, description = s.delete) }
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        Text(s.localNetwork, Modifier.padding(start = 4.dp, end = 4.dp, bottom = 4.dp), style = MaterialTheme.typography.titleMedium)
        Text(s.syncLanFirst, Modifier.padding(start = 4.dp, end = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        Surface(shape = RoundedCornerShape(24.dp), color = colors.surface) {
            Column {
                DeviceSettingsRow(ClipyIcons.tune_rounded, s.connectionSettings, state.settings.name, !toggling, editConnection)
                HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = colors.outlineVariant.copy(alpha = .55f))
                DeviceSettingsRow(ClipyIcons.monitor_heart_outlined, s.syncDiagnosticsTitle, s.syncDiagnosticsSubtitle, true, diagnostics)
                if (state.localAddresses.isNotEmpty()) SelectionContainer {
                    Text("${s.myIPAddress}: ${state.localAddresses.joinToString(", ")}", Modifier.padding(start = 20.dp, end = 20.dp, bottom = 18.dp), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        // ClipySection adds 24dp bottom padding, followed by the original 20dp spacer.
        Spacer(Modifier.height(44.dp)); relayContent(); Spacer(Modifier.height(20.dp))
        Surface(shape = RoundedCornerShape(24.dp), color = colors.surface) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(s.manualDevices, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    IconButton(onClick = { adding = true }, enabled = state.settings.enabled && !manualBusy) { ClipyIcon(ClipyIcons.add_rounded, color = LocalContentColor.current, description = s.addDevice) }
                }
                Text(s.manualDevicesHint, style = MaterialTheme.typography.bodySmall)
                state.manualPeers.forEach { address ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                        ClipyIcon(ClipyIcons.dns_outlined); Spacer(Modifier.width(16.dp)); Text(address, Modifier.weight(1f))
                        IconButton(onClick = {
                            manualBusy = true
                            scope.launch {
                                try { removeManual(address) }
                                catch (cancelled: CancellationException) { throw cancelled }
                                catch (_: Exception) { message(s.operationFailed) }
                                finally { manualBusy = false }
                            }
                        }, enabled = !manualBusy) { ClipyIcon(ClipyIcons.close_rounded, color = LocalContentColor.current, description = s.delete) }
                    }
                }
            }
        }
    }
    removing?.takeIf { activePage }?.let { peer ->
        AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = { removing = null }, containerColor = colors.surface, shape = RoundedCornerShape(24.dp),
            title = { Text(s.delete) }, text = { Text(s.removeDeviceConfirm) },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(s.cancel) } },
            confirmButton = { Button(contentPadding = clipyButtonPadding(), onClick = { removing = null; peerAction(peer.peerId) { capabilities(peer.peerId, false, false) } },
                modifier = Modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = colors.error)) { Text(s.delete) } })
    }
    textPeer?.let { peer ->
        SendTextDialog(peer, dismiss = { textPeer = null }) { text ->
            textPeer = null
            peerAction(peer.peerId) { message(if (sendText(peer, text)) s.textSentTo(peer.name) else s.textDeliveryUnconfirmed) }
        }
    }
    if (adding) ManualPeerDialog(state.settings.port, { adding = false }) { host, port ->
        adding = false; manualBusy = true
        scope.launch {
            try { addManual(host, port) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { message(s.operationFailed) }
            finally { manualBusy = false }
        }
    }
}

@Composable private fun CapabilitySwitch(title: String, value: Boolean, enabled: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(enabled = enabled) { change(!value) }.padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(value, change, enabled = enabled)
    }
}
@Composable private fun DeviceSettingsRow(icon: Int, title: String, subtitle: String, enabled: Boolean, click: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = click).heightIn(min = 80.dp).padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        ClipyIconTile(icon); Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) { Text(title, style = MaterialTheme.typography.bodyLarge); Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Spacer(Modifier.width(16.dp))
        ClipyIcon(ClipyIcons.chevron_right_rounded)
    }
}
@Composable fun SendTextDialog(peer: SyncPeer, dismiss: () -> Unit, initialText: String = "", send: (String) -> Unit) {
    val s = LocalStrings.current; var text by remember { mutableStateOf(initialText) }
    if (!LocalPageActive.current) return
    AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = dismiss, containerColor = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(24.dp),
        title = { Text(s.sendTextTo(peer.name)) }, text = { ClipyTextField(text, { text = it }, label = "", hint = s.enterTextToSend, lines = 3, maximumLines = 6, autofocus = true) },
        dismissButton = { TextButton(onClick = dismiss) { Text(s.cancel) } },
        confirmButton = { Button(contentPadding = clipyButtonPadding(), onClick = { send(text) }, enabled = text.isNotBlank(), modifier = Modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp)) { Text(s.send) } })
}
@Composable private fun ManualPeerDialog(defaultPort: Int, dismiss: () -> Unit, add: (String, Int) -> Unit) {
    val s = LocalStrings.current
    var host by remember { mutableStateOf("") }; var port by remember { mutableStateOf(defaultPort.toString()) }; var validating by remember { mutableStateOf(false) }
    val hostError = validating && !validIPv4(host.trim())
    val portError = validating && port.trim().toIntOrNull()?.let { it !in 1..65535 } != false
    if (!LocalPageActive.current) return
    AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = dismiss, containerColor = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(24.dp), title = { Text(s.addDevice) },
        text = { Column {
            ClipyTextField(host, { host = it }, s.ipAddress, hint = "192.168.1.20", autofocus = true,
                error = if (hostError) s.invalidIP else null, keyboard = KeyboardType.Decimal)
            Spacer(Modifier.height(16.dp))
            ClipyTextField(port, { port = it }, s.syncPort,
                error = if (portError) s.invalidPort else null, keyboard = KeyboardType.Number)
        } }, dismissButton = { TextButton(onClick = dismiss) { Text(s.cancel) } }, confirmButton = { Button(contentPadding = clipyButtonPadding(), onClick = {
            validating = true
            val number = port.trim().toIntOrNull()
            if (validIPv4(host.trim()) && number != null && number in 1..65535) add(host.trim(), number)
        }, modifier = Modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp)) { Text(s.add) } })
}
