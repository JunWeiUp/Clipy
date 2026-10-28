package com.clipyclone.nativeandroid

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import com.clipyclone.nativeandroid.data.*
import com.clipyclone.nativeandroid.ui.*

/** Debug-only, synthetic fixture surface. Never reads production user data or starts sync. */
class VisualFixtureActivity : ComponentActivity() {
    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); setIntent(intent); recreate() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val scene = intent.getStringExtra("scene") ?: "history"
        val chinese = intent.getStringExtra("language") == "zh"
        val dark = intent.getBooleanExtra("dark", false)
        val epoch = intent.getLongExtra("epoch", System.currentTimeMillis())
        val entries = if (intent.getBooleanExtra("empty", false)) emptyList() else listOf(
            HistoryEntry(1, "a", "text", if (scene == "long-text") "x\n".repeat(512 * 1024) else if (chinese) "为每一次复制，保留一份安心。" else "Everything you copied. Within reach.", "Example Notes", epoch),
            HistoryEntry(2, "b", "text", "https://example.com/clipy", "Example Browser", epoch - 60000),
        ) + if (intent.getBooleanExtra("older", false)) listOf(HistoryEntry(3, "c", "text", "An older saved note.", "Example Notes", epoch - 3 * 24 * 3600 * 1000)) else emptyList()
        setContent {
            var index by remember { mutableIntStateOf(if (scene == "settings") 3 else 0) }
            var preferences by remember { mutableStateOf(PreferencesState(if (dark) "dark" else "light", if (chinese) "zh" else "en")) }
            var history by remember { mutableStateOf(HistoryState(entries = entries, loading = false)) }
            ClipyTheme(dark = preferences.appearance == "dark", chinese = preferences.language == "zh") {
                CompositionLocalProvider(LocalStrings provides AppStrings(preferences.language == "zh")) {
                    ClipyShell(index, { index = it }, {}, {}, clearing = false, reduceMotion = true) { page ->
                        when (page) {
                            0 -> HistoryPage(history, { query, filter -> history = history.copy(query = query, filter = filter) }, {}, {}, { true }, {}, {})
                            3 -> SettingsPage(preferences, { preferences = preferences.copy(appearance = it) },
                                { preferences = preferences.copy(language = it) }, {}, {}, {}, {})
                            else -> Text("No fixture for this route")
                        }
                    }
                }
            }
        }
    }
}
