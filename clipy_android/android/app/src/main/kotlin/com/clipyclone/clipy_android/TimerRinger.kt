package com.clipyclone.clipy_android

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * Alarm-grade ringing that does NOT rely on the notification channel's
 * sound: MIUI/HyperOS (and some other OEM ROMs) may replace or suppress a
 * notification channel's ringtone even with INSISTENT flags, so the finish
 * alarm plays its own looped ringtone on the ALARM stream and drives its
 * own vibration pattern. Stopped by [stop] from reset/stop paths, or after
 * [MAX_RING_SECONDS] so it can never ring forever.
 */
object TimerRinger {

    private const val TAG = "TimerRinger"
    private const val MAX_RING_SECONDS = 60

    @Volatile private var player: MediaPlayer? = null
    @Volatile private var vibrator: Vibrator? = null

    val isRinging: Boolean
        get() = player?.isPlaying == true

    fun start(context: Context) {
        stop()
        try {
            val appContext = context.applicationContext
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val mp = MediaPlayer()
            player = mp
            mp.setDataSource(appContext, uri)
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            mp.isLooping = true
            mp.setOnCompletionListener {
                // Looping media sometimes ends on OEM builds; re-kick it.
                try {
                    mp.prepare()
                    mp.start()
                } catch (e: Exception) {
                    Log.w(TAG, "ring re-kick failed", e)
                }
            }
            mp.prepare()
            mp.start()
        } catch (e: Exception) {
            Log.w(TAG, "ringtone start failed", e)
        }
        try {
            val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            vibrator = vib
            // Di-di-di: 0.3s on / 0.15s off, repeating.
            vib.vibrate(
                VibrationEffect.createWaveform(
                    longArrayOf(0, 300, 150, 300, 150, 300, 150, 300, 150, 300),
                    0, // repeat index — loops until cancel()
                ),
            )
        } catch (e: Exception) {
            Log.w(TAG, "vibrator start failed", e)
        }
    }

    fun stop() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "ringtone stop failed", e)
        }
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
    }
}
