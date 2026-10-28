package com.clipyclone.nativeandroid

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.clipy_android.SharedFileInbox
import com.clipyclone.clipy_android.TransferNotifications
import com.clipyclone.nativeandroid.sharing.ShareImportException
import com.clipyclone.nativeandroid.sync.*
import com.clipyclone.nativeandroid.ui.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import java.util.UUID
import kotlin.math.roundToInt

class MainActivity : ComponentActivity() {
    private var notificationPath: String? = null
    private var picker: CompletableDeferred<Uri?>? = null
    private val filePicker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        picker?.complete(if (result.resultCode == RESULT_OK) result.data?.data ?: result.data?.clipData?.getItemAt(0)?.uri else null)
        picker = null
    }
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        lifecycleScope.launch { (application as ClipyApplication).notifications.checkHealth() }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        notificationPath = TransferNotifications.takePath(this, intent)
        if (savedInstanceState == null) SharedFileInbox.enqueue(applicationContext, Intent(intent))
        val app = application as ClipyApplication
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                app.sync.state.first { it.initialized }
                app.clipboard.attach(); app.notifications.setForeground(true)
                try { awaitCancellation() }
                finally { app.clipboard.detach(); app.notifications.setForeground(false) }
            }
        }
        setContent { NativeApp(app, ::pickFile, ::requestNotifications) }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && (application as ClipyApplication).sync.state.value.initialized) (application as ClipyApplication).clipboard.onFocus()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        notificationPath = TransferNotifications.takePath(this, intent)
        SharedFileInbox.enqueue(applicationContext, Intent(intent))
    }
    override fun onPostResume() {
        super.onPostResume()
        notificationPath?.let { path ->
            notificationPath = null
            if (NativeFileNavigator.openFolder(this, path) != OpenFileResult.OPENED) {
                android.widget.Toast.makeText(this,
                    if (resources.configuration.locales[0].language == "zh") "文件已移动或没有可用的打开方式" else "File moved or no viewer available",
                    android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }
    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
    private suspend fun pickFile(): Uri? {
        if (picker != null) return null
        val result = CompletableDeferred<Uri?>()
        picker = result
        try {
            // Match the pinned file_picker plugin's Android API>=19 path.
            filePicker.launch(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false).putExtra("multi-pick", false))
            return result.await()
        } finally { if (picker === result) picker = null }
    }
    override fun onDestroy() { picker?.complete(null); picker = null; super.onDestroy() }
}

private enum class Page { HOME, FILES, LOGS, DIAGNOSTICS, GROUPS, SHARED, DEVICES }
private data class Route(val key: String, val page: Page, val shareId: String? = null)
private enum class ModalKind { CONNECTION, CLEAR_HISTORY, SEND_HISTORY }
private data class Modal(val key: String, val owner: String, val kind: ModalKind, val text: String = "", val peers: List<SyncPeer> = emptyList())

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NativeApp(app: ClipyApplication, pickFile: suspend () -> Uri?, requestNotifications: () -> Unit,
                      preferences: PreferencesViewModel = viewModel()) {
    val preference by preferences.state.collectAsStateWithLifecycle()
    val dark = when (preference.appearance) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
    val reduceMotion = rememberReduceMotion(app)
    ClipyTheme(dark, chinese = preference.language == "zh") {
        CompositionLocalProvider(LocalStrings provides AppStrings(preference.language == "zh"), LocalReduceMotion provides reduceMotion) {
            val strings = LocalStrings.current
            val latestStrings by rememberUpdatedState(strings)
            val sync by app.sync.state.collectAsStateWithLifecycle()
            val startupError by app.startupError.collectAsStateWithLifecycle()
            val relay by app.relay.state.collectAsStateWithLifecycle()
            val shares by SharedFileInbox.pending.collectAsStateWithLifecycle()
            val transfers by app.fileTransfers.active.collectAsStateWithLifecycle()
            val scope = rememberCoroutineScope(); val snackbar = remember { SnackbarHostState() }
            val focus = LocalFocusManager.current
            val keyboard = LocalSoftwareKeyboardController.current
            var selected by rememberSaveable { mutableIntStateOf(0) }
            val routes = remember { mutableStateListOf(Route("home", Page.HOME)) }
            val awaiters = remember { mutableMapOf<String, CompletableDeferred<Unit>>() }
            val modals = remember { mutableStateListOf<Modal>() }
            val ime = WindowInsets.ime
            val density = LocalDensity.current
            val keyboardVisible by remember(ime, density) { derivedStateOf { ime.getBottom(density) > 0 } }
            LaunchedEffect(routes.last().key) {
                focus.clearFocus(force = true); keyboard?.hide()
                withFrameNanos { }
                focus.clearFocus(force = true); keyboard?.hide()
            }
            LaunchedEffect(routes.last().page, keyboardVisible) {
                // External shares have no editable field; discard late IME-show requests from the hidden tab.
                if (routes.last().page == Page.SHARED && keyboardVisible) {
                    focus.clearFocus(force = true); keyboard?.hide()
                }
            }
            fun modal(kind: ModalKind, text: String = "", peers: List<SyncPeer> = emptyList()) {
                focus.clearFocus(force = true); keyboard?.hide()
                modals.add(Modal(UUID.randomUUID().toString(), routes.last().key, kind, text, peers))
            }
            fun message(value: String) { scope.launch { snackbar.currentSnackbarData?.dismiss(); snackbar.showSnackbar(value) } }
            fun push(page: Page, shareId: String? = null): Route {
                focus.clearFocus(force = true); keyboard?.hide()
                return Route(UUID.randomUUID().toString(), page, shareId).also { routes.add(it) }
            }
            fun pop() {
                if (routes.size <= 1) return
                focus.clearFocus(force = true); keyboard?.hide()
                val old = routes.removeAt(routes.lastIndex)
                modals.removeAll { it.owner == old.key }
                if (old.page == Page.SHARED) old.shareId?.let { SharedFileInbox.complete(app, it) }
                awaiters.remove(old.key)?.complete(Unit)
            }
            fun openPath(path: String) {
                when (NativeFileNavigator.openFolder(app, path)) {
                    OpenFileResult.OPENED -> Unit
                    OpenFileResult.MISSING -> message(strings.fileNotFound)
                    OpenFileResult.NO_ACTIVITY -> message(strings.noFileManager)
                    OpenFileResult.FAILED -> message(strings.couldNotOpenFolder("OPEN_FAILED"))
                }
            }
            suspend fun sendPicked(peer: SyncPeer) {
                val uri = pickFile() ?: return
                val operation = app.appScope.async(Dispatchers.Default) {
                    val staged = SharedFileInbox.stageSingle(app, uri)
                    try { app.fileTransfers.send(staged.file, peer.peerId) }
                    finally { withContext(NonCancellable) { staged.close() } }
                }
                try { message(if (operation.await()) strings.fileSentTo(peer.name) else strings.sendFailed) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (error: ShareImportException) { message(strings.shareImportError(error.code)) }
                catch (_: Exception) { message(strings.sendFailed) }
            }
            @Composable fun devices() {
                DevicesPage(sync,
                    toggle = { enabled -> if (enabled) requestNotifications(); app.setSyncEnabled(enabled) },
                    refresh = { app.sync.refreshDiscovery(); app.sync.state.value.peers.count { it.discovered } },
                    editConnection = { modal(ModalKind.CONNECTION) }, diagnostics = { push(Page.DIAGNOSTICS) },
                    capabilities = { id, clipboard, notifications -> app.sync.updateCapabilities(id, clipboard, notifications) },
                    sendText = { peer, text -> app.sync.sendText(text, peer.peerId) }, sendFile = { sendPicked(it) },
                    addManual = { host, port -> app.sync.addManualPeer(host, port) }, removeManual = { app.sync.removeManualPeer(it) },
                    message = ::message, relayState = RelayConnectivity.valueOf(relay.control.name), hasRelay = sync.hasRelaySession) {
                    RelaySettingsPanel(app.relay, openGroups = { push(Page.GROUPS) }, message = ::message)
                }
            }
            LaunchedEffect(shares.firstOrNull()?.id, routes.lastOrNull()?.key) {
                val first = shares.firstOrNull() ?: return@LaunchedEffect
                if (routes.none { it.page == Page.SHARED }) push(Page.SHARED, first.id)
            }
            LaunchedEffect(app) {
                app.filesReceived.collect { file ->
                    scope.launch {
                        snackbar.currentSnackbarData?.dismiss()
                        if (snackbar.showSnackbar(latestStrings.receivedFile(file.name), actionLabel = latestStrings.view, duration = SnackbarDuration.Short) == SnackbarResult.ActionPerformed) push(Page.FILES)
                    }
                }
            }
            DisposableEffect(Unit) { onDispose { awaiters.values.forEach { it.cancel() }; awaiters.clear() } }
            BackHandler(enabled = routes.size > 1) { pop() }
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
                if (!sync.initialized) {
                    if (startupError != null) ClipyEmptyState(ClipyIcons.cloud_off_rounded, strings.loadFailed, strings.retryHint, app::retryInitialization)
                    else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { ClipySpinner() }
                }
                else {
                    val history: HistoryViewModel = viewModel()
                    val feed by history.state.collectAsStateWithLifecycle()
                    ActivePageLayout(routes.toList(), routes.last(), Modifier.fillMaxSize()) { route ->
                        when (route.page) {
                            Page.HOME -> ClipyShell(selected, { selected = it }, { push(Page.FILES) }, { modal(ModalKind.CLEAR_HISTORY) }, feed.writing, reduceMotion) { tab ->
                                Column(Modifier.fillMaxSize()) {
                                    Box(Modifier.weight(1f)) {
                                        when (tab) {
                                            0 -> HistoryPage(feed, history::search, { history.refresh() }, history::more,
                                                copy = { entry -> app.clipboard.copy(entry.value).also { message(if (it) strings.copiedToClipboard else strings.operationFailed) } },
                                                send = { entry ->
                                                    val peers = app.sync.state.value.peers.filter { it.discovered }
                                                    if (peers.isEmpty()) message(strings.noDevicesFound) else modal(ModalKind.SEND_HISTORY, entry.value, peers)
                                                }, openFile = { entry -> historyPaths(entry).firstOrNull()?.let(::openPath) ?: message(strings.fileNotFound) },
                                                topContent = { if (transfers.isNotEmpty()) TransferProgressList(transfers.values.toList()) }, copyFailed = { message(strings.operationFailed) })
                                            1 -> Column(Modifier.fillMaxSize()) {
                                                if (transfers.isNotEmpty()) TransferProgressList(transfers.values.toList())
                                                Box(Modifier.weight(1f)) { devices() }
                                            }
                                            2 -> NotificationsPage(app.notifications, message = ::message, requestPostPermission = requestNotifications,
                                                transferContent = { if (transfers.isNotEmpty()) TransferProgressList(transfers.values.toList()) })
                                            3 -> SettingsPage(preference, preferences::appearance, preferences::language,
                                                { modal(ModalKind.CONNECTION) }, { push(Page.FILES) }, { push(Page.LOGS) }, ::message,
                                                topContent = { if (transfers.isNotEmpty()) TransferProgressList(transfers.values.toList()) })
                                        }
                                    }
                                }
                            }
                            Page.FILES -> ReceivedFilesPage(app.receivedFiles, app.fileRevision, ::pop, { openPath(it.path) }, ::message)
                            Page.LOGS -> LogPage(app.logs, ::pop, copy = { text ->
                                try { app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Clipy", text)); true } catch (_: Exception) { false }
                            }, message = ::message)
                            Page.DIAGNOSTICS -> SyncDiagnosticsPage(app.sync, ::pop)
                            Page.GROUPS -> RelayGroupPage(app.relay, back = ::pop, message = ::message)
                            Page.DEVICES -> Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = { SecondaryAppBar(strings.lanDevices, ::pop) }) {
                                Box(Modifier.fillMaxSize().padding(it).consumeWindowInsets(it).imePadding()) { devices() }
                            }
                            Page.SHARED -> {
                                val share = shares.firstOrNull { it.id == route.shareId }
                                if (share != null) SharedFilesPage(share, app.sync,
                                    sendFile = { file, peer -> app.fileTransfers.send(file, peer) },
                                    openDevices = {
                                        val child = push(Page.DEVICES); val done = CompletableDeferred<Unit>(); awaiters[child.key] = done
                                        try { done.await() } finally { awaiters.remove(child.key) }
                                    }, close = ::pop, message = ::message)
                            }
                        }
                    }

                }
                SnackbarHost(snackbar, modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                    .padding(bottom = if (routes.last().page == Page.HOME && androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp < 720) 76.dp else 0.dp)
                    .padding(16.dp)) { data -> Snackbar(data, shape = RoundedCornerShape(16.dp)) }
            }
            modals.forEach { dialog ->
                key(dialog.key) {
                    val visible = dialog.owner == routes.last().key && modals.lastOrNull { it.owner == dialog.owner }?.key == dialog.key
                    CompositionLocalProvider(LocalPageActive provides visible) {
                        when (dialog.kind) {
                            ModalKind.CONNECTION -> ConnectionEditor(sync.settings, { modals.remove(dialog) }, app.sync::saveConnection, ::message)
                            ModalKind.CLEAR_HISTORY -> if (visible && sync.initialized) {
                                val history: HistoryViewModel = viewModel()
                                val feed by history.state.collectAsStateWithLifecycle()
                                AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = { modals.remove(dialog) }, containerColor = MaterialTheme.colorScheme.surface,
                                    shape = RoundedCornerShape(24.dp), title = { Text(strings.clearHistory) }, text = { Text(strings.clearHistoryConfirm) },
                                    dismissButton = { TextButton(onClick = { modals.remove(dialog) }) { Text(strings.cancel) } },
                                    confirmButton = { Button(contentPadding = clipyButtonPadding(), modifier = Modifier.heightIn(min = 48.dp), enabled = !feed.writing, onClick = {
                                        modals.remove(dialog); history.clear(onSuccess = { message(strings.historyCleared) }, onFailure = { message(strings.operationFailed) })
                                    }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error), shape = RoundedCornerShape(16.dp)) { Text(strings.delete) } })
                            }
                            ModalKind.SEND_HISTORY -> HistorySendSheet(dialog, dismiss = { modals.remove(dialog) }) { peer ->
                                modals.remove(dialog)
                                scope.launch {
                                    try { message(if (app.sync.sendText(dialog.text, peer.peerId)) strings.textSentTo(peer.name) else strings.sendFailed) }
                                    catch (cancelled: CancellationException) { throw cancelled }
                                    catch (_: Exception) { message(strings.sendFailed) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistorySendSheet(dialog: Modal, dismiss: () -> Unit, select: (SyncPeer) -> Unit) {
    val s = LocalStrings.current
    val scroll = rememberScrollState()
    val density = LocalDensity.current
    val maximumHeight = with(density) { (LocalWindowInfo.current.containerSize.height - WindowInsets.navigationBars.getBottom(this)).toDp() } * .65f
    if (LocalPageActive.current) ModalBottomSheet(sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), onDismissRequest = dismiss, scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
        ClipyModalSystemBars()
        Column(Modifier.fillMaxWidth().navigationBarsPadding().heightIn(max = maximumHeight).verticalScroll(scroll)) {
            Box(Modifier.padding(20.dp)) { ClipyHeadingText(s.sendText, MaterialTheme.typography.titleLarge) }
            dialog.peers.forEach { peer ->
                Row(Modifier.fillMaxWidth().clickable { select(peer) }.heightIn(min = 80.dp).padding(horizontal = 20.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    ClipyIconTile(ClipyIcons.devices_rounded); Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(peer.name, style = MaterialTheme.typography.bodyLarge)
                        Text(peer.host, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun TransferProgressList(progress: List<FileProgress>) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    Column(Modifier.heightIn(max = 140.dp).verticalScroll(rememberScrollState())) {
        progress.forEach { transfer ->
            Surface(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 10.dp), color = colors.surface, shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.padding(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ClipyIcon(if (transfer.outgoing) ClipyIcons.upload_rounded else ClipyIcons.download_rounded, size = 18.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(if (transfer.outgoing) s.sending(transfer.name) else s.receiving(transfer.name), Modifier.weight(1f), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        Spacer(Modifier.width(8.dp)); Text("${(transfer.fraction * 100).roundToInt()}%")
                    }
                    Spacer(Modifier.height(10.dp))
                    LinearProgressIndicator(progress = { transfer.fraction }, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun rememberReduceMotion(context: android.content.Context): Boolean {
    fun read() = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    var reduced by remember { mutableStateOf(read()) }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) { override fun onChange(selfChange: Boolean) { reduced = read() } }
        context.contentResolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    return reduced
}
