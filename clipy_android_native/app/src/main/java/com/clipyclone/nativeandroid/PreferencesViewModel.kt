package com.clipyclone.nativeandroid

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

data class PreferencesState(val appearance: String, val language: String)

/** Read/write the existing shared_preferences file and keys, preserving unknown keys. */
class PreferencesViewModel(application: Application) : AndroidViewModel(application) {
    private val prefs = application.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(PreferencesState(
        prefs.getString("flutter.appearance", "system")!!.let { if (it in setOf("system", "light", "dark")) it else "system" },
        prefs.getString("flutter.appLanguage", null)?.takeIf { it == "en" || it == "zh" }
            ?: if (Locale.getDefault().language == "zh") "zh" else "en",
    ))
    val state = mutable.asStateFlow()
    fun appearance(value: String) { require(value in setOf("system", "light", "dark")); save("appearance", value) }
    fun language(value: String) { require(value == "en" || value == "zh"); save("appLanguage", value) }
    private fun save(key: String, value: String) {
        viewModelScope.launch {
            val saved = withContext(Dispatchers.IO) { prefs.edit().putString("flutter.$key", value).commit() }
            if (saved) mutable.value = if (key == "appearance") mutable.value.copy(appearance = value) else mutable.value.copy(language = value)
        }
    }
}
