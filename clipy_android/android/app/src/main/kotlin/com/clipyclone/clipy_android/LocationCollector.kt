package com.clipyclone.clipy_android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

class LocationCollector(private val context: Context) : LocationListener {
    private val handler = Handler(Looper.getMainLooper())
    private var lastLocation: Location? = null
    private var lastEmitAt: Long = 0
    private val minIntervalMs = 5 * 60 * 1000L
    private val minDistanceMeters = 100f

    private val locationManager: LocationManager? =
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    fun start() {
        if (!hasLocationPermission()) return
        val manager = locationManager ?: return

        try {
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
            )
            for (provider in providers) {
                if (!manager.isProviderEnabled(provider)) continue
                manager.requestLocationUpdates(
                    provider,
                    minIntervalMs,
                    minDistanceMeters,
                    this,
                    Looper.getMainLooper(),
                )
            }
            requestUpdate()
        } catch (_: SecurityException) {
        }
    }

    fun stop() {
        try {
            locationManager?.removeUpdates(this)
        } catch (_: SecurityException) {
        }
        handler.removeCallbacksAndMessages(null)
    }

    fun requestUpdate() {
        if (!hasLocationPermission()) return
        val manager = locationManager ?: return
        try {
            val location = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
            ).mapNotNull { provider ->
                if (!manager.isProviderEnabled(provider)) return@mapNotNull null
                manager.getLastKnownLocation(provider)
            }.maxByOrNull { it.time }

            if (location != null) {
                emitLocation(location)
            }
        } catch (_: SecurityException) {
        }
    }

    override fun onLocationChanged(location: Location) {
        emitLocation(location)
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}

    private fun emitLocation(location: Location) {
        val now = System.currentTimeMillis()
        val previous = lastLocation
        if (previous != null) {
            val distance = previous.distanceTo(location)
            val elapsed = now - lastEmitAt
            if (distance < minDistanceMeters && elapsed < minIntervalMs) {
                return
            }
        }

        lastLocation = location
        lastEmitAt = now

        CollectorEventBridge.emit(
            context = context,
            category = "location",
            timestamp = location.time,
            payload = mapOf(
                "latitude" to location.latitude,
                "longitude" to location.longitude,
                "accuracy" to location.accuracy,
                "provider" to (location.provider ?: ""),
            ),
        )
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }
}
