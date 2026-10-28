package com.clipyclone.nativeandroid
import com.clipyclone.nativeandroid.ui.materialMediumDate
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Test
class MaterialDateFormatTest {
    @Test fun matchesFlutterIntlMMMEdWithoutAddingYear() {
        assertEquals("Thu, Jan 1", materialMediumDate(0, false, TimeZone.getTimeZone("UTC")))
        assertEquals("1月1日周四", materialMediumDate(0, true, TimeZone.getTimeZone("UTC")))
    }
}
