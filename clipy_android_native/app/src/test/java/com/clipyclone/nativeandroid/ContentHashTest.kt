package com.clipyclone.nativeandroid
import com.clipyclone.nativeandroid.data.*
import org.junit.Assert.*
import org.junit.Test

class ContentHashTest {
    @Test fun matchesDartTextNormalization() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ContentHash.text("abc"))
        assertEquals(ContentHash.text("one\ntwo\nthree"), ContentHash.text(" \uFEFFone\r\ntwo\rthree\u00A0"))
        assertEquals(ContentHash.text("abc"), ContentHash.text("\u0085abc\u0085"))
        assertNotEquals(ContentHash.text("abc"), ContentHash.text("\u001Cabc"))
    }
    @Test fun previewDoesNotSplitSurrogate() {
        val entry = HistoryEntry(1, null, "text", "x".repeat(599) + "😀" + "tail", null, 0)
        assertEquals("x".repeat(599) + "…", entry.preview)
    }
}
