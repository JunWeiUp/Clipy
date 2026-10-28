package com.clipyclone.nativeandroid.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clipyclone.clipy_android.ClipyApplication
import com.clipyclone.nativeandroid.notifications.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Faithful port of the embedded NotificationSyncPage: Settings + grouped History. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun NotificationsPage(manager: NativeNotificationManager, message: (String) -> Unit, requestPostPermission: () -> Unit = {}, transferContent: @Composable () -> Unit = {}) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    val state by manager.state.collectAsStateWithLifecycle(); val revision by manager.revision.collectAsStateWithLifecycle()
    val active = LocalPageActive.current; val reduceMotion = LocalReduceMotion.current
    val pager = rememberPagerState { 2 }; val header = rememberPageHeaderState()
    val settingsList = rememberLazyListState(); val historyList = rememberLazyListState()
    var apps by remember { mutableStateOf(emptyList<InstalledNotificationApp>()) }
    var appsLoading by remember { mutableStateOf(true) }; var appsFailed by remember { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }; var query by remember { mutableStateOf("") }
    var expanded by rememberSaveable { mutableStateOf(emptySet<String>()) }
    var collapsed by rememberSaveable { mutableStateOf(emptySet<String>()) }
    var history by remember { mutableStateOf<NotificationSnapshot?>(null) }; var historyFailed by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }; var clear by remember { mutableStateOf(false) }
    var details by remember { mutableStateOf<NotificationEntry?>(null) }
    var detailsFraction by remember { mutableFloatStateOf(.72f) }
    val detailsScroll = rememberTextDocumentState()
    LaunchedEffect(details?.id) { detailsScroll.scrollTo(0) }
    var retry by remember { mutableIntStateOf(0) }
    fun action(block: suspend () -> Unit) { scope.launch { try { block() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { message(s.operationFailed) } } }
    fun copy(text: String): Boolean {
        val ok = (context.applicationContext as? ClipyApplication)?.clipboard?.copy(text) == true
        message(if (ok) s.copiedToClipboard else s.operationFailed)
        return ok
    }
    fun loadApps() {
        appsLoading = true; appsFailed = false
        action { try { apps = manager.installedApps() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { appsFailed = true } finally { appsLoading = false } }
    }
    LaunchedEffect(manager) { manager.initialize(); manager.refreshStatus(); loadApps() }
    LaunchedEffect(search) { delay(250); query = search.trim().lowercase() }
    LaunchedEffect(revision, expanded, retry) {
        try { history = manager.snapshot(expanded); historyFailed = false }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { historyFailed = true }
    }
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle, manager) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) action { manager.refreshStatus() } }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); manager.evictInstalledApps() }
    }
    Column(Modifier.fillMaxSize()) {
        CollapsingPageHeader(header, s.notifications, s.notificationIntro)
        transferContent()
        Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            PrimaryTabRow(selectedTabIndex = pager.currentPage, modifier = Modifier.weight(1f), containerColor = colors.background) {
                listOf(s.notificationSettings, s.notificationHistory).forEachIndexed { index, title ->
                    Tab(pager.currentPage == index, onClick = { scope.launch { if (reduceMotion) pager.scrollToPage(index) else pager.animateScrollToPage(index, animationSpec = tween(300, easing = CubicBezierEasing(.25f, .1f, .25f, 1f))) } },
                        text = { Text(title, style = MaterialTheme.typography.titleSmall) }, selectedContentColor = colors.primary, unselectedContentColor = colors.onSurfaceVariant)
                }
            }
            Box {
                IconButton(onClick = { menu = true }) { ClipyIcon(ClipyIcons.more_vert, description = s.moreActions) }
                DropdownMenu(expanded = menu && active, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(s.notificationListenerPermission) }, onClick = { menu = false; action { manager.platform.openListenerSettings() } })
                    DropdownMenuItem(text = { Text(s.clearNotificationHistory) }, onClick = { menu = false; clear = true })
                    DropdownMenuItem(text = { Text(s.clearAllNotifications) }, onClick = { menu = false; action { manager.clearRemote() } })
                }
            }
        }
        HorizontalPager(state = pager, beyondViewportPageCount = 1, modifier = Modifier.weight(1f)) { page ->
            CompositionLocalProvider(LocalPageActive provides (active && pager.currentPage == page)) {
                if (page == 0) {
                    val filtered = apps.filter { query.isEmpty() || it.name.lowercase().contains(query) || it.packageName.lowercase().contains(query) }
                    LazyColumn(state = settingsList, modifier = Modifier.fillMaxSize().observePageHeader(header) { settingsList.headerMetrics() }) {
                        item { NotificationPermissionCard(state.listener.permission, s, manager) }
                        item { HorizontalDivider() }
                        item {
                            Row(Modifier.fillMaxWidth().heightIn(min = 80.dp).padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                ClipyIcon(if (state.enabled && state.listener.permission) ClipyIcons.sync else ClipyIcons.sync_disabled,
                                    color = if (state.enabled && state.listener.permission) Color(0xFF4CAF50) else Color.Gray)
                                Spacer(Modifier.width(16.dp))
                                Column(Modifier.weight(1f)) { Text(s.enableNotificationSync, style = MaterialTheme.typography.bodyLarge); Text(if (!state.listener.permission) s.notificationPermissionRequired else if (state.enabled) s.syncing else s.paused, style = MaterialTheme.typography.bodyMedium) }
                                Switch(state.enabled && state.listener.permission, { enabled -> action { manager.setEnabled(enabled) } }, enabled = state.listener.permission)
                            }
                        }
                        item { HorizontalDivider() }
                        item {
                            Column(Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 8.dp)) {
                                Text(s.syncNotificationsFrom, style = MaterialTheme.typography.titleMedium)
                                Spacer(Modifier.height(6.dp)); Text(s.packageSelection(state.collected.size, state.synced.size), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        item {
                            NotificationAppSearch(search, { search = it }, s.searchApps)
                        }
                        item {
                            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = { action { manager.collectAll() } }) { ClipyIcon(ClipyIcons.select_all, size = 18.dp); Spacer(Modifier.width(8.dp)); Text(s.collectAll) }
                                TextButton(onClick = { action { manager.syncAll() } }) { ClipyIcon(ClipyIcons.sync, size = 18.dp); Spacer(Modifier.width(8.dp)); Text(s.syncAll) }
                            }
                        }
                        if (appsLoading) item { Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { ClipySpinner() } }
                        else if (appsFailed) item { Column(Modifier.padding(24.dp)) { Text(s.loadFailed); TextButton(onClick = ::loadApps) { Text(s.retry) } } }
                        else if (filtered.isEmpty()) item { Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { Text(s.noAppsAvailable, color = colors.onSurfaceVariant) } }
                        else for ((system, title) in listOf(false to s.userApps, true to s.systemApps)) {
                            val section = filtered.filter { it.system == system }
                            if (section.isNotEmpty()) {
                                item(key = "apps-$system") { NotificationSectionLabel(title, section.size) }
                                items(section, key = { it.packageName }) { app ->
                                    NotificationAppTile(app, manager.isCollected(app.packageName), manager.isSynced(app.packageName),
                                        { value -> action { manager.setCollected(app.packageName, value) } }, { value -> action { manager.setSynced(app.packageName, value) } })
                                }
                            }
                        }
                    }
                } else {
                    val snapshot = history
                    if (snapshot == null && !historyFailed) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { ClipySpinner() }
                    else if (snapshot == null || snapshot.count == 0) ClipyEmptyState(
                        if (historyFailed) ClipyIcons.cloud_off_outlined else ClipyIcons.notifications_none_rounded,
                        if (historyFailed) s.loadFailed else s.noNotificationHistory, if (historyFailed) s.retryHint else s.notificationEmptyHint,
                        if (historyFailed) ({ retry++ }) else null)
                    else LazyColumn(state = historyList, modifier = Modifier.fillMaxSize().observePageHeader(header) { historyList.headerMetrics() }) {
                        item(key = "summary") {
                            Row(Modifier.fillMaxWidth().background(colors.surfaceContainerHighest.copy(alpha = .3f)).padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                ClipyIcon(ClipyIcons.notifications_active, size = 18.dp, color = colors.primary); Spacer(Modifier.width(8.dp))
                                Text(s.notificationsCount(snapshot.count), style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
                                Spacer(Modifier.width(8.dp)); NotificationCountBadge(snapshot.packageCount); Spacer(Modifier.weight(1f))
                                Row(Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button) { clear = true }.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) { ClipyIcon(ClipyIcons.delete_sweep, size = 16.dp, color = colors.primary); Spacer(Modifier.width(8.dp)); Text(s.clearAll, style = MaterialTheme.typography.labelLarge, color = colors.primary) }
                            }
                        }
                        val sections = listOf("synced" to s.syncedSection, "collected" to s.collectedSection, "not_collected" to s.notCollectedSection)
                        for ((key, title) in sections) {
                            val groups = snapshot.groups.filter { group ->
                                val collected = manager.isCollected(group.packageName); val synced = manager.isSynced(group.packageName)
                                when (key) { "synced" -> collected && synced; "collected" -> collected && !synced; else -> !collected }
                            }
                            if (groups.isEmpty()) continue
                            item(key = "section-$key") {
                                val collapsedSection = key in collapsed
                                Row(Modifier.fillMaxWidth().background(colors.surfaceContainerLow).clickable { collapsed = if (collapsedSection) collapsed - key else collapsed + key }
                                    .padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                                    ClipyIcon(if (collapsedSection) ClipyIcons.chevron_right else ClipyIcons.expand_more, size = 18.dp)
                                    Spacer(Modifier.width(4.dp)); ClipyIcon(when (key) { "synced" -> ClipyIcons.sync; "collected" -> ClipyIcons.check_circle_outline; else -> ClipyIcons.block }, size = 16.dp,
                                        color = if (key == "not_collected") colors.onSurfaceVariant else colors.primary)
                                    Spacer(Modifier.width(6.dp)); Text(title, fontSize = 13.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold, color = colors.onSurfaceVariant)
                                    Spacer(Modifier.width(6.dp)); NotificationCountBadge(groups.size)
                                }
                            }
                            if (key in collapsed) continue
                            groups.forEach { group ->
                                val collected = manager.isCollected(group.packageName); val synced = manager.isSynced(group.packageName)
                                item(key = "group-${group.packageName}") {
                                    NotificationGroupHeader(group, group.packageName in expanded, collected, synced,
                                        { expanded = if (group.packageName in expanded) expanded - group.packageName else expanded + group.packageName },
                                        { value -> action { manager.setCollected(group.packageName, value) } },
                                        { value -> action { manager.setSynced(group.packageName, value) } },
                                        { action { copy(manager.forPackage(group.packageName).joinToString("\n\n") { it.detailText() }) } },
                                        { remote -> action { manager.forPackage(group.packageName).forEach { if (remote) manager.dismissRemote(it) else manager.remove(it.id) } } })
                                }
                                if (group.packageName in expanded) items(snapshot.expanded[group.packageName].orEmpty(), key = { it.id }) { entry ->
                                    NotificationHistoryTile(entry, collected, synced,
                                        { action { manager.remove(entry.id) } }, { action { manager.dismissRemote(entry) } },
                                        { copy(entry.detailText()) }, { manager.open(entry) }, { detailsFraction = .72f; details = entry },
                                        { value -> action { manager.setCollected(entry.packageName, value) } },
                                        { value -> action { manager.setSynced(entry.packageName, value) } })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (clear && active) AlertDialog(modifier = clipyDialogModifier(), properties = DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = { clear = false }, containerColor = colors.surface, shape = RoundedCornerShape(24.dp),
        title = { Text(s.clearNotificationHistory) }, text = { Text(s.clearNotificationHistoryConfirm) },
        dismissButton = { TextButton(onClick = { clear = false }) { Text(s.cancel) } },
        confirmButton = { TextButton(onClick = { clear = false; action { manager.clearLocal() } }) { Text(s.clearAll) } })
    if (active) details?.let { entry ->
        NotificationDetailsSheet(entry, detailsFraction, { detailsFraction = it }, detailsScroll,
            dismiss = { details = null }, open = { details = null; manager.open(entry) },
            copy = { if (copy(entry.detailText())) details = null }, copyFailed = { message(s.operationFailed) })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotificationDetailsSheet(entry: NotificationEntry, fraction: Float, changeFraction: (Float) -> Unit,
    scroll: TextDocumentState, dismiss: () -> Unit, open: () -> Unit, copy: () -> Unit, copyFailed: () -> Unit) {
    val colors = MaterialTheme.colorScheme; val s = LocalStrings.current
    val document = remember(entry) { entry.detailText() }
    val density = LocalDensity.current
    // Flutter's DSS fraction applies below the 48dp modal handle, within the app
    // viewport (including status area, excluding the system navigation bar).
    val viewportPixels = LocalWindowInfo.current.containerSize.height - WindowInsets.navigationBars.getBottom(density)
    val bodyMaximum = with(density) { viewportPixels.toDp() } - 48.dp
    val pixels = with(density) { bodyMaximum.toPx() }
    val currentFraction by rememberUpdatedState(fraction)
    val resize: (Float) -> Unit = { delta ->
        val next = (currentFraction - delta / pixels).coerceIn(.35f, .95f)
        if (next <= .35f && delta > 0) dismiss() else changeFraction(next)
    }
    val resizeLatest by rememberUpdatedState(resize)
    val connection = remember(scroll, pixels) { object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            if (source != NestedScrollSource.UserInput) return Offset.Zero
            val before = currentFraction
            if ((available.y < 0 && before < .95f) || (available.y > 0 && scroll.offset == 0)) {
                val next = (before - available.y / pixels).coerceIn(.35f, .95f)
                resizeLatest(available.y)
                return Offset(0f, (before - next) * pixels)
            }
            return Offset.Zero
        }
    } }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        sheetGesturesEnabled = true, containerColor = colors.surface, scrimColor = Color.Black.copy(alpha = .54f),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        dragHandle = { BottomSheetDefaults.DragHandle() }) {
        ClipyModalSystemBars()
        Column(Modifier.fillMaxWidth().height(bodyMaximum * fraction).padding(start = 20.dp, end = 20.dp, bottom = 20.dp)) {
            Column(Modifier.fillMaxWidth()) {
                Text(entry.appName, style = MaterialTheme.typography.titleLarge); Spacer(Modifier.height(4.dp)); Text(entry.packageName, style = MaterialTheme.typography.bodySmall)
            }
            Spacer(Modifier.height(16.dp))
            SelectableLongText(document, Modifier.weight(1f).nestedScroll(connection), style = MaterialTheme.typography.bodyMedium,
                state = scroll, onCopyFailed = copyFailed)
            Spacer(Modifier.height(12.dp))
            Row {
                Button(onClick = open, contentPadding = clipyButtonPadding(icon = true), shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                    ClipyButtonIcon(ClipyIcons.open_in_new); Spacer(Modifier.width(clipyButtonSpacing())); Text("Open")
                }
                Spacer(Modifier.width(8.dp)); TextButton(onClick = copy) { ClipyButtonIcon(ClipyIcons.copy); Spacer(Modifier.width(clipyButtonSpacing())); Text(s.copyContent) }
            }
        }
    }
}

@Composable private fun NotificationPermissionCard(granted: Boolean, s: AppStrings, manager: NativeNotificationManager) {
    val colors = MaterialTheme.colorScheme; val foreground = if (granted) colors.onPrimaryContainer else colors.onTertiaryContainer
    Surface(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), shape = RoundedCornerShape(24.dp), color = if (granted) colors.primaryContainer else colors.tertiaryContainer) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ClipyIcon(if (granted) ClipyIcons.verified_user_outlined else ClipyIcons.notifications_active_outlined, color = foreground)
                Spacer(Modifier.width(12.dp)); Text(if (granted) s.permissionGranted else s.notificationListenerPermission, style = MaterialTheme.typography.titleMedium, color = foreground)
            }
            Spacer(Modifier.height(12.dp)); Text(if (granted) s.notificationIntro else s.permissionGuide, color = foreground, lineHeight = 1.5.em)
            if (!granted) { Spacer(Modifier.height(16.dp)); Button(onClick = { manager.platform.openListenerSettings() }, contentPadding = clipyButtonPadding(), shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) { Text(s.grantPermission) } }
        }
    }
}
@Composable private fun NotificationCountBadge(count: Int, background: Color = MaterialTheme.colorScheme.outlineVariant) {
    Text("$count", Modifier.background(background, RoundedCornerShape(8.dp)).padding(horizontal = 6.dp, vertical = 1.dp), fontSize = 11.sp, lineHeight = 1.5.em, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
@Composable private fun NotificationSectionLabel(title: String, count: Int) {
    Row(Modifier.padding(start = 16.dp, top = 12.dp, end = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 13.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(6.dp)); NotificationCountBadge(count, MaterialTheme.colorScheme.surfaceContainerHigh)
    }
}
@Composable private fun NotificationAppTile(app: InstalledNotificationApp, collected: Boolean, synced: Boolean, collect: (Boolean) -> Unit, sync: (Boolean) -> Unit) {
    val s = LocalStrings.current
    Row(Modifier.fillMaxWidth().heightIn(min = 80.dp).padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        ClipyIconTile(ClipyIcons.apps_rounded, 36.dp); Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) { Text(app.name, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall); Text(app.packageName, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 11.sp, lineHeight = 1.5.em, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) { Text(s.collect, fontSize = 11.sp, lineHeight = 1.0.em); Box(Modifier.size(52.dp, 48.dp), contentAlignment = Alignment.Center) { Switch(collected, collect) } }
            Column(horizontalAlignment = Alignment.CenterHorizontally) { Text(s.sync, fontSize = 11.sp, lineHeight = 1.0.em, color = if (collected) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.outline); Box(Modifier.size(52.dp, 48.dp), contentAlignment = Alignment.Center) { Switch(synced, sync, enabled = collected) } }
        }
    }
}
@Composable private fun NotificationAvatar(name: String, size: Int, fontSize: Int = 14) {
    Box(Modifier.size(size.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape), contentAlignment = Alignment.Center) {
        Text(name.firstOrNull()?.toString() ?: "?", color = MaterialTheme.colorScheme.onPrimaryContainer, fontWeight = FontWeight.Bold, fontSize = fontSize.sp, lineHeight = 1.5.em)
    }
}
@Composable private fun NotificationPill(label: String, selected: Boolean, enabled: Boolean = true, click: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    // The original history-specific pills are 36dp high; do not inflate their visible row to 48dp.
    CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 0.dp) {
        Surface(onClick = click, enabled = enabled, shape = RoundedCornerShape(50), color = if (selected) colors.primaryContainer else colors.surfaceContainerHighest,
            border = BorderStroke(1.dp, if (selected) colors.primary else colors.outlineVariant)) {
            Box(Modifier.heightIn(min = 36.dp).widthIn(min = 48.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
                Text(label, maxLines = 1, fontSize = 12.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold, color = if (!enabled) colors.outline else if (selected) colors.onPrimaryContainer else colors.onSurfaceVariant)
            }
        }
    }
}
@Composable private fun NotificationGroupHeader(group: NotificationGroup, expanded: Boolean, collected: Boolean, synced: Boolean,
    expand: () -> Unit, collect: (Boolean) -> Unit, sync: (Boolean) -> Unit, copy: () -> Unit, delete: (Boolean) -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme; var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().alpha(if (collected) 1f else .55f).padding(horizontal = 12.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).clickable(onClick = expand).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                ClipyIcon(if (expanded) ClipyIcons.expand_more else ClipyIcons.chevron_right, size = 22.dp)
                Spacer(Modifier.width(4.dp)); NotificationAvatar(group.appName, 32); Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) { Text(group.appName, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 14.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold); Spacer(Modifier.height(2.dp)); Text(group.packageName, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 11.sp, lineHeight = 1.5.em, color = colors.onSurfaceVariant) }
            }
            Text("${group.count}", Modifier.background(colors.primary, RoundedCornerShape(10.dp)).padding(horizontal = 8.dp, vertical = 2.dp), fontSize = 12.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold, color = colors.onPrimary)
            Box {
                IconButton(onClick = { menu = true }) { ClipyIcon(ClipyIcons.more_vert, size = 18.dp) }
                DropdownMenu(menu && LocalPageActive.current, { menu = false }) {
                    DropdownMenuItem(text = { Text(if (collected) s.stopCollectingThisApp else s.collectThisApp) }, onClick = { menu = false; collect(!collected) })
                    DropdownMenuItem(text = { Text(if (synced) s.stopSyncingThisApp else s.syncThisApp) }, enabled = collected, onClick = { menu = false; sync(!synced) })
                    DropdownMenuItem(text = { Text(s.copyContent) }, onClick = { menu = false; copy() })
                    DropdownMenuItem(text = { Text(s.dismissOnPhone) }, onClick = { menu = false; delete(true) })
                    DropdownMenuItem(text = { Text(s.delete) }, onClick = { menu = false; delete(false) })
                }
            }
        }
        Row(Modifier.padding(start = 68.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(notificationTime(group.latest, true), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 11.sp, lineHeight = 1.5.em, color = colors.onSurfaceVariant)
            NotificationPill(s.collect, collected) { collect(!collected) }; Spacer(Modifier.width(6.dp))
            NotificationPill(s.sync, collected && synced, collected) { sync(!synced) }
        }
    }
    HorizontalDivider(color = colors.outlineVariant)
}
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable private fun NotificationHistoryTile(entry: NotificationEntry, collected: Boolean, synced: Boolean, delete: () -> Unit,
    remoteDelete: () -> Unit, copy: () -> Unit, open: () -> Unit, details: () -> Unit, collect: (Boolean) -> Unit, sync: (Boolean) -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme; var menu by remember { mutableStateOf(false) }
    val dismiss = rememberSwipeToDismissBoxState(confirmValueChange = { value -> if (value == SwipeToDismissBoxValue.EndToStart) { delete(); true } else false })
    SwipeToDismissBox(state = dismiss, modifier = Modifier.alpha(if (collected) 1f else .55f), enableDismissFromStartToEnd = false, backgroundContent = {
        Box(Modifier.fillMaxSize().background(Color.Red).padding(end = 16.dp), contentAlignment = Alignment.CenterEnd) { ClipyIcon(ClipyIcons.delete, color = Color.White) }
    }) {
        val title = entry.title.trim().ifEmpty { entry.body.trim().ifEmpty { entry.appName } }; val body = entry.body.trim()
        val threeLine = entry.isArchived || (body.isNotEmpty() && body != title)
        val preview = remember(body) { body.lineSequence().take(2).joinToString("\n") }
        Row(Modifier.fillMaxWidth().background(colors.background).combinedClickable(onClick = open, onLongClick = details)
            .heightIn(min = if (threeLine) 96.dp else 80.dp).padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.Top) {
            NotificationAvatar(entry.appName, 40, 16); Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 14.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold)
                if (entry.isArchived) Text(s.notificationArchivedBadge, Modifier.padding(bottom = 2.dp), fontSize = 11.sp, lineHeight = 1.5.em, fontWeight = FontWeight.SemiBold, color = colors.tertiary)
                if (body.isNotEmpty() && body != title) Text(preview, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, lineHeight = 1.5.em, color = colors.onSurfaceVariant)
                Spacer(Modifier.height(2.dp))
                Text("${notificationTime(entry.postTime)} · ${if (collected) s.collect else s.appCollectDisabled} · ${if (synced) s.sync else s.appSyncDisabled}", maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 11.sp, lineHeight = 1.5.em, color = colors.onSurfaceVariant)
            }
            Box {
                IconButton(onClick = { menu = true }) { ClipyIcon(ClipyIcons.more_vert, size = 18.dp) }
                DropdownMenu(menu && LocalPageActive.current, { menu = false }) {
                    DropdownMenuItem(text = { Text(s.copyContent) }, onClick = { menu = false; copy() })
                    DropdownMenuItem(text = { Text(if (collected) s.stopCollectingThisApp else s.collectThisApp) }, onClick = { menu = false; collect(!collected) })
                    DropdownMenuItem(text = { Text(if (synced) s.stopSyncingThisApp else s.syncThisApp) }, enabled = collected, onClick = { menu = false; sync(!synced) })
                    if (entry.isClearable) DropdownMenuItem(text = { Text(s.dismissOnPhone) }, onClick = { menu = false; remoteDelete() })
                    DropdownMenuItem(text = { Text(s.delete) }, onClick = { menu = false; delete() })
                }
            }
        }
    }
}
private fun notificationTime(timestamp: Long, showDate: Boolean = false): String {
    val date = Calendar.getInstance().apply { timeInMillis = timestamp }; val today = Calendar.getInstance()
    val sameDay = date.get(Calendar.YEAR) == today.get(Calendar.YEAR) && date.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)
    return SimpleDateFormat(if (showDate && !sameDay) "M/d HH:mm" else "HH:mm", Locale.US).format(Date(timestamp))
}

@Composable private fun NotificationAppSearch(value: String, change: (String) -> Unit, hint: String) {
    val colors = MaterialTheme.colorScheme
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    BasicTextField(value, change, singleLine = true, interactionSource = interaction,
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface),
        cursorBrush = SolidColor(colors.primary),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        decorationBox = { field ->
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                .background(colors.surfaceContainerLow, RoundedCornerShape(18.dp))
                .then(if (focused) Modifier.border(1.5.dp, colors.primary, RoundedCornerShape(18.dp)) else Modifier),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { ClipyIcon(ClipyIcons.search, size = 20.dp) }
                Box(Modifier.weight(1f).padding(end = 16.dp)) {
                    if (value.isEmpty()) Text(hint, style = MaterialTheme.typography.bodyLarge, color = colors.onSurfaceVariant)
                    field()
                }
            }
        })
}
