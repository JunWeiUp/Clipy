package com.clipyclone.nativeandroid

import com.clipyclone.nativeandroid.ui.PageHeaderState
import org.junit.Assert.*
import org.junit.Test

class PageHeaderStateTest {
    @Test fun longListsCollapsePast48AndOnlyExpandAtTop() {
        val state = PageHeaderState()
        state.scroll(49f, 400f, -49f); assertTrue(state.collapsed)
        state.scroll(20f, 400f, 29f); assertTrue(state.collapsed)
        state.scroll(0f, 400f, 20f); assertFalse(state.collapsed)
    }
    @Test fun shortListRequires24InOneGestureAndIgnoresViewportChanges() {
        val state = PageHeaderState()
        state.beginGesture(); state.scroll(0f, 30f, -15f); assertFalse(state.collapsed)
        state.beginGesture(); state.scroll(0f, 30f, -15f); assertFalse(state.collapsed)
        state.scroll(0f, 30f, 9f); assertTrue(state.collapsed)
        state.scroll(0f, 0f, null); assertTrue(state.collapsed)
        state.reset(); assertFalse(state.collapsed)
    }
}
