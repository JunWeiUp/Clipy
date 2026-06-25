package com.clipyclone.clipy_android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build

class SystemStatusReceiver : BroadcastReceiver() {
    private var lastFingerprint: String? = null

    override fun onReceive(context: Context, intent: Intent) {
        emitCurrentStatus(context)
    }

    fun emitCurrentStatus(context: Context? = null) {
        val appContext = context ?: return
        val batteryIntent = appContext.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )

        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val batteryLevel = if (level >= 0 && scale > 0) {
            ((level * 100f) / scale).toInt()
        } else {
            -1
        }
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL

        val connectivityManager =
            appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        var networkType = "none"
        var ssid = ""

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = connectivityManager.activeNetwork
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            networkType = when {
                capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "wifi"
                capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "cellular"
                capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ethernet"
                else -> "none"
            }
        } else {
            @Suppress("DEPRECATION")
            val info = connectivityManager.activeNetworkInfo
            networkType = when (info?.type) {
                ConnectivityManager.TYPE_WIFI -> "wifi"
                ConnectivityManager.TYPE_MOBILE -> "cellular"
                else -> "none"
            }
        }

        if (networkType == "wifi") {
            try {
                val wifiManager =
                    appContext.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                ssid = wifiManager.connectionInfo?.ssid?.replace("\"", "") ?: ""
            } catch (_: Exception) {
                ssid = ""
            }
        }

        val fingerprint = "$batteryLevel|$isCharging|$networkType|$ssid"
        if (fingerprint == lastFingerprint) return
        lastFingerprint = fingerprint

        CollectorEventBridge.emit(
            context = appContext,
            category = "system",
            payload = mapOf(
                "batteryLevel" to batteryLevel,
                "isCharging" to isCharging,
                "networkType" to networkType,
                "ssid" to ssid,
            ),
        )
    }
}
