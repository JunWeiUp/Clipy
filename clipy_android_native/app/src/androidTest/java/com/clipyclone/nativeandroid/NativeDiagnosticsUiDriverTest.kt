package com.clipyclone.nativeandroid

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.clipy_android.ClipyApplication
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in real-Main UI fixture. Adds only a fictional process-local diagnostic, no sockets. */
@RunWith(AndroidJUnit4::class)
class NativeDiagnosticsUiDriverTest {
    @Test fun manualRefreshAndReset() = runBlocking<Unit> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("diagnosticsUiDriver") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(context.packageName.endsWith(".nativepreview"))
        val app = context.applicationContext as ClipyApplication
        app.sync.initialize()
        assertFalse(app.sync.state.value.settings.enabled)
        app.sync.diagnostics.noteError("parity-diagnostic-peer", "Synthetic connection error", "Parity diagnostic peer", "192.0.2.10")
        try {
            context.startActivity(Intent().setClassName(context.packageName, "com.clipyclone.clipy_android.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            android.util.Log.i("ClipyDiagnosticsUiFixture", "ready-open-real-Devices-Diagnostics-and-reset")
            withTimeout(10 * 60 * 1000L) { app.sync.diagnostics.records.first { it.isEmpty() } }
            android.util.Log.i("ClipyDiagnosticsUiFixture", "PASS reset-cleared-process-local-record")
            delay(2000)
        } finally { app.sync.diagnostics.reset() }
    }
}
