package com.clipyclone.nativeandroid.ui

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/** intl 0.20.2 MMMEd used by the shipping GlobalMaterialLocalizations; no year. */
fun materialMediumDate(timestamp: Long, chinese: Boolean, zone: TimeZone = TimeZone.getDefault()): String {
    val date = Calendar.getInstance(zone, Locale.US).apply { timeInMillis = timestamp }
    val weekday = date.get(Calendar.DAY_OF_WEEK) - Calendar.SUNDAY
    val month = date.get(Calendar.MONTH)
    val day = date.get(Calendar.DAY_OF_MONTH)
    return if (chinese) "${month + 1}月${day}日${listOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")[weekday]}"
    else "${listOf("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[weekday]}, ${listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")[month]} $day"
}
