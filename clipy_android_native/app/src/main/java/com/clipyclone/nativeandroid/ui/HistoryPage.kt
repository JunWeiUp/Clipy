package com.clipyclone.nativeandroid.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.em
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import com.clipyclone.nativeandroid.HistoryState
import com.clipyclone.nativeandroid.data.*
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import kotlin.math.abs

/** Port of PaginatedClipboardHistoryList and its collapsing intro. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
fun HistoryPage(state: HistoryState, search: (String, HistoryFilter) -> Unit, refresh: () -> Unit,
                more: () -> Unit, copy: (HistoryEntry) -> Boolean, send: (HistoryEntry) -> Unit,
                openFile: (HistoryEntry) -> Unit, modifier: Modifier = Modifier, topContent: @Composable () -> Unit = {}, copyFailed: () -> Unit = {}) {
    val s = LocalStrings.current
    val colors = MaterialTheme.colorScheme
    val list = rememberLazyListState()
    val active = LocalPageActive.current
    val view = LocalView.current
    val pageFocus = remember { FocusRequester() }
    LaunchedEffect(Unit) { if (active) pageFocus.requestFocus() }
    var selected by remember { mutableStateOf<HistoryEntry?>(null) }
    val previewTextState = rememberTextDocumentState()
    LaunchedEffect(selected?.id) { previewTextState.scrollTo(0) }
    var copied by remember { mutableStateOf<String?>(null) }
    val header = rememberPageHeaderState()
    LaunchedEffect(state.query, state.filter) { list.scrollToItem(0); header.reset() }
    LaunchedEffect(copied) { if (copied != null) { kotlinx.coroutines.delay(2000); copied = null } }
    LaunchedEffect(list, state.entries.size, state.loading, state.canLoadMore) {
        if (state.canLoadMore && !state.loading) snapshotFlow {
            val last = list.layoutInfo.visibleItemsInfo.lastOrNull()
            last != null && last.index >= list.layoutInfo.totalItemsCount - 3
        }.collect { if (it) more() }
    }
    fun copyEntry(entry: HistoryEntry) {
        if (copy(entry)) {
            view.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)
            copied = entry.hash ?: entry.id.toString()
        }
    }
    Column(modifier.fillMaxSize().focusRequester(pageFocus).focusable()) {
        CollapsingPageHeader(header, s.history, s.historyTagline)
        topContent()
        OutlinedTextField(value = state.query, onValueChange = { search(it, state.filter) }, singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge,
            placeholder = { Text(s.searchHistory, style = MaterialTheme.typography.bodyLarge) },
            leadingIcon = { ClipyIcon(ClipyIcons.search_rounded) },
            trailingIcon = if (state.query.isNotEmpty()) ({ IconButton(onClick = { search("", state.filter) }) {
                ClipyIcon(ClipyIcons.close_rounded, description = s.clearSearch) } }) else null,
            shape = RoundedCornerShape(18.dp),
            colors = OutlinedTextFieldDefaults.colors(focusedContainerColor = colors.surfaceContainerLow,
                unfocusedContainerColor = colors.surfaceContainerLow, focusedBorderColor = colors.primary,
                unfocusedBorderColor = androidx.compose.ui.graphics.Color.Transparent),
            modifier = Modifier.fillMaxWidth().padding(start = 20.dp, top = 4.dp, end = 20.dp, bottom = 8.dp))
        val density = LocalDensity.current
        val labelRatio = with(density) { MaterialTheme.typography.labelLarge.fontSize.toPx() } / density.density / 14f
        val labelPadding = (8f - 4f * (labelRatio - 1f).coerceIn(0f, 1f)).dp
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 8.dp)) {
            HistoryFilter.entries.forEach { filter ->
                val label = when (filter) {
                    HistoryFilter.ALL -> s.allItems; HistoryFilter.TEXT -> s.textItems; HistoryFilter.LINKS -> s.linkItems
                    HistoryFilter.FILES -> s.fileItems; HistoryFilter.IMAGES -> s.imageItems
                }
                Surface(onClick = { search(state.query, filter) }, modifier = Modifier.padding(end = 8.dp).semantics { this.selected = state.filter == filter; role = Role.Button },
                    shape = RoundedCornerShape(14.dp), color = if (state.filter == filter) colors.secondaryContainer else colors.surface,
                    contentColor = if (state.filter == filter) colors.onSecondaryContainer else colors.onSurfaceVariant) {
                    Box(Modifier.padding(8.dp).padding(horizontal = labelPadding), contentAlignment = Alignment.Center) {
                        Text(label, style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
        }
        }
        Box(Modifier.weight(1f)) {
            if (state.entries.isEmpty()) {
                val filtered = state.query.trim().isNotEmpty() || state.filter != HistoryFilter.ALL
                if (state.loading) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { ClipySpinner() }
                else ClipyEmptyState(
                    if (state.error) ClipyIcons.cloud_off_rounded else if (filtered) ClipyIcons.search_off_rounded else ClipyIcons.content_paste_rounded,
                    if (state.error) s.loadFailed else if (filtered) s.nothingFound else s.noClipboardHistory,
                    if (state.error) s.retryHint else if (filtered) s.changeSearchHint else s.historyEmptyHint,
                    if (state.error) refresh else null)
            } else PullToRefreshBox(isRefreshing = state.loading && LocalPageActive.current, onRefresh = refresh) {
                LazyColumn(state = list, modifier = Modifier.fillMaxSize().observePageHeader(header) { list.headerMetrics() },
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 24.dp)) {
                    itemsIndexed(state.entries, key = { _, row -> row.id }) { index, entry ->
                        val date = dateLabel(entry.createdAt, s)
                        if (index == 0 || dateLabel(state.entries[index - 1].createdAt, s) != date) {
                            Text(date, Modifier.padding(horizontal = 4.dp, vertical = 12.dp),
                                style = MaterialTheme.typography.titleSmall, color = colors.onSurfaceVariant)
                        }
                        HistoryCard(entry, copied == (entry.hash ?: entry.id.toString()), onClick = {
                            when (entry.type) { "text" -> copyEntry(entry); "fileURL", "fileURLs" -> openFile(entry); else -> selected = entry }
                        }, onLongClick = { selected = entry })
                    }
                    if (state.error) item { TextButton(onClick = refresh) { Text(s.retry) } }
                    else if (state.loading) item { Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) { ClipySpinner() } }
                }
            }
        }
    }
    selected?.takeIf { LocalPageActive.current }?.let { entry ->
        val previewDensity = LocalDensity.current
        val previewWindow = LocalWindowInfo.current.containerSize.height
        val previewNav = WindowInsets.navigationBars.getBottom(previewDensity)
        val previewHeight = with(previewDensity) { (previewWindow - previewNav).toDp() } * .65f
        ModalBottomSheet(sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), onDismissRequest = { selected = null }, scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), containerColor = colors.surface,
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
            ClipyModalSystemBars()
            Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp)
                .height(previewHeight)) {
                ClipyHeadingText(s.preview, MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(16.dp))
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    if (entry.type == "image") Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) { HistoryImagePreview(entry.value) }
                    else SelectableLongText(historyFullValue(entry), Modifier.fillMaxSize(), style = MaterialTheme.typography.bodyMedium,
                        state = previewTextState, onCopyFailed = copyFailed)
                }
                Spacer(Modifier.height(20.dp))
                if (entry.type == "text") FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(contentPadding = clipyButtonPadding(icon = true), onClick = { selected = null; copyEntry(entry) }, shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                        ClipyButtonIcon(ClipyIcons.copy_rounded); Spacer(Modifier.width(clipyButtonSpacing())); Text(s.copyContent)
                    }
                    OutlinedButton(border = clipyOutlinedBorder(), colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.primary), contentPadding = clipyButtonPadding(icon = true), onClick = { selected = null; send(entry) }, shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                        ClipyButtonIcon(ClipyIcons.send_outlined); Spacer(Modifier.width(clipyButtonSpacing())); Text(s.send)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryCard(entry: HistoryEntry, copied: Boolean, onClick: () -> Unit, onLongClick: () -> Unit) {
    val s = LocalStrings.current
    val colors = MaterialTheme.colorScheme
    val file = entry.type == "fileURL" || entry.type == "fileURLs"
    val text = entry.type == "text"
    val link = text && (entry.value.trim().startsWith("http://", true) || entry.value.trim().startsWith("https://", true))
    val glyph = if (file) ClipyIcons.description_outlined else if (link) ClipyIcons.link_rounded else if (text) ClipyIcons.notes_rounded else ClipyIcons.image_outlined
    Surface(Modifier.fillMaxWidth().padding(bottom = 10.dp), shape = RoundedCornerShape(24.dp), color = colors.surface) {
        Column(Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ClipyIcon(glyph, size = 18.dp, color = colors.primary)
                Spacer(Modifier.width(8.dp))
                Text(entry.source ?: "Clipy", Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
                Text(java.text.SimpleDateFormat(if (s.chinese) "a h:mm" else "h:mm a", if (s.chinese) java.util.Locale.CHINA else java.util.Locale.US).format(Date(entry.createdAt)),
                    style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            }
            Spacer(Modifier.height(12.dp))
            Text(historyTitle(entry), maxLines = 3, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyLarge.copy(lineHeight = 1.45.em))
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (file) historyPaths(entry).firstOrNull().orEmpty() else if (text) s.tapToCopy else s.preview, Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                Crossfade(copied, animationSpec = tween(if (LocalReduceMotion.current || !LocalPageActive.current) 0 else 180), label = "history-copy-feedback") { checked ->
                    ClipyIcon(if (checked) ClipyIcons.check_rounded else if (file) ClipyIcons.folder_open_rounded else if (text) ClipyIcons.copy_rounded else ClipyIcons.open_in_full_rounded,
                        size = 18.dp, color = colors.primary)
                }
            }
        }
    }
}

private fun dateLabel(time: Long, s: AppStrings): String {
    val day = Calendar.getInstance().apply { timeInMillis = time }
    val today = Calendar.getInstance()
    fun same() = day.get(Calendar.YEAR) == today.get(Calendar.YEAR) && day.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)
    if (same()) return s.today
    today.add(Calendar.DAY_OF_YEAR, -1)
    return if (same()) s.yesterday else materialMediumDate(time, s.chinese)
}

fun historyPaths(entry: HistoryEntry): List<String> = when (entry.type) {
    "fileURL" -> listOf(entry.value)
    "fileURLs" -> runCatching { val array = JSONArray(entry.value); List(array.length()) { array.getString(it) } }.getOrDefault(emptyList())
    else -> emptyList()
}
fun historyFullValue(entry: HistoryEntry): String = if (entry.type == "fileURLs") historyPaths(entry).joinToString("\n") else entry.value
fun historyTitle(entry: HistoryEntry): String = when (entry.type) {
    "text" -> {
        var end = minOf(600, entry.value.length)
        if (end < entry.value.length && end > 0 && entry.value[end - 1].isHighSurrogate()) end--
        entry.value.substring(0, end).trim().replace('\n', ' ') + if (end < entry.value.length) "…" else ""
    }
    "image" -> "[Image]"
    "fileURL" -> "[File] ${File(entry.value).name}"
    "fileURLs" -> historyPaths(entry).let { "[${it.size} Files] ${it.firstOrNull()?.let { path -> File(path).name }.orEmpty()}" }
    else -> "[${entry.type}]"
}
@Composable
private fun HistoryImagePreview(path: String) {
    val s = LocalStrings.current
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current.density
    val maxWidth = (configuration.screenWidthDp * density).toInt().coerceAtLeast(1)
    val maxHeight = (configuration.screenHeightDp * density).toInt().coerceAtLeast(1)
    val decoded by produceState<Result<android.graphics.Bitmap>?>(null, path, maxWidth, maxHeight) {
        value = null
        value = withContext(Dispatchers.IO) {
            runCatching {
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(path, bounds)
                var sample = 1
                while (bounds.outWidth / sample > maxWidth * 2 || bounds.outHeight / sample > maxHeight * 2) sample *= 2
                android.graphics.BitmapFactory.decodeFile(path, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
                    ?: error("Image unavailable")
            }
        }
    }
    when {
        decoded == null -> Spacer(Modifier.fillMaxWidth().height(1.dp))
        decoded?.isFailure == true -> Text(s.fileNotFound)
        else -> decoded?.getOrNull()?.let { Image(it.asImageBitmap(), contentDescription = null, modifier = Modifier.fillMaxWidth().aspectRatio(it.width.toFloat() / it.height), contentScale = ContentScale.Fit) }
    }
}
