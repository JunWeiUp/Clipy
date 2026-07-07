package com.clipyclone.clipy_android

import android.content.Context

object FlutterPrefs {
    private const val PREFS_NAME = "FlutterSharedPreferences"

    fun getBool(context: Context, key: String, default: Boolean): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val flutterKey = "flutter.$key"
        if (!prefs.contains(flutterKey)) return default
        return prefs.getBoolean(flutterKey, default)
    }

    fun isCategoryEnabled(context: Context, category: String, default: Boolean = true): Boolean {
        return getBool(context, "collectorCategory_$category", default)
    }
}
