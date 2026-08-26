package com.clipyclone.clipy_android

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import java.util.Locale

/**
 * Home-screen countdown timer widget (2x2, 1..40 minutes, 1-minute steps).
 *
 * RemoteViews widgets are rendered by the launcher process and can only
 * receive click events — no drag/gesture handling is possible. So the
 * interaction is: -/+ buttons for 1-minute steps on the widget itself, and a
 * tap on the time readout opens [TimerSetupActivity], a fullscreen drag
 * ruler. While running the ticking readout is a countdown-mode Chronometer
 * driven by the launcher (zero per-minute updates from the app;
 * updatePeriodMillis=0), and a single AlarmManager alarm fires the
 * "time's up" notification.
 *
 * State is global (all placed instances mirror one timer) and persisted in
 * SharedPreferences so it survives process death; the remaining time is
 * derived from a wall-clock deadline, so it stays correct across reboots.
 */
class TimerWidgetProvider : AppWidgetProvider() {

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val ctx = context.applicationContext
        when (intent.action) {
            ACTION_MINUS -> adjust(ctx, -1)
            ACTION_PLUS -> adjust(ctx, +1)
            ACTION_TOGGLE -> toggle(ctx)
            ACTION_RESET -> reset(ctx)
            ACTION_FINISHED -> refreshAll(ctx, notifyOnExpire = true)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        refreshAll(context)
    }

    override fun onEnabled(context: Context) {
        refreshAll(context)
    }

    override fun onDisabled(context: Context) {
        // Last instance removed: stop the countdown machinery. Prefs stay so
        // re-adding the widget restores the last configuration.
        cancelFinishAlarm(context.applicationContext)
        cancelFinishedNotification(context.applicationContext)
    }

    companion object {
        private const val TAG = "TimerWidget"
        const val MAX_MINUTES = 40
        const val DEFAULT_MINUTES = 40
        private const val PREFS = "timer_widget"
        private const val KEY_STATE = "state"
        private const val KEY_DURATION_MIN = "duration_minutes"
        private const val KEY_END_AT = "end_at_ms"
        private const val KEY_REMAINING = "remaining_ms"

        private const val IDLE = "idle"
        private const val RUNNING = "running"
        private const val PAUSED = "paused"
        private const val FINISHED = "finished"

        const val ACTION_MINUS = "com.clipyclone.clipy_android.timer.MINUS"
        const val ACTION_PLUS = "com.clipyclone.clipy_android.timer.PLUS"
        const val ACTION_TOGGLE = "com.clipyclone.clipy_android.timer.TOGGLE"
        const val ACTION_RESET = "com.clipyclone.clipy_android.timer.RESET"
        private const val ACTION_FINISHED = "com.clipyclone.clipy_android.timer.FINISHED"

        private const val CHANNEL_ID = "clipy_timer"
        private const val NOTIFICATION_ID = 0x7103

        // Palette shared with the widget layout / panel (see TimerDialView).
        val COLOR_ACCENT = 0xFF4F9CF9.toInt()
        val COLOR_ACCENT_LIGHT = 0xFF8FD0FF.toInt()
        val COLOR_TEXT = 0xFFFFFFFF.toInt()
        val COLOR_TEXT_SOFT = 0xE6FFFFFF.toInt()
        val COLOR_MUTED = 0xFF8DA0BC.toInt()
        val COLOR_FINISHED = 0xFFFFB169.toInt()
        val COLOR_ON_ACCENT = 0xFF0B1220.toInt()

        private fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun isPinned(ctx: Context): Boolean =
            AppWidgetManager.getInstance(ctx)
                .getAppWidgetIds(ComponentName(ctx, TimerWidgetProvider::class.java))
                .isNotEmpty()

        fun currentDurationMinutes(ctx: Context): Int =
            prefs(ctx).getInt(KEY_DURATION_MIN, DEFAULT_MINUTES)

        /** Set (or restart) the countdown — called from the drag panel. */
        fun start(context: Context, minutes: Int) {
            val ctx = context.applicationContext
            val m = minutes.coerceIn(1, MAX_MINUTES)
            prefs(ctx).edit()
                .putInt(KEY_DURATION_MIN, m)
                .putLong(KEY_END_AT, System.currentTimeMillis() + m * 60_000L)
                .putLong(KEY_REMAINING, m * 60_000L)
                .putString(KEY_STATE, RUNNING)
                .apply()
            cancelFinishedNotification(ctx)
            armFinishAlarm(ctx)
            refreshAll(ctx)
        }

        /** -/+ button: 1-minute step, clamped to 1..40 minutes. */
        fun adjust(context: Context, deltaMinutes: Int) {
            val ctx = context.applicationContext
            val p = prefs(ctx)
            when (p.getString(KEY_STATE, IDLE)) {
                RUNNING -> {
                    val remaining = (remainingMillis(p) + deltaMinutes * 60_000L)
                        .coerceIn(60_000L, MAX_MINUTES * 60_000L)
                    p.edit()
                        .putLong(KEY_END_AT, System.currentTimeMillis() + remaining)
                        .apply()
                    armFinishAlarm(ctx)
                }
                PAUSED -> {
                    val remaining =
                        (p.getLong(KEY_REMAINING, DEFAULT_MINUTES * 60_000L) + deltaMinutes * 60_000L)
                            .coerceIn(60_000L, MAX_MINUTES * 60_000L)
                    p.edit().putLong(KEY_REMAINING, remaining).apply()
                }
                else -> {
                    val duration = (p.getInt(KEY_DURATION_MIN, DEFAULT_MINUTES) + deltaMinutes)
                        .coerceIn(1, MAX_MINUTES)
                    p.edit().putInt(KEY_DURATION_MIN, duration).apply()
                }
            }
            refreshAll(ctx)
        }

        /** Start / pause button. */
        fun toggle(context: Context) {
            val ctx = context.applicationContext
            val p = prefs(ctx)
            when (p.getString(KEY_STATE, IDLE)) {
                RUNNING -> {
                    val remaining = remainingMillis(p)
                    val edit = p.edit()
                    if (remaining <= 0L) {
                        edit.putString(KEY_STATE, FINISHED)
                    } else {
                        edit.putLong(KEY_REMAINING, remaining).putString(KEY_STATE, PAUSED)
                    }
                    edit.apply()
                    cancelFinishAlarm(ctx)
                }
                PAUSED -> {
                    val remaining = p.getLong(KEY_REMAINING, DEFAULT_MINUTES * 60_000L)
                    p.edit()
                        .putLong(KEY_END_AT, System.currentTimeMillis() + remaining)
                        .putString(KEY_STATE, RUNNING)
                        .apply()
                    armFinishAlarm(ctx)
                }
                else -> start(ctx, p.getInt(KEY_DURATION_MIN, DEFAULT_MINUTES))
            }
            refreshAll(ctx)
        }

        fun reset(context: Context) {
            val ctx = context.applicationContext
            prefs(ctx).edit().putString(KEY_STATE, IDLE).apply()
            cancelFinishAlarm(ctx)
            cancelFinishedNotification(ctx)
            refreshAll(ctx)
        }

        /** Re-render every placed instance (also called from [BootReceiver]). */
        fun refreshAll(context: Context, notifyOnExpire: Boolean = false) {
            val ctx = context.applicationContext
            normalize(ctx, notifyOnExpire)
            val manager = AppWidgetManager.getInstance(ctx)
            val ids = manager.getAppWidgetIds(
                ComponentName(ctx, TimerWidgetProvider::class.java),
            )
            if (ids.isEmpty()) return
            manager.updateAppWidget(ids, buildViews(ctx))
        }

        /** Fallback for alarms the system dropped: flip to finished on read. */
        private fun normalize(ctx: Context, notifyOnExpire: Boolean) {
            val p = prefs(ctx)
            if (p.getString(KEY_STATE, IDLE) != RUNNING) return
            if (remainingMillis(p) > 0L) return
            val durationMin = p.getInt(KEY_DURATION_MIN, DEFAULT_MINUTES)
            p.edit().putString(KEY_STATE, FINISHED).apply()
            cancelFinishAlarm(ctx)
            if (notifyOnExpire) notifyFinished(ctx, durationMin)
        }

        private fun remainingMillis(p: SharedPreferences): Long {
            return when (p.getString(KEY_STATE, IDLE)) {
                RUNNING -> p.getLong(KEY_END_AT, 0L) - System.currentTimeMillis()
                PAUSED -> p.getLong(KEY_REMAINING, DEFAULT_MINUTES * 60_000L)
                else -> p.getInt(KEY_DURATION_MIN, DEFAULT_MINUTES) * 60_000L
            }
        }

        private fun buildViews(ctx: Context): RemoteViews {
            val p = prefs(ctx)
            val state = p.getString(KEY_STATE, IDLE)
            val remaining = remainingMillis(p)
            val views = RemoteViews(ctx.packageName, R.layout.timer_widget)

            if (state == RUNNING) {
                views.setChronometer(
                    R.id.time_chronometer,
                    SystemClock.elapsedRealtime() + remaining.coerceAtLeast(0L),
                    null,
                    true,
                )
                views.setChronometerCountDown(R.id.time_chronometer, true)
                views.setViewVisibility(R.id.time_chronometer, View.VISIBLE)
                views.setViewVisibility(R.id.time_text, View.GONE)
            } else {
                views.setTextViewText(
                    R.id.time_text,
                    if (state == FINISHED) "00:00" else formatMillis(remaining),
                )
                views.setViewVisibility(R.id.time_text, View.VISIBLE)
                views.setViewVisibility(R.id.time_chronometer, View.GONE)
            }

            val statusRes = when (state) {
                RUNNING -> R.string.timer_widget_status_running
                PAUSED -> R.string.timer_widget_status_paused
                FINISHED -> R.string.timer_widget_status_finished
                else -> R.string.timer_widget_status_idle
            }
            views.setTextViewText(R.id.status_text, ctx.getString(statusRes))
            // Status colors live in their own lane: running=accent blue,
            // finished=amber; the readout dims to amber when time is up.
            views.setTextColor(
                R.id.status_text,
                when (state) {
                    RUNNING -> COLOR_ACCENT_LIGHT
                    FINISHED -> COLOR_FINISHED
                    else -> COLOR_MUTED
                },
            )
            views.setTextColor(
                R.id.time_text,
                if (state == FINISHED) COLOR_FINISHED else COLOR_TEXT,
            )
            // Pause becomes a filled accent pill while running.
            views.setTextViewText(R.id.btn_toggle, if (state == RUNNING) "⏸" else "▶")
            views.setInt(
                R.id.btn_toggle,
                "setBackgroundResource",
                if (state == RUNNING) {
                    R.drawable.timer_widget_button_accent
                } else {
                    R.drawable.timer_widget_button
                },
            )
            views.setTextColor(
                R.id.btn_toggle,
                if (state == RUNNING) COLOR_ON_ACCENT else COLOR_TEXT_SOFT,
            )

            views.setOnClickPendingIntent(R.id.btn_minus, broadcastPI(ctx, ACTION_MINUS, 1))
            views.setOnClickPendingIntent(R.id.btn_toggle, broadcastPI(ctx, ACTION_TOGGLE, 2))
            views.setOnClickPendingIntent(R.id.btn_reset, broadcastPI(ctx, ACTION_RESET, 3))
            views.setOnClickPendingIntent(R.id.btn_plus, broadcastPI(ctx, ACTION_PLUS, 4))
            // Tapping the readout opens the drag-to-set panel — the closest we
            // can get to "drag the widget" given the RemoteViews click-only rule.
            views.setOnClickPendingIntent(
                R.id.time_area,
                PendingIntent.getActivity(
                    ctx,
                    5,
                    Intent(ctx, TimerSetupActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            return views
        }

        private fun broadcastPI(ctx: Context, action: String, requestCode: Int): PendingIntent {
            val intent = Intent(ctx, TimerWidgetProvider::class.java).setAction(action)
            return PendingIntent.getBroadcast(
                ctx,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun formatMillis(millis: Long): String {
            val totalSeconds = (millis.coerceAtLeast(0L) / 1000L).toInt()
            return String.format(Locale.ROOT, "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
        }

        private fun finishPI(ctx: Context): PendingIntent =
            PendingIntent.getBroadcast(
                ctx,
                0,
                Intent(ctx, TimerWidgetProvider::class.java).setAction(ACTION_FINISHED),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        private fun armFinishAlarm(ctx: Context) {
            val endAt = prefs(ctx).getLong(KEY_END_AT, 0L)
            if (endAt <= System.currentTimeMillis()) return
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pi = finishPI(ctx)
            // Exact alarms need SCHEDULE_EXACT_ALARM (denied by default when
            // targeting 33+); degrade to an inexact alarm rather than skipping.
            val canExact =
                Build.VERSION.SDK_INT < Build.VERSION_CODES.S || am.canScheduleExactAlarms()
            try {
                if (canExact) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endAt, pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endAt, pi)
                }
            } catch (e: SecurityException) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endAt, pi)
            }
        }

        private fun cancelFinishAlarm(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(finishPI(ctx))
        }

        private fun notifyFinished(ctx: Context, durationMin: Int) {
            ensureChannel(ctx)
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
            val contentPI = PendingIntent.getActivity(
                ctx,
                6,
                Intent(ctx, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(ctx.getString(R.string.timer_widget_done_title))
                .setContentText(ctx.getString(R.string.timer_widget_done_text, durationMin))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(true)
                .setContentIntent(contentPI)
                .addAction(
                    0,
                    ctx.getString(R.string.timer_widget_reset),
                    broadcastPI(ctx, ACTION_RESET, 3),
                )
                .build()
            try {
                NotificationManagerCompat.from(ctx).notify(NOTIFICATION_ID, notification)
            } catch (e: Exception) {
                Log.w(TAG, "post finished notification failed", e)
            }
        }

        private fun cancelFinishedNotification(ctx: Context) {
            try {
                NotificationManagerCompat.from(ctx).cancel(NOTIFICATION_ID)
            } catch (_: Exception) {
            }
        }

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                ctx.getString(R.string.timer_widget_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = ctx.getString(R.string.timer_widget_channel_desc)
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }
}
