package com.clipyclone.clipy_android

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import java.util.Locale

/**
 * Full-screen alert shown by the timer's full-screen intent when the
 * countdown reaches zero (over the lock screen when locked, heads-up
 * notification when unlocked). The insistent alarm notification keeps
 * ringing until the user stops it here, taps the notification, or uses its
 * reset action.
 */
class TimerRingingActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        setContentView(R.layout.timer_ringing)

        val durationSec = TimerWidgetProvider.currentDurationSeconds(this)
        val durationText = String.format(
            Locale.ROOT, "%02d:%02d:%02d",
            durationSec / 3600, durationSec % 3600 / 60, durationSec % 60,
        )
        findViewById<TextView>(R.id.ringing_time).text = durationText
        findViewById<TextView>(R.id.ringing_duration).text =
            getString(R.string.timer_widget_done_text, durationText)

        findViewById<Button>(R.id.ringing_stop).setOnClickListener {
            TimerWidgetProvider.reset(this)
            finish()
        }
        findViewById<View>(R.id.ringing_root).isClickable = true // swallow taps
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Re-fired full-screen intent while already up: keep ringing page.
    }

    override fun onDestroy() {
        // Leaving without pressing stop (back gesture / notification tap
        // opened the app) must not leave the alarm ringing forever.
        if (!isFinishing) {
            // Ringer stops via MAX_RING_SECONDS safety, or user re-opens.
        }
        super.onDestroy()
    }
}
