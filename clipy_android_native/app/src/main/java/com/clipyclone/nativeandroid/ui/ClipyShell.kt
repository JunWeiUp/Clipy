package com.clipyclone.nativeandroid.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.clipyclone.nativeandroid.R

/** Four-route application chrome, matching HomePage rather than native defaults. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClipyShell(selected: Int, select: (Int) -> Unit, openFiles: () -> Unit,
               clearHistory: () -> Unit, clearing: Boolean, reduceMotion: Boolean = false,
               content: @Composable (Int) -> Unit) {
    val strings = LocalStrings.current
    val colors = MaterialTheme.colorScheme
    val titles = listOf(strings.history, strings.devices, strings.notifications, strings.settings)
    val icons = listOf(ClipyIcons.content_paste_rounded, ClipyIcons.devices_rounded,
        ClipyIcons.notifications_outlined, ClipyIcons.tune_rounded)
    var menu by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val fade = remember { Animatable(1f) }
    val focus = LocalFocusManager.current
    val active = LocalPageActive.current
    LaunchedEffect(selected, reduceMotion) {
        focus.clearFocus(force = true); keyboard?.hide()
        withFrameNanos { }
        keyboard?.hide()
        if (reduceMotion) fade.snapTo(1f)
        else { fade.snapTo(0f); fade.animateTo(1f, tween(220, easing = CubicBezierEasing(.215f, .61f, .355f, 1f))) }
    }
    fun navigate(index: Int) { if (index != selected) { focus.clearFocus(force = true); keyboard?.hide(); select(index) } }
    BackHandler(enabled = active && selected != 0) { navigate(0) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 720.dp
        Scaffold(containerColor = colors.background,
            topBar = {
                Row(Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(start = 16.dp, end = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Image(ImageBitmap.imageResource(R.drawable.clipy_logo), contentDescription = null, modifier = Modifier.size(32.dp), filterQuality = FilterQuality.Medium)
                    Spacer(Modifier.width(10.dp))
                    Text("Clipy", style = clampedChromeTextStyle(MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold), 1.34f), color = colors.onSurface)
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = openFiles) { ClipyIcon(ClipyIcons.folder_open_rounded, color = colors.onSurface, description = strings.receivedFiles) }
                    if (selected == 0) Box {
                        IconButton(onClick = { menu = true }) { ClipyIcon(ClipyIcons.more_vert, color = colors.onSurface, description = strings.moreActions) }
                        DropdownMenu(expanded = menu && active, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text(strings.clearHistory, color = colors.error) }, enabled = !clearing,
                                onClick = { menu = false; clearHistory() })
                        }
                    }
                }
            },
            bottomBar = {
                if (!wide) Surface(color = colors.surface) {
                    Row(Modifier.fillMaxWidth().navigationBarsPadding().height(76.dp).selectableGroup()) {
                        titles.forEachIndexed { index, title ->
                            val tooltip = rememberTooltipState()
                            LaunchedEffect(active) { if (!active) tooltip.dismiss() }
                            Box(Modifier.weight(1f).fillMaxHeight()) {
                            TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
                                tooltip = { PlainTooltip { Text(title, style = MaterialTheme.typography.bodySmall) } }, state = tooltip,
                                modifier = Modifier.fillMaxSize()) {
                            Column(Modifier.fillMaxSize().selectable(
                                selected = selected == index, role = Role.Tab, onClick = { navigate(index) }),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.Center) {
                                Box(Modifier.size(width = 64.dp, height = 32.dp), contentAlignment = Alignment.Center) {
                                    if (selected == index) Box(Modifier.requiredSize(64.dp, 32.dp)
                                        .background(colors.primaryContainer, RoundedCornerShape(16.dp)))
                                    ClipyIcon(icons[index], color = if (index == selected) colors.onSecondaryContainer else colors.onSurfaceVariant)
                                }
                                Spacer(Modifier.height(4.dp))
                                Text(title, style = clampedChromeTextStyle(MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), 1.3f),
                                    color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            }
                            }
                        }
                    }
                }
            }) { padding ->
            Row(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding).imePadding()) {
                if (wide) NavigationRail(containerColor = colors.surface) {
                    titles.forEachIndexed { index, title ->
                        NavigationRailItem(modifier = Modifier.height(60.dp), selected = selected == index, onClick = { navigate(index) },
                            icon = { ClipyIcon(icons[index], color = if (index == selected) colors.onSecondaryContainer else colors.onSurfaceVariant) }, label = { Text(title) }, alwaysShowLabel = true,
                            colors = NavigationRailItemDefaults.colors(indicatorColor = colors.primaryContainer))
                    }
                }
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                    Box(Modifier.widthIn(max = 920.dp).fillMaxSize().alpha(fade.value)) {
                        CompositionLocalProvider(LocalReduceMotion provides reduceMotion, LocalSelectedTab provides selected) { KeepAliveTabs(selected) { content(it) } }
                    }
                }
            }
        }
    }
}
