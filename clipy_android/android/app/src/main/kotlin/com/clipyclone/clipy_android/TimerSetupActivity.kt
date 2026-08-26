package com.clipyclone.clipy_android

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.TextView
import java.util.Locale

/**
 * Fullscreen drag-to-set panel opened by tapping the timer widget's readout.
 * Plain framework Activity (no AppCompat/Flutter) so it opens instantly even
 * when the process was dead. Tapping outside the card dismisses the panel.
 */
class TimerSetupActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.timer_panel)

        val timeText = findViewById<TextView>(R.id.panel_time)
        val startButton = findViewById<Button>(R.id.panel_start)
        val dialView = findViewById<TimerDialView>(R.id.panel_dial)
        dialView.setValue(TimerWidgetProvider.currentDurationMinutes(this))
        fun render(minutes: Int) {
            timeText.text = String.format(Locale.ROOT, "%02d:00", minutes)
            startButton.isEnabled = minutes > 0
        }
        dialView.onMinutesChanged = { render(it) }
        render(dialView.minutes)

        findViewById<Button>(R.id.panel_cancel).setOnClickListener { finish() }
        startButton.setOnClickListener {
            TimerWidgetProvider.start(this, dialView.minutes)
            finish()
        }
        findViewById<View>(R.id.panel_root).setOnClickListener { finish() }
    }
}
