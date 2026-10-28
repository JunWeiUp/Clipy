package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipyclone.nativeandroid.data.NativeLogRecord
import com.clipyclone.nativeandroid.data.NativeLogStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun LogPage(store: NativeLogStore, back: () -> Unit, copy: (String) -> Boolean, message: (String) -> Unit) {
    val s = LocalStrings.current; val colors = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope(); val list = rememberLazyListState()
    var rows by remember { mutableStateOf(emptyList<NativeLogRecord>()) }
    var loading by remember { mutableStateOf(false) }; var failed by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(true) }; var pending by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }; var copying by remember { mutableStateOf(false) }
    fun load(reset: Boolean) {
        if (loading) { pending = pending || reset; return }
        loading = true; failed = false
        scope.launch {
            var clear = reset
            try {
                do {
                    val page = store.page(if (clear) 0 else rows.size, 100)
                    rows = if (clear) page else rows + page
                    more = page.size == 100
                    clear = pending; pending = false
                } while (clear)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failed = true }
            finally { loading = false }
        }
    }
    LaunchedEffect(store) { store.revision.collect { load(true) } }
    LaunchedEffect(rows.size, loading, more) {
        if (!loading && more && rows.isNotEmpty()) snapshotFlow { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= rows.size - 3 } == true }
            .collect { if (it) load(false) }
    }
    Scaffold(containerColor = colors.background, topBar = {
        SecondaryAppBar(s.appLogs, back) {
            IconButton(onClick = { confirm = true }) { ClipyIcon(ClipyIcons.delete_sweep, color = colors.onSurface, description = s.clearLogs) }
            IconButton(enabled = !copying, onClick = {
                copying = true
                scope.launch {
                    try {
                        val all = StringBuilder(); var offset = 0
                        do { val page = store.page(offset, 200); page.forEach { all.append(it.formatted).append('\n') }; offset += page.size } while (page.size == 200)
                        message(if (copy(all.toString())) s.logsCopied else s.operationFailed)
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { message(s.operationFailed) }
                    finally { copying = false }
                }
            }) { ClipyIcon(ClipyIcons.copy, color = colors.onSurface, description = s.copyAll) }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (rows.isEmpty() && !loading) ClipyEmptyState(ClipyIcons.article_outlined,
                if (failed) s.loadFailed else s.noLogs, if (failed) s.retryHint else s.appRuntimeLogs, if (failed) ({ load(true) }) else null)
            else LazyColumn(state = list, reverseLayout = true, modifier = Modifier.fillMaxSize()) {
                items(rows, key = { it.id }) { record -> Text(record.formatted, Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace, fontSize = 12.sp)) }
                if (failed) item { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { TextButton(onClick = { load(true) }) { Text(s.retry) } } }
                else if (more || loading) item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { ClipySpinner() } }
            }
        }
    }
    if (confirm && LocalPageActive.current) AlertDialog(modifier = clipyDialogModifier(), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false), onDismissRequest = { confirm = false }, containerColor = colors.surface,
        shape = RoundedCornerShape(24.dp), title = { Text(s.clearLogs) }, text = { Text(s.clearLogsConfirm) },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(s.cancel) } },
        confirmButton = { Button(contentPadding = clipyButtonPadding(), onClick = { confirm = false; scope.launch { try { store.clear() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { message(s.operationFailed) } } },
            modifier = Modifier.heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = colors.error)) { Text(s.delete) } })
}

@Composable
fun SecondaryAppBar(title: String, back: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().height(56.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(56.dp).fillMaxHeight(), contentAlignment = Alignment.Center) {
            IconButton(onClick = back) { ClipyIcon(ClipyIcons.arrow_back, color = MaterialTheme.colorScheme.onSurface, description = if (LocalStrings.current.chinese) "返回" else "Back") }
        }
        Spacer(Modifier.width(16.dp))
        Text(title, Modifier.weight(1f), style = clampedChromeTextStyle(MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold), 1.34f), color = MaterialTheme.colorScheme.onSurface)
        actions()
    }
}
