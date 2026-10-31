package com.clipyclone.clipy_android

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.RingtoneManager
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
            ACTION_FINISHED -> {
                Log.i(TAG, "finish alarm fired")
                refreshAll(ctx, notifyOnExpire = true)
            }
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
        // Duration is stored in seconds; the panel's wheel picker allows up
        // to 23:59:59 (the old 40-minute cap is gone).
        const val DEFAULT_DURATION_SEC = 40 * 60
        val MAX_DURATION_SEC = 23 * 3600 + 59 * 60 + 59
        private const val PREFS = "timer_widget"
        private const val KEY_STATE = "state"
        private const val KEY_DURATION_SEC = "duration_seconds"

        /** Legacy minute key from the 40-minute-cap era, migrated on read. */
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

        // v2: channel sound/vibration settings are locked at creation, so the
        // alarm-grade sound needed a fresh channel id.
        private const val CHANNEL_ID = "clipy_timer_v2"
        private const val NOTIFICATION_ID = 0x7103
        // Ongoing "countdown running" notification: silent, chronometer-driven;
        // MIUI/HyperOS renders it as a status-bar focus countdown.
        private const val RUNNING_CHANNEL_ID = "clipy_timer_running"
        private const val RUNNING_NOTIFICATION_ID = 0x7104

        // Palette sampled from the MIUI clock reference screenshot, shared
        // with the wheel panel (see TimerWheelPicker).
        val COLOR_TEXT = 0xFFF2F2F2.toInt()
        val COLOR_MUTED = 0xFF808080.toInt()
        val COLOR_IDLE = 0xFF515151.toInt()
        val COLOR_ACCENT = 0xFF4787FD.toInt()
        val COLOR_FINISHED = 0xFFFFB169.toInt()

        private fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun isPinned(ctx: Context): Boolean =
            AppWidgetManager.getInstance(ctx)
                .getAppWidgetIds(ComponentName(ctx, TimerWidgetProvider::class.java))
                .isNotEmpty()

        fun currentDurationSeconds(ctx: Context): Int = currentDurationSeconds(prefs(ctx))

        private fun currentDurationSeconds(p: SharedPreferences): Int {
            if (p.contains(KEY_DURATION_SEC)) return p.getInt(KEY_DURATION_SEC, DEFAULT_DURATION_SEC)
            // Migrate the legacy minutes value once.
            return p.getInt(KEY_DURATION_MIN, 40) * 60
        }

        /** Set (or restart) the countdown — called from the wheel panel. */
        fun start(context: Context, seconds: Int) {
            val ctx = context.applicationContext
            val sec = seconds.coerceIn(1, MAX_DURATION_SEC)
            prefs(ctx).edit()
                .putInt(KEY_DURATION_SEC, sec)
                .putLong(KEY_END_AT, System.currentTimeMillis() + sec * 1000L)
                .putLong(KEY_REMAINING, sec * 1000L)
                .putString(KEY_STATE, RUNNING)
                .apply()
            cancelFinishedNotification(ctx)
            armFinishAlarm(ctx)
            refreshAll(ctx)
            postRunningNotification(ctx)
        }

        /** -/+ widget button: 1-minute step, clamped to 1s..23:59:59. */
        fun adjust(context: Context, deltaMinutes: Int) {
            val ctx = context.applicationContext
            val p = prefs(ctx)
            when (p.getString(KEY_STATE, IDLE)) {
                RUNNING -> {
                    val remaining = (remainingMillis(p) + deltaMinutes * 60_000L)
                        .coerceIn(1_000L, MAX_DURATION_SEC * 1000L)
                    p.edit()
                        .putLong(KEY_END_AT, System.currentTimeMillis() + remaining)
                        .apply()
                    armFinishAlarm(ctx)
                    postRunningNotification(ctx)
                }
                PAUSED -> {
                    val remaining =
                        (p.getLong(KEY_REMAINING, DEFAULT_DURATION_SEC * 1000L) + deltaMinutes * 60_000L)
                            .coerceIn(1_000L, MAX_DURATION_SEC * 1000L)
                    p.edit().putLong(KEY_REMAINING, remaining).apply()
                }
                else -> {
                    val duration = (currentDurationSeconds(p) + deltaMinutes * 60)
                        .coerceIn(1, MAX_DURATION_SEC)
                    p.edit().putInt(KEY_DURATION_SEC, duration).apply()
                }
            }
            refreshAll(ctx)
        }

        /** Start / pause button; in FINISHED state it is a stop (✕) button. */
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
                    postRunningNotification(ctx)
                }
                PAUSED -> {
                    val remaining = p.getLong(KEY_REMAINING, DEFAULT_DURATION_SEC * 1000L)
                    p.edit()
                        .putLong(KEY_END_AT, System.currentTimeMillis() + remaining)
                        .putString(KEY_STATE, RUNNING)
                        .apply()
                    armFinishAlarm(ctx)
                    postRunningNotification(ctx)
                }
                FINISHED -> reset(ctx)
                else -> start(ctx, currentDurationSeconds(ctx))
            }
            refreshAll(ctx)
        }

        fun reset(context: Context) {
            val ctx = context.applicationContext
            TimerRinger.stop()
            cancelRunningNotification(ctx)
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
            val durationSec = currentDurationSeconds(ctx)
            p.edit().putString(KEY_STATE, FINISHED).apply()
            cancelFinishAlarm(ctx)
            cancelRunningNotification(ctx)
            if (notifyOnExpire) {
                TimerRinger.start(ctx)
                notifyFinished(ctx, durationSec)
            }
        }

        /**
         * Persistent countdown notification. While running it embeds the
         * framework chronometer in countdown mode, so it ticks by itself —
         * and MIUI/HyperOS surfaces it as a status-bar countdown next to the
         * clock. Paused shows the frozen remaining time instead.
         */
        private fun postRunningNotification(ctx: Context) {
            val p = prefs(ctx)
            val state = p.getString(KEY_STATE, IDLE)
            if (state != RUNNING && state != PAUSED) return
            ensureRunningChannel(ctx)
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
            val remaining = remainingMillis(p)
            val remainingText = formatMillis(remaining)
            val contentPI = PendingIntent.getActivity(
                ctx,
                6,
                Intent(ctx, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = NotificationCompat.Builder(ctx, RUNNING_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(ctx.getString(R.string.timer_countdown_title))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentPI)
                .addAction(
                    0,
                    ctx.getString(
                        if (state == RUNNING) R.string.timer_action_pause else R.string.timer_action_resume,
                    ),
                    broadcastPI(ctx, ACTION_TOGGLE, 2),
                )
                .addAction(
                    0,
                    ctx.getString(R.string.timer_widget_reset),
                    broadcastPI(ctx, ACTION_RESET, 3),
                )
            if (state == RUNNING) {
                builder.setUsesChronometer(true)
                builder.setChronometerCountDown(true)
                builder.setWhen(p.getLong(KEY_END_AT, System.currentTimeMillis()))
            } else {
                builder.setShowWhen(false)
                builder.setContentText(ctx.getString(R.string.timer_countdown_paused, remainingText))
            }
            try {
                NotificationManagerCompat.from(ctx).notify(RUNNING_NOTIFICATION_ID, builder.build())
            } catch (e: Exception) {
                Log.w(TAG, "post running notification failed", e)
            }
        }

        private fun cancelRunningNotification(ctx: Context) {
            try {
                NotificationManagerCompat.from(ctx).cancel(RUNNING_NOTIFICATION_ID)
            } catch (_: Exception) {
            }
        }

        private fun ensureRunningChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(RUNNING_CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                RUNNING_CHANNEL_ID,
                ctx.getString(R.string.timer_running_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = ctx.getString(R.string.timer_running_channel_desc)
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(channel)
        }

        private fun remainingMillis(p: SharedPreferences): Long {
            return when (p.getString(KEY_STATE, IDLE)) {
                RUNNING -> p.getLong(KEY_END_AT, 0L) - System.currentTimeMillis()
                PAUSED -> p.getLong(KEY_REMAINING, DEFAULT_DURATION_SEC * 1000L)
                else -> currentDurationSeconds(p) * 1000L
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
                    RUNNING -> COLOR_ACCENT
                    FINISHED -> COLOR_FINISHED
                    PAUSED -> COLOR_MUTED
                    else -> COLOR_IDLE
                },
            )
            views.setTextColor(
                R.id.time_text,
                if (state == FINISHED) COLOR_FINISHED else COLOR_TEXT,
            )
            // The primary button is state-shaped: ▶/⏸ normally, but once the
            // countdown is finished it becomes the amber ✕ that silences the
            // alarm — the always-visible stop affordance on the widget.
            when (state) {
                RUNNING -> {
                    views.setTextViewText(R.id.btn_toggle, "⏸")
                    views.setTextColor(R.id.btn_toggle, COLOR_ACCENT)
                }
                FINISHED -> {
                    views.setTextViewText(R.id.btn_toggle, "✕")
                    views.setTextColor(R.id.btn_toggle, COLOR_FINISHED)
                }
                else -> {
                    views.setTextViewText(R.id.btn_toggle, "▶")
                    views.setTextColor(R.id.btn_toggle, COLOR_ACCENT)
                }
            }

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

        private fun notifyFinished(ctx: Context, durationSec: Int) {
            ensureChannel(ctx)
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
            val durationText = String.format(
                Locale.ROOT, "%02d:%02d:%02d",
                durationSec / 3600, durationSec % 3600 / 60, durationSec % 60,
            )
            val contentPI = PendingIntent.getActivity(
                ctx,
                6,
                Intent(ctx, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // Alarm-grade: full-screen alert over the lock screen. The sound
            // itself is played by TimerRinger (channel ringtones are muted by
            // some OEM ROMs); the notification is the visual anchor.
            val fullScreenPI = PendingIntent.getActivity(
                ctx,
                7,
                Intent(ctx, TimerRingingActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(ctx.getString(R.string.timer_widget_done_title))
                .setContentText(ctx.getString(R.string.timer_widget_done_text, durationText))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setOngoing(true)
                .setAutoCancel(true)
                .setContentIntent(contentPI)
                .setFullScreenIntent(fullScreenPI, true)
                .addAction(
                    0,
                    ctx.getString(R.string.timer_widget_reset),
                    broadcastPI(ctx, ACTION_RESET, 3),
                )
                .build()
            notification.flags = notification.flags or Notification.FLAG_INSISTENT
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
            val alarmSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val channel = NotificationChannel(
                CHANNEL_ID,
                ctx.getString(R.string.timer_widget_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = ctx.getString(R.string.timer_widget_channel_desc)
                setShowBadge(false)
                // Alarm stream: independent of media volume, rings through
                // alarms-only DND.
                setSound(
                    alarmSound,
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(
                    0, 300, 150, 300, 150, 300, 150, 300, 150, 300,
                )
            }
            nm.createNotificationChannel(channel)
        }
    }
}
