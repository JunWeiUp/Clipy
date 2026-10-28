package com.clipyclone.nativeandroid.ui

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.clipyclone.nativeandroid.PreferencesState
import com.clipyclone.clipy_android.TimerWidgetProvider

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsPage(state: PreferencesState, appearance: (String) -> Unit, language: (String) -> Unit,
                 openConnection: () -> Unit, openFiles: () -> Unit, openLogs: () -> Unit,
                 message: (String) -> Unit, topContent: @Composable () -> Unit = {}) {
    val s = LocalStrings.current
    val context = LocalContext.current
    val colors = MaterialTheme.colorScheme
    val lifecycle = LocalLifecycleOwner.current
    var pinned by remember { mutableStateOf(TimerWidgetProvider.isPinned(context)) }
    var pinning by remember { mutableStateOf(false) }
    var languageMenu by remember { mutableStateOf(false) }
    var languageWidth by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val selectedLanguage = if (state.language == "zh") "中文" else "English"
    val version = remember(context) {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        "v${info.versionName} ($code)"
    }
    DisposableEffect(lifecycle, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) pinned = TimerWidgetProvider.isPinned(context)
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(pinning) {
        if (pinning) { kotlinx.coroutines.delay(3000); pinned = TimerWidgetProvider.isPinned(context); pinning = false }
    }
    val scroll = rememberScrollState()
    val header = rememberPageHeaderState()
    Column(Modifier.fillMaxSize()) {
        CollapsingPageHeader(header, s.settings, s.settingsTagline)
        topContent()
        Column(Modifier.weight(1f).fillMaxWidth().observePageHeader(header) { scroll.headerMetrics() }
            .verticalScroll(scroll).padding(start = 20.dp, top = 4.dp, end = 20.dp, bottom = 28.dp)) {
            SettingsSection(s.personalize) {
                SettingsRow(ClipyIcons.palette_outlined, s.appearance)
                Box(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 16.dp).heightIn(min = 48.dp),
                    contentAlignment = Alignment.Center) {
                CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 0.dp) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                    listOf("system" to s.systemTheme, "light" to s.lightTheme, "dark" to s.darkTheme).forEachIndexed { index, option ->
                        SegmentedButton(modifier = Modifier.fillMaxHeight(), contentPadding = PaddingValues(horizontal = 12.dp), selected = state.appearance == option.first, onClick = { appearance(option.first) },
                            shape = SegmentedButtonDefaults.itemShape(index, 3), icon = {}) { Text(option.second) }
                    }
                }
                }
                }
                HorizontalDivider(Modifier.padding(horizontal = 20.dp), color = colors.outlineVariant.copy(alpha = .55f))
                SettingsRow(ClipyIcons.language_rounded, s.languageLabel, trailing = {
                    val measurer = rememberTextMeasurer()
                    val languageStyle = MaterialTheme.typography.titleMedium
                    val labelWidth = remember(measurer, languageStyle, density) {
                        with(density) { maxOf(measurer.measure("中文", languageStyle).size.width,
                            measurer.measure("English", languageStyle).size.width).toDp() }
                    }
                    Box {
                        Row(Modifier.heightIn(min = 48.dp).onSizeChanged { languageWidth = it.width }
                            .clickable(role = Role.Button) { languageMenu = true }
                            .clearAndSetSemantics { role = Role.Button; contentDescription = "${s.languageLabel}\n$selectedLanguage"; onClick { languageMenu = true; true } },
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(selectedLanguage, Modifier.width(labelWidth), style = MaterialTheme.typography.titleMedium, color = colors.onSurface)
                            ClipyIcon(ClipyIcons.arrow_drop_down, color = if (colors.surface.luminance() < .5f) Color.White.copy(alpha = .7f) else Color(0xFF616161))
                        }
                        DropdownMenu(expanded = languageMenu && LocalPageActive.current, onDismissRequest = { languageMenu = false },
                            modifier = Modifier.width(with(density) { languageWidth.toDp() } + 40.dp),
                            offset = DpOffset(-16.dp, if (state.language == "en") (-104).dp else (-56).dp),
                            shape = RoundedCornerShape(2.dp), containerColor = colors.surface, tonalElevation = 0.dp, shadowElevation = 8.dp) {
                            listOf("zh" to "中文", "en" to "English").forEach { option ->
                                val selected = state.language == option.first
                                DropdownMenuItem(text = { Text(option.second, style = MaterialTheme.typography.titleMedium, color = colors.onSurface) },
                                    contentPadding = PaddingValues(horizontal = 16.dp),
                                    modifier = Modifier.then(if (selected) Modifier.background(if (colors.surface.luminance() < .5f) Color.White.copy(alpha = .12f) else Color.Black.copy(alpha = .12f)) else Modifier),
                                    onClick = { languageMenu = false; language(option.first) })
                            }
                        }
                    }
                })
            }
            SettingsSection(s.homeWidgetSection) {
                Column(Modifier.padding(20.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        ClipyIconTile(ClipyIcons.timer_outlined)
                        Spacer(Modifier.width(14.dp))
                        Text(s.timerWidgetTitle, style = MaterialTheme.typography.titleMedium)
                    }
                    Spacer(Modifier.height(14.dp))
                    Text(s.timerWidgetDesc, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(18.dp))
                    FilledTonalButton(contentPadding = clipyButtonPadding(icon = true), onClick = {
                        val ok = try {
                            Build.VERSION.SDK_INT >= 26 && AppWidgetManager.getInstance(context)
                                .requestPinAppWidget(ComponentName(context, TimerWidgetProvider::class.java), null, null)
                        } catch (_: Exception) { false }
                        if (ok) pinning = true
                        message(if (ok) s.timerWidgetPinRequested else s.timerWidgetPinFailed)
                    }, enabled = !pinned && !pinning, shape = RoundedCornerShape(16.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                        ClipyButtonIcon(if (pinned) ClipyIcons.check_circle_outline else ClipyIcons.add_rounded)
                        Spacer(Modifier.width(clipyButtonSpacing()))
                        Text(if (pinned) s.timerWidgetAdded else s.addToHomeScreen)
                    }
                }
            }
            SettingsSection(s.toolsAndSupport) {
                SettingsRow(ClipyIcons.tune_rounded, s.connectionSettings, onClick = openConnection)
                HorizontalDivider(Modifier.padding(start = 76.dp, end = 20.dp), color = colors.outlineVariant.copy(alpha = .55f))
                SettingsRow(ClipyIcons.folder_open_rounded, s.receivedFiles, onClick = openFiles)
                HorizontalDivider(Modifier.padding(start = 76.dp, end = 20.dp), color = colors.outlineVariant.copy(alpha = .55f))
                SettingsRow(ClipyIcons.article_outlined, s.viewLogs, s.appRuntimeLogs, onClick = openLogs)
            }
            Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Clipy", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(6.dp))
                Text(s.aboutClipy, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
                Spacer(Modifier.height(10.dp))
                Text("${s.appVersionLabel} $version", style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(bottom = 24.dp)) {
        Text(title, Modifier.padding(start = 4.dp, end = 4.dp, bottom = 12.dp), style = MaterialTheme.typography.titleMedium)
        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.fillMaxWidth(), content = content)
        }
    }
}

@Composable
private fun SettingsRow(icon: Int, title: String, subtitle: String? = null, onClick: (() -> Unit)? = null,
                        trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().then(if (onClick == null) Modifier else Modifier.clickable(onClick = onClick))
        .heightIn(min = if (subtitle == null) 64.dp else 80.dp).padding(horizontal = 20.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        ClipyIconTile(icon)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (trailing != null) trailing()
        else if (onClick != null) ClipyIcon(ClipyIcons.chevron_right_rounded)
    }
}
