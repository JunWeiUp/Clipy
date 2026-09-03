package com.clipyclone.clipy_android

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * Fullscreen timer-setup page opened by tapping the timer widget's readout,
 * pixel-matched to the MIUI system clock timer page: h:mm:ss wheel picker
 * (no 40-minute cap), preset pills, one wide start button. Plain framework
 * Activity (no AppCompat/Flutter) so it opens instantly even when the
 * process was dead. Back gesture (or tapping the background) dismisses.
 */
class TimerSetupActivity : Activity() {

    private val presetMinutes = listOf(1, 5, 10, 15, 25, 40)
    private val presetViews = mutableListOf<TextView>()
    private lateinit var startButton: Button
    private lateinit var wheel: TimerWheelPicker

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.timer_panel)

        startButton = findViewById(R.id.panel_start)
        wheel = findViewById(R.id.panel_wheel)
        val total = TimerWidgetProvider.currentDurationSeconds(this)
        wheel.setDuration(total / 3600, total % 3600 / 60, total % 60)

        val presetIds = listOf(
            R.id.preset_1, R.id.preset_2, R.id.preset_3,
            R.id.preset_4, R.id.preset_5, R.id.preset_6,
        )
        presetIds.forEachIndexed { index, id ->
            val preset = findViewById<TextView>(id)
            presetViews.add(preset)
            preset.setOnClickListener {
                wheel.setDuration(0, presetMinutes[index], 0)
                render()
            }
        }

        wheel.onDurationChanged = { _, _, _ -> render() }
        render()

        startButton.setOnClickListener {
            // The finished alarm only rings if notifications are allowed;
            // ask once here (no-op when already granted).
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
            }
            TimerWidgetProvider.start(this, wheel.durationSeconds())
            finish()
        }
        findViewById<View>(R.id.panel_root).setOnClickListener { finish() }
    }

    private fun render() {
        startButton.isEnabled = wheel.durationSeconds() > 0
        val seconds = wheel.durationSeconds()
        presetViews.forEachIndexed { index, view ->
            view.isSelected = presetMinutes[index] * 60 == seconds
        }
    }
}
