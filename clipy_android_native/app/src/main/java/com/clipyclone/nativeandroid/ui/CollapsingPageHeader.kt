package com.clipyclone.nativeandroid.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.*
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.abs

/** Gesture semantics mirror ScrollCollapsingHeader, including <=48dp short lists. */
@Stable
class PageHeaderState {
    var collapsed by mutableStateOf(false)
        private set
    private var drag = 0f
    fun reset() { collapsed = false; drag = 0f }
    fun beginGesture() { drag = 0f }
    fun scroll(offset: Float, maxExtent: Float, userDelta: Float?) {
        if (maxExtent <= 48f) {
            if (userDelta != null) { drag += abs(userDelta); if (drag >= 24f) collapsed = true }
        } else {
            if (offset > 48f) collapsed = true
            else if (offset <= 0f) collapsed = false
        }
    }
}

data class HeaderScrollMetrics(val offsetPx: Float, val maxExtentPx: Float)
fun ScrollState.headerMetrics() = HeaderScrollMetrics(value.toFloat(), maxValue.toFloat())
fun LazyListState.headerMetrics(): HeaderScrollMetrics {
    val info = layoutInfo
    val last = info.visibleItemsInfo.lastOrNull()
    val offset = firstVisibleItemScrollOffset.toFloat()
    val max = if (firstVisibleItemIndex == 0 && last?.index == info.totalItemsCount - 1)
        (offset + last.offset + last.size + info.afterContentPadding - info.viewportEndOffset).coerceAtLeast(0f)
        else Float.POSITIVE_INFINITY
    return HeaderScrollMetrics(if (firstVisibleItemIndex > 0) Float.POSITIVE_INFINITY else offset, max)
}

@Composable
fun rememberPageHeaderState(): PageHeaderState {
    val state = remember { PageHeaderState() }
    val selectedTab = LocalSelectedTab.current
    LaunchedEffect(selectedTab) { state.reset() }
    return state
}

@Composable
fun Modifier.observePageHeader(state: PageHeaderState, metrics: () -> HeaderScrollMetrics): Modifier {
    val density = LocalDensity.current.density
    val currentMetrics by rememberUpdatedState(metrics)
    val connection = remember(state, density) { object : NestedScrollConnection {
        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            val position = currentMetrics()
            state.scroll(position.offsetPx / density, position.maxExtentPx / density,
                if (source == NestedScrollSource.UserInput) (consumed.y + available.y) / density else null)
            return Offset.Zero
        }
    } }
    return this.pointerInput(state) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            state.beginGesture()
            do { val event = awaitPointerEvent(PointerEventPass.Initial) } while (event.changes.any { it.pressed })
        }
    }.nestedScroll(connection)
}

@Composable
fun CollapsingPageHeader(state: PageHeaderState, title: String, subtitle: String) {
    val animate = LocalPageActive.current && !LocalReduceMotion.current
    Box(Modifier.fillMaxWidth().animateContentSize(tween(if (animate) 160 else 0))) {
        if (!state.collapsed) ClipyPageHeading(title, subtitle)
    }
}

/** Hidden tabs keep business jobs, but indeterminate animation clocks are not kept running. */
@Composable
fun ClipySpinner(modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.primary, strokeWidth: Dp = 4.dp) {
    if (LocalPageActive.current) CircularProgressIndicator(modifier = modifier, color = color, strokeWidth = strokeWidth)
    else Spacer(modifier.size(40.dp))
}
@Composable
fun ClipyIndeterminateBar(modifier: Modifier = Modifier) {
    if (LocalPageActive.current) LinearProgressIndicator(modifier = modifier) else Spacer(modifier)
}
