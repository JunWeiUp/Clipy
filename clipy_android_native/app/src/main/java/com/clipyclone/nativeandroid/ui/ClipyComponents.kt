package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.sp
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
fun ClipyPageHeading(title: String, subtitle: String) {
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, top = 8.dp, end = 24.dp, bottom = 20.dp)) {
        ClipyHeadingText(title, MaterialTheme.typography.headlineLarge)
        Spacer(Modifier.height(6.dp))
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun ClipyEmptyState(glyph: Int, title: String, message: String, retry: (() -> Unit)? = null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 416.dp).verticalScroll(rememberScrollState()).padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            ClipyIconTile(glyph, 80.dp)
            Spacer(Modifier.height(24.dp))
            ClipyHeadingText(title, MaterialTheme.typography.titleLarge, TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            Text(message, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (retry != null) {
                Spacer(Modifier.height(20.dp))
                Button(onClick = retry, modifier = Modifier.heightIn(min = 48.dp), shape = androidx.compose.foundation.shape.RoundedCornerShape(16.dp), contentPadding = clipyButtonPadding()) { Text(LocalStrings.current.retry) }
            }
        }
    }
}

/** Filled/outlined button geometry from Flutter ButtonStyleButton.scaledPadding. */
@Composable
fun clipyButtonPadding(icon: Boolean = false): PaddingValues {
    val density = LocalDensity.current
    val scale = with(density) { 14.sp.toPx() } / density.density / 14f
    fun scaled(a: Float, b: Float, c: Float): Float = when {
        scale <= 1f -> a
        scale < 2f -> a + (b - a) * (scale - 1f)
        scale < 3f -> b + (c - b) * (scale - 2f)
        else -> c
    }
    return PaddingValues(start = scaled(if (icon) 16f else 24f, if (icon) 8f else 12f, if (icon) 4f else 6f).dp,
        end = scaled(24f, 12f, 6f).dp)
}
@Composable
fun clipyButtonSpacing(): androidx.compose.ui.unit.Dp {
    val density = LocalDensity.current
    val scale = with(density) { 14.sp.toPx() } / density.density / 14f
    return (8f - 4f * (scale - 1f).coerceIn(0f, 1f)).dp
}
@Composable
fun ClipyButtonIcon(glyph: Int) = ClipyIcon(glyph, size = 18.dp, color = LocalContentColor.current)

/** Android fallback font metrics can override a fixed CJK headline line height by 7dp.
 * Keep Flutter's explicit line box, centering the platform glyph leading within it. */
@Composable
internal fun ClipyHeadingText(text: String, style: TextStyle, align: TextAlign = TextAlign.Start) {
    val density = LocalDensity.current
    var lines by remember(text, style, density) { mutableIntStateOf(1) }
    val linePx = with(density) {
        if (style.lineHeight.isEm) style.fontSize.toPx() * style.lineHeight.value else style.lineHeight.toPx()
    }
    Text(text, style = style, textAlign = align, onTextLayout = { lines = it.lineCount },
        modifier = Modifier.layout { measurable, constraints ->
            val child = measurable.measure(constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity))
            val target = kotlin.math.ceil(linePx * lines).toInt().coerceIn(constraints.minHeight, constraints.maxHeight)
            layout(child.width, target) { child.place(0, (target - child.height) / 2) }
        })
}

/** Flutter AppBar and NavigationBar clamp only chrome typography, not page text. */
@Composable
fun clampedChromeTextStyle(style: TextStyle, maxScale: Float): TextStyle {
    val density = LocalDensity.current
    return with(density) {
        val actual = style.fontSize.toPx()
        val capped = minOf(actual, style.fontSize.value * this.density * maxScale)
        if (actual <= capped) style else style.copy(fontSize = capped.toSp(),
            lineHeight = if (style.lineHeight.isSp) (style.lineHeight.toPx() * capped / actual).toSp() else style.lineHeight)
    }
}

@Composable
fun clipyOutlinedBorder(enabled: Boolean = true) = androidx.compose.foundation.BorderStroke(1.dp,
    if (enabled) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface.copy(alpha = .12f))

/** Flutter Dialog uses intrinsic content width with a 280dp minimum and 40dp side insets. */
@Composable
fun clipyDialogModifier(): Modifier = Modifier
    .widthIn(max = (androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp - 80).coerceAtLeast(0).dp)
    .width(IntrinsicSize.Max)

/** Flutter modal routes retain the black legacy system navigation bar before edge-to-edge enforcement. */
@Composable
internal fun ClipyModalSystemBars() {
    val view = androidx.compose.ui.platform.LocalView.current
    val window = (view.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window ?: return
    DisposableEffect(window) {
        val controller = androidx.core.view.WindowCompat.getInsetsController(window, window.decorView)
        @Suppress("DEPRECATION") val previous = window.navigationBarColor
        val wasLight = controller.isAppearanceLightNavigationBars
        if (android.os.Build.VERSION.SDK_INT < 35) {
            @Suppress("DEPRECATION")
            window.navigationBarColor = android.graphics.Color.BLACK
            controller.isAppearanceLightNavigationBars = false
        }
        onDispose {
            if (android.os.Build.VERSION.SDK_INT < 35) {
                @Suppress("DEPRECATION")
                window.navigationBarColor = previous
                controller.isAppearanceLightNavigationBars = wasLight
            }
        }
    }
}
