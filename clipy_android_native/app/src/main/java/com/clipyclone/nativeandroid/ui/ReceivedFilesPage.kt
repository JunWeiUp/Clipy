package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.clipyclone.nativeandroid.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** Route-local tasks and subscriptions cancel on pop, matching the existing files page. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceivedFilesPage(store: ReceivedFileStore, revision: StateFlow<Long>, back: () -> Unit,
                      open: (ReceivedFile) -> Unit, message: (String) -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope(); val list = rememberLazyListState()
    var entries by remember { mutableStateOf(emptyList<ReceivedFile>()) }
    var loading by remember { mutableStateOf(false) }; var failed by remember { mutableStateOf(false) }
    var hasMore by remember { mutableStateOf(true) }; var pendingRefresh by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(emptySet<Long>()) }; var confirmation by remember { mutableStateOf<ReceivedFile?>(null) }
    fun load(reset: Boolean) {
        if (loading) { pendingRefresh = pendingRefresh || reset; return }
        loading = true; failed = false
        scope.launch {
            var refresh = reset
            try {
                do {
                    val page = store.page(offset = if (refresh) 0 else entries.size, limit = 20)
                    entries = if (refresh) page else entries + page
                    hasMore = page.size == 20
                    refresh = pendingRefresh; pendingRefresh = false
                } while (refresh)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { loading = false }
        }
    }
    LaunchedEffect(revision) { revision.collect { load(true) } }
    LaunchedEffect(entries.size, hasMore, loading) {
        if (hasMore && !loading && entries.isNotEmpty()) snapshotFlow {
            list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= entries.size - 2 } == true
        }.collect { if (it) load(false) }
    }
    Scaffold(containerColor = colors.background, topBar = {
        SecondaryAppBar(s.receivedFiles, back)
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Box(Modifier.padding(start = 24.dp, top = 8.dp, end = 24.dp, bottom = 20.dp)) { ClipyHeadingText(s.filesHint, MaterialTheme.typography.titleLarge) }
            Box(Modifier.weight(1f)) {
                if (entries.isEmpty()) {
                    if (loading) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { ClipySpinner() }
                    else ClipyEmptyState(if (failed) ClipyIcons.cloud_off_rounded else ClipyIcons.folder_open_rounded,
                        if (failed) s.loadFailed else s.noFilesReceived, if (failed) s.retryHint else s.filesEmptyHint,
                        if (failed) ({ load(true) }) else null)
                } else PullToRefreshBox(isRefreshing = loading && LocalPageActive.current, onRefresh = { load(true) }) {
                    LazyColumn(state = list, contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 24.dp), modifier = Modifier.fillMaxSize()) {
                        items(entries, key = { it.id }) { file ->
                            Surface(Modifier.fillMaxWidth().padding(bottom = 12.dp), shape = RoundedCornerShape(24.dp), color = colors.surface) {
                                Row(Modifier.clickable { open(file) }.heightIn(min = 80.dp).padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    ClipyIconTile(ClipyIcons.description_outlined); Spacer(Modifier.width(16.dp))
                                    Column(Modifier.weight(1f)) {
                                        Text(file.name, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
                                        val date = materialMediumDate(file.createdAt, s.chinese)
                                        Text("${formatFileSize(file.size)} · ${s.fromSender(file.sender)}\n$date", style = MaterialTheme.typography.bodyMedium,
                                            color = colors.onSurfaceVariant)
                                    }
                                    Spacer(Modifier.width(16.dp))
                                    IconButton(onClick = { confirmation = file }, enabled = file.id !in deleting) { ClipyIcon(ClipyIcons.delete_outline_rounded, color = LocalContentColor.current, description = s.delete) }
                                }
                            }
                        }
                        if (failed) item { TextButton(onClick = { load(false) }) { Text(s.retry) } }
                        else if (loading) item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { ClipySpinner() } }
                    }
                }
            }
        }
    }
    if (LocalPageActive.current) confirmation?.let { file ->
        AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = { confirmation = null }, title = { Text(s.delete) }, text = { Text(s.deleteFileConfirm) },
            shape = RoundedCornerShape(24.dp), containerColor = colors.surface,
            dismissButton = { TextButton(onClick = { confirmation = null }) { Text(s.cancel) } },
            confirmButton = { Button(contentPadding = clipyButtonPadding(), onClick = {
                confirmation = null; deleting = deleting + file.id
                scope.launch {
                    try { store.delete(file); load(true) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { message(s.fileDeleteFailed) }
                    finally { deleting = deleting - file.id }
                }
            }, modifier = Modifier.heightIn(min = 48.dp), colors = ButtonDefaults.buttonColors(containerColor = colors.error), shape = RoundedCornerShape(16.dp)) { Text(s.delete) } })
    }
}

fun formatFileSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(Locale.US, "%.1f KB", bytes / 1024.0)
    else -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024.0))
}
