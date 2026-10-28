package com.clipyclone.nativeandroid.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.clearAndSetSemantics

/** Business effects remain alive, but hidden pages do not participate in layout/focus/accessibility. */
val LocalPageActive = staticCompositionLocalOf { true }
val LocalSelectedTab = staticCompositionLocalOf { 0 }
val LocalReduceMotion = staticCompositionLocalOf { false }

@Composable
fun KeepAliveTabs(selected: Int, modifier: Modifier = Modifier, content: @Composable (Int) -> Unit) {
    require(selected in 0..3)
    var visited by rememberSaveable { mutableIntStateOf(1 shl selected) }
    val mask = visited or (1 shl selected)
    SideEffect { if (visited != mask) visited = mask }
    val keys = (0..3).filter { mask and (1 shl it) != 0 }
    ActivePageLayout(keys, selected, modifier, content)
}

/** A route stack uses this same layout; removing a key disposes that route and its jobs. */
@Composable
fun <T> ActivePageLayout(keys: List<T>, selected: T, modifier: Modifier = Modifier, content: @Composable (T) -> Unit) {
    val parentActive = LocalPageActive.current
    require(selected in keys)
    Layout(modifier = modifier, content = {
        keys.forEach { page ->
            key(page) {
                val active = parentActive && page == selected
                CompositionLocalProvider(LocalPageActive provides active) {
                    Box(Modifier.focusProperties { canFocus = active }
                        .then(if (active) Modifier else Modifier.clearAndSetSemantics { })) { content(page) }
                }
            }
        }
    }) { measurables, constraints ->
        require(constraints.hasBoundedWidth && constraints.hasBoundedHeight)
        val visible = measurables[keys.indexOf(selected)].measure(constraints)
        layout(constraints.maxWidth, constraints.maxHeight) { visible.placeRelative(0, 0) }
    }
}
